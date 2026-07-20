#!/usr/bin/env bash
# Read-only proof that the configured AWS number supports two-way SMS and that
# its inbound SNS topic is the exact topic Terraform will subscribe to.

set -Eeuo pipefail
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

PROFILE=""
REGION="us-west-2"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile) [[ $# -ge 2 ]] || die "--profile requires a value."; PROFILE="$2"; shift 2 ;;
    --region) [[ $# -ge 2 ]] || die "--region requires a value."; REGION="$2"; shift 2 ;;
    *) die "Unknown scheduled-channel validation option: $1" ;;
  esac
done

readonly CONFIG_FILE="${TERRAFORM_DIR}/scheduled_destroy.auto.tfvars.json"
[[ -f "${CONFIG_FILE}" ]] || die "Scheduled self-destruct configuration is missing."
[[ "$(jq -r '.scheduled_destroy_enabled // false' "${CONFIG_FILE}")" == "true" ]] || exit 0

AWS_OPTIONS=(--region "${REGION}" --no-cli-pager)
if [[ -n "${PROFILE}" ]]; then
  AWS_OPTIONS+=(--profile "${PROFILE}")
fi

topic_arn=$(jq -r '.scheduled_destroy_configuration.sms_inbound_topic_arn' "${CONFIG_FILE}")
origination=$(jq -r '.scheduled_destroy_configuration.sms_origination_number' "${CONFIG_FILE}")
destination=$(jq -r '.scheduled_destroy_contacts.operator_phone' "${CONFIG_FILE}")
topic_region=$(printf '%s' "${topic_arn}" | cut -d: -f4)
topic_account=$(printf '%s' "${topic_arn}" | cut -d: -f5)
identity=$(aws "${AWS_OPTIONS[@]}" sts get-caller-identity --output json)
account_id=$(printf '%s' "${identity}" | jq -r '.Account')

[[ "${topic_region}" == "${REGION}" ]] || die "The inbound SNS topic is not in ${REGION}."
[[ "${topic_account}" == "${account_id}" ]] || die "The inbound SNS topic belongs to a different AWS account."

aws "${AWS_OPTIONS[@]}" sns get-topic-attributes --topic-arn "${topic_arn}" >/dev/null \
  || die "The configured inbound SNS topic cannot be read."

phone_file=$(mktemp "${TMPDIR:-/tmp}/scheduled-phone-proof.XXXXXX")
trap 'rm -f "${phone_file}" "${dry_run_error:-}"' EXIT
aws "${AWS_OPTIONS[@]}" pinpoint-sms-voice-v2 describe-phone-numbers \
  --owner SELF \
  --output json >"${phone_file}" \
  || die "The configured AWS End User Messaging phone number cannot be described."

matching_count=$(jq --arg number "${origination}" '[.PhoneNumbers[]? | select(.PhoneNumber == $number)] | length' "${phone_file}")
[[ "${matching_count}" -eq 1 ]] || die "Exactly one configured AWS origination number was not found."
jq -e --arg number "${origination}" --arg topic "${topic_arn}" '
  .PhoneNumbers[]
  | select(.PhoneNumber == $number)
  | select(.Status == "ACTIVE")
  | select(.IsoCountryCode == "US")
  | select(.NumberType == "TOLL_FREE")
  | select((.NumberCapabilities // []) | index("SMS"))
  | select(.TwoWayEnabled == true)
  | select(.TwoWayChannelArn == $topic)
  | select(.SelfManagedOptOutsEnabled == false)
' "${phone_file}" >/dev/null \
  || die "The AWS number must be account-owned, ACTIVE, US TOLL_FREE, SMS-capable, two-way enabled, use carrier-managed opt-outs, and connect to the exact inbound SNS topic."

# AWS validates the complete outbound path but must not send or bill a message.
dry_run_error=$(mktemp "${TMPDIR:-/tmp}/scheduled-sms-dry-run.XXXXXX")
set +e
aws "${AWS_OPTIONS[@]}" pinpoint-sms-voice-v2 send-text-message \
  --destination-phone-number "${destination}" \
  --origination-identity "${origination}" \
  --message-body "AWS-EnvBuilder channel validation only" \
  --message-type TRANSACTIONAL \
  --dry-run >/dev/null 2>"${dry_run_error}"
dry_run_exit=$?
set -e
if [[ "${dry_run_exit}" -ne 0 ]] && ! grep -q 'DryRunOperation' "${dry_run_error}"; then
  die "AWS rejected the no-send SMS validation. Check number registration, destination country, sandbox, and IAM permissions."
fi

log_info "Two-way SMS ownership, inbound routing, and no-send outbound validation passed."
log_warning "The SNS email subscription will remain PENDING until the operator clicks AWS's confirmation email."
