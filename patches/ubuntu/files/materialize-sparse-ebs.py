#!/usr/bin/env python3

"""Materialize every allocated sparse extent into verified EBS-sized blocks."""

from __future__ import annotations

import argparse
import errno
import fcntl
import hashlib
import json
import os
import stat
import struct
import tempfile
from pathlib import Path


EBS_BLOCK_SIZE = 512 * 1024
BLKGETSIZE64 = 0x80081272


def fail(message: str) -> None:
    raise SystemExit(f"[compact-extent-copy] {message}")


def allocated_ranges(source_fd: int, size: int) -> list[tuple[int, int]]:
    """Return merged EBS-block-aligned ranges backed by real file extents."""
    ranges: list[tuple[int, int]] = []
    position = 0

    while position < size:
        try:
            data_start = os.lseek(source_fd, position, os.SEEK_DATA)
        except OSError as error:
            if error.errno == errno.ENXIO:
                break
            raise

        data_end = os.lseek(source_fd, data_start, os.SEEK_HOLE)
        if data_end <= data_start:
            fail(f"invalid allocated extent {data_start}..{data_end}")
        aligned_start = data_start // EBS_BLOCK_SIZE * EBS_BLOCK_SIZE
        aligned_end = min(
            ((data_end + EBS_BLOCK_SIZE - 1) // EBS_BLOCK_SIZE) * EBS_BLOCK_SIZE,
            size,
        )

        if ranges and aligned_start <= ranges[-1][1]:
            ranges[-1] = (ranges[-1][0], max(ranges[-1][1], aligned_end))
        else:
            ranges.append((aligned_start, aligned_end))
        position = data_end

    return ranges


def block_indices(ranges: list[tuple[int, int]]) -> list[int]:
    indices: list[int] = []
    previous = -1
    for start, end in ranges:
        if start % EBS_BLOCK_SIZE or end % EBS_BLOCK_SIZE or end <= start:
            fail(f"unaligned materialization range {start}..{end}")
        for offset in range(start, end, EBS_BLOCK_SIZE):
            index = offset // EBS_BLOCK_SIZE
            if index <= previous:
                fail(f"duplicate or unordered EBS block {index}")
            indices.append(index)
            previous = index
    return indices


def pwrite_all(target_fd: int, data: bytes, offset: int) -> None:
    written = 0
    while written < len(data):
        count = os.pwrite(target_fd, data[written:], offset + written)
        if count == 0:
            fail(f"short write at byte {offset + written}")
        written += count


def read_block(file_descriptor: int, index: int) -> bytes:
    offset = index * EBS_BLOCK_SIZE
    data = os.pread(file_descriptor, EBS_BLOCK_SIZE, offset)
    if len(data) != EBS_BLOCK_SIZE:
        fail(f"short read at EBS block {index}: {len(data)} bytes")
    return data


def block_device_size(target_fd: int) -> int:
    encoded = fcntl.ioctl(target_fd, BLKGETSIZE64, struct.pack("Q", 0))
    return struct.unpack("Q", encoded)[0]


def write_manifest(path: Path, manifest: dict[str, object]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    file_descriptor, temporary_name = tempfile.mkstemp(
        dir=path.parent, prefix=f".{path.name}.", suffix=".tmp"
    )
    try:
        with os.fdopen(file_descriptor, "w", encoding="utf-8") as output:
            json.dump(manifest, output, indent=2, sort_keys=True)
            output.write("\n")
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary_name, path)
    finally:
        try:
            os.unlink(temporary_name)
        except FileNotFoundError:
            pass


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=Path)
    parser.add_argument("target", type=Path)
    parser.add_argument("--manifest", required=True, type=Path)
    parser.add_argument("--expected-block-count", type=int)
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    source_stat = args.source.stat()
    if not stat.S_ISREG(source_stat.st_mode):
        fail(f"source is not a regular sparse image: {args.source}")
    source_size = source_stat.st_size
    if source_size == 0 or source_size % EBS_BLOCK_SIZE:
        fail(f"source size {source_size} is not a positive 512 KiB multiple")
    if source_stat.st_blocks * 512 >= source_size:
        fail("source raw image is not sparse")

    source_fd = os.open(args.source, os.O_RDONLY | os.O_CLOEXEC)
    target_fd = os.open(args.target, os.O_RDWR | os.O_CLOEXEC)
    copied_hashes: list[dict[str, object]] = []
    verified_count = 0
    try:
        target_stat = os.fstat(target_fd)
        if not stat.S_ISBLK(target_stat.st_mode):
            fail(f"target is not a block device: {args.target}")
        target_size = block_device_size(target_fd)
        if target_size != source_size:
            fail(f"target size {target_size} differs from source size {source_size}")

        ranges = allocated_ranges(source_fd, source_size)
        indices = block_indices(ranges)
        total_blocks = source_size // EBS_BLOCK_SIZE
        if not indices:
            fail("source has no allocated EBS blocks")
        if len(indices) >= total_blocks:
            fail("source has no holes at EBS-block granularity")
        if args.expected_block_count is not None and len(indices) != args.expected_block_count:
            fail(
                f"allocated block count {len(indices)} differs from expected "
                f"{args.expected_block_count}"
            )

        # Copy exactly the blocks which intersect SEEK_DATA extents. This keeps
        # allocated all-zero filesystem metadata; content is never used to
        # decide whether a block can be omitted.
        for index in indices:
            source_data = read_block(source_fd, index)
            pwrite_all(target_fd, source_data, index * EBS_BLOCK_SIZE)
            copied_hashes.append(
                {"index": index, "sha256": hashlib.sha256(source_data).hexdigest()}
            )
        os.fsync(target_fd)

        for block in copied_hashes:
            index = int(block["index"])
            target_hash = hashlib.sha256(read_block(target_fd, index)).hexdigest()
            if target_hash != block["sha256"]:
                fail(f"verification hash differs at EBS block {index}")
            verified_count += 1
    finally:
        os.close(target_fd)
        os.close(source_fd)

    if verified_count != len(copied_hashes):
        fail(f"verified {verified_count} of {len(copied_hashes)} copied blocks")

    manifest: dict[str, object] = {
        "version": 1,
        "block_size": EBS_BLOCK_SIZE,
        "source_size": source_size,
        "total_block_count": source_size // EBS_BLOCK_SIZE,
        "copied_block_count": len(copied_hashes),
        "verified_block_count": verified_count,
        "copied_blocks": copied_hashes,
    }
    write_manifest(args.manifest, manifest)
    copied_bytes = len(copied_hashes) * EBS_BLOCK_SIZE
    print(
        "[compact-extent-copy] "
        f"copied_blocks={len(copied_hashes)}/{source_size // EBS_BLOCK_SIZE} "
        f"verified_blocks={verified_count}/{source_size // EBS_BLOCK_SIZE} "
        f"copied_bytes={copied_bytes} skipped_hole_bytes={source_size - copied_bytes} "
        f"manifest={args.manifest}"
    )


if __name__ == "__main__":
    main()
