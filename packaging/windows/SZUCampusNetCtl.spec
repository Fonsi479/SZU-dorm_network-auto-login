from pathlib import Path

from PyInstaller.utils.hooks import collect_submodules, copy_metadata


ROOT = Path(SPEC).resolve().parents[2]
ASSET_DIR = ROOT / "build" / "windows-assets"
hiddenimports = collect_submodules("keyring.backends")
datas = [(str(ROOT / "config.example.yaml"), "."), *copy_metadata("keyring")]

a = Analysis(
    [str(ROOT / "src" / "szu_netlogin" / "json_cli.py")],
    pathex=[str(ROOT)],
    binaries=[],
    datas=datas,
    hiddenimports=hiddenimports,
    hookspath=[],
    hooksconfig={},
    runtime_hooks=[],
    excludes=[],
    noarchive=False,
    optimize=0,
)
pyz = PYZ(a.pure)
exe = EXE(
    pyz,
    a.scripts,
    a.binaries,
    a.datas,
    [],
    name="szu-campus-netctl",
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    upx=False,
    console=True,
    disable_windowed_traceback=False,
    version=str(ASSET_DIR / "cli-version-info.txt"),
    uac_admin=False,
)
