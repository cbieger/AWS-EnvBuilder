#!/usr/bin/env bash
# Read-only workstation, login, Region, and IAM readiness checks.

set -Eeuo pipefail
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

PROFILE=""
REGION="us-west-2"
STRICT=false
SKIP_PERMISSIONS=false
ALLOW_CLI_DRIFT=false

usage() {
  cat <<'USAGE'
Usage: ./scripts/preflight.sh [options]

Options:
  --profile NAME       AWS CLI profile to test. Omit to use the default chain.
  --region REGION      AWS Region to inspect (default: us-west-2).
  --strict             Fail if latest-version or permission proof is unavailable.
  --allow-cli-drift    With --strict, warn rather than block emergency teardown
                       solely because a newer AWS CLI patch exists.
  --skip-permissions   Skip IAM policy simulation; useful only for local diagnosis.
  --help               Show this explanation.

This script performs no AWS create, update, or delete request.
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
    --skip-permissions)
      SKIP_PERMISSIONS=true
      shift
      ;;
    --allow-cli-drift)
      ALLOW_CLI_DRIFT=true
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      die "Unknown preflight option: $1"
      ;;
  esac
done

begin_logged_run "preflight"

failures=0
warnings=0

check_program() {
  local program="$1"
  local installation_hint="$2"

  if require_command "${program}" "${installation_hint}"; then
    log_info "Found ${program}: $(command -v "${program}")"
  else
    failures=$((failures + 1))
  fi
}

check_program "aws" "Install AWS CLI v2 using docs/WORKSTATION_SETUP.md."
check_program "terraform" "Install Terraform 1.10 or newer using docs/WORKSTATION_SETUP.md."
check_program "python3" "Install Python 3.9 or newer using docs/WORKSTATION_SETUP.md."
check_program "jq" "Install jq 1.6 or newer using docs/WORKSTATION_SETUP.md."
check_program "curl" "Install curl so current AWS CLI releases can be checked."

if [[ "${failures}" -gt 0 ]]; then
  die "${failures} required workstation program(s) are missing."
fi

aws_version=$(aws --version 2>&1 | sed -E 's#^aws-cli/([^ ]+).*#\1#')
terraform_version=$(terraform version -json | jq -r '.terraform_version')
python_version=$(python3 -c 'import platform; print(platform.python_version())')
jq_version=$(jq --version | sed 's/^jq-//')

log_info "AWS CLI version: ${aws_version}"
log_info "Terraform version: ${terraform_version}"
log_info "Python version: ${python_version}"
log_info "jq version: ${jq_version}"

# Python is already a required dependency, so use its numeric version comparison
# instead of platform-specific `sort -V` behavior.
if ! python3 - "${terraform_version}" "1.10.0" <<'PY'
import sys

def parts(value):
    return tuple(int(piece) for piece in value.split(".")[:3])

raise SystemExit(0 if parts(sys.argv[1]) >= parts(sys.argv[2]) else 1)
PY
then
  log_error "Terraform ${terraform_version} is too old; version 1.10.0 or newer is required."
  failures=$((failures + 1))
fi

if ! python3 - "${python_version}" "3.9.0" <<'PY'
import sys

def parts(value):
    return tuple(int(piece) for piece in value.split(".")[:3])

raise SystemExit(0 if parts(sys.argv[1]) >= parts(sys.argv[2]) else 1)
PY
then
  log_error "Python ${python_version} is too old; version 3.9.0 or newer is required."
  failures=$((failures + 1))
fi

# AWS publishes the newest v2 number at the top of its official v2 changelog.
# A strict deployment refuses an unverifiable or outdated CLI; an ordinary
# diagnostic preflight records a warning so an offline developer can continue.
latest_aws_version=""
if latest_aws_version=$(curl -fsSL --max-time 15 \
  https://raw.githubusercontent.com/aws/aws-cli/v2/CHANGELOG.rst \
  | awk '!found && /^[0-9]+\.[0-9]+\.[0-9]+$/ { print; found = 1 }'); then
  if [[ -z "${latest_aws_version}" ]]; then
    log_warning "The official AWS CLI changelog was reachable but no version could be parsed."
    warnings=$((warnings + 1))
  elif [[ "${aws_version}" != "${latest_aws_version}" ]]; then
    log_warning "Installed AWS CLI is ${aws_version}; the official changelog starts with ${latest_aws_version}."
    log_warning "Update it using docs/WORKSTATION_SETUP.md before deployment."
    warnings=$((warnings + 1))
  else
    log_info "AWS CLI matches the latest official v2 changelog release (${latest_aws_version})."
  fi
else
  log_warning "Could not reach the official AWS CLI changelog to prove the installed CLI is current."
  warnings=$((warnings + 1))
fi

AWS_OPTIONS=(--region "${REGION}")
if [[ -n "${PROFILE}" ]]; then
  AWS_OPTIONS+=(--profile "${PROFILE}")
fi

identity_file=$(mktemp "${TMPDIR:-/tmp}/workspace-identity.XXXXXX")
if ! aws "${AWS_OPTIONS[@]}" sts get-caller-identity --output json >"${identity_file}" 2>/dev/null; then
  rm -f "${identity_file}"
  print_authentication_help
  die "AWS authentication failed. No AWS resource was changed."
fi

account_id=$(jq -r '.Account' "${identity_file}")
caller_arn=$(jq -r '.Arn' "${identity_file}")
rm -f "${identity_file}"

log_info "Authenticated AWS account: ${account_id}"
log_info "Authenticated principal: ${caller_arn}"

if [[ "${caller_arn}" == *":root" ]]; then
  die "Refusing to deploy as the AWS account root user. Create or assume an administrative IAM role instead."
fi

if ! aws "${AWS_OPTIONS[@]}" ec2 describe-availability-zones \
  --filters Name=opt-in-status,Values=opt-in-not-required,opted-in \
  --query 'AvailabilityZones[?State==`available`].ZoneName' \
  --output text >/dev/null; then
  die "Credentials cannot read Availability Zones in ${REGION}, or the Region is not enabled."
fi
log_info "Region ${REGION} is enabled and EC2 availability can be read."

if [[ "${SKIP_PERMISSIONS}" != "true" ]]; then
  permission_args=(--region "${REGION}")
  [[ -n "${PROFILE}" ]] && permission_args+=(--profile "${PROFILE}")
  [[ "${STRICT}" == "true" ]] && permission_args+=(--strict)

  set +e
  "${SCRIPT_DIR}/permissions.sh" "${permission_args[@]}"
  permission_exit=$?
  set -e
  if [[ "${permission_exit}" -ne 0 ]]; then
    if [[ "${STRICT}" == "true" ]]; then
      failures=$((failures + 1))
    else
      warnings=$((warnings + 1))
    fi
  fi
fi

if [[ "${STRICT}" == "true" && "${ALLOW_CLI_DRIFT}" != "true" && "${warnings}" -gt 0 ]]; then
  failures=$((failures + warnings))
fi

if [[ "${failures}" -gt 0 ]]; then
  die "Preflight found ${failures} blocking issue(s). Review the ERROR/WARNING lines above."
fi

log_info "Preflight passed with ${warnings} non-blocking warning(s). No AWS resource was changed."
