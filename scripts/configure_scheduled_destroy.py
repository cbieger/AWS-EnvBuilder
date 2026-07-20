#!/usr/bin/env python3
"""Collect, validate, and locally package an optional scheduled teardown.

This helper does not contact AWS. It writes one ignored Terraform variable file
and two ignored, deterministic source archives. The archives contain reviewed
source only; phone numbers, email addresses, backend settings, state, plans,
credentials, and logs are never placed inside either archive.
"""

from __future__ import annotations

import argparse
import base64
from datetime import datetime, timedelta, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import uuid
import zipfile
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError


MINIMUM_LEAD_TIME = timedelta(hours=13)
MINIMUM_REMAINING_AT_PLAN = timedelta(hours=12, minutes=15)
E164 = re.compile(r"^\+[1-9][0-9]{7,14}$")
EMAIL = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")
TOPIC_ARN = re.compile(r"^arn:[^:]+:sns:([a-z0-9-]+):([0-9]{12}):[^:]+$")


def arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Configure the optional, cancellable scheduled self-destruct."
    )
    parser.add_argument("--terraform-dir", required=True)
    parser.add_argument("--repository-root", required=True)
    parser.add_argument("--region", required=True)
    parser.add_argument("--ensure", action="store_true", help="Reuse existing answers and rebuild source archives.")
    parser.add_argument("--enabled", choices=("yes", "no"), help=argparse.SUPPRESS)
    parser.add_argument("--duration-hours", type=int, help=argparse.SUPPRESS)
    parser.add_argument("--duration-minutes", type=int, help=argparse.SUPPRESS)
    parser.add_argument("--at", help=argparse.SUPPRESS)
    parser.add_argument("--timezone", help=argparse.SUPPRESS)
    parser.add_argument("--phone", help=argparse.SUPPRESS)
    parser.add_argument("--email", help=argparse.SUPPRESS)
    parser.add_argument("--origination-number", help=argparse.SUPPRESS)
    parser.add_argument("--inbound-topic-arn", help=argparse.SUPPRESS)
    parser.add_argument("--now", help=argparse.SUPPRESS)
    return parser.parse_args()


def prompt(question: str) -> str:
    """Read one answer from the controlling terminal without accepting EOF."""
    try:
        return input(question).strip()
    except EOFError as error:
        raise SystemExit("An interactive terminal is required for first-time schedule setup.") from error


def prompt_yes_no(question: str) -> bool:
    while True:
        answer = prompt(f"{question} [y/n]: ").lower()
        if answer in {"y", "yes"}:
            return True
        if answer in {"n", "no"}:
            return False
        print("Please enter y or n.")


def detect_timezone(explicit: str | None) -> str:
    """Return an IANA timezone name; fixed abbreviations are intentionally rejected."""
    candidates = [explicit, os.environ.get("TZ")]
    localtime = Path("/etc/localtime")
    try:
        target = localtime.resolve()
        marker = "/zoneinfo/"
        if marker in str(target):
            candidates.append(str(target).split(marker, 1)[1])
    except OSError:
        pass
    try:
        completed = subprocess.run(
            ["timedatectl", "show", "--property=Timezone", "--value"],
            check=False,
            capture_output=True,
            text=True,
            timeout=3,
        )
        if completed.returncode == 0:
            candidates.append(completed.stdout.strip())
    except (FileNotFoundError, subprocess.TimeoutExpired):
        pass

    for candidate in candidates:
        if not candidate:
            continue
        try:
            ZoneInfo(candidate)
            return candidate
        except ZoneInfoNotFoundError:
            continue
    raise SystemExit(
        "Could not determine an IANA local timezone. Retry with --timezone, for example America/Chicago."
    )


def parse_now(value: str | None) -> datetime:
    if not value:
        return datetime.now(timezone.utc)
    parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    if parsed.tzinfo is None:
        raise SystemExit("--now must contain a UTC offset.")
    return parsed.astimezone(timezone.utc)


def local_deadline(value: str, timezone_name: str) -> datetime:
    """Convert an unambiguous, existent local wall time to UTC."""
    try:
        naive = datetime.strptime(value, "%Y-%m-%d %H:%M")
    except ValueError as error:
        raise SystemExit("Local time must use YYYY-MM-DD HH:MM, for example 2026-08-01 17:30.") from error
    zone = ZoneInfo(timezone_name)
    first = naive.replace(tzinfo=zone, fold=0)
    second = naive.replace(tzinfo=zone, fold=1)
    first_utc = first.astimezone(timezone.utc)
    second_utc = second.astimezone(timezone.utc)
    if first.utcoffset() != second.utcoffset():
        raise SystemExit(
            "That local time is ambiguous during a daylight-saving clock change. Choose another minute."
        )
    if first_utc.astimezone(zone).replace(tzinfo=None) != naive:
        raise SystemExit(
            "That local time does not exist during a daylight-saving clock change. Choose another minute."
        )
    return first_utc


