"""Configuration loading for the dorm Dr.COM login flow."""

from __future__ import annotations

import ast
import json
import os
import subprocess
import sys
from pathlib import Path
from typing import Any, NamedTuple


SOURCE_PROJECT_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_APP_PROJECT_ROOT = Path.home() / "Projects" / "szu-netlogin"
PROJECT_HOME_ENV = "SZU_NETLOGIN_HOME"


def get_project_root() -> Path:
    configured_home = os.environ.get(PROJECT_HOME_ENV)
    if configured_home:
        return Path(configured_home).expanduser().resolve()

    if getattr(sys, "frozen", False):
        bundled_project_root = _find_project_root_from_executable()
        if bundled_project_root is not None:
            return bundled_project_root
        return DEFAULT_APP_PROJECT_ROOT

    return SOURCE_PROJECT_ROOT


def _find_project_root_from_executable() -> Path | None:
    executable = Path(sys.executable).resolve()
    for candidate in executable.parents:
        if (candidate / "src" / "szu_netlogin" / "config.py").exists():
            return candidate
    return None


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
        try:
            return ast.literal_eval(value)
        except Exception:
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


class _YamlLine(NamedTuple):
    line_number: int
    indent: int
    text: str


def _parse_simple_yaml(text: str) -> dict[str, Any]:
    lines = _prepare_yaml_lines(text)
    data: dict[str, Any] = {}
    stack: list[tuple[int, Any]] = [(-1, data)]

    for index, line in enumerate(lines):
        while len(stack) > 1 and line.indent <= stack[-1][0]:
            stack.pop()

        parent = stack[-1][1]
        if line.text.startswith("- "):
            if not isinstance(parent, list):
                raise ConfigError(f"config.yaml 第 {line.line_number} 行列表格式不正确。")

            item_text = line.text[2:].strip()
            if not item_text:
                child = _new_nested_container(lines, index, line.indent)
                parent.append(child)
                if isinstance(child, (dict, list)):
                    stack.append((line.indent, child))
                continue

            mapping = _try_split_key_value(item_text, line.line_number)
            if mapping is None:
                parent.append(_parse_scalar(item_text))
                continue

            key, value = mapping
            item: dict[str, Any] = {}
            parent.append(item)
            if value:
                item[key] = _parse_scalar(value)
                stack.append((line.indent, item))
                continue

            child = _new_nested_container(lines, index, line.indent)
            item[key] = child
            stack.append((line.indent, item))
            if isinstance(child, (dict, list)):
                stack.append((line.indent + 1, child))
            continue

        if not isinstance(parent, dict):
            raise ConfigError(f"config.yaml 第 {line.line_number} 行格式不正确。")

        key, value = _split_key_value(line.text, line.line_number)
        if not key:
            raise ConfigError(f"config.yaml 第 {line.line_number} 行缺少配置键。")

        if value:
            parent[key] = _parse_scalar(value)
            continue

        child = _new_nested_container(lines, index, line.indent)
        parent[key] = child
        if isinstance(child, (dict, list)):
            stack.append((line.indent, child))

    return data


def _prepare_yaml_lines(text: str) -> list[_YamlLine]:
    lines: list[_YamlLine] = []
    raw_lines = text.splitlines()
    index = 0
    while index < len(raw_lines):
        line_number = index + 1
        raw_line = raw_lines[index]
        leading = raw_line[: len(raw_line) - len(raw_line.lstrip(" \t"))]
        if "\t" in leading:
            raise ConfigError(f"config.yaml 第 {line_number} 行缩进不能使用 Tab。")

        without_comment = _strip_inline_comment(raw_line)
        if not without_comment.strip():
            index += 1
            continue

        indent = len(without_comment) - len(without_comment.lstrip(" "))
        stripped = without_comment.strip()
        block_marker = _block_scalar_marker(stripped)
        if block_marker:
            value, index = _consume_block_scalar(raw_lines, index, indent, block_marker)
            split_at = _find_mapping_colon(stripped)
            key = stripped[:split_at].strip()
            encoded_value = json.dumps(value, ensure_ascii=False)
            lines.append(_YamlLine(line_number, indent, f"{key}: {encoded_value}"))
            continue

        lines.append(_YamlLine(line_number, indent, stripped))
        index += 1
    return lines


def _block_scalar_marker(line: str) -> str:
    split_at = _find_mapping_colon(line)
    if split_at < 0:
        return ""

    value = line[split_at + 1 :].strip()
    if not value or value[0] not in ("|", ">"):
        return ""
    if any(char not in "+-0123456789" for char in value[1:]):
        return ""
    return value[0]


def _consume_block_scalar(
    raw_lines: list[str],
    current_index: int,
    current_indent: int,
    marker: str,
) -> tuple[str, int]:
    content: list[str] = []
    block_indent: int | None = None
    index = current_index + 1

    while index < len(raw_lines):
        raw_line = raw_lines[index]
        leading = raw_line[: len(raw_line) - len(raw_line.lstrip(" \t"))]
        if "\t" in leading:
            raise ConfigError(f"config.yaml 第 {index + 1} 行缩进不能使用 Tab。")

        if not raw_line.strip():
            if block_indent is not None:
                content.append("")
            index += 1
            continue

        indent = len(raw_line) - len(raw_line.lstrip(" "))
        if indent <= current_indent:
            break

        if block_indent is None:
            block_indent = indent
        content.append(raw_line[block_indent:].rstrip())
        index += 1

    if marker == "|":
        return "\n".join(content), index
    return _fold_block_scalar(content), index


