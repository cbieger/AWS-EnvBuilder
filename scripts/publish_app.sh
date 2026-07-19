#!/usr/bin/env bash
# Inspect, build, and push any Dockerized application into this workspace's ECR
# repository. The immutable digest is recorded locally but not auto-applied.

set -Eeuo pipefail
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

if [[ $# -lt 1 ]]; then
  die "Usage: ./scripts/publish_app.sh /absolute/path/to/application [--profile NAME] [--region REGION] [--tag TAG]"
fi

APPLICATION_PATH="$1"
shift
PROFILE=""
REGION="us-west-2"
IMAGE_TAG=""

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
    --tag)
      [[ $# -ge 2 ]] || die "--tag requires a value."
      IMAGE_TAG="$2"
      shift 2
      ;;
    --help|-h)
      printf '%s\n' "Usage: ./scripts/publish_app.sh APP_PATH [--profile NAME] [--region REGION] [--tag TAG]"
      exit 0
      ;;
    *)
      die "Unknown publish option: $1"
      ;;
  esac
done

APPLICATION_PATH="$(cd "${APPLICATION_PATH}" 2>/dev/null && pwd)" \
  || die "Application directory does not exist or is not readable."

begin_logged_run "publish-app"

require_command docker "Install and start Docker Desktop/Engine using docs/WORKSTATION_SETUP.md."
require_command terraform "Install Terraform 1.10 or newer using docs/WORKSTATION_SETUP.md."
require_command jq "Install jq 1.6 or newer using docs/WORKSTATION_SETUP.md."
docker info >/dev/null 2>&1 || die "Docker is installed but its engine is not running."

preflight_args=(--region "${REGION}" --strict)
[[ -n "${PROFILE}" ]] && preflight_args+=(--profile "${PROFILE}")
"${SCRIPT_DIR}/preflight.sh" "${preflight_args[@]}"

log_info "Inspecting every eligible application file before Docker ingestion."
"${SCRIPT_DIR}/inspect_app.py" "${APPLICATION_PATH}"

[[ -f "${TERRAFORM_DIR}/backend.hcl" ]] \
  || die "terraform/backend.hcl is missing. Bootstrap and apply the infrastructure first."

if [[ -n "${PROFILE}" ]]; then
  export AWS_PROFILE="${PROFILE}"
fi
export AWS_REGION="${REGION}"
export AWS_DEFAULT_REGION="${REGION}"

terraform -chdir="${TERRAFORM_DIR}" init \
  -backend-config=backend.hcl \
  -input=false

repository_url=$(terraform -chdir="${TERRAFORM_DIR}" output -raw ecr_repository_url 2>/dev/null) \
  || die "ECR output is unavailable. Apply the default infrastructure before publishing an app."

if [[ -z "${IMAGE_TAG}" ]]; then
  if git -C "${APPLICATION_PATH}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    IMAGE_TAG=$(git -C "${APPLICATION_PATH}" rev-parse --short=12 HEAD)
  else
    IMAGE_TAG=$(date -u +'%Y%m%dT%H%M%SZ')
  fi
fi

[[ "${IMAGE_TAG}" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]] \
  || die "Image tag contains unsupported characters or is longer than 128 characters."

full_image="${repository_url}:${IMAGE_TAG}"
registry_host="${repository_url%%/*}"

log_info "Application source: ${APPLICATION_PATH}"
log_info "Proposed image: ${full_image}"
print_cost_warning
require_exact_confirmation \
  "BUILD AND PUSH APPLICATION IMAGE" \
  "Docker will ingest the inspected directory, download current base layers, build locally, and write an image to AWS ECR."

AWS_OPTIONS=(--region "${REGION}")
[[ -n "${PROFILE}" ]] && AWS_OPTIONS+=(--profile "${PROFILE}")

log_info "Obtaining a short-lived ECR login token without displaying it."
aws "${AWS_OPTIONS[@]}" ecr get-login-password \
  | docker login --username AWS --password-stdin "${registry_host}" >/dev/null

log_info "Building linux/amd64 container and pulling the Dockerfile's current base image."
docker build --pull --platform linux/amd64 -t "${full_image}" "${APPLICATION_PATH}"

log_info "Pushing application layers to ECR."
docker push "${full_image}"

repository_name="${repository_url#*/}"
image_digest=$(aws "${AWS_OPTIONS[@]}" ecr describe-images \
  --repository-name "${repository_name}" \
  --image-ids "imageTag=${IMAGE_TAG}" \
  --query 'imageDetails[0].imageDigest' \
  --output text)

[[ "${image_digest}" == sha256:* ]] || die "ECR did not return a valid immutable image digest."
immutable_image="${repository_url}@${image_digest}"

# Atomically record only the non-secret image digest. This generated file is
# ignored by Git; source control should identify app source, not runtime state.
python3 - "${TERRAFORM_DIR}/application.auto.tfvars.json" "${immutable_image}" <<'PY'
import json
import os
import sys
import tempfile

destination, image = sys.argv[1:]
directory = os.path.dirname(destination)
descriptor, temporary_path = tempfile.mkstemp(prefix="application.", suffix=".json", dir=directory)
try:
    with os.fdopen(descriptor, "w", encoding="utf-8") as output:
        json.dump({"container_image": image}, output, indent=2, sort_keys=True)
        output.write("\n")
    os.replace(temporary_path, destination)
except BaseException:
    try:
        os.unlink(temporary_path)
    except FileNotFoundError:
        pass
    raise
PY

log_info "Published immutable image: ${immutable_image}"
log_info "Recorded it in ignored terraform/application.auto.tfvars.json."
log_info "No EC2 instance was changed. Run workspace.sh plan, review replacement, then apply."
