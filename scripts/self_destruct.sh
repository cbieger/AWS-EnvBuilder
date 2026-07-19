#!/usr/bin/env bash
# Inventory an AWS account, show the exact Terraform-owned deletion proposal,
# and—only after an exact confirmation—remove the selected AWS-EnvBuilder scope.
# Unrelated or ambiguously owned account resources are never auto-deleted.

set -Eeuo pipefail
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

PROFILE=""
REGION="us-west-2"
PROJECT="stub-app"
ENVIRONMENT="dev"
EXPECTED_ACCOUNT=""
MODE="review"
MODE_EXPLICIT=false
DELETE_STATE_BUCKET=false
DELETE_SERVICE_ACCOUNT=false
SERVICE_ACCOUNT_NAME=""
SERVICE_PROFILE=""
RUN_AS_ROOT=false

usage() {
  cat <<'USAGE'
Usage: ./scripts/self_destruct.sh [options]

Required before deletion:
  --expected-account 123456789012
                         Exact 12-digit AWS account ID typed by the operator.
  --execute              Permit the confirmation prompt and approved deletion.

Inventory and ownership options:
  --profile NAME         Cleanup AWS CLI profile. Saved service profile is the
                         default when this option is omitted.
  --region REGION        Runtime/backend Region (default: us-west-2).
  --project NAME         Application tag/Terraform project (default: stub-app).
  --environment NAME     Environment tag (default: dev).
  --review-only          Inventory and create/show a destroy plan; change nothing.

Additional irreversible scopes (both default to KEEP):
  --delete-state-bucket  Permanently delete every state version and the backend.
  --delete-service-account
                         Delete the bootstrap IAM user, its keys/policy, and its
                         selected local AWS CLI profile. A different cleanup
                         identity with IAM deletion authority is required.
  --service-account NAME Optional IAM-user-name cross-check. The user must still
                         resolve through the selected local service profile.
  --service-profile NAME Local profile section to remove; otherwise use the
                         ignored first-run marker. A working profile is required
                         to prove the local handoff before IAM-user deletion.

Exceptional identity option:
  --run-as-root          Permit AWS account root for this invocation. Root remains
                         blocked without this flag. It does not bypass inventory,
                         ownership proofs, destroy-plan review, or confirmation.
  --help                 Show this explanation.

Safe first command:
  ./scripts/self_destruct.sh --review-only --region us-west-2 \
    --project stub-app --environment dev

Full standalone-account cleanup after review:
  aws login --profile aws-root-cleanup
  ./scripts/self_destruct.sh --execute --expected-account 123456789012 \
    --profile aws-root-cleanup --run-as-root --region us-west-2 \
    --project stub-app --environment dev \
    --delete-state-bucket --delete-service-account

The account inventory is broad but cannot be universal: AWS has no single API
that lists every resource in every service and Region. Deletion is intentionally
narrower—it uses Terraform state plus exact ownership tags and names.
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
    --project)
      [[ $# -ge 2 ]] || die "--project requires a value."
      PROJECT="$2"
      shift 2
      ;;
    --environment)
      [[ $# -ge 2 ]] || die "--environment requires a value."
      ENVIRONMENT="$2"
      shift 2
      ;;
    --expected-account)
      [[ $# -ge 2 ]] || die "--expected-account requires a value."
      EXPECTED_ACCOUNT="$2"
      shift 2
      ;;
    --review-only)
      [[ "${MODE_EXPLICIT}" == "false" ]] || die "Choose only one of --review-only or --execute."
      MODE="review"
      MODE_EXPLICIT=true
      shift
      ;;
    --execute)
      [[ "${MODE_EXPLICIT}" == "false" ]] || die "Choose only one of --review-only or --execute."
      MODE="execute"
      MODE_EXPLICIT=true
      shift
      ;;
    --delete-state-bucket)
      DELETE_STATE_BUCKET=true
      shift
      ;;
    --delete-service-account)
      DELETE_SERVICE_ACCOUNT=true
      shift
      ;;
    --service-account)
      [[ $# -ge 2 ]] || die "--service-account requires a value."
      SERVICE_ACCOUNT_NAME="$2"
      shift 2
      ;;
    --service-profile)
      [[ $# -ge 2 ]] || die "--service-profile requires a value."
      SERVICE_PROFILE="$2"
      shift 2
      ;;
    --run-as-root)
      RUN_AS_ROOT=true
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      die "Unknown self-destruct option: $1"
      ;;
  esac
done

[[ "${REGION}" =~ ^[a-z]{2}(-gov)?-[a-z]+-[0-9]$ ]] \
  || die "--region must look like us-west-2."
[[ "${PROJECT}" =~ ^[a-z][a-z0-9-]{1,22}[a-z0-9]$ ]] \
  || die "--project must be 3-24 lowercase letters, digits, or hyphens."
[[ "${ENVIRONMENT}" =~ ^[a-z][a-z0-9-]{1,10}[a-z0-9]$ ]] \
  || die "--environment must be 3-12 lowercase letters, digits, or hyphens."
[[ -z "${EXPECTED_ACCOUNT}" || "${EXPECTED_ACCOUNT}" =~ ^[0-9]{12}$ ]] \
  || die "--expected-account must contain exactly 12 digits."
[[ -z "${SERVICE_ACCOUNT_NAME}" || "${SERVICE_ACCOUNT_NAME}" =~ ^[A-Za-z0-9_.@+-]{1,64}$ ]] \
  || die "--service-account contains unsupported characters."
[[ -z "${SERVICE_PROFILE}" || "${SERVICE_PROFILE}" =~ ^[A-Za-z0-9_.@+-]{1,128}$ ]] \
  || die "--service-profile contains unsupported characters."

if [[ "${MODE}" == "execute" && -z "${EXPECTED_ACCOUNT}" ]]; then
  die "Deletion requires --expected-account with the intended 12-digit account ID."
fi

begin_logged_run "self-destruct-${MODE}"
require_command aws "Install AWS CLI v2 using docs/WORKSTATION_SETUP.md."
require_command terraform "Install Terraform 1.10 or newer using docs/WORKSTATION_SETUP.md."
require_command python3 "Install Python 3.9 or newer using docs/WORKSTATION_SETUP.md."
require_command jq "Install jq 1.6 or newer using docs/WORKSTATION_SETUP.md."

temporary_directory=$(mktemp -d "${TMPDIR:-/tmp}/aws-envbuilder-self-destruct.XXXXXX")
case "${temporary_directory}" in
  "${TMPDIR:-/tmp}"/aws-envbuilder-self-destruct.*) ;;
  *) die "Temporary workspace did not have the expected safe prefix." ;;
