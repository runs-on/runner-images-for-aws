#!/bin/bash
set -ex

# make sure we have the latest packages
apt-get update
apt-get upgrade -y

echo "Setting up runner user..."
adduser --shell /bin/bash --disabled-password --gecos "" --uid 1001 runner
usermod -aG sudo runner
echo "%sudo   ALL=(ALL:ALL) NOPASSWD:ALL" >> /etc/sudoers
echo "Defaults env_keep += \"DEBIAN_FRONTEND\"" >> /etc/sudoers

# add bc, probably installed by PHP script originally
apt-get install -y bc
# add git-crypt
apt-get install -y git-crypt
# add ncdu
apt-get install -y ncdu
# add fio for warming up the runner
apt-get install -y fio

# add kvm virt, only available on metal instances
apt-get install -y qemu-kvm libvirt-daemon-system libvirt-clients bridge-utils virtinst
modprobe kvm
usermod -aG kvm runner

# https://github.com/runs-on/runs-on/issues/261 for apptainer
# install uidmap and squashfs-tools
add-apt-repository universe
apt-get update -qq
apt-get install -y uidmap squashfs-tools
add-apt-repository -r universe

# install archive from cache
archive_name=$(ls /opt/runner-cache)
archive_path="/opt/runner-cache/$archive_name"
echo "Installing runner from $archive_path"
tar xzf "$archive_path" -C /home/runner
rm -rf /opt/runner-cache
# test presence of run.sh
test -s /home/runner/run.sh

# warmup runner
/home/runner/bin/Runner.Listener warmup && rm -rf /home/runner/_diag

# https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/set-time.html
echo 'server 169.254.169.123 prefer iburst minpoll 4 maxpoll 4' >  /etc/chrony/chrony.conf

echo "Storage=Volatile" >> /etc/systemd/journald.conf
echo "RuntimeMaxUse=64M" >> /etc/systemd/journald.conf

apt-get purge plymouth update-notifier-common multipath-tools -y

# speed-up boot
systemctl disable timers.target
#  dev-hugepages.mount
systemctl disable console-setup.service hibinit-agent.service grub-initrd-fallback.service qemu-kvm.service lvm2-monitor.service rsyslog.service ubuntu-advantage.service vgauth.service setvtrgb.service
systemctl disable snapd.seeded.service snapd.autoimport.service snapd.core-fixup.service snapd.recovery-chooser-trigger.service snapd.system-shutdown.service
# only on ubuntu 22.04
systemctl disable update-notifier-download.service plymouth-quit.service plymouth-quit-wait.service || true
systemctl disable libvirt-guests.service libvirtd.service systemd-machined.service || true
systemctl disable mono-xsp4.service || true
systemctl disable containerd.service docker.service
systemctl disable apport.service logrotate.service grub-common.service keyboard-setup.service systemd-update-utmp.service systemd-fsck-root.service systemd-tmpfiles-setup.service apparmor.service e2scrub_reap.service || true
systemctl disable snapd.service snap.lxd.activate.service snapd.apparmor.service snap.amazon-ssm-agent.amazon-ssm-agent.service || true
# Disable firmware update services, not needed for one-shot runners
systemctl mask fwupd.service fwupd-refresh.service || true
# Disable dpkg-db-backup service, not needed for one-shot runners
systemctl mask dpkg-db-backup.service dpkg-db-backup.timer || true
# Can spawn every 24h, not needed for one-shot runners
systemctl mask apt-news.service
systemctl mask esm-cache.service || true

systemctl mask \
  dev-hugepages.mount \
  dev-mqueue.mount \
  sys-kernel-debug.mount \
  sys-kernel-tracing.mount \
  sys-fs-fuse-connections.mount

sed -i 's/^#\?Storage=.*/Storage=volatile/' /etc/systemd/journald.conf
systemctl mask systemd-journal-flush.service
systemctl mask systemd-fsck@dev-disk-by\x2dlabel-UEFI.service
systemctl mask rpcbind.service
# Can trigger DNS resolution issues when service starts while cloud-init is running. Not essential for CI ephemeral runners.
systemctl mask systemd-hostnamed.service

