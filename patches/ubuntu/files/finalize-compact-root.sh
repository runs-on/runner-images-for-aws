#!/usr/bin/env bash

# Transform a finalized Ubuntu 26 x64 builder into a compact immutable root.
set -Eeuo pipefail
shopt -s nullglob
export LC_ALL=C

readonly asset_dir="${COMPACT_ROOT_ASSET_DIR:-/run/runs-on-compact-root}"
readonly target_size_gib="${TARGET_VOLUME_SIZE_GB:-}"
readonly variant="${COMPACT_ROOT_VARIANT:-full}"
readonly target_mapping="/dev/sdf"
readonly target_mount="/srv/runs-on-compact-target"
readonly work_dir="/var/lib/runs-on-compact-build"
readonly validation_dir="/run/runs-on-compact-validation"
readonly profile_sha256="4aeb92333b17c6f235dffe7be52391dc689b8a25d701f054c6d2ac96e57ec73d"

target_disk=''
target_p1=''
target_p13=''
target_p14=''
target_p15=''

log() {
  printf '[compact-finalizer] %s\n' "$*"
}

fail() {
  printf '[compact-finalizer] ERROR: %s\n' "$*" >&2
  exit 1
}

partition_path() {
  local disk="$1" number="$2"
  if [[ "${disk}" =~ [0-9]$ ]]; then
    printf '%sp%s\n' "${disk}" "${number}"
  else
    printf '%s%s\n' "${disk}" "${number}"
  fi
}

unmount_tree() {
  local root="$1" mount
  local -a mounts=()
  mapfile -t mounts < <(findmnt -Rnr -o TARGET --target "${root}" 2>/dev/null | sort -r)
  for mount in "${mounts[@]}"; do
    umount "${mount}" 2>/dev/null || true
  done
}

cleanup() {
  local status=$?
  trap - EXIT INT TERM
  unmount_tree "${validation_dir}"
  unmount_tree "${target_mount}"
  if [[ -d "${validation_dir}" && ! -L "${validation_dir}" ]]; then
    rm -rf -- "${validation_dir}"
  fi
  if [[ -d "${work_dir}" && ! -L "${work_dir}" ]]; then
    rm -rf -- "${work_dir}"
  fi
  exit "${status}"
}
trap cleanup EXIT INT TERM

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "required command is missing: $1"
}

resolve_backing_root_mount() {
  local marker=/etc/runs-on-overlay/backing-root-mount value
  if [[ ! -e "${marker}" ]]; then
    printf '/\n'
    return
  fi
  [[ -f "${marker}" && ! -L "${marker}" ]] || fail "invalid backing-root marker type"
  [[ $(wc -c < "${marker}") -le 4096 ]] || fail "backing-root marker is too large"
  IFS= read -r value < "${marker}" || true
  [[ "${value}" =~ ^/[A-Za-z0-9._/-]+$ && "${value}" != / && "${value}" != *'/../'* && "${value}" != */.. ]] || \
    fail "invalid backing-root marker value: ${value:-<empty>}"
  [[ "$(findmnt -nro TARGET --target "${value}")" == "${value}" ]] || fail "backing root is not an exact mount"
  printf '%s\n' "${value}"
}

