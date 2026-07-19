"""Offline end-to-end tests for account inventory and self-destruct gating."""

from __future__ import annotations

import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import tempfile
import unittest


REPOSITORY_ROOT = Path(__file__).resolve().parents[1]


FAKE_AWS = r'''#!/usr/bin/env python3
import json
import os
from pathlib import Path
import sys

arguments = sys.argv[1:]
events_path = Path(os.environ["MOCK_EVENTS"])
with events_path.open("a", encoding="utf-8") as events:
    events.write("aws " + " ".join(arguments) + "\n")

if arguments == ["--version"]:
    print("aws-cli/2.36.2 Python/3.14.6 Darwin/25.5.0 exe/x86_64")
    raise SystemExit(0)

services = {
    "sts", "resourcegroupstaggingapi", "ec2", "autoscaling", "elbv2",
    "ecr", "logs", "s3api", "iam", "budgets",
}
service_index = next((index for index, value in enumerate(arguments) if value in services), None)
if service_index is None or service_index + 1 >= len(arguments):
    print("unknown fake AWS command", file=sys.stderr)
    raise SystemExit(90)
service = arguments[service_index]
operation = arguments[service_index + 1]
command = f"{service} {operation}"

if command == "sts get-caller-identity":
    profile = arguments[arguments.index("--profile") + 1] if "--profile" in arguments else ""
    if profile == "aws-envbuilder-automation":
        arn = "arn:aws:iam::123456789012:user/aws-envbuilder-automation"
        user_id = "AIDASERVICE"
    else:
        arn = "arn:aws:iam::123456789012:user/cleanup-admin"
        user_id = "AIDACLEANUP"
    print(json.dumps({
        "Account": "123456789012",
        "Arn": arn,
        "UserId": user_id,
    }))
elif command == "resourcegroupstaggingapi get-resources":
    if os.environ.get("MOCK_OWNED_RESOURCE", "present") == "present" and "--tag-filters" in arguments:
        resources = [{
            "ResourceARN": "arn:aws:ec2:us-west-2:123456789012:vpc/vpc-owned",
            "Tags": [
                {"Key": "Application", "Value": "stub-app"},
                {"Key": "Environment", "Value": "dev"},
            ],
        }]
    else:
        resources = []
    print(json.dumps({"ResourceTagMappingList": resources, "PaginationToken": ""}))
elif command == "iam simulate-principal-policy":
    start = arguments.index("--action-names") + 1
    end = arguments.index("--output", start)
    actions = arguments[start:end]
    deny_cleanup = os.environ.get("MOCK_DENY_IDENTITY_CLEANUP") == "true"
    print(json.dumps({
        "EvaluationResults": [
            {
                "EvalActionName": action,
                "EvalDecision": (
                    "implicitDeny"
                    if deny_cleanup and action == "iam:DeleteUser"
                    else "allowed"
                ),
            }
            for action in actions
        ]
    }))
elif command == "s3api list-buckets" and "--output" in arguments and arguments[arguments.index("--output") + 1] == "text":
    print("1")
elif command == "s3api list-buckets":
    print(json.dumps({"Buckets": [{"Name": "stub-app-dev-123456789012-us-west-2-tfstate"}]}))
elif command == "s3api get-bucket-tagging":
    print(json.dumps({"TagSet": [
        {"Key": "Application", "Value": "stub-app"},
        {"Key": "Environment", "Value": "dev"},
        {"Key": "ManagedBy", "Value": "bootstrap-backend"},
        {"Key": "Purpose", "Value": "terraform-state"},
    ]}))
elif command == "s3api get-bucket-versioning":
    print(json.dumps({"Status": "Enabled"}))
elif command == "s3api get-object-lock-configuration":
    print("An error occurred (ObjectLockConfigurationNotFoundError)", file=sys.stderr)
    raise SystemExit(254)
elif command == "s3api list-object-versions":
    counter_path = Path(os.environ["MOCK_S3_COUNTER"])
    deleting = "--no-paginate" in arguments
    already_listed = counter_path.exists()
    if deleting and not already_listed:
        counter_path.write_text("listed\n", encoding="utf-8")
    if not deleting or not already_listed:
        response = {
            "Versions": [{"Key": "stub-app/dev/terraform.tfstate", "VersionId": "version-1"}],
            "DeleteMarkers": [],
            "IsTruncated": False,
        }
    else:
        response = {"Versions": [], "DeleteMarkers": [], "IsTruncated": False}
    print(json.dumps(response))
elif command == "s3api delete-objects":
    print(json.dumps({"Deleted": [{"Key": "stub-app/dev/terraform.tfstate"}], "Errors": []}))
elif command == "ec2 describe-instances":
    print(json.dumps({"Reservations": [{"Instances": [{
        "InstanceId": "i-owned",
        "InstanceType": "t3.micro",
        "State": {"Name": "running"},
        "Tags": [{"Key": "Application", "Value": "stub-app"}],
    }]}]}))
elif command == "ec2 describe-vpcs":
    print(json.dumps({"Vpcs": [{"VpcId": "vpc-owned", "IsDefault": False, "State": "available"}]}))
elif command == "budgets describe-budgets":
    print(json.dumps({"Budgets": []}))
elif command == "iam list-users":
    print(json.dumps({"Users": [{"UserName": "cleanup-admin", "Arn": "arn:aws:iam::123456789012:user/cleanup-admin"}]}))
elif command == "iam list-roles":
    print(json.dumps({"Roles": []}))
elif command == "iam list-instance-profiles":
    print(json.dumps({"InstanceProfiles": []}))
elif command == "iam get-user":
    print(json.dumps({"User": {
        "UserName": "aws-envbuilder-automation",
        "Arn": "arn:aws:iam::123456789012:user/aws-envbuilder-automation",
        "Tags": [
            {"Key": "ManagedBy", "Value": "AWS-EnvBuilder"},
            {"Key": "Purpose", "Value": "terraform-service-account"},
        ],
    }}))
elif command == "iam list-access-keys":
    print(json.dumps({"AccessKeyMetadata": [{
        "AccessKeyId": "AKIA" + "0" * 16,
        "Status": "Active",
        "CreateDate": "2026-07-19T00:00:00Z",
    }]}))
elif command == "iam list-user-policies":
    print(json.dumps({"PolicyNames": ["AWS-EnvBuilder-ServiceAccount"]}))
elif command == "iam list-attached-user-policies":
    print(json.dumps({"AttachedPolicies": []}))
elif command == "iam list-groups-for-user":
    print(json.dumps({"Groups": []}))
elif command == "iam list-mfa-devices":
    print(json.dumps({"MFADevices": []}))
elif command == "iam list-signing-certificates":
    print(json.dumps({"Certificates": []}))
elif command == "iam list-ssh-public-keys":
    print(json.dumps({"SSHPublicKeys": []}))
elif command == "iam list-service-specific-credentials":
    print(json.dumps({"ServiceSpecificCredentials": []}))
elif command == "iam get-login-profile":
    print("An error occurred (NoSuchEntity)", file=sys.stderr)
    raise SystemExit(254)
elif command in {"s3api delete-bucket"}:
    print("{}")
else:
    # Empty JSON is a valid zero-asset response for every other read family and
    # a successful response for the fake deletion calls used in execute tests.
    print("{}")
'''


