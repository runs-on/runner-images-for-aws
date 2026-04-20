#!/usr/bin/env bash

set -euo pipefail

TARGET_ROOT_MOUNT="${TARGET_ROOT_MOUNT:-}"
IMAGE_FOLDER="${IMAGE_FOLDER:-/imagegeneration}"
DEBIAN_FRONTEND="${DEBIAN_FRONTEND:-noninteractive}"

log() {
  echo "[runner-finalize-cleanup] $*"
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

log "applying cleanup and disk trimming policy"
target_bash <<'EOF'
set -euo pipefail
shopt -s nullglob globstar

install -d -m 0755 /etc/chrony
echo 'server 169.254.169.123 prefer iburst minpoll 4 maxpoll 4' > /etc/chrony/chrony.conf

sed -i 's/^Storage=Volatile$/Storage=volatile/' /etc/systemd/journald.conf
grep -qxF 'Storage=volatile' /etc/systemd/journald.conf || echo 'Storage=volatile' >> /etc/systemd/journald.conf
grep -qxF 'RuntimeMaxUse=64M' /etc/systemd/journald.conf || echo 'RuntimeMaxUse=64M' >> /etc/systemd/journald.conf

apt-get purge -y plymouth update-notifier-common multipath-tools || true

rm -f /home/ubuntu/minikube-linux-amd64
rm -rf /usr/share/doc /usr/share/man /usr/share/icons
rm -rf /usr/local/n /usr/local/doc
rm -rf /var/lib/gems/**/doc /var/lib/gems/**/cache /usr/share/ri
rm -rf /usr/local/share/vcpkg/.git
rm -rf /var/lib/ubuntu-advantage

for dir in /opt/hostedtoolcache/Python/**/**/lib/python*/test; do
  rm -rf "${dir}"
done
for dir in /opt/hostedtoolcache/go/**/**/test; do
  rm -rf "${dir}"
done
for dir in /opt/hostedtoolcache/PyPy/**/**/lib/pypy*/test; do
  rm -rf "${dir}"
done

for dir in .sbt .cargo .rustup .nvm .dotnet; do
  if [[ -d "/etc/skel/${dir}" ]]; then
    rm -rf "/home/runner/${dir}"
    mv "/etc/skel/${dir}" /home/runner/
  fi
  rm -rf "/root/${dir}"
done

cp /etc/skel/.bashrc /root/
cp /etc/skel/.profile /root/

apt-get autoremove --purge -y snapd || true
apt-mark hold snapd || true
rm -rf /var/cache/snapd /root/snap

chown -R runner:runner /home/runner

apt-get clean
rm -rf /var/lib/apt/lists/*
EOF
