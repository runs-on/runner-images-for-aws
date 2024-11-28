#!/bin/bash
set -exo pipefail

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

# https://docs.aws.amazon.com/systems-manager/latest/userguide/agent-install-ubuntu-64-deb.html
wget https://s3.amazonaws.com/ec2-downloads-windows/SSMAgent/latest/debian_arm64/amazon-ssm-agent.deb
dpkg -i amazon-ssm-agent.deb
systemctl enable amazon-ssm-agent
rm -f amazon-ssm-agent.deb

# avoid nvme0n1: Process '/usr/bin/unshare -m /usr/bin/snap auto-import --mount=/dev/nvme0n1' failed with exit code 1.
snap set system experimental.hotplug=false

cat > /etc/cloud/cloud.cfg.d/01_runs_on.cfg <<EOF
# The modules that run in the 'init' stage
cloud_init_modules:
  - seed_random
  - users_groups
  - ssh

# The modules that run in the 'config' stage
cloud_config_modules:
  - apt_pipelining
  - apt_configure
  - scripts_user

# The modules that run in the 'final' stage. Keep at least one so that `cloud-init status` does not return error
cloud_final_modules:
  - final_message
EOF