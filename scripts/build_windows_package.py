#!/usr/bin/env python3
"""Assemble the end-user Windows zip around the standalone GUI executable."""

from __future__ import annotations

import argparse
import hashlib
import shutil
import sys
import zipfile
from pathlib import Path

from verify_windows_package import verify_executable, verify_release, verify_source


DEFAULT_VERSION = "1.2.0"
EXECUTABLE_NAME = "SZU Dorm Login.exe"


def write_utf8_lf(path: Path, text: str) -> None:
    with path.open("w", encoding="utf-8", newline="\n") as handle:
        handle.write(text)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", default=DEFAULT_VERSION)
    parser.add_argument("--executable", type=Path)
    args = parser.parse_args(argv)

    root = Path(__file__).resolve().parents[1]
    executable = (args.executable or root / "dist" / "windows-app" / EXECUTABLE_NAME).resolve()
    failures = verify_source(root) + verify_executable(executable)
    if failures:
        for failure in failures:
            print(f"[失败] {failure}", file=sys.stderr)
        return 1

    output_dir = root / "dist" / "release"
    staging_root = root / "dist" / "windows-staging"
    package_name = f"SZU-Dorm-Login-Windows-v{args.version}"
    package_root = staging_root / package_name
    archive_path = output_dir / f"{package_name}.zip"

    if staging_root.exists():
        shutil.rmtree(staging_root)
    package_root.mkdir(parents=True)
    shutil.copy2(executable, package_root / EXECUTABLE_NAME)
    shutil.copy2(root / "LICENSE", package_root / "LICENSE.txt")

    digest = hashlib.sha256((package_root / EXECUTABLE_NAME).read_bytes()).hexdigest()
    write_utf8_lf(
        package_root / "SHA256.txt",
        f"{digest}  {EXECUTABLE_NAME}\n",
    )
    write_utf8_lf(
        package_root / "README.txt",
        "SZU Dorm Login Windows v"
        + args.version
        + "\n\n"
        + "1. 双击“SZU Dorm Login.exe”。无需安装 Python，也不会打开命令行窗口。\n"
        + "2. 首次运行，在“概览”页依次点击“修改账号”和“修改密码”。\n"
        + "3. 如需登录 Windows 后自动运行，点击“安装开机自启”。\n"
        + "4. 自动登录只依据宿舍网关和校园网门户会话；不会检测、关闭或配置 VPN。\n"
        + "5. 若 Windows SmartScreen 提示未知发布者，这是因为当前测试包未使用商业证书签名。\n\n"
        + "配置：%APPDATA%\\SZU Dorm NetLogin\\config.yaml\n"
        + "日志：%LOCALAPPDATA%\\SZU Dorm NetLogin\\Logs\\netlogin.log\n",
    )

    failures = verify_release(package_root)
    if failures:
        for failure in failures:
            print(f"[失败] {failure}", file=sys.stderr)
        return 1

    output_dir.mkdir(parents=True, exist_ok=True)
    archive_path.unlink(missing_ok=True)
    with zipfile.ZipFile(archive_path, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        for path in sorted(package_root.rglob("*")):
            if path.is_file():
                archive.write(path, path.relative_to(staging_root))

    print(f"Windows 发布包：{archive_path}")
    print(f"SHA-256：{digest}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
