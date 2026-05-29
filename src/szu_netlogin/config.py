"""Configuration loading for the dorm Dr.COM login flow."""

from __future__ import annotations

import ast
import os
import subprocess
import sys
from pathlib import Path
from typing import Any


SOURCE_PROJECT_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_APP_PROJECT_ROOT = Path.home() / "Projects" / "szu-netlogin"
PROJECT_HOME_ENV = "SZU_NETLOGIN_HOME"


def get_project_root() -> Path:
    configured_home = os.environ.get(PROJECT_HOME_ENV)
    if configured_home:
        return Path(configured_home).expanduser().resolve()

    if getattr(sys, "frozen", False):
        return DEFAULT_APP_PROJECT_ROOT

    return SOURCE_PROJECT_ROOT


PROJECT_ROOT = get_project_root()
DEFAULT_CONFIG_PATH = PROJECT_ROOT / "config.yaml"


class ConfigError(ValueError):
    """Raised when config.yaml is missing or not usable."""


def load_config(path: str | Path | None = None) -> dict[str, Any]:
    config_path = Path(path) if path else DEFAULT_CONFIG_PATH
    if not config_path.exists():
        raise ConfigError(
            f"找不到配置文件：{config_path}。请先运行 cp config.example.yaml config.yaml"
        )

    text = config_path.read_text(encoding="utf-8")
    data = _parse_yaml(text)
    validate_config(data)
    return data


def validate_config(config: dict[str, Any]) -> None:
    auth = _section(config, "auth")
    user = _section(config, "user")
    network = _section(config, "network")
    security = _section(config, "security")

    if auth.get("type") != "dorm_drcom":
        raise ConfigError("auth.type 必须是 dorm_drcom。")

    required_auth = (
        "login_url",
        "callback",
        "login_method",
        "account_prefix",
        "timeout_seconds",
    )
    for key in required_auth:
        if auth.get(key) in (None, ""):
            raise ConfigError(f"auth.{key} 不能为空。")

    if not str(auth["login_url"]).startswith("http://"):
        raise ConfigError("auth.login_url 应该使用宿舍区 HTTP 登录地址。")

    logout_url = str(auth.get("logout_url") or "").strip()
    if logout_url and not logout_url.startswith(("http://", "https://")):
        raise ConfigError("auth.logout_url 应该填写 HTTP/HTTPS 退出接口地址，或留空。")

    if user.get("username") in (None, "", "你的校园卡号，不要写密码"):
        raise ConfigError("请在 config.yaml 的 user.username 填写校园卡号。")

    if not isinstance(network.get("test_urls"), list) or not network["test_urls"]:
        raise ConfigError("network.test_urls 至少需要填写一个检测网址。")

    password_source = str(security.get("password_source", "env"))
    if password_source not in ("env", "keychain", "private_file"):
        raise ConfigError("security.password_source 只支持 env、keychain、private_file。")

    if password_source == "env" and not security.get("password_env_name"):
        raise ConfigError("security.password_env_name 不能为空。")

    if password_source == "keychain" and not security.get("keychain_service"):
        raise ConfigError("security.keychain_service 不能为空。")

    if password_source == "private_file" and not security.get("password_file"):
        raise ConfigError("security.password_file 不能为空。")


def get_password_env_name(config: dict[str, Any]) -> str:
    return str(config["security"].get("password_env_name") or "SZU_NET_PASSWORD")


def get_password(config: dict[str, Any]) -> str:
    security = config["security"]
    password_source = str(security.get("password_source", "env"))

    if password_source == "env":
        return os.environ.get(get_password_env_name(config), "")

    if password_source == "keychain":
        return _get_keychain_password(config)

    if password_source == "private_file":
        return _get_private_file_password(config)

    return ""


def describe_password_source(config: dict[str, Any]) -> str:
    security = config["security"]
    password_source = str(security.get("password_source", "env"))
    if password_source == "env":
        return f"环境变量 {get_password_env_name(config)}"
    if password_source == "keychain":
        return f"macOS Keychain 服务 {security.get('keychain_service')}"
    if password_source == "private_file":
        return f"私有密码文件 {security.get('password_file')}"
    return password_source


