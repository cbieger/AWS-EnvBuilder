#!/usr/bin/env python3
"""Create a read-only AWS account/Region asset inventory for safe teardown.

AWS does not expose one universal API that lists every possible resource. This
collector combines the Resource Groups Tagging API with native list/describe
calls for every service family AWS-EnvBuilder uses. It never issues a create,
update, or delete request and never prints credential material.
"""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Inventory AWS-EnvBuilder service families without changing AWS."
    )
    parser.add_argument("--profile", help="AWS CLI profile selected by the caller.")
    parser.add_argument("--region", required=True, help="AWS Region to inventory.")
    parser.add_argument("--project", required=True, help="Expected Application tag.")
    parser.add_argument("--environment", required=True, help="Expected Environment tag.")
    parser.add_argument("--output", required=True, help="Protected JSON report path.")
    return parser.parse_args()


def normalize_tags(tags: object) -> list[dict[str, str]]:
    """Return deterministic Key/Value tag objects and discard malformed input."""
    if not isinstance(tags, list):
        return []
    normalized = []
    for tag in tags:
        if isinstance(tag, dict) and isinstance(tag.get("Key"), str):
            normalized.append({"Key": tag["Key"], "Value": str(tag.get("Value", ""))})
    return sorted(normalized, key=lambda item: (item["Key"], item["Value"]))


def selected(record: dict, keys: tuple[str, ...], *, tags_key: str | None = None) -> dict:
    """Copy only operator-useful identifiers; inventory reports need no policies."""
    result = {key: record.get(key) for key in keys if record.get(key) is not None}
    if tags_key and record.get(tags_key) is not None:
        result["Tags"] = normalize_tags(record.get(tags_key))
    return result


class AwsCollector:
    """Run AWS CLI JSON reads and retain complete failure evidence."""

    def __init__(self, profile: str | None, region: str) -> None:
        self.base = ["aws", "--region", region]
        if profile:
            self.base.extend(["--profile", profile])
        self.errors: list[dict[str, str]] = []

    def read(self, label: str, *arguments: str) -> dict:
        command = [*self.base, *arguments, "--output", "json", "--no-cli-pager"]
        completed = subprocess.run(
            command,
            check=False,
            capture_output=True,
            text=True,
        )
        if completed.returncode != 0:
            # AWS CLI error text can contain account/resource identifiers but
            # should never contain secret keys. Limit retained size regardless.
            self.errors.append(
                {
                    "section": label,
                    "command_family": " ".join(arguments[:2]),
                    "error": completed.stderr.strip()[-2000:],
                }
            )
            return {}
        try:
            value = json.loads(completed.stdout or "{}")
        except json.JSONDecodeError as error:
            self.errors.append(
                {
                    "section": label,
                    "command_family": " ".join(arguments[:2]),
                    "error": f"AWS CLI returned invalid JSON: {error}",
                }
            )
            return {}
        return value if isinstance(value, dict) else {}


