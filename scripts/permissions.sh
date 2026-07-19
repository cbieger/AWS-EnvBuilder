#!/usr/bin/env bash
# Prove common read access and ask IAM's simulator about required write/delete
# actions. Policy simulation is read-only and does not create a test resource.

set -Eeuo pipefail
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

PROFILE=""
REGION="us-west-2"
STRICT=false
RUN_AS_ROOT=false
PRINT_SERVICE_POLICY=false

usage() {
  cat <<'USAGE'
Usage: ./scripts/permissions.sh [--profile NAME] [--region REGION] [--strict] [--run-as-root]

The IAM simulator is the safest available pre-deployment check for create and
delete actions. It cannot include every Service Control Policy, permission
boundary, tag condition, quota, or eventual runtime condition. Terraform's
saved plan and actual apply remain the final checks.

--run-as-root is an exceptional override. Root cannot be simulated, so the
script performs read checks and prints a prominent warning instead.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile)
      [[ $# -ge 2 ]] || die "--profile requires a value."
      PROFILE="$2"
      shift 2
      ;;
    --region)
      [[ $# -ge 2 ]] || die "--region requires a value."
      REGION="$2"
      shift 2
      ;;
    --strict)
      STRICT=true
      shift
      ;;
    --run-as-root)
      RUN_AS_ROOT=true
      shift
      ;;
    --print-service-policy)
      # Internal packaging/bootstrap interface. It prints no credential and
      # performs no AWS request.
      PRINT_SERVICE_POLICY=true
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      die "Unknown permissions option: $1"
      ;;
  esac
done

readonly REQUIRED_ACTIONS=(
  "autoscaling:AttachLoadBalancerTargetGroups"
  "autoscaling:CreateAutoScalingGroup"
  "autoscaling:DeleteAutoScalingGroup"
  "autoscaling:DeletePolicy"
  "autoscaling:DescribeAutoScalingGroups"
  "autoscaling:DescribePolicies"
  "autoscaling:PutScalingPolicy"
  "autoscaling:StartInstanceRefresh"
  "autoscaling:UpdateAutoScalingGroup"
  "budgets:CreateBudget"
  "budgets:CreateNotification"
  "budgets:CreateSubscriber"
  "budgets:DeleteBudget"
  "budgets:DeleteNotification"
  "budgets:DeleteSubscriber"
  "budgets:DescribeBudget"
  "budgets:DescribeNotificationsForBudget"
  "budgets:DescribeSubscribersForNotification"
  "budgets:ListTagsForResource"
  "budgets:TagResource"
  "budgets:UntagResource"
  "budgets:UpdateBudget"
  "budgets:UpdateNotification"
  "budgets:UpdateSubscriber"
  "ec2:AssociateRouteTable"
  "ec2:AttachInternetGateway"
  "ec2:AuthorizeSecurityGroupEgress"
  "ec2:AuthorizeSecurityGroupIngress"
  "ec2:CreateInternetGateway"
  "ec2:CreateLaunchTemplate"
  "ec2:CreateLaunchTemplateVersion"
  "ec2:CreateRoute"
  "ec2:CreateRouteTable"
  "ec2:CreateSecurityGroup"
  "ec2:CreateSubnet"
  "ec2:CreateTags"
  "ec2:CreateVpc"
  "ec2:DeleteInternetGateway"
  "ec2:DeleteLaunchTemplate"
  "ec2:DeleteLaunchTemplateVersions"
  "ec2:DeleteRoute"
  "ec2:DeleteRouteTable"
  "ec2:DeleteSecurityGroup"
  "ec2:DeleteSubnet"
  "ec2:DeleteTags"
  "ec2:DeleteVpc"
  "ec2:Describe*"
  "ec2:DetachInternetGateway"
  "ec2:DisassociateRouteTable"
  "ec2:ModifySubnetAttribute"
  "ec2:ModifyVpcAttribute"
  "ec2:ModifyLaunchTemplate"
  "ec2:RevokeSecurityGroupEgress"
  "ec2:RevokeSecurityGroupIngress"
  "ec2:RunInstances"
  "ec2:TerminateInstances"
  "elasticloadbalancing:AddTags"
  "elasticloadbalancing:CreateListener"
  "elasticloadbalancing:CreateLoadBalancer"
  "elasticloadbalancing:CreateTargetGroup"
  "elasticloadbalancing:DeleteListener"
  "elasticloadbalancing:DeleteLoadBalancer"
  "elasticloadbalancing:DeleteTargetGroup"
  "elasticloadbalancing:Describe*"
  "elasticloadbalancing:ModifyLoadBalancerAttributes"
  "elasticloadbalancing:ModifyTargetGroup"
  "elasticloadbalancing:ModifyTargetGroupAttributes"
  "elasticloadbalancing:RemoveTags"
  "elasticloadbalancing:SetSecurityGroups"
  "elasticloadbalancing:SetSubnets"
  "ecr:CreateRepository"
  "ecr:BatchCheckLayerAvailability"
  "ecr:BatchGetImage"
  "ecr:CompleteLayerUpload"
  "ecr:DeleteLifecyclePolicy"
  "ecr:DeleteRepository"
  "ecr:DescribeRepositories"
  "ecr:GetAuthorizationToken"
  "ecr:GetDownloadUrlForLayer"
  "ecr:InitiateLayerUpload"
  "ecr:ListImages"
  "ecr:PutImage"
  "ecr:PutImageScanningConfiguration"
  "ecr:PutImageTagMutability"
  "ecr:PutLifecyclePolicy"
  "ecr:TagResource"
  "ecr:UntagResource"
  "ecr:UploadLayerPart"
  "iam:AddRoleToInstanceProfile"
  "iam:AttachRolePolicy"
  "iam:CreateInstanceProfile"
  "iam:CreateRole"
  "iam:CreateServiceLinkedRole"
  "iam:DeleteInstanceProfile"
  "iam:DeleteRole"
  "iam:DeleteRolePolicy"
  "iam:DetachRolePolicy"
  "iam:GetInstanceProfile"
  "iam:GetRole"
  "iam:GetRolePolicy"
  "iam:ListAttachedRolePolicies"
  "iam:ListInstanceProfilesForRole"
  "iam:ListInstanceProfileTags"
  "iam:ListRolePolicies"
  "iam:ListRoleTags"
  "iam:ListRoles"
  "iam:ListUsers"
  "iam:ListInstanceProfiles"
  "iam:PassRole"
  "iam:PutRolePolicy"
  "iam:RemoveRoleFromInstanceProfile"
  "iam:SimulatePrincipalPolicy"
  "iam:TagInstanceProfile"
  "iam:TagRole"
  "iam:UntagInstanceProfile"
  "iam:UntagRole"
  "logs:CreateLogGroup"
  "logs:DeleteLogGroup"
  "logs:DescribeLogGroups"
  "logs:FilterLogEvents"
  "logs:ListTagsForResource"
  "logs:PutRetentionPolicy"
  "logs:TagResource"
  "logs:UntagResource"
  "s3:CreateBucket"
  "s3:DeleteBucket"
  "s3:DeleteBucketLifecycle"
  "s3:DeleteBucketOwnershipControls"
  "s3:DeleteBucketPolicy"
  "s3:DeleteObject"
  "s3:DeleteObjectVersion"
  "s3:Get*"
  "s3:List*"
  "s3:PutBucketLifecycleConfiguration"
  "s3:PutBucketOwnershipControls"
  "s3:PutBucketPolicy"
  "s3:PutBucketPublicAccessBlock"
  "s3:PutBucketTagging"
  "s3:PutBucketVersioning"
  "s3:PutEncryptionConfiguration"
  "s3:PutObject"
  "tag:GetResources"
)