esac

# Sensitive Terraform plan JSON is temporary. The redacted account inventory is
# retained separately for 365 days. Preserve the ordinary success/error log via
# the common logging finalizer after cleaning the exact mktemp directory.
finish_self_destruct() {
  local exit_code="$?"
  trap - EXIT
  rm -rf -- "${temporary_directory}"
  if ! rotate_one_log_set "${WORKSPACE_LOG_ROOT}/inventory" 365 20 '*.json'; then
    log_warning "Inventory retention rotation failed; inspect ${WORKSPACE_LOG_ROOT}/inventory manually."
  fi
  _finish_logged_run "${exit_code}"
}
trap finish_self_destruct EXIT

PROFILE="$(resolve_aws_profile "${PROFILE}")"
AWS_OPTIONS=(--region "${REGION}")
if [[ -n "${PROFILE}" ]]; then
  AWS_OPTIONS+=(--profile "${PROFILE}")
  export AWS_PROFILE="${PROFILE}"
fi
export AWS_REGION="${REGION}"
export AWS_DEFAULT_REGION="${REGION}"

# Teardown must not be stranded solely by a newer CLI patch, but authentication,
# account identity, Region reads, and permissions still receive strict checks.
preflight_args=(--region "${REGION}" --strict --allow-cli-drift)
[[ -n "${PROFILE}" ]] && preflight_args+=(--profile "${PROFILE}")
[[ "${RUN_AS_ROOT}" == "true" ]] && preflight_args+=(--run-as-root)
"${SCRIPT_DIR}/preflight.sh" "${preflight_args[@]}"

identity_json=$(aws "${AWS_OPTIONS[@]}" sts get-caller-identity --output json) \
  || die "Unable to identify the cleanup caller. No deletion was attempted."
account_id=$(printf '%s' "${identity_json}" | jq -er '.Account')
caller_arn=$(printf '%s' "${identity_json}" | jq -er '.Arn')
enforce_non_root_aws_identity "${caller_arn}" "${RUN_AS_ROOT}"

if [[ -n "${EXPECTED_ACCOUNT}" && "${account_id}" != "${EXPECTED_ACCOUNT}" ]]; then
  die "Authenticated account ${account_id} does not match --expected-account ${EXPECTED_ACCOUNT}. No deletion was attempted."
fi

log_warning "SELF-DESTRUCT REVIEW FOR AWS ACCOUNT ${account_id}."
log_info "Cleanup caller: ${caller_arn}"
log_info "Requested ownership: Application=${PROJECT}, Environment=${ENVIRONMENT}, Region=${REGION}"

[[ -f "${TERRAFORM_DIR}/backend.hcl" ]] \
  || die "terraform/backend.hcl is required to prove which state inventory owns the runtime. No deletion was attempted."

# backend.hcl is generated by bootstrap_backend.sh and has a deliberately tiny
# key/value format. Parse only quoted bucket/key/Region values and reject every
# mismatch before Terraform is initialized.
backend_json="${temporary_directory}/backend.json"
python3 - "${TERRAFORM_DIR}/backend.hcl" >"${backend_json}" <<'PY'
import json
import re
import sys

values = {}
allowed = {"bucket", "key", "region", "encrypt", "use_lockfile"}
with open(sys.argv[1], "r", encoding="utf-8") as source:
    for number, line in enumerate(source, start=1):
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        match = re.fullmatch(r'([a-z_]+)\s*=\s*(?:"([^"]*)"|(true|false))', stripped)
        if not match or match.group(1) not in allowed:
            raise SystemExit(f"Unsupported backend.hcl line {number}; refusing ambiguous backend ownership.")
        key = match.group(1)
        if key in values:
            raise SystemExit(f"Duplicate backend.hcl key {key!r}; refusing ambiguous backend ownership.")
        values[key] = match.group(2) if match.group(2) is not None else match.group(3)
