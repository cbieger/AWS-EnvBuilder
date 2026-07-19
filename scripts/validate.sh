#!/usr/bin/env bash
# Local, non-deploying quality checks. Provider installation may download files,
# but this script makes no authenticated AWS API call and creates no AWS resource.

set -Eeuo pipefail
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

begin_logged_run "validate"

require_command terraform "Install Terraform 1.10 or newer using docs/WORKSTATION_SETUP.md."
require_command python3 "Install Python 3.9 or newer using docs/WORKSTATION_SETUP.md."

log_info "Checking Bash syntax."
while IFS= read -r shell_file; do
  bash -n "${shell_file}"
done < <(find "${SCRIPT_DIR}" -type f -name '*.sh' | sort)

if command -v shellcheck >/dev/null 2>&1; then
  log_info "Running optional ShellCheck analysis."
  while IFS= read -r shell_file; do
    shellcheck "${shell_file}"
  done < <(find "${SCRIPT_DIR}" -type f -name '*.sh' | sort)
else
  log_warning "Optional shellcheck is not installed; Bash syntax was still checked."
fi

log_info "Running Python unit tests."
python3 -m unittest discover -s "${WORKSPACE_ROOT}/tests" -p 'test_*.py' -v

log_info "Checking Terraform canonical formatting."
terraform -chdir="${TERRAFORM_DIR}" fmt -check -recursive

log_info "Initializing providers with remote state disabled."
terraform -chdir="${TERRAFORM_DIR}" init -backend=false -input=false

log_info "Validating Terraform structure without contacting AWS."
terraform -chdir="${TERRAFORM_DIR}" validate

log_info "All local validation checks passed. No AWS resource was changed."
