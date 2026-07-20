#!/usr/bin/env python3
"""Small, auditable safety helper used by the scheduled CodeBuild job."""

from __future__ import annotations

import argparse
import json
from pathlib import Path


def client(name: str):
    import boto3

    return boto3.client(name)


def status(table: str, schedule_id: str) -> str:
    response = client("dynamodb").get_item(
        TableName=table,
        Key={"ScheduleId": {"S": schedule_id}},
        ConsistentRead=True,
    )
    return response.get("Item", {}).get("Status", {}).get("S", "MISSING")


def main() -> int:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)
    verify = subparsers.add_parser("verify-account")
    verify.add_argument("--expected", required=True)
    check = subparsers.add_parser("check-status")
    check.add_argument("--table", required=True)
    check.add_argument("--schedule-id", required=True)
    check.add_argument("--expected", required=True)
    backend = subparsers.add_parser("write-backend")
    backend.add_argument("--bucket", required=True)
    backend.add_argument("--key", required=True)
    backend.add_argument("--region", required=True)
    backend.add_argument("--output", required=True)
    plan = subparsers.add_parser("validate-plan")
    plan.add_argument("path")
    claim = subparsers.add_parser("claim-execution")
    claim.add_argument("--table", required=True)
    claim.add_argument("--schedule-id", required=True)
    options = parser.parse_args()

    if options.command == "verify-account":
        actual = client("sts").get_caller_identity()["Account"]
        if actual != options.expected:
            raise SystemExit(f"Account mismatch: expected {options.expected}; got {actual}.")
    elif options.command == "check-status":
        actual = status(options.table, options.schedule_id)
        if actual != options.expected:
            raise SystemExit(f"Schedule status is {actual}, not {options.expected}; teardown stopped.")
    elif options.command == "write-backend":
        values = (options.bucket, options.key, options.region)
        if any('"' in value or "\n" in value for value in values):
            raise SystemExit("Unsafe backend value.")
        Path(options.output).write_text(
            f'bucket = "{options.bucket}"\nkey = "{options.key}"\n'
            f'region = "{options.region}"\nencrypt = true\nuse_lockfile = true\n',
            encoding="utf-8",
        )
    elif options.command == "validate-plan":
        document = json.loads(Path(options.path).read_text(encoding="utf-8"))
        changes = document.get("resource_changes", [])
        destructive = 0
        for change in changes:
            actions = change.get("change", {}).get("actions", [])
            if any(action in {"create", "update"} for action in actions):
                raise SystemExit(f"Unsafe scheduled plan action at {change.get('address')}: {actions}")
            if "delete" in actions:
                destructive += 1
        if destructive == 0:
            raise SystemExit("Scheduled plan contains no deletions; refusing an unexpected empty teardown.")
    elif options.command == "claim-execution":
        try:
            client("dynamodb").update_item(
                TableName=options.table,
                Key={"ScheduleId": {"S": options.schedule_id}},
                UpdateExpression="SET #status = :executing",
                ConditionExpression="#status = :triggered",
                ExpressionAttributeNames={"#status": "Status"},
                ExpressionAttributeValues={
                    ":triggered": {"S": "TRIGGERED"},
                    ":executing": {"S": "EXECUTING"},
                },
            )
        except Exception as error:
            response = getattr(error, "response", {})
            if response.get("Error", {}).get("Code") == "ConditionalCheckFailedException":
                raise SystemExit("Cancellation or another state change won the execution race; teardown stopped.")
            raise
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
