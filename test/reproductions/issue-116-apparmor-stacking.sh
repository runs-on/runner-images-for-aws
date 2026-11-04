#!/usr/bin/env bash
# Issue 116: with apparmor.service disabled no runc profile is loaded, and on
# Ubuntu 26 kernels from 7.0.0-1016-aws an unconfined runc has its change to
# docker-default stacked as docker-default//&unconfined, whose rules then deny
# signals between a container's own processes.
#
# Fails when a container's processes carry a stacked label or cannot signal
# each other, under docker run, a BuildKit RUN step, and podman when present.
set -uo pipefail

failures=0
check() {
  local name="$1" want="$2" got="$3"
  if [[ "$got" == *"$want"* ]]; then
    echo "ok   $name: $got"
  else
    echo "FAIL $name: want '$want', got: $got"
    failures=$((failures + 1))
  fi
}

echo "kernel $(uname -r)"
echo "apparmor.service: $(systemctl is-enabled apparmor.service 2>&1)"
for k in apparmor_restrict_unprivileged_unconfined apparmor_restrict_unprivileged_userns; do
  echo "kernel.$k=$(cat /proc/sys/kernel/$k 2>&1)"
done
sudo cat /etc/sysctl.d/20-apparmor.conf 2>&1 | grep -v '^#'
sudo aa-status --profiled 2>&1 | sed 's/^/profiles loaded: /'
sudo dmesg -C 2>/dev/null || true

docker pull -q ubuntu:24.04 >/dev/null
out=$(docker run --rm ubuntu:24.04 sh -c 'cat /proc/self/attr/current; sleep 30 & kill $! && echo kill=ok' 2>&1)
check "docker run label" "docker-default (enforce)" "$(head -1 <<<"$out")"
check "docker run kill" "kill=ok" "$out"

out=$(printf 'FROM ubuntu:24.04\nRUN sh -c "sleep 30 & kill \\$!" && echo build-kill=ok\n' |
  docker build --no-cache --progress=plain -t issue116-build - 2>&1)
check "BuildKit RUN kill" "build-kill=ok" "$(grep -E '^#[0-9]+ [0-9.]+ build-kill=ok|^ERROR' <<<"$out" | tail -1)"

if command -v podman >/dev/null; then
  sudo podman pull -q ubuntu:24.04 >/dev/null 2>&1 || true
  out=$(sudo podman run --rm ubuntu:24.04 sh -c 'cat /proc/self/attr/current; sleep 30 & kill $! && echo kill=ok' 2>&1)
  check "podman run label" "(enforce)" "$(head -1 <<<"$out")"
  [[ "$out" != *'//&'* ]] || { echo "FAIL podman run label is stacked"; failures=$((failures + 1)); }
  check "podman run kill" "kill=ok" "$out"
fi

sudo dmesg 2>/dev/null | grep -E 'apparmor="(AUDIT|DENIED)"' | tail -5 || true
echo "failures=$failures"
exit $(( failures > 0 ))
