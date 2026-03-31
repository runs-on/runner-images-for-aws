#!/bin/bash

set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

ROOTFS_COMPACTION_HELPER="${ROOTFS_COMPACTION_HELPER:-/tmp/rootfs-compaction.sh}"
source "${ROOTFS_COMPACTION_HELPER}"

TARGET_VOLUME_SIZE_GB="${TARGET_VOLUME_SIZE_GB:-2}"
UBUNTU_RELEASE="${UBUNTU_RELEASE:-noble}"
UBUNTU_MIRROR="${UBUNTU_MIRROR:-http://archive.ubuntu.com/ubuntu}"
UBUNTU_SECURITY_MIRROR="${UBUNTU_SECURITY_MIRROR:-http://security.ubuntu.com/ubuntu}"
BOOTSTRAP_APT_TIMEOUT_SECONDS="${BOOTSTRAP_APT_TIMEOUT_SECONDS:-900}"
DEBOOTSTRAP_TIMEOUT_SECONDS="${DEBOOTSTRAP_TIMEOUT_SECONDS:-1200}"
CHROOT_APT_TIMEOUT_SECONDS="${CHROOT_APT_TIMEOUT_SECONDS:-900}"
MOUNT_DIR=/mnt/target-root
SPARSE_IMAGE=/var/tmp/ubuntu24-minimal-root.img
ROLAUNCH_SOURCE="${ROLAUNCH_SOURCE:-}"
LOOP_DISK=""

step() {
  echo "[bootstrap] $*"
}

run_logged() {
  local description="$1"
  shift

  step "$description"
  "$@"
}

run_logged_timeout() {
  local description="$1"
  local timeout_seconds="$2"
  shift 2

  step "$description (timeout=${timeout_seconds}s)"
  timeout --foreground --signal=TERM --kill-after=30s "${timeout_seconds}" \
    "$@"
}

cleanup_root() {
  local root="$1"

  set +e
  for mountpoint in \
    "$root/dev/pts" \
    "$root/dev" \
    "$root/proc" \
    "$root/sys" \
    "$root/run" \
    "$root"
  do
    mountpoint -q "$mountpoint" && umount "$mountpoint"
  done
}

cleanup() {
  cleanup_root "$MOUNT_DIR"

  if [[ -n "$LOOP_DISK" ]]; then
    losetup -d "$LOOP_DISK" || true
  fi

  rm -f "$SPARSE_IMAGE"
}

on_error() {
  local exit_code=$?

  echo "[bootstrap] build failed" >&2
  exit "$exit_code"
}

trap on_error ERR
trap cleanup EXIT

root_source="$(findmnt -n -o SOURCE /)"
root_parent_disk="/dev/$(lsblk -nro PKNAME "$root_source" | head -n1)"
target_bytes=$((TARGET_VOLUME_SIZE_GB * 1024 * 1024 * 1024))

find_target_disk() {
  while read -r name type size; do
    disk="/dev/$name"
    if [[ "$type" == "disk" && "$size" == "$target_bytes" && "$disk" != "$root_parent_disk" ]]; then
      echo "$disk"
      return 0
    fi
  done < <(lsblk -b -dn -o NAME,TYPE,SIZE)

  return 1
}

partition_path() {
  local disk="$1"

  if [[ "$disk" =~ [0-9]$ ]]; then
    echo "${disk}p1"
  else
    echo "${disk}1"
  fi
}

mount_chroot_root() {
  local root="$1"

  mkdir -p \
    "$root/dev" \
    "$root/dev/pts" \
    "$root/proc" \
    "$root/sys" \
    "$root/run"

  mount --bind /dev "$root/dev"
  mount --bind /dev/pts "$root/dev/pts"
  mount -t proc proc "$root/proc"
  mount -t sysfs sysfs "$root/sys"
  mount --bind /run "$root/run"
  cp /etc/resolv.conf "$root/etc/resolv.conf"
}

chroot_exec() {
  local root="$1"
  shift

  chroot "$root" /usr/bin/env DEBIAN_FRONTEND=noninteractive "$@"
}

