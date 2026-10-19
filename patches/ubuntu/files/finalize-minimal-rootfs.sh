#!/usr/bin/env bash

set -euo pipefail

ROOTFS_COMPACTION_HELPER="${ROOTFS_COMPACTION_HELPER:-/tmp/rootfs-compaction.sh}"
MINIMAL_TARGET_STATE_FILE="${MINIMAL_TARGET_STATE_FILE:-/var/lib/runs-on/minimal-target/state.env}"
INSTALLER_SCRIPT_FOLDER="${INSTALLER_SCRIPT_FOLDER:-/imagegeneration/installers}"
IMAGE_FOLDER="${IMAGE_FOLDER:-/imagegeneration}"
HELPER_SCRIPTS="${HELPER_SCRIPTS:-${IMAGE_FOLDER}/helpers}"
UPX_ARCH="${UPX_ARCH:-amd64}"

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
    "$root/boot/efi" \
    "$root"
  do
    mountpoint -q "$mountpoint" && umount "$mountpoint"
  done
  set -e
  # Copying the image of a still-mounted filesystem loses whatever it has not
  # written back yet.
  if mountpoint -q "$root"; then
    echo "Failed to unmount ${root}" >&2
    exit 1
  fi
}

prepare_rootfs_for_compaction() {
  local root="$1"

  if [[ -f "${root}${INSTALLER_SCRIPT_FOLDER}/cleanup.sh" ]]; then
    log "running installer cleanup inside target root"
    ro-run-script-in-target "${INSTALLER_SCRIPT_FOLDER}/cleanup.sh"
  fi

  log "compressing target binaries with host-side UPX"
  install_host_upx
  trap cleanup_host_upx RETURN
  compress_target_docker_binaries
  compress_target_runner_node_binaries
}

# update-grub inside the target writes the build host's loop partition as the
# root device, and later in-target steps rerun it (upstream's
# configure-environment.sh, kernel upgrades). Pin the root device once every
# step is done, and refuse an image that would boot from a loop device.
pin_grub_root_partuuid() {
  local grub_cfg="${TARGET_ROOT_MOUNT}/boot/grub/grub.cfg"

  if [[ -z "${ROOT_PARTUUID:-}" ]]; then
    echo "Missing ROOT_PARTUUID in ${MINIMAL_TARGET_STATE_FILE}" >&2
    exit 1
  fi

  log "pinning grub root device to PARTUUID=${ROOT_PARTUUID}"
  sed -E -i "s#root=/dev/loop[0-9]+p[0-9]+#root=PARTUUID=${ROOT_PARTUUID}#g" "${grub_cfg}"
  if grep -q 'root=/dev/loop' "${grub_cfg}"; then
    echo "grub.cfg still boots from a loop device:" >&2
    grep -n 'root=/dev/loop' "${grub_cfg}" >&2
    exit 1
  fi
}

