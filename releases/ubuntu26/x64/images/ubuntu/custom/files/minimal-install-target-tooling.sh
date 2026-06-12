#!/usr/bin/env bash

set -euo pipefail

IMAGE_FOLDER="${IMAGE_FOLDER:-/imagegeneration}"
INSTALLER_SCRIPT_FOLDER="${INSTALLER_SCRIPT_FOLDER:-${IMAGE_FOLDER}/installers}"

apt-get install -y --no-install-recommends \
  netcat-openbsd \
  unzip \
  zip

if ! command -v netcat >/dev/null 2>&1; then
  ln -sf /usr/bin/nc /usr/bin/netcat
fi

if ! command -v pwsh >/dev/null 2>&1; then
  cat > /usr/local/bin/invoke_tests <<'EOF'
#!/bin/bash
echo "Skipping invoke_tests: pwsh not installed"
EOF
  chmod +x /usr/local/bin/invoke_tests
fi

apt-get install -y --no-install-recommends git

if ! grep -Fq 'directory = *' /etc/gitconfig 2>/dev/null; then
  cat >> /etc/gitconfig <<'EOF'
[safe]
        directory = *
EOF
fi

if command -v ssh-keyscan >/dev/null 2>&1; then
  mkdir -p /etc/ssh
  ssh-keyscan -t rsa,ecdsa,ed25519 github.com >> /etc/ssh/ssh_known_hosts 2>/dev/null || true
  ssh-keyscan -t rsa ssh.dev.azure.com >> /etc/ssh/ssh_known_hosts 2>/dev/null || true
fi

bash "${INSTALLER_SCRIPT_FOLDER}/install-python.sh"