resolve_ebs_target() {
  local disk mapping
  local -a matches=()
  while IFS= read -r disk; do
    mapping="$(ebsnvme-id -b "${disk}" 2>/dev/null | sed 's/[[:space:]]*$//' || true)"
    log "EBS mapping ${disk} -> ${mapping:-not-an-ebs-volume}" >&2
    if [[ "/dev/${mapping#/dev/}" == "${target_mapping}" ]]; then
      matches+=("$(readlink -f "${disk}")")
    fi
  done < <(lsblk -dnpo NAME,TYPE | awk '$2 == "disk" { print $1 }')
  [[ ${#matches[@]} -eq 1 ]] || fail "expected one Nitro disk for ${target_mapping}, found ${#matches[@]}"
  printf '%s\n' "${matches[0]}"
}

assert_isolated_fresh_target() {
  local target="$1" expected_bytes="$2" source_disk="$3"
  local target_name child mountpoint signature
  target_name="$(basename "${target}")"
  [[ -b "${target}" ]] || fail "resolved target is not a block device: ${target}"
  [[ "$(blockdev --getsize64 "${target}")" -eq "${expected_bytes}" ]] || fail "target size differs from ${target_size_gib} GiB"
  [[ "$(readlink -f "${target}")" != "$(readlink -f "${source_disk}")" ]] || fail "target resolves to the builder root disk"
  [[ "$(lsblk -dnro TYPE "${target}")" == disk ]] || fail "target is not a whole disk"
  if compgen -G "/sys/class/block/${target_name}/holders/*" >/dev/null; then
    fail "target disk has block holders"
  fi
  while read -r child; do
    [[ "$(readlink -f "${child}")" == "$(readlink -f "${target}")" ]] && continue
    fail "target already exposes a child block device: ${child}"
  done < <(lsblk -nrpo NAME "${target}")
  while read -r mountpoint; do
    [[ -z "${mountpoint}" ]] || fail "target is mounted at ${mountpoint}"
  done < <(lsblk -nrpo MOUNTPOINTS "${target}")
  awk -v disk="${target}" 'NR > 1 && $1 == disk { found = 1 } END { exit found ? 0 : 1 }' /proc/swaps && \
    fail "target is active swap"
  signature="$(wipefs -n "${target}" 2>/dev/null || true)"
  [[ -z "${signature}" ]] || fail "fresh target already contains a recognized signature"
  python3 - "${target}" <<'PY'
import os
import sys
fd = os.open(sys.argv[1], os.O_RDWR | os.O_EXCL | os.O_CLOEXEC)
os.close(fd)
PY
}

partition_field() {
  local disk="$1" number="$2" field="$3"
  sgdisk -i "${number}" "${disk}" | awk -F: -v field="${field}" '
    index($1, field) == 1 {
      value=$2
      sub(/^[[:space:]]+/, "", value)
      sub(/[[:space:]].*$/, "", value)
      print value
      exit
    }'
}

partition_name() {
  local disk="$1" number="$2"
  sgdisk -i "${number}" "${disk}" | sed -n "s/^Partition name: '\(.*\)'$/\1/p"
}

valid_partition_type_guid() {
  local type_code="$1"
  [[ "${type_code}" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]]
}

partition_target() {
  local source_disk="$1" destination_disk="$2"
  local number first last type name
  sgdisk --zap-all "${destination_disk}"
  for number in 13 14 15; do
    first="$(partition_field "${source_disk}" "${number}" 'First sector')"
    last="$(partition_field "${source_disk}" "${number}" 'Last sector')"
    type="$(partition_field "${source_disk}" "${number}" 'Partition GUID code')"
    name="$(partition_name "${source_disk}" "${number}")"
    if ! [[ "${first}" =~ ^[0-9]+$ && "${last}" =~ ^[0-9]+$ ]] || ! valid_partition_type_guid "${type}"; then
      fail "cannot read source partition ${number} geometry: first=${first:-missing} last=${last:-missing} type=${type:-missing}"
    fi
    sgdisk --new="${number}:${first}:${last}" --typecode="${number}:${type}" "${destination_disk}"
    [[ -z "${name}" ]] || sgdisk --change-name="${number}:${name}" "${destination_disk}"
  done
  first="$(partition_field "${source_disk}" 1 'First sector')"
  type="$(partition_field "${source_disk}" 1 'Partition GUID code')"
  name="$(partition_name "${source_disk}" 1)"
  if ! [[ "${first}" =~ ^[0-9]+$ ]] || ! valid_partition_type_guid "${type}"; then
    fail "cannot read source root geometry: first=${first:-missing} type=${type:-missing}"
  fi
  sgdisk --new="1:${first}:0" --typecode="1:${type}" "${destination_disk}"
  [[ -z "${name}" ]] || sgdisk --change-name="1:${name}" "${destination_disk}"
  sgdisk --randomize-guids "${destination_disk}"
  sgdisk --verify "${destination_disk}" | tee "${work_dir}/sgdisk-write.verify"
  grep -q 'No problems found' "${work_dir}/sgdisk-write.verify" || fail "target GPT validation failed"
  partprobe "${destination_disk}"
  udevadm settle
}

select_kernel() {
  local boot_dir="$1" kernel_path kernel_release package_status
  local -a releases=()
  for kernel_path in "${boot_dir}"/vmlinuz-*-aws; do
    [[ -f "${kernel_path}" ]] || continue
    kernel_release="${kernel_path#"${boot_dir}/vmlinuz-"}"
    package_status="$(dpkg-query -W -f='${db:Status-Status}' "linux-image-${kernel_release}" 2>/dev/null || true)"
    [[ "${package_status}" == installed ]] || continue
    releases+=("${kernel_release}")
  done
  [[ ${#releases[@]} -gt 0 ]] || fail "no installed linux-aws kernel image found"
  printf '%s\n' "${releases[@]}" | sort -V | tail -n1
}

find_overlay_module() {
  local kernel_release="$1" source destination
  source="$(find "/usr/lib/modules/${kernel_release}" -type f \( -name 'overlay.ko' -o -name 'overlay.ko.xz' -o -name 'overlay.ko.zst' -o -name 'overlay.ko.gz' \) -print -quit)"
  [[ -n "${source}" ]] || fail "cannot find OverlayFS module for ${kernel_release}"
  destination="${work_dir}/overlay.ko"
  case "${source}" in
    *.xz) xz -cd "${source}" > "${destination}" ;;
    *.zst) zstd -q -d -c "${source}" > "${destination}" ;;
    *.gz) gzip -cd "${source}" > "${destination}" ;;
    *) cp "${source}" "${destination}" ;;
  esac
  [[ -s "${destination}" ]] || fail "decompressed OverlayFS module is empty"
  [[ -z "$(modinfo -F depends "${destination}" | tr -d '[:space:]')" ]] || fail "OverlayFS module gained dependencies"
  [[ "$(modinfo -F vermagic "${destination}" | awk '{print $1}')" == "${kernel_release}" ]] || fail "OverlayFS module vermagic differs from selected kernel"
  printf '%s\n' "${destination}"
}

source_excludes() {
  cat <<'EOF'
.bootstrap
.recovery-initramfs
boot
dev
proc
sys
run
tmp
var/tmp
mnt
home/runner/_work
var/lib/docker
var/lib/containerd
var/lib/containers
var/lib/runs-on-direct-uefi
var/lib/runs-on-compact-build
var/log/journal
srv/runs-on-compact-target
lost+found
EOF
}

write_squash_excludes() {
  local destination="$1" item
  : > "${destination}"
  while IFS= read -r item; do
    printf '%s\n%s/*\n' "${item}" "${item}" >> "${destination}"
  done < <(source_excludes)
}

manifest_exclude_args() {
  local item
  while IFS= read -r item; do
    printf '%s\n' "${item}"
  done < <(source_excludes)
}

copy_tree() {
  local source="$1" destination="$2"
  install -d "${destination}"
  rsync -aHAXx --numeric-ids "${source%/}/" "${destination%/}/"
}

validate_copy_manifest() {
  local source="$1" destination="$2" label="$3"
  "${asset_dir}/compact-root-tree-manifest.py" "${source}" "${work_dir}/${label}-source.json"
  "${asset_dir}/compact-root-tree-manifest.py" "${destination}" "${work_dir}/${label}-target.json"
  cmp -s "${work_dir}/${label}-source.json" "${work_dir}/${label}-target.json" || fail "persistent tree differs: ${label}"
}

assert_variant() {
  local root="$1"
  [[ -x "${root}/usr/bin/rolaunch" ]] || fail "final root lacks rolaunch"
  [[ -x "${root}/home/runner/run.sh" || -x "${root}/home/runner/bin/Runner.Listener" ]] || fail "final root lacks the Actions runner"
  case "${variant}" in
    full) ;;
    gpu)
      [[ -x "${root}/usr/local/cuda-13/bin/nvcc" || -x "${root}/usr/local/cuda/bin/nvcc" || -x "${root}/usr/bin/nvcc" ]] || fail "GPU root lacks nvcc"
      [[ -x "${root}/usr/bin/nvidia-smi" ]] || fail "GPU root lacks nvidia-smi"
      [[ ! -e "${root}/root/cuda-installed.txt" ]] || fail "GPU installer sentinel leaked into final root"
      ;;
    stepsecurity)
      [[ -x "${root}/home/agent/agent" ]] || fail "StepSecurity root lacks the agent"
      [[ -x "${root}/runs-on/pre.custom.sh" && -x "${root}/runs-on/post.custom.sh" ]] || fail "StepSecurity root lacks executable pre/post hooks"
      [[ -f "${root}/etc/systemd/system/agent.service" ]] || fail "StepSecurity root lacks agent.service"
      grep -Eq '^ExecStart=.*/home/agent/agent([[:space:]]|$)' "${root}/etc/systemd/system/agent.service" || fail "agent.service does not start /home/agent/agent"
      ;;
    *) fail "unsupported compact-root variant: ${variant}" ;;
  esac
  for leaked in \
    etc/ssh/ssh_host_ed25519_key \
    etc/ssh/ssh_host_rsa_key \
    var/lib/rolaunch/instance-identity.json \
    var/lib/rolaunch/runs-on-user-data.done \
    var/lib/rolaunch/timings.json \
    var/lib/rolaunch/user-data.sh; do
    [[ ! -e "${root}/${leaked}" ]] || fail "builder state leaked into final root: ${leaked}"
  done
}

