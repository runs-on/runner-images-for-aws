#!/bin/bash
# The packages Canonical's Ubuntu 26.04 AMI has beyond its cloud root tarball
# (compared on 2026-11-10), which the RunsOn scripts expect, such as
# runner-user.sh disabling hibinit-agent.service. GRUB and shim are left
# out: the converter boots a UKI.
set -euxo pipefail
apt-get update
apt-get install -y acpid ec2-hibinit-agent ec2-instance-connect irqbalance efibootmgr \
  linux-aws ubuntu-fan ubuntu-kernel-accessories
