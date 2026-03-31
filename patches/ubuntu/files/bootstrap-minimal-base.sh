#!/bin/bash

set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

TARGET_VOLUME_SIZE_GB="${TARGET_VOLUME_SIZE_GB:-2}"
UBUNTU_RELEASE="${UBUNTU_RELEASE:-noble}"
UBUNTU_MIRROR="${UBUNTU_MIRROR:-http://archive.ubuntu.com/ubuntu}"
UBUNTU_SECURITY_MIRROR="${UBUNTU_SECURITY_MIRROR:-http://security.ubuntu.com/ubuntu}"
BOOTSTRAP_APT_TIMEOUT_SECONDS="${BOOTSTRAP_APT_TIMEOUT_SECONDS:-900}"
DEBOOTSTRAP_TIMEOUT_SECONDS="${DEBOOTSTRAP_TIMEOUT_SECONDS:-1200}"
CHROOT_APT_TIMEOUT_SECONDS="${CHROOT_APT_TIMEOUT_SECONDS:-900}"
TARGET_ROOT_MOUNT="${TARGET_ROOT_MOUNT:-/mnt/minimal-root}"
SPARSE_IMAGE="${SPARSE_IMAGE:-/var/tmp/ubuntu24-minimal-root.img}"
MINIMAL_TARGET_STATE_FILE="${MINIMAL_TARGET_STATE_FILE:-/var/lib/runs-on/minimal-target/state.env}"
ROLAUNCH_SOURCE="${ROLAUNCH_SOURCE:-}"
LOOP_DISK=""

step() {
  echo "[minimal-base] $*"
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
  timeout --foreground --signal=TERM --kill-after=30s "${timeout_seconds}" "$@"
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
  set -e
}

cleanup_on_error() {
  local exit_code=$?

  echo "[minimal-base] base bootstrap failed" >&2
  cleanup_root "$TARGET_ROOT_MOUNT"
  if [[ -n "$LOOP_DISK" ]]; then
    losetup -d "$LOOP_DISK" || true
  fi
  rm -f "$SPARSE_IMAGE"
  exit "$exit_code"
}

trap cleanup_on_error ERR

root_source="$(findmnt -n -o SOURCE /)"
root_parent_disk="/dev/$(lsblk -nro PKNAME "$root_source" | head -n1)"
target_bytes=$((TARGET_VOLUME_SIZE_GB * 1024 * 1024 * 1024))

