 #!/bin/bash 
set -ex

# Check FS on next boot for the / mount
tune2fs -c 0 $(cat /proc/self/mounts | grep " / " | cut -f 1 -d " ")

# Stopped-pool preparation masks polkit. If PackageKit remains installed, its
# APT hook waits for a DBus activation that cannot initialize after resume.
for package in packagekit packagekit-tools; do
  if dpkg-query -W -f='${db:Status-Status}' "$package" 2>/dev/null | grep -qx installed; then
    DEBIAN_FRONTEND=noninteractive apt-get purge -y "$package"
  fi
done
test ! -e /etc/apt/apt.conf.d/20packagekit

# cloud-init's init-local stage runs dhcpcd for a throwaway lease to reach IMDS.
# Skip its randomised start delay (measured 0.2-2.0 s on EC2).
if [ -f /etc/dhcpcd.conf ] && ! grep -qx nodelay /etc/dhcpcd.conf; then
  echo nodelay >> /etc/dhcpcd.conf
fi

rm -rf /var/lib/apt/lists

cloud-init clean --logs
rm -rf /var/lib/cloud/*

# ensure no ssh keys are present
rm -f /home/ubuntu/.ssh/authorized_keys /root/.ssh/authorized_keys

# Remove SSH host key pairs - https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/building-shared-amis.html#remove-ssh-host-key-pairs
shred -u /etc/ssh/*_key /etc/ssh/*_key.pub

# disable ssh daemon by default, do this after VM has rebooted
systemctl disable ssh.service

# Keep the cloud image's initrdless boot. GRUB sets initrdfail before each
# initrdless attempt and grub-initrd-fallback.service clears it once userspace
# is up. A flag left set makes GRUB load the full initramfs on every later boot,
# including every instance launched from this AMI (measured 1.1-1.9 s).
for unit in grub-common.service grub-initrd-fallback.service; do
  if systemctl list-unit-files "${unit}" --no-legend | grep -q "^${unit}"; then
    systemctl enable "${unit}"
  fi
done
for variable in initrdfail initrdless_boot_fallback_triggered recordfail prev_entry; do
  grub-editenv /boot/grub/grubenv unset "${variable}" || true
done

# Journals from the build instance must not ship in the AMI.
find /var/log/journal -mindepth 1 -delete || true