def parse_backend(path: Path) -> dict[str, str]:
    if not path.is_file():
        raise SystemExit(f"Missing {path}. Bootstrap the Terraform backend first.")
    values: dict[str, str] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        match = re.match(r'^\s*(bucket|key|region)\s*=\s*"([^"]+)"\s*$', line)
        if match:
            values[match.group(1)] = match.group(2)
    missing = {"bucket", "key", "region"} - values.keys()
    if missing:
        raise SystemExit(f"backend.hcl is missing: {', '.join(sorted(missing))}.")
    return values


def validate_contact(phone: str, email: str, origination: str, topic: str, region: str) -> None:
    if not E164.fullmatch(phone):
        raise SystemExit("Cell phone must use E.164 format, for example +13125550123.")
    if not EMAIL.fullmatch(email):
        raise SystemExit("Email address is not valid.")
    if not E164.fullmatch(origination):
        raise SystemExit("AWS SMS origination number must use E.164 format.")
    if phone == origination:
        raise SystemExit("Operator cell and AWS origination number must be different.")
    topic_match = TOPIC_ARN.fullmatch(topic)
    if not topic_match:
        raise SystemExit("Inbound SNS topic must be a complete SNS topic ARN.")
    if topic_match.group(1) != region:
        raise SystemExit(f"Inbound SNS topic must be in selected Region {region}.")


def archive_file(archive: zipfile.ZipFile, source: Path, name: str, executable: bool = False) -> None:
    data = source.read_bytes()
    information = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
    information.compress_type = zipfile.ZIP_DEFLATED
    information.external_attr = ((0o755 if executable else 0o644) & 0xFFFF) << 16
    archive.writestr(information, data)


def sha256(path: Path) -> tuple[str, str]:
    digest = hashlib.sha256(path.read_bytes()).digest()
    return digest.hex(), base64.b64encode(digest).decode("ascii")


def runner_actions(repository_root: Path) -> list[str]:
    completed = subprocess.run(
        [str(repository_root / "scripts" / "permissions.sh"), "--print-required-actions"],
        check=True,
        capture_output=True,
        text=True,
    )
    value = json.loads(completed.stdout)
    if not isinstance(value, list) or not all(isinstance(item, str) for item in value):
        raise SystemExit("permissions.sh returned an invalid scheduled-runner action list.")
    return sorted(set(value))


def build_archives(repository_root: Path, terraform_dir: Path, output_dir: Path) -> dict[str, str]:
    output_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
    terraform_zip = output_dir / "terraform-source.zip"
    controller_zip = output_dir / "controller-source.zip"

    terraform_sources = sorted(
        path for path in terraform_dir.iterdir()
        if path.is_file() and (path.suffix in {".tf", ".tftpl"} or path.name == ".terraform.lock.hcl")
    )
    if not terraform_sources:
        raise SystemExit("No Terraform source files were found to package.")
    with zipfile.ZipFile(terraform_zip, "w") as archive:
        for source in terraform_sources:
            archive_file(archive, source, source.name)
        archive_file(
            archive,
            repository_root / "scripts" / "scheduled_destroy_build.py",
            "scheduled_destroy_build.py",
            executable=True,
        )
    with zipfile.ZipFile(controller_zip, "w") as archive:
        archive_file(
            archive,
            repository_root / "scripts" / "scheduled_destroy_controller.py",
            "lambda_function.py",
        )

    terraform_hex, terraform_base64 = sha256(terraform_zip)
    controller_hex, controller_base64 = sha256(controller_zip)
    return {
        "terraform_zip": str(terraform_zip),
        "controller_zip": str(controller_zip),
        "terraform_sha256": terraform_hex,
        "terraform_sha256_base64": terraform_base64,
        "controller_sha256": controller_hex,
        "controller_sha256_base64": controller_base64,
    }


