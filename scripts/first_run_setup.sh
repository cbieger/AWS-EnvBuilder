#!/usr/bin/env bash
# One-time AWS account bootstrap. This deliberately requires the AWS account
# root identity, creates a dedicated IAM automation user, stores that user's
# access key in the standard local AWS credentials file without displaying it,
# and records the new AWS CLI profile as this workspace's default.

set -Eeuo pipefail
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

ROOT_PROFILE=""
REGION="us-west-2"
SERVICE_ACCOUNT_NAME=""
SERVICE_PROFILE=""

usage() {
  cat <<'USAGE'
Usage: ./scripts/first_run_setup.sh [options]

Options:
  --root-profile NAME       AWS CLI profile authenticated as AWS account root.
  --region REGION           Default deployment Region (default: us-west-2).
  --service-account NAME    IAM user name; omitted means prompt interactively.
  --service-profile NAME    Local AWS CLI profile; defaults to the IAM user name.
  --help                    Show this explanation.

"Root" means the AWS account root identity shown by STS. It does not mean the
macOS/Linux root account, and this script must not be run with sudo merely to
satisfy the check.

Preferred root bootstrap login (temporary browser credentials):
  aws login --profile aws-root-bootstrap
  ./scripts/first_run_setup.sh --root-profile aws-root-bootstrap

The script creates one IAM user and one long-term programmatic access key. AWS
recommends roles or IAM Identity Center whenever those options are practical.
The key is never printed or logged; it is written with restrictive permissions
to the standard AWS shared credentials file.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --root-profile)
      [[ $# -ge 2 ]] || die "--root-profile requires a value."
      ROOT_PROFILE="$2"
      shift 2
      ;;
    --region)
      [[ $# -ge 2 ]] || die "--region requires a value."
      REGION="$2"
      shift 2
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
    --help|-h)
      usage
      exit 0
      ;;
    *)
      die "Unknown first-run option: $1"
      ;;
  esac
done

[[ "${REGION}" =~ ^[a-z]{2}(-gov)?-[a-z]+-[0-9]$ ]] \
  || die "--region must look like us-west-2."
[[ -z "${ROOT_PROFILE}" || "${ROOT_PROFILE}" =~ ^[A-Za-z0-9_.@+-]{1,128}$ ]] \
  || die "--root-profile contains unsupported characters."

begin_logged_run "first-run-setup"

require_command aws "Install AWS CLI v2 using docs/WORKSTATION_SETUP.md."
require_command jq "Install jq 1.6 or newer using docs/WORKSTATION_SETUP.md."
require_command python3 "Install Python 3.9 or newer using docs/WORKSTATION_SETUP.md."

ROOT_AWS_OPTIONS=(--region "${REGION}")
if [[ -n "${ROOT_PROFILE}" ]]; then
  ROOT_AWS_OPTIONS+=(--profile "${ROOT_PROFILE}")
fi

bootstrap_secret_file=""
bootstrap_policy_file=""
created_user=false
created_access_key_id=""
credential_profile_written=false
bootstrap_complete=false

# Remove only the profile sections created by this run while preserving every
# other profile, comment, and line in the operator's shared AWS files. AWS CLI
# has no `configure unset` command, so rollback performs this narrowly scoped
# edit itself.
remove_local_service_profile() {
  local credentials_path="${AWS_SHARED_CREDENTIALS_FILE:-${HOME}/.aws/credentials}"
  local config_path="${AWS_CONFIG_FILE:-${HOME}/.aws/config}"

  python3 - "${SERVICE_PROFILE}" "${credentials_path}" "${config_path}" <<'PY'
import os
import re
import sys
import tempfile

profile_name, credentials_path, config_path = sys.argv[1:]


def remove_section(path, section_name):
    """Remove one exact INI section without reformatting unrelated content."""
    path = os.path.abspath(os.path.expanduser(path))
    if not os.path.exists(path):
        return

    with open(path, "r", encoding="utf-8") as source:
        lines = source.readlines()

    header = f"[{section_name}]"
    kept = []
    removing = False
    found = False
    for line in lines:
        stripped = line.strip()
        if re.fullmatch(r"\[[^]]+\]", stripped):
            removing = stripped == header
            found = found or removing
        if not removing:
            kept.append(line)

    if not found:
        return

    directory = os.path.dirname(path)
    descriptor, temporary_path = tempfile.mkstemp(prefix=".aws-envbuilder-rollback-", dir=directory)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as output:
            output.writelines(kept)
        os.chmod(temporary_path, 0o600)
        os.replace(temporary_path, path)
    except BaseException:
        try:
            os.unlink(temporary_path)
        except FileNotFoundError:
            pass
        raise


remove_section(credentials_path, profile_name)
remove_section(config_path, f"profile {profile_name}")
PY
}

# If a failure happens after an AWS write, remove only the user/key/policy that
# this exact run created. This prevents a half-configured privileged identity.
finish_first_run() {
  local exit_code="$?"
  trap - EXIT
  set +e

  [[ -z "${bootstrap_secret_file}" ]] || rm -f -- "${bootstrap_secret_file}"
  [[ -z "${bootstrap_policy_file}" ]] || rm -f -- "${bootstrap_policy_file}"

  if [[ "${exit_code}" -ne 0 && "${bootstrap_complete}" != "true" ]]; then
    log_warning "First-run setup failed; attempting rollback of only resources created by this run."
    if [[ "${created_user}" == "true" ]]; then
      # The user name was proven absent before this run created it, so every
      # key now attached to that new user belongs to this failed transaction.
      # Listing also handles the rare case where AWS created a key but the CLI
      # connection failed before returning its ID.
      rollback_access_key_ids=""
      if rollback_access_key_ids=$(aws "${ROOT_AWS_OPTIONS[@]}" iam list-access-keys \
        --user-name "${SERVICE_ACCOUNT_NAME}" \
        --query 'AccessKeyMetadata[].AccessKeyId' \
        --output text 2>/dev/null); then
        for rollback_access_key_id in ${rollback_access_key_ids}; do
          if ! aws "${ROOT_AWS_OPTIONS[@]}" iam delete-access-key \
            --user-name "${SERVICE_ACCOUNT_NAME}" \
            --access-key-id "${rollback_access_key_id}" >/dev/null 2>&1; then
            log_warning "Rollback could not delete access key ${rollback_access_key_id}; remove it immediately in IAM."
          fi
        done
      elif [[ -n "${created_access_key_id}" ]]; then
        if ! aws "${ROOT_AWS_OPTIONS[@]}" iam delete-access-key \
          --user-name "${SERVICE_ACCOUNT_NAME}" \
          --access-key-id "${created_access_key_id}" >/dev/null 2>&1; then
          log_warning "Rollback could not delete the known access key; remove it immediately in IAM."
        fi
      else
        log_warning "Rollback could not list access keys; inspect the failed IAM user immediately."
      fi

      aws "${ROOT_AWS_OPTIONS[@]}" iam delete-user-policy \
        --user-name "${SERVICE_ACCOUNT_NAME}" \
        --policy-name "AWS-EnvBuilder-ServiceAccount" >/dev/null 2>&1 || true
      if ! aws "${ROOT_AWS_OPTIONS[@]}" iam delete-user \
        --user-name "${SERVICE_ACCOUNT_NAME}" >/dev/null 2>&1; then
        log_warning "Rollback could not delete IAM user '${SERVICE_ACCOUNT_NAME}'; audit and remove it before retrying."
      fi
    fi
    if [[ "${credential_profile_written}" == "true" ]]; then
      remove_local_service_profile >/dev/null 2>&1 || \
        log_warning "Automatic local-profile cleanup failed; inspect the AWS shared credentials and config files."
    fi
  fi

  _finish_logged_run "${exit_code}"
}
trap finish_first_run EXIT

identity_file=$(mktemp "${TMPDIR:-/tmp}/aws-envbuilder-root-identity.XXXXXX")
if ! aws "${ROOT_AWS_OPTIONS[@]}" sts get-caller-identity --output json >"${identity_file}" 2>/dev/null; then
  rm -f -- "${identity_file}"
  die "No usable AWS root login. Run 'aws login --profile aws-root-bootstrap', sign in as AWS account root, and rerun with --root-profile aws-root-bootstrap."
fi

account_id=$(jq -r '.Account' "${identity_file}")
caller_arn=$(jq -r '.Arn' "${identity_file}")
rm -f -- "${identity_file}"
require_aws_root_identity "${caller_arn}"

log_warning "AWS ACCOUNT ROOT VERIFIED FOR ONE-TIME BOOTSTRAP: ${account_id}."
log_warning "Do not use sudo. Do not continue using AWS root after this script succeeds."

if [[ -f "${WORKSPACE_SERVICE_PROFILE_FILE}" ]]; then
  existing_profile=$(resolve_aws_profile "")
  die "First-run marker already exists for profile '${existing_profile}'. Remove it only after auditing the existing IAM user and credentials."
fi

if [[ -z "${SERVICE_ACCOUNT_NAME}" ]]; then
  if [[ -r /dev/tty ]]; then
    printf '%s\n> ' "Enter a new IAM service-account name (example: aws-envbuilder-automation):"
    IFS= read -r SERVICE_ACCOUNT_NAME </dev/tty
  else
    die "No interactive terminal is available. Supply --service-account NAME."
  fi
fi

# Use the conservative subset shared by IAM user names and AWS CLI profile
# names. Avoiding exotic valid IAM punctuation keeps the default local-profile
# handoff unambiguous across supported AWS CLI versions.
[[ "${SERVICE_ACCOUNT_NAME}" =~ ^[A-Za-z0-9_.@+-]{1,64}$ ]] \
  || die "Service-account name must be 1-64 letters, digits, dots, underscores, @, +, or hyphens."

if [[ -z "${SERVICE_PROFILE}" ]]; then
  SERVICE_PROFILE="${SERVICE_ACCOUNT_NAME}"
fi
[[ "${SERVICE_PROFILE}" =~ ^[A-Za-z0-9_.@+-]{1,128}$ ]] \
  || die "Service profile must contain only letters, digits, dots, underscores, @, +, or hyphens."
[[ "${SERVICE_PROFILE}" != "default" ]] \
  || die "The service profile cannot be named 'default'; use a distinct, recognizable profile name."

if aws configure list-profiles | grep -Fxq "${SERVICE_PROFILE}"; then
  die "Local AWS profile '${SERVICE_PROFILE}' already exists. Choose a new --service-profile or audit/remove the existing profile first."
fi

user_lookup_error=$(mktemp "${TMPDIR:-/tmp}/aws-envbuilder-user-lookup.XXXXXX")
if aws "${ROOT_AWS_OPTIONS[@]}" iam get-user \
  --user-name "${SERVICE_ACCOUNT_NAME}" >/dev/null 2>"${user_lookup_error}"; then
  rm -f -- "${user_lookup_error}"
  die "IAM user '${SERVICE_ACCOUNT_NAME}' already exists. This bootstrap will not modify an identity it did not create."
elif ! grep -q 'NoSuchEntity' "${user_lookup_error}"; then
  lookup_message=$(tr '\n' ' ' <"${user_lookup_error}")
  rm -f -- "${user_lookup_error}"
  die "Unable to prove the requested IAM user name is unused: ${lookup_message}"
fi
rm -f -- "${user_lookup_error}"

log_info "Proposed AWS account: ${account_id}"
log_info "Proposed IAM user: ${SERVICE_ACCOUNT_NAME}"
log_info "Proposed local AWS CLI profile: ${SERVICE_PROFILE}"
log_warning "This IAM user can manage the infrastructure action families documented in docs/PERMISSIONS.md."
log_warning "Its long-term key must be protected and rotated. Prefer IAM Identity Center or a role when available."
require_exact_confirmation \
  "CREATE AWS SERVICE ACCOUNT" \
  "This creates a powerful IAM user, attaches an inline deployment policy, and stores one new access key locally."

aws "${ROOT_AWS_OPTIONS[@]}" iam create-user \
  --user-name "${SERVICE_ACCOUNT_NAME}" \
  --tags \
    Key=ManagedBy,Value=AWS-EnvBuilder \
    Key=Purpose,Value=terraform-service-account >/dev/null
created_user=true

umask 077
bootstrap_policy_file=$(mktemp "${TMPDIR:-/tmp}/aws-envbuilder-policy.XXXXXX")
"${SCRIPT_DIR}/permissions.sh" --print-service-policy >"${bootstrap_policy_file}"

aws "${ROOT_AWS_OPTIONS[@]}" iam put-user-policy \
  --user-name "${SERVICE_ACCOUNT_NAME}" \
  --policy-name "AWS-EnvBuilder-ServiceAccount" \
  --policy-document "file://${bootstrap_policy_file}"

bootstrap_secret_file=$(mktemp "${TMPDIR:-/tmp}/aws-envbuilder-access-key.XXXXXX")
aws "${ROOT_AWS_OPTIONS[@]}" iam create-access-key \
  --user-name "${SERVICE_ACCOUNT_NAME}" \
  --output json >"${bootstrap_secret_file}"
created_access_key_id=$(jq -er '.AccessKey.AccessKeyId' "${bootstrap_secret_file}") \
  || die "AWS created an access key but returned no access-key ID. Rollback will be attempted."
jq -e '.AccessKey.SecretAccessKey | type == "string" and length > 0' \
  "${bootstrap_secret_file}" >/dev/null \
  || die "AWS created an access key but returned no secret. Rollback will be attempted."

credentials_file="${AWS_SHARED_CREDENTIALS_FILE:-${HOME}/.aws/credentials}"
python3 - "${bootstrap_secret_file}" "${SERVICE_PROFILE}" "${credentials_file}" <<'PY'
import configparser
import json
import os
import sys
import tempfile

secret_path, profile_name, destination = sys.argv[1:]
destination = os.path.abspath(os.path.expanduser(destination))
directory = os.path.dirname(destination)
os.makedirs(directory, mode=0o700, exist_ok=True)

parser = configparser.RawConfigParser()
if os.path.exists(destination):
    parser.read(destination, encoding="utf-8")
if parser.has_section(profile_name):
    raise SystemExit(f"Credentials file already contains profile {profile_name!r}; refusing to overwrite it.")

with open(secret_path, "r", encoding="utf-8") as source:
    access_key = json.load(source)["AccessKey"]

# Replace the file atomically so an interruption cannot leave half a key/profile
# block. Existing bytes are preserved exactly; only a final newline and the new
# section are added.
existing_content = b""
if os.path.exists(destination):
    with open(destination, "rb") as existing:
        existing_content = existing.read()

new_section = (
    f"[{profile_name}]\n"
    f"aws_access_key_id = {access_key['AccessKeyId']}\n"
    f"aws_secret_access_key = {access_key['SecretAccessKey']}\n"
).encode("utf-8")

descriptor, temporary_path = tempfile.mkstemp(prefix=".aws-envbuilder-credentials-", dir=directory)
try:
    with os.fdopen(descriptor, "wb") as output:
        output.write(existing_content)
        if existing_content and not existing_content.endswith(b"\n"):
            output.write(b"\n")
        output.write(new_section)
        output.flush()
        os.fsync(output.fileno())
    os.chmod(temporary_path, 0o600)
    os.replace(temporary_path, destination)
except BaseException:
    try:
        os.unlink(temporary_path)
    except FileNotFoundError:
        pass
    raise
PY
credential_profile_written=true

# Region and output are non-secret and belong in the standard AWS config file.
aws configure set region "${REGION}" --profile "${SERVICE_PROFILE}"
aws configure set output json --profile "${SERVICE_PROFILE}"

rm -f -- "${bootstrap_secret_file}"
bootstrap_secret_file=""

service_identity_file=$(mktemp "${TMPDIR:-/tmp}/aws-envbuilder-service-identity.XXXXXX")
if ! aws --profile "${SERVICE_PROFILE}" --region "${REGION}" \
  sts get-caller-identity --output json >"${service_identity_file}"; then
  rm -f -- "${service_identity_file}"
  die "The new local profile could not authenticate. Rollback will be attempted."
fi
service_arn=$(jq -r '.Arn' "${service_identity_file}")
service_account_id=$(jq -r '.Account' "${service_identity_file}")
rm -f -- "${service_identity_file}"

expected_service_arn="arn:aws:iam::${account_id}:user/${SERVICE_ACCOUNT_NAME}"
[[ "${service_account_id}" == "${account_id}" && "${service_arn}" == "${expected_service_arn}" ]] \
  || die "New profile resolved to unexpected identity '${service_arn}'. Rollback will be attempted."

# Run the full read-only proof before making this profile the workspace default.
"${SCRIPT_DIR}/preflight.sh" \
  --profile "${SERVICE_PROFILE}" \
  --region "${REGION}" \
  --strict

mkdir -p "$(dirname "${WORKSPACE_SERVICE_PROFILE_FILE}")"
umask 077
printf '%s\n' "${SERVICE_PROFILE}" >"${WORKSPACE_SERVICE_PROFILE_FILE}"

bootstrap_complete=true
log_info "First-run setup completed for ${service_arn}."
log_info "Future workspace commands default to AWS CLI profile '${SERVICE_PROFILE}'."
if [[ -n "${ROOT_PROFILE}" ]]; then
  log_warning "End the root session now. If it used browser login, run: aws logout --profile ${ROOT_PROFILE}"
else
  log_warning "End the root session now. If it used browser login, run: aws logout"
fi
log_warning "If a root access key exists, replace root usage and remove that key through the AWS security-credentials page."