# Change default target from graphical to multi-user
systemctl set-default multi-user.target

# No need with SSM, only for EC2 connect which we don't use
systemctl mask ec2-instance-connect-harvest-hostkeys.service
systemctl mask ec2-instance-connect.service 

# GUI-related
systemctl mask gdm.service lightdm.service
systemctl mask ModemManager.service polkit.service udisks2.service
systemctl mask e2scrub_all.timer    # Filesystem checks
systemctl mask fstrim.timer         # SSD trim (ephemeral instances)
systemctl mask man-db.timer         # Man page index updates
systemctl mask motd-news.timer      # Ubuntu news in MOTD
systemctl mask cups.service cups.socket cups.path bluetooth.service alsa-restore.service alsa-state.service 
systemctl mask logrotate.timer
systemctl mask ufw.service
# Random number generator daemon (kernel has good entropy in VMs)
systemctl mask haveged.service
# RF kill for wireless - not needed
systemctl mask systemd-rfkill.socket systemd-rfkill.service

# USB modem/cellular rules - not needed in cloud VMs
rm -f /usr/lib/udev/rules.d/40-usb_modeswitch.rules
rm -f /usr/lib/udev/rules.d/77-mm-broadmobi-port-types.rules
rm -f /usr/lib/udev/rules.d/77-mm-cinterion-port-types.rules
rm -f /usr/lib/udev/rules.d/77-mm-dell-port-types.rules
rm -f /usr/lib/udev/rules.d/77-mm-dlink-port-types.rules
rm -f /usr/lib/udev/rules.d/77-mm-ericsson-mbm.rules
rm -f /usr/lib/udev/rules.d/77-mm-fibocom-port-types.rules
rm -f /usr/lib/udev/rules.d/77-mm-foxconn-port-types.rules
rm -f /usr/lib/udev/rules.d/77-mm-gosuncn-port-types.rules
rm -f /usr/lib/udev/rules.d/77-mm-haier-port-types.rules
rm -f /usr/lib/udev/rules.d/77-mm-huawei-net-port-types.rules
rm -f /usr/lib/udev/rules.d/77-mm-linktop-port-types.rules
rm -f /usr/lib/udev/rules.d/77-mm-longcheer-port-types.rules
rm -f /usr/lib/udev/rules.d/77-mm-mtk-legacy-port-types.rules
rm -f /usr/lib/udev/rules.d/77-mm-mtk-port-types.rules
rm -f /usr/lib/udev/rules.d/77-mm-nokia-port-types.rules
rm -f /usr/lib/udev/rules.d/77-mm-qcom-soc.rules
rm -f /usr/lib/udev/rules.d/77-mm-qdl-device-blacklist.rules
rm -f /usr/lib/udev/rules.d/77-mm-quectel-port-types.rules
rm -f /usr/lib/udev/rules.d/77-mm-sierra.rules
rm -f /usr/lib/udev/rules.d/77-mm-simtech-port-types.rules
rm -f /usr/lib/udev/rules.d/77-mm-telit-port-types.rules
rm -f /usr/lib/udev/rules.d/77-mm-tplink-port-types.rules
rm -f /usr/lib/udev/rules.d/77-mm-ublox-port-types.rules
rm -f /usr/lib/udev/rules.d/77-mm-x22x-port-types.rules
rm -f /usr/lib/udev/rules.d/77-mm-zte-port-types.rules
rm -f /usr/lib/udev/rules.d/80-mm-candidate.rules

# Input devices - no keyboards/mice/joysticks in CI
rm -f /usr/lib/udev/rules.d/60-evdev.rules
rm -f /usr/lib/udev/rules.d/60-persistent-input.rules
rm -f /usr/lib/udev/rules.d/70-joystick.rules
rm -f /usr/lib/udev/rules.d/70-mouse.rules
rm -f /usr/lib/udev/rules.d/70-touchpad.rules

