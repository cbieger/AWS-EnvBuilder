#!/usr/bin/env bash
# Shared safety, display, confirmation, and local log-retention functions.
# Every executable helper sources this file before doing meaningful work.

set -Eeuo pipefail

readonly COMMON_LIBRARY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly WORKSPACE_ROOT="$(cd "${COMMON_LIBRARY_DIR}/../.." && pwd)"
readonly TERRAFORM_DIR="${WORKSPACE_ROOT}/terraform"
readonly WORKSPACE_LOG_ROOT="${WORKSPACE_LOG_DIR:-${WORKSPACE_ROOT}/logs}"
readonly WORKSPACE_SERVICE_PROFILE_FILE="${WORKSPACE_SERVICE_PROFILE_FILE:-${WORKSPACE_ROOT}/.workspace/service-account-profile}"

timestamp_utc() {
  date -u +'%Y-%m-%dT%H:%M:%SZ'
}

log_info() {
  printf '%s INFO %s\n' "$(timestamp_utc)" "$*"
}

log_warning() {
  printf '%s WARNING %s\n' "$(timestamp_utc)" "$*" >&2
}

log_error() {
  printf '%s ERROR %s\n' "$(timestamp_utc)" "$*" >&2
}

die() {
  log_error "$*"
  exit 1
}

require_command() {
  local command_name="$1"
  local help_text="${2:-Install ${command_name}, then run this command again.}"

  if ! command -v "${command_name}" >/dev/null 2>&1; then
    log_error "Required program '${command_name}' was not found."
    log_error "${help_text}"
    return 1
  fi
}

# A successful first-run bootstrap records only the AWS CLI profile name—not a
# credential—in an ignored local marker. Explicit --profile always wins.
resolve_aws_profile() {
  local requested_profile="${1:-}"
  local saved_profile=""

  if [[ -n "${requested_profile}" ]]; then
    printf '%s\n' "${requested_profile}"
    return 0
  fi

  if [[ -f "${WORKSPACE_SERVICE_PROFILE_FILE}" ]]; then
    IFS= read -r saved_profile <"${WORKSPACE_SERVICE_PROFILE_FILE}"
    [[ "${saved_profile}" =~ ^[A-Za-z0-9_.@+-]{1,128}$ ]] \
      || die "Saved AWS profile marker is invalid: ${WORKSPACE_SERVICE_PROFILE_FILE}"
    printf '%s\n' "${saved_profile}"
    return 0
  fi

  printf '\n'
}

is_aws_root_arn() {
  [[ "${1:-}" =~ ^arn:[^:]+:iam::[0-9]{12}:root$ ]]
}

# All normal operations refuse AWS account root. The explicit override is
# intentionally verbose so a copied flag never looks like ordinary operation.
enforce_non_root_aws_identity() {
  local caller_arn="$1"
  local allow_root="${2:-false}"

  if ! is_aws_root_arn "${caller_arn}"; then
    return 0
  fi

  if [[ "${allow_root}" == "true" ]]; then
    log_warning "ROOT OVERRIDE ACTIVE: --run-as-root explicitly permits AWS account root for this command."
    log_warning "Root bypasses normal IAM boundaries. Stop unless this exceptional use is intentional."
    return 0
  fi

  die "Refusing AWS account root. Run scripts/first_run_setup.sh once, then use its saved service-account profile. Exceptional root use requires --run-as-root."
}

# The bootstrap has the inverse rule: it must prove the one-time caller is AWS
# account root. This checks AWS identity only; it never checks the operating-
# system user and must never be run with sudo merely to satisfy the requirement.
require_aws_root_identity() {
  local caller_arn="$1"

  if ! is_aws_root_arn "${caller_arn}"; then
    die "First run requires the AWS account root identity. Do not use sudo. Sign in to AWS root with 'aws login --profile aws-root-bootstrap', then pass --root-profile aws-root-bootstrap."
  fi
}

