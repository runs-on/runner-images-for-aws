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
# slows boots by seconds, so record where file data lives while the image is
# still mounted, and rewrite only the file blocks the copy got wrong.
record_file_extents() {
  local mount_dir="$1"
  local loop_disk="$2"
  local extents_file="$3"

  python3 - "$mount_dir" "$(basename "$loop_disk")" "$extents_file" <<'PY'
import errno
import fcntl
import os
import stat
import struct
import sys

FS_IOC_FIEMAP = 0xC020660B
FIEMAP_FLAG_SYNC = 0x1
FIEMAP_EXTENT_LAST = 0x1
# Extents whose blocks do not hold the file's bytes as stored on disk.
SKIP_FLAGS = 0x2 | 0x4 | 0x8 | 0x80 | 0x100 | 0x200 | 0x800
HEADER = struct.Struct("=QQLLLL")
EXTENT = struct.Struct("=QQQQQLLLL")
BATCH = 512

root, loop_name, out_path = sys.argv[1:]
partitions = {}


def partition(dev):
    """Byte offset and size of a partition of the loop disk, or None."""
    if dev not in partitions:
        sys_path = os.path.realpath(f"/sys/dev/block/{os.major(dev)}:{os.minor(dev)}")
        found = None
        if f"/{loop_name}/" in sys_path and os.path.exists(f"{sys_path}/start"):
            with open(f"{sys_path}/start") as start, open(f"{sys_path}/size") as size:
                found = (int(start.read()) * 512, int(size.read()) * 512)
        partitions[dev] = found
    return partitions[dev]


def extents(fd):
    logical = 0
    while True:
        request = bytearray(HEADER.size + BATCH * EXTENT.size)
        HEADER.pack_into(request, 0, logical, (1 << 64) - 1 - logical, FIEMAP_FLAG_SYNC, 0, BATCH, 0)
        fcntl.ioctl(fd, FS_IOC_FIEMAP, request)
        mapped = HEADER.unpack_from(request, 0)[3]
        if mapped == 0:
            return
        for index in range(mapped):
            fe_logical, fe_physical, fe_length, _, _, fe_flags, _, _, _ = EXTENT.unpack_from(
                request, HEADER.size + index * EXTENT.size
            )
            if not fe_flags & SKIP_FLAGS:
                yield fe_physical, fe_length
            if fe_flags & FIEMAP_EXTENT_LAST:
                return
        logical = fe_logical + fe_length


count = 0
total = 0
seen = set()
whole = set()
with open(out_path, "w") as out:
    for directory, _, files in os.walk(root):
        for name in files:
            path = os.path.join(directory, name)
            try:
                info = os.lstat(path)
            except FileNotFoundError:
                continue
            if not stat.S_ISREG(info.st_mode) or info.st_size == 0:
                continue
            found = partition(info.st_dev)
            if found is None or info.st_dev in whole or (info.st_dev, info.st_ino) in seen:
                continue
            seen.add((info.st_dev, info.st_ino))
            start, size = found
            fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
            try:
                file_extents = list(extents(fd))
            except OSError as error:
                # vfat (the EFI partition) has no FIEMAP, and its FAT and
                # directories are mostly zeros too: check the whole partition.
                if error.errno != errno.EOPNOTSUPP:
                    raise
                whole.add(info.st_dev)
                file_extents = [(0, size)]
            finally:
                os.close(fd)
            for physical, length in file_extents:
                out.write(f"{start + physical} {length}\n")
                count += 1
                total += length

print(f"[rootfs-compaction] recorded {count} file extents ({total} bytes)")
PY
}

# Compare every recorded file extent between the image and the target disk.
# In repair mode, rewrite the 4 KiB blocks that differ; in verify mode, fail
# if any differ.
check_file_extents() {
  local mode="$1"
  local sparse_image="$2"
  local target_disk="$3"
  local extents_file="$4"

  python3 - "$mode" "$sparse_image" "$target_disk" "$extents_file" <<'PY'
import os
import sys

BLOCK = 4096
CHUNK = 1 << 20

mode, image_path, target_path, extents_path = sys.argv[1:]
image = os.open(image_path, os.O_RDONLY)
target = os.open(target_path, os.O_RDWR if mode == "repair" else os.O_RDONLY)
checked = 0
differing = 0

with open(extents_path) as extents:
    for line in extents:
        offset, length = map(int, line.split())
        end = offset + length
        while offset < end:
            size = min(CHUNK, end - offset)
            expected = os.pread(image, size, offset)
            actual = os.pread(target, size, offset)
            if expected != actual:
                for start in range(0, size, BLOCK):
                    block = expected[start:start + BLOCK]
                    if block != actual[start:start + BLOCK]:
                        differing += 1
                        if mode == "repair":
                            os.pwrite(target, block, offset + start)
            checked += size
            offset += size

if mode == "repair":
    os.fsync(target)
print(f"[rootfs-compaction] {mode}: {checked} bytes of file data checked, {differing} blocks differed")
if mode == "verify" and differing:
    sys.exit(1)
PY
}

materialize_sparse_image() {
  local sparse_image="$1"
  local target_disk="$2"
  local extents_file="$3"
  local ddpt_output=""
  local ddpt_summary=""

  wipefs -af "$target_disk"
  ddpt_output="$(ddpt if="$sparse_image" of="$target_disk" oflag=sparse 2>&1)"
  ddpt_summary="$(printf '%s\n' "$ddpt_output" | awk '/records in|records out|bypassed records out/ {print}' | paste -sd '; ' -)"
  if [[ -n "$ddpt_summary" ]]; then
    rootfs_compaction_log "$ddpt_summary"
  fi
  check_file_extents repair "$sparse_image" "$target_disk" "$extents_file"
  blockdev --flushbufs "$target_disk"
  check_file_extents verify "$sparse_image" "$target_disk" "$extents_file"
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
  record_file_extents "$mount_dir" "$loop_disk" "${sparse_image}.extents"

  if [[ -n "$cleanup_handler" ]] && declare -F "$cleanup_handler" >/dev/null 2>&1; then
    "$cleanup_handler" "$mount_dir"
  fi

  detach_loop_disk "$loop_disk"
  compact_sparse_image "$sparse_image"
  materialize_sparse_image "$sparse_image" "$target_disk" "${sparse_image}.extents"
}
