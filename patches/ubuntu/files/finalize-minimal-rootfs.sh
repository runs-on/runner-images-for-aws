#!/usr/bin/env bash

set -euo pipefail

ROOTFS_COMPACTION_HELPER="${ROOTFS_COMPACTION_HELPER:-/tmp/rootfs-compaction.sh}"
MINIMAL_TARGET_STATE_FILE="${MINIMAL_TARGET_STATE_FILE:-/var/lib/runs-on/minimal-target/state.env}"
INSTALLER_SCRIPT_FOLDER="${INSTALLER_SCRIPT_FOLDER:-/imagegeneration/installers}"
IMAGE_FOLDER="${IMAGE_FOLDER:-/imagegeneration}"
HELPER_SCRIPTS="${HELPER_SCRIPTS:-${IMAGE_FOLDER}/helpers}"

source "${ROOTFS_COMPACTION_HELPER}"
source "${HELPER_SCRIPTS}/install.sh"

log() {
  echo "[finalize-minimal-rootfs] $*"
}

cleanup_root() {
  local root="$1"

  set +e
  for mountpoint in \
    "$root/dev/pts" \
    "$root/dev" \
    "$root/proc" \
    "$root/sys" \
    "$root/run" \
    "$root"
  do
    mountpoint -q "$mountpoint" && umount "$mountpoint"
  done
  set -e
}

install_host_upx() {
  local upx_url=""

  upx_url="$(resolve_github_release_asset_url "upx/upx" "endswith(\"amd64_linux.tar.xz\")" "latest")"
  download_with_retry "${upx_url}" "/tmp/upx.tar.xz" >/dev/null
  python3 - <<'PY'
import tarfile

with tarfile.open('/tmp/upx.tar.xz', 'r:xz') as archive:
    member = next(item for item in archive.getmembers() if item.name.endswith('/upx'))
    member.name = 'upx'
    archive.extract(member, '/tmp')
PY
  install -m 0755 /tmp/upx /usr/local/bin/upx
}

cleanup_host_upx() {
  rm -f /usr/local/bin/upx /tmp/upx /tmp/upx.tar.xz
}

compress_target_binary() {
  local binary_path="$1"
  local backup_path="${binary_path}.orig"
  local before=""
  local after=""

  if [[ ! -f "${binary_path}" ]]; then
    echo "Missing target binary for UPX compression: ${binary_path}" >&2
    exit 1
  fi

  before="$(stat -c %s "${binary_path}")"
  cp -p "${binary_path}" "${backup_path}"
  if /usr/local/bin/upx --best --lzma "${binary_path}" && /usr/local/bin/upx -t "${binary_path}"; then
    after="$(stat -c %s "${binary_path}")"
    log "UPX compressed ${binary_path}: ${before} -> ${after} bytes"
    rm -f "${backup_path}"
  else
    mv -f "${backup_path}" "${binary_path}"
    log "UPX skipped ${binary_path} after compression/test failure"
  fi
}

compress_target_docker_binaries() {
  install_host_upx
  trap cleanup_host_upx RETURN

  for relative_path in \
    /usr/libexec/docker/cli-plugins/docker-buildx \
    /usr/bin/dockerd \
    /usr/libexec/docker/cli-plugins/docker-compose \
    /usr/bin/containerd \
    /usr/bin/ctr; do
    compress_target_binary "${TARGET_ROOT_MOUNT}${relative_path}"
  done
}

if [[ ! -f "${MINIMAL_TARGET_STATE_FILE}" ]]; then
  echo "Missing target state file ${MINIMAL_TARGET_STATE_FILE}" >&2
  exit 1
fi

source "${MINIMAL_TARGET_STATE_FILE}"

if [[ -f "${TARGET_ROOT_MOUNT}${INSTALLER_SCRIPT_FOLDER}/cleanup.sh" ]]; then
  log "running installer cleanup inside target root"
  ro-run-script-in-target "${INSTALLER_SCRIPT_FOLDER}/cleanup.sh"
fi

log "compressing target docker binaries with host-side UPX"
compress_target_docker_binaries

log "finalizing sparse rootfs image"
finalize_sparse_rootfs_image "${TARGET_ROOT_MOUNT}" "${LOOP_DISK}" "${SPARSE_IMAGE}" "${TARGET_DISK}" cleanup_root

log "materialization completed; clearing build state"
rm -f "${MINIMAL_TARGET_STATE_FILE}"
