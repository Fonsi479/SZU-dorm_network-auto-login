"""Password storage helpers backed by config.yaml and macOS Keychain."""

from __future__ import annotations

import json
import os
import subprocess
from pathlib import Path
from typing import Any

from .config import (
    describe_password_source as _describe_config_password_source,
    get_password as _get_config_password,
)


SERVICE_NAME = "szu-netlogin"
PASSWORD_ENV_NAME = "SZU_NET_PASSWORD"


def get_password(config_or_username: dict[str, Any] | str) -> str:
    if isinstance(config_or_username, dict):
        return _get_config_password(config_or_username)

    username = config_or_username
    password = _get_keyring_password(SERVICE_NAME, username)
    if password:
        return password

    password = os.environ.get(PASSWORD_ENV_NAME, "")
    if password:
        return password

    return ""


def set_password(config_or_username: dict[str, Any] | str, password: str) -> None:
    if isinstance(config_or_username, dict):
        security = config_or_username.get("security") or {}
        password_source = str(security.get("password_source", "env"))

        if password_source == "keychain":
            service, account = _get_keychain_target(config_or_username)
            _set_keychain_password(service, account, password)
            return

        if password_source == "private_file":
            _set_private_file_password(config_or_username, password)
            return

        if password_source == "env":
            env_name = str(security.get("password_env_name") or PASSWORD_ENV_NAME)
            raise ValueError(
                f"当前密码来源是环境变量 {env_name}，本程序不能替父进程持久设置环境变量。"
                "请在 shell/LaunchAgent 中设置它，或把 security.password_source 改为 keychain/private_file。"
            )

        raise ValueError("security.password_source 只支持 env、keychain、private_file。")

    service, account = _get_keychain_target(config_or_username)
    _set_keychain_password(service, account, password)


def has_password(config_or_username: dict[str, Any] | str) -> bool:
    if isinstance(config_or_username, dict):
        return bool(_get_config_password(config_or_username))

    username = config_or_username
    return bool(_get_keyring_password(SERVICE_NAME, username) or os.environ.get(PASSWORD_ENV_NAME, ""))


def describe_password_source(config_or_username: dict[str, Any] | str) -> str:
    if isinstance(config_or_username, dict):
        return _describe_config_password_source(config_or_username)

    return f"系统凭据库服务 {SERVICE_NAME} 或环境变量 {PASSWORD_ENV_NAME}"


def _get_keychain_target(config_or_username: dict[str, Any] | str) -> tuple[str, str]:
    if not isinstance(config_or_username, dict):
        return SERVICE_NAME, config_or_username

    security = config_or_username.get("security") or {}
    user = config_or_username.get("user") or {}
    service = str(security.get("keychain_service") or SERVICE_NAME)
    account = str(security.get("keychain_account") or user.get("username") or "")
    return service, account


def _set_keychain_password(service: str, account: str, password: str) -> None:
    keyring = _load_keyring()
    keyring.set_password(service, account, password)


def _set_private_file_password(config: dict[str, Any], password: str) -> None:
    security = config.get("security") or {}
    password_file_value = str(security.get("password_file") or "").strip()
    if not password_file_value:
        raise ValueError("security.password_file 不能为空。")

    password_file = Path(password_file_value).expanduser()
    password_file.parent.mkdir(parents=True, exist_ok=True)
    password_file.write_text(
        f"password: {json.dumps(password, ensure_ascii=False)}\n",
        encoding="utf-8",
    )
    try:
        os.chmod(password_file, 0o600)
    except OSError:
        pass


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
