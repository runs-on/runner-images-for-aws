 #!/bin/bash 
set -ex

# Check FS on next boot for the / mount
tune2fs -c 0 $(cat /proc/self/mounts | grep " / " | cut -f 1 -d " ")

# Stopped-pool preparation masks polkit. If PackageKit remains installed, its
# APT hook waits for a DBus activation that cannot initialize after resume.
packagekit_packages=()
for package in packagekit packagekit-tools; do
  if dpkg-query -W -f='${db:Status-Status}' "$package" 2>/dev/null | grep -qx installed; then
    packagekit_packages+=("$package")
  fi
done
if (( ${#packagekit_packages[@]} )); then
  DEBIAN_FRONTEND=noninteractive apt-get purge -y "${packagekit_packages[@]}"
fi
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