FAKE_TERRAFORM = r'''#!/usr/bin/env python3
import json
import os
from pathlib import Path
import sys

arguments = sys.argv[1:]
with Path(os.environ["MOCK_EVENTS"]).open("a", encoding="utf-8") as events:
    events.write("terraform " + " ".join(arguments) + "\n")

filtered = [argument for argument in arguments if not argument.startswith("-chdir=")]
command = filtered[0] if filtered else ""
state_path = Path(os.environ["MOCK_TERRAFORM_STATE"])

if command == "version":
    print(json.dumps({"terraform_version": "1.11.4"}))
elif command == "init":
    print("Terraform has been successfully initialized!")
elif command == "state" and len(filtered) > 1 and filtered[1] == "list":
    if not state_path.exists():
        print("aws_vpc.workspace")
        print("aws_instance.application")
elif command == "plan":
    output = next(argument.split("=", 1)[1] for argument in filtered if argument.startswith("-out="))
    Path(output).write_text("fake plan\n", encoding="utf-8")
    print("Plan: 0 to add, 0 to change, 2 to destroy.")
elif command == "show" and "-json" in filtered and len(filtered) > 2:
    action = os.environ.get("MOCK_PLAN_ACTION", "delete")
    print(json.dumps({"resource_changes": [
        {"address": "aws_vpc.workspace", "change": {"actions": [action]}},
        {"address": "aws_instance.application", "change": {"actions": ["delete"]}},
    ]}))
elif command == "show" and "-json" in filtered:
    resources = []
    if os.environ.get("MOCK_REMAINING_MANAGED") == "true":
        resources.append({"address": "aws_vpc.workspace", "mode": "managed"})
    # A data source may remain after destroy and must not look like unfinished
    # managed infrastructure to the safety check.
    resources.append({"address": "data.aws_partition.current", "mode": "data"})
    print(json.dumps({"values": {"root_module": {"resources": resources}}}))
elif command == "show":
    print("Plan: aws_vpc.workspace and aws_instance.application will be destroyed")
elif command == "apply":
    state_path.write_text("destroyed\n", encoding="utf-8")
    os.environ["MOCK_OWNED_RESOURCE"] = "absent"
    print("Apply complete! Resources: 2 destroyed.")
else:
    print(f"unsupported fake Terraform command: {filtered}", file=sys.stderr)
    raise SystemExit(91)
'''