# Minimal images boot straight into a unified kernel image, skipping GRUB.
# With no UEFI variables in the AMI, the firmware loads the removable-media
# path, so the UKI carries the command line GRUB would pass, read from the
# pinned grub.cfg. GRUB stays installed: x64 instance types without UEFI
# boot it from the BIOS boot partition.
build_uki() {
  local grub_cfg="${TARGET_ROOT_MOUNT}/boot/grub/grub.cfg"
  local linux_line kernel cmdline stub output

  # The target ships only its own architecture's stub (linuxx64 or
  # linuxaa64), which also names the removable-media loader. bin/patch
  # rewrites every architecture literal in this file for arm64.
  local -a stubs=("${TARGET_ROOT_MOUNT}"/usr/lib/systemd/boot/efi/linux*.efi.stub)
  [[ "${#stubs[@]}" -eq 1 && -f "${stubs[0]}" ]] || { echo "Expected one systemd-stub, found: ${stubs[*]}" >&2; exit 1; }
  stub="${stubs[0]}"
  local efi_arch="${stub##*/linux}"
  efi_arch="${efi_arch%.efi.stub}"
  output="${TARGET_ROOT_MOUNT}/boot/efi/EFI/BOOT/BOOT$(tr a-z A-Z <<< "${efi_arch}").EFI"

  linux_line="$(awk '$1 == "linux" { print; exit }' "${grub_cfg}")"
  kernel="${TARGET_ROOT_MOUNT}$(awk '{ print $2 }' <<< "${linux_line}")"
  cmdline="$(awk '{ $1 = ""; $2 = ""; sub(/^ +/, ""); print }' <<< "${linux_line}")"
  [[ -f "${kernel}" ]] || { echo "Missing kernel ${kernel}" >&2; exit 1; }
  [[ "${cmdline}" == *"root=PARTUUID=${ROOT_PARTUUID}"* ]] || { echo "UKI command line lacks the pinned root: ${cmdline}" >&2; exit 1; }

  # Noble's ukify crashes looking the release up without readelf.
  local release="${kernel##*/vmlinuz-}"

  # systemd-stub needs a PE kernel; arm64 kernels ship gzip-compressed.
  if [[ "$(od -An -tx1 -N2 "${kernel}" | tr -d '[:space:]')" == "1f8b" ]]; then
    zcat "${kernel}" > /tmp/uki-vmlinux
    kernel=/tmp/uki-vmlinux
  fi

  log "building ${efi_arch} UKI from ${kernel#"${TARGET_ROOT_MOUNT}"} with: ${cmdline}"
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends systemd-ukify >/dev/null
  install -d "$(dirname "${output}")"
  # No early-microcode initrd: Nitro owns the microcode of a virtual machine
  # and the guest cannot load any, so the 15 MB archive only slowed the
  # firmware's read of the UKI. Metal instances keep the packages on disk.
  ukify build \
    --linux "${kernel}" \
    --uname "${release}" \
    --cmdline "${cmdline}" \
    --stub "${stub}" \
    --output "${output}"
  rm -f /tmp/uki-vmlinux
}

install_host_upx() {
  local upx_url=""

  upx_url="$(resolve_github_release_asset_url "upx/upx" "endswith(\"${UPX_ARCH}_linux.tar.xz\")" "latest")"
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
  for relative_path in \
    /usr/libexec/docker/cli-plugins/docker-buildx \
    /usr/bin/dockerd \
    /usr/libexec/docker/cli-plugins/docker-compose \
    /usr/bin/containerd \
    /usr/bin/ctr; do
    compress_target_binary "${TARGET_ROOT_MOUNT}${relative_path}"
  done
}

compress_target_runner_node_binaries() {
  for relative_path in \
    /home/runner/externals/node24/bin/node \
    /home/runner/externals/node24_alpine/bin/node; do
    # Runner releases can omit optional externals such as node24_alpine.
    if [[ ! -f "${TARGET_ROOT_MOUNT}${relative_path}" ]]; then
      log "skipping missing runner Node binary ${TARGET_ROOT_MOUNT}${relative_path}"
      continue
    fi

    compress_target_binary "${TARGET_ROOT_MOUNT}${relative_path}"
  done
}

if [[ ! -f "${MINIMAL_TARGET_STATE_FILE}" ]]; then
  echo "Missing target state file ${MINIMAL_TARGET_STATE_FILE}" >&2
  exit 1
fi

source "${MINIMAL_TARGET_STATE_FILE}"

pin_grub_root_partuuid
build_uki

log "finalizing sparse rootfs image"
finalize_sparse_rootfs_image \
  "${TARGET_ROOT_MOUNT}" \
  "${LOOP_DISK}" \
  "${SPARSE_IMAGE}" \
  "${TARGET_DISK}" \
  prepare_rootfs_for_compaction \
  cleanup_root

log "materialization completed; clearing build state"
rm -f "${MINIMAL_TARGET_STATE_FILE}"
