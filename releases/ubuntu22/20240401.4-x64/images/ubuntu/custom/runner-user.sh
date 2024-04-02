#!/bin/bash
set -e

RUNS_ON_AGENT_VERSION=v2.0.10

# add kvm virt, only available on metal instances
apt-get install -y qemu-kvm libvirt-daemon-system libvirt-clients bridge-utils virtinst
modprobe kvm
systemctl disable libvirtd.service

echo "Setting up runner user..."
adduser --shell /bin/bash --disabled-password --gecos "" --uid 1001 runner
usermod -aG sudo runner
usermod -aG kvm runner
echo "%sudo   ALL=(ALL:ALL) NOPASSWD:ALL" >> /etc/sudoers
echo "Defaults env_keep += \"DEBIAN_FRONTEND\"" >> /etc/sudoers

# install archive from cache
archive_name=$(ls /opt/runner-cache)
archive_path="/opt/runner-cache/$archive_name"
echo "Installing runner from $archive_path"
tar xzf "$archive_path" -C /home/runner
chown -R runner:runner /home/runner
rm -rf /opt/runner-cache

# test presence of run.sh
test -s /home/runner/run.sh

mkdir -p /opt/runs-on
time curl -Ls https://runs-on.s3.eu-west-1.amazonaws.com/agent/$RUNS_ON_AGENT_VERSION/agent-linux-$(uname -i) -o /opt/runs-on/agent
chmod a+x /opt/runs-on/agent

cat > /etc/systemd/system/runs-on-agent.service <<EOF
[Unit]
Description=RunsOn Agent
After=network-online.target
Before=cloud-final.service
Wants=network-online.target

[Service]
Nice=-10
Environment="RUNS_ON_AGENT_LAUNCHED_WITH=systemd"
Type=oneshot
ExecStart=/opt/runs-on/agent
RemainAfterExit=no

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable runs-on-agent.service

# speed-up boot
systemctl disable containerd.service docker.service
systemctl disable chrony.service polkit.service rsyslog.service apport.service logrotate.service snapd.seeded.service grub-common.service keyboard-setup.service systemd-update-utmp.service systemd-fsck-root.service systemd-tmpfiles-setup.service plymouth-quit.service plymouth-quit-wait.service systemd-journal-flush.service apparmor.service systemd-fsck-root.service e2scrub_reap.service
systemctl disable ufw.service snapd.service snap.lxd.activate.service snapd.apparmor.service ec2-instance-connect.service snap.amazon-ssm-agent.amazon-ssm-agent.service cron.service

# cleanup
rm -f /home/ubuntu/minikube-linux-amd64
rm -rf /usr/share/doc

