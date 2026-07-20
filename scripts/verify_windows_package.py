#!/usr/bin/env python3
"""Verify Windows source boundaries, executable shape, and end-user release contents."""

from __future__ import annotations

import argparse
import ast
import sys
from pathlib import Path


EXECUTABLE_NAME = "SZU Dorm Login.exe"
SOURCE_REQUIRED_PATHS = (
    "README.md",
    "LICENSE",
    "requirements.txt",
    "requirements-build.txt",
    "config.example.yaml",
    "apps/windows_desktop/README.md",
    "apps/windows_desktop/szu_windows_desktop.py",
    "packaging/windows/SZUDormLogin.spec",
    "scripts/build_windows_exe.py",
    "scripts/build_windows_package.py",
    "src/szu_netlogin/config.py",
    "src/szu_netlogin/control.py",
    "src/szu_netlogin/dorm_drcom_client.py",
    "src/szu_netlogin/login.py",
    "src/szu_netlogin/platform_paths.py",
)

FORBIDDEN_PATHS = (
    "launchd",
    "packaging/SZUDormLogin.spec",
    "scripts/build_app.sh",
    "scripts/install_launchagent.sh",
    "scripts/open_menubar_app.sh",
    "scripts/run_menubar.sh",
    "scripts/uninstall_launchagent.sh",
    "scripts/verify_app.sh",
    "src/szu_netlogin/menubar_app.py",
)


def verify_source(root: Path) -> list[str]:
    failures: list[str] = []
    for relative in SOURCE_REQUIRED_PATHS:
        if not (root / relative).is_file():
            failures.append(f"缺少 Windows 必需文件：{relative}")

    for relative in FORBIDDEN_PATHS:
        forbidden = root / relative
        contains_files = forbidden.is_dir() and any(path.is_file() for path in forbidden.rglob("*"))
        if forbidden.is_file() or contains_files:
            failures.append(f"混入 macOS 专用内容：{relative}")

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
    for marker in ('name="SZU Dorm Login"', "console=False", "uac_admin=False"):
        if marker not in spec:
            failures.append(f"Windows GUI spec 缺少安全构建标记：{marker}")

    for source_path in sorted(root.rglob("*.py")):
        if any(part in {".venv-szu-dorm-login", "build", "dist", "__pycache__", "macos"} for part in source_path.parts):
            continue
        try:
            ast.parse(source_path.read_text(encoding="utf-8"), filename=str(source_path))
        except (OSError, UnicodeError, SyntaxError) as exc:
            failures.append(f"Python 语法检查失败：{source_path.relative_to(root)}：{exc}")
    return failures


def verify_executable(executable: Path) -> list[str]:
    failures: list[str] = []
    if not executable.is_file():
        return [f"缺少 Windows GUI：{executable}"]
    try:
        with executable.open("rb") as handle:
            magic = handle.read(2)
        size = executable.stat().st_size
    except OSError as exc:
        return [f"无法读取 Windows GUI：{exc}"]
    if magic != b"MZ":
        failures.append(f"Windows GUI 缺少 PE/MZ 文件头：{executable}")
    if size < 1_000_000:
        failures.append(f"Windows GUI 体积异常，可能未包含 Python 运行时：{size} bytes")
    return failures


def verify_release(root: Path) -> list[str]:
    failures = verify_executable(root / EXECUTABLE_NAME)
    for relative in ("README.txt", "SHA256.txt", "LICENSE.txt"):
        if not (root / relative).is_file():
            failures.append(f"发布目录缺少：{relative}")
    for path in root.rglob("*"):
        if path.is_file() and path.suffix.lower() in {".py", ".pyc", ".bat", ".cmd", ".ps1"}:
            failures.append(f"最终发布包不应包含命令行/源码入口：{path.relative_to(root)}")
        if path.name in {".DS_Store", "__pycache__"}:
            failures.append(f"发布目录包含生成文件：{path.relative_to(root)}")
    return failures


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
    args = parser.parse_args(argv)

    root = Path(__file__).resolve().parents[1]
    if args.executable:
        target = args.executable.expanduser().resolve()
        failures = verify_executable(target)
    elif args.release_root:
        target = args.release_root.expanduser().resolve()
        failures = verify_release(target)
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