# Remove one named profile from the standard AWS credentials and config files
# without reformatting or replacing any unrelated profile. This is used only by
# failed first-run rollback or an explicitly approved service-account teardown.
remove_aws_cli_profile_sections() {
  local profile_name="$1"
  local credentials_path="${AWS_SHARED_CREDENTIALS_FILE:-${HOME}/.aws/credentials}"
  local config_path="${AWS_CONFIG_FILE:-${HOME}/.aws/config}"

  [[ "${profile_name}" =~ ^[A-Za-z0-9_.@+-]{1,128}$ ]] \
    || die "Refusing to remove an invalid AWS CLI profile name."

  python3 - "${profile_name}" "${credentials_path}" "${config_path}" <<'PY'
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
    descriptor, temporary_path = tempfile.mkstemp(
        prefix=".aws-envbuilder-profile-removal-", dir=directory
    )
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as output:
            output.writelines(kept)
            output.flush()
            os.fsync(output.fileno())
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

# Routine success logs have short retention; failure logs have much longer
# retention and a larger count limit. Only helper-generated *.log files inside
# these exact directories are eligible for removal.
rotate_one_log_set() {
  local directory="$1"
  local age_days="$2"
  local maximum_files="$3"
  local file_pattern="${4:-*.log}"
  local file_count
  local oldest_file

  mkdir -p "${directory}"
  find "${directory}" -type f -name "${file_pattern}" -mtime "+${age_days}" -delete

  while true; do
    file_count=$(find "${directory}" -type f -name "${file_pattern}" | wc -l | tr -d ' ')
    if [[ "${file_count}" -le "${maximum_files}" ]]; then
      break
    fi

    oldest_file=$(find "${directory}" -type f -name "${file_pattern}" -print0 \
      | xargs -0 ls -1tr 2>/dev/null | head -n 1 || true)
    [[ -n "${oldest_file}" ]] || break
    rm -f -- "${oldest_file}"
  done
}

rotate_workspace_logs() {
  mkdir -p \
    "${WORKSPACE_LOG_ROOT}/active" \
    "${WORKSPACE_LOG_ROOT}/success" \
    "${WORKSPACE_LOG_ROOT}/errors" \
    "${WORKSPACE_LOG_ROOT}/inventory"

  rotate_one_log_set "${WORKSPACE_LOG_ROOT}/success" 14 20
  rotate_one_log_set "${WORKSPACE_LOG_ROOT}/errors" 90 100
  rotate_one_log_set "${WORKSPACE_LOG_ROOT}/inventory" 365 20 '*.json'

  # An interrupted process may leave an active transcript. Preserve it as an
  # error after one day rather than deleting potentially valuable evidence.
  find "${WORKSPACE_LOG_ROOT}/active" -type f -name '*.log' -mtime +0 \
    -exec mv {} "${WORKSPACE_LOG_ROOT}/errors/" \;
}

_finish_logged_run() {
  local exit_code="$1"
  local destination_directory

  trap - EXIT
  if [[ "${exit_code}" -eq 0 ]]; then
    destination_directory="${WORKSPACE_LOG_ROOT}/success"
    log_info "Run completed successfully. Transcript: ${destination_directory}/$(basename "${RUN_LOG}")"
  else
    destination_directory="${WORKSPACE_LOG_ROOT}/errors"
    log_error "Run failed with exit code ${exit_code}. Retained transcript: ${destination_directory}/$(basename "${RUN_LOG}")"
  fi

  # Restore the original terminal descriptors. Closing the FIFO writers lets
  # tee flush and exit before the transcript is moved into its retention class.
  exec 1>&3 2>&4
  exec 3>&- 4>&-
  wait "${RUN_TEE_PID}" 2>/dev/null || true
  rm -f -- "${RUN_PIPE}" 2>/dev/null || true
  mv "${RUN_LOG}" "${destination_directory}/$(basename "${RUN_LOG}")" 2>/dev/null || true
  exit "${exit_code}"
}

begin_logged_run() {
  local operation_name="$1"
  local safe_operation_name

  rotate_workspace_logs
  safe_operation_name=$(printf '%s' "${operation_name}" | tr -cs 'A-Za-z0-9._-' '-')
  RUN_LOG="${WORKSPACE_LOG_ROOT}/active/$(date -u +'%Y%m%dT%H%M%SZ')-${safe_operation_name}-$$.log"
  RUN_PIPE="${WORKSPACE_LOG_ROOT}/active/.transcript-pipe-$$"
  export RUN_LOG

  # A named pipe is more portable than Bash /dev/fd process substitution in
  # restricted shells. It keeps output visible and records one combined stream.
  mkfifo "${RUN_PIPE}"
  exec 3>&1 4>&2
  tee -a "${RUN_LOG}" <"${RUN_PIPE}" >&3 &
  RUN_TEE_PID=$!
  export RUN_PIPE RUN_TEE_PID
  exec >"${RUN_PIPE}" 2>&1
  trap '_finish_logged_run "$?"' EXIT
  log_info "Starting ${operation_name}. Transcript in progress: ${RUN_LOG}"
}

print_cost_warning() {
  # ANSI bright red is used in terminals. The ASCII frame remains obvious in
  # terminals that do not support color.
  printf '\n\033[1;31m'
  printf '%s\n' '!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!'
  printf '%s\n' '!!  AWS WILL CHARGE FOR THIS WORKSPACE UNLESS CREDITS COVER THE USAGE. !!'
  printf '%s\n' '!!  DEFAULT ESTIMATE: ABOUT US$1.40/DAY OR US$42/30-DAY MONTH.         !!'
  printf '%s\n' '!!  TRAFFIC, EXTRA INSTANCES, LOGS, TAX, AND REGION CAN COST MORE.     !!'
  printf '%s\n' '!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!'
  printf '\033[0m\n'
}

require_exact_confirmation() {
  local expected_phrase="$1"
  local explanation="$2"
  local entered_phrase=""

  printf '%s\n' "${explanation}"
  printf 'Type exactly: %s\n> ' "${expected_phrase}"

  # A deliberately named environment variable supports controlled automation.
  # It must contain the same full phrase; a vague --yes flag is not accepted.
  if [[ -n "${WORKSPACE_EXACT_CONFIRMATION:-}" ]]; then
    entered_phrase="${WORKSPACE_EXACT_CONFIRMATION}"
    printf '%s\n' '[confirmation supplied through WORKSPACE_EXACT_CONFIRMATION]'
  elif [[ -r /dev/tty ]]; then
    IFS= read -r entered_phrase </dev/tty
  else
    die "No interactive terminal is available. Set WORKSPACE_EXACT_CONFIRMATION to the exact displayed phrase."
  fi

  if [[ "${entered_phrase}" != "${expected_phrase}" ]]; then
    die "Confirmation did not match. No approved action was taken."
  fi

  log_info "Exact approval phrase accepted."
}

print_authentication_help() {
  cat <<'AUTH_HELP'
No usable AWS login was found. No credentials should be pasted into this log.

Preferred short-lived login:
  1. Run: aws configure sso
  2. Give the profile a memorable name when prompted.
  3. Run: aws sso login --profile YOUR_PROFILE_NAME
  4. Retry this helper with: --profile YOUR_PROFILE_NAME

If the account supports AWS CLI browser login, `aws login` may be used instead.
If an administrator gave you long-lived access keys, use `aws configure
--profile YOUR_PROFILE_NAME` interactively. After first-run setup, normal
workspace commands refuse the AWS account root user unless --run-as-root is
explicitly supplied.
AUTH_HELP
}
