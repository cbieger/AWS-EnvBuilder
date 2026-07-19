#!/usr/bin/env bash
# Create the encrypted/versioned S3 bucket used only for Terraform state, then
# write the ignored local backend.hcl connection file.

set -Eeuo pipefail
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

PROFILE=""
REGION="us-west-2"
PROJECT="stub-app"
ENVIRONMENT="dev"

usage() {
  cat <<'USAGE'
Usage: ./scripts/bootstrap_backend.sh [options]

Options:
  --profile NAME          AWS CLI profile (recommended).
  --region REGION         State bucket Region (default: us-west-2).
  --project NAME          3-24 lowercase letters/digits/hyphens.
  --environment NAME      3-12 lowercase letters/digits/hyphens.
  --help                  Show this explanation.

This is a one-time AWS write operation. The versioned state bucket remains after
normal workspace destruction so accidental state deletion is recoverable.
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
    --help|-h)
      usage
      exit 0
      ;;
    *)
      die "Unknown backend option: $1"
      ;;
  esac
done

[[ "${PROJECT}" =~ ^[a-z][a-z0-9-]{1,22}[a-z0-9]$ ]] \
  || die "--project must be 3-24 lowercase letters, digits, or hyphens."
[[ "${ENVIRONMENT}" =~ ^[a-z][a-z0-9-]{1,10}[a-z0-9]$ ]] \
  || die "--environment must be 3-12 lowercase letters, digits, or hyphens."
[[ "${REGION}" =~ ^[a-z]{2}(-gov)?-[a-z]+-[0-9]$ ]] \
  || die "--region must look like us-west-2."

begin_logged_run "bootstrap-backend"

preflight_args=(--region "${REGION}" --strict)
[[ -n "${PROFILE}" ]] && preflight_args+=(--profile "${PROFILE}")
"${SCRIPT_DIR}/preflight.sh" "${preflight_args[@]}"

AWS_OPTIONS=(--region "${REGION}")
if [[ -n "${PROFILE}" ]]; then
  AWS_OPTIONS+=(--profile "${PROFILE}")
fi

account_id=$(aws "${AWS_OPTIONS[@]}" sts get-caller-identity --query Account --output text)
project_prefix=$(printf '%s' "${PROJECT}" | cut -c1-18)
environment_prefix=$(printf '%s' "${ENVIRONMENT}" | cut -c1-10)
bucket_name="${project_prefix}-${environment_prefix}-${account_id}-${REGION}-tfstate"
state_key="${PROJECT}/${ENVIRONMENT}/terraform.tfstate"

log_info "Proposed state bucket: ${bucket_name}"
log_info "Proposed state object: ${state_key}"
log_info "Controls: Block Public Access, AES-256 at rest, versioning, native lock file, 365-day noncurrent retention."
print_cost_warning
require_exact_confirmation \
  "CREATE TERRAFORM STATE BUCKET" \
  "This creates or secures a small persistent S3 bucket and can incur minor storage/request charges."

existing_bucket=$(aws "${AWS_OPTIONS[@]}" s3api list-buckets \
  --query "Buckets[?Name=='${bucket_name}'].Name | [0]" --output text)

if [[ "${existing_bucket}" == "None" || -z "${existing_bucket}" ]]; then
  if [[ "${REGION}" == "us-east-1" ]]; then
    aws "${AWS_OPTIONS[@]}" s3api create-bucket --bucket "${bucket_name}"
  else
    aws "${AWS_OPTIONS[@]}" s3api create-bucket \
      --bucket "${bucket_name}" \
      --create-bucket-configuration "LocationConstraint=${REGION}"
  fi
  log_info "Created state bucket ${bucket_name}."
else
  log_info "State bucket already exists in this account; security settings will be reconciled."
  existing_location=$(aws "${AWS_OPTIONS[@]}" s3api get-bucket-location \
    --bucket "${bucket_name}" --query 'LocationConstraint' --output text)
  [[ "${existing_location}" == "None" ]] && existing_location="us-east-1"
  if [[ "${existing_location}" != "${REGION}" ]]; then
    die "Existing bucket is in ${existing_location}, not requested Region ${REGION}. Nothing was changed."
  fi
fi

aws "${AWS_OPTIONS[@]}" s3api put-public-access-block \
  --bucket "${bucket_name}" \
  --public-access-block-configuration \
  'BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true'

aws "${AWS_OPTIONS[@]}" s3api put-bucket-encryption \
  --bucket "${bucket_name}" \
  --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"},"BucketKeyEnabled":true}]}'

aws "${AWS_OPTIONS[@]}" s3api put-bucket-versioning \
  --bucket "${bucket_name}" \
  --versioning-configuration Status=Enabled

aws "${AWS_OPTIONS[@]}" s3api put-bucket-ownership-controls \
  --bucket "${bucket_name}" \
  --ownership-controls 'Rules=[{ObjectOwnership=BucketOwnerEnforced}]'

aws "${AWS_OPTIONS[@]}" s3api put-bucket-tagging \
  --bucket "${bucket_name}" \
  --tagging "TagSet=[{Key=Application,Value=${PROJECT}},{Key=Environment,Value=${ENVIRONMENT}},{Key=ManagedBy,Value=bootstrap-backend},{Key=Purpose,Value=terraform-state}]"

aws "${AWS_OPTIONS[@]}" s3api put-bucket-lifecycle-configuration \
  --bucket "${bucket_name}" \
  --lifecycle-configuration \
  '{"Rules":[{"ID":"retain-recoverable-state-history","Status":"Enabled","Filter":{"Prefix":""},"NoncurrentVersionExpiration":{"NoncurrentDays":365,"NewerNoncurrentVersions":20}}]}'

# This file contains no secret, but it is account-specific and therefore ignored
# by Git. A restrictive umask prevents unrelated local users from replacing it.
umask 077
{
  printf 'bucket       = "%s"\n' "${bucket_name}"
  printf 'key          = "%s"\n' "${state_key}"
  printf 'region       = "%s"\n' "${REGION}"
  printf 'encrypt      = true\n'
  printf 'use_lockfile = true\n'
} >"${TERRAFORM_DIR}/backend.hcl"

log_info "Wrote ignored Terraform connection settings: ${TERRAFORM_DIR}/backend.hcl"
log_info "Backend is ready. Next run: ./scripts/workspace.sh plan --profile YOUR_PROFILE --region ${REGION}"