def build_report(arguments: argparse.Namespace) -> tuple[dict, list[dict[str, str]]]:
    collector = AwsCollector(arguments.profile, arguments.region)
    identity = collector.read("identity", "sts", "get-caller-identity")

    tag_filters = json.dumps(
        [
            {"Key": "Application", "Values": [arguments.project]},
            {"Key": "Environment", "Values": [arguments.environment]},
        ],
        separators=(",", ":"),
    )
    all_tagged = collector.read(
        "tagged_resources", "resourcegroupstaggingapi", "get-resources"
    )
    owned_tagged = collector.read(
        "ownership_tag_matches",
        "resourcegroupstaggingapi",
        "get-resources",
        "--tag-filters",
        tag_filters,
    )

    instances = collector.read("ec2_instances", "ec2", "describe-instances")
    vpcs = collector.read("vpcs", "ec2", "describe-vpcs")
    subnets = collector.read("subnets", "ec2", "describe-subnets")
    route_tables = collector.read("route_tables", "ec2", "describe-route-tables")
    gateways = collector.read("internet_gateways", "ec2", "describe-internet-gateways")
    security_groups = collector.read("security_groups", "ec2", "describe-security-groups")
    interfaces = collector.read("network_interfaces", "ec2", "describe-network-interfaces")
    nat_gateways = collector.read("nat_gateways", "ec2", "describe-nat-gateways")
    volumes = collector.read("ebs_volumes", "ec2", "describe-volumes")
    addresses = collector.read("elastic_ips", "ec2", "describe-addresses")
    templates = collector.read("launch_templates", "ec2", "describe-launch-templates")
    autoscaling_groups = collector.read(
        "autoscaling_groups", "autoscaling", "describe-auto-scaling-groups"
    )
    autoscaling_policies = collector.read(
        "autoscaling_policies", "autoscaling", "describe-policies"
    )
    load_balancers = collector.read(
        "load_balancers", "elbv2", "describe-load-balancers"
    )
    target_groups = collector.read("target_groups", "elbv2", "describe-target-groups")
    repositories = collector.read("ecr_repositories", "ecr", "describe-repositories")
    log_groups = collector.read("cloudwatch_log_groups", "logs", "describe-log-groups")
    buckets = collector.read("s3_buckets", "s3api", "list-buckets")
    users = collector.read("iam_users", "iam", "list-users")
    roles = collector.read("iam_roles", "iam", "list-roles")
    instance_profiles = collector.read(
        "iam_instance_profiles", "iam", "list-instance-profiles"
    )
    account_id = identity.get("Account", "")
    budgets = collector.read(
        "budgets", "budgets", "describe-budgets", "--account-id", str(account_id)
    )
    lambda_functions = collector.read("lambda_functions", "lambda", "list-functions")
    schedules = collector.read("scheduler_schedules", "scheduler", "list-schedules")
    codebuild_projects = collector.read("codebuild_projects", "codebuild", "list-projects")
    dynamodb_tables = collector.read("dynamodb_tables", "dynamodb", "list-tables")
    sns_topics = collector.read("sns_topics", "sns", "list-topics")
    sns_subscriptions = collector.read("sns_subscriptions", "sns", "list-subscriptions")
    sms_phone_numbers = collector.read(
        "sms_phone_numbers", "pinpoint-sms-voice-v2", "describe-phone-numbers"
    )

    sections: dict[str, list[dict]] = {}
    sections["tagged_resources"] = [
        {
            "ResourceARN": mapping.get("ResourceARN"),
            "Tags": normalize_tags(mapping.get("Tags")),
        }
        for mapping in all_tagged.get("ResourceTagMappingList", [])
        if isinstance(mapping, dict)
    ]
    sections["ownership_tag_matches"] = [
        {
            "ResourceARN": mapping.get("ResourceARN"),
            "Tags": normalize_tags(mapping.get("Tags")),
        }
        for mapping in owned_tagged.get("ResourceTagMappingList", [])
        if isinstance(mapping, dict)
    ]

    sections["ec2_instances"] = []
    for reservation in instances.get("Reservations", []):
        for instance in reservation.get("Instances", []):
            state = (instance.get("State") or {}).get("Name")
            if state != "terminated":
                item = selected(
                    instance,
                    ("InstanceId", "InstanceType", "LaunchTime", "VpcId", "SubnetId"),
                    tags_key="Tags",
                )
                item["State"] = state
                sections["ec2_instances"].append(item)

    simple_sections = (
        ("vpcs", vpcs.get("Vpcs", []), ("VpcId", "CidrBlock", "IsDefault", "State"), "Tags"),
        ("subnets", subnets.get("Subnets", []), ("SubnetId", "VpcId", "CidrBlock", "AvailabilityZone", "State"), "Tags"),
        ("route_tables", route_tables.get("RouteTables", []), ("RouteTableId", "VpcId"), "Tags"),
        ("internet_gateways", gateways.get("InternetGateways", []), ("InternetGatewayId", "Attachments"), "Tags"),
        ("security_groups", security_groups.get("SecurityGroups", []), ("GroupId", "GroupName", "VpcId", "Description"), "Tags"),
        ("network_interfaces", interfaces.get("NetworkInterfaces", []), ("NetworkInterfaceId", "InterfaceType", "Status", "VpcId", "SubnetId", "Description"), "TagSet"),
        ("nat_gateways", nat_gateways.get("NatGateways", []), ("NatGatewayId", "State", "VpcId", "SubnetId"), "Tags"),
        ("ebs_volumes", volumes.get("Volumes", []), ("VolumeId", "State", "Size", "VolumeType", "Attachments"), "Tags"),
        ("elastic_ips", addresses.get("Addresses", []), ("AllocationId", "AssociationId", "PublicIp", "InstanceId", "NetworkInterfaceId"), "Tags"),
        ("launch_templates", templates.get("LaunchTemplates", []), ("LaunchTemplateId", "LaunchTemplateName", "LatestVersionNumber", "DefaultVersionNumber"), "Tags"),
        ("autoscaling_groups", autoscaling_groups.get("AutoScalingGroups", []), ("AutoScalingGroupARN", "AutoScalingGroupName", "MinSize", "MaxSize", "DesiredCapacity", "Instances"), "Tags"),
        ("autoscaling_policies", autoscaling_policies.get("ScalingPolicies", []), ("PolicyARN", "PolicyName", "AutoScalingGroupName", "PolicyType"), None),
        ("load_balancers", load_balancers.get("LoadBalancers", []), ("LoadBalancerArn", "LoadBalancerName", "DNSName", "Scheme", "Type", "State", "VpcId"), None),
        ("target_groups", target_groups.get("TargetGroups", []), ("TargetGroupArn", "TargetGroupName", "Protocol", "Port", "VpcId", "LoadBalancerArns"), None),
        ("ecr_repositories", repositories.get("repositories", []), ("repositoryArn", "repositoryName", "repositoryUri", "createdAt", "imageTagMutability"), None),
        ("cloudwatch_log_groups", log_groups.get("logGroups", []), ("arn", "logGroupName", "creationTime", "retentionInDays", "storedBytes"), None),
        ("s3_buckets", buckets.get("Buckets", []), ("Name", "CreationDate", "BucketArn", "BucketRegion"), None),
        ("iam_users", users.get("Users", []), ("Arn", "UserName", "Path", "CreateDate", "PasswordLastUsed"), "Tags"),
        ("iam_roles", roles.get("Roles", []), ("Arn", "RoleName", "Path", "CreateDate", "MaxSessionDuration"), "Tags"),
        ("iam_instance_profiles", instance_profiles.get("InstanceProfiles", []), ("Arn", "InstanceProfileName", "Path", "CreateDate", "Roles"), "Tags"),
        ("budgets", budgets.get("Budgets", []), ("BudgetName", "BudgetType", "BudgetLimit", "TimeUnit", "CalculatedSpend"), None),
        ("lambda_functions", lambda_functions.get("Functions", []), ("FunctionName", "FunctionArn", "Runtime", "LastModified", "MemorySize", "Timeout"), None),
        ("scheduler_schedules", schedules.get("Schedules", []), ("Arn", "Name", "GroupName", "State", "ScheduleExpression", "Target"), None),
        ("sns_topics", sns_topics.get("Topics", []), ("TopicArn",), None),
        # Endpoint is intentionally omitted because it may be an operator's
        # personal email address or cell number.
        ("sns_subscriptions", sns_subscriptions.get("Subscriptions", []), ("SubscriptionArn", "TopicArn", "Protocol"), None),
        # The literal telephone number is omitted from the retained inventory;
        # ARN/ID/status/capabilities are enough for an operator to find it.
        ("sms_phone_numbers", sms_phone_numbers.get("PhoneNumbers", []), ("PhoneNumberArn", "PhoneNumberId", "Status", "IsoCountryCode", "MessageType", "NumberCapabilities", "NumberType", "TwoWayEnabled", "TwoWayChannelArn", "SelfManagedOptOutsEnabled"), None),
    )
    for name, records, keys, tags_key in simple_sections:
        sections[name] = [
            selected(record, keys, tags_key=tags_key)
            for record in records
            if isinstance(record, dict)
        ]

    sections["codebuild_projects"] = [
        {"Name": name} for name in codebuild_projects.get("projects", []) if isinstance(name, str)
    ]
    sections["dynamodb_tables"] = [
        {"TableName": name} for name in dynamodb_tables.get("TableNames", []) if isinstance(name, str)
    ]

    for records in sections.values():
        records.sort(key=lambda item: json.dumps(item, sort_keys=True, default=str))

    report = {
        "schema_version": 1,
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "complete": not collector.errors,
        "identity": {
            "Account": identity.get("Account"),
            "Arn": identity.get("Arn"),
            "UserId": identity.get("UserId"),
        },
        "scope": {
            "region": arguments.region,
            "project": arguments.project,
            "environment": arguments.environment,
            "profile": arguments.profile,
            "coverage": (
                "All tagged/previously tagged resources returned by the regional "
                "Resource Groups Tagging API, plus native account/Region lists for "
                "EC2 networking/compute, Auto Scaling, ELBv2, ECR, CloudWatch Logs, "
                "S3, IAM, AWS Budgets, Lambda, EventBridge Scheduler, CodeBuild, "
                "DynamoDB, SNS, and AWS End User Messaging phone-number metadata. "
                "This is not every possible AWS service."
            ),
            "limitation": (
                "AWS has no universal list-all-assets API. GetResources omits resources "
                "that never had tags. Untagged assets outside the native service census "
                "and assets in other Regions/accounts are not represented."
            ),
        },
        "sections": sections,
        "errors": collector.errors,
    }
    return report, collector.errors


