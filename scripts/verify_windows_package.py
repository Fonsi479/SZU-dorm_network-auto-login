#!/usr/bin/env python3
"""Verify the Windows source tree or an assembled release directory."""

from __future__ import annotations

import argparse
import ast
import sys
from pathlib import Path


REQUIRED_PATHS = (
    "README.md",
    "LICENSE",
    "requirements.txt",
    "config.example.yaml",
    "one_click_install_and_run.bat",
    "start_szu_dorm_login.bat",
    "apps/windows_desktop/README.md",
    "apps/windows_desktop/szu_windows_desktop.py",
    "src/szu_netlogin/config.py",
    "src/szu_netlogin/control.py",
    "src/szu_netlogin/login.py",
    "src/szu_netlogin/platform_paths.py",
)

FORBIDDEN_PATHS = (
    "launchd",
    "requirements-build.txt",
    "packaging/SZUDormLogin.spec",
    "scripts/build_app.sh",
    "scripts/install_launchagent.sh",
    "scripts/open_menubar_app.sh",
    "scripts/run_menubar.sh",
    "scripts/uninstall_launchagent.sh",
    "scripts/verify_app.sh",
    "src/szu_netlogin/menubar_app.py",
)


def verify(root: Path, *, reject_generated: bool = False) -> list[str]:
    failures: list[str] = []
    for relative in REQUIRED_PATHS:
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
        "def hidden_popen_options",
    ):
        if marker not in desktop_source:
            failures.append(f"Windows 客户端缺少实现：{marker}")

    launcher = _read_text(root / "start_szu_dorm_login.bat", failures)
    if "pythonw" not in launcher.lower():
        failures.append("Windows 启动脚本未使用 pythonw.exe")

    for source_path in sorted(root.rglob("*.py")):
        if any(part in {".venv-szu-dorm-login", "build", "dist", "__pycache__"} for part in source_path.parts):
            continue
        try:
            ast.parse(source_path.read_text(encoding="utf-8"), filename=str(source_path))
        except (OSError, UnicodeError, SyntaxError) as exc:
            failures.append(f"Python 语法检查失败：{source_path.relative_to(root)}：{exc}")

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
    parser.add_argument(
        "--package-root",
        type=Path,
        default=Path(__file__).resolve().parents[1],
        help="源码树或已组装的 Windows 发布目录",
    )
    args = parser.parse_args(argv)
    root = args.package_root.expanduser().resolve()
    is_assembled_package = not (root / "scripts/build_windows_package.py").is_file()
    failures = verify(root, reject_generated=is_assembled_package)
    if failures:
        for failure in failures:
            print(f"[失败] {failure}", file=sys.stderr)
        return 1
    print(f"Windows 包检查通过：{root}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
