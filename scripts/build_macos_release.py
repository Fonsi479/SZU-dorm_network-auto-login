#!/usr/bin/env python3
"""Build and stage a local, non-publishing macOS release archive."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import shutil
import subprocess
from datetime import datetime, timezone
from pathlib import Path


DEFAULT_VERSION = "2.0.0"
APP_NAME = "SZU Dorm Login.app"
RELEASE_LABEL_PATTERN = re.compile(r"[0-9A-Za-z]+(?:[.-][0-9A-Za-z]+)*")


def normalize_release_label(value: str | None) -> str:
    label = (value or "").strip()
    if not label:
        return ""
    if label.lower() == "local" or RELEASE_LABEL_PATTERN.fullmatch(label) is None:
        raise ValueError("release label must look like beta.1 or rc.1 and cannot be local")
    return label


def run(command: list[str], *, cwd: Path) -> None:
    subprocess.run(command, cwd=cwd, check=True)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def git_state(root: Path) -> tuple[str, bool]:
    revision = subprocess.run(
        ["git", "rev-parse", "HEAD"], cwd=root, check=True, capture_output=True, text=True
    ).stdout.strip()
    dirty = bool(
        subprocess.run(
            ["git", "status", "--porcelain"], cwd=root, check=True, capture_output=True, text=True
        ).stdout.strip()
    )
    return revision, dirty


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", default=DEFAULT_VERSION)
    parser.add_argument(
        "--release-label",
        help="optional package suffix such as beta.1 or rc.1; the app version stays numeric",
    )
    parser.add_argument("--allow-dirty", action="store_true", help="build a clearly marked local candidate")
    args = parser.parse_args(argv)
    try:
        release_label = normalize_release_label(args.release_label)
    except ValueError as error:
        parser.error(str(error))
    root = Path(__file__).resolve().parents[1]
    revision, dirty = git_state(root)
    if dirty and not args.allow_dirty:
        parser.error("worktree is dirty; commit reviewed changes or pass --allow-dirty for a local candidate")

    run(["bash", "scripts/build_app.sh"], cwd=root)
    run(["bash", "scripts/verify_app.sh"], cwd=root)
    source_app = root / "dist" / APP_NAME
    if not source_app.is_dir():
        parser.error(f"missing built app: {source_app}")

    suffix = f"-{release_label}" if release_label else ""
    if dirty:
        suffix += "-local"
    package_name = f"SZU-Campus-Network-macOS-v{args.version}{suffix}"
    staging_parent = root / "dist" / "macos-staging"
    package_root = staging_parent / package_name
    archive = root / "dist" / "release" / f"{package_name}.zip"
    if staging_parent.exists():
        shutil.rmtree(staging_parent)
    package_root.mkdir(parents=True)
    shutil.copytree(source_app, package_root / APP_NAME, symlinks=True)
    for name in ("README.md", "LICENSE", "SECURITY.md", "PRIVACY.md", "CHANGELOG.md", "THIRD_PARTY_NOTICES.md"):
        shutil.copy2(root / name, package_root / name)
    run(
        [
            "python3", "scripts/generate_sbom.py", "--platform", "macos",
            "--output", str(package_root / "SBOM.spdx.json"),
        ],
        cwd=root,
    )
    provenance = {
        "schemaVersion": 1,
        "product": "SZU Campus Network",
        "platform": "macOS",
        "version": args.version,
        "releaseLabel": release_label or None,
        "releaseChannel": "prerelease" if release_label else "stable-candidate",
        "gitRevision": revision,
        "treeState": "dirty-local-candidate" if dirty else "clean",
        "createdAt": datetime.now(timezone.utc).replace(microsecond=0).isoformat(),
        "published": False,
        "notarization": "BLOCKED_NOT_PERFORMED",
        "campusValidation": "PENDING_CAMPUS_VALIDATION",
    }
    (package_root / "BUILD-PROVENANCE.json").write_text(
        json.dumps(provenance, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    manifest_lines = []
    for path in sorted(package_root.rglob("*")):
        if path.is_file():
            manifest_lines.append(f"{sha256(path)}  {path.relative_to(package_root)}")
    (package_root / "MANIFEST-SHA256.txt").write_text(
        "\n".join(manifest_lines) + "\n", encoding="utf-8"
    )
    run(["python3", "scripts/scan_release_artifacts.py", str(package_root)], cwd=root)
    archive.parent.mkdir(parents=True, exist_ok=True)
    archive.unlink(missing_ok=True)
    run(
        ["/usr/bin/ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(package_root), str(archive)],
        cwd=root,
    )
    run(["python3", "scripts/scan_release_artifacts.py", str(archive)], cwd=root)
    checksum_path = archive.with_suffix(archive.suffix + ".sha256")
    checksum_path.write_text(f"{sha256(archive)}  {archive.name}\n", encoding="ascii")
    print(archive)
    print(checksum_path)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
