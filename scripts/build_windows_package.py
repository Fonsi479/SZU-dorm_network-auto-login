#!/usr/bin/env python3
"""Build a Windows-only transfer zip from the dedicated Windows branch."""

from __future__ import annotations

import argparse
import shutil
import sys
import zipfile
from pathlib import Path

from verify_windows_package import verify


PACKAGE_ENTRIES = (
    "README.md",
    "LICENSE",
    "requirements.txt",
    "config.example.yaml",
    "diagnose.py",
    "one_click_install_and_run.bat",
    "start_szu_dorm_login.bat",
    "apps/windows_desktop",
    "src/szu_netlogin",
)


def copy_entry(source: Path, destination: Path) -> None:
    if source.is_dir():
        shutil.copytree(
            source,
            destination,
            ignore=shutil.ignore_patterns("__pycache__", "*.pyc", ".DS_Store"),
        )
        return
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, destination)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", default="1.1.0")
    args = parser.parse_args(argv)

    root = Path(__file__).resolve().parents[1]
    output_dir = root / "dist" / "release"
    staging_root = root / "dist" / "windows-staging"
    package_name = f"szu-dorm-login-windows-v{args.version}"
    package_root = staging_root / package_name
    archive_path = output_dir / f"SZU-Dorm-Login-Windows-v{args.version}.zip"

    source_failures = verify(root)
    if source_failures:
        for failure in source_failures:
            print(f"[失败] {failure}", file=sys.stderr)
        return 1

    shutil.rmtree(staging_root, ignore_errors=True)
    package_root.mkdir(parents=True)
    for relative in PACKAGE_ENTRIES:
        source = root / relative
        if not source.exists():
            print(f"[失败] 缺少打包内容：{relative}", file=sys.stderr)
            return 1
        copy_entry(source, package_root / relative)

    package_failures = verify(package_root, reject_generated=True)
    if package_failures:
        for failure in package_failures:
            print(f"[失败] {failure}", file=sys.stderr)
        return 1

    output_dir.mkdir(parents=True, exist_ok=True)
    archive_path.unlink(missing_ok=True)
    with zipfile.ZipFile(archive_path, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        for path in sorted(package_root.rglob("*")):
            if path.is_file():
                archive.write(path, path.relative_to(staging_root))

    print(f"Windows 发布包：{archive_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
