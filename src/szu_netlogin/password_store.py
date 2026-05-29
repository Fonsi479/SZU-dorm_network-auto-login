"""Password storage helpers backed by config.yaml and macOS Keychain."""

from __future__ import annotations

import os
import subprocess
from typing import Any

from .config import (
    describe_password_source as _describe_config_password_source,
    get_password as _get_config_password,
)


SERVICE_NAME = "szu-netlogin"
PASSWORD_ENV_NAME = "SZU_NET_PASSWORD"


def get_password(config_or_username: dict[str, Any] | str) -> str:
    if isinstance(config_or_username, dict):
        password = _get_config_password(config_or_username)
        if not password:
            print(f"没有检测到校园网密码。请检查：{describe_password_source(config_or_username)}。")
        return password

    username = config_or_username
    password = _get_keyring_password(SERVICE_NAME, username)
    if password:
        return password

    password = os.environ.get(PASSWORD_ENV_NAME, "")
    if password:
        return password

    print("没有检测到校园网密码。请先运行 set-password 保存到 macOS Keychain，或设置环境变量 SZU_NET_PASSWORD。")
    return ""


def set_password(config_or_username: dict[str, Any] | str, password: str) -> None:
    service, account = _get_keychain_target(config_or_username)
    keyring = _load_keyring()
    keyring.set_password(service, account, password)


def has_password(config_or_username: dict[str, Any] | str) -> bool:
    if isinstance(config_or_username, dict):
        return bool(_get_config_password(config_or_username))

    username = config_or_username
    return bool(_get_keyring_password(SERVICE_NAME, username) or os.environ.get(PASSWORD_ENV_NAME, ""))


def describe_password_source(config_or_username: dict[str, Any] | str) -> str:
    if isinstance(config_or_username, dict):
        return _describe_config_password_source(config_or_username)

    return f"macOS Keychain 服务 {SERVICE_NAME} 或环境变量 {PASSWORD_ENV_NAME}"


def _get_keychain_target(config_or_username: dict[str, Any] | str) -> tuple[str, str]:
    if not isinstance(config_or_username, dict):
        return SERVICE_NAME, config_or_username

    security = config_or_username.get("security") or {}
    user = config_or_username.get("user") or {}
    service = str(security.get("keychain_service") or SERVICE_NAME)
    account = str(security.get("keychain_account") or user.get("username") or "")
    return service, account


def _get_keyring_password(service: str, username: str) -> str:
    try:
        keyring = _load_keyring()
        password = keyring.get_password(service, username) or ""
        return password or _get_security_password(service, username)
    except Exception:
        return _get_security_password(service, username)


def _load_keyring():
    try:
        import keyring  # type: ignore[import-not-found]
    except Exception as exc:
        raise RuntimeError("未安装 keyring，请先运行：pip install keyring") from exc

    return keyring


def _get_security_password(service: str, username: str) -> str:
    try:
        result = subprocess.run(
            [
                "/usr/bin/security",
                "find-generic-password",
                "-s",
                service,
                "-a",
                username,
                "-w",
            ],
            check=False,
            capture_output=True,
            text=True,
            timeout=8,
        )
    except (OSError, subprocess.SubprocessError):
        return ""

    if result.returncode != 0:
        return ""
    return result.stdout.strip()
