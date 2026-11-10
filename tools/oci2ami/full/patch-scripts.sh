#!/bin/bash
# The few edits the runner-images and RunsOn scripts need inside `docker
# build`, where /etc/hosts and /etc/resolv.conf are bind mounts, the root is
# overlayfs, and no daemon runs. Each edit must match, or the build stops: a
# script that changed upstream must be looked at again.
set -euo pipefail
src=/opt/oci-build/src

edit() { # file, sed expression, text that must be present afterwards
  sed -i "$2" "$src/$1"
  grep -qF -- "$3" "$src/$1" || { echo "oci patch did not apply: $1: $2" >&2; exit 1; }
}

# No cloud-init boot happened in a container.
edit custom/pre.sh 's/^cloud-init status --wait$/true # oci: no cloud-init boot/' 'true # oci: no cloud-init boot'
# /etc/hosts is a bind mount during the build: edit the copy the converter installs.
edit build/configure-environment.sh "s#' /etc/hosts\$#' /etc/oci2ami/hosts#" "' /etc/oci2ami/hosts"
# The root is overlayfs here; the converter writes the ext4 root (and its rootflags).
edit build/configure-environment.sh 's/^if \[\[ "\$root_fs_type" != "ext4" \]\]; then$/if false; then # oci: the converter writes an ext4 root/' 'if false; then # oci'
# No Docker daemon runs in a build.
edit build/install-docker.sh 's/^docker info$/: docker info # oci: no daemon/' ': docker info # oci'
edit build/install-docker.sh 's/^\( *\)docker pull /\1: oci: no daemon: docker pull /' ': oci: no daemon: docker pull'
# journald does not run in a build.
edit build/cleanup.sh 's/^\( *\)journalctl --rotate$/\1journalctl --rotate || true/' 'journalctl --rotate || true'
edit build/cleanup.sh 's/^\( *\)journalctl --vacuum-time=1s$/\1journalctl --vacuum-time=1s || true/' 'journalctl --vacuum-time=1s || true'
# A build never generated SSH host keys.
edit custom/after-reboot.sh 's#^shred -u /etc/ssh/\*_key /etc/ssh/\*_key.pub$#& || true#' '*_key.pub || true'
# nft -c needs CAP_NET_ADMIN, which a build does not have.
edit custom/configure-syn-reroll.sh 's#^in_root nft -c -f /etc/runs-on/syn-reroll.nft$#& || echo "nft check skipped: no CAP_NET_ADMIN in a build"#' 'nft check skipped'
# /etc/resolv.conf is a bind mount during the build: leave the link for the converter.
edit custom/configure-full-rolaunch.sh 's#^rm -f /etc/resolv.conf$#mkdir -p /etc/oci2ami#' 'mkdir -p /etc/oci2ami'
edit custom/configure-full-rolaunch.sh 's#^ln -s ../run/systemd/resolve/stub-resolv.conf /etc/resolv.conf$#ln -sfn ../run/systemd/resolve/stub-resolv.conf /etc/oci2ami/resolv.conf#' '/etc/oci2ami/resolv.conf'
