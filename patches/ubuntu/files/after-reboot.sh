#!/usr/bin/env bash
set -ex

# Check the real ext filesystem, not the OverlayFS facade used by compact roots.
root_mount=/
backing_marker=/etc/runs-on-overlay/backing-root-mount
if [[ -e "${backing_marker}" ]]; then
  [[ -f "${backing_marker}" && ! -L "${backing_marker}" ]]
  mapfile -t backing_lines < "${backing_marker}"
  [[ "${#backing_lines[@]}" -eq 1 ]]
  root_mount="${backing_lines[0]}"
  [[ "${root_mount}" =~ ^/[A-Za-z0-9._/-]+$ && "${root_mount}" != / ]]
  [[ "$(readlink -m "${root_mount}")" == "${root_mount}" ]]
fi
[[ "$(findmnt -nro TARGET --target "${root_mount}")" == "${root_mount}" ]]
root_source="$(readlink -f "$(findmnt -nro SOURCE --target "${root_mount}")")"
root_fstype="$(findmnt -nro FSTYPE --target "${root_mount}")"
[[ -b "${root_source}" && "${root_fstype}" =~ ^ext[234]$ ]]
tune2fs -c 0 "${root_source}"

# Stopped-pool preparation masks polkit. If PackageKit remains installed, its
# APT hook waits for a DBus activation that cannot initialize after resume.
for package in packagekit packagekit-tools; do
  if dpkg-query -W -f='${db:Status-Status}' "$package" 2>/dev/null | grep -qx installed; then
    DEBIAN_FRONTEND=noninteractive apt-get purge -y "$package"
  fi
done
test ! -e /etc/apt/apt.conf.d/20packagekit

rm -rf /var/lib/apt/lists

cloud-init clean --logs
rm -rf /var/lib/cloud/*

# ensure no ssh keys are present
rm -f /home/ubuntu/.ssh/authorized_keys /root/.ssh/authorized_keys

# Remove SSH host key pairs - https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/building-shared-amis.html#remove-ssh-host-key-pairs
shred -u /etc/ssh/*_key /etc/ssh/*_key.pub

# disable ssh daemon by default, do this after VM has rebooted
systemctl disable ssh.service
