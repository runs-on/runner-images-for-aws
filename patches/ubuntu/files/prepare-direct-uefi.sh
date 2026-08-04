#!/usr/bin/env bash

set -euo pipefail

export LC_ALL=C

readonly label_direct="RunsOn direct Linux"
readonly label_fallback="RunsOn GRUB fallback"
readonly state_dir="${DIRECT_UEFI_STATE_DIR:-/var/lib/runs-on-direct-uefi}"

fallback_hashes_before=''
fallback_hashes_after=''

cleanup() {
  local path

  for path in "${fallback_hashes_before}" "${fallback_hashes_after}"; do
    [[ -z "${path}" ]] || rm -f "${path}"
  done
}

cleanup_on_exit() {
  local status=$?

  trap - EXIT
  cleanup
  exit "${status}"
}
trap cleanup_on_exit EXIT

fail() {
  echo "[direct-uefi] $*" >&2
  exit 1
}

bootnums_for_label_from_output() {
  local label="$1"

  awk -v label="${label}" '
    $0 ~ /^Boot[0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][* ]/ {
      bootnum = substr($0, 5, 4)
      entry_label = $0
      sub(/^Boot[0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][* ]+[[:space:]]*/, "", entry_label)
      sub(/\t.*/, "", entry_label)
      sub(/[[:space:]]+$/, "", entry_label)
      if (entry_label == label) {
        print bootnum
      }
    }
  '
}

bootnums_for_label() {
  local label="$1"
  local output

  output="$(efibootmgr)"
  bootnums_for_label_from_output "${label}" <<< "${output}"
}

delete_boot_entries_for_label() {
  local label="$1"
  local bootnums bootnum

  bootnums="$(bootnums_for_label "${label}")"
  while IFS= read -r bootnum; do
    [[ -z "${bootnum}" ]] || efibootmgr --bootnum "${bootnum}" --delete-bootnum
  done <<< "${bootnums}"
}

unique_bootnum_for_label() {
  local label="$1"
  local bootnums bootnum count

  bootnums="$(bootnums_for_label "${label}")"
  count="$(awk 'NF { count++ } END { print count + 0 }' <<< "${bootnums}")"
  bootnum="$(awk 'NF && !found { print; found = 1 }' <<< "${bootnums}")"
  if [[ "${count}" -ne 1 || ! "${bootnum}" =~ ^[0-9A-Fa-f]{4}$ ]]; then
    fail "expected exactly one EFI entry named ${label}"
  fi
  printf '%s\n' "${bootnum}" | tr '[:lower:]' '[:upper:]'
}

compose_boot_order() {
  local fallback_bootnum direct_bootnum
  local original_order="$3"
  local entry seen
  local -a original_entries=()
  local -a new_entries=()

  fallback_bootnum="$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')"
  direct_bootnum="$(printf '%s' "$2" | tr '[:lower:]' '[:upper:]')"
  new_entries=("${fallback_bootnum}")
  seen=",${fallback_bootnum},${direct_bootnum},"

  IFS=',' read -ra original_entries <<< "${original_order}"
  for entry in "${original_entries[@]}"; do
    entry="${entry//[[:space:]]/}"
    entry="$(printf '%s' "${entry}" | tr '[:lower:]' '[:upper:]')"
    [[ "${entry}" =~ ^[0-9A-F]{4}$ ]] || fail "invalid EFI boot number in BootOrder: ${entry}"
    if [[ "${seen}" != *",${entry},"* ]]; then
      new_entries+=("${entry}")
      seen+="${entry},"
    fi
  done
  new_entries+=("${direct_bootnum}")

  local IFS=','
  printf '%s\n' "${new_entries[*]}"
}

select_latest_aws_kernel() {
  local boot_dir="${1:-/boot}"
  local kernel_path kernel_release package_status
  local -a releases=()

  for kernel_path in "${boot_dir}"/vmlinuz-*-aws; do
    [[ -f "${kernel_path}" ]] || continue
    kernel_release="${kernel_path#"${boot_dir}/vmlinuz-"}"
    package_status="$(dpkg-query -W -f='${db:Status-Status}' "linux-image-${kernel_release}" 2>/dev/null || true)"
    [[ "${package_status}" == "installed" ]] || continue
    releases+=("${kernel_release}")
  done
  [[ "${#releases[@]}" -gt 0 ]] || fail "no installed linux-aws kernel image found"

  printf '%s\n' "${releases[@]}" | sort -V | awk 'NF { latest = $0 } END { print latest }'
}

