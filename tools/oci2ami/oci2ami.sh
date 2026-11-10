#!/bin/bash
# oci2ami.sh IMAGE DEVICE: writes a bootable EC2 disk from an OCI image that
# carries a kernel and systemd (the EC2 layer): GPT, an EFI partition with a
# UKI (kernel + command line, no initrd), and an ext4 root with the image's
# files. The caller snapshots DEVICE and registers the AMI (UEFI, ENA).
# Runs on a builder of the image's architecture (x64 or arm64).
#
# KERNEL_ARGS replaces the kernel arguments after root= and ro (the default
# is the minimal image's). An image can leave /etc/hosts, /etc/hostname and
# /etc/resolv.conf in /etc/oci2ami, since Docker owns those files in every
# container; otherwise they get the minimal image's. ROOT_HOOK, when set, runs
# with the exported root as its last argument before the disk is written.
set -euo pipefail
IMAGE=$1; DEV=$2
PARTUUID=${PARTUUID:-6b1e7a52-0c1d-4f0e-9a51-52756e734f6e}
KERNEL_ARGS=${KERNEL_ARGS:-console=ttyS0 nvme_core.io_timeout=4294967295 panic=-1 raid=noautodetect i8042.nokbd i8042.noaux i8042.nomux i8042.nopnp quiet net.ifnames=0 systemd.tty.term.console=linux systemd.tty.rows.console=24 systemd.tty.columns.console=80 rootflags=nobarrier,data=writeback,journal_async_commit,commit=30}
CMDLINE="root=PARTUUID=$PARTUUID ro $KERNEL_ARGS"
case $(uname -m) in
  x86_64) EFI_ARCH=x64 ;;
  aarch64) EFI_ARCH=aa64 ;;
  *) echo "unsupported architecture $(uname -m)" >&2; exit 1 ;;
esac
W=$(mktemp -d /var/tmp/oci2ami.XXXX); trap 'umount -q $W/esp 2>/dev/null || true; rm -rf $W' EXIT
t0=$(date +%s.%N)
ctr=$(docker create "$IMAGE" /bin/true)
mkdir $W/root $W/esp
docker export "$ctr" | tar -x -C $W/root --numeric-owner --xattrs-include='*'
docker rm "$ctr" >/dev/null
# Docker owns these at run time; the export leaves them empty.
rm -f $W/root/.dockerenv
# /run is a tmpfs at boot: drop what build steps wrote there.
find $W/root/run -mindepth 1 -delete
printf 'nameserver 169.254.169.253\n' > $W/root/etc/resolv.conf
echo runs-on > $W/root/etc/hostname
printf '127.0.0.1 localhost\n127.0.1.1 runs-on\n::1 localhost ip6-localhost ip6-loopback\n' > $W/root/etc/hosts
if [ -d $W/root/etc/oci2ami ]; then
  for f in hosts hostname resolv.conf; do
    if [ -e $W/root/etc/oci2ami/$f ] || [ -L $W/root/etc/oci2ami/$f ]; then
      rm -f $W/root/etc/$f && mv $W/root/etc/oci2ami/$f $W/root/etc/$f
    fi
  done
  rm -rf $W/root/etc/oci2ami
fi
[ -z "${ROOT_HOOK:-}" ] || $ROOT_HOOK "$W/root"
# The image is built: no first-boot ldconfig or update-done pass.
touch $W/root/etc/.updated $W/root/var/.updated
# Keep an image fstab that mounts / (Canonical's cloud root: LABEL=cloudimg-rootfs
# and LABEL=UEFI, the labels given below).
grep -Eq '^[^#[:space:]]+[[:space:]]+/[[:space:]]' $W/root/etc/fstab 2>/dev/null ||
  echo "PARTUUID=$PARTUUID / ext4 defaults,discard 0 0" > $W/root/etc/fstab
t1=$(date +%s.%N)
# The newest kernel; an AWS one when the image has several.
K=$(ls $W/root/boot/vmlinuz-*-aws 2>/dev/null | sort -V | tail -1)
[ -n "$K" ] || K=$(ls $W/root/boot/vmlinuz-* | sort -V | tail -1)
KIMG=$K
# arm64 kernels are gzip files; ukify wants the EFI image inside.
if [ "$(od -An -tx1 -N2 "$K" | tr -d '[:space:]')" = 1f8b ]; then zcat "$K" > $W/vmlinux; KIMG=$W/vmlinux; fi
EFI=BOOT$(echo $EFI_ARCH | tr a-z A-Z).EFI
ukify build --linux "$KIMG" --uname "${K##*/vmlinuz-}" --cmdline "$CMDLINE" \
  --stub /usr/lib/systemd/boot/efi/linux$EFI_ARCH.efi.stub --output $W/$EFI >/dev/null
wipefs -qaf "$DEV"
sgdisk -Z "$DEV" >/dev/null || true
sgdisk -n 1:2048:+256M -t 1:EF00 -c 1:ESP -n 2:0:0 -t 2:8300 -c 2:root -u 2:$PARTUUID "$DEV" >/dev/null
partprobe "$DEV"; udevadm settle
case $DEV in *[0-9]) P1=${DEV}p1 P2=${DEV}p2;; *) P1=${DEV}1 P2=${DEV}2;; esac
mkfs.vfat -F 32 -n UEFI "$P1" >/dev/null
mount "$P1" $W/esp
install -D $W/$EFI $W/esp/EFI/BOOT/$EFI
umount $W/esp
mkfs.ext4 -q -F -i 65536 -m 0 -E lazy_itable_init=0,lazy_journal_init=0 -L cloudimg-rootfs -d $W/root "$P2"
sync
t2=$(date +%s.%N)
echo "export_s=$(echo "$t1-$t0"|bc) disk_s=$(echo "$t2-$t1"|bc) root_used=$(du -sh $W/root | cut -f1) uki=$(du -h $W/$EFI|cut -f1) kernel=${K##*/}"
