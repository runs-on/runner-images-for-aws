#!/bin/bash

set -exo pipefail

cat > /root/.gemrc <<EOF
gem: --no-document
EOF

cat > /etc/cloud/cloud.cfg.d/01_runs_on.cfg <<EOF
# The modules that run in the 'init' stage
cloud_init_modules:
  - seed_random
  - growpart
  - resizefs
  - disk_setup
  - mounts
  - users_groups
  - ssh

# The modules that run in the 'config' stage
cloud_config_modules:
  - apt_pipelining
  - apt_configure
  - scripts_user

# The modules that run in the 'final' stage
cloud_final_modules: []
EOF