quiesce_root_writers() {
  local unit state
  local -a discovered_units=()
  local -a units=(
    amazon-ssm-agent.service
    chrony.service
    irqbalance.service
    syslog.socket
    rsyslog.socket
    rsyslog.service
    cron.service
    udisks2.service
    docker.service
    docker.socket
    containerd.service
    apt-daily.timer
    apt-daily-upgrade.timer
  )
  mapfile -t discovered_units < <(
    {
      systemctl list-units --type=timer --state=active --no-legend --plain || true
      systemctl list-units --type=service --state=active --no-legend --plain 'php*-fpm.service' || true
    } | awk 'NF { print $1 }' | sort -u
  )
  units+=("${discovered_units[@]}")

  for unit in "${units[@]}"; do
    systemctl stop "${unit}" 2>/dev/null || true
    state="$(systemctl is-active "${unit}" 2>/dev/null || true)"
    case "${state}" in
      ''|inactive|failed|unknown) ;;
      *) fail "root-writing unit did not stop: ${unit} (${state})" ;;
    esac
  done
}

clean_socket_nodes() {
  local socket
  local -a sockets=()
  mapfile -d '' -t sockets < <(find / -xdev -type s -print0 | sort -z)
  log "removing ${#sockets[@]} deliberate runtime socket nodes from the finalized source"
  for socket in "${sockets[@]}"; do
    log "removing socket ${socket}"
    rm -f -- "${socket}"
  done
  [[ -z "$(find / -xdev -type s -print -quit)" ]] || fail "a socket node remains in the source root"
}

