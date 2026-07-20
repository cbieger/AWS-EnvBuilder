#!/usr/bin/env python3
"""AWS Lambda controller for cancellable scheduled Terraform teardown.

The function has two event sources: EventBridge Scheduler calls it once per
minute, and the pre-existing two-way SMS SNS topic forwards operator replies.
It deliberately logs state transitions only—never phone numbers, email
addresses, or message bodies.
"""

from __future__ import annotations

import json
import os
import time
from typing import Any

NOTICE_MINUTES = (720, 120, 60, 15, 5)
TERMINAL_STATES = {"CANCELLED", "EXECUTING"}


def aws(name: str):
    """Create a normal boto3 client; tests replace this single function."""
    import boto3

    return boto3.client(name)


def conditional_failure(error: BaseException) -> bool:
    """Recognize DynamoDB's optimistic-concurrency response without a local SDK."""
    response = getattr(error, "response", {})
    return response.get("Error", {}).get("Code") == "ConditionalCheckFailedException"


def required_environment(name: str) -> str:
    value = os.environ.get(name, "")
    if not value:
        raise RuntimeError(f"Required controller setting {name} is missing.")
    return value


def settings() -> dict[str, Any]:
    return {
        "table": required_environment("SCHEDULE_TABLE"),
        "schedule_id": required_environment("SCHEDULE_ID"),
        "deadline_epoch": int(required_environment("DEADLINE_EPOCH")),
        "deadline_utc": required_environment("DEADLINE_UTC"),
        "local_deadline": required_environment("LOCAL_DEADLINE"),
        "phone": required_environment("OPERATOR_PHONE"),
        "email": required_environment("OPERATOR_EMAIL"),
        "origination": required_environment("SMS_ORIGINATION_NUMBER"),
        "email_topic": required_environment("EMAIL_TOPIC_ARN"),
        "build_project": required_environment("CODEBUILD_PROJECT"),
    }


def key(config: dict[str, Any]) -> dict[str, dict[str, str]]:
    return {"ScheduleId": {"S": config["schedule_id"]}}


def ensure_item(config: dict[str, Any]) -> None:
    """Initialize once; Terraform never manages this mutable state item."""
    try:
        aws("dynamodb").put_item(
            TableName=config["table"],
            Item={
                "ScheduleId": {"S": config["schedule_id"]},
                "Status": {"S": "PENDING"},
                "DeadlineEpoch": {"N": str(config["deadline_epoch"])},
                "CreatedEpoch": {"N": str(int(time.time()))},
                "Notices": {"M": {}},
            },
            ConditionExpression="attribute_not_exists(ScheduleId)",
        )
    except Exception as error:
        if not conditional_failure(error):
            raise


def get_status(config: dict[str, Any]) -> str:
    response = aws("dynamodb").get_item(
        TableName=config["table"], Key=key(config), ConsistentRead=True
    )
    return response.get("Item", {}).get("Status", {}).get("S", "MISSING")


def transition(config: dict[str, Any], before: str, after: str) -> bool:
    try:
        aws("dynamodb").update_item(
            TableName=config["table"],
            Key=key(config),
            UpdateExpression="SET #status = :after, UpdatedEpoch = :now",
            ConditionExpression="#status = :before",
            ExpressionAttributeNames={"#status": "Status"},
            ExpressionAttributeValues={
                ":before": {"S": before},
                ":after": {"S": after},
                ":now": {"N": str(int(time.time()))},
            },
        )
        print(f"Schedule state changed: {before} -> {after}.")
        return True
    except Exception as error:
        if conditional_failure(error):
            return False
        raise


def email_confirmed(config: dict[str, Any]) -> bool:
    token = None
    while True:
        request = {"TopicArn": config["email_topic"]}
        if token:
            request["NextToken"] = token
        response = aws("sns").list_subscriptions_by_topic(**request)
        for subscription in response.get("Subscriptions", []):
            if (
                subscription.get("Protocol") == "email"
                and subscription.get("Endpoint", "").casefold() == config["email"].casefold()
                and subscription.get("SubscriptionArn") not in {None, "", "PendingConfirmation"}
            ):
                return True
        token = response.get("NextToken")
        if not token:
            return False


