#!/usr/bin/env bash
# Single beginner-facing entry point for local checks, Terraform previews,
# guarded changes, status, logs, cost, and teardown.

set -Eeuo pipefail
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

COMMAND="${1:-help}"
if [[ $# -gt 0 ]]; then
  shift
fi

PROFILE=""
REGION="us-west-2"
RUN_AS_ROOT=false

usage() {
  cat <<'USAGE'
Usage: ./scripts/workspace.sh COMMAND [--profile NAME] [--region REGION] [--run-as-root]

Commands:
  validate   Check local code and Terraform; does not authenticate to AWS.
  preflight  Read-only tool, login, Region, and IAM permission checks.
  cost       Print the documented conservative cost estimate.
  init       Connect Terraform to the protected S3 state backend.
  plan       Create and display a saved proposal; changes no AWS resource.
  apply      Create a fresh plan, demand cost approval, then apply that plan.
  status     Display Terraform outputs and current Auto Scaling instances.
  logs       Follow recent application logs from CloudWatch.
  destroy    Create a destroy plan, demand exact approval, then remove runtime.
  schedule-status  Read the current scheduled self-destruct state from AWS.
  help       Show this explanation.

Examples:
  ./scripts/workspace.sh validate
  ./scripts/workspace.sh preflight --profile company-dev --region us-west-2
  ./scripts/workspace.sh plan --profile company-dev --region us-west-2
  ./scripts/workspace.sh schedule-status --profile company-dev --region us-west-2

There is deliberately no blanket --yes option. A billable apply or destructive
destroy always needs the exact phrase displayed on screen (or the matching
WORKSPACE_EXACT_CONFIRMATION value in tightly controlled automation).

Normal AWS commands refuse the AWS account root identity. --run-as-root is an
exceptional per-command override; it does not bypass cost or destroy approval.
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
    --run-as-root)
      RUN_AS_ROOT=true
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      die "Unknown option for ${COMMAND}: $1"
      ;;
  esac
done

begin_logged_run "workspace-${COMMAND}"

# Local-only commands remain usable for repair even when AWS is logged out or
# a profile marker needs attention. Every command that can contact AWS resolves
# and checks its selected identity through preflight below.
case "${COMMAND}" in
  preflight|init|plan|apply|status|logs|destroy|schedule-status)
    PROFILE="$(resolve_aws_profile "${PROFILE}")"
    ;;
esac

AWS_OPTIONS=(--region "${REGION}")
if [[ -n "${PROFILE}" ]]; then
  AWS_OPTIONS+=(--profile "${PROFILE}")
  export AWS_PROFILE="${PROFILE}"
fi
export AWS_REGION="${REGION}"
export AWS_DEFAULT_REGION="${REGION}"

preflight_arguments=(--region "${REGION}" --strict)
if [[ -n "${PROFILE}" ]]; then
  preflight_arguments+=(--profile "${PROFILE}")
fi
[[ "${RUN_AS_ROOT}" == "true" ]] && preflight_arguments+=(--run-as-root)

require_backend_file() {
  if [[ ! -f "${TERRAFORM_DIR}/backend.hcl" ]]; then
    die "terraform/backend.hcl is missing. Complete README Step 5 with scripts/bootstrap_backend.sh first."
  fi
}

initialize_terraform() {
  require_backend_file
  require_command terraform "Install Terraform 1.10 or newer using docs/WORKSTATION_SETUP.md."
  log_info "Initializing the protected S3 backend and latest compatible provider releases."
  terraform -chdir="${TERRAFORM_DIR}" init \
    -backend-config=backend.hcl \
    -input=false \
    -upgrade
}

run_strict_preflight() {
  "${SCRIPT_DIR}/preflight.sh" "${preflight_arguments[@]}"
}

run_destroy_preflight() {
  local destroy_preflight_arguments=(--region "${REGION}" --strict --allow-cli-drift)
  [[ -n "${PROFILE}" ]] && destroy_preflight_arguments+=(--profile "${PROFILE}")
  [[ "${RUN_AS_ROOT}" == "true" ]] && destroy_preflight_arguments+=(--run-as-root)
  "${SCRIPT_DIR}/preflight.sh" "${destroy_preflight_arguments[@]}"
}

create_plan() {
  local plan_path="$1"
  log_info "Creating a saved Terraform proposal. This API phase is read-only."
  terraform -chdir="${TERRAFORM_DIR}" plan \
    -input=false \
    -out="${plan_path}" \
    -var="aws_region=${REGION}"
  log_info "Saved proposal: ${TERRAFORM_DIR}/${plan_path}"
}

ensure_scheduled_destroy_configuration() {
  require_command python3 "Install Python 3.9 or newer using docs/WORKSTATION_SETUP.md."
  python3 "${SCRIPT_DIR}/configure_scheduled_destroy.py" \
    --terraform-dir "${TERRAFORM_DIR}" \
    --repository-root "${WORKSPACE_ROOT}" \
    --region "${REGION}" \
    --ensure

  if [[ "$(jq -r '.scheduled_destroy_enabled // false' "${TERRAFORM_DIR}/scheduled_destroy.auto.tfvars.json")" == "true" ]]; then
    print_scheduled_destroy_cost_warning
    channel_arguments=(--region "${REGION}")
    [[ -n "${PROFILE}" ]] && channel_arguments+=(--profile "${PROFILE}")
    "${SCRIPT_DIR}/validate_scheduled_destroy_channels.sh" "${channel_arguments[@]}"
  fi
}

case "${COMMAND}" in
  help)
    usage
    ;;

  validate)
    "${SCRIPT_DIR}/validate.sh"
    ;;

  preflight)
    diagnostic_args=(--region "${REGION}")
    [[ -n "${PROFILE}" ]] && diagnostic_args+=(--profile "${PROFILE}")
    [[ "${RUN_AS_ROOT}" == "true" ]] && diagnostic_args+=(--run-as-root)
    "${SCRIPT_DIR}/preflight.sh" "${diagnostic_args[@]}"
    ;;

  cost)
    require_command python3 "Install Python 3.9 or newer using docs/WORKSTATION_SETUP.md."
    print_cost_warning
    "${SCRIPT_DIR}/cost_estimate.py"
    ;;

  init)
    run_strict_preflight
    initialize_terraform
    ;;

  plan)
    run_strict_preflight
    initialize_terraform
    ensure_scheduled_destroy_configuration
    print_cost_warning
    "${SCRIPT_DIR}/cost_estimate.py"
    create_plan "workspace.tfplan"
    log_info "No AWS resource was changed. Read every line before running apply."
    ;;

  apply)
    run_strict_preflight
    initialize_terraform
    ensure_scheduled_destroy_configuration
    create_plan "workspace.tfplan"
    terraform -chdir="${TERRAFORM_DIR}" show -no-color "workspace.tfplan"
    print_cost_warning
    "${SCRIPT_DIR}/cost_estimate.py"
    require_exact_confirmation \
      "I ACCEPT ESTIMATED AWS CHARGES" \
      "This applies the displayed saved plan and may begin AWS billing immediately."
    upload_arguments=(--region "${REGION}")
    [[ -n "${PROFILE}" ]] && upload_arguments+=(--profile "${PROFILE}")
    "${SCRIPT_DIR}/upload_scheduled_destroy_artifacts.sh" "${upload_arguments[@]}"
    terraform -chdir="${TERRAFORM_DIR}" apply -input=false "workspace.tfplan"
    log_info "Workspace apply completed. Application URL follows."
    terraform -chdir="${TERRAFORM_DIR}" output -raw application_url
    printf '\n'
    if [[ "$(jq -r '.scheduled_destroy_enabled // false' "${TERRAFORM_DIR}/scheduled_destroy.auto.tfvars.json")" == "true" ]]; then
      print_scheduled_destroy_cost_warning
      log_warning "SCHEDULE IS NOT ARMED YET: open the AWS SNS confirmation email and click Confirm subscription."
      log_warning "After confirmation, AWS will text/email ARMED. Only an exact CANCEL SMS reply stops teardown."
      terraform -chdir="${TERRAFORM_DIR}" output scheduled_destroy_status
    fi
    ;;

  schedule-status)
    run_strict_preflight
    initialize_terraform
    config_file="${TERRAFORM_DIR}/scheduled_destroy.auto.tfvars.json"
    [[ -f "${config_file}" ]] || die "No local scheduled self-destruct configuration exists."
    [[ "$(jq -r '.scheduled_destroy_enabled // false' "${config_file}")" == "true" ]] \
      || die "Scheduled self-destruct is disabled for this environment."
    schedule_id=$(jq -r '.scheduled_destroy_configuration.schedule_id' "${config_file}")
    schedule_table=$(terraform -chdir="${TERRAFORM_DIR}" output -raw scheduled_destroy_table_name)
    aws "${AWS_OPTIONS[@]}" dynamodb get-item \
      --table-name "${schedule_table}" \
      --key "{\"ScheduleId\":{\"S\":\"${schedule_id}\"}}" \
      --consistent-read \
      --projection-expression '#status,DeadlineEpoch' \
      --expression-attribute-names '{"#status":"Status"}' \
      --output table
    log_info "Only an exact CANCEL reply from the enrolled phone can change an armed schedule to CANCELLED."
    ;;

  status)
    run_strict_preflight
    initialize_terraform
    application_url=$(terraform -chdir="${TERRAFORM_DIR}" output -raw application_url)
    asg_name=$(terraform -chdir="${TERRAFORM_DIR}" output -raw autoscaling_group_name)
    log_info "Application URL: ${application_url}"
    log_info "Auto Scaling Group: ${asg_name}"
    aws "${AWS_OPTIONS[@]}" autoscaling describe-auto-scaling-groups \
      --auto-scaling-group-names "${asg_name}" \
      --query 'AutoScalingGroups[0].Instances[].{Instance:InstanceId,State:LifecycleState,Health:HealthStatus,Zone:AvailabilityZone}' \
      --output table
    ;;

  logs)
    run_strict_preflight
    initialize_terraform
    log_group=$(terraform -chdir="${TERRAFORM_DIR}" output -raw application_log_group)
    log_info "Following CloudWatch group ${log_group}. Press Control-C to stop."
    aws "${AWS_OPTIONS[@]}" logs tail "${log_group}" --since 1h --follow --format short
    ;;

  destroy)
    # A newly released CLI patch must never strand billable infrastructure.
    # Credential and permission failures still block teardown.
    run_destroy_preflight
    initialize_terraform
    log_warning "Creating a saved proposal to permanently remove the runtime workspace."
    terraform -chdir="${TERRAFORM_DIR}" plan \
      -destroy \
      -input=false \
      -out="destroy.tfplan" \
      -var="aws_region=${REGION}"
    terraform -chdir="${TERRAFORM_DIR}" show -no-color "destroy.tfplan"
    require_exact_confirmation \
      "DESTROY AWS WORKSPACE" \
      "This permanently removes runtime resources, ECR images, and runtime logs. The separate state bucket remains."
    terraform -chdir="${TERRAFORM_DIR}" apply -input=false "destroy.tfplan"
    log_info "Runtime destroy completed. Follow docs/TROUBLESHOOTING.md to verify billable resources are gone."
    ;;

  *)
    usage
    die "Unknown command: ${COMMAND}"
    ;;
esac
