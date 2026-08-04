#!/usr/bin/env bash

set -euo pipefail

IMAGE_OS="${IMAGE_OS:-}"
ROLAUNCH_SOURCE="${ROLAUNCH_SOURCE:-}"

if [[ "${IMAGE_OS}" != "ubuntu26" ]]; then
  echo "[configure-full-rolaunch] keeping cloud-init for ${IMAGE_OS}"
  exit 0
fi

if [[ -z "${ROLAUNCH_SOURCE}" || ! -x "${ROLAUNCH_SOURCE}" ]]; then
  echo "Missing rolaunch binary at ${ROLAUNCH_SOURCE:-<unset>}" >&2
  exit 1
fi

echo "[configure-full-rolaunch] installing rolaunch and the measured fast-boot contract"

. /etc/os-release
if [[ "${VERSION_CODENAME:-}" != "resolute" ]]; then
  echo "Expected Ubuntu Resolute for ${IMAGE_OS}, found ${VERSION_CODENAME:-unknown}" >&2
  exit 1
fi

debian_arch="$(dpkg --print-architecture)"
case "${debian_arch}" in
  amd64)
    ubuntu_mirror="https://archive.ubuntu.com/ubuntu/"
    ubuntu_security_mirror="https://security.ubuntu.com/ubuntu/"
    ;;
  arm64)
    ubuntu_mirror="https://ports.ubuntu.com/ubuntu-ports/"
    ubuntu_security_mirror="https://ports.ubuntu.com/ubuntu-ports/"
    ;;
  *)
    echo "Unsupported Debian architecture for full rolaunch: ${debian_arch}" >&2
    exit 1
    ;;
esac

apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y linux-aws

install -D -m 0755 "${ROLAUNCH_SOURCE}" /usr/bin/rolaunch

cat > /etc/systemd/system/rolaunch.service <<'EOF'
[Unit]
Description=ROLaunch
DefaultDependencies=no
Wants=systemd-networkd.service systemd-resolved.service
After=systemd-networkd.service systemd-resolved.service
Conflicts=shutdown.target
Before=multi-user.target shutdown.target

[Service]
Type=oneshot
TimeoutStartSec=infinity
ExecStart=/usr/bin/rolaunch --mode=full
RemainAfterExit=yes
StandardOutput=journal+console
StandardError=journal+console

[Install]
WantedBy=multi-user.target
EOF

# Cloud-init previously selected these mirrors during first boot. Seal the
# architecture-appropriate Resolute sources into the image instead.
cat > /etc/apt/sources.list.d/ubuntu.sources <<EOF
Types: deb
URIs: ${ubuntu_mirror}
Suites: resolute resolute-updates resolute-backports
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg

Types: deb
URIs: ${ubuntu_security_mirror}
Suites: resolute-security
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
EOF
rm -f /etc/apt/sources.list

# RunsOn launches Ubuntu 26 on Nitro instances with one primary ENA. Let
# networkd obtain IPv4, IPv6, DNS, domains, NTP, routes, and MTU directly from
# the VPC instead of starting cloud-init and netplan on every runner.
install -d -m 0755 /etc/systemd/network
cat > /etc/systemd/network/10-runs-on-ec2.network <<'EOF'
[Match]
Driver=ena

[Network]
DHCP=yes
IPv6AcceptRA=yes
IPv6DuplicateAddressDetection=0
DNSDefaultRoute=yes
LLMNR=no

[DHCPv4]
UseDNS=yes
UseDomains=yes
UseHostname=no
UseNTP=yes
UseMTU=yes
RouteMetric=100

[DHCPv6]
UseDNS=yes
UseDomains=yes
UseHostname=no
UseNTP=yes
WithoutRA=solicit
RouteMetric=100

[IPv6AcceptRA]
UseDNS=yes
UseDomains=yes
RouteMetric=100
EOF

