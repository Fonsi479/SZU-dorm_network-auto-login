#!/usr/bin/env python3
"""Assemble the end-user Windows zip around the standalone GUI executable."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import zipfile
from datetime import datetime, timezone
from pathlib import Path

try:
    from .verify_windows_package import verify_executable, verify_release, verify_source
except ImportError:  # Direct script execution keeps the scripts directory on sys.path.
    from verify_windows_package import verify_executable, verify_release, verify_source


DEFAULT_VERSION = "2.0.0"
EXECUTABLE_NAME = "SZU Campus Network.exe"
CLI_EXECUTABLE_NAME = "szu-campus-netctl.exe"
RELEASE_LABEL_PATTERN = re.compile(r"[0-9A-Za-z]+(?:[.-][0-9A-Za-z]+)*")


def normalize_release_label(value: str | None) -> str:
    label = (value or "").strip()
    if not label:
        return ""
    if label.lower() == "local" or RELEASE_LABEL_PATTERN.fullmatch(label) is None:
        raise ValueError("release label must look like beta.1 or rc.1 and cannot be local")
    return label


def write_utf8_lf(path: Path, text: str) -> None:
    with path.open("w", encoding="utf-8", newline="\n") as handle:
        handle.write(text)


def git_state(root: Path) -> tuple[str, bool]:
    try:
        revision = subprocess.run(
            ["git", "rev-parse", "HEAD"],
            cwd=root,
            check=False,
            capture_output=True,
            text=True,
        )
        status = subprocess.run(
            ["git", "status", "--porcelain"],
            cwd=root,
            check=False,
            capture_output=True,
            text=True,
        )
    except OSError:
        return ("NOASSERTION", True)

    revision_value = (
        revision.stdout.strip() if revision.returncode == 0 else "NOASSERTION"
    )
    dirty = status.returncode != 0 or bool(status.stdout.strip())
    return (revision_value or "NOASSERTION", dirty)


def digest_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def verify_frozen_self_test(executable: Path) -> list[str]:
    if os.name != "nt":
        return [f"冻结版自检必须在 Windows 运行：{executable}"]
    try:
        result = subprocess.run(
            [str(executable), "--self-test"],
            cwd=executable.parent,
            check=False,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=45,
        )
    except subprocess.TimeoutExpired:
        return [f"冻结版自检超时：{executable}"]
    except OSError as exc:
        return [f"无法运行冻结版自检：{executable}：{exc}"]
    if result.returncode != 0:
        return [f"冻结版自检失败：{executable}：exit={result.returncode}"]
    return []


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", default=DEFAULT_VERSION)
    parser.add_argument(
        "--release-label",
        help="optional package suffix such as beta.1 or rc.1; PE versions stay numeric",
    )
    parser.add_argument("--executable", type=Path)
    parser.add_argument("--cli-executable", type=Path)
    parser.add_argument("--allow-dirty", action="store_true")
    parser.add_argument("--architecture", choices=("x64", "arm64"), required=True)
    args = parser.parse_args(argv)
    try:
        release_label = normalize_release_label(args.release_label)
    except ValueError as error:
        parser.error(str(error))

    root = Path(__file__).resolve().parents[1]
    revision, dirty = git_state(root)
    if dirty and not args.allow_dirty:
        print(
            "[失败] 工作树存在未提交改动；正式候选必须使用干净工作树，"
            "本地候选请显式传入 --allow-dirty。",
            file=sys.stderr,
        )
        return 2
    executable = (args.executable or root / "dist" / "windows-app" / EXECUTABLE_NAME).resolve()
    cli_executable = (args.cli_executable or root / "dist" / "windows-app" / CLI_EXECUTABLE_NAME).resolve()
    failures = (
        verify_source(root)
        + verify_executable(
            executable,
            expected_subsystem=2,
            expected_architecture=args.architecture,
        )
        + verify_executable(
            cli_executable,
            expected_subsystem=3,
            expected_architecture=args.architecture,
        )
    )
    if not failures:
        failures += verify_frozen_self_test(executable)
        failures += verify_frozen_self_test(cli_executable)
    if failures:
        for failure in failures:
            print(f"[失败] {failure}", file=sys.stderr)
        return 1

    output_dir = root / "dist" / "release"
    staging_root = root / "dist" / "windows-staging"
    package_suffix = f"-{release_label}" if release_label else ""
    if dirty:
        package_suffix += "-local"
    package_name = (
        f"SZU-Campus-Network-Windows-{args.architecture}-v{args.version}{package_suffix}"
    )
    package_root = staging_root / package_name
    archive_path = output_dir / f"{package_name}.zip"

    if staging_root.exists():
        shutil.rmtree(staging_root)
    package_root.mkdir(parents=True)
    shutil.copy2(executable, package_root / EXECUTABLE_NAME)
    shutil.copy2(cli_executable, package_root / CLI_EXECUTABLE_NAME)
    shutil.copy2(root / "LICENSE", package_root / "LICENSE.txt")
    for source, destination in (
        ("SECURITY.md", "SECURITY.txt"),
        ("PRIVACY.md", "PRIVACY.txt"),
        ("CHANGELOG.md", "CHANGELOG.txt"),
        ("THIRD_PARTY_NOTICES.md", "THIRD_PARTY_NOTICES.txt"),
    ):
        shutil.copy2(root / source, package_root / destination)
    write_utf8_lf(
        package_root / "README.txt",
        "SZU Campus Network Windows v"
        + args.version
        + (f"-{release_label}" if release_label else "")
        + "\n\n"
        + "GUI: double-click SZU Campus Network.exe. Python is bundled.\n"
        + "JSON CLI: szu-campus-netctl.exe --json reads one JSON object from stdin.\n"
        + "The CLI never accepts passwords in arguments, stdin, environment, or config.\n"
        + "Dorm and Teaching providers are independently controlled; Teaching defaults off.\n"
        + "SRun logout remains disabled pending campus validation.\n"
        + "No VPN, proxy, DNS, or route settings are changed.\n"
        + "This unsigned test build may trigger SmartScreen. Verify SHA256.txt.\n",
    )
    sbom = package_root / "SBOM.spdx.json"
    subprocess.run(
        [
            sys.executable,
            str(root / "scripts" / "generate_sbom.py"),
            "--platform",
            "windows",
            "--output",
            str(sbom),
        ],
        cwd=root,
        check=True,
    )
    provenance = {
        "schemaVersion": 1,
        "product": "SZU Campus Network",
        "platform": "Windows",
        "architecture": args.architecture,
        "version": args.version,
        "releaseLabel": release_label or None,
        "releaseChannel": "prerelease" if release_label else "stable-candidate",
        "gitRevision": revision,
        "treeState": "dirty-local-candidate" if dirty else "clean",
        "createdAt": datetime.now(timezone.utc).replace(microsecond=0).isoformat(),
        "published": False,
        "authenticode": "BLOCKED_NOT_PERFORMED",
        "defenderSmartScreen": "BLOCKED_NOT_PERFORMED",
        "campusValidation": "PENDING_CAMPUS_VALIDATION",
    }
    write_utf8_lf(
        package_root / "BUILD-PROVENANCE.json",
        json.dumps(provenance, ensure_ascii=True, indent=2) + "\n",
    )
    checksums = [
        f"{digest_file(path)}  {path.name}"
        for path in sorted(package_root.iterdir())
        if path.is_file() and path.name != "SHA256.txt"
    ]
    write_utf8_lf(package_root / "SHA256.txt", "\n".join(checksums) + "\n")

    failures = verify_release(
        package_root,
        expected_architecture=args.architecture,
    )
    if failures:
        for failure in failures:
            print(f"[失败] {failure}", file=sys.stderr)
        return 1
    scan = subprocess.run(
        [sys.executable, str(root / "scripts" / "scan_release_artifacts.py"), str(package_root)],
        cwd=root,
        check=False,
    )
    if scan.returncode != 0:
        return scan.returncode

    output_dir.mkdir(parents=True, exist_ok=True)
    archive_path.unlink(missing_ok=True)
    with zipfile.ZipFile(archive_path, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        for path in sorted(package_root.rglob("*")):
            if path.is_file():
                archive.write(path, path.relative_to(staging_root))

    scan = subprocess.run(
        [sys.executable, str(root / "scripts" / "scan_release_artifacts.py"), str(archive_path)],
        cwd=root,
        check=False,
    )
    if scan.returncode != 0:
        archive_path.unlink(missing_ok=True)
        return scan.returncode
    write_utf8_lf(
        archive_path.with_suffix(archive_path.suffix + ".sha256"),
        f"{digest_file(archive_path)}  {archive_path.name}\n",
    )

    print(f"Windows 发布包：{archive_path}")
    print(f"SHA-256：{digest_file(archive_path)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
