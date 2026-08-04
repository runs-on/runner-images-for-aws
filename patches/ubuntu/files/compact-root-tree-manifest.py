#!/usr/bin/env python3

"""Write a deterministic content, metadata, xattr, and hardlink tree manifest."""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
import stat
from collections import defaultdict
from pathlib import Path


POSIX_ACL_XATTRS = {"system.posix_acl_access", "system.posix_acl_default"}


def digest_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb", buffering=0) as source:
        while chunk := source.read(2 * 1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def path_type(mode: int) -> str:
    if stat.S_ISDIR(mode):
        return "directory"
    if stat.S_ISREG(mode):
        return "file"
    if stat.S_ISLNK(mode):
        return "symlink"
    if stat.S_ISCHR(mode):
        return "character-device"
    if stat.S_ISBLK(mode):
        return "block-device"
    if stat.S_ISFIFO(mode):
        return "fifo"
    if stat.S_ISSOCK(mode):
        return "socket"
    raise RuntimeError(f"unsupported mode: {mode:o}")


def read_xattrs(path: Path, ignore_posix_acl: bool) -> dict[str, str]:
    attributes: dict[str, str] = {}
    if not hasattr(os, "listxattr"):
        return attributes
    for name in sorted(os.listxattr(path, follow_symlinks=False)):
        if ignore_posix_acl and name in POSIX_ACL_XATTRS:
            continue
        value = os.getxattr(path, name, follow_symlinks=False)
        attributes[name] = base64.b64encode(value).decode("ascii")
    return attributes


def excluded(relative: str, exclusions: tuple[str, ...]) -> bool:
    return any(relative == item or relative.startswith(f"{item}/") for item in exclusions)


def walk_paths(root: Path, exclusions: tuple[str, ...]) -> list[tuple[str, Path, os.stat_result]]:
    root_stat = root.lstat()
    root_device = root_stat.st_dev
    found: list[tuple[str, Path, os.stat_result]] = [(".", root, root_stat)]

    def visit(directory: Path, relative_directory: str) -> None:
        with os.scandir(directory) as iterator:
            entries = sorted(iterator, key=lambda item: os.fsencode(item.name))
        for entry in entries:
            relative = f"{relative_directory}/{entry.name}" if relative_directory else entry.name
            if excluded(relative, exclusions):
                continue
            path = Path(entry.path)
            file_stat = entry.stat(follow_symlinks=False)
            # SquashFS -one-file-system records a mountpoint directory but does
            # not traverse the mounted filesystem. Explicit exclusions cover
            # the mountpoints whose directory metadata is intentionally rebuilt.
            if file_stat.st_dev != root_device:
                continue
            found.append((relative, path, file_stat))
            if stat.S_ISDIR(file_stat.st_mode):
                visit(path, relative)

    visit(root, "")
    return found


def build_manifest(
    root: Path, exclusions: tuple[str, ...], ignore_posix_acl: bool
) -> dict[str, object]:
    paths = walk_paths(root, exclusions)
    inode_paths: dict[tuple[int, int], list[str]] = defaultdict(list)
    for relative, _path, file_stat in paths:
        if stat.S_ISREG(file_stat.st_mode):
            inode_paths[(file_stat.st_dev, file_stat.st_ino)].append(relative)
    hardlink_groups = {
        inode: sorted(linked_paths)
        for inode, linked_paths in inode_paths.items()
        if len(linked_paths) > 1
    }
    hardlink_names = {
        relative: linked_paths
        for inode, linked_paths in hardlink_groups.items()
        for relative in linked_paths
    }

    entries: list[dict[str, object]] = []
    capability_count = 0
    xattr_count = 0
    for relative, path, file_stat in paths:
        kind = path_type(file_stat.st_mode)
        attributes = read_xattrs(path, ignore_posix_acl)
        xattr_count += len(attributes)
        capability_count += int("security.capability" in attributes)
        entry: dict[str, object] = {
            "path": relative,
            "type": kind,
            "mode": stat.S_IMODE(file_stat.st_mode),
            "uid": file_stat.st_uid,
            "gid": file_stat.st_gid,
            "mtime": int(file_stat.st_mtime),
            "xattrs": attributes,
        }
        if kind == "file":
            entry["size"] = file_stat.st_size
            entry["sha256"] = digest_file(path)
            if relative in hardlink_names:
                entry["hardlinks"] = hardlink_names[relative]
        elif kind == "symlink":
            entry["target"] = os.readlink(path)
        elif kind in ("character-device", "block-device"):
            entry["rdev"] = file_stat.st_rdev
        entries.append(entry)

    return {
        "version": 1,
        "entry_count": len(entries),
        "xattr_count": xattr_count,
        "capability_count": capability_count,
        "hardlink_group_count": len(hardlink_groups),
        "entries": entries,
    }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("root", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--exclude", action="append", default=[])
    parser.add_argument("--ignore-posix-acl", action="store_true")
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    root = args.root.resolve()
    exclusions = tuple(sorted({item.strip("/") for item in args.exclude if item.strip("/")}))
    manifest = build_manifest(root, exclusions, args.ignore_posix_acl)
    args.output.write_text(
        json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    print(
        "[compact-tree-manifest] "
        f"root={root} entries={manifest['entry_count']} xattrs={manifest['xattr_count']} "
        f"capabilities={manifest['capability_count']} hardlink_groups={manifest['hardlink_group_count']}"
    )


if __name__ == "__main__":
    main()