for required in ("bucket", "key", "region"):
    if not values.get(required):
        raise SystemExit(f"backend.hcl is missing required key {required!r}.")
json.dump(values, sys.stdout, sort_keys=True)
PY

backend_bucket=$(jq -er '.bucket' "${backend_json}")
backend_key=$(jq -er '.key' "${backend_json}")
backend_region=$(jq -er '.region' "${backend_json}")
project_prefix=$(printf '%s' "${PROJECT}" | cut -c1-18)
environment_prefix=$(printf '%s' "${ENVIRONMENT}" | cut -c1-10)
expected_bucket="${project_prefix}-${environment_prefix}-${account_id}-${REGION}-tfstate"
expected_key="${PROJECT}/${ENVIRONMENT}/terraform.tfstate"

[[ "${backend_bucket}" == "${expected_bucket}" ]] \
  || die "Backend bucket '${backend_bucket}' does not equal generated ownership name '${expected_bucket}'."
[[ "${backend_key}" == "${expected_key}" ]] \
  || die "Backend key '${backend_key}' does not equal expected state key '${expected_key}'."
[[ "${backend_region}" == "${REGION}" ]] \
  || die "Backend Region '${backend_region}' does not equal requested Region '${REGION}'."

log_info "Proven backend bucket name: ${backend_bucket}"
log_info "Proven Terraform state key: ${backend_key}"

log_info "Initializing the exact backend without upgrading provider selections."
terraform -chdir="${TERRAFORM_DIR}" init \
  -backend-config=backend.hcl \
  -reconfigure \
  -input=false

state_list_file="${temporary_directory}/terraform-state-addresses.txt"
terraform -chdir="${TERRAFORM_DIR}" state list >"${state_list_file}"

destroy_plan="${temporary_directory}/self-destruct.tfplan"
log_info "Creating a saved destroy plan. This phase does not delete a resource."
terraform -chdir="${TERRAFORM_DIR}" plan \
  -destroy \
  -input=false \
  -out="${destroy_plan}" \
  -var="aws_region=${REGION}" \
  -var="project_name=${PROJECT}" \
  -var="environment=${ENVIRONMENT}"

plan_json="${temporary_directory}/self-destruct-plan.json"
terraform -chdir="${TERRAFORM_DIR}" show -json "${destroy_plan}" >"${plan_json}"