def _section(config: dict[str, Any], name: str) -> dict[str, Any]:
    section = config.get(name)
    if not isinstance(section, dict):
        raise ConfigError(f"config.yaml 缺少 {name} 配置段。")
    return section


def _get_keychain_password(config: dict[str, Any]) -> str:
    security = config["security"]
    user = config["user"]
    service = str(security["keychain_service"])
    account = str(security.get("keychain_account") or user["username"])

    try:
        result = subprocess.run(
            [
                "/usr/bin/security",
                "find-generic-password",
                "-s",
                service,
                "-a",
                account,
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


def _get_private_file_password(config: dict[str, Any]) -> str:
    password_file = Path(str(config["security"]["password_file"])).expanduser()
    if not password_file.exists():
        return ""

    text = password_file.read_text(encoding="utf-8").strip()
    if not text:
        return ""

    for line in text.splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#") or ":" not in stripped:
            continue
        key, value = stripped.split(":", 1)
        if key.strip() == "password":
            return _strip_quotes(value.strip())

    return text.splitlines()[0].strip()


def _strip_quotes(value: str) -> str:
    if len(value) >= 2 and value[0] in ("'", '"') and value[-1] == value[0]:
        return value[1:-1]
    return value


def _parse_yaml(text: str) -> dict[str, Any]:
    try:
        import yaml  # type: ignore[import-not-found]
    except Exception:
        return _parse_simple_yaml(text)

    loaded = yaml.safe_load(text)
    if not isinstance(loaded, dict):
        raise ConfigError("config.yaml 内容格式不正确。")
    return loaded


def _parse_simple_yaml(text: str) -> dict[str, Any]:
    data: dict[str, Any] = {}
    current_section: str | None = None
    current_list_key: str | None = None

    for line_number, raw_line in enumerate(text.splitlines(), start=1):
        if not raw_line.strip() or raw_line.lstrip().startswith("#"):
            continue

        indent = len(raw_line) - len(raw_line.lstrip(" "))
        stripped = raw_line.strip()

        if indent == 0 and stripped.endswith(":"):
            current_section = stripped[:-1].strip()
            data[current_section] = {}
            current_list_key = None
            continue

        if current_section is None:
            raise ConfigError(f"config.yaml 第 {line_number} 行格式不正确。")

        section = data[current_section]
        if not isinstance(section, dict):
            raise ConfigError(f"config.yaml 第 {line_number} 行格式不正确。")

        if indent == 2:
            if stripped.endswith(":"):
                current_list_key = stripped[:-1].strip()
                section[current_list_key] = []
                continue

            key, value = _split_key_value(stripped, line_number)
            section[key] = _parse_scalar(value)
            current_list_key = None
            continue

        if indent == 4 and stripped.startswith("- ") and current_list_key:
            current_list = section.get(current_list_key)
            if not isinstance(current_list, list):
                raise ConfigError(f"config.yaml 第 {line_number} 行列表格式不正确。")
            current_list.append(_parse_scalar(stripped[2:].strip()))
            continue

        raise ConfigError(f"config.yaml 第 {line_number} 行格式不正确。")

    return data


def _split_key_value(line: str, line_number: int) -> tuple[str, str]:
    if ":" not in line:
        raise ConfigError(f"config.yaml 第 {line_number} 行缺少冒号。")
    key, value = line.split(":", 1)
    return key.strip(), value.strip()


def _parse_scalar(value: str) -> Any:
    if not value:
        return ""

    if value[0] in ("'", '"') and value[-1:] == value[0]:
        try:
            return ast.literal_eval(value)
        except Exception:
            return value[1:-1]

    lower = value.lower()
    if lower == "true":
        return True
    if lower == "false":
        return False
    if lower == "null":
        return None

    try:
        return int(value)
    except ValueError:
        return value
