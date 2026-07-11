"""Password storage helpers backed by config.yaml and macOS Keychain."""

from __future__ import annotations

import json
import os
import subprocess
import tempfile
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
        password = _get_config_password(config_or_username)
        if password:
            return password
        security = config_or_username.get("security") or {}
        if str(security.get("password_source", "env")) == "keychain":
            return _get_private_file_password(config_or_username)
        return ""

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
            try:
                _set_keychain_password(service, account, password)
            except RuntimeError:
                if not str(security.get("password_file") or "").strip():
                    raise
                _set_private_file_password(config_or_username, password)
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
        return bool(get_password(config_or_username))

    username = config_or_username
    return bool(_get_keyring_password(SERVICE_NAME, username) or os.environ.get(PASSWORD_ENV_NAME, ""))


def describe_password_source(config_or_username: dict[str, Any] | str) -> str:
    if isinstance(config_or_username, dict):
        security = config_or_username.get("security") or {}
        if (
            str(security.get("password_source", "env")) == "keychain"
            and _get_private_file_password(config_or_username)
        ):
            return f"私有密码文件 {security.get('password_file')}（钥匙串不可用时回退）"
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
    try:
        keyring = _load_keyring()
        keyring.set_password(service, account, password)
        return
    except Exception as keyring_error:
        try:
            _set_security_password(service, account, password)
            return
        except Exception as security_error:
            raise RuntimeError(
                f"无法保存密码到 macOS 钥匙串：{security_error}"
            ) from keyring_error


def _set_security_password(service: str, account: str, password: str) -> None:
    """Use Apple's signed CLI when a frozen Python keyring client is rejected."""
    try:
        result = subprocess.run(
            [
                "/usr/bin/security",
                "add-generic-password",
                "-U",
                "-a",
                account,
                "-s",
                service,
                "-X",
                password.encode("utf-8").hex(),
            ],
            check=False,
            capture_output=True,
            text=True,
            timeout=8,
        )
    except (OSError, subprocess.SubprocessError) as exc:
        raise RuntimeError(str(exc) or type(exc).__name__) from exc

    if result.returncode != 0:
        detail = (result.stderr or result.stdout).strip()
        raise RuntimeError(detail or f"security 退出码 {result.returncode}")


def _get_private_file_password(config: dict[str, Any]) -> str:
    security = config.get("security") or {}
    password_file_value = str(security.get("password_file") or "").strip()
    if not password_file_value:
        return ""
    password_file = Path(password_file_value).expanduser()
    try:
        text = password_file.read_text(encoding="utf-8").strip()
    except OSError:
        return ""
    if not text:
        return ""
    for line in text.splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#") or ":" not in stripped:
            continue
        key, value = stripped.split(":", 1)
        if key.strip() != "password":
            continue
        try:
            parsed = json.loads(value.strip())
        except json.JSONDecodeError:
            return value.strip().strip("'\"")
        return parsed if isinstance(parsed, str) else str(parsed)
    return text.splitlines()[0].strip()


def _set_private_file_password(config: dict[str, Any], password: str) -> None:
    security = config.get("security") or {}
    password_file_value = str(security.get("password_file") or "").strip()
    if not password_file_value:
        raise ValueError("security.password_file 不能为空。")

    if os.name == "nt":
        raise ValueError("Windows 不支持 private_file 密码来源；请使用系统凭据库。")

    password_file = Path(password_file_value).expanduser()
    password_file.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary_name = tempfile.mkstemp(prefix=f".{password_file.name}.", dir=password_file.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as temporary_file:
            temporary_file.write(f"password: {json.dumps(password, ensure_ascii=False)}\n")
            temporary_file.flush()
            os.fsync(temporary_file.fileno())
        os.chmod(temporary_name, 0o600)
        if os.stat(temporary_name).st_mode & 0o777 != 0o600:
            raise OSError("无法设置密码文件为 0600")
        os.replace(temporary_name, password_file)
    except Exception:
        try:
            os.unlink(temporary_name)
        except FileNotFoundError:
            pass
        raise


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
