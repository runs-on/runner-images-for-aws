#!/usr/bin/env bash

set -euo pipefail

if [[ "${IMAGE_OS:-}" != "ubuntu26" ]]; then
  exit 0
fi

if ! systemctl list-unit-files rolaunch.service --no-legend | grep -q '^rolaunch.service'; then
  echo "Ubuntu 26 descendant is missing rolaunch.service" >&2
  exit 1
fi

# SSH can become available just before the one-shot launcher records success.
# Join the unit before deleting the builder instance's launch state.
systemctl start rolaunch.service
systemctl is-active --quiet rolaunch.service

# Descendant package provisioning may restore distro enablement defaults.
systemctl disable netavark-dhcp-proxy.service udisks2.service
systemctl enable netavark-dhcp-proxy.socket
rm -f \
  /etc/systemd/system/sysinit.target.wants/systemd-binfmt.service \
  /lib/systemd/system/sysinit.target.wants/systemd-binfmt.service \
  /usr/lib/systemd/system/sysinit.target.wants/systemd-binfmt.service

truncate -s 0 /etc/machine-id
rm -f /var/lib/dbus/machine-id
rm -f \
  /var/lib/rolaunch/instance-identity.json \
  /var/lib/rolaunch/runs-on-user-data.done \
  /var/lib/rolaunch/timings.json \
  /var/lib/rolaunch/user-data.sh

# Descendants retain the parent's direct networkd configuration and must not
# reuse a netplan file generated for their builder instance.
test -s /etc/systemd/network/10-runs-on-ec2.network
test -e /etc/cloud/cloud-init.disabled
rm -f /etc/netplan/*.yaml

sync