remove_irrelevant_tpm_acl() {
  local root="$1" evidence="$2"
  local acl_path="${root%/}/var/lib/tpm2-tss/system/keystore"
  local before_acl after_acl
  [[ "${root}" == /* && -d "${root}" && ! -L "${root}" ]] \
    || fail "invalid ACL normalization root: ${root:-missing}"
  [[ -d "${acl_path}" ]] || fail "expected TPM keystore directory is missing"
  before_acl="$(getfacl --absolute-names --numeric --skip-base --physical -- "${acl_path}")"
  [[ "${before_acl}" == *$'default:'* ]] \
    || fail "expected TPM keystore default ACL is missing"
  printf '%s\n' "${before_acl}" > "${evidence}"
  setfacl --remove-all --remove-default -- "${acl_path}"
  after_acl="$(getfacl --absolute-names --numeric --skip-base --physical -- "${acl_path}")"
  [[ -z "${after_acl}" ]] || fail "TPM keystore still has an extended POSIX ACL"
  log "removed unsupported TPM keystore POSIX ACL"
}

build_squash() {
  local kernel_release="$1"
  local excludes="${work_dir}/squash-excludes"
  local profile="${work_dir}/boot.sort"
  local profile_report="${work_dir}/boot-profile.json"
  local squash="${work_dir}/rootfs.squashfs"
  local log_file="${work_dir}/mksquashfs.log"
  write_squash_excludes "${excludes}"
  echo "${profile_sha256}  ${asset_dir}/compact-root.boot-profile" | sha256sum -c -
  "${asset_dir}/filter-compact-root-boot-profile.py" \
    "${asset_dir}/compact-root.boot-profile" / "${profile}" \
    --kernel-release "${kernel_release}" \
    --exclude boot --exclude dev --exclude proc --exclude sys --exclude run \
    --exclude tmp --exclude var/tmp --exclude mnt --exclude home/runner/_work \
    --exclude var/lib/docker --exclude var/lib/containerd --exclude var/lib/containers \
    --exclude var/lib/runs-on-compact-build --exclude var/log/journal \
    --report "${profile_report}" \
    --min-output-count 900 \
    --min-coverage-percent 99
  grep -q '^usr/lib/systemd/systemd ' "${profile}" || fail "boot profile lacks systemd"
  grep -q '^usr/bin/rolaunch ' "${profile}" || fail "boot profile lacks rolaunch"

  mksquashfs / "${squash}" \
    -noappend -no-recovery -no-progress -exit-on-error -one-file-system -xattrs \
    -processors "$(nproc)" -comp zstd -Xcompression-level 3 -b 256K \
    -sort "${profile}" -wildcards -ef "${excludes}" 2>&1 | tee "${log_file}"
  [[ -s "${squash}" ]] || fail "SquashFS output is empty"
  if grep -qi 'warning' "${log_file}"; then
    fail "mksquashfs emitted an unexpected warning"
  fi
  if grep -qi 'unrecognised xattr prefix' "${log_file}"; then
    fail "mksquashfs emitted an unknown xattr warning"
  fi
  unsquashfs -stat "${squash}" | tee "${work_dir}/squash.stat"
  grep -q 'Compression zstd' "${work_dir}/squash.stat" || fail "SquashFS compression differs from zstd"
  grep -q 'Block size 262144' "${work_dir}/squash.stat" || fail "SquashFS block size differs from 256 KiB"
}

place_squash_first() {
  local source="$1" root="$2"
  local seed="${root}/.root-allocation-seed"
  local staged="${root}/rootfs.squashfs"
  local size first_block extent_count
  size="$(stat -c %s "${source}")"
  [[ "${size}" =~ ^[0-9]+$ && "${size}" -gt 16777216 ]] || fail "SquashFS is unexpectedly small"
  fallocate -l 16M "${seed}"
  sync
  filefrag -e -v "${seed}" | tee "${work_dir}/allocation-seed.filefrag"
  dd if="${source}" of="${staged}" bs=16M count=1 iflag=fullblock oflag=direct conv=notrunc status=none
  sync
  fallocate -l "${size}" "${staged}"
  dd if="${source}" of="${staged}" bs=16M iflag=fullblock oflag=direct conv=notrunc status=progress
  sync
  filefrag -e -v "${staged}" | tee "${work_dir}/rootfs.filefrag"
  first_block="$(awk '$1 == "0:" { value=$4; sub(/\.\..*/, "", value); print value; exit }' "${work_dir}/rootfs.filefrag")"
  extent_count="$(awk '/extents? found$/ { print $(NF - 2); exit }' "${work_dir}/rootfs.filefrag")"
  [[ "${first_block}" =~ ^[0-9]+$ && "${first_block}" -lt 1048576 ]] || fail "SquashFS header allocated too high: ${first_block:-unknown}"
  [[ "${extent_count}" =~ ^[0-9]+$ && "${extent_count}" -le 20 ]] || fail "SquashFS is too fragmented: ${extent_count:-unknown}"
  grep -Eq 'unwritten|delalloc' "${work_dir}/rootfs.filefrag" && fail "final SquashFS has unwritten or delayed extents"
  rm -f -- "${seed}"
  install -d -m 0700 "${root}/runs-on-root"
  mv "${staged}" "${root}/runs-on-root/rootfs.squashfs"
  (cd "${root}/runs-on-root" && sha256sum rootfs.squashfs > rootfs.squashfs.sha256)
}

install_recovery_initramfs() {
  local kernel_release="$1" overlay_module="$2" output="$3"
  local stage="${work_dir}/recovery-initramfs"
  install -d -m 0755 "${stage}/bin"
  install -m 0755 "${asset_dir}/compact-root-recovery-init" "${stage}/init"
  install -m 0755 /bin/busybox "${stage}/bin/busybox"
  install -m 0644 "${overlay_module}" "${stage}/overlay.ko"
  for applet in cat insmod mkdir mount mv pivot_root reboot sh sleep sync; do
    /bin/busybox --list | grep -qx "${applet}" || fail "static BusyBox lacks ${applet}"
  done
  /bin/busybox sh -n "${stage}/init"
  (
    cd "${stage}"
    find . -print0 | sort -z | cpio --null -o -H newc --quiet | gzip -1 > "${output}"
  )
  [[ -s "${output}" ]] || fail "recovery initramfs is empty"
}

write_effective_fstab() {
  local root="$1"
  install -d -m 0755 "${root}/runs-on-root/upper/etc"
  awk '
    $2 == "/" { next }
    $2 == "/boot" { $1 = "LABEL=BOOT" }
    $2 == "/boot/efi" { $1 = "LABEL=UEFI" }
    { print }
  ' /etc/fstab > "${root}/runs-on-root/upper/etc/fstab"
  grep -Eq '^LABEL=BOOT[[:space:]]+/boot[[:space:]]' "${root}/runs-on-root/upper/etc/fstab" || fail "effective fstab lacks LABEL=BOOT"
  grep -Eq '^LABEL=UEFI[[:space:]]+/boot/efi[[:space:]]' "${root}/runs-on-root/upper/etc/fstab" || fail "effective fstab lacks LABEL=UEFI"
}

