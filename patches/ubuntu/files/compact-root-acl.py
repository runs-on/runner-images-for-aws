#!/usr/bin/env python3

"""Capture and restore extended directory ACLs without following symlinks."""

from __future__ import annotations

import argparse
import json
import os
import re
import stat
import subprocess
from pathlib import Path
from typing import Iterable


BATCH_PATH_LIMIT = 512
BATCH_BYTE_LIMIT = 64 * 1024
OCTAL_ESCAPE = re.compile(r"\\([0-7]{3})")


def excluded(relative: str, exclusions: tuple[str, ...]) -> bool:
    return any(relative == item or relative.startswith(f"{item}/") for item in exclusions)


def walk_candidates(
    root: Path, exclusions: tuple[str, ...]
) -> list[tuple[str, Path, os.stat_result]]:
    root_stat = root.lstat()
    root_device = root_stat.st_dev
    candidates: list[tuple[str, Path, os.stat_result]] = [(".", root, root_stat)]

    def visit(directory: Path, relative_directory: str) -> None:
        with os.scandir(directory) as iterator:
            children = sorted(iterator, key=lambda item: os.fsencode(item.name))
        for child in children:
            relative = f"{relative_directory}/{child.name}" if relative_directory else child.name
            if excluded(relative, exclusions):
                continue
            path = Path(child.path)
            file_stat = child.stat(follow_symlinks=False)
            if file_stat.st_dev != root_device:
                continue
            candidates.append((relative, path, file_stat))
            if stat.S_ISDIR(file_stat.st_mode):
                visit(path, relative)

    visit(root, "")
    return candidates


def batches(paths: Iterable[Path]) -> Iterable[list[Path]]:
    batch: list[Path] = []
    byte_count = 0
    for path in paths:
        path_bytes = len(os.fsencode(path)) + 1
        if batch and (
            len(batch) >= BATCH_PATH_LIMIT or byte_count + path_bytes > BATCH_BYTE_LIMIT
        ):
            yield batch
            batch = []
            byte_count = 0
        batch.append(path)
        byte_count += path_bytes
    if batch:
        yield batch


def decode_getfacl_path(value: str) -> str:
    return OCTAL_ESCAPE.sub(lambda match: chr(int(match.group(1), 8)), value).replace(
        r"\\", "\\"
    )


def encode_getfacl_path(value: str) -> str:
    encoded: list[str] = []
    for character in value:
        codepoint = ord(character)
        if character == "\\":
            encoded.append(r"\\")
        elif codepoint < 32 or codepoint == 127:
            encoded.append(f"\\{codepoint:03o}")
        else:
            encoded.append(character)
    return "".join(encoded)


def parse_getfacl_output(output: str) -> dict[str, str]:
    parsed: dict[str, str] = {}
    for raw_block in output.split("\n\n"):
        lines = [line for line in raw_block.splitlines() if line]
        if not lines:
            continue
        file_headers = [line for line in lines if line.startswith("# file: ")]
        if len(file_headers) != 1:
            raise SystemExit("[compact-acl] getfacl block has no unique file header")
        path = decode_getfacl_path(file_headers[0].removeprefix("# file: "))
        acl_lines = [line for line in lines if not line.startswith("#")]
        if not acl_lines:
            raise SystemExit(f"[compact-acl] getfacl emitted an empty ACL block: {path}")
        if path in parsed:
            raise SystemExit(f"[compact-acl] getfacl emitted a duplicate path: {path}")
        parsed[path] = "\n".join(acl_lines) + "\n"
    return parsed


def query_acl_batches(paths: list[Path]) -> dict[str, str]:
    found: dict[str, str] = {}
    for batch in batches(paths):
        result = subprocess.run(
            [
                "getfacl",
                "--absolute-names",
                "--numeric",
                "--skip-base",
                "--physical",
                "--",
                *(str(path) for path in batch),
            ],
            check=True,
            stdout=subprocess.PIPE,
            text=True,
        )
        for path, acl in parse_getfacl_output(result.stdout).items():
            if path in found:
                raise SystemExit(f"[compact-acl] duplicate ACL path across batches: {path}")
            found[path] = acl
    return found


