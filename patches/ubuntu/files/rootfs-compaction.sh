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
  udevadm settle
  sync
}

finalize_sparse_rootfs_image() {
  local mount_dir="$1"
  local loop_disk="$2"
  local sparse_image="$3"
  local target_disk="$4"
  local cleanup_handler="${5:-}"

  scrub_rootfs_mount_for_image "$mount_dir"
  trim_rootfs_mount "$mount_dir"

  if [[ -n "$cleanup_handler" ]] && declare -F "$cleanup_handler" >/dev/null 2>&1; then
    "$cleanup_handler" "$mount_dir"
  fi

  detach_loop_disk "$loop_disk"
  compact_sparse_image "$sparse_image"
  materialize_sparse_image "$sparse_image" "$target_disk"
}
