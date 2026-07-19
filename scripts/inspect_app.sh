#!/usr/bin/env bash
# Logged user-facing wrapper around the dependency-free Python inspector.

set -Eeuo pipefail
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

if [[ $# -lt 1 ]]; then
  die "Usage: ./scripts/inspect_app.sh /absolute/path/to/application [--json]"
fi

begin_logged_run "inspect-app"
require_command python3 "Install Python 3.9 or newer using docs/WORKSTATION_SETUP.md."
"${SCRIPT_DIR}/inspect_app.py" "$@"
