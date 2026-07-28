#!/usr/bin/env python3
"""Build the standalone, windowed Windows executable with PyInstaller."""

from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
from pathlib import Path


DEFAULT_VERSION = "2.0.0"
VERSION_RE = re.compile(r"^(?P<major>\d+)\.(?P<minor>\d+)\.(?P<patch>\d+)$")


def parse_version(value: str) -> tuple[int, int, int]:
    match = VERSION_RE.fullmatch(value.strip())
    if not match:
        raise ValueError("版本号必须是 major.minor.patch，例如 2.0.0")
    return tuple(int(match.group(name)) for name in ("major", "minor", "patch"))


def prepare_windows_assets(root: Path, version: str) -> Path:
    version_tuple = parse_version(version)
    asset_dir = root / "build" / "windows-assets"
    asset_dir.mkdir(parents=True, exist_ok=True)
    _write_version_info(
        asset_dir / "version-info.txt",
        version,
        version_tuple,
        file_description="SZU Campus Network",
        internal_name="SZUCampusNetwork",
        original_filename="SZU Campus Network.exe",
    )
    _write_version_info(
        asset_dir / "cli-version-info.txt",
        version,
        version_tuple,
        file_description="SZU Campus Network JSON CLI",
        internal_name="SZUCampusNetCtl",
        original_filename="szu-campus-netctl.exe",
    )
    _write_icon(asset_dir / "szu-dorm-login.ico")
    return asset_dir


def _write_version_info(
    destination: Path,
    version: str,
    version_tuple: tuple[int, int, int],
    *,
    file_description: str,
    internal_name: str,
    original_filename: str,
) -> None:
    major, minor, patch = version_tuple
    destination.write_text(
        f"""VSVersionInfo(
  ffi=FixedFileInfo(
    filevers=({major}, {minor}, {patch}, 0),
    prodvers=({major}, {minor}, {patch}, 0),
    mask=0x3f,
    flags=0x0,
    OS=0x40004,
    fileType=0x1,
    subtype=0x0,
    date=(0, 0)
  ),
  kids=[
    StringFileInfo([
      StringTable(
        '040904B0',
        [StringStruct('CompanyName', 'SZUNET'),
         StringStruct('FileDescription', '{file_description}'),
         StringStruct('FileVersion', '{version}'),
         StringStruct('InternalName', '{internal_name}'),
         StringStruct('LegalCopyright', 'MIT License'),
         StringStruct('OriginalFilename', '{original_filename}'),
         StringStruct('ProductName', 'SZU Campus Network'),
         StringStruct('ProductVersion', '{version}')])
    ]),
    VarFileInfo([VarStruct('Translation', [1033, 1200])])
  ]
)
""",
        encoding="utf-8",
    )


def _write_icon(destination: Path) -> None:
    from PIL import Image, ImageDraw

    size = 256
    image = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    pixels = image.load()
    for y in range(size):
        ratio = y / (size - 1)
        color = (
            int(23 + 8 * ratio),
            int(92 + 91 * ratio),
            int(211 - 38 * ratio),
            255,
        )
        for x in range(size):
            pixels[x, y] = color

    mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(mask).rounded_rectangle((4, 4, 252, 252), radius=52, fill=255)
    image.putalpha(mask)

    draw = ImageDraw.Draw(image)
    white = (255, 255, 255, 245)
    draw.arc((48, 54, 208, 206), 220, 320, fill=white, width=18)
    draw.arc((78, 88, 178, 190), 220, 320, fill=white, width=18)
    draw.ellipse((119, 169, 137, 187), fill=white)
    draw.rounded_rectangle((78, 194, 178, 214), radius=10, fill=white)
    destination.parent.mkdir(parents=True, exist_ok=True)
    image.save(
        destination,
        format="ICO",
        sizes=[(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)],
    )


def _read_app_version(root: Path) -> str:
    source = (root / "apps" / "windows_desktop" / "szu_windows_desktop.py").read_text(
        encoding="utf-8"
    )
    match = re.search(r'^APP_VERSION\s*=\s*"([^"]+)"', source, flags=re.MULTILINE)
    return match.group(1) if match else ""


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", default=DEFAULT_VERSION)
    parser.add_argument(
        "--prepare-only",
        action="store_true",
        help="只生成版本资源与图标，可在非 Windows 开发机运行",
    )
    args = parser.parse_args(argv)

    root = Path(__file__).resolve().parents[1]
    try:
        parse_version(args.version)
    except ValueError as exc:
        print(f"[失败] {exc}", file=sys.stderr)
        return 2

    app_version = _read_app_version(root)
    if app_version != args.version:
        print(
            f"[失败] GUI 版本 {app_version or 'missing'} 与构建版本 {args.version} 不一致",
            file=sys.stderr,
        )
        return 2

    asset_dir = prepare_windows_assets(root, args.version)
    print(f"Windows 构建资源：{asset_dir}")
    if args.prepare_only:
        return 0
    if os.name != "nt":
        print("[失败] Windows .exe 必须在 Windows 上构建；请使用 windows-ci。", file=sys.stderr)
        return 2

    dist_dir = root / "dist" / "windows-app"
    work_dir = root / "build" / "windows-pyinstaller"
    for spec_name in ("SZUDormLogin.spec", "SZUCampusNetCtl.spec"):
        command = [
            sys.executable, "-m", "PyInstaller", "--noconfirm", "--clean",
            "--distpath", str(dist_dir),
            "--workpath", str(work_dir / Path(spec_name).stem),
            str(root / "packaging" / "windows" / spec_name),
        ]
        result = subprocess.run(command, cwd=root, check=False)
        if result.returncode != 0:
            return result.returncode

    executable = dist_dir / "SZU Campus Network.exe"
    if not executable.is_file():
        print(f"[失败] 未生成 Windows GUI：{executable}", file=sys.stderr)
        return 1
    cli_executable = dist_dir / "szu-campus-netctl.exe"
    if not cli_executable.is_file():
        print(f"[失败] 未生成 Windows JSON CLI：{cli_executable}", file=sys.stderr)
        return 1
    print(f"Windows GUI：{executable}")
    print(f"Windows JSON CLI：{cli_executable}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