find_target_disk() {
  while read -r name type size; do
    local disk="/dev/$name"
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

write_target_state() {
  local target_disk="$1"
  local loop_disk="$2"
  local root_partuuid="$3"

  install -d -m 0755 "$(dirname "$MINIMAL_TARGET_STATE_FILE")"
  {
    printf 'TARGET_ROOT_MOUNT=%q\n' "$TARGET_ROOT_MOUNT"
    printf 'SPARSE_IMAGE=%q\n' "$SPARSE_IMAGE"
    printf 'TARGET_DISK=%q\n' "$target_disk"
    printf 'LOOP_DISK=%q\n' "$loop_disk"
    printf 'ROOT_PARTUUID=%q\n' "$root_partuuid"
    printf 'MINIMAL_TARGET_STATE_FILE=%q\n' "$MINIMAL_TARGET_STATE_FILE"
  } > "$MINIMAL_TARGET_STATE_FILE"
}

install_target_helpers() {
  install -d -m 0755 /usr/local/bin

  cat > /usr/local/bin/ro-run-in-target <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

STATE_FILE="${MINIMAL_TARGET_STATE_FILE:-/var/lib/runs-on/minimal-target/state.env}"
if [[ -f "$STATE_FILE" ]]; then
  source "$STATE_FILE"
fi

TARGET_ROOT_MOUNT="${TARGET_ROOT_MOUNT:-/mnt/minimal-root}"
DEBIAN_FRONTEND="${DEBIAN_FRONTEND:-noninteractive}"
IMAGE_FOLDER="${IMAGE_FOLDER:-/imagegeneration}"
HELPER_SCRIPTS="${HELPER_SCRIPTS:-${IMAGE_FOLDER}/helpers}"
HELPER_SCRIPT_FOLDER="${HELPER_SCRIPT_FOLDER:-${HELPER_SCRIPTS}}"
INSTALLER_SCRIPT_FOLDER="${INSTALLER_SCRIPT_FOLDER:-${IMAGE_FOLDER}/installers}"
IMAGEDATA_FILE="${IMAGEDATA_FILE:-${IMAGE_FOLDER}/imagedata.json}"

if [[ $# -eq 0 ]]; then
  echo "usage: ro-run-in-target <command>" >&2
  exit 64
fi

command="$*"
chroot "$TARGET_ROOT_MOUNT" /usr/bin/env \
  "IMAGE_VERSION=${IMAGE_VERSION-}" \
  "IMAGE_OS=${IMAGE_OS-}" \
  "IMAGE_FOLDER=${IMAGE_FOLDER}" \
  "HELPER_SCRIPTS=${HELPER_SCRIPTS}" \
  "HELPER_SCRIPT_FOLDER=${HELPER_SCRIPT_FOLDER}" \
  "INSTALLER_SCRIPT_FOLDER=${INSTALLER_SCRIPT_FOLDER}" \
  "IMAGEDATA_FILE=${IMAGEDATA_FILE}" \
  "TARGET_UBUNTU_MIRROR=${TARGET_UBUNTU_MIRROR-}" \
  "TARGET_UBUNTU_SECURITY_MIRROR=${TARGET_UBUNTU_SECURITY_MIRROR-}" \
  "MINIMAL_INCLUDE_FULL_INSTALLERS=${MINIMAL_INCLUDE_FULL_INSTALLERS-false}" \
  "DEBIAN_FRONTEND=${DEBIAN_FRONTEND}" \
  "SUDO_USER=${SUDO_USER:-runner}" \
  /bin/bash -lc "$command"
EOF

  cat > /usr/local/bin/ro-run-script-in-target <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

STATE_FILE="${MINIMAL_TARGET_STATE_FILE:-/var/lib/runs-on/minimal-target/state.env}"
if [[ -f "$STATE_FILE" ]]; then
  source "$STATE_FILE"
fi

TARGET_ROOT_MOUNT="${TARGET_ROOT_MOUNT:-/mnt/minimal-root}"
DEBIAN_FRONTEND="${DEBIAN_FRONTEND:-noninteractive}"
IMAGE_FOLDER="${IMAGE_FOLDER:-/imagegeneration}"
HELPER_SCRIPTS="${HELPER_SCRIPTS:-${IMAGE_FOLDER}/helpers}"
HELPER_SCRIPT_FOLDER="${HELPER_SCRIPT_FOLDER:-${HELPER_SCRIPTS}}"
INSTALLER_SCRIPT_FOLDER="${INSTALLER_SCRIPT_FOLDER:-${IMAGE_FOLDER}/installers}"
IMAGEDATA_FILE="${IMAGEDATA_FILE:-${IMAGE_FOLDER}/imagedata.json}"

if [[ $# -lt 1 ]]; then
  echo "usage: ro-run-script-in-target <script> [args...]" >&2
  exit 64
fi

script_path="$1"
shift

chroot "$TARGET_ROOT_MOUNT" /usr/bin/env \
  "IMAGE_VERSION=${IMAGE_VERSION-}" \
  "IMAGE_OS=${IMAGE_OS-}" \
  "IMAGE_FOLDER=${IMAGE_FOLDER}" \
  "HELPER_SCRIPTS=${HELPER_SCRIPTS}" \
  "HELPER_SCRIPT_FOLDER=${HELPER_SCRIPT_FOLDER}" \
  "INSTALLER_SCRIPT_FOLDER=${INSTALLER_SCRIPT_FOLDER}" \
  "IMAGEDATA_FILE=${IMAGEDATA_FILE}" \
  "TARGET_UBUNTU_MIRROR=${TARGET_UBUNTU_MIRROR-}" \
  "TARGET_UBUNTU_SECURITY_MIRROR=${TARGET_UBUNTU_SECURITY_MIRROR-}" \
  "MINIMAL_INCLUDE_FULL_INSTALLERS=${MINIMAL_INCLUDE_FULL_INSTALLERS-false}" \
  "DEBIAN_FRONTEND=${DEBIAN_FRONTEND}" \
  "SUDO_USER=${SUDO_USER:-runner}" \
  /bin/bash "$script_path" "$@"
EOF

  cat > /usr/local/bin/ro-bash-in-target <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

STATE_FILE="${MINIMAL_TARGET_STATE_FILE:-/var/lib/runs-on/minimal-target/state.env}"
if [[ -f "$STATE_FILE" ]]; then
  source "$STATE_FILE"
fi

TARGET_ROOT_MOUNT="${TARGET_ROOT_MOUNT:-/mnt/minimal-root}"
DEBIAN_FRONTEND="${DEBIAN_FRONTEND:-noninteractive}"
IMAGE_FOLDER="${IMAGE_FOLDER:-/imagegeneration}"
HELPER_SCRIPTS="${HELPER_SCRIPTS:-${IMAGE_FOLDER}/helpers}"
HELPER_SCRIPT_FOLDER="${HELPER_SCRIPT_FOLDER:-${HELPER_SCRIPTS}}"
INSTALLER_SCRIPT_FOLDER="${INSTALLER_SCRIPT_FOLDER:-${IMAGE_FOLDER}/installers}"
IMAGEDATA_FILE="${IMAGEDATA_FILE:-${IMAGE_FOLDER}/imagedata.json}"

chroot "$TARGET_ROOT_MOUNT" /usr/bin/env \
  "IMAGE_VERSION=${IMAGE_VERSION-}" \
  "IMAGE_OS=${IMAGE_OS-}" \
  "IMAGE_FOLDER=${IMAGE_FOLDER}" \
  "HELPER_SCRIPTS=${HELPER_SCRIPTS}" \
  "HELPER_SCRIPT_FOLDER=${HELPER_SCRIPT_FOLDER}" \
  "INSTALLER_SCRIPT_FOLDER=${INSTALLER_SCRIPT_FOLDER}" \
  "IMAGEDATA_FILE=${IMAGEDATA_FILE}" \
  "TARGET_UBUNTU_MIRROR=${TARGET_UBUNTU_MIRROR-}" \
  "TARGET_UBUNTU_SECURITY_MIRROR=${TARGET_UBUNTU_SECURITY_MIRROR-}" \
  "MINIMAL_INCLUDE_FULL_INSTALLERS=${MINIMAL_INCLUDE_FULL_INSTALLERS-false}" \
  "DEBIAN_FRONTEND=${DEBIAN_FRONTEND}" \
  "SUDO_USER=${SUDO_USER:-runner}" \
  /bin/bash -s "$@"
EOF

  chmod 0755 \
    /usr/local/bin/ro-run-in-target \
    /usr/local/bin/ro-run-script-in-target \
    /usr/local/bin/ro-bash-in-target
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
mkdir -p "$TARGET_ROOT_MOUNT"
run_logged "mounting sparse root filesystem" mount -o discard "$loop_partition" "$TARGET_ROOT_MOUNT"

run_logged_timeout "debootstrap $UBUNTU_RELEASE rootfs" "$DEBOOTSTRAP_TIMEOUT_SECONDS" \
  debootstrap --arch=amd64 --variant=minbase "$UBUNTU_RELEASE" "$TARGET_ROOT_MOUNT" "$UBUNTU_MIRROR"

cat > "$TARGET_ROOT_MOUNT/etc/apt/sources.list" <<EOF
deb $UBUNTU_MIRROR $UBUNTU_RELEASE main restricted universe multiverse
deb $UBUNTU_MIRROR ${UBUNTU_RELEASE}-updates main restricted universe multiverse
deb $UBUNTU_SECURITY_MIRROR ${UBUNTU_RELEASE}-security main restricted universe multiverse
EOF

mkdir -p \
  "$TARGET_ROOT_MOUNT/etc/dpkg/dpkg.cfg.d" \
  "$TARGET_ROOT_MOUNT/etc/netplan" \
  "$TARGET_ROOT_MOUNT/etc/systemd/system/systemd-networkd-wait-online.service.d" \
  "$TARGET_ROOT_MOUNT/etc/modprobe.d" \
  "$TARGET_ROOT_MOUNT/etc/ssh/sshd_config.d"

cat > "$TARGET_ROOT_MOUNT/etc/dpkg/dpkg.cfg.d/01lean" <<'EOF'
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
mount_chroot_root "$TARGET_ROOT_MOUNT"

run_logged_timeout "updating apt inside target rootfs" "$CHROOT_APT_TIMEOUT_SECONDS" \
  chroot "$TARGET_ROOT_MOUNT" /usr/bin/env DEBIAN_FRONTEND=noninteractive apt-get update
run_logged_timeout "installing minimal runtime packages" "$CHROOT_APT_TIMEOUT_SECONDS" \
  chroot "$TARGET_ROOT_MOUNT" /usr/bin/env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
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
  bash /tmp/install-runs-on-bootstrap.sh "$TARGET_ROOT_MOUNT"

run_logged "creating ubuntu user" chroot_exec "$TARGET_ROOT_MOUNT" /bin/bash -lc '
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

install -D -m 0755 "$ROLAUNCH_SOURCE" "$TARGET_ROOT_MOUNT/usr/bin/rolaunch"

cat > "$TARGET_ROOT_MOUNT/etc/fstab" <<EOF
PARTUUID=$ROOT_PARTUUID / ext4 defaults 0 0
EOF

cat > "$TARGET_ROOT_MOUNT/etc/hostname" <<'EOF'
ubuntu24-minimal
EOF

cat > "$TARGET_ROOT_MOUNT/etc/hosts" <<'EOF'
127.0.0.1 localhost
127.0.1.1 ubuntu24-minimal

::1 localhost ip6-localhost ip6-loopback
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters
EOF

cat > "$TARGET_ROOT_MOUNT/etc/netplan/10-ec2.yaml" <<'EOF'
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

cat > "$TARGET_ROOT_MOUNT/etc/ssh/sshd_config.d/10-hostkeys.conf" <<'EOF'
HostKey /etc/ssh/ssh_host_ed25519_key
PermitRootLogin yes
PasswordAuthentication no
KbdInteractiveAuthentication no
EOF

cat > "$TARGET_ROOT_MOUNT/etc/systemd/system/rolaunch.service" <<'EOF'
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

rm -f "$TARGET_ROOT_MOUNT/etc/systemd/system/ldconfig-after-rolaunch.service"

cat > "$TARGET_ROOT_MOUNT/etc/default/grub" <<'EOF'
GRUB_DEFAULT=0
GRUB_TIMEOUT=0
GRUB_DISTRIBUTOR=`( . /etc/os-release; echo ${NAME:-Ubuntu} ) 2>/dev/null || echo Ubuntu`
GRUB_CMDLINE_LINUX_DEFAULT="console=ttyS0 nvme_core.io_timeout=4294967295 panic=-1 raid=noautodetect i8042.nokbd i8042.noaux i8042.nomux i8042.nopnp"
GRUB_CMDLINE_LINUX=""
GRUB_TERMINAL="console serial"
GRUB_SERIAL_COMMAND="serial --speed=115200 --unit=0 --word=8 --parity=no --stop=1"
EOF

cat > "$TARGET_ROOT_MOUNT/etc/systemd/system/systemd-networkd-wait-online.service.d/override.conf" <<'EOF'
[Service]
ExecStart=
ExecStart=/usr/lib/systemd/systemd-networkd-wait-online --any --ipv4 --timeout=5
EOF

cat > "$TARGET_ROOT_MOUNT/etc/default/locale" <<'EOF'
LANG=C.UTF-8
LC_ALL=C.UTF-8
EOF

cat > "$TARGET_ROOT_MOUNT/etc/apt/apt.conf.d/80-retries" <<'EOF'
APT::Acquire::Retries "10";
EOF

cat > "$TARGET_ROOT_MOUNT/etc/apt/apt.conf.d/90assumeyes" <<'EOF'
APT::Get::Assume-Yes "true";
EOF

cat > "$TARGET_ROOT_MOUNT/etc/apt/apt.conf.d/99-phased-updates" <<'EOF'
APT::Get::Always-Include-Phased-Updates "true";
EOF

cat > "$TARGET_ROOT_MOUNT/etc/apt/apt.conf.d/99bad_proxy" <<'EOF'
Acquire::http::Pipeline-Depth 0;
Acquire::http::No-Cache true;
Acquire::https::Pipeline-Depth 0;
Acquire::https::No-Cache true;
Acquire::BrokenProxy true;
EOF

cat > "$TARGET_ROOT_MOUNT/etc/modprobe.d/runs-on-minimal-blacklist.conf" <<'EOF'
# Legacy parallel-port stack is not useful on EC2 runner images.
blacklist ppdev
blacklist parport_pc
blacklist parport
EOF

run_logged "installing grub to $LOOP_DISK" chroot_exec "$TARGET_ROOT_MOUNT" grub-install --target=i386-pc "$LOOP_DISK"
run_logged "generating grub config" chroot_exec "$TARGET_ROOT_MOUNT" update-grub
run_logged "rewriting grub root device to partition uuid" sed -E -i "s#root=/dev/loop[0-9]+p1#root=PARTUUID=$ROOT_PARTUUID#g" "$TARGET_ROOT_MOUNT/boot/grub/grub.cfg"

write_target_state "$target_disk" "$LOOP_DISK" "$ROOT_PARTUUID"
install_target_helpers

step "base bootstrap completed; target root mounted at $TARGET_ROOT_MOUNT"
step "state recorded in $MINIMAL_TARGET_STATE_FILE"