if [[ "${PRINT_SERVICE_POLICY}" == "true" ]]; then
  require_command python3 "Python 3.9 or newer is required to render the service-account policy."
  python3 - "${REQUIRED_ACTIONS[@]}" <<'PY'
import json
import sys

# Actions are passed as individual arguments so no shell evaluation or policy
# text parsing is involved. Resource "*" is required because this reusable kit
# cannot know future account IDs, generated names, buckets, or IAM role ARNs.
policy = {
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "AWSenvBuilderRequiredActions",
            "Effect": "Allow",
            "Action": sorted(set(sys.argv[1:])),
            "Resource": "*",
        }
    ],
}
json.dump(policy, sys.stdout, indent=2)
sys.stdout.write("\n")
PY
  exit 0
fi

begin_logged_run "permissions"
PROFILE="$(resolve_aws_profile "${PROFILE}")"

AWS_OPTIONS=(--region "${REGION}")
if [[ -n "${PROFILE}" ]]; then
  AWS_OPTIONS+=(--profile "${PROFILE}")
fi

identity_json=$(aws "${AWS_OPTIONS[@]}" sts get-caller-identity --output json) \
  || die "Unable to identify the authenticated AWS principal."
account_id=$(printf '%s' "${identity_json}" | jq -r '.Account')
caller_arn=$(printf '%s' "${identity_json}" | jq -r '.Arn')

enforce_non_root_aws_identity "${caller_arn}" "${RUN_AS_ROOT}"

log_info "Testing read access for ${caller_arn}."
read_failures=0

read_check() {
  local description="$1"
  shift

  if aws "${AWS_OPTIONS[@]}" "$@" >/dev/null 2>&1; then
    log_info "Read check passed: ${description}."
  else
    log_error "Read check failed: ${description}. Command family: aws $1 $2"
    read_failures=$((read_failures + 1))
  fi
}