def send_sms(config: dict[str, Any], body: str) -> None:
    aws("pinpoint-sms-voice-v2").send_text_message(
        DestinationPhoneNumber=config["phone"],
        OriginationIdentity=config["origination"],
        MessageBody=body,
        MessageType="TRANSACTIONAL",
    )


def send_email(config: dict[str, Any], subject: str, body: str) -> None:
    aws("sns").publish(TopicArn=config["email_topic"], Subject=subject[:100], Message=body)


def notice_text(config: dict[str, Any], label: str) -> str:
    if label == "CANCELLED":
        return "AWS-EnvBuilder SELF-DESTRUCT CANCELLED. No scheduled teardown will start. Verify with workspace schedule-status."
    return (
        f"AWS-EnvBuilder SELF-DESTRUCT {label}. {config['local_deadline']}. "
        "Reply CANCEL before execution to stop teardown. STOP opts out texts only; no/other reply deletes."
    )


def notify_both(config: dict[str, Any], label: str) -> None:
    body = notice_text(config, label)
    send_sms(config, body)
    send_email(
        config,
        f"AWS environment self-destruct {label}",
        body + f"\nUTC deadline: {config['deadline_utc']}\n\nDo not reply to this email. Cancellation is accepted only by replying CANCEL to the enrolled SMS number.",
    )


def claim_notice(config: dict[str, Any], minutes: int) -> bool:
    notice_name = f"M{minutes}"
    try:
        aws("dynamodb").update_item(
            TableName=config["table"],
            Key=key(config),
            UpdateExpression="SET Notices.#notice = :sending",
            ConditionExpression="#status = :active AND attribute_not_exists(Notices.#notice)",
            ExpressionAttributeNames={"#status": "Status", "#notice": notice_name},
            ExpressionAttributeValues={
                ":active": {"S": "ACTIVE"},
                ":sending": {"S": "SENDING"},
            },
        )
        return True
    except Exception as error:
        if conditional_failure(error):
            return False
        raise


def finish_notice(config: dict[str, Any], minutes: int, success: bool) -> None:
    notice_name = f"M{minutes}"
    if success:
        aws("dynamodb").update_item(
            TableName=config["table"],
            Key=key(config),
            UpdateExpression="SET Notices.#notice = :sent",
            ExpressionAttributeNames={"#notice": notice_name},
            ExpressionAttributeValues={":sent": {"S": "SENT"}},
        )
    else:
        aws("dynamodb").update_item(
            TableName=config["table"],
            Key=key(config),
            UpdateExpression="REMOVE Notices.#notice",
            ExpressionAttributeNames={"#notice": notice_name},
        )


def activate_if_ready(config: dict[str, Any]) -> str:
    status = get_status(config)
    if status != "PENDING" or not email_confirmed(config):
        return status
    # All five notices must be meaningful. If email confirmation arrives after
    # the 12-hour milestone, fail closed and leave the schedule unarmed.
    if config["deadline_epoch"] - int(time.time()) <= NOTICE_MINUTES[0] * 60:
        print("Schedule remains PENDING because email was confirmed too late for every required notice.")
        return status
    if transition(config, "PENDING", "ACTIVE"):
        notify_both(config, "ARMED")
        return "ACTIVE"
    return get_status(config)


def start_triggered_build(config: dict[str, Any]) -> None:
    """Start/recover the idempotent build only while state remains TRIGGERED."""
    if get_status(config) != "TRIGGERED":
        return
    try:
        response = aws("codebuild").start_build(
            projectName=config["build_project"],
            idempotencyToken=config["schedule_id"],
        )
    except BaseException:
        transition(config, "TRIGGERED", "ACTIVE")
        raise
    build_id = response.get("build", {}).get("id", "started")
    try:
        aws("dynamodb").update_item(
            TableName=config["table"],
            Key=key(config),
            UpdateExpression="SET BuildId = :build",
            ConditionExpression="#status = :triggered",
            ExpressionAttributeNames={"#status": "Status"},
            ExpressionAttributeValues={
                ":triggered": {"S": "TRIGGERED"},
                ":build": {"S": str(build_id)},
            },
        )
        print("Scheduled teardown build started.")
    except Exception as error:
        if not conditional_failure(error):
            raise
        print("A cancellation won after build start; the build status gate will stop Terraform apply.")


