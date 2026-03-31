#!/usr/bin/env bash

set -euo pipefail

IMAGE_FOLDER="${IMAGE_FOLDER:-/imagegeneration}"
HELPER_SCRIPTS="${HELPER_SCRIPTS:-${IMAGE_FOLDER}/helpers}"

source "${HELPER_SCRIPTS}/install.sh"

REPO_URL="https://download.docker.com/linux/ubuntu"
GPG_KEY="/usr/share/keyrings/docker.gpg"
REPO_PATH="/etc/apt/sources.list.d/docker.list"
os_codename="$(lsb_release -cs)"

curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o "${GPG_KEY}"
echo "deb [arch=amd64 signed-by=${GPG_KEY}] ${REPO_URL} ${os_codename} stable" > "${REPO_PATH}"
apt-get update

components="$(get_toolset_value '.docker.components[] .package')"
for package in ${components}; do
  version="$(get_toolset_value ".docker.components[] | select(.package == \"${package}\") | .version")"
  if [[ "${version}" == "latest" ]]; then
    apt-get install -y --no-install-recommends "${package}"
    continue
  fi

  version_string="$(apt-cache madison "${package}" | awk '{ print $3 }' | grep "${version}" | grep "${os_codename}" | head -1)"
  apt-get install -y --no-install-recommends "${package}=${version_string}"
done

plugins="$(get_toolset_value '.docker.plugins[] .plugin')"
for plugin in ${plugins}; do
  version="$(get_toolset_value ".docker.plugins[] | select(.plugin == \"${plugin}\") | .version")"
  filter="$(get_toolset_value ".docker.plugins[] | select(.plugin == \"${plugin}\") | .asset")"
  url="$(resolve_github_release_asset_url "docker/${plugin}" "endswith(\"${filter}\")" "${version}")"
  binary_path="$(download_with_retry "${url}" "/tmp/docker-${plugin}")"
  mkdir -p /usr/libexec/docker/cli-plugins
  install "${binary_path}" "/usr/libexec/docker/cli-plugins/docker-${plugin}"
done

if getent group docker >/dev/null 2>&1; then
  gid="$(cut -d ':' -f 3 /etc/group | grep '^1..$' | sort -n | tail -n 1 | awk '{ print $1+1 }')"
  groupmod -g "${gid}" docker
fi

cat > /etc/tmpfiles.d/docker.conf <<'EOF'
L /run/docker.sock - - - - root docker 0770
EOF

systemd-tmpfiles --create /etc/tmpfiles.d/docker.conf || true
systemctl is-enabled --quiet docker.socket || systemctl enable docker.socket || true
systemctl disable containerd.service docker.service || true
rm -f "${GPG_KEY}" "${REPO_PATH}"
