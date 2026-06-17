"""Local state flags for the SZU netlogin control layer."""

from __future__ import annotations

import os
from datetime import datetime
from pathlib import Path


STATE_DIR_ENV = "SZU_NETLOGIN_STATE_DIR"
STATE_DIR = Path(os.environ.get(STATE_DIR_ENV, Path.home() / ".szu-netlogin")).expanduser()
PAUSE_FLAG_FILE = STATE_DIR / "paused"


def is_paused() -> bool:
    try:
        return PAUSE_FLAG_FILE.exists()
    except OSError:
        return True


def pause() -> None:
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    PAUSE_FLAG_FILE.write_text(f"{datetime.now().astimezone().isoformat()}\n", encoding="utf-8")


def resume() -> None:
    try:
        PAUSE_FLAG_FILE.unlink()
    except FileNotFoundError:
        return
