#!/usr/bin/env bash

set -euo pipefail

TARGET_ROOT_MOUNT="${TARGET_ROOT_MOUNT:-}"
IMAGE_FOLDER="${IMAGE_FOLDER:-/imagegeneration}"
DEBIAN_FRONTEND="${DEBIAN_FRONTEND:-noninteractive}"

log() {
  echo "[runner-finalize-nested-virt] $*"
}

target_bash() {
  if [[ -n "${TARGET_ROOT_MOUNT}" ]]; then
    chroot "${TARGET_ROOT_MOUNT}" /usr/bin/env \
      DEBIAN_FRONTEND="${DEBIAN_FRONTEND}" \
      IMAGE_FOLDER="${IMAGE_FOLDER}" \
      /bin/bash -s
  else
    /usr/bin/env \
      DEBIAN_FRONTEND="${DEBIAN_FRONTEND}" \
      IMAGE_FOLDER="${IMAGE_FOLDER}" \
      /bin/bash -s
  fi
}

log "installing nested virtualization packages"
target_bash <<'EOF'
set -euo pipefail

apt-get install -y \
  bridge-utils \
  libvirt-clients \
  libvirt-daemon-system \
  qemu-kvm \
  virtinst

usermod -aG kvm runner || true
EOF

if [[ -z "${TARGET_ROOT_MOUNT}" ]]; then
  log "loading kvm module on build host"
  modprobe kvm || true
fi