# A destroy plan must not contain a create or update action. This catches drift,
# configuration accidents, or an unexpected provider interpretation before the
# operator sees a confirmation prompt.
unexpected_plan_actions=$(jq -r '
  [.resource_changes[]?
    | select(any(.change.actions[]?; . != "delete" and . != "no-op" and . != "read"))
    | "\(.address): \(.change.actions | join(","))"]
  | .[]' "${plan_json}")
if [[ -n "${unexpected_plan_actions}" ]]; then
  log_error "Destroy plan contains non-destruction actions:"
  printf '%s\n' "${unexpected_plan_actions}" >&2
  die "Refusing a self-destruct plan that could create or update resources."
fi

planned_deletions_file="${temporary_directory}/planned-deletions.txt"
jq -r '.resource_changes[]? | select(.change.actions == ["delete"]) | .address' \
  "${plan_json}" | sort >"${planned_deletions_file}"
planned_deletion_count=$(wc -l <"${planned_deletions_file}" | tr -d ' ')

inventory_timestamp=$(date -u +'%Y%m%dT%H%M%SZ')
inventory_run_id="${inventory_timestamp}-$$"
inventory_report="${WORKSPACE_LOG_ROOT}/inventory/${inventory_run_id}-${account_id}-${PROJECT}-${ENVIRONMENT}-before.json"
inventory_args=(
  --region "${REGION}"
  --project "${PROJECT}"
  --environment "${ENVIRONMENT}"
  --output "${inventory_report}"
)
[[ -n "${PROFILE}" ]] && inventory_args+=(--profile "${PROFILE}")
"${SCRIPT_DIR}/account_inventory.py" "${inventory_args[@]}" \
  || die "Account inventory was incomplete. No deletion was attempted."

verify_backend_ownership() {
  local bucket_tags_file="${temporary_directory}/backend-tags.json"
  local bucket_versioning_file="${temporary_directory}/backend-versioning.json"
  local bucket_versions_file="${temporary_directory}/backend-versions.json"
  local object_lock_file="${temporary_directory}/backend-object-lock.json"
  local object_lock_error_file="${temporary_directory}/backend-object-lock.error"
  local bucket_count
  local version_count
  local delete_marker_count

  bucket_count=$(aws "${AWS_OPTIONS[@]}" s3api list-buckets \
    --query "length(Buckets[?Name=='${backend_bucket}'])" --output text)
  [[ "${bucket_count}" == "1" ]] \
    || die "Backend bucket is not uniquely present in the authenticated account."

  aws "${AWS_OPTIONS[@]}" s3api get-bucket-tagging \
    --bucket "${backend_bucket}" \
    --expected-bucket-owner "${account_id}" \
    --output json >"${bucket_tags_file}"

  jq -e \
    --arg project "${PROJECT}" \
    --arg environment "${ENVIRONMENT}" '
      (.TagSet | map({key: .Key, value: .Value}) | from_entries) as $tags
      | $tags.Application == $project
        and $tags.Environment == $environment
        and $tags.ManagedBy == "bootstrap-backend"
        and $tags.Purpose == "terraform-state"
    ' "${bucket_tags_file}" >/dev/null \
    || die "Backend bucket ownership tags do not exactly match this workspace."

  aws "${AWS_OPTIONS[@]}" s3api get-bucket-versioning \
    --bucket "${backend_bucket}" \
    --expected-bucket-owner "${account_id}" \
    --output json >"${bucket_versioning_file}"
  [[ "$(jq -r '.Status // "Disabled"' "${bucket_versioning_file}")" == "Enabled" ]] \
    || die "Backend bucket does not have the versioning enabled by bootstrap; refusing ambiguous deletion."
  [[ "$(jq -r '.MFADelete // "Disabled"' "${bucket_versioning_file}")" != "Enabled" ]] \
    || die "Backend bucket has MFA Delete enabled. This script will not solicit or log an MFA deletion token."

  if aws "${AWS_OPTIONS[@]}" s3api get-object-lock-configuration \
    --bucket "${backend_bucket}" \
    --expected-bucket-owner "${account_id}" \
    --output json >"${object_lock_file}" 2>"${object_lock_error_file}"; then
    [[ "$(jq -r '.ObjectLockConfiguration.ObjectLockEnabled // "Disabled"' "${object_lock_file}")" != "Enabled" ]] \
      || die "Backend bucket has S3 Object Lock enabled; automatic permanent deletion is blocked."
  elif ! grep -q 'ObjectLockConfigurationNotFoundError' "${object_lock_error_file}"; then
    die "Unable to prove S3 Object Lock is disabled for the backend bucket."
  fi

  aws "${AWS_OPTIONS[@]}" s3api list-object-versions \
    --bucket "${backend_bucket}" \
    --expected-bucket-owner "${account_id}" \
    --output json >"${bucket_versions_file}"
  version_count=$(jq '(.Versions // []) | length' "${bucket_versions_file}")
  delete_marker_count=$(jq '(.DeleteMarkers // []) | length' "${bucket_versions_file}")

  log_warning "STATE BUCKET SELECTED FOR PERMANENT DELETION: ${backend_bucket}"
  log_warning "State object versions: ${version_count}; delete markers: ${delete_marker_count}."
  log_warning "Deleting this bucket removes Terraform recovery history and cannot be undone."
}

determine_service_identity() {
  if [[ -z "${SERVICE_PROFILE}" && -f "${WORKSPACE_SERVICE_PROFILE_FILE}" ]]; then
    IFS= read -r SERVICE_PROFILE <"${WORKSPACE_SERVICE_PROFILE_FILE}"
  fi
  [[ -z "${SERVICE_PROFILE}" || "${SERVICE_PROFILE}" =~ ^[A-Za-z0-9_.@+-]{1,128}$ ]] \
    || die "Saved service profile contains unsupported characters."

  if [[ -n "${SERVICE_PROFILE}" ]]; then
    service_identity=$(aws --profile "${SERVICE_PROFILE}" --region "${REGION}" \
      sts get-caller-identity --output json 2>/dev/null) \
      || die "Selected local service profile cannot identify its IAM user; refusing to remove that profile."
    service_identity_account=$(printf '%s' "${service_identity}" | jq -er '.Account')
    service_identity_arn=$(printf '%s' "${service_identity}" | jq -er '.Arn')
    [[ "${service_identity_account}" == "${account_id}" ]] \
      || die "Saved service profile belongs to account ${service_identity_account}, not ${account_id}."
    [[ "${service_identity_arn}" =~ ^arn:[^:]+:iam::${account_id}:user/[A-Za-z0-9_.@+-]{1,64}$ ]] \
      || die "Saved service profile is not the expected pathless IAM user."
    resolved_service_account_name="${service_identity_arn##*/}"
    if [[ -n "${SERVICE_ACCOUNT_NAME}" && "${SERVICE_ACCOUNT_NAME}" != "${resolved_service_account_name}" ]]; then
      die "Selected local profile resolves to IAM user '${resolved_service_account_name}', not requested '${SERVICE_ACCOUNT_NAME}'."
    fi
    SERVICE_ACCOUNT_NAME="${resolved_service_account_name}"
  fi

  [[ -n "${SERVICE_PROFILE}" ]] \
    || die "Service-account deletion requires --service-profile or a valid first-run profile marker. A user name alone is not ownership proof."
}

verify_service_account_ownership() {
  local identity_dir="${temporary_directory}/service-account"
  local user_arn
  local unexpected_count=0
  local login_profile_present=false
  local login_profile_error="${temporary_directory}/service-account-login-profile.error"

  determine_service_identity
  mkdir -p "${identity_dir}"

  aws "${AWS_OPTIONS[@]}" iam get-user --user-name "${SERVICE_ACCOUNT_NAME}" \
    --output json >"${identity_dir}/user.json"
  user_arn=$(jq -er '.User.Arn' "${identity_dir}/user.json")
  [[ "${caller_arn}" != "${user_arn}" ]] \
    || die "The cleanup caller is the service account selected for deletion. Use a different admin/root cleanup profile."

  jq -e '
    (.User.Tags | map({key: .Key, value: .Value}) | from_entries) as $tags
    | $tags.ManagedBy == "AWS-EnvBuilder"
      and $tags.Purpose == "terraform-service-account"
  ' "${identity_dir}/user.json" >/dev/null \
    || die "IAM user lacks the exact first-run ownership tags; refusing deletion."

  aws "${AWS_OPTIONS[@]}" iam list-access-keys --user-name "${SERVICE_ACCOUNT_NAME}" --output json >"${identity_dir}/access-keys.json"
  aws "${AWS_OPTIONS[@]}" iam list-user-policies --user-name "${SERVICE_ACCOUNT_NAME}" --output json >"${identity_dir}/inline-policies.json"
  aws "${AWS_OPTIONS[@]}" iam list-attached-user-policies --user-name "${SERVICE_ACCOUNT_NAME}" --output json >"${identity_dir}/attached-policies.json"
  aws "${AWS_OPTIONS[@]}" iam list-groups-for-user --user-name "${SERVICE_ACCOUNT_NAME}" --output json >"${identity_dir}/groups.json"
  aws "${AWS_OPTIONS[@]}" iam list-mfa-devices --user-name "${SERVICE_ACCOUNT_NAME}" --output json >"${identity_dir}/mfa.json"
  aws "${AWS_OPTIONS[@]}" iam list-signing-certificates --user-name "${SERVICE_ACCOUNT_NAME}" --output json >"${identity_dir}/certificates.json"
  aws "${AWS_OPTIONS[@]}" iam list-ssh-public-keys --user-name "${SERVICE_ACCOUNT_NAME}" --output json >"${identity_dir}/ssh-keys.json"
  aws "${AWS_OPTIONS[@]}" iam list-service-specific-credentials --user-name "${SERVICE_ACCOUNT_NAME}" --output json >"${identity_dir}/service-credentials.json"

  if aws "${AWS_OPTIONS[@]}" iam get-login-profile --user-name "${SERVICE_ACCOUNT_NAME}" \
    --output json >"${identity_dir}/login-profile.json" 2>"${login_profile_error}"; then
    login_profile_present=true
  elif ! grep -q 'NoSuchEntity' "${login_profile_error}"; then
    die "Unable to prove the service account has no console login profile."
  fi

  jq -e '.PolicyNames == ["AWS-EnvBuilder-ServiceAccount"]' \
    "${identity_dir}/inline-policies.json" >/dev/null || unexpected_count=$((unexpected_count + 1))
  [[ "$(jq '.AttachedPolicies | length' "${identity_dir}/attached-policies.json")" == "0" ]] || unexpected_count=$((unexpected_count + 1))
  [[ "$(jq '.Groups | length' "${identity_dir}/groups.json")" == "0" ]] || unexpected_count=$((unexpected_count + 1))
  [[ "$(jq '.MFADevices | length' "${identity_dir}/mfa.json")" == "0" ]] || unexpected_count=$((unexpected_count + 1))
  [[ "$(jq '.Certificates | length' "${identity_dir}/certificates.json")" == "0" ]] || unexpected_count=$((unexpected_count + 1))
  [[ "$(jq '.SSHPublicKeys | length' "${identity_dir}/ssh-keys.json")" == "0" ]] || unexpected_count=$((unexpected_count + 1))
  [[ "$(jq '.ServiceSpecificCredentials | length' "${identity_dir}/service-credentials.json")" == "0" ]] || unexpected_count=$((unexpected_count + 1))
  [[ "${login_profile_present}" == "false" ]] || unexpected_count=$((unexpected_count + 1))

  log_warning "IAM SERVICE ACCOUNT SELECTED FOR PERMANENT DELETION: ${user_arn}"
  log_info "Programmatic keys that would be deleted:"
  jq -r '.AccessKeyMetadata[]? | "  - \(.AccessKeyId) status=\(.Status) created=\(.CreateDate)"' \
    "${identity_dir}/access-keys.json"
  log_info "Inline policies: $(jq -c '.PolicyNames' "${identity_dir}/inline-policies.json")"
  log_info "Attached policies: $(jq -c '.AttachedPolicies' "${identity_dir}/attached-policies.json")"
  log_info "Groups: $(jq -c '.Groups' "${identity_dir}/groups.json")"
  log_info "MFA devices: $(jq -c '.MFADevices' "${identity_dir}/mfa.json")"
  log_info "Signing certificates: $(jq -c '.Certificates' "${identity_dir}/certificates.json")"
  log_info "SSH public keys: $(jq -c '.SSHPublicKeys' "${identity_dir}/ssh-keys.json")"
  log_info "Service-specific credentials: $(jq -c '.ServiceSpecificCredentials' "${identity_dir}/service-credentials.json")"
  log_info "Console login profile present: ${login_profile_present}"

  [[ "${unexpected_count}" -eq 0 ]] \
    || die "IAM user has credentials, membership, or policies outside the exact bootstrap shape. Refusing automatic deletion."
}

verify_service_account_delete_permissions() {
  local policy_source_arn="${caller_arn}"
  local role_and_session=""
  local role_name=""
  local simulation_file="${temporary_directory}/service-account-delete-simulation.json"
  local evaluation_count
  local denied_actions
  local -a cleanup_actions=(
    "iam:DeleteAccessKey"
    "iam:DeleteUserPolicy"
    "iam:DeleteUser"
  )

  # IAM does not simulate the account-root identity. The explicit root override
  # already makes that exceptional limitation visible; the real read calls and
  # exact confirmation still run before root is allowed to delete anything.
  if is_aws_root_arn "${caller_arn}"; then
    log_warning "Root cannot be evaluated by IAM's policy simulator; service-account deletion permissions were not simulated."
    return 0
  fi

  # SimulatePrincipalPolicy accepts an IAM user/role ARN, not an STS assumed-role
  # session ARN. Resolve an assumed session to the IAM role that owns it.
  if [[ "${caller_arn}" == *":assumed-role/"* ]]; then
    role_and_session="${caller_arn#*:assumed-role/}"
    role_name="${role_and_session%%/*}"
    policy_source_arn=$(aws "${AWS_OPTIONS[@]}" iam get-role \
      --role-name "${role_name}" --query 'Role.Arn' --output text 2>/dev/null || true)
  fi
  [[ -n "${policy_source_arn}" && "${policy_source_arn}" != *":federated-user/"* ]] \
    || die "Service-account deletion requires a cleanup IAM user or assumed role whose delete permissions can be simulated."

  aws "${AWS_OPTIONS[@]}" iam simulate-principal-policy \
    --policy-source-arn "${policy_source_arn}" \
    --action-names "${cleanup_actions[@]}" \
    --output json >"${simulation_file}" \
    || die "Unable to simulate the cleanup caller's IAM user-deletion permissions."

  evaluation_count=$(jq '.EvaluationResults | length' "${simulation_file}")
  [[ "${evaluation_count}" -eq "${#cleanup_actions[@]}" ]] \
    || die "IAM returned an incomplete service-account deletion permission simulation."
  denied_actions=$(jq -r \
    '.EvaluationResults[] | select(.EvalDecision != "allowed") | "\(.EvalActionName): \(.EvalDecision)"' \
    "${simulation_file}")
  if [[ -n "${denied_actions}" ]]; then
    log_error "Cleanup caller is not permitted to complete these IAM deletions:"
    printf '%s\n' "${denied_actions}" >&2
    die "Service-account deletion permission proof failed. Runtime resources were not deleted."
  fi

  log_info "IAM simulation allowed the three service-account deletion actions."
}

if [[ "${DELETE_STATE_BUCKET}" == "true" ]]; then
  verify_backend_ownership
fi
if [[ "${DELETE_SERVICE_ACCOUNT}" == "true" ]]; then
  verify_service_account_ownership
  verify_service_account_delete_permissions
fi

manifest_report="${WORKSPACE_LOG_ROOT}/inventory/${inventory_run_id}-${account_id}-${PROJECT}-${ENVIRONMENT}-deletion-manifest.json"
state_action="KEEP"
service_action="KEEP"
[[ "${DELETE_STATE_BUCKET}" == "true" ]] && state_action="DELETE"
[[ "${DELETE_SERVICE_ACCOUNT}" == "true" ]] && service_action="DELETE"

# Store a redacted, long-retention manifest in addition to the terminal
# transcript. It contains identifiers/actions only—never Terraform values,
# policies, access-key secrets, or other credential material.
python3 - \
  "${manifest_report}" \
  "${account_id}" \
  "${caller_arn}" \
  "${REGION}" \
  "${PROJECT}" \
  "${ENVIRONMENT}" \
  "${MODE}" \
  "${planned_deletions_file}" \
  "${backend_bucket}" \
  "${state_action}" \
  "${SERVICE_ACCOUNT_NAME}" \
  "${service_action}" \
  "${SERVICE_PROFILE}" \
  "${inventory_report}" <<'PY'
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import sys
import tempfile

(
    destination_text,
    account_id,
    caller_arn,
    region,
    project,
    environment,
    mode,
    deletion_list_path,
    backend_bucket,
    state_action,
    service_account,
    service_action,
    service_profile,
    inventory_report,
) = sys.argv[1:]

with open(deletion_list_path, "r", encoding="utf-8") as source:
    terraform_addresses = [line.strip() for line in source if line.strip()]

manifest = {
    "schema_version": 1,
    "generated_at": datetime.now(timezone.utc).isoformat(),
    "mode": mode,
    "account_id": account_id,
    "caller_arn": caller_arn,
    "region": region,
    "project": project,
    "environment": environment,
    "before_inventory": inventory_report,
    "terraform": {"action": "DELETE_AFTER_CONFIRMATION", "addresses": terraform_addresses},
    "state_bucket": {"action": state_action, "name": backend_bucket},
    "service_account": {
        "action": service_action,
        "name": service_account or None,
        "local_profile": service_profile or None,
    },
    "unrelated_assets": {"action": "NEVER_AUTO_DELETE"},
    "required_confirmation": f"SELF DESTRUCT {account_id} {project} {environment}",
}

destination = Path(destination_text)
destination.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
descriptor, temporary_name = tempfile.mkstemp(prefix=".deletion-manifest-", dir=destination.parent)
try:
    with os.fdopen(descriptor, "w", encoding="utf-8") as output:
        json.dump(manifest, output, indent=2, sort_keys=True)
        output.write("\n")
        output.flush()
        os.fsync(output.fileno())
    os.chmod(temporary_name, 0o600)
    os.replace(temporary_name, destination)
except BaseException:
    try:
        os.unlink(temporary_name)
    except FileNotFoundError:
        pass
    raise
PY

printf '\n\033[1;31m'
printf '%s\n' '!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!'
printf '%s\n' '!! SELF-DESTRUCT CAN PERMANENTLY DELETE COMPUTE, NETWORKS, LOGS, IMAGES,     !!'
printf '%s\n' '!! COST BUDGETS, TERRAFORM HISTORY, AND THE BOOTSTRAP IAM USER.              !!'
printf '%s\n' '!! THERE IS NO UNDO. UNRELATED ASSETS ARE INVENTORIED BUT NEVER AUTO-DELETED.!!'
printf '%s\n' '!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!'
printf '\033[0m\n'

printf '\n%s\n' '=============================================================================='
printf '%s\n' 'PROPOSED AWS-ENVBUILDER DELETION MANIFEST'
printf '%s\n' '=============================================================================='
printf 'Account:             %s\n' "${account_id}"
printf 'Region:              %s\n' "${REGION}"
printf 'Project/environment: %s/%s\n' "${PROJECT}" "${ENVIRONMENT}"
printf 'Terraform deletes:   %s managed resource address(es)\n' "${planned_deletion_count}"
sed 's/^/  - /' "${planned_deletions_file}"
printf 'State bucket:        %s\n' "$([[ "${DELETE_STATE_BUCKET}" == "true" ]] && printf 'DELETE %s' "${backend_bucket}" || printf 'KEEP %s' "${backend_bucket}")"
if [[ "${DELETE_SERVICE_ACCOUNT}" == "true" ]]; then
  printf 'Service account:     DELETE %s\n' "${SERVICE_ACCOUNT_NAME}"
  if [[ -n "${SERVICE_PROFILE}" ]]; then
    printf 'Local AWS profile:   DELETE section %s\n' "${SERVICE_PROFILE}"
  fi
else
  printf '%s\n' 'Service account:     KEEP'
fi
printf '%s\n' 'Unrelated assets:    LISTED IN INVENTORY; NEVER AUTO-DELETED'
printf 'Retained manifest:   %s\n' "${manifest_report}"
printf '%s\n\n' '=============================================================================='

log_info "Displaying the exact saved Terraform destroy plan."
terraform -chdir="${TERRAFORM_DIR}" show -no-color "${destroy_plan}"

if [[ "${MODE}" == "review" ]]; then
  log_info "REVIEW-ONLY COMPLETE. No Terraform plan was applied and no AWS resource was deleted."
  log_info "Retained account inventory: ${inventory_report}"
  log_info "Retained deletion manifest: ${manifest_report}"
  log_warning "To execute after independent review, rerun with --execute and --expected-account ${account_id}."
  exit 0
fi

confirmation_phrase="SELF DESTRUCT ${account_id} ${PROJECT} ${ENVIRONMENT}"
require_exact_confirmation \
  "${confirmation_phrase}" \
  "This applies only the displayed Terraform destroy plan, then performs only the explicitly selected state/user cleanup. There is no undo."

log_warning "Applying the exact reviewed Terraform destroy plan now."
terraform -chdir="${TERRAFORM_DIR}" apply -input=false "${destroy_plan}"

remaining_state_json="${temporary_directory}/remaining-state.json"
remaining_managed_file="${temporary_directory}/remaining-managed-addresses.txt"
terraform -chdir="${TERRAFORM_DIR}" show -json >"${remaining_state_json}"

# Terraform may legitimately retain read-only data-source records after a full
# destroy. Inspect state modes instead of requiring `terraform state list` to be
# literally empty; only a remaining managed object can represent unfinished
# infrastructure and must block backend/identity removal.
jq -r '
  [.values.root_module
    | recurse(.child_modules[]?)
    | .resources[]?
    | select(.mode == "managed")
    | .address]
  | .[]' "${remaining_state_json}" >"${remaining_managed_file}"
if [[ -s "${remaining_managed_file}" ]]; then
  log_error "Terraform state still contains managed resources after the destroy apply:"
  sed 's/^/  - /' "${remaining_managed_file}" >&2
  die "Runtime teardown was incomplete. State bucket and service account were kept for recovery."
fi
log_info "Terraform state contains no remaining managed runtime resources."

delete_versioned_backend_bucket() {
  local page_file="${temporary_directory}/backend-page.json"
  local delete_file="${temporary_directory}/backend-delete.json"
  local delete_response_file="${temporary_directory}/backend-delete-response.json"
  local page_count=0
  local object_count

  # Repeatedly delete the first at-most-1000 versions/markers. Starting over is
  # robust when the prior page's marker was itself just deleted.
  while true; do
    aws "${AWS_OPTIONS[@]}" s3api list-object-versions \
      --bucket "${backend_bucket}" \
      --expected-bucket-owner "${account_id}" \
      --max-keys 1000 \
      --no-paginate \
      --output json >"${page_file}"
    jq '{Objects: (((.Versions // []) + (.DeleteMarkers // [])) | map({Key, VersionId})), Quiet: true}' \
      "${page_file}" >"${delete_file}"
    object_count=$(jq '.Objects | length' "${delete_file}")
    [[ "${object_count}" -gt 0 ]] || break

    page_count=$((page_count + 1))
    [[ "${page_count}" -le 10000 ]] \
      || die "Backend deletion exceeded 10,000 batches; stopping to prevent an infinite loop."
    log_warning "Permanently deleting backend version batch ${page_count} (${object_count} object versions/markers)."
    aws "${AWS_OPTIONS[@]}" s3api delete-objects \
      --bucket "${backend_bucket}" \
      --expected-bucket-owner "${account_id}" \
      --delete "file://${delete_file}" \
      --output json >"${delete_response_file}"
    [[ "$(jq '(.Errors // []) | length' "${delete_response_file}")" == "0" ]] \
      || die "S3 reported one or more failed object-version deletions; backend bucket was kept."
  done

  aws "${AWS_OPTIONS[@]}" s3api delete-bucket \
    --bucket "${backend_bucket}" \
    --expected-bucket-owner "${account_id}"
  rm -f -- "${TERRAFORM_DIR}/backend.hcl"
  log_warning "Permanently deleted state bucket ${backend_bucket} and removed local backend.hcl."
}

delete_bootstrap_service_account() {
  local identity_dir="${temporary_directory}/service-account"
  local access_key_id
  local policy_name

  while IFS= read -r access_key_id; do
    [[ -n "${access_key_id}" ]] || continue
    aws "${AWS_OPTIONS[@]}" iam delete-access-key \
      --user-name "${SERVICE_ACCOUNT_NAME}" \
      --access-key-id "${access_key_id}"
  done < <(jq -r '.AccessKeyMetadata[]?.AccessKeyId' "${identity_dir}/access-keys.json")

  while IFS= read -r policy_name; do
    [[ -n "${policy_name}" ]] || continue
    aws "${AWS_OPTIONS[@]}" iam delete-user-policy \
      --user-name "${SERVICE_ACCOUNT_NAME}" \
      --policy-name "${policy_name}"
  done < <(jq -r '.PolicyNames[]?' "${identity_dir}/inline-policies.json")

  aws "${AWS_OPTIONS[@]}" iam delete-user --user-name "${SERVICE_ACCOUNT_NAME}"
  log_warning "Permanently deleted IAM service account ${SERVICE_ACCOUNT_NAME}."

  if [[ -n "${SERVICE_PROFILE}" ]]; then
    remove_aws_cli_profile_sections "${SERVICE_PROFILE}"
    log_warning "Removed local AWS credentials/config sections for profile ${SERVICE_PROFILE}."
  fi
  if [[ -f "${WORKSPACE_SERVICE_PROFILE_FILE}" ]]; then
    marker_profile=""
    IFS= read -r marker_profile <"${WORKSPACE_SERVICE_PROFILE_FILE}"
    if [[ -n "${SERVICE_PROFILE}" && "${marker_profile}" == "${SERVICE_PROFILE}" ]]; then
      rm -f -- "${WORKSPACE_SERVICE_PROFILE_FILE}"
      log_warning "Removed the local first-run service-profile marker."
    else
      log_warning "Kept the local first-run marker because it does not match the deleted profile."
    fi
  fi
}

if [[ "${DELETE_STATE_BUCKET}" == "true" ]]; then
  delete_versioned_backend_bucket
fi
if [[ "${DELETE_SERVICE_ACCOUNT}" == "true" ]]; then
  delete_bootstrap_service_account
fi

after_timestamp=$(date -u +'%Y%m%dT%H%M%SZ')
after_report="${WORKSPACE_LOG_ROOT}/inventory/${after_timestamp}-$$-${account_id}-${PROJECT}-${ENVIRONMENT}-after.json"
after_inventory_args=(
  --region "${REGION}"
  --project "${PROJECT}"
  --environment "${ENVIRONMENT}"
  --output "${after_report}"
)
[[ -n "${PROFILE}" ]] && after_inventory_args+=(--profile "${PROFILE}")

if "${SCRIPT_DIR}/account_inventory.py" "${after_inventory_args[@]}"; then
  survivor_count=$(jq '.sections.ownership_tag_matches | length' "${after_report}")
  if [[ "${DELETE_STATE_BUCKET}" != "true" ]]; then
    survivor_count=$(jq --arg backend_arn "arn:aws:s3:::${backend_bucket}" \
      '[.sections.ownership_tag_matches[] | select(.ResourceARN != $backend_arn)] | length' \
      "${after_report}")
  fi
  if [[ "${survivor_count}" -gt 0 ]]; then
    log_warning "Post-delete inventory still reports ${survivor_count} ownership-tag match(es)."
    log_warning "AWS inventory can be eventually consistent. Review the retained after-report; nothing else will be auto-deleted."
  else
    log_info "Post-delete inventory reports no unexpected current ownership-tag matches."
  fi
else
  log_warning "Post-delete inventory was incomplete. Review AWS manually using docs/SELF_DESTRUCT.md."
fi

log_warning "SELF-DESTRUCT SEQUENCE COMPLETED FOR ${account_id} ${PROJECT}/${ENVIRONMENT}."
log_info "Before inventory: ${inventory_report}"
log_info "After inventory: ${after_report}"
log_info "Deletion manifest: ${manifest_report}"
log_warning "Billing data is delayed. Recheck Billing, Free Tier, EC2, ELB, EBS, public IPv4, ECR, Logs, Budgets, S3, and IAM tomorrow."