write_recovery_cmdline() {
  local direct_cmdline_path="$1" recovery_cmdline_path="$2"
  local direct_cmdline argument
  local -a direct_arguments=() recovery_arguments=()

  [[ -f "${direct_cmdline_path}" && ! -L "${direct_cmdline_path}" ]] || fail "Direct cmdline state is not a regular file"
  [[ "$(awk 'END { print NR }' "${direct_cmdline_path}")" -eq 1 ]] || fail "Direct cmdline state must contain exactly one line"
  IFS= read -r direct_cmdline < "${direct_cmdline_path}" || true
  [[ -n "${direct_cmdline}" ]] || fail "Direct cmdline state is empty"
  read -ra direct_arguments <<< "${direct_cmdline}"

  for argument in "${direct_arguments[@]}"; do
    case "${argument}" in
      BOOT_IMAGE=*|initrd=*|initrdfail|initrdless_boot_fallback_triggered|init=/runs-on-root/init|console=*|earlycon|earlycon=*|quiet|loglevel=*|systemd.show_status=*|rd.systemd.show_status=*|runs_on.recovery=*)
        ;;
      *)
        recovery_arguments+=("${argument}")
        ;;
    esac
  done
  recovery_arguments+=("console=ttyS0" "runs_on.recovery=1")

  local recovery_cmdline="${recovery_arguments[*]}"
  [[ " ${recovery_cmdline} " == *' root=PARTUUID='* ]] || fail "recovery cmdline lacks the target root PARTUUID"
  [[ " ${recovery_cmdline} " == *' runs_on.immutable=1 '* ]] || fail "recovery cmdline lacks the immutable-root marker"
  [[ "${recovery_cmdline}" != *' quiet'* && "${recovery_cmdline}" != *'systemd.show_status='* ]] || fail "recovery cmdline suppresses boot status"
  [[ "$(tr ' ' '\n' <<< "${recovery_cmdline}" | grep -c '^console=')" -eq 1 ]] || fail "recovery cmdline must contain exactly one console"
  [[ "$(tr ' ' '\n' <<< "${recovery_cmdline}" | grep -c '^runs_on.recovery=1$')" -eq 1 ]] || fail "recovery cmdline must contain exactly one recovery marker"

  printf '%s\n' "${recovery_cmdline}" > "${recovery_cmdline_path}.new"
  chmod 0644 "${recovery_cmdline_path}.new"
  mv -f "${recovery_cmdline_path}.new" "${recovery_cmdline_path}"
}

write_grub_config() {
  local boot_root="$1" kernel_release="$2" boot_uuid="$3" recovery_cmdline="$4"
  install -d -m 0755 "${boot_root}/grub"
  cat > "${boot_root}/grub/grub.cfg" <<EOF
set default=0
set timeout=0
insmod part_gpt
insmod ext2
search --no-floppy --fs-uuid --set=root ${boot_uuid}

menuentry 'RunsOn compact root recovery' {
  linux /vmlinuz-${kernel_release} ${recovery_cmdline}
  initrd /runs-on-recovery-initrd-${kernel_release}.img
}
EOF
  grep -Fqx "  linux /vmlinuz-${kernel_release} ${recovery_cmdline}" "${boot_root}/grub/grub.cfg" || fail "GRUB recovery cmdline differs from persisted state"
}

verify_hash_manifest_at_root() {
  local root="$1" manifest="$2"
  sed "s#  /#  ${root%/}/#" "${manifest}" | sha256sum -c -
}