def _fold_block_scalar(lines: list[str]) -> str:
    paragraphs: list[str] = []
    current: list[str] = []

    for line in lines:
        if line:
            current.append(line.strip())
            continue

        if current:
            paragraphs.append(" ".join(current))
            current = []
        paragraphs.append("")

    if current:
        paragraphs.append(" ".join(current))
    return "\n".join(paragraphs)


def _strip_inline_comment(line: str) -> str:
    quote: str | None = None
    escaped = False

    for index, char in enumerate(line):
        if quote:
            if quote == '"' and char == "\\" and not escaped:
                escaped = True
                continue
            if char == quote and not escaped:
                quote = None
            escaped = False
            continue

        if char in ("'", '"'):
            quote = char
            continue

        if char == "#" and (index == 0 or line[index - 1].isspace()):
            return line[:index].rstrip()

    return line.rstrip()


def _new_nested_container(
    lines: list[_YamlLine],
    current_index: int,
    current_indent: int,
) -> Any:
    if current_index + 1 >= len(lines):
        return None

    next_line = lines[current_index + 1]
    if next_line.indent <= current_indent:
        return None
    if next_line.text.startswith("- "):
        return []
    return {}


def _split_key_value(line: str, line_number: int) -> tuple[str, str]:
    split_at = _find_mapping_colon(line)
    if split_at < 0:
        raise ConfigError(f"config.yaml 第 {line_number} 行缺少冒号。")
    key, value = line[:split_at], line[split_at + 1 :]
    if key.strip() == "<<":
        raise ConfigError(_unsupported_yaml_feature_message())
    return key.strip(), value.strip()


def _try_split_key_value(line: str, line_number: int) -> tuple[str, str] | None:
    split_at = _find_mapping_colon(line)
    if split_at < 0:
        return None
    key, value = line[:split_at].strip(), line[split_at + 1 :].strip()
    if not key:
        raise ConfigError(f"config.yaml 第 {line_number} 行缺少配置键。")
    if key == "<<":
        raise ConfigError(_unsupported_yaml_feature_message())
    return key, value


def _find_mapping_colon(line: str) -> int:
    quote: str | None = None
    escaped = False
    bracket_depth = 0
    brace_depth = 0

    for index, char in enumerate(line):
        if quote:
            if quote == '"' and char == "\\" and not escaped:
                escaped = True
                continue
            if char == quote and not escaped:
                quote = None
            escaped = False
            continue

        if char in ("'", '"'):
            quote = char
            continue
        if char == "[":
            bracket_depth += 1
            continue
        if char == "]" and bracket_depth:
            bracket_depth -= 1
            continue
        if char == "{":
            brace_depth += 1
            continue
        if char == "}" and brace_depth:
            brace_depth -= 1
            continue
        if char == ":" and bracket_depth == 0 and brace_depth == 0:
            if index + 1 == len(line) or line[index + 1].isspace():
                return index

    return -1


def _parse_scalar(value: str) -> Any:
    if not value:
        return ""

    if value.startswith(("&", "*")):
        raise ConfigError(_unsupported_yaml_feature_message())

    if value.startswith("[") and value.endswith("]"):
        inner = value[1:-1].strip()
        if not inner:
            return []
        return [_parse_scalar(item.strip()) for item in _split_inline_items(inner)]

    if value.startswith("{") and value.endswith("}"):
        inner = value[1:-1].strip()
        if not inner:
            return {}
        parsed: dict[Any, Any] = {}
        for item in _split_inline_items(inner):
            key, item_value = _split_key_value(item.strip(), 0)
            parsed[_parse_inline_key(key)] = _parse_scalar(item_value)
        return parsed

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
        try:
            return float(value)
        except ValueError:
            return value


def _split_inline_items(value: str) -> list[str]:
    items: list[str] = []
    start = 0
    quote: str | None = None
    escaped = False
    bracket_depth = 0
    brace_depth = 0

    for index, char in enumerate(value):
        if quote:
            if quote == '"' and char == "\\" and not escaped:
                escaped = True
                continue
            if char == quote and not escaped:
                quote = None
            escaped = False
            continue

        if char in ("'", '"'):
            quote = char
            continue
        if char == "[":
            bracket_depth += 1
            continue
        if char == "]" and bracket_depth:
            bracket_depth -= 1
            continue
        if char == "{":
            brace_depth += 1
            continue
        if char == "}" and brace_depth:
            brace_depth -= 1
            continue
        if char == "," and bracket_depth == 0 and brace_depth == 0:
            items.append(value[start:index].strip())
            start = index + 1

    items.append(value[start:].strip())
    return [item for item in items if item]


def _parse_inline_key(value: str) -> Any:
    stripped = value.strip()
    if stripped == "<<":
        raise ConfigError(_unsupported_yaml_feature_message())
    if stripped and stripped[0] in ("'", '"') and stripped[-1:] == stripped[0]:
        return _parse_scalar(stripped)
    return stripped


def _unsupported_yaml_feature_message() -> str:
    return "内置 YAML 解析器不支持 YAML 锚点、别名或 merge key；请安装 PyYAML，或改用简单配置。"
