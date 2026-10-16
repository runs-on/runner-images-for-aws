#!/usr/bin/env bash

set -euo pipefail

rootfs_compaction_log() {
  echo "[rootfs-compaction] $*"
}

scrub_rootfs_mount_for_image() {
  local mount_dir="$1"

  truncate -s 0 "$mount_dir/etc/machine-id"
  rm -f "$mount_dir/var/lib/dbus/machine-id"
  rm -f "$mount_dir"/etc/ssh/ssh_host_*
  rm -rf "$mount_dir"/var/log/*
  rm -rf "$mount_dir"/var/cache/apt/*
  rm -rf "$mount_dir"/var/lib/apt/lists/*
  rm -rf "$mount_dir"/var/cache/debconf/*.dat-old "$mount_dir"/var/cache/debconf/*.dat
  find "$mount_dir/var/tmp" -mindepth 1 -delete
  find "$mount_dir/tmp" -mindepth 1 -delete
}

trim_rootfs_mount() {
  local mount_dir="$1"
  local trim_output=""

  sync
  if trim_output="$(fstrim -v "$mount_dir" 2>&1)"; then
    rootfs_compaction_log "$trim_output"
  else
    if [[ "$trim_output" == *"discard operation is not supported"* ]] || [[ "$trim_output" == *"operation is not supported"* ]]; then
      rootfs_compaction_log "fstrim unsupported for ${mount_dir}: ${trim_output}"
      sync
      return 0
    fi
    rootfs_compaction_log "fstrim failed for ${mount_dir}: ${trim_output}"
    return 1
  fi
  sync
}

compact_sparse_image() {
  local sparse_image="$1"
  local sparse_usage_bytes=""
  local sparse_apparent_bytes=""

  fallocate -d "$sparse_image" || true
  sparse_usage_bytes="$(du -B1 "$sparse_image" | awk '{print $1}')"
  sparse_apparent_bytes="$(du -B1 --apparent-size "$sparse_image" | awk '{print $1}')"

  if [[ -n "$sparse_usage_bytes" && -n "$sparse_apparent_bytes" ]]; then
    rootfs_compaction_log "sparse image bytes used=${sparse_usage_bytes} apparent=${sparse_apparent_bytes}"
  fi
}

detach_loop_disk() {
  local loop_disk="$1"

  if [[ -n "$loop_disk" ]]; then
    losetup -d "$loop_disk"
  fi
}

# Blocks of a new EBS volume that were never written do not read as zeros,
# so the sparse copy below leaves random bytes wherever it skips an all-zero
# chunk. Writing every block instead puts the whole image in the snapshot and
# slows boots by seconds. So rewrite only what each partition uses: on ext4,
# e2image compares the blocks the filesystem uses and writes those that
# differ. Other partitions (EFI, BIOS boot) and the space around them are
# small and copied whole.
copy_image_range() {
  local sparse_image="$1"
  local target_disk="$2"
  local offset="$3"
  local length="$4"

  [[ "${length}" -gt 0 ]] || return 0
  dd if="${sparse_image}" of="${target_disk}" bs=1M \
    iflag=skip_bytes,count_bytes oflag=seek_bytes conv=notrunc,fsync status=none \
    skip="${offset}" seek="${offset}" count="${length}"
  blockdev --flushbufs "${target_disk}"
  cmp -n "${length}" -i "${offset}:${offset}" "${sparse_image}" "${target_disk}"
}

repair_sparse_copy() {
  local sparse_image="$1"
  local target_disk="$2"
  local image_size first_start="" last_end=0 start size offset fstype pending

  image_size="$(stat -c %s "${sparse_image}")"
  while read -r start size; do
    offset=$((start * 512))
    [[ -n "${first_start}" && "${first_start}" -le "${offset}" ]] || first_start="${offset}"
    [[ "$((offset + size * 512))" -le "${last_end}" ]] || last_end=$((offset + size * 512))
    fstype="$(blkid -p -O "${offset}" -s TYPE -o value "${sparse_image}" || true)"
    if [[ "${fstype}" == "ext4" ]]; then
      e2image -rac -o "${offset}" -O "${offset}" "${sparse_image}" "${target_disk}"
      blockdev --flushbufs "${target_disk}"
      # Block -1 is e2image marking the end of the filesystem, not a block.
      pending="$(e2image -racn -o "${offset}" -O "${offset}" "${sparse_image}" "${target_disk}" 2>&1 |
        grep '^Writing block' | grep -c -v ' 18446744073709551615$' || true)"
      [[ "${pending}" == "0" ]] || { echo "ext4 partition at ${offset} still differs in ${pending} blocks" >&2; exit 1; }
      rootfs_compaction_log "repaired ext4 partition at ${offset}"
    else
      copy_image_range "${sparse_image}" "${target_disk}" "${offset}" "$((size * 512))"
      rootfs_compaction_log "copied ${fstype:-unformatted} partition at ${offset} whole"
    fi
  done < <(sfdisk -d "${sparse_image}" | awk -F'[=,]' '/ : start=/ { print $2 + 0, $4 + 0 }')
  [[ -n "${first_start}" ]] || { echo "No partitions found in ${sparse_image}" >&2; exit 1; }

  copy_image_range "${sparse_image}" "${target_disk}" 0 "${first_start}"
  copy_image_range "${sparse_image}" "${target_disk}" "${last_end}" "$((image_size - last_end))"
}

materialize_sparse_image() {
  local sparse_image="$1"
  local target_disk="$2"
  local ddpt_output=""
  local ddpt_summary=""

  wipefs -af "$target_disk"
  ddpt_output="$(ddpt if="$sparse_image" of="$target_disk" oflag=sparse 2>&1)"
  ddpt_summary="$(printf '%s\n' "$ddpt_output" | awk '/records in|records out|bypassed records out/ {print}' | paste -sd '; ' -)"
  if [[ -n "$ddpt_summary" ]]; then
    rootfs_compaction_log "$ddpt_summary"
  fi
  repair_sparse_copy "$sparse_image" "$target_disk"
  udevadm settle
  sync
}

finalize_sparse_rootfs_image() {
  local mount_dir="$1"
  local loop_disk="$2"
  local sparse_image="$3"
  local target_disk="$4"
  local pre_trim_handler=""
  local cleanup_handler=""

  if [[ $# -ge 6 ]]; then
    pre_trim_handler="${5:-}"
    cleanup_handler="${6:-}"
  else
    cleanup_handler="${5:-}"
  fi

  scrub_rootfs_mount_for_image "$mount_dir"

  if [[ -n "$pre_trim_handler" ]] && declare -F "$pre_trim_handler" >/dev/null 2>&1; then
    "$pre_trim_handler" "$mount_dir"
  fi

  trim_rootfs_mount "$mount_dir"

  if [[ -n "$cleanup_handler" ]] && declare -F "$cleanup_handler" >/dev/null 2>&1; then
    "$cleanup_handler" "$mount_dir"
  fi

  detach_loop_disk "$loop_disk"
  compact_sparse_image "$sparse_image"
  materialize_sparse_image "$sparse_image" "$target_disk"
}
