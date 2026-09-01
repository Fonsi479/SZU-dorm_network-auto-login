#!/usr/bin/env python3
"""Verify Windows source boundaries, executable shape, and end-user release contents."""

from __future__ import annotations

import argparse
import ast
import hashlib
import re
import struct
import sys
from pathlib import Path


EXECUTABLE_NAME = "SZU Campus Network.exe"
CLI_EXECUTABLE_NAME = "szu-campus-netctl.exe"
MACHINE_TYPES = {"x64": 0x8664, "arm64": 0xAA64}
SOURCE_REQUIRED_PATHS = (
    "README.md",
    "LICENSE",
    "requirements.txt",
    "requirements-build.txt",
    "requirements-windows.lock",
    "requirements-windows-arm64.lock",
    "config.example.yaml",
    "apps/windows_desktop/README.md",
    "apps/windows_desktop/szu_windows_desktop.py",
    "packaging/windows/SZUDormLogin.spec",
    "packaging/windows/SZUCampusNetCtl.spec",
    "scripts/build_windows_exe.py",
    "scripts/build_windows_package.py",
    "src/szu_netlogin/config.py",
    "src/szu_netlogin/control.py",
    "src/szu_netlogin/dorm_drcom_client.py",
    "src/szu_netlogin/login.py",
    "src/szu_netlogin/json_cli.py",
    "src/szu_netlogin/windows_product.py",
    "src/szu_netlogin/coordinator.py",
    "src/szu_netlogin/platform_paths.py",
)

def verify_source(root: Path) -> list[str]:
    failures: list[str] = []
    for relative in SOURCE_REQUIRED_PATHS:
        if not (root / relative).is_file():
            failures.append(f"缺少 Windows 必需文件：{relative}")

    requirements = _read_text(root / "requirements.txt", failures)
    for dependency in ("rumps", "pyobjc"):
        if dependency in requirements.lower():
            failures.append(f"Windows requirements 不应包含：{dependency}")

    desktop_source = _read_text(
        root / "apps/windows_desktop/szu_windows_desktop.py",
        failures,
    )
    for marker in (
        "class SzuDormWindowsApp",
        "def set_windows_startup_enabled",
        "def run_frozen_self_test",
    ):
        if marker not in desktop_source:
            failures.append(f"Windows 客户端缺少实现：{marker}")

    protocol_source = _read_text(root / "src/szu_netlogin/dorm_drcom_client.py", failures)
    if "Get-NetAdapter" in protocol_source or "_get_windows_terminal_mac_for_ip" in protocol_source:
        failures.append("登录核心仍在读取 Windows 网卡 MAC")
    if "def session_fact" not in protocol_source or "/drcom/chkstatus" not in protocol_source:
        failures.append("登录核心缺少门户会话事实读取")

    spec = _read_text(root / "packaging/windows/SZUDormLogin.spec", failures)
    for marker in ('name="SZU Campus Network"', "console=False", "uac_admin=False"):
        if marker not in spec:
            failures.append(f"Windows GUI spec 缺少安全构建标记：{marker}")
    cli_spec = _read_text(root / "packaging/windows/SZUCampusNetCtl.spec", failures)
    for marker in (
        'name="szu-campus-netctl"',
        "console=True",
        'version=str(ASSET_DIR / "cli-version-info.txt")',
        "uac_admin=False",
    ):
        if marker not in cli_spec:
            failures.append(f"Windows CLI spec 缺少安全构建标记：{marker}")
    packaging_inputs = spec + cli_spec + _read_text(root / "scripts/build_windows_package.py", failures)
    for marker in ("macos/", "build_app.sh", "verify_app.sh", "SourceBoundHTTPTransport"):
        if marker in packaging_inputs:
            failures.append(f"Windows 资产输入引用 macOS 内容：{marker}")

    for source_path in sorted(root.rglob("*.py")):
        if any(part in {".venv-szu-dorm-login", "build", "dist", "__pycache__", "macos"} for part in source_path.parts):
            continue
        try:
            ast.parse(source_path.read_text(encoding="utf-8"), filename=str(source_path))
        except (OSError, UnicodeError, SyntaxError) as exc:
            failures.append(f"Python 语法检查失败：{source_path.relative_to(root)}：{exc}")
    return failures


