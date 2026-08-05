#!/usr/bin/env python3

"""Filter a measured SquashFS sort profile against the current merged root."""

from __future__ import annotations

import argparse
import json
import os
import re
import stat
from collections import deque
from pathlib import Path, PurePosixPath


KERNEL_MODULE_PATH = re.compile(r"\Ausr/lib/modules/[^/]+-aws(?=/)")
CAPTURED_KERNEL_RELEASE = re.compile(
    r"(?<![A-Za-z0-9])\d+(?:\.\d+)+(?:-\d+)+-aws"
)
MAX_SYMLINKS = 40


def safe_parts(path: str, base: list[str] | None = None) -> list[str]:
    parts = list(base or [])
    for part in PurePosixPath(path).parts:
        if part in ("", "/", "."):
            continue
        if part == "..":
            if not parts:
                raise ValueError(f"path escapes root: {path}")
            parts.pop()
        else:
            parts.append(part)
    return parts


def resolve_in_root(root: Path, relative_path: str) -> tuple[Path, str]:
    """Resolve symlinks as though root were `/`, including absolute targets."""
    resolved: list[str] = []
    remaining = deque(safe_parts(relative_path))
    followed = 0

    while remaining:
        part = remaining.popleft()
        candidate = root.joinpath(*resolved, part)
        file_stat = candidate.lstat()
        if stat.S_ISLNK(file_stat.st_mode):
            followed += 1
            if followed > MAX_SYMLINKS:
                raise OSError(f"too many symlinks while resolving {relative_path}")
            target = os.readlink(candidate)
            target_parts = safe_parts(target, [] if target.startswith("/") else resolved)
            target_parts.extend(remaining)
            remaining = deque(target_parts)
            resolved = []
        else:
            resolved.append(part)

    normalized = "/".join(resolved)
    return root.joinpath(*resolved), normalized


def parse_profile(path: Path) -> list[tuple[str, int]]:
    entries: list[tuple[str, int]] = []
    for line_number, raw_line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        try:
            candidate, raw_weight = line.rsplit(maxsplit=1)
            weight = int(raw_weight)
            if not -32768 <= weight <= 32767:
                raise ValueError(f"weight outside mksquashfs range: {weight}")
        except (ValueError, TypeError) as error:
            raise SystemExit(f"{path}:{line_number}: invalid profile entry: {error}") from error
        entries.append((candidate.lstrip("/"), weight))
    return entries


def filter_profile(
    root: Path,
    entries: list[tuple[str, int]],
    kernel_release: str,
    exclusions: tuple[str, ...] = (),
    cross_filesystems: bool = False,
) -> tuple[list[tuple[str, int]], dict[str, int]]:
    filtered: list[tuple[str, int]] = []
    seen_inodes: set[tuple[int, int]] = set()
    report = {
        "input_count": len(entries),
        "output_count": 0,
        "missing_count": 0,
        "non_regular_count": 0,
        "duplicate_inode_count": 0,
        "unsafe_count": 0,
        "excluded_count": 0,
    }
    root_device = root.stat().st_dev

    for candidate, weight in entries:
        candidate = KERNEL_MODULE_PATH.sub(
            f"usr/lib/modules/{kernel_release}", candidate
        )
        candidate = CAPTURED_KERNEL_RELEASE.sub(kernel_release, candidate)
        if any(candidate == item or candidate.startswith(f"{item}/") for item in exclusions):
            report["excluded_count"] += 1
            continue
        try:
            resolved_path, resolved_relative = resolve_in_root(root, candidate)
            file_stat = resolved_path.stat()
        except (FileNotFoundError, NotADirectoryError):
            report["missing_count"] += 1
            continue
        except (OSError, ValueError):
            report["unsafe_count"] += 1
            continue

        if not stat.S_ISREG(file_stat.st_mode):
            report["non_regular_count"] += 1
            continue
        if not cross_filesystems and file_stat.st_dev != root_device:
            report["excluded_count"] += 1
            continue
        inode = (file_stat.st_dev, file_stat.st_ino)
        if inode in seen_inodes:
            report["duplicate_inode_count"] += 1
            continue
        seen_inodes.add(inode)
        filtered.append((resolved_relative, weight))

    report["output_count"] = len(filtered)
    report["eligible_count"] = (
        report["output_count"] + report["missing_count"] + report["unsafe_count"]
    )
    return filtered, report


def validate_report(
    report: dict[str, int], min_output_count: int, min_coverage_percent: int
) -> None:
    if not 0 <= min_coverage_percent <= 100:
        raise ValueError("coverage percentage must be between 0 and 100")
    if report["unsafe_count"] != 0:
        raise ValueError(f"profile contains unsafe paths: {report['unsafe_count']}")
    if report["output_count"] < min_output_count:
        raise ValueError(
            "profile contains too few unique files: "
            f"{report['output_count']} < {min_output_count}"
        )
    eligible_count = report["eligible_count"]
    if eligible_count == 0 or (
        report["output_count"] * 100
        < eligible_count * min_coverage_percent
    ):
        raise ValueError(
            "profile coverage is too low: "
            f"{report['output_count']}/{eligible_count} unique eligible files "
            f"< {min_coverage_percent}%"
        )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("profile", type=Path)
    parser.add_argument("root", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--kernel-release", required=True)
    parser.add_argument("--report", type=Path)
    parser.add_argument("--exclude", action="append", default=[])
    parser.add_argument(
        "--cross-filesystems",
        action="store_true",
        help="include files whose reported device differs from the root device",
    )
    parser.add_argument("--min-output-count", type=int, default=0)
    parser.add_argument("--min-coverage-percent", type=int, default=0)
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    entries = parse_profile(args.profile)
    exclusions = tuple(sorted({item.strip("/") for item in args.exclude if item.strip("/")}))
    filtered, report = filter_profile(
        args.root.resolve(),
        entries,
        args.kernel_release,
        exclusions,
        args.cross_filesystems,
    )
    args.output.write_text(
        "".join(f"{path} {weight}\n" for path, weight in filtered),
        encoding="utf-8",
    )
    if args.report:
        args.report.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(
        "[compact-boot-profile] "
        + " ".join(f"{name}={value}" for name, value in report.items())
    )
    try:
        validate_report(
            report,
            min_output_count=args.min_output_count,
            min_coverage_percent=args.min_coverage_percent,
        )
    except ValueError as error:
        raise SystemExit(f"boot profile rejected: {error}") from error


if __name__ == "__main__":
    main()
