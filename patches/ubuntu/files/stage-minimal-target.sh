#!/usr/bin/env bash

set -euo pipefail

TARGET_ROOT_MOUNT="${TARGET_ROOT_MOUNT:-/mnt/minimal-root}"
IMAGE_FOLDER="${IMAGE_FOLDER:-/imagegeneration}"
TARGET_UBUNTU_MIRROR="${TARGET_UBUNTU_MIRROR:-http://archive.ubuntu.com/ubuntu/}"
TARGET_UBUNTU_SECURITY_MIRROR="${TARGET_UBUNTU_SECURITY_MIRROR:-http://security.ubuntu.com/ubuntu/}"
WAAGENT_CONFIG_SOURCE="${WAAGENT_CONFIG_SOURCE:-/etc/waagent.conf}"

log() {
  echo "[stage-minimal-target] $*"
}

if [[ ! -x /usr/local/bin/ro-run-in-target || ! -x /usr/local/bin/ro-bash-in-target ]]; then
  echo "Target chroot helpers are missing; run bootstrap-minimal-base.sh first" >&2
  exit 1
fi

log "copying staged imagegeneration payload into target root"
cp -a "${IMAGE_FOLDER}" "${TARGET_ROOT_MOUNT}/"

if [[ -f "${WAAGENT_CONFIG_SOURCE}" ]]; then
  log "copying waagent config into target root"
  install -D -m 0644 "${WAAGENT_CONFIG_SOURCE}" "${TARGET_ROOT_MOUNT}/etc/waagent.conf"
fi

log "installing installer prerequisites inside target root"
ro-run-in-target \
  "apt-get update && apt-get install -y --no-install-recommends lsb-release sudo man-db jq curl gpg"

log "ensuring runner compatibility user exists in target root"
ro-bash-in-target <<'EOF'
set -euo pipefail

if ! id -u runner >/dev/null 2>&1; then
  useradd --create-home --shell /bin/bash --uid 1001 runner
fi
EOF

log "seeding compatibility files and canonical apt sources"
TARGET_UBUNTU_MIRROR="${TARGET_UBUNTU_MIRROR}" \
TARGET_UBUNTU_SECURITY_MIRROR="${TARGET_UBUNTU_SECURITY_MIRROR}" \
ro-bash-in-target <<'EOF'
set -euo pipefail

mkdir -p /etc/default /etc/apt/sources.list.d /etc/cloud/templates
touch /etc/default/motd-news /etc/environment

if grep -q '^DEBIAN_FRONTEND=' /etc/environment; then
  sed -i 's|^DEBIAN_FRONTEND=.*|DEBIAN_FRONTEND=noninteractive|' /etc/environment
else
  printf '%s\n' 'DEBIAN_FRONTEND=noninteractive' >> /etc/environment
fi

cat > /etc/apt/sources.list.d/ubuntu.sources <<APT_SOURCES
Types: deb
URIs: ${TARGET_UBUNTU_MIRROR}
Suites: noble noble-updates noble-backports
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg

Types: deb
URIs: ${TARGET_UBUNTU_SECURITY_MIRROR}
Suites: noble-security
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
APT_SOURCES

cat > /etc/apt/apt-mirrors.txt <<APT_MIRRORS
${TARGET_UBUNTU_MIRROR}	priority:1
http://archive.ubuntu.com/ubuntu/	priority:2
${TARGET_UBUNTU_SECURITY_MIRROR}	priority:3
APT_MIRRORS

rm -f /etc/apt/sources.list /etc/cloud/templates/sources.list.ubuntu.tmpl
EOF

log "target staging completed"