main() {
  [[ "${target_size_gib}" =~ ^[1-9][0-9]*$ ]] || fail "TARGET_VOLUME_SIZE_GB must be a positive integer"
  [[ "${IMAGE_OS:-}" == ubuntu26 ]] || fail "compact root is limited to Ubuntu 26"
  [[ "$(dpkg --print-architecture)" == amd64 ]] || fail "compact root is limited to amd64"
  grep -q '^VERSION_CODENAME=resolute$' /etc/os-release || fail "expected Ubuntu Resolute"
  [[ "${asset_dir}" == /run/runs-on-compact-root ]] || fail "assets must live on excluded /run"

  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    acl amazon-ec2-utils attr busybox-static cpio dosfstools e2fsprogs gdisk \
    grub-pc-bin grub2-common kmod python3 rsync squashfs-tools zstd
  apt-get clean
  rm -rf /var/lib/apt/lists/*
  for command in blkid blockdev cmp cpio dd e2fsck ebsnvme-id fallocate filefrag findmnt fsck.vfat getfacl grub-install lsblk mkfs.ext4 mkfs.vfat mksquashfs mount partprobe rsync setfacl sgdisk unsquashfs; do
    require_command "${command}"
  done
  for helper in compact-root-direct-init compact-root-recovery-init compact-root-tree-manifest.py compact-root.boot-profile filter-compact-root-boot-profile.py prepare-direct-uefi.sh; do
    [[ -s "${asset_dir}/${helper}" ]] || fail "compact-root asset is missing: ${helper}"
  done
  [[ ! -e "${work_dir}" ]] || fail "compact build work directory already exists"
  install -d -m 0700 "${work_dir}" "${validation_dir}"
  rm -f -- "$(readlink -f "$0")" 2>/dev/null || true

  quiesce_root_writers
  rm -f /etc/ssh/ssh_host_* /home/ubuntu/.ssh/authorized_keys /root/.ssh/authorized_keys /root/cuda-installed.txt
  rm -f /var/lib/rolaunch/instance-identity.json /var/lib/rolaunch/runs-on-user-data.done /var/lib/rolaunch/timings.json /var/lib/rolaunch/user-data.sh
  truncate -s 0 /etc/machine-id
  rm -f /var/lib/dbus/machine-id
  clean_socket_nodes
  remove_irrelevant_tpm_acl / "${work_dir}/removed-tpm-keystore.getfacl"
  assert_variant /
  local ssh_unit ssh_unit_state
  for ssh_unit in ssh.service ssh.socket; do
    ssh_unit_state="$(systemctl is-enabled "${ssh_unit}" 2>/dev/null || true)"
    [[ "${ssh_unit_state}" == disabled ]] || fail "${ssh_unit} must be disabled before finalization; got ${ssh_unit_state:-missing}"
  done

  local kernel_release kernel_config config_option overlay_module staged_squash
  kernel_release="$(select_kernel /boot)"
  kernel_config="/boot/config-${kernel_release}"
  [[ -n "${kernel_release}" && -f "${kernel_config}" ]] || fail "cannot select linux-aws kernel"
  for config_option in CONFIG_BLK_DEV_LOOP CONFIG_SQUASHFS CONFIG_SQUASHFS_ZSTD CONFIG_SQUASHFS_CHOICE_DECOMP_BY_MOUNT; do
    grep -qx "${config_option}=y" "${kernel_config}" || fail "linux-aws kernel does not build ${config_option} into the image"
  done
  overlay_module="$(find_overlay_module "${kernel_release}")"
  /bin/busybox sh -n "${asset_dir}/compact-root-direct-init"

  local -a exclude_args=()
  local exclusion
  while IFS= read -r exclusion; do exclude_args+=(--exclude "${exclusion}"); done < <(manifest_exclude_args)
  "${asset_dir}/compact-root-tree-manifest.py" / "${work_dir}/source-tree-full.json" "${exclude_args[@]}"
  build_squash "${kernel_release}"
  staged_squash="${work_dir}/rootfs.squashfs"
  [[ "${staged_squash}" == "${work_dir}/rootfs.squashfs" && -s "${staged_squash}" ]] || fail "SquashFS builder returned an invalid path"

  local backing_mount source_root_partition source_parent source_disk expected_bytes
  backing_mount="$(resolve_backing_root_mount)"
  source_root_partition="$(readlink -f "$(findmnt -nro SOURCE --target "${backing_mount}")")"
  source_parent="$(lsblk -nro PKNAME "${source_root_partition}" | awk '!seen {print; seen=1}')"
  [[ -n "${source_parent}" && "$(lsblk -nro PARTN "${source_root_partition}" | awk '!seen {print; seen=1}')" == 1 ]] || fail "builder backing root is not partition 1"
  source_disk="$(readlink -f "/dev/${source_parent}")"
  expected_bytes=$((target_size_gib * 1024 * 1024 * 1024))
  target_disk="$(resolve_ebs_target)"
  assert_isolated_fresh_target "${target_disk}" "${expected_bytes}" "${source_disk}"

  local source_disk_guid source_p1_guid source_p13_guid source_p14_guid source_p15_guid
  local source_root_uuid source_boot_uuid source_esp_uuid
  source_disk_guid="$(sgdisk -p "${source_disk}" | awk -F: '/Disk identifier \(GUID\)/ {gsub(/ /, "", $2); print tolower($2)}')"
  source_p1_guid="$(partition_field "${source_disk}" 1 'Partition unique GUID' | tr '[:upper:]' '[:lower:]')"
  source_p13_guid="$(partition_field "${source_disk}" 13 'Partition unique GUID' | tr '[:upper:]' '[:lower:]')"
  source_p14_guid="$(partition_field "${source_disk}" 14 'Partition unique GUID' | tr '[:upper:]' '[:lower:]')"
  source_p15_guid="$(partition_field "${source_disk}" 15 'Partition unique GUID' | tr '[:upper:]' '[:lower:]')"
  source_root_uuid="$(blkid -s UUID -o value "$(partition_path "${source_disk}" 1)")"
  source_boot_uuid="$(blkid -s UUID -o value "$(partition_path "${source_disk}" 13)")"
  source_esp_uuid="$(blkid -s UUID -o value "$(partition_path "${source_disk}" 15)")"
  [[ "${source_disk_guid}" =~ ^[0-9a-f-]{36}$ ]] || fail "source disk GUID is invalid"
  for guid in "${source_p1_guid}" "${source_p13_guid}" "${source_p14_guid}" "${source_p15_guid}"; do
    [[ "${guid}" =~ ^[0-9a-f-]{36}$ ]] || fail "source partition GUID is invalid: ${guid:-missing}"
  done
  [[ "${source_root_uuid}" =~ ^[0-9A-Fa-f-]{36}$ && "${source_boot_uuid}" =~ ^[0-9A-Fa-f-]{36}$ ]] || fail "source ext4 UUID is invalid"
  [[ "${source_esp_uuid}" =~ ^[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}$ ]] || fail "source ESP UUID is invalid"

  partition_target "${source_disk}" "${target_disk}"
  target_p1="$(partition_path "${target_disk}" 1)"
  target_p13="$(partition_path "${target_disk}" 13)"
  target_p14="$(partition_path "${target_disk}" 14)"
  target_p15="$(partition_path "${target_disk}" 15)"
  for partition in "${target_p1}" "${target_p13}" "${target_p14}" "${target_p15}"; do
    [[ -b "${partition}" ]] || fail "target partition is missing: ${partition}"
  done
  mkfs.ext4 -F -L cloudimg-rootfs -m 0 -E nodiscard,lazy_itable_init=0,lazy_journal_init=0 "${target_p1}"
  mkfs.ext4 -F -L BOOT -m 0 -E nodiscard,lazy_itable_init=0,lazy_journal_init=0 "${target_p13}"
  mkfs.vfat -F 32 -n UEFI "${target_p15}"

  install -d -m 0755 "${target_mount}"
  mount -o rw "${target_p1}" "${target_mount}"
  place_squash_first "${staged_squash}" "${target_mount}"
  install -m 0755 /bin/busybox "${target_mount}/runs-on-root/busybox"
  install -m 0755 "${asset_dir}/compact-root-direct-init" "${target_mount}/runs-on-root/init"
  install -m 0644 "${overlay_module}" "${target_mount}/runs-on-root/overlay.ko"
  printf '%s\n' "${kernel_release}" > "${target_mount}/runs-on-root/kernel-release"
  printf '%s\n' zstd > "${target_mount}/runs-on-root/compressor"
  printf '%s\n' 256K > "${target_mount}/runs-on-root/block-size"
  install -d -m 0755 "${target_mount}/runs-on-root/upper"
  install -d -m 0700 "${target_mount}/runs-on-root/work" "${target_mount}/runs-on-root/runtime" "${target_mount}/runs-on-root/recovery-runtime" "${target_mount}/runs-on-root/persist"

  local lower="${validation_dir}/lower" merged="${validation_dir}/merged"
  install -d -m 0755 "${lower}" "${merged}"
  mount -t squashfs -o loop,ro "${target_mount}/runs-on-root/rootfs.squashfs" "${lower}"
  assert_variant "${lower}"
  "${asset_dir}/compact-root-tree-manifest.py" "${lower}" "${work_dir}/lower-tree-full.json"
  cmp -s "${work_dir}/source-tree-full.json" "${work_dir}/lower-tree-full.json" || fail "SquashFS lower differs from finalized source"

  chown --reference=/ "${target_mount}/runs-on-root/upper"
  chmod --reference=/ "${target_mount}/runs-on-root/upper"
  touch --reference=/ "${target_mount}/runs-on-root/upper"
  mount -t overlay overlay -o "lowerdir=${lower},upperdir=${target_mount}/runs-on-root/upper,workdir=${target_mount}/runs-on-root/work" "${merged}"
  # OverlayFS may report lower-backed non-directories with the lower
  # filesystem's st_dev when xino is unavailable. This isolated validation
  # tree has no nested mounts, so include both OverlayFS and lower devices.
  "${asset_dir}/compact-root-tree-manifest.py" \
    "${merged}" "${work_dir}/merged-tree-full.json" --cross-filesystems
  cmp -s "${work_dir}/source-tree-full.json" "${work_dir}/merged-tree-full.json" || fail "merged tree differs from finalized source"
  umount "${merged}"
  rm -rf -- "${target_mount}/runs-on-root/work"
  install -d -m 0700 "${target_mount}/runs-on-root/work"

  mount -t overlay overlay -o "lowerdir=${lower},upperdir=${target_mount}/runs-on-root/upper,workdir=${target_mount}/runs-on-root/work" "${merged}"
  printf 'same-upper\n' > "${merged}/etc/.runs-on-upper-persistence"
  sync
  umount "${merged}"
  rm -rf -- "${target_mount}/runs-on-root/work"
  install -d -m 0700 "${target_mount}/runs-on-root/work"
  mount -t overlay overlay -o "lowerdir=${lower},upperdir=${target_mount}/runs-on-root/upper,workdir=${target_mount}/runs-on-root/work" "${merged}"
  [[ "$(< "${merged}/etc/.runs-on-upper-persistence")" == same-upper ]] || fail "GRUB path would not see Direct upper mutations"
  rm -f "${merged}/etc/.runs-on-upper-persistence"
  umount "${merged}"
  umount "${lower}"
  rm -rf -- "${target_mount}/runs-on-root/work"
  install -d -m 0700 "${target_mount}/runs-on-root/work"

  local path
  for path in home/runner/_work mnt tmp var/tmp var/lib/docker var/lib/containerd var/lib/containers; do
    install -d "/${path}"
    copy_tree "/${path}" "${target_mount}/runs-on-root/persist/${path}"
    validate_copy_manifest "/${path}" "${target_mount}/runs-on-root/persist/${path}" "persist-${path//\//-}"
  done
  write_effective_fstab "${target_mount}"
  install -d -m 0755 "${target_mount}/runs-on-root/upper/boot/efi"

  install -d -m 0755 "${target_mount}/boot"
  mount -o rw "${target_p13}" "${target_mount}/boot"
  rsync -aHAXx --numeric-ids --delete /boot/ "${target_mount}/boot/"
  install -d -m 0700 "${target_mount}/boot/efi"
  mount -o rw "${target_p15}" "${target_mount}/boot/efi"
  rsync -aHAXx --numeric-ids --delete /boot/efi/ "${target_mount}/boot/efi/"
  install_recovery_initramfs "${kernel_release}" "${overlay_module}" "${target_mount}/boot/runs-on-recovery-initrd-${kernel_release}.img"

  local root_partuuid boot_uuid target_disk_guid target_root_uuid target_boot_uuid target_esp_uuid
  local direct_state_dir recovery_cmdline_path recovery_cmdline
  root_partuuid="$(blkid -s PARTUUID -o value "${target_p1}")"
  boot_uuid="$(blkid -s UUID -o value "${target_p13}")"
  install -d -m 0755 "${target_mount}/boot/efi/EFI/ubuntu"
  cat > "${target_mount}/boot/efi/EFI/ubuntu/grub.cfg" <<EOF
search.fs_uuid ${boot_uuid} root hd0,gpt13
set prefix=(\$root)'/grub'
configfile \$prefix/grub.cfg
EOF
  grub-install --target=i386-pc --boot-directory="${target_mount}/boot" --recheck "${target_disk}"
  cmp -s -n 446 "${target_disk}" /dev/zero && fail "GRUB did not install protective-MBR boot code"
  cmp -s -n "$(blockdev --getsize64 "${target_p14}")" "${target_p14}" /dev/zero && fail "GRUB did not install a BIOS core image"

  direct_state_dir="${target_mount}/runs-on-root/upper/var/lib/runs-on-direct-uefi"
  DIRECT_UEFI_ESP_MOUNT="${target_mount}/boot/efi" \
  DIRECT_UEFI_DISK="${target_disk}" \
  DIRECT_UEFI_ESP_PARTITION=15 \
  DIRECT_UEFI_KERNEL_BOOT_DIR="${target_mount}/boot" \
  DIRECT_UEFI_ROOT_PARTUUID="${root_partuuid}" \
  DIRECT_UEFI_EXTRA_ARGUMENTS='rw init=/runs-on-root/init runs_on.immutable=1 runs_on.squash_threads=percpu' \
  DIRECT_UEFI_STATE_DIR="${direct_state_dir}" \
    "${asset_dir}/prepare-direct-uefi.sh"
  recovery_cmdline_path="${direct_state_dir}/expected-recovery-cmdline"
  write_recovery_cmdline "${direct_state_dir}/expected-cmdline" "${recovery_cmdline_path}"
  recovery_cmdline="$(< "${recovery_cmdline_path}")"
  write_grub_config "${target_mount}/boot" "${kernel_release}" "${boot_uuid}" "${recovery_cmdline}"

  target_disk_guid="$(sgdisk -p "${target_disk}" | awk -F: '/Disk identifier \(GUID\)/ {gsub(/ /, "", $2); print tolower($2)}')"
  target_root_uuid="$(blkid -s UUID -o value "${target_p1}")"
  target_boot_uuid="$(blkid -s UUID -o value "${target_p13}")"
  target_esp_uuid="$(blkid -s UUID -o value "${target_p15}")"
  [[ "${target_disk_guid}" != "${source_disk_guid}" ]] || fail "target disk GUID was reused"
  [[ "${root_partuuid}" != "${source_p1_guid}" ]] || fail "target root PARTUUID was reused"
  [[ "$(blkid -s PARTUUID -o value "${target_p13}")" != "${source_p13_guid}" ]] || fail "target BOOT PARTUUID was reused"
  [[ "$(blkid -s PARTUUID -o value "${target_p14}")" != "${source_p14_guid}" ]] || fail "target BIOS PARTUUID was reused"
  [[ "$(blkid -s PARTUUID -o value "${target_p15}")" != "${source_p15_guid}" ]] || fail "target ESP PARTUUID was reused"
  [[ "${target_root_uuid}" != "${source_root_uuid}" && "${target_boot_uuid}" != "${source_boot_uuid}" && "${target_esp_uuid}" != "${source_esp_uuid}" ]] || fail "target filesystem identity was reused"

  sync
  unmount_tree "${target_mount}"
  e2fsck -fn "${target_p1}" | tee "${work_dir}/root.fsck"
  e2fsck -fn "${target_p13}" | tee "${work_dir}/boot.fsck"
  fsck.vfat -n "${target_p15}" | tee "${work_dir}/esp.fsck"
  sgdisk --verify "${target_disk}" | tee "${work_dir}/sgdisk-final.verify"
  grep -q 'No problems found' "${work_dir}/sgdisk-final.verify" || fail "final GPT validation failed"

  mount -o ro,noload "${target_p1}" "${target_mount}"
  mount -o ro,noload "${target_p13}" "${target_mount}/boot"
  mount -o ro "${target_p15}" "${target_mount}/boot/efi"
  (cd "${target_mount}/runs-on-root" && sha256sum -c --strict rootfs.squashfs.sha256)
  recovery_cmdline="$(< "${target_mount}/runs-on-root/upper/var/lib/runs-on-direct-uefi/expected-recovery-cmdline")"
  grep -Fqx "  linux /vmlinuz-${kernel_release} ${recovery_cmdline}" "${target_mount}/boot/grub/grub.cfg" || fail "persisted GRUB recovery cmdline differs from state"
  verify_hash_manifest_at_root "${target_mount}" "${target_mount}/runs-on-root/upper/var/lib/runs-on-direct-uefi/direct-kernel.sha256"
  verify_hash_manifest_at_root "${target_mount}" "${target_mount}/runs-on-root/upper/var/lib/runs-on-direct-uefi/fallback.sha256"
  mount -t squashfs -o loop,ro "${target_mount}/runs-on-root/rootfs.squashfs" "${lower}"
  assert_variant "${lower}"
  umount "${lower}"
  log "final SquashFS sha256=$(cut -d' ' -f1 "${target_mount}/runs-on-root/rootfs.squashfs.sha256")"
  log "final target identities disk=${target_disk_guid} root_partuuid=${root_partuuid} root_uuid=${target_root_uuid} boot_uuid=${target_boot_uuid} esp_uuid=${target_esp_uuid}"
  unmount_tree "${target_mount}"
  log "direct compact target complete: variant=${variant} disk=${target_disk} size_gib=${target_size_gib}"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
