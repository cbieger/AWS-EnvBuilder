"""Unit tests for AWS-root safety, profile selection, and package contents."""

import json
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest


REPOSITORY_ROOT = Path(__file__).resolve().parents[1]
COMMON_LIBRARY = REPOSITORY_ROOT / "scripts" / "lib" / "common.sh"


class IdentityGuardTests(unittest.TestCase):
    """Exercise guard functions in an isolated Bash child process."""

    def run_common(self, command, marker=None):
        environment = os.environ.copy()
        if marker is not None:
            environment["WORKSPACE_SERVICE_PROFILE_FILE"] = str(marker)
        return subprocess.run(
            ["bash", "-c", f'source "$1"; {command}', "test", str(COMMON_LIBRARY)],
            cwd=REPOSITORY_ROOT,
            env=environment,
            check=False,
            capture_output=True,
            text=True,
        )

    def test_first_run_requires_aws_account_root_arn(self):
        root = self.run_common(
            "require_aws_root_identity arn:aws:iam::123456789012:root"
        )
        iam_user = self.run_common(
            "require_aws_root_identity arn:aws:iam::123456789012:user/deployer"
        )

        self.assertEqual(root.returncode, 0, root.stderr)
        self.assertNotEqual(iam_user.returncode, 0)
        self.assertIn("First run requires the AWS account root identity", iam_user.stderr)

    def test_normal_commands_refuse_root_without_explicit_override(self):
        rejected = self.run_common(
            "enforce_non_root_aws_identity arn:aws:iam::123456789012:root false"
        )
        overridden = self.run_common(
            "enforce_non_root_aws_identity arn:aws:iam::123456789012:root true"
        )
        iam_user = self.run_common(
            "enforce_non_root_aws_identity arn:aws:iam::123456789012:user/deployer false"
        )

        self.assertNotEqual(rejected.returncode, 0)
        self.assertIn("Refusing AWS account root", rejected.stderr)
        self.assertEqual(overridden.returncode, 0, overridden.stderr)
        self.assertIn("ROOT OVERRIDE ACTIVE", overridden.stderr)
        self.assertEqual(iam_user.returncode, 0, iam_user.stderr)

    def test_saved_profile_is_used_but_explicit_profile_wins(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            marker = Path(temporary_directory) / "service-account-profile"
            marker.write_text("saved-service-profile\n", encoding="utf-8")

            saved = self.run_common('resolve_aws_profile ""', marker)
            explicit = self.run_common(
                'resolve_aws_profile "explicit-profile"', marker
            )

        self.assertEqual(saved.returncode, 0, saved.stderr)
        self.assertEqual(saved.stdout.strip(), "saved-service-profile")
        self.assertEqual(explicit.returncode, 0, explicit.stderr)
        self.assertEqual(explicit.stdout.strip(), "explicit-profile")

    def test_invalid_saved_profile_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            marker = Path(temporary_directory) / "service-account-profile"
            marker.write_text("unsafe profile with spaces\n", encoding="utf-8")
            result = self.run_common('resolve_aws_profile ""', marker)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Saved AWS profile marker is invalid", result.stderr)

    def test_first_run_script_rejects_a_non_root_aws_caller_before_writes(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary_path = Path(temporary_directory)
            fake_aws = temporary_path / "aws"
            fake_aws.write_text(
                """#!/usr/bin/env bash
if [[ " $* " == *" sts get-caller-identity "* ]]; then
  printf '%s\\n' '{"Account":"123456789012","Arn":"arn:aws:iam::123456789012:user/not-root","UserId":"AIDATEST"}'
  exit 0
fi
printf '%s\\n' "unexpected fake AWS call: $*" >&2
exit 90
""",
                encoding="utf-8",
            )
            fake_aws.chmod(0o755)
            environment = {
                **os.environ,
                "PATH": f"{temporary_directory}{os.pathsep}{os.environ['PATH']}",
                "WORKSPACE_LOG_DIR": str(temporary_path / "logs"),
                "WORKSPACE_SERVICE_PROFILE_FILE": str(temporary_path / "profile-marker"),
            }
            result = subprocess.run(
                [
                    "bash",
                    "scripts/first_run_setup.sh",
                    "--service-account",
                    "must-not-be-created",
                ],
                cwd=REPOSITORY_ROOT,
                env=environment,
                check=False,
                capture_output=True,
                text=True,
            )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("First run requires the AWS account root identity", result.stdout)
        self.assertNotIn("unexpected fake AWS call", result.stdout)

    def test_first_run_hands_root_off_without_printing_the_new_secret(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary_path = Path(temporary_directory)
            fake_bin = temporary_path / "bin"
            fake_bin.mkdir()
            events_path = temporary_path / "aws-events.txt"
            credentials_path = temporary_path / "credentials"
            config_path = temporary_path / "config"
            marker_path = temporary_path / "profile-marker"
            service_name = "tested-service-account"
            test_secret = "test-secret-that-must-not-appear-in-output"

            fake_aws = fake_bin / "aws"
            fake_aws.write_text(
                """#!/usr/bin/env python3
import json
import os
import sys

arguments = sys.argv[1:]
with open(os.environ["MOCK_AWS_EVENTS"], "a", encoding="utf-8") as events:
    events.write(" ".join(arguments) + "\\n")

if arguments == ["--version"]:
    print("aws-cli/2.36.2 Python/3.14.6 Darwin/25.5.0 exe/x86_64")
elif arguments[:2] == ["configure", "list-profiles"]:
    pass
elif arguments and arguments[0] == "configure":
    pass
elif "sts" in arguments and "get-caller-identity" in arguments:
    if "--profile" in arguments and arguments[arguments.index("--profile") + 1] == os.environ["MOCK_SERVICE_PROFILE"]:
        arn = f"arn:aws:iam::123456789012:user/{os.environ['MOCK_SERVICE_PROFILE']}"
    else:
        arn = "arn:aws:iam::123456789012:root"
    print(json.dumps({"Account": "123456789012", "Arn": arn, "UserId": "TEST"}))
elif "iam" in arguments and "get-user" in arguments:
    print("An error occurred (NoSuchEntity) when calling GetUser", file=sys.stderr)
    raise SystemExit(254)
elif "iam" in arguments and "create-access-key" in arguments:
    print(json.dumps({"AccessKey": {"AccessKeyId": "AKIA" + "0" * 16, "SecretAccessKey": os.environ["MOCK_ACCESS_SECRET"]}}))
elif "iam" in arguments and "simulate-principal-policy" in arguments:
    start = arguments.index("--action-names") + 1
    end = arguments.index("--output", start)
    actions = arguments[start:end]
    print(json.dumps({"EvaluationResults": [{"EvalActionName": action, "EvalDecision": "allowed"} for action in actions]}))
else:
    print("{}")
""",
                encoding="utf-8",
            )
            fake_aws.chmod(0o755)

            # Strict preflight checks the official changelog. A fixed local
            # response keeps this unit test offline and deterministic.
            fake_curl = fake_bin / "curl"
            fake_curl.write_text(
                "#!/usr/bin/env bash\nprintf '%s\\n' '2.36.2'\n",
                encoding="utf-8",
            )
            fake_curl.chmod(0o755)

            environment = {
                **os.environ,
                "PATH": f"{fake_bin}{os.pathsep}{os.environ['PATH']}",
                "AWS_SHARED_CREDENTIALS_FILE": str(credentials_path),
                "AWS_CONFIG_FILE": str(config_path),
                "MOCK_ACCESS_SECRET": test_secret,
                "MOCK_AWS_EVENTS": str(events_path),
                "MOCK_SERVICE_PROFILE": service_name,
                "WORKSPACE_EXACT_CONFIRMATION": "CREATE AWS SERVICE ACCOUNT",
                "WORKSPACE_LOG_DIR": str(temporary_path / "logs"),
                "WORKSPACE_SERVICE_PROFILE_FILE": str(marker_path),
            }
            result = subprocess.run(
                [
                    "bash",
                    "scripts/first_run_setup.sh",
                    "--root-profile",
                    "mock-root",
                    "--region",
                    "us-west-2",
                    "--service-account",
                    service_name,
                ],
                cwd=REPOSITORY_ROOT,
                env=environment,
                check=False,
                capture_output=True,
                text=True,
            )

            credentials = credentials_path.read_text(encoding="utf-8")
            events = events_path.read_text(encoding="utf-8")
            marker = marker_path.read_text(encoding="utf-8").strip()

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(marker, service_name)
        self.assertIn(test_secret, credentials)
        self.assertNotIn(test_secret, result.stdout)
        self.assertNotIn(test_secret, result.stderr)
        self.assertIn("iam create-user", events)
        self.assertIn("iam create-access-key", events)
        self.assertIn("iam simulate-principal-policy", events)
        self.assertIn(f"First-run setup completed for arn:aws:iam::123456789012:user/{service_name}", result.stdout)


class GeneratedPolicyTests(unittest.TestCase):
    """Keep bootstrap permissions aligned with the audited preflight list."""

    def test_generated_policy_is_valid_and_does_not_manage_iam_users(self):
        result = subprocess.run(
            ["bash", "scripts/permissions.sh", "--print-service-policy"],
            cwd=REPOSITORY_ROOT,
            check=True,
            capture_output=True,
            text=True,
        )
        policy = json.loads(result.stdout)
        statement = policy["Statement"][0]
        actions = statement["Action"]

        self.assertEqual(statement["Effect"], "Allow")
        self.assertEqual(statement["Resource"], "*")
        self.assertEqual(actions, sorted(set(actions)))
        self.assertIn("iam:SimulatePrincipalPolicy", actions)
        self.assertNotIn("iam:CreateUser", actions)
        self.assertNotIn("iam:CreateAccessKey", actions)
        self.assertNotIn("iam:AttachUserPolicy", actions)


class PackageTests(unittest.TestCase):
    """Prove a release contains the kit but excludes local and secret state."""

    def test_source_package_uses_the_reviewed_allowlist(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            result = subprocess.run(
                [
                    "bash",
                    "scripts/package.sh",
                    "--output",
                    temporary_directory,
                    "--version",
                    "unit-test",
                ],
                cwd=REPOSITORY_ROOT,
                check=True,
                capture_output=True,
                text=True,
                env={**os.environ, "WORKSPACE_LOG_DIR": temporary_directory},
            )
            archive_path = Path(temporary_directory) / "aws-envbuilder-unit-test.tar.gz"
            with tarfile.open(archive_path, "r:gz") as archive:
                members = set(archive.getnames())

        prefix = "aws-envbuilder-unit-test/"
        self.assertIn(f"{prefix}README.md", members)
        self.assertIn(f"{prefix}scripts/first_run_setup.sh", members)
        self.assertIn(f"{prefix}scripts/package.sh", members)
        self.assertIn(f"{prefix}scripts/account_inventory.py", members)
        self.assertIn(f"{prefix}scripts/self_destruct.sh", members)
        self.assertIn(f"{prefix}docs/SELF_DESTRUCT.md", members)
        self.assertIn(f"{prefix}logs/inventory/.gitkeep", members)
        self.assertIn(f"{prefix}terraform/variables.tf", members)
        self.assertFalse(any(".workspace" in name for name in members))
        self.assertFalse(any(".terraform/" in name for name in members))
        self.assertFalse(any(name.endswith("terraform.tfvars") for name in members))
        self.assertFalse(any(name.endswith(".tfplan") for name in members))
        self.assertFalse(any(name.endswith(".log") for name in members))
        self.assertFalse(any(name.endswith(".json") for name in members))
        self.assertFalse(any("AGENTS.md" in name for name in members))


if __name__ == "__main__":
    unittest.main()
