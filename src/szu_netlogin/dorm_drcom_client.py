"""Dorm-area Dr.COM / ePortal login client for Shenzhen University."""

from __future__ import annotations

import json
import re
import socket
from dataclasses import dataclass
from typing import Any
from typing import Literal
from urllib.parse import urlparse, urlunparse

import requests

from .logger import get_logger, redact_sensitive_text

LogoutStatus = Literal["success", "failed", "unknown"]


@dataclass(frozen=True)
class LogoutResult:
    status: LogoutStatus
    reason: str = ""


class DormDrcomClient:
    """Client for the dorm Dr.COM login GET endpoint."""

    def __init__(self, config: dict[str, Any]) -> None:
        self.config = config
        self.auth = config["auth"]
        self.session = requests.Session()
        self.session.trust_env = False
        self.logger = get_logger()

    def build_login_params(self, username: str, password: str) -> dict[str, str]:
        return {
            "callback": str(self.auth["callback"]),
            "login_method": str(self.auth["login_method"]),
            "user_account": f"{self.auth['account_prefix']}{username}",
            "user_password": password,
        }

    def build_logout_params(self, username: str) -> dict[str, str]:
        params = {
            "callback": str(self.auth.get("logout_callback") or "dr1004"),
            "login_method": str(self.auth["login_method"]),
            "user_account": f"{self.auth['account_prefix']}{username}",
        }

        source_ip = _get_source_ip(str(self.auth["login_url"]), int(self.auth["timeout_seconds"]))
        if source_ip:
            params["wlan_user_ip"] = source_ip
        return params

    def login(self, username: str, password: str) -> bool | None:
        params = self.build_login_params(username, password)
        timeout_seconds = int(self.auth["timeout_seconds"])

        try:
            response = self.session.get(
                str(self.auth["login_url"]),
                params=params,
                timeout=timeout_seconds,
                headers={
                    "User-Agent": _user_agent(),
                    "Referer": "http://172.30.255.42:801/",
                },
            )
        except requests.RequestException as exc:
            self.logger.error(
                "宿舍区 Dr.COM 登录请求异常：type=%s reason=%s",
                type(exc).__name__,
                redact_sensitive_text(str(exc).replace("\n", " ")[:160], password),
            )
            return False

        preview = redact_sensitive_text(response.text[:200], password)
        self.logger.info("宿舍区 Dr.COM 登录请求完成：请求成功=True")
        self.logger.info("宿舍区 Dr.COM 登录 HTTP 状态码=%s", response.status_code)
        self.logger.info("宿舍区 Dr.COM 登录响应前 200 字=%s", preview)

        if response.status_code >= 500:
            self.logger.info("宿舍区 Dr.COM 登录判断结果：不确定")
            return None

        if not 200 <= response.status_code < 300:
            self.logger.info("宿舍区 Dr.COM 登录判断结果：失败")
            return False

        parsed = self.parse_jsonp_response(response.text)
        result = self.is_success_response(parsed)
        self.logger.info("宿舍区 Dr.COM 登录判断结果：%s", _result_label(result))
        return result

    def logout(self, username: str) -> LogoutResult:
        logout_url = self._get_logout_url()
        if not logout_url:
            self.logger.info("宿舍区 Dr.COM 退出接口未配置，且无法从 login_url 推导")
            return LogoutResult("failed", "logout_url_not_configured")

        if not logout_url.startswith(("http://", "https://")):
            self.logger.info("宿舍区 Dr.COM 退出接口配置无效：auth.logout_url 不是 HTTP 地址")
            return LogoutResult("failed", "logout_url_invalid")

        params = self.build_logout_params(username)
        timeout_seconds = int(self.auth["timeout_seconds"])

        try:
            response = self.session.get(
                logout_url,
                params=params,
                timeout=timeout_seconds,
                headers={
                    "User-Agent": _user_agent(),
                    "Referer": "http://172.30.255.42:801/",
                },
            )
        except requests.RequestException as exc:
            self.logger.error(
                "宿舍区 Dr.COM 退出请求异常：type=%s reason=%s",
                type(exc).__name__,
                _safe_exception_summary(exc),
            )
            return LogoutResult("failed", "request_exception")

        preview = redact_sensitive_text(response.text[:200])
        self.logger.info("宿舍区 Dr.COM 退出请求完成：请求成功=True")
        self.logger.info("宿舍区 Dr.COM 退出 HTTP 状态码=%s", response.status_code)
        self.logger.info("宿舍区 Dr.COM 退出响应前 200 字=%s", preview)

        if response.status_code >= 500:
            self.logger.info("宿舍区 Dr.COM 退出判断结果：不确定")
            return LogoutResult("unknown", f"http_status_{response.status_code}")

        if not 200 <= response.status_code < 300:
            self.logger.info("宿舍区 Dr.COM 退出判断结果：失败")
            return LogoutResult("failed", f"http_status_{response.status_code}")

        parsed = self.parse_jsonp_response(response.text)
        result = self.is_success_response(parsed)
        self.logger.info("宿舍区 Dr.COM 退出判断结果：%s", _result_label(result))

        if result is True:
            return LogoutResult("success", "server_success")
        if result is False:
            return LogoutResult("failed", "server_failed")
        return LogoutResult("unknown", "server_unknown")

    def _get_logout_url(self) -> str:
        configured_url = str(self.auth.get("logout_url") or "").strip()
        if configured_url:
            return configured_url

        login_url = str(self.auth.get("login_url") or "").strip()
        parsed = urlparse(login_url)
        if not parsed.scheme or not parsed.netloc:
            return ""

        path = parsed.path.rstrip("/")
        if not path.endswith("/login"):
            return ""

        logout_path = f"{path.removesuffix('/login')}/logout"
        inferred_url = urlunparse(parsed._replace(path=logout_path, query="", fragment=""))
        self.logger.info("宿舍区 Dr.COM 退出接口未显式配置，已从 login_url 推导：%s", inferred_url)
        return inferred_url

    def parse_jsonp_response(self, text: str) -> Any:
        stripped = text.strip()
        jsonp_match = re.fullmatch(r"[\w.$]+\((.*)\)\s*;?", stripped, flags=re.S)
        payload = jsonp_match.group(1).strip() if jsonp_match else stripped

        try:
            return json.loads(payload)
        except json.JSONDecodeError:
            return stripped

    def is_success_response(self, parsed_or_text: Any) -> bool | None:
        if isinstance(parsed_or_text, dict):
            values = {
                str(key).lower(): value for key, value in parsed_or_text.items()
            }
            message = " ".join(str(value) for value in values.values())

            if _contains_failure(message):
                return False
            if _contains_success(message):
                return True

            for key in ("success", "result", "ret_code", "code"):
                if key not in values:
                    continue
                value = values[key]
                if isinstance(value, bool):
                    return value
                normalized = str(value).strip().lower()
                if normalized in ("1", "true", "ok", "success"):
                    return True
                if normalized in ("0", "false", "fail", "failed", "error", "-1"):
                    return False

            return None

        text = str(parsed_or_text)
        if _contains_failure(text):
            return False
        if _contains_success(text):
            return True
        return None