target_disk="$(find_target_disk)"
if [[ -z "$target_disk" ]]; then
  echo "Failed to find target disk of size ${TARGET_VOLUME_SIZE_GB} GiB" >&2
  lsblk >&2
  exit 1
fi

step "target disk: $target_disk (${TARGET_VOLUME_SIZE_GB} GiB)"

run_logged_timeout "installing bootstrap dependencies" "$BOOTSTRAP_APT_TIMEOUT_SECONDS" apt-get update
run_logged_timeout "installing bootstrap packages" "$BOOTSTRAP_APT_TIMEOUT_SECONDS" apt-get install -y debootstrap parted rsync
if ! command -v ddpt >/dev/null 2>&1; then
  run_logged_timeout "installing ddpt" "$BOOTSTRAP_APT_TIMEOUT_SECONDS" apt-get install -y ddpt || \
    run_logged_timeout "installing sg3-utils fallback" "$BOOTSTRAP_APT_TIMEOUT_SECONDS" apt-get install -y sg3-utils
fi

if ! command -v ddpt >/dev/null 2>&1; then
  echo "ddpt is required for sparse image materialization" >&2
  exit 1
fi

rm -f "$SPARSE_IMAGE"
truncate -s "${TARGET_VOLUME_SIZE_GB}G" "$SPARSE_IMAGE"

LOOP_DISK="$(losetup --find --show -P "$SPARSE_IMAGE")"
loop_partition="$(partition_path "$LOOP_DISK")"

run_logged "partitioning sparse loop disk $LOOP_DISK" wipefs -af "$LOOP_DISK"
run_logged "creating partition table on $LOOP_DISK" parted -s "$LOOP_DISK" mklabel msdos
run_logged "creating root partition on $LOOP_DISK" parted -s -a optimal "$LOOP_DISK" mkpart primary ext4 1MiB 100%
run_logged "marking partition bootable on $LOOP_DISK" parted -s "$LOOP_DISK" set 1 boot on
partprobe "$LOOP_DISK" || true
udevadm settle
ROOT_PARTUUID="$(blkid -s PARTUUID -o value "$loop_partition")"
if [[ -z "$ROOT_PARTUUID" ]]; then
  echo "Failed to determine PARTUUID for $loop_partition" >&2
  exit 1
fi

run_logged "formatting $loop_partition as ext4" mkfs.ext4 -F -i 65536 -m 0 -E lazy_itable_init=0,lazy_journal_init=0 -L cloudimg-rootfs "$loop_partition"
mkdir -p "$MOUNT_DIR"
run_logged "mounting sparse root filesystem" mount -o discard "$loop_partition" "$MOUNT_DIR"

run_logged_timeout "debootstrap $UBUNTU_RELEASE rootfs" "$DEBOOTSTRAP_TIMEOUT_SECONDS" \
  debootstrap --arch=amd64 --variant=minbase "$UBUNTU_RELEASE" "$MOUNT_DIR" "$UBUNTU_MIRROR"

cat > "$MOUNT_DIR/etc/apt/sources.list" <<EOF
deb $UBUNTU_MIRROR $UBUNTU_RELEASE main restricted universe multiverse
deb $UBUNTU_MIRROR ${UBUNTU_RELEASE}-updates main restricted universe multiverse
deb $UBUNTU_SECURITY_MIRROR ${UBUNTU_RELEASE}-security main restricted universe multiverse
EOF

mkdir -p \
  "$MOUNT_DIR/etc/dpkg/dpkg.cfg.d" \
  "$MOUNT_DIR/etc/netplan" \
  "$MOUNT_DIR/etc/systemd/system/systemd-networkd-wait-online.service.d"