def capture(root: Path, exclusions: tuple[str, ...]) -> dict[str, object]:
    candidates = walk_candidates(root, exclusions)
    by_absolute_path = {str(path): (relative, file_stat) for relative, path, file_stat in candidates}
    acl_by_path = query_acl_batches([path for _relative, path, _file_stat in candidates])
    entries: list[dict[str, object]] = []
    for absolute_path in sorted(acl_by_path, key=os.fsencode):
        if absolute_path not in by_absolute_path:
            raise SystemExit(f"[compact-acl] getfacl returned an unrequested path: {absolute_path}")
        relative, file_stat = by_absolute_path[absolute_path]
        if not stat.S_ISDIR(file_stat.st_mode):
            raise SystemExit(
                f"[compact-acl] unsupported ACL-bearing non-directory: {relative}"
            )
        entries.append(
            {
                "path": relative,
                "mode": stat.S_IMODE(file_stat.st_mode),
                "uid": file_stat.st_uid,
                "gid": file_stat.st_gid,
                "getfacl": acl_by_path[absolute_path],
            }
        )
    entries.sort(key=lambda entry: os.fsencode(str(entry["path"])))
    return {"version": 1, "acl_directory_count": len(entries), "entries": entries}


def restore(source_root: Path, merged_root: Path, manifest: dict[str, object]) -> None:
    if manifest.get("version") != 1 or not isinstance(manifest.get("entries"), list):
        raise SystemExit("[compact-acl] unsupported ACL manifest")
    restore_blocks: list[str] = []
    for entry in manifest["entries"]:
        if not isinstance(entry, dict):
            raise SystemExit("[compact-acl] invalid ACL manifest entry")
        relative = str(entry["path"])
        source = source_root if relative == "." else source_root / relative
        destination = merged_root if relative == "." else merged_root / relative
        source_stat = source.lstat()
        destination_stat = destination.lstat()
        if not stat.S_ISDIR(source_stat.st_mode) or not stat.S_ISDIR(destination_stat.st_mode):
            raise SystemExit(f"[compact-acl] ACL path is not a directory in both trees: {relative}")
        if (
            stat.S_IMODE(source_stat.st_mode) != int(entry["mode"])
            or source_stat.st_uid != int(entry["uid"])
            or source_stat.st_gid != int(entry["gid"])
        ):
            raise SystemExit(f"[compact-acl] source metadata changed after capture: {relative}")
        restore_blocks.append(
            "\n".join(
                [
                    f"# file: {encode_getfacl_path(str(destination))}",
                    f"# owner: {entry['uid']}",
                    f"# group: {entry['gid']}",
                    str(entry["getfacl"]).rstrip("\n"),
                    "",
                ]
            )
        )
    if restore_blocks:
        subprocess.run(
            ["setfacl", "--restore=-"],
            check=True,
            input="\n".join(restore_blocks),
            text=True,
        )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)
    capture_parser = subparsers.add_parser("capture")
    capture_parser.add_argument("root", type=Path)
    capture_parser.add_argument("output", type=Path)
    capture_parser.add_argument("--exclude", action="append", default=[])
    restore_parser = subparsers.add_parser("restore")
    restore_parser.add_argument("source_root", type=Path)
    restore_parser.add_argument("merged_root", type=Path)
    restore_parser.add_argument("manifest", type=Path)
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    if args.command == "capture":
        exclusions = tuple(sorted({item.strip("/") for item in args.exclude if item.strip("/")}))
        manifest = capture(args.root.resolve(), exclusions)
        args.output.write_text(
            json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8"
        )
        print(f"[compact-acl] captured_directories={manifest['acl_directory_count']}")
    else:
        manifest = json.loads(args.manifest.read_text(encoding="utf-8"))
        restore(args.source_root.resolve(), args.merged_root.resolve(), manifest)
        print(f"[compact-acl] restored_directories={manifest['acl_directory_count']}")


if __name__ == "__main__":
    main()