validate_direct_cmdline() {
  local kernel_cmdline="$1"
  local argument
  local console_count=0
  local quiet_count=0
  local loglevel_count=0
  local systemd_status_count=0
  local rd_systemd_status_count=0
  local -a kernel_arguments=()

  [[ " ${kernel_cmdline} " == *' root=PARTUUID='* ]] || fail "direct kernel command line has no root=PARTUUID= argument"
  [[ " ${kernel_cmdline} " == *' panic=-1 '* ]] || fail "direct kernel command line must reboot immediately after a panic"
  [[ " ${kernel_cmdline} " != *' initrd='* ]] || fail "direct kernel command line still refers to an initrd"

  read -ra kernel_arguments <<< "${kernel_cmdline}"
  for argument in "${kernel_arguments[@]}"; do
    case "${argument}" in
      console=*)
        console_count="$((console_count + 1))"
        [[ "${argument}" == 'console=null' ]] || fail "direct kernel command line contains an active console"
        ;;
      earlycon|earlycon=*)
        fail "direct kernel command line still enables an early console"
        ;;
      quiet)
        quiet_count="$((quiet_count + 1))"
        ;;
      loglevel=*)
        loglevel_count="$((loglevel_count + 1))"
        [[ "${argument}" == 'loglevel=3' ]] || fail "direct kernel command line has the wrong log level"
        ;;
      systemd.show_status=*)
        systemd_status_count="$((systemd_status_count + 1))"
        [[ "${argument}" == 'systemd.show_status=false' ]] || fail "direct kernel command line still shows systemd status"
        ;;
      rd.systemd.show_status=*)
        rd_systemd_status_count="$((rd_systemd_status_count + 1))"
        [[ "${argument}" == 'rd.systemd.show_status=false' ]] || fail "direct kernel command line still shows initrd systemd status"
        ;;
    esac
  done
  [[ "${console_count}" -eq 1 ]] || fail "direct kernel command line must contain exactly one console=null argument"
  [[ "${quiet_count}" -eq 1 ]] || fail "direct kernel command line must contain exactly one quiet argument"
  [[ "${loglevel_count}" -eq 1 ]] || fail "direct kernel command line must contain exactly one loglevel=3 argument"
  [[ "${systemd_status_count}" -eq 1 ]] || fail "direct kernel command line must contain exactly one systemd.show_status=false argument"
  [[ "${rd_systemd_status_count}" -eq 1 ]] || fail "direct kernel command line must contain exactly one rd.systemd.show_status=false argument"
}

compose_direct_cmdline() {
  local argument kernel_cmdline=''
  local root_partuuid="${DIRECT_UEFI_ROOT_PARTUUID:-}"
  local extra_arguments="${DIRECT_UEFI_EXTRA_ARGUMENTS:-}"
  local -a extra_kernel_arguments=()

  for argument in "$@"; do
    case "${argument}" in
      BOOT_IMAGE=*|initrd=*|initrdfail|initrdless_boot_fallback_triggered|console=*|earlycon|earlycon=*|quiet|loglevel=*|systemd.show_status=*|rd.systemd.show_status=*)
        ;;
      root=PARTUUID=*)
        [[ -z "${root_partuuid}" ]] && kernel_cmdline+="${kernel_cmdline:+ }${argument}"
        ;;
      init=/runs-on-root/init|runs_on.immutable=*|runs_on.squash_threads=*)
        [[ -z "${extra_arguments}" ]] && kernel_cmdline+="${kernel_cmdline:+ }${argument}"
        ;;
      *)
        kernel_cmdline+="${kernel_cmdline:+ }${argument}"
        ;;
    esac
  done
  [[ -z "${root_partuuid}" ]] || kernel_cmdline="root=PARTUUID=${root_partuuid}${kernel_cmdline:+ ${kernel_cmdline}}"
  if [[ -n "${extra_arguments}" ]]; then
    read -ra extra_kernel_arguments <<< "${extra_arguments}"
    for argument in "${extra_kernel_arguments[@]}"; do
      [[ "${argument}" != *[[:space:]]* ]] || fail "invalid whitespace in Direct UEFI extra argument"
      kernel_cmdline+="${kernel_cmdline:+ }${argument}"
    done
  fi
  kernel_cmdline+="${kernel_cmdline:+ }console=null quiet loglevel=3 systemd.show_status=false rd.systemd.show_status=false"
  printf '%s\n' "${kernel_cmdline}"
}

