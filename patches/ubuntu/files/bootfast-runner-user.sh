#!/usr/bin/env bash

set -euo pipefail

TARGET_ROOT_MOUNT="${TARGET_ROOT_MOUNT:-/mnt/target-root}"
IMAGE_FOLDER="${IMAGE_FOLDER:-/imagegeneration}"
DEBIAN_FRONTEND="${DEBIAN_FRONTEND:-noninteractive}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HELPER_DIR="${RUNNER_FINALIZE_HELPER_DIR:-${SCRIPT_DIR}}"

run_in_target() {
  local command="$1"

  chroot "${TARGET_ROOT_MOUNT}" /usr/bin/env \
    DEBIAN_FRONTEND="${DEBIAN_FRONTEND}" \
    IMAGE_FOLDER="${IMAGE_FOLDER}" \
    /bin/bash -lc "${command}"
}

echo "[bootfast-runner-user] running common runner finalization"
bash "${HELPER_DIR}/runner-finalize-common.sh"

echo "[bootfast-runner-user] adding nested virtualization payload"
bash "${HELPER_DIR}/runner-finalize-nested-virt.sh"

echo "[bootfast-runner-user] applying cleanup"
bash "${HELPER_DIR}/runner-finalize-cleanup.sh"

echo "[bootfast-runner-user] scrubbing SSH material"
run_in_target '
  set -euo pipefail
  rm -f /home/ubuntu/.ssh/authorized_keys /root/.ssh/authorized_keys
  rm -f /etc/ssh/*_key /etc/ssh/*_key.pub
'

echo "[bootfast-runner-user] applying unit policy"
bash "${HELPER_DIR}/runner-finalize-units.sh" bootfast
