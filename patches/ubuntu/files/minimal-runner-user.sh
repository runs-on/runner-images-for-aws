#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HELPER_DIR="${RUNNER_FINALIZE_HELPER_DIR:-${SCRIPT_DIR}}"

bash "${HELPER_DIR}/runner-finalize-common.sh"
bash "${HELPER_DIR}/runner-finalize-cleanup.sh"
bash "${HELPER_DIR}/runner-finalize-units.sh" minimal
