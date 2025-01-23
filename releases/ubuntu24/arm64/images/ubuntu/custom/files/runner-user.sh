#!/bin/bash
set -ex

echo "Setting up runner user..."
adduser --shell /bin/bash --disabled-password --gecos "" --uid 1001 runner
usermod -aG sudo runner
echo "%sudo   ALL=(ALL:ALL) NOPASSWD:ALL" >> /etc/sudoers
echo "Defaults env_keep += \"DEBIAN_FRONTEND\"" >> /etc/sudoers

# add git-crypt
apt-get install -y git-crypt
# add ncdu
apt-get install -y ncdu

# add kvm virt, only available on metal instances
apt-get install -y qemu-kvm libvirt-daemon-system libvirt-clients bridge-utils virtinst
modprobe kvm
usermod -aG kvm runner

# install archive from cache
archive_name=$(ls /opt/runner-cache)
archive_path="/opt/runner-cache/$archive_name"
echo "Installing runner from $archive_path"
tar xzf "$archive_path" -C /home/runner
chown -R runner:runner /home/runner
rm -rf /opt/runner-cache
# test presence of run.sh
test -s /home/runner/run.sh

# https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/set-time.html
echo 'server 169.254.169.123 prefer iburst minpoll 4 maxpoll 4' >  /etc/chrony/chrony.conf

echo "Storage=Volatile" >> /etc/systemd/journald.conf
echo "RuntimeMaxUse=64M" >> /etc/systemd/journald.conf

apt-get purge plymouth update-notifier-common multipath-tools -y

# speed-up boot
systemctl disable timers.target
#  dev-hugepages.mount
systemctl disable console-setup.service hibinit-agent.service grub-initrd-fallback.service qemu-kvm.service lvm2-monitor.service rsyslog.service ubuntu-advantage.service vgauth.service setvtrgb.service systemd-journal-flush.service
systemctl disable snapd.seeded.service snapd.autoimport.service snapd.core-fixup.service snapd.recovery-chooser-trigger.service snapd.system-shutdown.service
# only on ubuntu 22.04
systemctl disable update-notifier-download.service plymouth-quit.service plymouth-quit-wait.service || true
systemctl disable cloud-final.service
systemctl disable libvirt-guests.service libvirtd.service systemd-machined.service || true
systemctl disable mono-xsp4.service || true
systemctl disable containerd.service docker.service
systemctl disable apport.service logrotate.service grub-common.service keyboard-setup.service systemd-update-utmp.service systemd-fsck-root.service systemd-tmpfiles-setup.service apparmor.service e2scrub_reap.service || true
systemctl disable ufw.service snapd.service snap.lxd.activate.service snapd.apparmor.service ec2-instance-connect.service snap.amazon-ssm-agent.amazon-ssm-agent.service cron.service || true

# cleanup
rm -f /home/ubuntu/minikube-linux-arm64
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

rm -rf /etc/skel/.rustup
rm -rf /etc/skel/.cargo
rm -rf /etc/skel/.dotnet
rm -rf /etc/skel/.nvm

rm -rf /root/.sbt
# reset root files to blank state
cp /etc/skel/.bashrc /root/
cp /etc/skel/.profile /root/

apt autoremove --purge snapd -y
apt-mark hold snapd
rm -rf /var/cache/snapd/ /root/snap