read_le16() {
  local path="$1"
  local offset="$2"
  local -a octets=()

  read -ra octets <<< "$(od -An -v -tu1 -j "${offset}" -N2 "${path}")"
  [[ "${#octets[@]}" -eq 2 ]] || fail "cannot read PE/COFF field at offset ${offset}: ${path}"
  printf '%u\n' "$((octets[0] | (octets[1] << 8)))"
}

read_le32() {
  local path="$1"
  local offset="$2"
  local -a octets=()

  read -ra octets <<< "$(od -An -v -tu1 -j "${offset}" -N4 "${path}")"
  [[ "${#octets[@]}" -eq 4 ]] || fail "cannot read PE/COFF field at offset ${offset}: ${path}"
  printf '%u\n' "$((octets[0] | (octets[1] << 8) | (octets[2] << 16) | (octets[3] << 24)))"
}

validate_pe_image() {
  local path="$1"
  local pe_offset image_size signature machine optional_magic subsystem

  [[ "$(od -An -tx1 -N2 "${path}" | tr -d '[:space:]')" == "4d5a" ]] || fail "kernel is missing the DOS MZ header: ${path}"
  pe_offset="$(read_le32 "${path}" 60)"
  image_size="$(stat -c '%s' "${path}")"
  [[ "${pe_offset}" -ge 64 && "$((pe_offset + 94))" -le "${image_size}" ]] || fail "kernel has an invalid PE header offset: ${path}"
  signature="$(od -An -tx1 -j "${pe_offset}" -N4 "${path}" | tr -d '[:space:]')"
  [[ "${signature}" == "50450000" ]] || fail "kernel is missing the PE signature: ${path}"

  machine="$(read_le16 "${path}" "$((pe_offset + 4))")"
  optional_magic="$(read_le16 "${path}" "$((pe_offset + 24))")"
  subsystem="$(read_le16 "${path}" "$((pe_offset + 92))")"
  [[ "${machine}" -eq 34404 ]] || fail "kernel PE architecture is not AMD64: ${path}" # IMAGE_FILE_MACHINE_AMD64 (0x8664)
  [[ "${optional_magic}" -eq 523 ]] || fail "kernel is not a PE32+ image: ${path}"
  [[ "${subsystem}" -eq 10 ]] || fail "kernel is not an EFI application: ${path}"
}

write_fallback_hashes() {
  local destination="$1"
  shift
  local -a directories=("$@")

  find "${directories[@]}" -maxdepth 1 -type f -print0 \
    | sort -z \
    | xargs -0 -r sha256sum > "${destination}"
  [[ -s "${destination}" ]] || fail "no fallback EFI files were hashed"
}

normalize_esp_hash_paths() {
  local source="$1"
  local destination="$2"
  local esp_mount="$3"

  sed "s#  ${esp_mount%/}/#  /boot/efi/#" "${source}" > "${destination}"
}

write_state() {
  local name="$1"
  local value="$2"
  local temporary="${state_dir}/.${name}.new"

  printf '%s\n' "${value}" > "${temporary}"
  chmod 0644 "${temporary}"
  mv -f "${temporary}" "${state_dir}/${name}"
}

