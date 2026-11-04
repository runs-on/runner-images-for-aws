#!/usr/bin/env bash
# Issue 116: on kernels from 7.0.0-1016-aws, a runc that runs unconfined has
# its change to docker-default stacked as docker-default//&unconfined, and the
# profile then denies signals between a container's own processes.
#
# Prints the image's state, reproduces the denial, then tries each candidate
# fix in turn and undoes it: loading only the runc (and crun) profiles,
# kernel.apparmor_restrict_unprivileged_unconfined=0, and apparmor.service.
set -uo pipefail

say() { printf '\n== %s\n' "$*"; }
ms() { date +%s%N; }

container_check() {
  # The label a container's processes carry, and whether one can signal another.
  docker run --rm ubuntu:24.04 sh -c 'echo "label=$(cat /proc/self/attr/current)"; sleep 30 & kill $!; echo "kill=$?"' 2>&1
}

build_check() {
  # BuildKit RUN steps run under docker-default too (issue 116, second report).
  printf 'FROM ubuntu:24.04\nRUN sh -c "sleep 30 & kill \\$!" && echo build-kill=ok\n' |
    docker build --no-cache --progress=plain -t issue116-build - 2>&1 | grep -E 'build-kill|Permission denied|ERROR' || echo "build: no output matched (exit ${PIPESTATUS[1]})"
}

podman_check() {
  command -v podman >/dev/null || { echo "podman: not installed"; return; }
  sudo podman run --rm --pull=never ubuntu:24.04 sh -c 'echo "podman-label=$(cat /proc/self/attr/current)"; sleep 30 & kill $!; echo "podman-kill=$?"' 2>&1 | tail -3
}

unshare_check() {
  # Unprivileged user namespaces, as the runner user.
  unshare -Ur true 2>&1 && echo "unshare -Ur: ok" || echo "unshare -Ur: failed ($?)"
  unshare -Urm true 2>&1 && echo "unshare -Urm: ok" || echo "unshare -Urm: failed ($?)"
}

all_checks() {
  say "checks: $1"
  container_check
  build_check
  podman_check
  unshare_check
  sudo dmesg | grep -E 'apparmor="(AUDIT|DENIED)"' | tail -4 || true
  sudo dmesg -C || true
}

say "image state"
uname -r
echo "apparmor.service: enabled=$(systemctl is-enabled apparmor.service 2>&1) active=$(systemctl is-active apparmor.service 2>&1)"
for k in apparmor_restrict_unprivileged_unconfined apparmor_restrict_unprivileged_userns; do
  echo "kernel.$k=$(cat /proc/sys/kernel/$k 2>&1)"
done
grep -rs . /usr/lib/sysctl.d/10-apparmor.conf /etc/sysctl.d/*apparmor* 2>/dev/null || true
echo "profiles loaded: $(sudo aa-status --profiled 2>/dev/null || sudo apparmor_status 2>&1 | head -3)"
dpkg-query -W -f='${Package} ${Version}\n' apparmor apparmor-profiles runc containerd.io docker-ce crun podman 2>/dev/null
echo "runc: $(command -v runc) -> $(readlink -f "$(command -v runc)")"
docker info --format 'docker runtime={{.DefaultRuntime}} runc={{index .Runtimes "runc"}}' 2>&1 | head -2
ls -l /etc/apparmor.d/runc /etc/apparmor.d/crun /etc/apparmor.d/unprivileged_userns /etc/apparmor.d/docker-default 2>&1
echo "--- /etc/apparmor.d/runc"; cat /etc/apparmor.d/runc 2>&1
echo "--- cache"; ls -la /var/cache/apparmor/ 2>&1 | head; du -sh /var/cache/apparmor 2>/dev/null
echo "--- profiles in /etc/apparmor.d: $(ls /etc/apparmor.d/ 2>/dev/null | wc -l)"

docker pull -q ubuntu:24.04
sudo podman pull -q ubuntu:24.04 2>/dev/null || true
sudo dmesg -C || true

all_checks "baseline"

say "fix B: load only the runc (and crun) profiles"
profiles=()
for p in /etc/apparmor.d/runc /etc/apparmor.d/crun; do [ -f "$p" ] && profiles+=("$p"); done
t0=$(ms); sudo apparmor_parser -r "${profiles[@]}"; echo "apparmor_parser -r ${profiles[*]}: exit=$? $(( ($(ms) - t0) / 1000000 )) ms"
sudo aa-status 2>/dev/null | grep -A3 'profiles are in unconfined mode' || sudo aa-status 2>/dev/null | head -8
all_checks "runc profile loaded"
sudo apparmor_parser -R "${profiles[@]}" && echo "profiles unloaded"

say "fix C: kernel.apparmor_restrict_unprivileged_unconfined=0"
sudo sysctl -w kernel.apparmor_restrict_unprivileged_unconfined=0
all_checks "sysctl unconfined=0"
sudo sysctl -w kernel.apparmor_restrict_unprivileged_unconfined=1

say "fix A: apparmor.service (all profiles)"
t0=$(ms); sudo systemctl start apparmor.service; echo "systemctl start apparmor.service: exit=$? $(( ($(ms) - t0) / 1000000 )) ms"
echo "profiles loaded: $(sudo aa-status --profiled 2>/dev/null)"; echo "enforced: $(sudo aa-status --enforced 2>/dev/null)"
sudo aa-status 2>/dev/null | grep -A12 'profiles are in enforce mode' | head -14
echo "--- cache after"; ls -la /var/cache/apparmor/ 2>&1 | head -4
t0=$(ms); sudo apparmor_parser -r /etc/apparmor.d/ 2>&1 | tail -2; echo "apparmor_parser -r /etc/apparmor.d (warm): $(( ($(ms) - t0) / 1000000 )) ms"
all_checks "apparmor.service started"
