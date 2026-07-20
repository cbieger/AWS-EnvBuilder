"""Offline tests for schedule conversion, source hygiene, and cancellation gates."""

from __future__ import annotations

import importlib.util
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import tempfile
import unittest
from unittest import mock
import zipfile


REPOSITORY_ROOT = Path(__file__).resolve().parents[1]
CONTROLLER_PATH = REPOSITORY_ROOT / "scripts" / "scheduled_destroy_controller.py"


def load_controller():
    specification = importlib.util.spec_from_file_location(
        "scheduled_destroy_controller_under_test", CONTROLLER_PATH
    )
    module = importlib.util.module_from_spec(specification)
    assert specification.loader is not None
    specification.loader.exec_module(module)
    return module


class ConfiguratorTests(unittest.TestCase):
    def make_workspace(self, temporary_directory: str) -> Path:
        root = Path(temporary_directory) / "workspace"
        shutil.copytree(REPOSITORY_ROOT / "scripts", root / "scripts")
        terraform = root / "terraform"
        terraform.mkdir()
        shutil.copy2(REPOSITORY_ROOT / "terraform" / "variables.tf", terraform / "variables.tf")
        (terraform / "backend.hcl").write_text(
            'bucket = "test-state-bucket"\n'
            'key = "stub-app/dev/terraform.tfstate"\n'
            'region = "us-west-2"\n',
            encoding="utf-8",
        )
        return root

    def run_configurator(self, root: Path, *arguments: str) -> subprocess.CompletedProcess:
        return subprocess.run(
            [
                "python3",
                "scripts/configure_scheduled_destroy.py",
                "--repository-root",
                str(root),
                "--terraform-dir",
                str(root / "terraform"),
                "--region",
                "us-west-2",
                *arguments,
            ],
            cwd=root,
            check=False,
            capture_output=True,
            text=True,
        )

    def test_duration_is_converted_and_archives_exclude_contacts_and_backend(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = self.make_workspace(temporary_directory)
            result = self.run_configurator(
                root,
                "--enabled", "yes",
                "--duration-hours", "13",
                "--timezone", "UTC",
                "--now", "2026-07-19T00:00:00Z",
                "--phone", "+13125550123",
                "--email", "operator@example.com",
                "--origination-number", "+13125550999",
                "--inbound-topic-arn", "arn:aws:sns:us-west-2:123456789012:sms-replies",
            )
            config_path = root / "terraform" / "scheduled_destroy.auto.tfvars.json"
            config = json.loads(config_path.read_text(encoding="utf-8"))
            source_zip = root / ".workspace" / "scheduled-destroy" / "terraform-source.zip"
            with zipfile.ZipFile(source_zip) as archive:
                names = archive.namelist()
                contents = b"".join(archive.read(name) for name in names)

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(
            config["scheduled_destroy_configuration"]["deadline_utc"],
            "2026-07-19T13:00:00Z",
        )
        self.assertTrue(config["scheduled_destroy_enabled"])
        self.assertNotIn("backend.hcl", names)
        self.assertNotIn("scheduled_destroy.auto.tfvars.json", names)
        self.assertNotIn(b"operator@example.com", contents)
        self.assertNotIn(b"+13125550123", contents)
        self.assertIn("scheduled_destroy_build.py", names)

    def test_specific_local_time_converts_to_utc(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = self.make_workspace(temporary_directory)
            result = self.run_configurator(
                root,
                "--enabled", "yes",
                "--at", "2026-07-20 08:00",
                "--timezone", "America/Chicago",
                "--now", "2026-07-19T00:00:00Z",
                "--phone", "+13125550123",
                "--email", "operator@example.com",
                "--origination-number", "+13125550999",
                "--inbound-topic-arn", "arn:aws:sns:us-west-2:123456789012:sms-replies",
            )
            config = json.loads(
                (root / "terraform" / "scheduled_destroy.auto.tfvars.json").read_text(encoding="utf-8")
            )

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(
            config["scheduled_destroy_configuration"]["deadline_utc"],
            "2026-07-20T13:00:00Z",
        )
        self.assertEqual(
            config["scheduled_destroy_configuration"]["local_timezone"],
            "America/Chicago",
        )

    def test_schedule_shorter_than_thirteen_hours_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = self.make_workspace(temporary_directory)
            result = self.run_configurator(
                root,
                "--enabled", "yes",
                "--duration-hours", "12",
                "--timezone", "UTC",
                "--now", "2026-07-19T00:00:00Z",
                "--phone", "+13125550123",
                "--email", "operator@example.com",
                "--origination-number", "+13125550999",
                "--inbound-topic-arn", "arn:aws:sns:us-west-2:123456789012:sms-replies",
            )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("at least 13 hours", result.stdout + result.stderr)

    def test_operator_can_decline_without_creating_archives(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = self.make_workspace(temporary_directory)
            result = self.run_configurator(root, "--enabled", "no")
            config = json.loads(
                (root / "terraform" / "scheduled_destroy.auto.tfvars.json").read_text(encoding="utf-8")
            )

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(config, {"scheduled_destroy_enabled": False})


class ControllerTests(unittest.TestCase):
    def setUp(self):
        self.controller = load_controller()
        self.config = {
            "table": "schedule-table",
            "schedule_id": "0123456789abcdef",
            "deadline_epoch": 2_000_000,
            "deadline_utc": "2026-08-01T00:00:00Z",
            "local_deadline": "2026-07-31 19:00 CDT",
            "phone": "+13125550123",
            "email": "operator@example.com",
            "origination": "+13125550999",
            "email_topic": "arn:aws:sns:us-west-2:123456789012:email",
            "build_project": "destroy-project",
        }

    def payload(self, body="CANCEL", phone="+13125550123"):
        return {
            "originationNumber": phone,
            "destinationNumber": "+13125550999",
            "messageBody": body,
        }

    def test_only_exact_cancel_from_enrolled_route_cancels(self):
        with mock.patch.object(self.controller, "ensure_item"), mock.patch.object(
            self.controller, "cancel", return_value=True
        ) as cancel, mock.patch.object(self.controller, "notify_both") as notify:
            self.controller.process_reply(self.config, self.payload("  cancel  "))
        cancel.assert_called_once_with(self.config)
        notify.assert_called_once_with(self.config, "CANCELLED")

    def test_other_text_and_other_phone_do_not_cancel(self):
        with mock.patch.object(self.controller, "cancel") as cancel, mock.patch.object(
            self.controller, "send_sms"
        ) as send_sms:
            self.controller.process_reply(self.config, self.payload("cancel please"))
            self.controller.process_reply(self.config, self.payload("CANCEL", "+13125550000"))
        cancel.assert_not_called()
        send_sms.assert_called_once()

    def test_pending_email_confirmation_cannot_start_build(self):
        with mock.patch.object(self.controller, "ensure_item"), mock.patch.object(
            self.controller, "activate_if_ready", return_value="PENDING"
        ), mock.patch.object(self.controller, "aws") as aws:
            self.controller.process_clock(self.config, self.config["deadline_epoch"] + 1)
        aws.assert_not_called()

    def test_required_sms_notice_fits_one_basic_segment_for_normal_deadline(self):
        message = self.controller.notice_text(self.config, "in 720m")
        self.assertLessEqual(len(message), 160)
        self.assertIn("Reply CANCEL", message)

    def test_cancelled_state_cannot_start_build(self):
        with mock.patch.object(self.controller, "ensure_item"), mock.patch.object(
            self.controller, "activate_if_ready", return_value="CANCELLED"
        ), mock.patch.object(self.controller, "aws") as aws:
            self.controller.process_clock(self.config, self.config["deadline_epoch"] + 1)
        aws.assert_not_called()

    def test_active_deadline_starts_build_after_atomic_transition(self):
        with mock.patch.object(self.controller, "ensure_item"), mock.patch.object(
            self.controller, "activate_if_ready", return_value="ACTIVE"
        ), mock.patch.object(
            self.controller, "transition", return_value=True
        ) as transition, mock.patch.object(
            self.controller, "start_triggered_build"
        ) as start_build:
            self.controller.process_clock(self.config, self.config["deadline_epoch"])

        self.assertEqual(
            transition.call_args_list,
            [
                mock.call(self.config, "ACTIVE", "TRIGGERING"),
                mock.call(self.config, "TRIGGERING", "TRIGGERED"),
            ],
        )
        start_build.assert_called_once_with(self.config)

    def test_triggered_build_rechecks_state_before_codebuild(self):
        with mock.patch.object(
            self.controller, "get_status", return_value="CANCELLED"
        ), mock.patch.object(self.controller, "aws") as aws:
            self.controller.start_triggered_build(self.config)
        aws.assert_not_called()


class ChannelValidationTests(unittest.TestCase):
    def run_validation(self, number_type: str) -> subprocess.CompletedProcess:
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name) / "workspace"
        shutil.copytree(REPOSITORY_ROOT / "scripts", root / "scripts")
        terraform = root / "terraform"
        terraform.mkdir()
        (terraform / "scheduled_destroy.auto.tfvars.json").write_text(
            json.dumps({
                "scheduled_destroy_enabled": True,
                "scheduled_destroy_configuration": {
                    "sms_inbound_topic_arn": "arn:aws:sns:us-west-2:123456789012:sms-replies",
                    "sms_origination_number": "+18005550199",
                },
                "scheduled_destroy_contacts": {"operator_phone": "+13125550123"},
            }),
            encoding="utf-8",
        )
        fake_bin = Path(temporary.name) / "bin"
        fake_bin.mkdir()
        fake_aws = fake_bin / "aws"
        fake_aws.write_text(
            """#!/usr/bin/env python3
import json
import os
import sys

args = sys.argv[1:]
if "sts" in args:
    print(json.dumps({"Account": "123456789012", "Arn": "arn:aws:iam::123456789012:user/test"}))
elif "sns" in args:
    print(json.dumps({"Attributes": {}}))
elif "describe-phone-numbers" in args:
    print(json.dumps({"PhoneNumbers": [{
        "PhoneNumber": "+18005550199",
        "Status": "ACTIVE",
        "IsoCountryCode": "US",
        "NumberType": os.environ["MOCK_NUMBER_TYPE"],
        "NumberCapabilities": ["SMS"],
        "TwoWayEnabled": True,
        "TwoWayChannelArn": "arn:aws:sns:us-west-2:123456789012:sms-replies",
        "SelfManagedOptOutsEnabled": False
    }]}))
elif "send-text-message" in args:
    print(json.dumps({"MessageId": "dry-run"}))
else:
    raise SystemExit(90)
""",
            encoding="utf-8",
        )
        fake_aws.chmod(fake_aws.stat().st_mode | stat.S_IXUSR)
        return subprocess.run(
            [
                "bash",
                "scripts/validate_scheduled_destroy_channels.sh",
                "--profile",
                "test",
                "--region",
                "us-west-2",
            ],
            cwd=root,
            env={
                **os.environ,
                "PATH": f"{fake_bin}{os.pathsep}{os.environ['PATH']}",
                "MOCK_NUMBER_TYPE": number_type,
            },
            check=False,
            capture_output=True,
            text=True,
        )

    def test_account_owned_us_toll_free_two_way_number_passes(self):
        result = self.run_validation("TOLL_FREE")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_long_code_is_rejected_because_cancel_can_be_consumed_as_opt_out(self):
        result = self.run_validation("LONG_CODE")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("US TOLL_FREE", result.stdout + result.stderr)


class BuildSafetyTests(unittest.TestCase):
    def run_plan_check(self, actions: list[str]) -> subprocess.CompletedProcess:
        with tempfile.TemporaryDirectory() as temporary_directory:
            plan = Path(temporary_directory) / "plan.json"
            plan.write_text(
                json.dumps({
                    "resource_changes": [
                        {"address": "aws_vpc.workspace", "change": {"actions": actions}}
                    ]
                }),
                encoding="utf-8",
            )
            return subprocess.run(
                ["python3", str(REPOSITORY_ROOT / "scripts" / "scheduled_destroy_build.py"), "validate-plan", str(plan)],
                check=False,
                capture_output=True,
                text=True,
            )

    def test_deletion_only_plan_is_accepted(self):
        self.assertEqual(self.run_plan_check(["delete"]).returncode, 0)

    def test_create_or_update_plan_is_rejected(self):
        result = self.run_plan_check(["delete", "create"])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Unsafe scheduled plan action", result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