main() {
  if [[ "${IMAGE_OS:-}" != "ubuntu26" ]]; then
    echo "[direct-uefi] keeping GRUB boot for ${IMAGE_OS:-unknown}"
    return 0
  fi

  local debian_arch
  debian_arch="$(dpkg --print-architecture)"
  if [[ "${debian_arch}" == "arm64" ]]; then
    # The gzip-wrapped arm64 kernel made direct firmware boot no faster than
    # GRUB in cold-start measurements. Keep the smaller GRUB boot path.
    echo "[direct-uefi] keeping GRUB boot for ubuntu26 arm64"
    return 0
  fi
  [[ "${debian_arch}" == "amd64" ]] || fail "unsupported Debian architecture: ${debian_arch}"

  # shellcheck source=/dev/null
  . /etc/os-release
  [[ "${VERSION_CODENAME:-}" == "resolute" ]] || fail "expected Ubuntu Resolute for ubuntu26"
  [[ -d /sys/firmware/efi/efivars ]] || fail "builder did not boot through UEFI"
  command -v efibootmgr >/dev/null || fail "efibootmgr is missing"

  local kernel_release kernel_path kernel_config kernel_magic kernel_boot_dir
  local esp_mount esp_source esp_parent esp_part esp_disk
  local fallback_loader='' loader
  local kernel_cmdline='' config_option direct_filename direct_path direct_loader
  local kernel_copy_size esp_available original_order fallback_bootnum direct_bootnum new_order
  local prepared_output prepared_next prepared_order direct_verbose direct_verbose_upper esp_partuuid
  local installed_direct_kernel installed_direct_count
  local -a fallback_loader_paths=()
  local -a fallback_directories=() kernel_arguments=()

  kernel_boot_dir="${DIRECT_UEFI_KERNEL_BOOT_DIR:-/boot}"
  kernel_release="$(select_latest_aws_kernel "${kernel_boot_dir}")"
  kernel_path="${kernel_boot_dir}/vmlinuz-${kernel_release}"
  kernel_config="${kernel_boot_dir}/config-${kernel_release}"
  [[ -f "${kernel_config}" ]] || fail "kernel config is missing: ${kernel_config}"
  grep -qx 'CONFIG_EFI_STUB=y' "${kernel_config}" || fail "linux-aws kernel lacks CONFIG_EFI_STUB=y"
  for config_option in \
    CONFIG_BLK_DEV_NVME \
    CONFIG_NVME_CORE \
    CONFIG_EXT4_FS \
    CONFIG_BLK_DEV_LOOP \
    CONFIG_SQUASHFS \
    CONFIG_SQUASHFS_ZSTD \
    CONFIG_SQUASHFS_CHOICE_DECOMP_BY_MOUNT; do
    grep -qx "${config_option}=y" "${kernel_config}" || fail "linux-aws kernel does not build ${config_option} into the image"
  done

  kernel_magic="$(od -An -tx1 -N2 "${kernel_path}" | tr -d '[:space:]')"
  [[ "${kernel_magic}" == "4d5a" ]] || fail "amd64 linux-aws kernel is not a raw PE/COFF EFI image"
  validate_pe_image "${kernel_path}"

  esp_mount="${DIRECT_UEFI_ESP_MOUNT:-$(findmnt -nro TARGET /boot/efi)}"
  [[ -n "${esp_mount}" && "$(findmnt -nro TARGET --target "${esp_mount}")" == "${esp_mount}" ]] || \
    fail "EFI system partition is not mounted at ${esp_mount:-<unset>}"
  if [[ -n "${DIRECT_UEFI_DISK:-}" || -n "${DIRECT_UEFI_ESP_PARTITION:-}" ]]; then
    [[ -b "${DIRECT_UEFI_DISK:-}" && "${DIRECT_UEFI_ESP_PARTITION:-}" =~ ^[0-9]+$ ]] || \
      fail "target EFI disk and partition override must be supplied together"
    esp_disk="$(readlink -f "${DIRECT_UEFI_DISK}")"
    esp_part="${DIRECT_UEFI_ESP_PARTITION}"
    esp_source="$(readlink -f "$(findmnt -nro SOURCE --target "${esp_mount}")")"
    esp_parent="$(lsblk -nro PKNAME "${esp_source}" | awk '!found { print; found = 1 }')"
    [[ -n "${esp_parent}" ]] || fail "cannot resolve target ESP parent disk"
    [[ "$(readlink -f "/dev/${esp_parent}")" == "${esp_disk}" ]] || \
      fail "mounted target ESP does not belong to ${esp_disk}"
    [[ "$(lsblk -nro PARTN "${esp_source}" | awk '!found { print; found = 1 }')" == "${esp_part}" ]] || \
      fail "mounted target ESP is not partition ${esp_part}"
  else
    esp_source="$(readlink -f "$(findmnt -nro SOURCE --target "${esp_mount}")")"
    # Consume all lsblk output. Exiting after the first line can turn a valid
    # pipeline into status 141 under pipefail.
    esp_parent="$(lsblk -nro PKNAME "${esp_source}" | awk '!found { print; found = 1 }')"
    esp_part="$(lsblk -nro PARTN "${esp_source}" | awk '!found { print; found = 1 }')"
    [[ -n "${esp_parent}" && "${esp_part}" =~ ^[0-9]+$ ]] || fail "cannot resolve ESP disk and partition"
    esp_disk="/dev/${esp_parent}"
  fi

  fallback_loader_paths=(
    "${esp_mount}/EFI/ubuntu/shimx64.efi"
    "${esp_mount}/EFI/ubuntu/grubx64.efi"
    "${esp_mount}/EFI/BOOT/BOOTX64.EFI"
  )

  for loader in "${fallback_loader_paths[@]}"; do
    if [[ -f "${loader}" ]]; then
      fallback_loader="\\${loader#"${esp_mount%/}/"}"
      fallback_loader="${fallback_loader//\//\\}"
      break
    fi
  done
  [[ -n "${fallback_loader}" ]] || fail "no existing GRUB or shim EFI loader found"

  read -ra kernel_arguments < /proc/cmdline
  kernel_cmdline="$(compose_direct_cmdline "${kernel_arguments[@]}")"
  validate_direct_cmdline "${kernel_cmdline}"
  if [[ -n "${DIRECT_UEFI_ROOT_PARTUUID:-}" ]]; then
    [[ " ${kernel_cmdline} " == *" root=PARTUUID=${DIRECT_UEFI_ROOT_PARTUUID} "* ]] || \
      fail "direct kernel command line does not use the requested target root PARTUUID"
  fi

  install -d -m 0755 "${esp_mount}/EFI/runs-on" "${state_dir}"
  for loader in "${esp_mount}/EFI/ubuntu" "${esp_mount}/EFI/BOOT"; do
    [[ ! -d "${loader}" ]] || fallback_directories+=("${loader}")
  done
  [[ "${#fallback_directories[@]}" -gt 0 ]] || fail "no fallback EFI directory found"
  fallback_hashes_before="$(mktemp /tmp/runs-on-fallback-before.XXXXXX)"
  fallback_hashes_after="$(mktemp /tmp/runs-on-fallback-after.XXXXXX)"
  write_fallback_hashes "${fallback_hashes_before}" "${fallback_directories[@]}"

  delete_boot_entries_for_label "${label_direct}"
  delete_boot_entries_for_label "${label_fallback}"
  find "${esp_mount}/EFI/runs-on" -maxdepth 1 -type f -name 'vmlinuz*.efi*' -delete

  direct_filename="vmlinuz.efi"
  direct_path="${esp_mount}/EFI/runs-on/${direct_filename}"
  direct_loader="\\EFI\\runs-on\\${direct_filename}"
  kernel_copy_size="$(stat -c '%s' "${kernel_path}")"
  esp_available="$(df -B1 --output=avail "${esp_mount}" | awk 'NR > 1 && !found { gsub(/[[:space:]]/, ""); print; found = 1 }')"
  [[ "${esp_available}" =~ ^[0-9]+$ && "${esp_available}" -ge "${kernel_copy_size}" ]] || fail "EFI system partition is too small for the direct kernel"
  install -m 0644 "${kernel_path}" "${direct_path}.new"
  mv -f "${direct_path}.new" "${direct_path}"

  efibootmgr -v > "${state_dir}/efibootmgr.before"
  original_order="$(awk -F': ' '/^BootOrder:/ && !found { print toupper($2); found = 1 }' "${state_dir}/efibootmgr.before")"
  [[ -n "${original_order}" ]] || fail "firmware has no BootOrder"

  efibootmgr --create \
    --disk "${esp_disk}" \
    --part "${esp_part}" \
    --label "${label_fallback}" \
    --loader "${fallback_loader}"
  fallback_bootnum="$(unique_bootnum_for_label "${label_fallback}")"

  efibootmgr --create \
    --disk "${esp_disk}" \
    --part "${esp_part}" \
    --label "${label_direct}" \
    --loader "${direct_loader}" \
    --unicode "${kernel_cmdline}"
  direct_bootnum="$(unique_bootnum_for_label "${label_direct}")"

  [[ "${direct_bootnum}" != "${fallback_bootnum}" ]] || fail "direct and fallback entries share a boot number"
  new_order="$(compose_boot_order "${fallback_bootnum}" "${direct_bootnum}" "${original_order}")"
  efibootmgr --bootorder "${new_order}"
  efibootmgr --bootnext "${direct_bootnum}"

  efibootmgr -v > "${state_dir}/efibootmgr.prepared"
  prepared_output="$(< "${state_dir}/efibootmgr.prepared")"
  prepared_next="$(awk -F': ' '/^BootNext:/ && !found { print toupper($2); found = 1 }' <<< "${prepared_output}")"
  prepared_order="$(awk -F': ' '/^BootOrder:/ && !found { print toupper($2); found = 1 }' <<< "${prepared_output}")"
  direct_verbose="$(awk -v boot="${direct_bootnum}" '$0 ~ "^Boot" boot "[* ]" && !found { print; found = 1 }' <<< "${prepared_output}")"
  direct_verbose_upper="$(tr '[:lower:]' '[:upper:]' <<< "${direct_verbose}")"
  esp_partuuid="$(blkid -s PARTUUID -o value "${esp_source}")"
  [[ "${direct_verbose}" == *'HD('* ]] || fail "direct entry does not use a portable HD() device path"
  [[ "${direct_verbose}" != *'NVMe('* ]] || fail "direct entry contains an instance-specific NVMe device path"
  [[ "${direct_verbose_upper}" == *"GPT,${esp_partuuid^^},"* ]] || \
    fail "direct entry HD() path does not use the mounted target ESP PARTUUID"
  [[ "${prepared_next}" == "${direct_bootnum}" ]] || fail "direct entry was not armed through BootNext"
  [[ "${prepared_order}" == "${new_order}" ]] || fail "firmware BootOrder differs from the requested order"
  [[ "${prepared_order%%,*}" == "${fallback_bootnum}" ]] || fail "GRUB fallback is not first in BootOrder"
  [[ "${prepared_order##*,}" == "${direct_bootnum}" ]] || fail "direct entry is not last in BootOrder"

  installed_direct_kernel="$(find "${esp_mount}/EFI/runs-on" -maxdepth 1 -type f -name 'vmlinuz.efi' -print)"
  installed_direct_count="$(awk 'NF { count++ } END { print count + 0 }' <<< "${installed_direct_kernel}")"
  [[ "${installed_direct_count}" -eq 1 ]] || fail "EFI system partition does not contain exactly one direct kernel"
  cmp -s "${kernel_path}" "${installed_direct_kernel}" || fail "direct kernel copy differs from the selected linux-aws kernel"
  sha256sum "${installed_direct_kernel}" > "${state_dir}/direct-kernel.sha256.actual"
  normalize_esp_hash_paths \
    "${state_dir}/direct-kernel.sha256.actual" \
    "${state_dir}/direct-kernel.sha256" \
    "${esp_mount}"
  rm -f "${state_dir}/direct-kernel.sha256.actual"

  write_fallback_hashes "${fallback_hashes_after}" "${fallback_directories[@]}"
  cmp -s "${fallback_hashes_before}" "${fallback_hashes_after}" || fail "fallback EFI files changed during direct boot preparation"
  normalize_esp_hash_paths "${fallback_hashes_after}" "${state_dir}/fallback.sha256" "${esp_mount}"

  write_state expected-boot-current "${direct_bootnum}"
  write_state fallback-bootnum "${fallback_bootnum}"
  write_state expected-boot-order "${prepared_order}"
  write_state expected-cmdline "${kernel_cmdline}"
  write_state kernel-release "${kernel_release}"
  write_state debian-architecture "${debian_arch}"
  write_state kernel-source-format raw

  sync
  cleanup
  trap - EXIT
  echo "[direct-uefi] armed Boot${direct_bootnum} once through BootNext; Boot${fallback_bootnum} remains first in BootOrder"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
