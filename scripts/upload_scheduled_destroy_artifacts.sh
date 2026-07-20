#!/usr/bin/env bash
# Upload only content-addressed reviewed source archives. This write occurs
# after cost approval but before Terraform creates the scheduling control plane.

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
    *) die "Unknown scheduled-artifact upload option: $1" ;;
  esac
done

readonly CONFIG_FILE="${TERRAFORM_DIR}/scheduled_destroy.auto.tfvars.json"
[[ -f "${CONFIG_FILE}" ]] || exit 0
[[ "$(jq -r '.scheduled_destroy_enabled // false' "${CONFIG_FILE}")" == "true" ]] || exit 0

AWS_OPTIONS=(--region "${REGION}" --no-cli-pager)
if [[ -n "${PROFILE}" ]]; then
  AWS_OPTIONS+=(--profile "${PROFILE}")
fi
account_id=$(aws "${AWS_OPTIONS[@]}" sts get-caller-identity --query Account --output text)
bucket=$(jq -r '.scheduled_destroy_configuration.source_bucket' "${CONFIG_FILE}")

upload_one() {
  local kind="$1"
  local file="$2"
  local key_path="$3"
  local expected_hash="$4"
  local actual_hash
  local remote_hash

  [[ -f "${file}" ]] || die "Missing generated ${kind} archive. Run plan again."
  actual_hash=$(python3 - "${file}" <<'PY'
import hashlib
from pathlib import Path
import sys

print(hashlib.sha256(Path(sys.argv[1]).read_bytes()).hexdigest())
PY
)
  [[ "${actual_hash}" == "${expected_hash}" ]] || die "Local ${kind} archive hash changed after planning. Run plan again."
  aws "${AWS_OPTIONS[@]}" s3api put-object \
    --bucket "${bucket}" \
    --key "${key_path}" \
    --body "${file}" \
    --server-side-encryption AES256 \
    --metadata "sha256=${expected_hash},artifact=${kind}" \
    --expected-bucket-owner "${account_id}" >/dev/null
  remote_hash=$(aws "${AWS_OPTIONS[@]}" s3api head-object \
    --bucket "${bucket}" \
    --key "${key_path}" \
    --expected-bucket-owner "${account_id}" \
    --query 'Metadata.sha256' --output text)
  [[ "${remote_hash}" == "${expected_hash}" ]] || die "Uploaded ${kind} archive failed metadata verification."
  log_info "Uploaded and verified content-addressed ${kind} source."
}

artifact_dir="${WORKSPACE_ROOT}/.workspace/scheduled-destroy"
upload_one \
  "terraform" \
  "${artifact_dir}/terraform-source.zip" \
  "$(jq -r '.scheduled_destroy_configuration.terraform_source_key' "${CONFIG_FILE}")" \
  "$(jq -r '.scheduled_destroy_configuration.terraform_source_sha256' "${CONFIG_FILE}")"
upload_one \
  "controller" \
  "${artifact_dir}/controller-source.zip" \
  "$(jq -r '.scheduled_destroy_configuration.controller_source_key' "${CONFIG_FILE}")" \
  "$(jq -r '.scheduled_destroy_configuration.controller_source_sha256' "${CONFIG_FILE}")"
