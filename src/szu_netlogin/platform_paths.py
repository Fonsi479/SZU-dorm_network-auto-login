"""Small platform helpers shared by CLI, macOS, and Windows clients."""

from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path
from typing import Any


APP_DIR_NAME = "SZU Dorm NetLogin"


def get_default_app_project_root() -> Path:
    """Return a writable default home for packaged apps."""
    if os.name == "nt" or sys.platform == "darwin":
        return get_user_data_dir()
    return Path.home() / "Projects" / "szu-netlogin"


def get_user_data_dir() -> Path:
    if os.name == "nt":
        base = Path(os.environ.get("APPDATA") or Path.home() / "AppData" / "Roaming")
        return base / APP_DIR_NAME
    if sys.platform == "darwin":
        return Path.home() / "Library" / "Application Support" / "szu-netlogin"
    base = Path(os.environ.get("XDG_DATA_HOME") or Path.home() / ".local" / "share")
    return base / "szu-netlogin"


def get_user_log_dir() -> Path:
    if os.name == "nt":
        base = Path(os.environ.get("LOCALAPPDATA") or Path.home() / "AppData" / "Local")
        return base / APP_DIR_NAME / "Logs"
    if sys.platform == "darwin":
        return Path.home() / "Library" / "Logs" / "szu-netlogin"
    base = Path(os.environ.get("XDG_STATE_HOME") or Path.home() / ".local" / "state")
    return base / "szu-netlogin" / "logs"


def open_path_with_default_app(path: Path) -> None:
    if os.name == "nt":
        os.startfile(str(path))  # type: ignore[attr-defined]
        return
    if sys.platform == "darwin":
        subprocess.run(["open", str(path)], check=False)
        return
    subprocess.run(["xdg-open", str(path)], check=False)


def run_subprocess_hidden(*popenargs: Any, **kwargs: Any) -> subprocess.CompletedProcess:
    """Run a subprocess without flashing a console window on Windows."""
    if os.name == "nt":
        kwargs.setdefault("creationflags", getattr(subprocess, "CREATE_NO_WINDOW", 0))
        startupinfo = subprocess.STARTUPINFO()
        startupinfo.dwFlags |= subprocess.STARTF_USESHOWWINDOW
        startupinfo.wShowWindow = 0
        kwargs.setdefault("startupinfo", startupinfo)
    return subprocess.run(*popenargs, **kwargs)
