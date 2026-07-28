#!/usr/bin/env python3
"""Scan current source and optional Git history without echoing secret values."""

from __future__ import annotations

import argparse
import io
import os
import re
import shutil
import stat
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable


GIT = shutil.which("git") or "git"
PATTERNS = (
    ("private-key", re.compile(rb"-----BEGIN (?:RSA |EC |OPENSSH |DSA |PGP )?PRIVATE KEY-----")),
    ("openai-key", re.compile(rb"\bsk-[A-Za-z0-9_-]{20,}\b")),
    ("github-token", re.compile(rb"\b(?:ghp|github_pat)_[A-Za-z0-9_]{20,}\b")),
    ("slack-token", re.compile(rb"\bxox[baprs]-[A-Za-z0-9-]{16,}\b")),
    ("aws-access-key", re.compile(rb"\bAKIA[0-9A-Z]{16}\b")),
    ("google-api-key", re.compile(rb"\bAIza[0-9A-Za-z_-]{30,}\b")),
    ("jwt", re.compile(rb"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b")),
    (
        "labeled-secret",
        re.compile(
            rb"(?i)(?:api[_-]?key|access[_-]?token|refresh[_-]?token|client[_-]?secret|password|secret|token)"
            rb"\s*[:=]\s*[\"']?[A-Za-z0-9+/=_-]{24,}"
        ),
    ),
)
FORBIDDEN_NAMES = {
    ".env",
    ".env.local",
    ".env.production",
    "auth.json",
    "config.json",
    "config.yaml",
    "credentials.json",
}
FORBIDDEN_SUFFIXES = {".key", ".pem", ".p12", ".pfx", ".mobileprovision"}


@dataclass(frozen=True)
class Finding:
    rule: str
    path: str


def is_runtime_secret_filename(path: Path) -> bool:
    name = path.name.lower()
    return (
        name in FORBIDDEN_NAMES
        or name.startswith(".env.")
        or path.suffix.lower() in FORBIDDEN_SUFFIXES
    )


def scan_data(data: bytes, label: str) -> list[Finding]:
    findings: list[Finding] = []
    for rule, pattern in PATTERNS:
        if pattern.search(data):
            findings.append(Finding(rule, label))
    return findings


def file_bytes(path: Path) -> bytes | None:
    try:
        metadata = path.lstat()
        if stat.S_ISLNK(metadata.st_mode):
            return os.fsencode(os.readlink(path))
        if not stat.S_ISREG(metadata.st_mode):
            return None
        descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
        with os.fdopen(descriptor, "rb") as handle:
            return handle.read()
    except OSError:
        return None


def source_paths(root: Path) -> list[Path]:
    result = subprocess.run(
        [GIT, "-C", str(root), "ls-files", "-z", "--cached", "--others", "--exclude-standard"],
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if result.returncode != 0:
        raise RuntimeError("source root is not a readable Git worktree")
    return [root / os.fsdecode(item) for item in result.stdout.split(b"\0") if item]


def scan_source(root: Path) -> list[Finding]:
    findings: list[Finding] = []
    for path in source_paths(root):
        label = path.relative_to(root).as_posix()
        if is_runtime_secret_filename(path):
            findings.append(Finding("runtime-secret-file", label))
            continue
        data = file_bytes(path)
        if data is not None:
            findings.extend(scan_data(data, label))
    return findings


def history_object_index(root: Path) -> tuple[list[bytes], dict[bytes, str]]:
    result = subprocess.run(
        [GIT, "-C", str(root), "rev-list", "--objects", "--all"],
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if result.returncode != 0:
        raise RuntimeError("Git history is not readable")

    object_ids: list[bytes] = []
    labels: dict[bytes, str] = {}
    seen: set[bytes] = set()
    for line in result.stdout.splitlines():
        object_id, separator, raw_path = line.partition(b" ")
        if object_id not in seen:
            object_ids.append(object_id)
            seen.add(object_id)
        if separator and object_id not in labels:
            labels[object_id] = os.fsdecode(raw_path)
    return object_ids, labels


def scan_history(root: Path) -> list[Finding]:
    object_ids, labels = history_object_index(root)
    if not object_ids:
        return []
    result = subprocess.run(
        [GIT, "-C", str(root), "cat-file", "--batch"],
        input=b"\n".join(object_ids) + b"\n",
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if result.returncode != 0:
        raise RuntimeError("Git object payloads are not readable")

    stream = io.BytesIO(result.stdout)
    findings: list[Finding] = []
    for expected_id in object_ids:
        header = stream.readline().rstrip(b"\n")
        fields = header.split()
        if len(fields) != 3 or fields[0] != expected_id:
            raise RuntimeError("Git cat-file returned an incomplete object stream")
        object_type = fields[1]
        try:
            size = int(fields[2])
        except ValueError as error:
            raise RuntimeError("Git cat-file returned an invalid object size") from error
        payload = stream.read(size)
        if len(payload) != size or stream.read(1) != b"\n":
            raise RuntimeError("Git cat-file object payload was truncated")
        if object_type != b"blob":
            continue
        path = labels.get(expected_id, f"object-{os.fsdecode(expected_id[:12])}")
        label = f"history:{path}@{os.fsdecode(expected_id[:12])}"
        if is_runtime_secret_filename(Path(path)):
            findings.append(Finding("runtime-secret-file", label))
        findings.extend(scan_data(payload, label))
    return findings


def render(findings: Iterable[Finding]) -> str:
    unique = sorted(set(findings), key=lambda item: (item.path, item.rule))
    return "\n".join(f"{finding.rule}: {finding.path}" for finding in unique)


def parse_arguments(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-root", type=Path, required=True)
    parser.add_argument("--history", action="store_true", help="scan every blob reachable from all refs")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    arguments = parse_arguments(argv)
    root = arguments.source_root.resolve()
    try:
        findings = scan_source(root)
        if arguments.history:
            findings.extend(scan_history(root))
    except RuntimeError as error:
        print(f"repository secret scan failed: {error}", file=sys.stderr)
        return 2
    if findings:
        print("repository secret scan failed; matching values were suppressed:", file=sys.stderr)
        print(render(findings), file=sys.stderr)
        return 1
    scope = "source and Git history" if arguments.history else "source"
    print(f"repository secret scan passed: {scope} contain no matching credentials")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
