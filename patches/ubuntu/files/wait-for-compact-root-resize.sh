#!/usr/bin/env bash

set -euo pipefail
export LC_ALL=C

if [[ "${IMAGE_OS:-}" != ubuntu26 ]]; then
  exit 0
fi

expected_gib="${EXPECTED_BUILDER_VOLUME_SIZE_GB:-}"
[[ "${expected_gib}" =~ ^[1-9][0-9]*$ ]] || {
  echo "EXPECTED_BUILDER_VOLUME_SIZE_GB must be a positive integer" >&2
  exit 1
}
expected_bytes=$((expected_gib * 1024 * 1024 * 1024))

marker=/etc/runs-on-overlay/backing-root-mount
[[ -f "${marker}" && ! -L "${marker}" ]] || {
  echo "Ubuntu 26 compact descendant lacks the backing-root marker" >&2
  exit 1
}
mapfile -t marker_lines < "${marker}"
[[ "${#marker_lines[@]}" -eq 1 ]] || {
  echo "Backing-root marker must contain exactly one line" >&2
  exit 1
}
backing_mount="${marker_lines[0]}"
[[ "${backing_mount}" =~ ^/[A-Za-z0-9._/-]+$ && "${backing_mount}" != / ]] || {
  echo "Backing-root marker is not a safe absolute path" >&2
  exit 1
}
[[ "$(readlink -m "${backing_mount}")" == "${backing_mount}" ]] || {
  echo "Backing-root marker is not canonical" >&2
  exit 1
}
[[ "$(findmnt -nro TARGET --target "${backing_mount}")" == "${backing_mount}" ]] || {
  echo "Backing-root marker is not an exact mount" >&2
  exit 1
}

partition="$(readlink -f "$(findmnt -nro SOURCE --target "${backing_mount}")")"
fstype="$(findmnt -nro FSTYPE --target "${backing_mount}")"
parent="$(lsblk -nro PKNAME "${partition}" | awk '!seen {print; seen=1}')"
part_number="$(lsblk -nro PARTN "${partition}" | awk '!seen {print; seen=1}')"
[[ -b "${partition}" && "${fstype}" == ext4 && -n "${parent}" && "${part_number}" == 1 ]] || {
  echo "Backing root is not ext4 partition 1" >&2
  exit 1
}
disk="$(readlink -f "/dev/${parent}")"
[[ "$(blockdev --getsize64 "${disk}")" -eq "${expected_bytes}" ]] || {
  echo "Builder disk size differs from ${expected_gib} GiB" >&2
  exit 1
}

deadline=$((SECONDS + 600))
while (( SECONDS < deadline )); do
  part_bytes="$(blockdev --getsize64 "${partition}")"
  block_count="$(tune2fs -l "${partition}" 2>/dev/null | awk -F: '/^Block count:/ {gsub(/[[:space:]]/, "", $2); print $2; exit}')"
  block_size="$(tune2fs -l "${partition}" 2>/dev/null | awk -F: '/^Block size:/ {gsub(/[[:space:]]/, "", $2); print $2; exit}')"
  if [[ "${part_bytes}" =~ ^[0-9]+$ && "${block_count}" =~ ^[0-9]+$ && "${block_size}" =~ ^[0-9]+$ ]]; then
    fs_bytes=$((block_count * block_size))
    trailing_gap=$((expected_bytes - part_bytes))
    filesystem_gap=$((part_bytes - fs_bytes))
    # p13/p14/p15 occupy the fixed prefix before p1. A grown p1 ends near the
    # disk boundary, and resize2fs leaves less than 16 MiB unused in p1.
    if (( trailing_gap >= 0 && trailing_gap < 2 * 1024 * 1024 * 1024 && filesystem_gap >= 0 && filesystem_gap < 16 * 1024 * 1024 )); then
      printf '[compact-resize] disk=%s partition=%s disk_bytes=%s part_bytes=%s fs_bytes=%s\n' \
        "${disk}" "${partition}" "${expected_bytes}" "${part_bytes}" "${fs_bytes}"
      exit 0
    fi
  fi
  sleep 2
done

echo "Compact backing root did not reach ${expected_gib} GiB builder geometry within 600 seconds" >&2
exit 1