def _contains_success(text: str) -> bool:
    lowered = text.lower()
    success_words = (
        "success",
        "login_ok",
        "logout_ok",
        "认证成功",
        "登录成功",
        "登陆成功",
        "注销成功",
        "下线成功",
        "退出成功",
        "已经在线",
        "已在线",
        "online",
    )
    return any(word in lowered for word in success_words)


def _contains_failure(text: str) -> bool:
    lowered = text.lower()
    failure_words = (
        "fail",
        "failed",
        "error",
        "认证失败",
        "登录失败",
        "登陆失败",
        "注销失败",
        "下线失败",
        "不在线",
        "页面已过期",
        "密码",
        "欠费",
        "不存在",
        "错误",
    )
    return any(word in lowered for word in failure_words)


def _get_source_ip(url: str, timeout_seconds: int) -> str:
    parsed = urlparse(url)
    host = parsed.hostname
    port = parsed.port or (443 if parsed.scheme == "https" else 80)
    if not host:
        return ""

    try:
        with socket.create_connection((host, port), timeout=timeout_seconds) as sock:
            return str(sock.getsockname()[0])
    except OSError:
        return ""


def _result_label(result: bool | None) -> str:
    if result is True:
        return "成功"
    if result is False:
        return "失败"
    return "不确定"


def _safe_exception_summary(exc: requests.RequestException, password: str = "") -> str:
    text = str(exc).replace("\n", " ")[:160]
    text = redact_sensitive_text(text, password)
    text = re.sub(r"(?i)https?://[^\s)]+", "[url_redacted]", text)
    text = re.sub(r"(?i)(cookie\s*[:=]\s*)[^\s;]+", r"\1***", text)
    return text


def _user_agent() -> str:
    return (
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
        "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0 Safari/537.36"
    )