class MockWorkspace:
    """Copy the repository and install deterministic fake AWS/Terraform tools."""

    def __init__(self, temporary_directory: str) -> None:
        self.root = Path(temporary_directory) / "workspace"
        shutil.copytree(
            REPOSITORY_ROOT,
            self.root,
            ignore=shutil.ignore_patterns(".git", ".terraform", "dist", "logs", "sources", "bangr_handoff_*", "AGENTS.md"),
        )
        for retention_class in ("active", "errors", "success", "inventory"):
            (self.root / "logs" / retention_class).mkdir(parents=True, exist_ok=True)

        backend = self.root / "terraform" / "backend.hcl"
        backend.write_text(
            'bucket       = "stub-app-dev-123456789012-us-west-2-tfstate"\n'
            'key          = "stub-app/dev/terraform.tfstate"\n'
            'region       = "us-west-2"\n'
            'encrypt      = true\n'
            'use_lockfile = true\n',
            encoding="utf-8",
        )

        workspace_directory = self.root / ".workspace"
        workspace_directory.mkdir()
        (workspace_directory / "service-account-profile").write_text(
            "aws-envbuilder-automation\n", encoding="utf-8"
        )

        self.credentials = Path(temporary_directory) / "credentials"
        self.config = Path(temporary_directory) / "config"
        self.credentials.write_text(
            "[cleanup-admin]\naws_access_key_id = cleanup\n"
            "[aws-envbuilder-automation]\naws_access_key_id = service\n",
            encoding="utf-8",
        )
        self.config.write_text(
            "[profile cleanup-admin]\nregion = us-west-2\n"
            "[profile aws-envbuilder-automation]\nregion = us-west-2\n",
            encoding="utf-8",
        )

        self.fake_bin = Path(temporary_directory) / "bin"
        self.fake_bin.mkdir()
        self._write_executable("aws", FAKE_AWS)
        self._write_executable("terraform", FAKE_TERRAFORM)
        self._write_executable("curl", "#!/usr/bin/env bash\nprintf '%s\\n' '2.36.2'\n")

        self.events = Path(temporary_directory) / "events.txt"
        self.environment = {
            **os.environ,
            "PATH": f"{self.fake_bin}{os.pathsep}{os.environ['PATH']}",
            "MOCK_EVENTS": str(self.events),
            "MOCK_S3_COUNTER": str(Path(temporary_directory) / "s3-counter"),
            "MOCK_TERRAFORM_STATE": str(Path(temporary_directory) / "terraform-destroyed"),
            "AWS_SHARED_CREDENTIALS_FILE": str(self.credentials),
            "AWS_CONFIG_FILE": str(self.config),
        }

    def _write_executable(self, name: str, content: str) -> None:
        destination = self.fake_bin / name
        destination.write_text(content, encoding="utf-8")
        destination.chmod(destination.stat().st_mode | stat.S_IXUSR)

    def run_self_destruct(self, *extra_arguments: str, confirmation: str | None = None):
        environment = dict(self.environment)
        if confirmation is not None:
            environment["WORKSPACE_EXACT_CONFIRMATION"] = confirmation
        return subprocess.run(
            [
                "bash",
                "scripts/self_destruct.sh",
                "--profile",
                "cleanup-admin",
                "--region",
                "us-west-2",
                "--project",
                "stub-app",
                "--environment",
                "dev",
                *extra_arguments,
            ],
            cwd=self.root,
            env=environment,
            check=False,
            capture_output=True,
            text=True,
        )


