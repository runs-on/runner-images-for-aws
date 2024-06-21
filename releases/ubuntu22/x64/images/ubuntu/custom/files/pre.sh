#!/bin/bash
set -exo pipefail

cat > /root/.gemrc <<EOF
gem: --no-document
EOF

cd /tmp
wget https://amazoncloudwatch-agent.s3.amazonaws.com/ubuntu/amd64/latest/amazon-cloudwatch-agent.deb
sudo dpkg -i -E ./amazon-cloudwatch-agent.deb
systemctl disable amazon-cloudwatch-agent
rm -f ./amazon-cloudwatch-agent.deb
cd -

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