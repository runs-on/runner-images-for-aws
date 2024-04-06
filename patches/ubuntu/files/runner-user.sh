#!/bin/bash
set -ex

echo "Setting up runner user..."
adduser --shell /bin/bash --disabled-password --gecos "" --uid 1001 runner
usermod -aG sudo runner
echo "%sudo   ALL=(ALL:ALL) NOPASSWD:ALL" >> /etc/sudoers
echo "Defaults env_keep += \"DEBIAN_FRONTEND\"" >> /etc/sudoers

# add kvm virt, only available on metal instances
# apt-get install -y qemu-kvm libvirt-daemon-system libvirt-clients bridge-utils virtinst
# modprobe kvm
# usermod -aG kvm runner

# install archive from cache
archive_name=$(ls /opt/runner-cache)
archive_path="/opt/runner-cache/$archive_name"
echo "Installing runner from $archive_path"
tar xzf "$archive_path" -C /home/runner
chown -R runner:runner /home/runner
rm -rf /opt/runner-cache
# test presence of run.sh
test -s /home/runner/run.sh

# disable ssh daemon by default
systemctl disable ssh.service

# speed-up boot
systemctl disable libvirt-guests.service libvirtd.service systemd-machined.service || true
systemctl disable mono-xsp4.service || true
systemctl disable containerd.service docker.service
systemctl disable chrony.service polkit.service rsyslog.service apport.service logrotate.service snapd.seeded.service grub-common.service keyboard-setup.service systemd-update-utmp.service systemd-fsck-root.service systemd-tmpfiles-setup.service plymouth-quit.service plymouth-quit-wait.service systemd-journal-flush.service apparmor.service systemd-fsck-root.service e2scrub_reap.service
systemctl disable ufw.service snapd.service snap.lxd.activate.service snapd.apparmor.service ec2-instance-connect.service snap.amazon-ssm-agent.amazon-ssm-agent.service cron.service

# cleanup
rm -f /home/ubuntu/minikube-linux-amd64
rm -rf /usr/share/doc

rm -rf /etc/skel/.rustup
rm -rf /etc/skel/.cargo
rm -rf /etc/skel/.dotnet
rm -rf /etc/skel/.nvm