def verify_executable(
    executable: Path,
    *,
    expected_subsystem: int | None = None,
    expected_architecture: str | None = None,
) -> list[str]:
    failures: list[str] = []
    if not executable.is_file():
        return [f"缺少 Windows GUI：{executable}"]
    try:
        with executable.open("rb") as handle:
            dos_header = handle.read(64)
            if len(dos_header) < 64 or dos_header[:2] != b"MZ":
                failures.append(f"Windows 可执行文件缺少完整 DOS/MZ 头：{executable}")
                return failures
            pe_offset = struct.unpack_from("<I", dos_header, 0x3C)[0]
            size = executable.stat().st_size
            if pe_offset < 64 or pe_offset > size - 24:
                failures.append(f"Windows 可执行文件 PE 头偏移无效：{executable}")
                return failures
            handle.seek(pe_offset)
            coff = handle.read(24)
            if len(coff) != 24 or coff[:4] != b"PE\0\0":
                failures.append(f"Windows 可执行文件缺少 PE 签名：{executable}")
                return failures
            (
                machine,
                section_count,
                _timestamp,
                _symbol_table,
                _symbol_count,
                optional_size,
                characteristics,
            ) = struct.unpack_from("<HHIIIHH", coff, 4)
            optional = handle.read(optional_size)
    except OSError as exc:
        return [f"无法读取 Windows GUI：{exc}"]

    accepted_machines = (
        {MACHINE_TYPES[expected_architecture]}
        if expected_architecture is not None
        else set(MACHINE_TYPES.values())
    )
    if machine not in accepted_machines:
        expected = expected_architecture or "x64/arm64"
        failures.append(
            f"Windows 可执行文件架构不是 {expected}：0x{machine:04x}"
        )
    if section_count == 0 or section_count > 96:
        failures.append(f"Windows 可执行文件 section 数异常：{section_count}")
    if characteristics & 0x0002 == 0:
        failures.append("Windows PE 未标记为 executable image")
    if len(optional) != optional_size or optional_size < 70:
        failures.append("Windows PE optional header 不完整")
    else:
        optional_magic = struct.unpack_from("<H", optional, 0)[0]
        subsystem = struct.unpack_from("<H", optional, 68)[0]
        if optional_magic != 0x020B:
            failures.append(
                f"Windows 可执行文件不是 PE32+：0x{optional_magic:04x}"
            )
        if expected_subsystem is not None and subsystem != expected_subsystem:
            failures.append(
                "Windows PE subsystem 不符："
                f"expected={expected_subsystem}, actual={subsystem}"
            )
    if size < 1_000_000:
        failures.append(f"Windows GUI 体积异常，可能未包含 Python 运行时：{size} bytes")
    return failures


def verify_release(root: Path, *, expected_architecture: str | None = None) -> list[str]:
    failures = verify_executable(
        root / EXECUTABLE_NAME,
        expected_subsystem=2,
        expected_architecture=expected_architecture,
    )
    failures += verify_executable(
        root / CLI_EXECUTABLE_NAME,
        expected_subsystem=3,
        expected_architecture=expected_architecture,
    )
    for relative in (
        "README.txt",
        "SHA256.txt",
        "LICENSE.txt",
        "SECURITY.txt",
        "PRIVACY.txt",
        "CHANGELOG.txt",
        "THIRD_PARTY_NOTICES.txt",
        "SBOM.spdx.json",
        "BUILD-PROVENANCE.json",
    ):
        if not (root / relative).is_file():
            failures.append(f"发布目录缺少：{relative}")
    for path in root.rglob("*"):
        if path.is_file() and path.suffix.lower() in {".py", ".pyc", ".bat", ".cmd", ".ps1"}:
            failures.append(f"最终发布包不应包含命令行/源码入口：{path.relative_to(root)}")
        if path.name in {".DS_Store", "__pycache__"}:
            failures.append(f"发布目录包含生成文件：{path.relative_to(root)}")
    allowed = {
        EXECUTABLE_NAME,
        CLI_EXECUTABLE_NAME,
        "README.txt",
        "SHA256.txt",
        "LICENSE.txt",
        "SECURITY.txt",
        "PRIVACY.txt",
        "CHANGELOG.txt",
        "THIRD_PARTY_NOTICES.txt",
        "SBOM.spdx.json",
        "BUILD-PROVENANCE.json",
    }
    unexpected = {path.name for path in root.iterdir() if path.is_file()} - allowed
    if unexpected:
        failures.append("发布目录包含未允许文件：" + ", ".join(sorted(unexpected)))
    readme = root / "README.txt"
    if readme.is_file():
        try:
            readme.read_bytes().decode("ascii")
        except UnicodeDecodeError:
            failures.append("README.txt 必须是 ASCII")
    _verify_checksum_manifest(root, failures)
    return failures


