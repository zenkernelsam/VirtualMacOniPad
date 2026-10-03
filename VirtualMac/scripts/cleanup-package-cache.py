#!/usr/bin/env python3
"""Keep the newest Debian packages in a directory and archive older ones.

Older files are moved into a sibling .archive directory so package cleanup is
reversible and never destroys a rollback artifact.
"""
from __future__ import annotations

import argparse
import functools
import os
from pathlib import Path
import shutil
import subprocess
import time


def version(path: Path) -> str | None:
    try:
        return subprocess.check_output(
            ["dpkg-deb", "-f", str(path), "Version"],
            text=True,
            stderr=subprocess.DEVNULL,
        ).strip()
    except (OSError, subprocess.CalledProcessError):
        return None


def compare(left: tuple[str, Path], right: tuple[str, Path]) -> int:
    lv, lp = left
    rv, rp = right
    if subprocess.run(["dpkg", "--compare-versions", lv, "gt", rv]).returncode:
        if subprocess.run(["dpkg", "--compare-versions", lv, "lt", rv]).returncode == 0:
            return 1
    else:
        return -1
    # Same Debian version: newest mtime wins; filename makes the result stable.
    lk = (lp.stat().st_mtime_ns, lp.name)
    rk = (rp.stat().st_mtime_ns, rp.name)
    return -1 if lk > rk else (1 if lk < rk else 0)


def archive_old(directory: Path, keep: int) -> list[Path]:
    candidates: list[tuple[str, Path]] = []
    for path in directory.glob("*.deb"):
        if path.is_file():
            package_version = version(path)
            if package_version is not None:
                candidates.append((package_version, path))
    candidates.sort(key=functools.cmp_to_key(compare))
    archive = directory / ".archive"
    moved: list[Path] = []
    for _, path in candidates[keep:]:
        archive.mkdir(mode=0o755, exist_ok=True)
        destination = archive / path.name
        if destination.exists():
            destination = archive / f"{path.stem}.{time.strftime('%Y%m%d-%H%M%S')}{path.suffix}"
        shutil.move(str(path), str(destination))
        moved.append(destination)
    return moved


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("directory", type=Path)
    parser.add_argument("--keep", type=int, default=3)
    parser.add_argument("--label", default="packages")
    args = parser.parse_args()
    if args.keep < 1:
        parser.error("--keep must be positive")
    directory = args.directory.expanduser()
    if not directory.is_dir():
        print(f"[{args.label}] directory absent; skipped: {directory}")
        return 0
    moved = archive_old(directory, args.keep)
    print(f"[{args.label}] kept newest {args.keep}; archived {len(moved)} old package(s) in {directory / '.archive'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