def process_clock(config: dict[str, Any], now_epoch: int) -> None:
    ensure_item(config)
    status = activate_if_ready(config)
    if status == "PENDING":
        print("Schedule remains PENDING until the operator confirms the SNS email subscription.")
        return
    if status in TERMINAL_STATES or status not in {"ACTIVE", "TRIGGERING", "TRIGGERED"}:
        print(f"No clock action for schedule state {status}.")
        return
    if status == "TRIGGERING":
        if transition(config, "TRIGGERING", "TRIGGERED"):
            status = "TRIGGERED"
        else:
            status = get_status(config)
    if status == "TRIGGERED":
        start_triggered_build(config)
        return
    if status != "ACTIVE":
        return

    remaining = config["deadline_epoch"] - now_epoch
    if remaining > 0:
        for minutes in NOTICE_MINUTES:
            if remaining <= minutes * 60 and claim_notice(config, minutes):
                sent = False
                try:
                    notify_both(config, f"in {minutes}m")
                    sent = True
                    print(f"Sent required {minutes}-minute notices.")
                finally:
                    finish_notice(config, minutes, sent)
        return

    if not transition(config, "ACTIVE", "TRIGGERING"):
        return
    if not transition(config, "TRIGGERING", "TRIGGERED"):
        return
    start_triggered_build(config)


def inbound_payload(event: dict[str, Any]) -> dict[str, Any] | None:
    records = event.get("Records")
    if not isinstance(records, list) or not records:
        return None
    message = records[0].get("Sns", {}).get("Message")
    if not isinstance(message, str):
        return None
    try:
        payload = json.loads(message)
    except json.JSONDecodeError:
        return None
    return payload if isinstance(payload, dict) else None


def cancel(config: dict[str, Any]) -> bool:
    try:
        aws("dynamodb").update_item(
            TableName=config["table"],
            Key=key(config),
            UpdateExpression="SET #status = :cancelled, CancelledEpoch = :now",
            ConditionExpression="#status IN (:pending, :active, :triggering, :triggered)",
            ExpressionAttributeNames={"#status": "Status"},
            ExpressionAttributeValues={
                ":pending": {"S": "PENDING"},
                ":active": {"S": "ACTIVE"},
                ":triggering": {"S": "TRIGGERING"},
                ":triggered": {"S": "TRIGGERED"},
                ":cancelled": {"S": "CANCELLED"},
                ":now": {"N": str(int(time.time()))},
            },
        )
        print("Authenticated SMS cancellation accepted.")
        return True
    except Exception as error:
        if conditional_failure(error):
            return False
        raise


def process_reply(config: dict[str, Any], payload: dict[str, Any]) -> None:
    """Accept only exact CANCEL from the enrolled phone to the enrolled AWS number."""
    correct_route = (
        payload.get("originationNumber") == config["phone"]
        and payload.get("destinationNumber") == config["origination"]
    )
    if not correct_route:
        print("Ignored SMS from an unenrolled route.")
        return
    if str(payload.get("messageBody", "")).strip().casefold() != "cancel":
        send_sms(
            config,
            "Self-destruct remains active. Reply with the single word CANCEL before execution begins.",
        )
        print("Enrolled sender replied with text other than exact CANCEL.")
        return
    ensure_item(config)
    if cancel(config):
        try:
            notify_both(config, "CANCELLED")
        except Exception:
            # The state transition is the authoritative cancellation. A failed
            # acknowledgement must never roll it back or report a false failure.
            print("Cancellation persisted, but at least one acknowledgement channel failed.")
    else:
        status = get_status(config)
        if status == "CANCELLED":
            send_sms(config, "Self-destruct is already CANCELLED. No scheduled teardown will start.")
        else:
            send_sms(config, "Cancellation was too late because Terraform execution already began.")


def lambda_handler(event: dict[str, Any], _context: Any) -> dict[str, str]:
    config = settings()
    payload = inbound_payload(event)
    if payload is not None:
        process_reply(config, payload)
    else:
        process_clock(config, int(time.time()))
    return {"status": "ok"}


if __name__ == "__main__":
    # Local execution is intentionally unavailable because this function needs
    # its narrowly scoped AWS role and generated environment.
    raise SystemExit("Invoke this module through AWS Lambda.")