cat > "$MOUNT_DIR/etc/dpkg/dpkg.cfg.d/01lean" <<'EOF'
path-exclude=/usr/share/doc/*
path-include=/usr/share/doc/*/copyright
path-exclude=/usr/share/man/*
path-exclude=/usr/share/groff/*
path-exclude=/usr/share/info/*
path-exclude=/usr/share/lintian/*
path-exclude=/usr/share/linda/*
path-exclude=/usr/share/locale/*
path-include=/usr/share/locale/en*
EOF

step "mounting chroot bind mounts"
mount_chroot_root "$MOUNT_DIR"

run_logged_timeout "updating apt inside target rootfs" "$CHROOT_APT_TIMEOUT_SECONDS" \
  chroot "$MOUNT_DIR" /usr/bin/env DEBIAN_FRONTEND=noninteractive apt-get update
# cloud-initramfs-growroot and cloud-guest-utils can be re-added later if root-volume resize support is needed again.
run_logged_timeout "installing minimal runtime packages" "$CHROOT_APT_TIMEOUT_SECONDS" \
  chroot "$MOUNT_DIR" /usr/bin/env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
  linux-image-aws \
  grub-pc-bin \
  grub2-common \
  cloud-guest-utils \
  openssh-server \
  ca-certificates \
  ncdu \
  netplan.io \
  sudo \
  systemd-sysv

run_logged "installing RunsOn bootstrap binaries into target rootfs" \
  bash /tmp/install-runs-on-bootstrap.sh "$MOUNT_DIR"

run_logged "creating ubuntu user" chroot_exec "$MOUNT_DIR" /bin/bash -lc '
  set -euo pipefail
  if ! id -u ubuntu >/dev/null 2>&1; then
    useradd --create-home --shell /bin/bash --groups sudo ubuntu
  fi
  passwd -l ubuntu >/dev/null 2>&1 || true
  install -d -m 0755 /etc/sudoers.d
  printf "%s\n" \
    "ubuntu ALL=(ALL:ALL) NOPASSWD:ALL" \
    "Defaults:ubuntu env_keep += \"DEBIAN_FRONTEND\"" \
    > /etc/sudoers.d/90-ubuntu-nopasswd
  chmod 0440 /etc/sudoers.d/90-ubuntu-nopasswd
'

if [[ -z "$ROLAUNCH_SOURCE" || ! -f "$ROLAUNCH_SOURCE" ]]; then
  echo "Missing rolaunch binary at $ROLAUNCH_SOURCE" >&2
  exit 1
fi

install -D -m 0755 "$ROLAUNCH_SOURCE" "$MOUNT_DIR/usr/bin/rolaunch"

cat > "$MOUNT_DIR/etc/fstab" <<EOF
PARTUUID=$ROOT_PARTUUID / ext4 defaults 0 0
EOF

cat > "$MOUNT_DIR/etc/hostname" <<EOF
ubuntu24-minimal
EOF

cat > "$MOUNT_DIR/etc/hosts" <<EOF
127.0.0.1 localhost
127.0.1.1 ubuntu24-minimal

::1 localhost ip6-localhost ip6-loopback
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters
EOF

cat > "$MOUNT_DIR/etc/netplan/10-ec2.yaml" <<'EOF'
network:
  version: 2
  renderer: networkd
  ethernets:
    en-nic:
      match:
        name: "en*"
      dhcp4: true
      dhcp6: false
    eth-nic:
      match:
        name: "eth*"
      dhcp4: true
      dhcp6: false
EOF

mkdir -p "$MOUNT_DIR/etc/ssh/sshd_config.d"
cat > "$MOUNT_DIR/etc/ssh/sshd_config.d/10-hostkeys.conf" <<'EOF'
HostKey /etc/ssh/ssh_host_ed25519_key
PermitRootLogin yes
PasswordAuthentication no
KbdInteractiveAuthentication no
EOF

cat > "$MOUNT_DIR/etc/systemd/system/rolaunch.service" <<'EOF'
[Unit]
Description=ROLaunch

[Service]
Type=oneshot
ExecStart=/usr/bin/rolaunch
RemainAfterExit=yes
StandardOutput=journal+console
StandardError=journal+console

[Install]
WantedBy=multi-user.target
EOF

rm -f "$MOUNT_DIR/etc/systemd/system/ldconfig-after-rolaunch.service"

cat > "$MOUNT_DIR/etc/default/grub" <<'EOF'
GRUB_DEFAULT=0
GRUB_TIMEOUT=0
GRUB_DISTRIBUTOR=`( . /etc/os-release; echo ${NAME:-Ubuntu} ) 2>/dev/null || echo Ubuntu`
GRUB_CMDLINE_LINUX_DEFAULT="console=ttyS0 nvme_core.io_timeout=4294967295 panic=-1 raid=noautodetect i8042.nokbd i8042.noaux i8042.nomux i8042.nopnp"
GRUB_CMDLINE_LINUX=""
GRUB_TERMINAL="console serial"
GRUB_SERIAL_COMMAND="serial --speed=115200 --unit=0 --word=8 --parity=no --stop=1"
EOF

cat > "$MOUNT_DIR/etc/systemd/system/systemd-networkd-wait-online.service.d/override.conf" <<'EOF'
[Service]
ExecStart=
ExecStart=/usr/lib/systemd/systemd-networkd-wait-online --any --ipv4 --timeout=5
EOF

cat > "$MOUNT_DIR/etc/default/locale" <<'EOF'
LANG=C.UTF-8
LC_ALL=C.UTF-8
EOF

cat > "$MOUNT_DIR/etc/apt/apt.conf.d/80-retries" <<'EOF'
APT::Acquire::Retries "10";
EOF

cat > "$MOUNT_DIR/etc/apt/apt.conf.d/90assumeyes" <<'EOF'
APT::Get::Assume-Yes "true";
EOF

cat > "$MOUNT_DIR/etc/apt/apt.conf.d/99-phased-updates" <<'EOF'
APT::Get::Always-Include-Phased-Updates "true";
EOF

cat > "$MOUNT_DIR/etc/apt/apt.conf.d/99bad_proxy" <<'EOF'
Acquire::http::Pipeline-Depth 0;
Acquire::http::No-Cache true;
Acquire::https::Pipeline-Depth 0;
Acquire::https::No-Cache true;
Acquire::BrokenProxy true;
EOF

cat > "$MOUNT_DIR/etc/modprobe.d/runs-on-minimal-blacklist.conf" <<'EOF'
# Legacy parallel-port stack is not useful on EC2 runner images.
blacklist ppdev
blacklist parport_pc
blacklist parport
EOF

run_logged "disabling apt timers" chroot_exec "$MOUNT_DIR" systemctl disable apt-daily.timer apt-daily.service || true
run_logged "disabling apt upgrade timers" chroot_exec "$MOUNT_DIR" systemctl disable apt-daily-upgrade.timer apt-daily-upgrade.service || true
run_logged "disabling ldconfig service in minimal image" chroot_exec "$MOUNT_DIR" systemctl disable ldconfig.service || true
run_logged "removing ldconfig sysinit wants symlinks" bash -lc '
  rm -f \
    "$1/etc/systemd/system/sysinit.target.wants/ldconfig.service" \
    "$1/lib/systemd/system/sysinit.target.wants/ldconfig.service" \
    "$1/usr/lib/systemd/system/sysinit.target.wants/ldconfig.service"
' _ "$MOUNT_DIR"
run_logged "disabling pollinate service" chroot_exec "$MOUNT_DIR" systemctl disable pollinate.service || true
run_logged "masking pollinate service" chroot_exec "$MOUNT_DIR" systemctl mask pollinate.service || true
run_logged "disabling haveged service" chroot_exec "$MOUNT_DIR" systemctl disable haveged.service || true
run_logged "masking haveged service" chroot_exec "$MOUNT_DIR" systemctl mask haveged.service || true
run_logged "masking systemd-hostnamed service" chroot_exec "$MOUNT_DIR" systemctl mask systemd-hostnamed.service || true
run_logged "disabling ssh socket activation" chroot_exec "$MOUNT_DIR" systemctl disable ssh.socket || true
run_logged "masking ssh socket activation" chroot_exec "$MOUNT_DIR" systemctl mask ssh.socket || true
run_logged "masking systemd-repart service" chroot_exec "$MOUNT_DIR" systemctl mask systemd-repart.service || true
run_logged "keeping only serial getty" chroot_exec "$MOUNT_DIR" systemctl mask getty-static.service getty@tty1.service getty@tty2.service getty@tty3.service getty@tty4.service getty@tty5.service getty@tty6.service || true
run_logged "masking nonessential boot services" chroot_exec "$MOUNT_DIR" systemctl mask systemd-binfmt.service proc-sys-fs-binfmt_misc.automount || true
run_logged "disabling noisy timers and sockets" chroot_exec "$MOUNT_DIR" systemctl disable dpkg-db-backup.timer e2scrub_all.timer fstrim.timer man-db.timer motd-news.timer systemd-tmpfiles-clean.timer || true
run_logged "masking noisy timers and sockets" chroot_exec "$MOUNT_DIR" systemctl mask dpkg-db-backup.timer e2scrub_all.timer fstrim.timer man-db.timer motd-news.timer systemd-tmpfiles-clean.timer || true
run_logged "masking short-lived maintenance services" chroot_exec "$MOUNT_DIR" systemctl mask e2scrub_reap.service grub-common.service grub-initrd-fallback.service systemd-pstore.service || true
run_logged "purging unattended-upgrades" chroot_exec "$MOUNT_DIR" apt-get purge unattended-upgrades || true
if [[ -f "$MOUNT_DIR/etc/default/motd-news" ]]; then
  sed -i 's/ENABLED=1/ENABLED=0/g' "$MOUNT_DIR/etc/default/motd-news"
fi
run_logged "autoremove and purge unused packages" chroot_exec "$MOUNT_DIR" apt-get autoremove -y --purge
run_logged "cleaning apt caches" chroot_exec "$MOUNT_DIR" apt-get clean
run_logged "installing grub to $LOOP_DISK" chroot_exec "$MOUNT_DIR" grub-install --target=i386-pc "$LOOP_DISK"
run_logged "generating grub config" chroot_exec "$MOUNT_DIR" update-grub
run_logged "rewriting grub root device to partition uuid" sed -E -i "s#root=/dev/loop[0-9]+p1#root=PARTUUID=$ROOT_PARTUUID#g" "$MOUNT_DIR/boot/grub/grub.cfg"
run_logged "disabling ssh service by default" chroot_exec "$MOUNT_DIR" systemctl disable ssh || true
run_logged "enabling rolaunch service" chroot_exec "$MOUNT_DIR" systemctl enable rolaunch.service || true
truncate -s 0 "$MOUNT_DIR/etc/machine-id"
rm -f "$MOUNT_DIR/var/lib/dbus/machine-id"
rm -f "$MOUNT_DIR/etc/ssh/ssh_host_"*
rm -rf "$MOUNT_DIR/var/log/"*
rm -rf "$MOUNT_DIR/var/cache/apt/"*
rm -rf "$MOUNT_DIR/var/lib/apt/lists/"*
rm -rf "$MOUNT_DIR/var/cache/debconf/"*.dat-old "$MOUNT_DIR/var/cache/debconf/"*.dat
find "$MOUNT_DIR/var/tmp" -mindepth 1 -delete
find "$MOUNT_DIR/tmp" -mindepth 1 -delete
step "trimming sparse filesystem"
trim_rootfs_mount "$MOUNT_DIR"

cleanup_root "$MOUNT_DIR"
losetup -d "$LOOP_DISK"
LOOP_DISK=""
step "compacting sparse image holes"
compact_sparse_image "$SPARSE_IMAGE"

run_logged "wiping target disk $target_disk" wipefs -af "$target_disk"
step "materializing sparse image onto $target_disk"
ddpt_output="$(ddpt if="$SPARSE_IMAGE" of="$target_disk" oflag=sparse 2>&1)"
ddpt_summary="$(printf '%s\n' "$ddpt_output" | awk '/records in|records out|bypassed records out/ {print}' | paste -sd '; ' -)"
if [[ -n "$ddpt_summary" ]]; then
  step "$ddpt_summary"
fi
udevadm settle
sync
step "bootstrap completed"