def atomic_write_report(path_text: str, report: dict) -> Path:
    destination = Path(path_text).expanduser().resolve()
    destination.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=".aws-inventory-", suffix=".json", dir=destination.parent
    )
    temporary_path = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as output:
            json.dump(report, output, indent=2, sort_keys=True, default=str)
            output.write("\n")
            output.flush()
            os.fsync(output.fileno())
        os.chmod(temporary_path, 0o600)
        os.replace(temporary_path, destination)
    except BaseException:
        temporary_path.unlink(missing_ok=True)
        raise
    return destination


def print_report(report: dict, destination: Path) -> None:
    identity = report["identity"]
    scope = report["scope"]
    print("=" * 78)
    print("AWS ACCOUNT ASSET INVENTORY — READ-ONLY")
    print("=" * 78)
    print(f"Account:     {identity.get('Account')}")
    print(f"Caller ARN:  {identity.get('Arn')}")
    print(f"Region:      {scope['region']}")
    print(f"Ownership:   Application={scope['project']}, Environment={scope['environment']}")
    print(f"Report:      {destination}")
    print()
    print(f"COVERAGE: {scope['coverage']}")
    print(f"LIMITATION: {scope['limitation']}")

    for name, records in report["sections"].items():
        print()
        print(f"[{name}] {len(records)} asset(s)")
        if not records:
            print("  (none)")
        for record in records:
            print("  - " + json.dumps(record, sort_keys=True, default=str))

    if report["errors"]:
        print(file=sys.stderr)
        print("INVENTORY ERRORS — deletion must remain blocked:", file=sys.stderr)
        for error in report["errors"]:
            print("  - " + json.dumps(error, sort_keys=True), file=sys.stderr)


def main() -> int:
    arguments = parse_arguments()
    report, errors = build_report(arguments)
    destination = atomic_write_report(arguments.output, report)
    print_report(report, destination)
    return 2 if errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