def _verify_checksum_manifest(root: Path, failures: list[str]) -> None:
    manifest_path = root / "SHA256.txt"
    if not manifest_path.is_file():
        return
    try:
        lines = manifest_path.read_text(encoding="ascii").splitlines()
    except (OSError, UnicodeError) as exc:
        failures.append(f"无法读取 SHA256.txt：{exc}")
        return

    manifest: dict[str, str] = {}
    for line in lines:
        match = re.fullmatch(r"([0-9a-f]{64})  ([^/\\]+)", line)
        if match is None:
            failures.append(f"SHA256.txt 行格式无效：{line[:120]}")
            continue
        digest, name = match.groups()
        if name in manifest:
            failures.append(f"SHA256.txt 重复文件：{name}")
        manifest[name] = digest

    expected = {
        path.name
        for path in root.iterdir()
        if path.is_file() and path.name != manifest_path.name
    }
    if set(manifest) != expected:
        missing = sorted(expected - set(manifest))
        extra = sorted(set(manifest) - expected)
        failures.append(f"SHA256.txt 文件集合不符：missing={missing}, extra={extra}")

    for name in sorted(expected & set(manifest)):
        digest = hashlib.sha256((root / name).read_bytes()).hexdigest()
        if manifest[name] != digest:
            failures.append(f"SHA256.txt 校验失败：{name}")


def verify(root: Path, *, reject_generated: bool = False) -> list[str]:
    """Compatibility wrapper for callers that verify a source checkout."""
    failures = verify_source(root)
    if reject_generated:
        for path in root.rglob("*"):
            if path.name in {".DS_Store", "__pycache__"} or path.suffix == ".pyc":
                failures.append(f"发布目录包含生成文件：{path.relative_to(root)}")
    return failures


def _read_text(path: Path, failures: list[str]) -> str:
    try:
        return path.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as exc:
        failures.append(f"无法读取 {path}：{exc}")
        return ""


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--package-root", type=Path)
    parser.add_argument("--executable", type=Path)
    parser.add_argument("--release-root", type=Path)
    parser.add_argument("--architecture", choices=tuple(MACHINE_TYPES))
    args = parser.parse_args(argv)

    root = Path(__file__).resolve().parents[1]
    if args.executable:
        target = args.executable.expanduser().resolve()
        expected_subsystem = (
            3
            if target.name == CLI_EXECUTABLE_NAME
            else 2 if target.name == EXECUTABLE_NAME else None
        )
        failures = verify_executable(
            target,
            expected_subsystem=expected_subsystem,
            expected_architecture=args.architecture,
        )
    elif args.release_root:
        target = args.release_root.expanduser().resolve()
        failures = verify_release(target, expected_architecture=args.architecture)
    else:
        target = (args.package_root or root).expanduser().resolve()
        failures = verify_source(target)

    if failures:
        for failure in failures:
            print(f"[失败] {failure}", file=sys.stderr)
        return 1
    print(f"Windows 检查通过：{target}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
