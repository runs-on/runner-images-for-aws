#!/bin/bash
# Builds an Ubuntu 26 full image as an OCI image with the runner-images and
# RunsOn scripts of the packer template, then writes its AMI disk.
#
#   build.sh context IMAGE_ID DIR   Assembles a build context in DIR from this
#                                   checkout (after bin/sync --image-id
#                                   IMAGE_ID). Needs yq and Go.
#   build.sh image DIR DEVICE       On an Ubuntu 26.04 builder of the image's
#                                   architecture: docker build, then
#                                   oci2ami.sh onto DEVICE (an empty 30 GB EBS
#                                   volume). Needs docker.io, docker-buildx,
#                                   systemd-ukify, systemd-boot-efi, gdisk,
#                                   dosfstools and bc.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../../.." && pwd)

case ${1:-} in
context)
  id=$2; dir=$3
  case $id in
    ubuntu26-full-x64) arch=x64 goarch=amd64 ;;
    ubuntu26-full-arm64) arch=arm64 goarch=arm64 ;;
    *) echo "unsupported image: $id" >&2; exit 1 ;;
  esac
  release=$repo/releases/ubuntu26/$arch
  [ -d "$release/images/ubuntu/scripts/build" ] || { echo "run bin/sync --image-id $id first" >&2; exit 1; }
  mkdir -p "$dir/ubuntu" "$dir/oci"
  cp -a "$release/images/ubuntu/"{scripts,custom,toolsets,assets} "$dir/ubuntu/"
  cp -a "$release/helpers/software-report-base" "$dir/"
  cp -a "$here/shims" "$here/step.sh" "$here/patches" "$dir/oci/"
  cp -a "$here/../oci2ami.sh" "$dir/"
  (cd "$repo/tools/rolaunch" && CGO_ENABLED=0 GOOS=linux GOARCH=$goarch go build -trimpath -ldflags='-s -w' -o "$dir/rolaunch" .)
  "$here/gen-dockerfile.sh" "$id" > "$dir/Dockerfile"
  echo "$id" > "$dir/IMAGE_ID"
  ;;
image)
  dir=$2; dev=$3
  id=$(cat "$dir/IMAGE_ID")
  case $id in
    ubuntu26-full-x64)
      deb=amd64
      # /proc/cmdline of the published ubuntu26-full-x64 (direct UEFI boot).
      args="console=tty1 console=ttyS0 nvme_core.io_timeout=4294967295 rootflags=nobarrier,data=writeback,journal_async_commit,commit=30 panic=-1 i8042.nokbd i8042.noaux i8042.nopnp quiet systemd.tty.term.console=linux systemd.tty.rows.console=24 systemd.tty.columns.console=80" ;;
    ubuntu26-full-arm64)
      deb=arm64
      # /proc/cmdline of the published ubuntu26-full-arm64 (GRUB), without BOOT_IMAGE.
      args="console=tty1 console=ttyS0 nvme_core.io_timeout=4294967295 quiet systemd.tty.term.console=linux systemd.tty.rows.console=24 systemd.tty.columns.console=80 rootflags=nobarrier,data=writeback,journal_async_commit,commit=30 panic=-1" ;;
  esac
  [ "$(dpkg --print-architecture)" = $deb ] || { echo "build $id on an $deb builder" >&2; exit 1; }
  [ -s "$dir/root.tar.xz" ] || curl -fsSL --retry 5 -o "$dir/root.tar.xz" \
    "https://cloud-images.ubuntu.com/resolute/current/resolute-server-cloudimg-$deb-root.tar.xz"
  docker build --progress=plain --build-arg IMAGE_VERSION="${IMAGE_VERSION:-$(date -u +%Y%m%d%H%M%S)}" -t "runs-on-$id" "$dir"
  KERNEL_ARGS=$args "$dir/oci2ami.sh" "runs-on-$id" "$dev"
  ;;
*) sed -n '2,15p' "$0"; exit 1 ;;
esac