class AccountInventoryTests(unittest.TestCase):
    def test_inventory_lists_assets_and_persists_protected_json(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            workspace = MockWorkspace(temporary_directory)
            report_path = Path(temporary_directory) / "inventory.json"
            result = subprocess.run(
                [
                    "python3",
                    "scripts/account_inventory.py",
                    "--profile",
                    "cleanup-admin",
                    "--region",
                    "us-west-2",
                    "--project",
                    "stub-app",
                    "--environment",
                    "dev",
                    "--output",
                    str(report_path),
                ],
                cwd=workspace.root,
                env=workspace.environment,
                check=False,
                capture_output=True,
                text=True,
            )
            report = json.loads(report_path.read_text(encoding="utf-8"))
            report_mode = stat.S_IMODE(report_path.stat().st_mode)

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue(report["complete"])
        self.assertEqual(report["identity"]["Account"], "123456789012")
        self.assertEqual(len(report["sections"]["ec2_instances"]), 1)
        self.assertEqual(len(report["sections"]["vpcs"]), 1)
        self.assertEqual(len(report["sections"]["ownership_tag_matches"]), 1)
        self.assertIn("AWS ACCOUNT ASSET INVENTORY", result.stdout)
        self.assertIn("AWS has no universal list-all-assets API", report["scope"]["limitation"])
        self.assertEqual(report_mode, 0o600)


class SelfDestructTests(unittest.TestCase):
    def test_review_only_lists_and_plans_without_any_delete_call(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            workspace = MockWorkspace(temporary_directory)
            result = workspace.run_self_destruct("--review-only", "--delete-state-bucket")
            events = workspace.events.read_text(encoding="utf-8")
            reports = list((workspace.root / "logs" / "inventory").glob("*-before.json"))
            manifests = list(
                (workspace.root / "logs" / "inventory").glob("*-deletion-manifest.json")
            )
            manifest = json.loads(manifests[0].read_text(encoding="utf-8"))
            manifest_mode = stat.S_IMODE(manifests[0].stat().st_mode)

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("PROPOSED AWS-ENVBUILDER DELETION MANIFEST", result.stdout)
        self.assertIn("REVIEW-ONLY COMPLETE", result.stdout)
        self.assertIn("terraform plan", events)
        self.assertNotIn("terraform apply", events)
        self.assertNotIn("s3api delete-objects", events)
        self.assertNotIn("s3api delete-bucket", events)
        self.assertEqual(len(reports), 1)
        self.assertEqual(len(manifests), 1)
        self.assertEqual(manifest["mode"], "review")
        self.assertEqual(manifest["state_bucket"]["action"], "DELETE")
        self.assertEqual(manifest["unrelated_assets"]["action"], "NEVER_AUTO_DELETE")
        self.assertEqual(manifest_mode, 0o600)

    def test_wrong_confirmation_blocks_every_delete(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            workspace = MockWorkspace(temporary_directory)
            result = workspace.run_self_destruct(
                "--execute",
                "--expected-account",
                "123456789012",
                "--delete-state-bucket",
                confirmation="WRONG PHRASE",
            )
            events = workspace.events.read_text(encoding="utf-8")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Confirmation did not match", result.stdout)
        self.assertNotIn("terraform apply", events)
        self.assertNotIn("s3api delete-objects", events)
        self.assertNotIn("s3api delete-bucket", events)

    def test_non_delete_plan_action_blocks_before_confirmation(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            workspace = MockWorkspace(temporary_directory)
            workspace.environment["MOCK_PLAN_ACTION"] = "create"
            result = workspace.run_self_destruct("--review-only")
            events = workspace.events.read_text(encoding="utf-8")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Destroy plan contains non-destruction actions", result.stdout)
        self.assertNotIn("terraform apply", events)
        self.assertNotIn("delete-objects", events)

    def test_missing_service_account_delete_permission_blocks_runtime_destroy(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            workspace = MockWorkspace(temporary_directory)
            workspace.environment["MOCK_DENY_IDENTITY_CLEANUP"] = "true"
            result = workspace.run_self_destruct(
                "--execute",
                "--expected-account",
                "123456789012",
                "--delete-service-account",
                "--service-account",
                "aws-envbuilder-automation",
                confirmation="SELF DESTRUCT 123456789012 stub-app dev",
            )
            events = workspace.events.read_text(encoding="utf-8")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Service-account deletion permission proof failed", result.stdout)
        self.assertNotIn("terraform apply", events)
        self.assertNotIn("iam delete-user", events)

    def test_service_account_name_without_local_profile_is_not_ownership_proof(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            workspace = MockWorkspace(temporary_directory)
            (workspace.root / ".workspace" / "service-account-profile").unlink()
            result = workspace.run_self_destruct(
                "--review-only",
                "--delete-service-account",
                "--service-account",
                "aws-envbuilder-automation",
            )
            events = workspace.events.read_text(encoding="utf-8")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("A user name alone is not ownership proof", result.stdout)
        self.assertNotIn("terraform apply", events)
        self.assertNotIn("iam delete-user", events)

    def test_approved_service_account_cleanup_removes_only_verified_bootstrap_user(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            workspace = MockWorkspace(temporary_directory)
            workspace.environment["MOCK_OWNED_RESOURCE"] = "absent"
            result = workspace.run_self_destruct(
                "--execute",
                "--expected-account",
                "123456789012",
                "--delete-service-account",
                "--service-account",
                "aws-envbuilder-automation",
                confirmation="SELF DESTRUCT 123456789012 stub-app dev",
            )
            events = workspace.events.read_text(encoding="utf-8")
            credentials = workspace.credentials.read_text(encoding="utf-8")
            config = workspace.config.read_text(encoding="utf-8")
            marker_exists = (
                workspace.root / ".workspace" / "service-account-profile"
            ).exists()

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("iam delete-access-key", events)
        self.assertIn("iam delete-user-policy", events)
        self.assertIn("iam delete-user --user-name aws-envbuilder-automation", events)
        self.assertLess(events.index("terraform apply"), events.index("iam delete-access-key"))
        self.assertNotIn("s3api delete-bucket", events)
        self.assertIn("[cleanup-admin]", credentials)
        self.assertNotIn("[aws-envbuilder-automation]", credentials)
        self.assertIn("[profile cleanup-admin]", config)
        self.assertNotIn("[profile aws-envbuilder-automation]", config)
        self.assertFalse(marker_exists)

    def test_remaining_managed_state_keeps_backend_and_service_account(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            workspace = MockWorkspace(temporary_directory)
            workspace.environment["MOCK_REMAINING_MANAGED"] = "true"
            result = workspace.run_self_destruct(
                "--execute",
                "--expected-account",
                "123456789012",
                "--delete-state-bucket",
                "--delete-service-account",
                "--service-account",
                "aws-envbuilder-automation",
                confirmation="SELF DESTRUCT 123456789012 stub-app dev",
            )
            events = workspace.events.read_text(encoding="utf-8")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("state still contains managed resources", result.stdout)
        self.assertIn("terraform apply", events)
        self.assertNotIn("s3api delete-objects", events)
        self.assertNotIn("s3api delete-bucket", events)
        self.assertNotIn("iam delete-user", events)

    def test_approved_execution_applies_saved_plan_then_deletes_owned_backend(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            workspace = MockWorkspace(temporary_directory)
            # The post-delete inventory should no longer report the fake tagged
            # VPC. The fake AWS process reads this environment on each call.
            workspace.environment["MOCK_OWNED_RESOURCE"] = "absent"
            result = workspace.run_self_destruct(
                "--execute",
                "--expected-account",
                "123456789012",
                "--delete-state-bucket",
                confirmation="SELF DESTRUCT 123456789012 stub-app dev",
            )
            events = workspace.events.read_text(encoding="utf-8")
            backend_exists = (workspace.root / "terraform" / "backend.hcl").exists()

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("terraform apply", events)
        self.assertIn("s3api delete-objects", events)
        self.assertIn("s3api delete-bucket", events)
        self.assertLess(events.index("terraform apply"), events.index("s3api delete-objects"))
        self.assertIn("SELF-DESTRUCT SEQUENCE COMPLETED", result.stdout)
        self.assertFalse(backend_exists)


if __name__ == "__main__":
    unittest.main()
