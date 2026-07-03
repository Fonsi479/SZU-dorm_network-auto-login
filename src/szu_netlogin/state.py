"""Local state flags for the SZU netlogin control layer."""

from __future__ import annotations

import json
import os
import subprocess
from datetime import datetime, timedelta
from pathlib import Path
from typing import Any

from .platform_paths import run_subprocess_hidden


STATE_DIR_ENV = "SZU_NETLOGIN_STATE_DIR"
STATE_DIR = Path(os.environ.get(STATE_DIR_ENV, Path.home() / ".szu-netlogin")).expanduser()
PAUSE_FLAG_FILE = STATE_DIR / "paused"


def is_paused() -> bool:
    return _active_pause_payload() is not None


def pause(minutes: int | None = None, until_next_boot: bool = False) -> None:
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    now = datetime.now().astimezone()
    payload: dict[str, Any] = {
        "paused_at": now.isoformat(),
        "mode": "manual",
    }

    if minutes is not None:
        payload["mode"] = "until"
        payload["resume_after"] = (now + timedelta(minutes=max(1, minutes))).isoformat()
    elif until_next_boot:
        payload["mode"] = "until_next_boot"
        payload["boot_marker"] = _current_boot_marker()

    PAUSE_FLAG_FILE.write_text(
        json.dumps(payload, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )


def describe_pause_state() -> str:
    payload = _active_pause_payload()
    if payload is None:
        return "未暂停"

    mode = str(payload.get("mode") or "manual")
    if mode == "until":
        resume_after = str(payload.get("resume_after") or "")
        return f"已暂停（预计 {resume_after} 自动恢复）" if resume_after else "已暂停（定时恢复）"
    if mode == "until_next_boot":
        return "已暂停（下次开机恢复）"
    return "已暂停（直到手动恢复）"


def resume() -> None:
    try:
        PAUSE_FLAG_FILE.unlink()
    except FileNotFoundError:
        return


def _active_pause_payload() -> dict[str, Any] | None:
    try:
        if not PAUSE_FLAG_FILE.exists():
            return None
        payload = _read_pause_payload()
    except OSError:
        return {"mode": "manual"}

    mode = str(payload.get("mode") or "manual")
    if mode == "until" and _is_timed_pause_expired(payload):
        resume()
        return None
    if mode == "until_next_boot" and _is_next_boot_pause_expired(payload):
        resume()
        return None

    return payload


def _read_pause_payload() -> dict[str, Any]:
    try:
        text = PAUSE_FLAG_FILE.read_text(encoding="utf-8").strip()
    except OSError:
        return {"mode": "manual"}

    if not text:
        return {"mode": "manual"}

    try:
        loaded = json.loads(text)
    except json.JSONDecodeError:
        return {"mode": "manual", "paused_at": text}

    if not isinstance(loaded, dict):
        return {"mode": "manual"}
    return loaded


def _is_timed_pause_expired(payload: dict[str, Any]) -> bool:
    resume_after = str(payload.get("resume_after") or "")
    if not resume_after:
        return False

    try:
        deadline = datetime.fromisoformat(resume_after)
    except ValueError:
        return False
    return datetime.now().astimezone() >= deadline


def _is_next_boot_pause_expired(payload: dict[str, Any]) -> bool:
    stored_marker = str(payload.get("boot_marker") or "")
    current_marker = _current_boot_marker()
    return bool(stored_marker and current_marker and stored_marker != current_marker)


def _current_boot_marker() -> str:
    if os.name == "nt":
        return _windows_boot_marker()

    try:
        result = subprocess.run(
            ["/bin/ps", "-p", "1", "-o", "lstart="],
            check=False,
            capture_output=True,
            text=True,
            timeout=3,
        )
    except (OSError, subprocess.SubprocessError):
        return ""

    if result.returncode != 0:
        return ""
    return result.stdout.strip()


def _windows_boot_marker() -> str:
    command = [
        "powershell",
        "-NoProfile",
        "-Command",
        "(Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToFileTimeUtc()",
    ]
    try:
        result = run_subprocess_hidden(
            command,
            check=False,
            capture_output=True,
            text=True,
            timeout=5,
        )
    except (OSError, subprocess.SubprocessError):
        return ""

    if result.returncode != 0:
        return ""
    return result.stdout.strip()
