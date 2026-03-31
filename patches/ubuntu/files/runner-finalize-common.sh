#!/usr/bin/env bash

set -euo pipefail

TARGET_ROOT_MOUNT="${TARGET_ROOT_MOUNT:-}"
IMAGE_FOLDER="${IMAGE_FOLDER:-/imagegeneration}"
DEBIAN_FRONTEND="${DEBIAN_FRONTEND:-noninteractive}"

log() {
  echo "[runner-finalize-common] $*"
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

log "updating base packages"
target_bash <<'EOF'
set -euo pipefail

apt-get update
apt-get upgrade -y
EOF

log "configuring runner user and common packages"
target_bash <<'EOF'
set -euo pipefail

if id -u runner >/dev/null 2>&1; then
  usermod --shell /bin/bash runner
else
  adduser --shell /bin/bash --disabled-password --gecos "" --uid 1001 runner
fi

usermod -aG sudo runner
grep -qxF '%sudo   ALL=(ALL:ALL) NOPASSWD:ALL' /etc/sudoers || echo '%sudo   ALL=(ALL:ALL) NOPASSWD:ALL' >> /etc/sudoers
grep -qxF 'Defaults env_keep += "DEBIAN_FRONTEND"' /etc/sudoers || echo 'Defaults env_keep += "DEBIAN_FRONTEND"' >> /etc/sudoers

need_universe=false
for package in uidmap squashfs-tools; do
  if ! apt-cache show "${package}" >/dev/null 2>&1; then
    need_universe=true
    break
  fi
done

if [[ "${need_universe}" == "true" ]]; then
  if command -v add-apt-repository >/dev/null 2>&1; then
    add-apt-repository universe
    apt-get update -qq
  else
    echo "uidmap/squashfs-tools require the universe repo but add-apt-repository is unavailable" >&2
    exit 1
  fi
fi

apt-get install -y \
  bc \
  fio \
  git-crypt \
  ncdu \
  squashfs-tools \
  uidmap

if [[ "${need_universe}" == "true" ]]; then
  add-apt-repository -r universe || true
fi

archive_path="$(find /opt/runner-cache -maxdepth 1 -type f | head -n1)"
test -n "${archive_path}"

echo "Extracting runner archive ${archive_path} into /home/runner during image build"
tar -xzf "${archive_path}" -C /home/runner

for path in \
  /home/runner/externals/node20 \
  /home/runner/externals/node20_alpine \
  /home/runner/_diag; do
  rm -rf "${path}"
done

test -x /home/runner/bin/Runner.Listener
rm -f "${archive_path}"
rm -rf /opt/runner-cache

if getent group docker >/dev/null 2>&1; then
  usermod -aG docker runner
fi

chown -R runner:runner /home/runner
EOF
