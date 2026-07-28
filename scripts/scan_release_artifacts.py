#!/usr/bin/env python3
"""Fail on source files, developer paths, or high-confidence secrets in release staging."""

from __future__ import annotations

import argparse
import re
import subprocess
import zipfile
from pathlib import Path


TEXT_SUFFIXES = {
    ".txt", ".md", ".json", ".plist", ".xml", ".html", ".css", ".js", ".yaml", ".yml"
}
SOURCE_SUFFIXES = {".py", ".pyc", ".swift", ".h", ".m", ".ps1", ".bat", ".cmd"}
BINARY_SUFFIXES = {".exe"}
PATTERNS = {
    "private-key": re.compile(r"-----BEGIN (?:RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----"),
    "openai-key": re.compile(r"\bsk-[A-Za-z0-9_-]{20,}\b"),
    "github-token": re.compile(r"\b(?:ghp|github_pat)_[A-Za-z0-9_]{20,}\b"),
    "slack-token": re.compile(r"\bxox[baprs]-[A-Za-z0-9-]{16,}\b"),
    "aws-key": re.compile(r"\bAKIA[0-9A-Z]{16}\b"),
    "developer-path": re.compile(r"(?:/Users/[A-Za-z0-9._-]+/(?:Documents|Downloads|Desktop)/|[A-Za-z]:\\Users\\[^\\]+\\(?:Documents|Downloads|Desktop)\\)"),
}


def scan_bytes(name: str, data: bytes) -> list[str]:
    text = data.decode("utf-8", errors="ignore")
    return [f"{name}: {label}" for label, pattern in PATTERNS.items() if pattern.search(text)]


def executable_strings(path: Path) -> bytes:
    strings_tool = Path("/usr/bin/strings")
    if not strings_tool.is_file():
        return path.read_bytes()
    result = subprocess.run([str(strings_tool), str(path)], check=False, capture_output=True)
    return result.stdout if result.returncode == 0 else b""


def scan_directory(root: Path) -> list[str]:
    failures: list[str] = []
    for path in sorted(root.rglob("*")):
        if not path.is_file():
            continue
        relative = path.relative_to(root)
        if path.suffix.lower() in SOURCE_SUFFIXES:
            failures.append(f"{relative}: source file forbidden")
            continue
        if path.suffix.lower() in TEXT_SUFFIXES or path.name in {"LICENSE", "README"}:
            failures.extend(scan_bytes(str(relative), path.read_bytes()))
        elif path.suffix.lower() in BINARY_SUFFIXES or path.stat().st_mode & 0o111:
            failures.extend(scan_bytes(str(relative), executable_strings(path)))
    return failures


def scan_zip(path: Path) -> list[str]:
    failures: list[str] = []
    with zipfile.ZipFile(path) as archive:
        for info in archive.infolist():
            suffix = Path(info.filename).suffix.lower()
            if suffix in SOURCE_SUFFIXES:
                failures.append(f"{info.filename}: source file forbidden")
            elif suffix in TEXT_SUFFIXES or Path(info.filename).name in {"LICENSE", "README"}:
                failures.extend(scan_bytes(info.filename, archive.read(info)))
            elif suffix in BINARY_SUFFIXES:
                failures.extend(scan_bytes(info.filename, archive.read(info)))
    return failures


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("paths", nargs="+", type=Path)
    args = parser.parse_args(argv)
    failures: list[str] = []
    for raw_path in args.paths:
        path = raw_path.expanduser().resolve()
        if path.is_dir():
            failures.extend(scan_directory(path))
        elif path.is_file() and path.suffix.lower() == ".zip":
            failures.extend(scan_zip(path))
        else:
            failures.append(f"unsupported release path: {path}")
    if failures:
        for failure in failures:
            print(f"[FAIL] {failure}")
        return 1
    print("Release artifact scan passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
