#!/usr/bin/env bash

set -euo pipefail

HELPER_DIR="${RUNNER_FINALIZE_HELPER_DIR:-/tmp/runner-finalize}"

bash "${HELPER_DIR}/runner-finalize-common.sh"
bash "${HELPER_DIR}/runner-finalize-nested-virt.sh"
bash "${HELPER_DIR}/runner-finalize-cleanup.sh"
bash "${HELPER_DIR}/runner-finalize-units.sh" full