def atomic_json(path: Path, value: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.temporary-{os.getpid()}")
    temporary.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    os.chmod(temporary, 0o600)
    os.replace(temporary, path)


def main() -> int:
    options = arguments()
    repository_root = Path(options.repository_root).resolve()
    terraform_dir = Path(options.terraform_dir).resolve()
    config_path = terraform_dir / "scheduled_destroy.auto.tfvars.json"
    output_dir = repository_root / ".workspace" / "scheduled-destroy"
    backend = parse_backend(terraform_dir / "backend.hcl")

    existing = None
    if config_path.is_file():
        existing = json.loads(config_path.read_text(encoding="utf-8"))
    if options.ensure and existing is not None:
        enabled = bool(existing.get("scheduled_destroy_enabled"))
    elif options.enabled:
        enabled = options.enabled == "yes"
    else:
        print("\nOPTIONAL SCHEDULED SELF-DESTRUCT")
        print("This creates a billable AWS control plane and automatically deletes runtime resources.")
        enabled = prompt_yes_no("Would you like to schedule this environment to self-destruct?")

    if not enabled:
        atomic_json(config_path, {"scheduled_destroy_enabled": False})
        print("Scheduled self-destruct is disabled. No scheduling resources will be proposed.")
        return 0

    if options.ensure and existing:
        configuration = existing["scheduled_destroy_configuration"]
        contacts = existing["scheduled_destroy_contacts"]
        remaining = datetime.fromtimestamp(
            int(configuration["deadline_epoch"]), timezone.utc
        ) - parse_now(options.now)
        if remaining < MINIMUM_REMAINING_AT_PLAN:
            raise SystemExit(
                "The saved deadline is now too close to apply and deliver every notice. "
                "Remove terraform/scheduled_destroy.auto.tfvars.json, then run plan again to choose a new deadline."
            )
    else:
        timezone_name = detect_timezone(options.timezone)
        now = parse_now(options.now)
        if options.at:
            deadline = local_deadline(options.at, timezone_name)
        elif options.duration_hours is not None or options.duration_minutes is not None:
            hours = options.duration_hours or 0
            minutes = options.duration_minutes or 0
            if hours < 0 or minutes < 0 or hours + minutes == 0:
                raise SystemExit("Duration must be a positive number of hours/minutes.")
            deadline = now + timedelta(hours=hours, minutes=minutes)
        else:
            print(f"Detected local timezone: {timezone_name}")
            print("Choose 1 for a duration, or 2 for a specific local date/time.")
            choice = prompt("Choice [1/2]: ")
            if choice == "1":
                try:
                    hours = int(prompt("Hours from now (0 or more): "))
                    minutes = int(prompt("Additional minutes (0-59): "))
                except ValueError as error:
                    raise SystemExit("Hours and minutes must be whole numbers.") from error
                if hours < 0 or minutes < 0 or minutes > 59 or hours + minutes == 0:
                    raise SystemExit("Enter a positive duration; minutes must be 0-59.")
                deadline = now + timedelta(hours=hours, minutes=minutes)
            elif choice == "2":
                deadline = local_deadline(
                    prompt("Local self-destruct time (YYYY-MM-DD HH:MM): "), timezone_name
                )
            else:
                raise SystemExit("Choice must be 1 or 2.")

        if deadline - now < MINIMUM_LEAD_TIME:
            raise SystemExit(
                "Self-destruct must be at least 13 hours away so every required warning can be sent."
            )
        local_value = deadline.astimezone(ZoneInfo(timezone_name))
        print(f"Local deadline: {local_value.strftime('%Y-%m-%d %H:%M %Z')}")
        print(f"AWS/UTC deadline: {deadline.strftime('%Y-%m-%dT%H:%M:%SZ')}")
        if not options.enabled and not prompt_yes_no("Is this deadline correct?"):
            raise SystemExit("Deadline was not approved. Run the command again to choose another time.")

        phone = options.phone or prompt("Operator cell phone in E.164 format (example +13125550123): ")
        email = options.email or prompt("Operator email address: ")
        print("A pre-existing account-owned US toll-free AWS two-way SMS number is required.")
        origination = options.origination_number or prompt("AWS US toll-free two-way SMS number (E.164): ")
        topic = options.inbound_topic_arn or prompt("SNS topic ARN receiving replies to that AWS number: ")
        validate_contact(phone, email, origination, topic, options.region)
        if not options.enabled and not prompt_yes_no(
            "Do you control the operator cell and consent to these transactional teardown alerts? "
            "(STOP opts out of texts but does not cancel teardown)"
        ):
            raise SystemExit("SMS consent was not granted. Scheduled self-destruct was not configured.")
        schedule_id = uuid.uuid4().hex[:16]
        configuration = {
            "schedule_id": schedule_id,
            "deadline_utc": deadline.strftime("%Y-%m-%dT%H:%M:%SZ"),
            "deadline_epoch": int(deadline.timestamp()),
            "local_deadline": local_value.strftime("%Y-%m-%d %H:%M %Z"),
            "local_timezone": timezone_name,
            "sms_origination_number": origination,
            "sms_inbound_topic_arn": topic,
            "source_bucket": backend["bucket"],
            "backend_key": backend["key"],
            "backend_region": backend["region"],
        }
        contacts = {"operator_phone": phone, "operator_email": email}

    artifacts = build_archives(repository_root, terraform_dir, output_dir)
    prefix = f"scheduled-destroy/{configuration['schedule_id']}"
    configuration.update(
        {
            "terraform_source_key": f"{prefix}/{artifacts['terraform_sha256']}.terraform.zip",
            "terraform_source_sha256": artifacts["terraform_sha256"],
            "controller_source_key": f"{prefix}/{artifacts['controller_sha256']}.controller.zip",
            "controller_source_sha256": artifacts["controller_sha256"],
            "controller_source_hash_base64": artifacts["controller_sha256_base64"],
            "runner_actions": runner_actions(repository_root),
        }
    )
    value = {
        "scheduled_destroy_enabled": True,
        "scheduled_destroy_configuration": configuration,
        "scheduled_destroy_contacts": contacts,
    }
    atomic_json(config_path, value)
    print("Scheduled self-destruct configuration is ready for Terraform planning.")
    print("The ignored local configuration contains contact information; do not commit or share it.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
