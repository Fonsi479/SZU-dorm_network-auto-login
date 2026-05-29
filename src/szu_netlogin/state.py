"""Local state flags for the SZU netlogin control layer."""

from __future__ import annotations

from datetime import datetime
from pathlib import Path


STATE_DIR = Path.home() / ".szu-netlogin"
PAUSE_FLAG_FILE = STATE_DIR / "paused"


def is_paused() -> bool:
    return PAUSE_FLAG_FILE.exists()


def pause() -> None:
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    PAUSE_FLAG_FILE.write_text(f"{datetime.now().astimezone().isoformat()}\n", encoding="utf-8")


def resume() -> None:
    try:
        PAUSE_FLAG_FILE.unlink()
    except FileNotFoundError:
        return
