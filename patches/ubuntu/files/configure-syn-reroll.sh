#!/usr/bin/env bash

set -euo pipefail

IMAGE_OS="${IMAGE_OS:-}"

if [[ "${IMAGE_OS}" != "ubuntu26" ]]; then
  echo "[configure-syn-reroll] skipped for ${IMAGE_OS}"
  exit 0
fi

# In us-east-1, an instance launched during a few minutes that recur about
# every hour loses the SYNs of some of its new outbound TCP connections for
# its first minute. A stalled connection stays dead for 5 to 36 s on its
# 5-tuple while other connections from the same instance complete at once.
#
# For the first two minutes after boot, connections to GitHub and AWS on port
# 443 leave through masquerade with a random source port, and their
# conntrack entry expires 1 s after the SYN (a SYN retransmission does not
# renew it). Each retransmission then creates a new entry and a new source
# port, so a stalled connection is retried on a new flow every second
# instead of waiting on the same one. tcp_syn_linear_timeouts keeps the
# retransmissions 1 s apart during that time.
#
# The table loads before networking, so rolaunch's own connections are
# covered. After two minutes the chain is flushed, never deleted: connections
# opened before keep their NAT binding, and deleting the last nat chain would
# unregister the hook that applies it.

echo "[configure-syn-reroll] installing the early-boot SYN re-roll for GitHub and AWS"

if ! command -v nft >/dev/null; then
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y nftables
fi
systemctl disable nftables.service 2>/dev/null || true

install -d -m 0755 /etc/runs-on
fetch() {
  curl -fsSL --retry 5 --retry-all-errors --max-time 60 "$1"
}
github_meta="$(mktemp)"
aws_ranges="$(mktemp)"
fetch https://api.github.com/meta > "${github_meta}"
fetch https://ip-ranges.amazonaws.com/ip-ranges.json > "${aws_ranges}"

# Addresses published at build time. A newer address is simply not re-rolled.
python3 - "${github_meta}" "${aws_ranges}" > /etc/runs-on/syn-reroll.nft <<'PY'
import ipaddress, json, sys
from datetime import datetime, timezone

github = json.load(open(sys.argv[1]))
aws = json.load(open(sys.argv[2]))
nets = []
for key in ("actions", "api", "git", "web", "packages"):
    for prefix in github[key]:
        net = ipaddress.ip_network(prefix)
        if net.version == 4:
            nets.append(net)
github_count = len(nets)
for prefix in aws["prefixes"]:
    if prefix["service"] == "AMAZON":
        nets.append(ipaddress.ip_network(prefix["ip_prefix"]))
nets = list(ipaddress.collapse_addresses(nets))
if len(nets) < 1000:
    sys.exit(f"only {len(nets)} prefixes: the published ranges look wrong")

print(f"# Generated {datetime.now(timezone.utc):%Y-%m-%dT%H:%M:%SZ} from api.github.com/meta")
print(f"# (actions, api, git, web, packages) and AWS ip-ranges.json (AMAZON, syncToken {aws['syncToken']}).")
print(f"# {len(nets)} IPv4 prefixes after collapsing. See configure-syn-reroll.sh.")
print("table ip ro_syn {")
print("  set github_aws {")
print("    type ipv4_addr; flags interval;")
print("    elements = {")
print(",\n".join(f"      {net}" for net in nets))
print("    }")
print("  }")
print("  ct timeout syn1s { protocol tcp; l3proto ip; policy = { syn_sent : 1 }; }")
print("  chain post {")
print("    type nat hook postrouting priority srcnat - 1; policy accept;")
print("    meta oiftype ether tcp dport 443 ip daddr @github_aws counter ct timeout set \"syn1s\" masquerade fully-random")
print("  }")
print("}")
PY
rm -f "${github_meta}" "${aws_ranges}"
nft -c -f /etc/runs-on/syn-reroll.nft
head -3 /etc/runs-on/syn-reroll.nft

cat > /etc/systemd/system/runs-on-syn-reroll.service <<'EOF'
[Unit]
Description=Retry stalled SYNs to GitHub and AWS on a new source port during early boot
DefaultDependencies=no
After=systemd-modules-load.service
Before=network-pre.target rolaunch.service
Wants=network-pre.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/nft -f /etc/runs-on/syn-reroll.nft
# Conntrack marks some packets of fast transfers out of window. Those skip
# NAT and draw a reset, so let conntrack accept them for NAT'd connections.
ExecStartPost=/usr/sbin/sysctl -q -w net.ipv4.tcp_syn_linear_timeouts=10 net.netfilter.nf_conntrack_tcp_be_liberal=1

[Install]
WantedBy=sysinit.target
EOF

cat > /etc/systemd/system/runs-on-syn-reroll-stop.service <<'EOF'
[Unit]
Description=Stop retrying stalled SYNs on a new source port
After=runs-on-syn-reroll.service

[Service]
Type=oneshot
ExecStart=/usr/sbin/nft flush chain ip ro_syn post
ExecStartPost=/usr/sbin/sysctl -q -w net.ipv4.tcp_syn_linear_timeouts=4
EOF

cat > /etc/systemd/system/runs-on-syn-reroll-stop.timer <<'EOF'
[Unit]
Description=Stop retrying stalled SYNs on a new source port two minutes after boot

[Timer]
OnBootSec=120
AccuracySec=1s

# runner-user.sh disables timers.target: start with the runner's target.
[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable runs-on-syn-reroll.service runs-on-syn-reroll-stop.timer
systemd-analyze verify runs-on-syn-reroll.service runs-on-syn-reroll-stop.service runs-on-syn-reroll-stop.timer
