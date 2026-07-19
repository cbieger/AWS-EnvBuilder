#!/usr/bin/env bash
# Shared safety, display, confirmation, and local log-retention functions.
# Every executable helper sources this file before doing meaningful work.

set -Eeuo pipefail

readonly COMMON_LIBRARY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly WORKSPACE_ROOT="$(cd "${COMMON_LIBRARY_DIR}/../.." && pwd)"
readonly TERRAFORM_DIR="${WORKSPACE_ROOT}/terraform"
readonly WORKSPACE_LOG_ROOT="${WORKSPACE_LOG_DIR:-${WORKSPACE_ROOT}/logs}"

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

# Routine success logs have short retention; failure logs have much longer
# retention and a larger count limit. Only helper-generated *.log files inside
# these exact directories are eligible for removal.
rotate_one_log_set() {
  local directory="$1"
  local age_days="$2"
  local maximum_files="$3"
  local file_count
  local oldest_file

  mkdir -p "${directory}"
  find "${directory}" -type f -name '*.log' -mtime "+${age_days}" -delete

  while true; do
    file_count=$(find "${directory}" -type f -name '*.log' | wc -l | tr -d ' ')
    if [[ "${file_count}" -le "${maximum_files}" ]]; then
      break
    fi

    oldest_file=$(ls -1tr "${directory}"/*.log 2>/dev/null | head -n 1 || true)
    [[ -n "${oldest_file}" ]] || break
    rm -f -- "${oldest_file}"
  done
}

rotate_workspace_logs() {
  mkdir -p \
    "${WORKSPACE_LOG_ROOT}/active" \
    "${WORKSPACE_LOG_ROOT}/success" \
    "${WORKSPACE_LOG_ROOT}/errors"

  rotate_one_log_set "${WORKSPACE_LOG_ROOT}/success" 14 20
  rotate_one_log_set "${WORKSPACE_LOG_ROOT}/errors" 90 100

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
--profile YOUR_PROFILE_NAME` interactively. Never use the AWS account root user.
AUTH_HELP
}