# The builder's network identity must not enter the AMI. Netplan stays
# installed for the full-image tool contract, but it does no work during boot.
rm -f /etc/netplan/*.yaml
rm -f /etc/cloud/cloud.cfg.d/99-runs-on-rolaunch-network.cfg

# Preserve DNS servers and search domains from the VPC DHCP option set.
rm -f /etc/resolv.conf
ln -s ../run/systemd/resolve/stub-resolv.conf /etc/resolv.conf

cloud-init clean --logs || true
rm -rf /var/lib/cloud/*
install -D -m 0644 /dev/null /etc/cloud/cloud-init.disabled
systemctl disable \
  cloud-init-main.service \
  cloud-init-local.service \
  cloud-init-network.service \
  cloud-config.service \
  cloud-final.service \
  cloud-init-hotplugd.service \
  cloud-init-hotplugd.socket \
  netplan-configure.service
systemctl mask \
  cloud-init-main.service \
  cloud-init-local.service \
  cloud-init-network.service \
  cloud-config.service \
  cloud-final.service \
  cloud-init-hotplugd.service \
  cloud-init-hotplugd.socket \
  netplan-configure.service
systemctl unmask \
  systemd-networkd.service \
  systemd-networkd.socket \
  systemd-resolved.service
systemctl enable systemd-networkd.service systemd-resolved.service
systemctl mask \
  systemd-networkd-wait-online.service \
  systemd-networkd-wait-online@.service
for unit in \
  cloud-init-main.service \
  cloud-init-local.service \
  cloud-init-network.service \
  cloud-config.service \
  cloud-final.service \
  cloud-init-hotplugd.service \
  cloud-init-hotplugd.socket \
  netplan-configure.service; do
  [[ "$(systemctl is-enabled "${unit}")" == "masked" ]]
done

# Keep the full image's service surface. Remove only measured boot-path work
# that rolaunch replaces or that does not contribute to a one-shot runner.
systemctl unmask \
  proc-sys-fs-binfmt_misc.automount \
  ssh.service \
  ssh.socket \
  systemd-networkd.service \
  systemd-networkd.socket
systemctl disable systemd-binfmt.service ssh.service ssh.socket ldconfig.service || true
# Keep Podman's DHCP proxy and the disk manager available on demand without
# starting either daemon on every headless runner boot.
systemctl disable netavark-dhcp-proxy.service udisks2.service
systemctl enable netavark-dhcp-proxy.socket
systemctl mask systemd-journal-flush.service
rm -f \
  /etc/systemd/system/sysinit.target.wants/systemd-binfmt.service \
  /etc/systemd/system/ldconfig-after-rolaunch.service \
  /etc/systemd/system/sysinit.target.wants/ldconfig.service \
  /lib/systemd/system/sysinit.target.wants/systemd-binfmt.service \
  /lib/systemd/system/sysinit.target.wants/ldconfig.service \
  /usr/lib/systemd/system/sysinit.target.wants/systemd-binfmt.service \
  /usr/lib/systemd/system/sysinit.target.wants/ldconfig.service

for unit in \
  amazon-ssm-agent.service \
  chrony.service \
  irqbalance.service \
  systemd-networkd.service \
  grub-common.service \
  grub-initrd-fallback.service; do
  if systemctl list-unit-files "${unit}" --no-legend | grep -q "^${unit}"; then
    systemctl enable "${unit}"
  fi
done

sed -i 's/^Storage=Volatile$/Storage=volatile/' /etc/systemd/journald.conf
grep -qxF 'Storage=volatile' /etc/systemd/journald.conf || echo 'Storage=volatile' >> /etc/systemd/journald.conf

update-grub
for variable in \
  initrdfail \
  initrdless_boot_fallback_triggered \
  recordfail \
  prev_entry; do
  grub-editenv /boot/grub/grubenv unset "${variable}" || true
done

# No builder identity, key, or completion marker may survive into the AMI.
truncate -s 0 /etc/machine-id
rm -f /var/lib/dbus/machine-id
rm -f /etc/ssh/ssh_host_*
rm -f /home/ubuntu/.ssh/authorized_keys /root/.ssh/authorized_keys
rm -f \
  /var/lib/rolaunch/instance-identity.json \
  /var/lib/rolaunch/runs-on-user-data.done \
  /var/lib/rolaunch/timings.json \
  /var/lib/rolaunch/user-data.sh

systemctl daemon-reload
systemctl enable rolaunch.service
systemd-analyze verify rolaunch.service

apt-get clean
rm -rf /var/lib/apt/lists/*
sync
sync