# Audio/video - not needed in CI
rm -f /usr/lib/udev/rules.d/60-persistent-alsa.rules
rm -f /usr/lib/udev/rules.d/60-persistent-v4l.rules
rm -f /usr/lib/udev/rules.d/70-camera.rules
rm -f /usr/lib/udev/rules.d/78-sound-card.rules

# Physical sensors - not in VMs
rm -f /usr/lib/udev/rules.d/60-sensor.rules

# Optical drives - not in cloud VMs
rm -f /usr/lib/udev/rules.d/60-cdrom_id.rules

# FIDO/security keys - not used in CI
rm -f /usr/lib/udev/rules.d/60-fido-id.rules

# Thunderbolt - not in VMs
rm -f /usr/lib/udev/rules.d/90-bolt.rules

# Power management for laptops - not relevant
rm -f /usr/lib/udev/rules.d/70-power-switch.rules
rm -f /usr/lib/udev/rules.d/71-power-switch-proliant.rules

# Optimize filesystem mount options for better performance
# Update fstab by replacing the entire file with optimized entries
cp /etc/fstab /etc/fstab.backup
awk '
/^LABEL=cloudimg-rootfs/ { 
    if (!/noatime/) gsub(/errors=remount-ro/, "errors=remount-ro,noatime")
    print; next 
}
/^LABEL=BOOT.*ext4/ { 
    if (!/noatime/) gsub(/defaults/, "defaults,noatime")
    print; next 
}
{ print }
' /etc/fstab.backup > /etc/fstab

# Optimize kernel parameters for faster boot
cat >> /etc/sysctl.conf << EOF
# Reduce kernel log level to avoid excessive logging during boot
kernel.printk = 3 4 1 3
# Faster network initialization
net.core.netdev_max_backlog = 1000
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
EOF

cat <<EOF > /etc/default/grub
GRUB_CMDLINE_LINUX_DEFAULT="quiet nosplash console=ttyS0 fsck.mode=skip systemd.show_status=0 rd.systemd.show_status=0"
EOF
update-grub

# disable all podman services
find /lib/systemd/system -name 'podman*' -type f -exec systemctl disable {} \;

# disable all php services
find /lib/systemd/system -name 'php*' -type f -exec systemctl disable {} \;

systemctl daemon-reload

# cleanup
rm -f /home/ubuntu/minikube-linux-amd64
rm -rf /usr/share/doc
rm -rf /usr/share/man
rm -rf /usr/share/icons

# Make sure to keep linux kernel source code, useful for compiling modules etc.
# rm -rf /usr/src/linux-*

rm -rf /usr/local/n
rm -rf /usr/local/doc

rm -rf /var/lib/gems/**/doc ; rm -rf /var/lib/gems/**/cache ; rm -rf /usr/share/ri
rm -rf /usr/local/share/vcpkg/.git
rm -rf /var/lib/ubuntu-advantage

# Remove test folders from cached python versions, they take up a lot of space
for dir in /opt/hostedtoolcache/Python/**/**/lib/python*/test; do
  echo "Removing $dir"
  rm -rf "$dir"
done

for dir in /opt/hostedtoolcache/go/**/**/test; do
  echo "Removing $dir"
  rm -rf "$dir"
done

for dir in /opt/hostedtoolcache/PyPy/**/**/lib/pypy*/test; do
  echo "Removing $dir"
  rm -rf "$dir"
done

# Those dirs end up being duplicated between /etc/skel and /home/runner, just move them over
for dir in .sbt .cargo .rustup .nvm .dotnet; do
  if [ -d "/etc/skel/$dir" ]; then
    rm -rf /home/runner/$dir && mv /etc/skel/$dir /home/runner/
  fi
  rm -rf /root/$dir
done

# reset root files to blank state
cp /etc/skel/.bashrc /root/
cp /etc/skel/.profile /root/

apt autoremove --purge snapd -y
apt-mark hold snapd
rm -rf /var/cache/snapd/ /root/snap

# make sure runner user owns everything in their home directory
chown -R runner:runner /home/runner