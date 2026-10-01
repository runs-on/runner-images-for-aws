#!/bin/bash
set -exo pipefail

# Let first-boot APT configuration finish before replacing its sources.
cloud-init status --wait

# SHA-256 of each pinned release asset, from the release's checksums.txt. v0.1.9
# publishes only per-asset .md5 files; its hashes match those.
bootstrap_sha256() {
  case "$1-$(uname -m)" in
    v0.1.17-x86_64) echo 1cb31b7988da2d705256f17b1c3da2956423fac53a2c4a6c36a4f4a4e0b82d86 ;;
    v0.1.17-aarch64) echo 5bebba9f776bb35a6397d7e8bd95991cd7d4f93bd867d6b66c0af8286b7f6ee7 ;;
    v0.1.12-x86_64) echo a387bf964c573daabaf753d42213bfec5931b9a71d01325442253e6caa3dd115 ;;
    v0.1.12-aarch64) echo 9fa9eda93563557a67b6ebcf3311a772c274f71bc2b6121af056b0778f185d2f ;;
    v0.1.9-x86_64) echo 64fcfe5b327b2a75a13846467df2692354618718377ae1465ff847f10651d23b ;;
    v0.1.9-aarch64) echo 8f193935c11050e49abe4ecc81880464ba6b3fd43e43e29baa77d5ba8be255a7 ;;
    *) echo "No pinned SHA-256 for RunsOn bootstrap $1 on $(uname -m)" >&2; return 1 ;;
  esac
}

# install RunsOn bootstrap binaries - IMPORTANT: only delete old ones when RunsOn stack versions that use them are deprecated
for BOOTSTRAP_VERSION in v0.1.17 v0.1.12 v0.1.9; do
  BOOTSTRAP_BIN=/usr/local/bin/runs-on-bootstrap-${BOOTSTRAP_VERSION}
  BOOTSTRAP_SHA256=$(bootstrap_sha256 ${BOOTSTRAP_VERSION})
  curl -fL --connect-timeout 3 --max-time 15 --retry 5 -s https://github.com/runs-on/bootstrap/releases/download/${BOOTSTRAP_VERSION}/bootstrap-${BOOTSTRAP_VERSION}-linux-$(uname -m) -o $BOOTSTRAP_BIN
  echo "${BOOTSTRAP_SHA256}  ${BOOTSTRAP_BIN}" | sha256sum -c -
  chmod +x $BOOTSTRAP_BIN
  $BOOTSTRAP_BIN -h
done

cat > /root/.gemrc <<EOF
gem: --no-document
EOF

arch=$(dpkg --print-architecture)
apt_primary_mirror="https://archive.ubuntu.com/ubuntu/"
apt_security_mirror="https://security.ubuntu.com/ubuntu/"
if [ "$arch" = "arm64" ]; then
  apt_primary_mirror="https://ports.ubuntu.com/ubuntu-ports/"
  apt_security_mirror="$apt_primary_mirror"
fi

# Replace ec2 regional mirrors with official Ubuntu mirrors before any apt call.
# Handles both deb822 (.sources) and legacy (sources.list) formats.
rewrite_apt_source() {
  local f="$1"
  if [ -f "$f" ]; then
    sed -i -E \
      -e "s#https?://[^/]*\.ec2\.(archive|ports)\.ubuntu\.com/(ubuntu|ubuntu-ports)/?#${apt_primary_mirror}#g" \
      -e "s#https?://security\.ubuntu\.com/ubuntu/?#${apt_security_mirror}#g" \
      -e "s#https?://ports\.ubuntu\.com/ubuntu-ports/?#${apt_primary_mirror}#g" \
      "$f"
  fi
}
for src in /etc/apt/sources.list /etc/apt/sources.list.d/*.sources; do
  rewrite_apt_source "$src"
done

# will be installed as classic debian package, to save space
snap remove amazon-ssm-agent
snap remove core18
snap remove lxd
snap remove core20
rm -rf /var/lib/snapd/seed/snaps

wget https://amazoncloudwatch-agent.s3.amazonaws.com/ubuntu/amd64/latest/amazon-cloudwatch-agent.deb
dpkg -i -E ./amazon-cloudwatch-agent.deb
systemctl disable amazon-cloudwatch-agent
rm -f ./amazon-cloudwatch-agent.deb

cat >> /opt/aws/amazon-cloudwatch-agent/etc/common-config.toml <<EOF
[agent]
auto_update = false
EOF

# https://docs.aws.amazon.com/systems-manager/latest/userguide/agent-install-ubuntu-64-deb.html
wget https://s3.amazonaws.com/ec2-downloads-windows/SSMAgent/latest/debian_amd64/amazon-ssm-agent.deb
dpkg -i amazon-ssm-agent.deb
systemctl enable amazon-ssm-agent
rm -f amazon-ssm-agent.deb

apt-get update -qq
wget https://runs-on.s3.eu-west-1.amazonaws.com/tools/efs-utils/amazon-efs-utils-2.3.0-1_amd64.deb
apt-get install -y ./amazon-efs-utils-2.3.0-1_amd64.deb
rm -f amazon-efs-utils-2.3.0-1_amd64.deb

# avoid nvme0n1: Process '/usr/bin/unshare -m /usr/bin/snap auto-import --mount=/dev/nvme0n1' failed with exit code 1.
snap set system experimental.hotplug=false

# saves ~1s on cloud-init (`cloud-init analyze blame`)
arch=$(dpkg --print-architecture)
codename=$(lsb_release --codename -s)
sed -i 's|release = util.lsb_release()\["codename"\].*|release = "'$codename'"|w /dev/stdout' /usr/lib/python3/dist-packages/cloudinit/config/cc_apt_configure.py | grep $codename
sed -i 's|util.get_dpkg_architecture()|"'$arch'"|w /dev/stdout' /usr/lib/python3/dist-packages/cloudinit/config/cc_apt_configure.py | grep $arch
sed -i 's|util.get_dpkg_architecture()|"'$arch'"|w /dev/stdout' /usr/lib/python3/dist-packages/cloudinit/distros/debian.py | grep $arch

cat > /etc/cloud/cloud.cfg.d/01_runs_on.cfg <<EOF
ssh_quiet_keygen: true
# keep true otherwise harder to build derivative images with packer
allow_public_ssh_keys: true
# keep default, but make it explicit
disable_root: true
ssh_deletekeys: true
ssh_genkeytypes: [ed25519]

apt:
  preserve_sources_list: false
  primary:
    - arches: [default]
      uri: "${apt_primary_mirror}"
  security:
    - arches: [default]
      uri: "${apt_security_mirror}"

# The modules that run in the 'init' stage.
# users_groups is probably required for allow_public_ssh_keys to work
cloud_init_modules:
  - seed_random
  - users_groups

# The modules that run in the 'config' stage
cloud_config_modules:
  - ssh
  - apt_configure
  - scripts_user

# The modules that run in the 'final' stage. Keep at least one so that `cloud-init status` does not return error
cloud_final_modules:
  - final_message
EOF
