#!/bin/bash
set -exo pipefail

# install RunsOn bootstrap binaries - IMPORTANT: only delete old ones when RunsOn stack versions that use them are deprecated
for BOOTSTRAP_VERSION in v0.1.12 v0.1.9; do
  BOOTSTRAP_BIN=/usr/local/bin/runs-on-bootstrap-${BOOTSTRAP_VERSION}
  curl -L --connect-time 3 --max-time 15 --retry 5 -s https://github.com/runs-on/bootstrap/releases/download/${BOOTSTRAP_VERSION}/bootstrap-${BOOTSTRAP_VERSION}-linux-$(uname -i) -o $BOOTSTRAP_BIN
  chmod +x $BOOTSTRAP_BIN
  $BOOTSTRAP_BIN -h
done

cat > /root/.gemrc <<EOF
gem: --no-document
EOF

# will be installed as classic debian package, to save space
snap remove amazon-ssm-agent
snap remove core18
snap remove lxd
snap remove core20
rm -rf /var/lib/snapd/seed/snaps

wget https://amazoncloudwatch-agent.s3.amazonaws.com/ubuntu/arm64/latest/amazon-cloudwatch-agent.deb
dpkg -i -E ./amazon-cloudwatch-agent.deb
systemctl disable amazon-cloudwatch-agent
rm -f ./amazon-cloudwatch-agent.deb

cat >> /opt/aws/amazon-cloudwatch-agent/etc/common-config.toml <<EOF
[agent]
auto_update = false
EOF

# https://docs.aws.amazon.com/systems-manager/latest/userguide/agent-install-ubuntu-64-deb.html
wget https://s3.amazonaws.com/ec2-downloads-windows/SSMAgent/latest/debian_arm64/amazon-ssm-agent.deb
dpkg -i amazon-ssm-agent.deb
systemctl enable amazon-ssm-agent
rm -f amazon-ssm-agent.deb

apt-get update -qq
wget https://runs-on.s3.eu-west-1.amazonaws.com/tools/efs-utils/amazon-efs-utils-2.3.0-1_arm64.deb
apt-get install -y ./amazon-efs-utils-2.3.0-1_arm64.deb
rm -f amazon-efs-utils-2.3.0-1_arm64.deb

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