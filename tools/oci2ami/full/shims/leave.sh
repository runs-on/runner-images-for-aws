#!/bin/bash
set -euo pipefail
for c in systemctl systemd-analyze invoke_tests snap modprobe tune2fs update-grub; do rm -f /usr/local/sbin/$c; done
rm -f /usr/sbin/policy-rc.d