read_check "EC2 networking" ec2 describe-vpcs --max-results 5
read_check "Auto Scaling" autoscaling describe-auto-scaling-groups --max-records 1
# Some AWS CLI configurations disable automatic pagination. Combining that
# setting with the generic --page-size/--max-items flags is rejected locally
# before AWS receives a request, which looks like a permission failure. Request
# only the service's first page so this remains a small, read-only access check.
read_check "Application Load Balancers" elbv2 describe-load-balancers --no-paginate
read_check "CloudWatch Logs" logs describe-log-groups --limit 1
read_check "ECR" ecr describe-repositories --max-results 1
read_check "S3" s3api list-buckets
read_check "AWS Budgets" budgets describe-budgets --account-id "${account_id}" --max-results 1
read_check "IAM users" iam list-users --max-items 1
read_check "IAM roles" iam list-roles --max-items 1
read_check "IAM instance profiles" iam list-instance-profiles --max-items 1
read_check "Resource Groups Tagging API" resourcegroupstaggingapi get-resources --resources-per-page 1

if [[ "${read_failures}" -gt 0 ]]; then
  die "${read_failures} required read check(s) failed. Ask an AWS administrator to review docs/PERMISSIONS.md."
fi

if is_aws_root_arn "${caller_arn}"; then
  log_warning "IAM policy simulation is unavailable for AWS account root and was skipped under the explicit override."
  log_warning "Read checks passed, but no least-privilege proof exists for root."
  exit 0
fi

# SimulatePrincipalPolicy accepts an IAM user or role ARN, not the temporary STS
# session ARN returned for an assumed role. Resolve that session to its IAM role.
policy_source_arn="${caller_arn}"
if [[ "${caller_arn}" == *":assumed-role/"* ]]; then
  role_and_session="${caller_arn#*:assumed-role/}"
  role_name="${role_and_session%%/*}"
  policy_source_arn=$(aws "${AWS_OPTIONS[@]}" iam get-role \
    --role-name "${role_name}" --query 'Role.Arn' --output text 2>/dev/null || true)
fi

if [[ -z "${policy_source_arn}" || "${policy_source_arn}" == *":federated-user/"* ]]; then
  log_warning "The temporary principal could not be mapped to a simulatable IAM user or role."
  if [[ "${STRICT}" == "true" ]]; then
    die "Strict permission proof requires an IAM user or assumed role that iam:SimulatePrincipalPolicy can inspect."
  fi
  exit 2
fi

simulation_file=$(mktemp "${TMPDIR:-/tmp}/workspace-policy-simulation.XXXXXX")
not_allowed=""
offset=0
maximum_actions_per_request=100

# IAM accepts at most 100 action names per simulation request. Keep the complete
# audited list and evaluate it in deterministic chunks rather than silently
# dropping permissions beyond that service limit.
while [[ "${offset}" -lt "${#REQUIRED_ACTIONS[@]}" ]]; do
  action_chunk=("${REQUIRED_ACTIONS[@]:offset:maximum_actions_per_request}")
  if ! aws "${AWS_OPTIONS[@]}" iam simulate-principal-policy \
    --policy-source-arn "${policy_source_arn}" \
    --action-names "${action_chunk[@]}" \
    --output json >"${simulation_file}" 2>/dev/null; then
    rm -f "${simulation_file}"
    log_warning "IAM policy simulation was denied or unavailable. This often means the caller lacks iam:SimulatePrincipalPolicy."
    if [[ "${STRICT}" == "true" ]]; then
      die "Strict permission proof failed. Grant simulation access or have an AWS administrator run this check."
    fi
    exit 2
  fi

  evaluation_count=$(jq -r '.EvaluationResults | length' "${simulation_file}")
  if [[ "${evaluation_count}" -ne "${#action_chunk[@]}" ]]; then
    rm -f "${simulation_file}"
    die "IAM simulation returned ${evaluation_count} result(s) for ${#action_chunk[@]} requested actions; refusing an incomplete permission proof."
  fi

  chunk_not_allowed=$(jq -r \
    '.EvaluationResults[] | select(.EvalDecision != "allowed") | "\(.EvalActionName): \(.EvalDecision)"' \
    "${simulation_file}")
  if [[ -n "${chunk_not_allowed}" ]]; then
    not_allowed="${not_allowed}${chunk_not_allowed}"$'\n'
  fi
  offset=$((offset + maximum_actions_per_request))
done
rm -f "${simulation_file}"

if [[ -n "${not_allowed}" ]]; then
  log_error "IAM simulation did not allow these required action patterns:"
  printf '%s\n' "${not_allowed}" >&2
  die "Permission simulation failed. No AWS resource was changed."
fi

log_info "IAM simulation allowed all ${#REQUIRED_ACTIONS[@]} required action patterns."
log_warning "Simulation does not prove quotas, tag conditions, permission boundaries, or AWS Organizations SCP behavior."
