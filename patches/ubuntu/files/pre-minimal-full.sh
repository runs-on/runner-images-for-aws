#!/bin/bash
set -exo pipefail

# if ! grep -q "^nameserver 169.254.169.253" /etc/resolv.conf 2>/dev/null; then
#   cat > /etc/resolv.conf <<'EOF'
# nameserver 169.254.169.253
# options timeout:1 attempts:5
# EOF
# fi

# wait_for_dns() {
#   local host
#   for host in archive.ubuntu.com security.ubuntu.com; do
#     for attempt in $(seq 1 30); do
#       if getent hosts "$host" >/dev/null 2>&1; then
#         break
#       fi
#       sleep 2
#       if [ "$attempt" -eq 30 ]; then
#         echo "DNS for ${host} did not become ready in time" >&2
#         return 1
#       fi
#     done
#   done
# }

refresh_apt_indexes() {
  local attempt
  for attempt in $(seq 1 10); do
    if apt-get update -qq && apt-cache show wget >/dev/null 2>&1; then
      return 0
    fi
    sleep 5
  done

  echo "apt indexes are not usable after retries" >&2
  return 1
}

# wait_for_dns
refresh_apt_indexes

# cat > /etc/apt/apt.conf.d/90runs-on-noninteractive <<'EOF'
# APT::Get::Assume-Yes "true";
# Dpkg::Options {
#   "--force-confdef";
#   "--force-confold";
# };
# EOF

apt-get install -y --no-install-recommends --fix-missing \
  ca-certificates \
  curl \
  gnupg \
  lsb-release \
  man-db \
  ncdu \
  software-properties-common \
  sudo \
  wget

cat > /root/.gemrc <<EOF
gem: --no-document
EOF

mkdir -p /etc/default
if [ ! -f /etc/default/motd-news ]; then
  echo "ENABLED=0" > /etc/default/motd-news
fi

# Keep snap available so the existing helper/install scripts can run unchanged.
systemctl enable snapd.socket || true
systemctl start snapd.socket || true
snap set system experimental.hotplug=false || true

wget -q https://amazoncloudwatch-agent.s3.amazonaws.com/ubuntu/amd64/latest/amazon-cloudwatch-agent.deb
dpkg -i -E ./amazon-cloudwatch-agent.deb
systemctl disable amazon-cloudwatch-agent || true
rm -f ./amazon-cloudwatch-agent.deb

if [ -f /opt/aws/amazon-cloudwatch-agent/etc/common-config.toml ]; then
  cat >> /opt/aws/amazon-cloudwatch-agent/etc/common-config.toml <<EOF
[agent]
auto_update = false
EOF
fi

# https://docs.aws.amazon.com/systems-manager/latest/userguide/agent-install-ubuntu-64-deb.html
wget -q https://s3.amazonaws.com/ec2-downloads-windows/SSMAgent/latest/debian_amd64/amazon-ssm-agent.deb
dpkg -i amazon-ssm-agent.deb
systemctl enable amazon-ssm-agent || true
rm -f amazon-ssm-agent.deb

wget -q https://runs-on.s3.eu-west-1.amazonaws.com/tools/efs-utils/amazon-efs-utils-2.3.0-1_amd64.deb
apt-get install -y ./amazon-efs-utils-2.3.0-1_amd64.deb
rm -f amazon-efs-utils-2.3.0-1_amd64.deb
