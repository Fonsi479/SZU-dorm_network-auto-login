# -*- mode: python ; coding: utf-8 -*-

from pathlib import Path

project_root = Path(SPECPATH)
if not (project_root / "src" / "szu_netlogin" / "menubar_app.py").exists():
    project_root = Path.cwd()
entry_script = project_root / "src" / "szu_netlogin" / "menubar_app.py"

a = Analysis(
    [str(entry_script)],
    pathex=[str(project_root)],
    binaries=[],
    datas=[
        (str(project_root / "scripts"), "scripts"),
        (str(project_root / "launchd"), "launchd"),
    ],
    hiddenimports=[
        "rumps",
        "objc",
        "Foundation",
        "AppKit",
        "keyring",
        "src.szu_netlogin.control",
        "src.szu_netlogin.diagnostic_report",
        "src.szu_netlogin.login",
        "src.szu_netlogin.diagnose",
        "src.szu_netlogin.dorm_drcom_client",
    ],
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
    [],
    exclude_binaries=True,
    name="SZU Dorm Login",
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    upx=True,
    console=False,
    disable_windowed_traceback=False,
    argv_emulation=False,
    target_arch=None,
    codesign_identity=None,
    entitlements_file=None,
)
coll = COLLECT(
    exe,
    a.binaries,
    a.datas,
    strip=False,
    upx=True,
    upx_exclude=[],
    name="SZU Dorm Login",
)
app = BUNDLE(
    coll,
    name="SZU Dorm Login.app",
    icon=None,
    bundle_identifier="com.szu-netlogin.dorm-login",
    info_plist={
        "CFBundleName": "SZU Dorm Login",
        "CFBundleDisplayName": "SZU Dorm Login",
        "CFBundleShortVersionString": "1.2.0",
        "CFBundleVersion": "3",
        "LSUIElement": True,
    },
)
