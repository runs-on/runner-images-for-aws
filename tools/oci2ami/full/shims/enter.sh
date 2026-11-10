#!/bin/bash
# Installs the container build shims; leave.sh removes them.
set -euo pipefail
d=/opt/oci-build/shims
install -m 0755 $d/systemctl /usr/local/sbin/systemctl
install -m 0755 $d/systemd-analyze /usr/local/sbin/systemd-analyze
install -m 0755 $d/invoke_tests /usr/local/sbin/invoke_tests
for c in snap modprobe tune2fs update-grub; do install -m 0755 $d/skip /usr/local/sbin/$c; done
# Services installed by apt stay stopped, as on a packer build before reboot.
printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d && chmod 0755 /usr/sbin/policy-rc.d
