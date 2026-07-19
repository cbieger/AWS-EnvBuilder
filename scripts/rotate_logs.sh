#!/usr/bin/env bash
# Manually run the same bounded local retention used by every helper.

set -Eeuo pipefail
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

rotate_workspace_logs
printf '%s INFO log rotation complete: successes=14 days/20 files; errors=90 days/100 files\n' \
  "$(timestamp_utc)"
