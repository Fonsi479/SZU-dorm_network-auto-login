"""Dorm-area Dr.COM / ePortal login client for Shenzhen University."""

from __future__ import annotations

import json
import re
import socket
import subprocess
from dataclasses import dataclass
from ipaddress import IPv4Address, AddressValueError
from typing import Any, Literal
from urllib.parse import parse_qs, urlparse, urlunparse

import requests

from .logger import get_logger, redact_sensitive_text
from .portal_detect import SourceAddressAdapter

LoginStatus = Literal["success", "failed", "unknown"]
LogoutStatus = Literal["success", "failed", "unknown"]
USER_AGENT = (
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
    "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0 Safari/537.36"
)


@dataclass(frozen=True)
class LoginResult:
    status: LoginStatus
    reason: str = ""
    http_status: int = 0
    source_ip: str = ""

    @property
    def ok(self) -> bool:
        return self.status == "success"


@dataclass(frozen=True)
class LogoutResult:
    status: LogoutStatus
    reason: str = ""


@dataclass(frozen=True)
class PortalTerminalParams:
    ip: str = ""
    mac: str = "000000000000"
    vlan: str = "0"
    wlan_ac_ip: str = ""
    wlan_ac_name: str = ""
    js_version: str = "4.1.3"
    page_url: str = ""


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

    def build_unbind_params(
        self,
        username: str,
        terminal: PortalTerminalParams | None = None,
    ) -> dict[str, str]:
        terminal = terminal or self.discover_logout_terminal_params(username)
        return {
            "callback": str(self.auth.get("unbind_callback") or self.auth.get("callback") or "dr1003"),
            "user_account": username,
            "wlan_user_mac": terminal.mac,
            "wlan_user_ip": _ip_to_parse_int(terminal.ip),
            "jsVersion": terminal.js_version,
        }

    def build_logout_params(
        self,
        username: str,
        terminal: PortalTerminalParams | None = None,
    ) -> dict[str, str]:
        terminal = terminal or self.discover_logout_terminal_params(username)
        return {
            "callback": str(self.auth.get("logout_callback") or "dr1004"),
            "login_method": str(self.auth["login_method"]),
            "user_account": str(self.auth.get("logout_user_account") or "drcom"),
            "user_password": str(self.auth.get("logout_user_password") or "123"),
            "ac_logout": str(self.auth.get("logout_ac_logout") or "0"),
            "register_mode": str(self.auth.get("logout_register_mode") or "1"),
            "wlan_user_ip": terminal.ip,
            "wlan_user_ipv6": "",
            "wlan_vlan_id": terminal.vlan,
            "wlan_user_mac": terminal.mac,
            "wlan_ac_ip": terminal.wlan_ac_ip,
            "wlan_ac_name": terminal.wlan_ac_name,
            "jsVersion": terminal.js_version,
        }

    def login(self, username: str, password: str) -> bool | None:
        result = self.login_with_result(username, password)
        if result.status == "success":
            return True
        if result.status == "failed":
            return False
        return None

    def login_with_result(self, username: str, password: str) -> LoginResult:
        params = self.build_login_params(username, password)
        timeout_seconds = int(self.auth["timeout_seconds"])
        source_ip = _get_source_ip(str(self.auth["login_url"]), timeout_seconds)
        if source_ip:
            params["wlan_user_ip"] = source_ip
            _add_terminal_mac_param(params, source_ip, self.logger)
            adapter = SourceAddressAdapter(source_ip)
            self.session.mount("http://", adapter)
            self.session.mount("https://", adapter)

        try:
            response = self.session.get(
                str(self.auth["login_url"]),
                params=params,
                timeout=timeout_seconds,
                headers={
                    "User-Agent": USER_AGENT,
                    "Referer": "http://172.30.255.42:801/",
                },
            )
        except requests.RequestException as exc:
            self.logger.error(
                "宿舍区 Dr.COM 登录请求异常：type=%s reason=%s",
                type(exc).__name__,
                redact_sensitive_text(str(exc).replace("\n", " ")[:160], password),
            )
            return LoginResult(
                "failed",
                _login_request_exception_reason(exc),
                source_ip=source_ip,
            )

        preview = redact_sensitive_text(response.text[:200], password)
        self.logger.info("宿舍区 Dr.COM 登录请求完成：请求成功=True")
        self.logger.info("宿舍区 Dr.COM 登录 HTTP 状态码=%s", response.status_code)
        self.logger.info("宿舍区 Dr.COM 登录响应前 200 字=%s", preview)

        if response.status_code >= 500:
            self.logger.info("宿舍区 Dr.COM 登录判断结果：不确定")
            return LoginResult(
                "unknown",
                "server_response_uncertain",
                http_status=response.status_code,
                source_ip=source_ip,
            )

        if not 200 <= response.status_code < 300:
            self.logger.info("宿舍区 Dr.COM 登录判断结果：失败")
            return LoginResult(
                "failed",
                "portal_interface_changed",
                http_status=response.status_code,
                source_ip=source_ip,
            )

        parsed = self.parse_jsonp_response(response.text)
        result = self.is_success_response(parsed)
        self.logger.info("宿舍区 Dr.COM 登录判断结果：%s", _result_label(result))
        if result is True:
            return LoginResult(
                "success",
                "server_success",
                http_status=response.status_code,
                source_ip=source_ip,
            )
        if result is False:
            return LoginResult(
                "failed",
                _classify_failed_login_response(parsed),
                http_status=response.status_code,
                source_ip=source_ip,
            )
        return LoginResult(
            "unknown",
            "portal_interface_changed",
            http_status=response.status_code,
            source_ip=source_ip,
        )

    def logout(self, username: str) -> LogoutResult:
        logout_url = self._get_logout_url()
        if not logout_url:
            self.logger.info("宿舍区 Dr.COM 退出接口未配置，且无法从 login_url 推导")
            return LogoutResult("failed", "logout_url_not_configured")

        if not logout_url.startswith(("http://", "https://")):
            self.logger.info("宿舍区 Dr.COM 退出接口配置无效：auth.logout_url 不是 HTTP 地址")
            return LogoutResult("failed", "logout_url_invalid")

        timeout_seconds = int(self.auth["timeout_seconds"])
        source_ip = _get_source_ip(logout_url, timeout_seconds)
        if source_ip:
            adapter = SourceAddressAdapter(source_ip)
            self.session.mount("http://", adapter)
            self.session.mount("https://", adapter)

        terminal = self.discover_logout_terminal_params(username, source_ip=source_ip)
        self.logger.info(
            "宿舍区 Dr.COM 退出终端参数：ip=%s mac=%s vlan=%s ac_ip=%s page_url=%s",
            terminal.ip,
            terminal.mac,
            terminal.vlan,
            terminal.wlan_ac_ip,
            terminal.page_url,
        )
        if not terminal.ip:
            self.logger.info("宿舍区 Dr.COM 退出失败：无法确定当前终端 IP")
            return LogoutResult("failed", "terminal_ip_not_found")

        unbind_url = self._get_unbind_url(logout_url)
        unbind_params = self.build_unbind_params(username, terminal)
        self._request_logout_unbind(unbind_url, unbind_params, timeout_seconds)

        params = self.build_logout_params(username, terminal)

        try:
            response = self.session.get(
                logout_url,
                params=params,
                timeout=timeout_seconds,
                headers=self._portal_headers(terminal.page_url),
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

        if result is True:
            self.logger.info("宿舍区 Dr.COM 退出判断结果：成功")
            return LogoutResult("success", "server_success")

        if result is False:
            if self.is_inactive_logout_response(parsed):
                self.logger.info("宿舍区 Dr.COM 退出判断结果：已无可注销会话")
                return LogoutResult("success", "already_logged_out")

            self.logger.info("宿舍区 Dr.COM 退出判断结果：失败")
            return LogoutResult("failed", "server_failed")

        self.logger.info("宿舍区 Dr.COM 退出判断结果：不确定")
        return LogoutResult("unknown", "server_unknown")

    def discover_logout_terminal_params(
        self,
        username: str,
        source_ip: str = "",
    ) -> PortalTerminalParams:
        page_url = self._get_logout_page_url()
        page_text = self._fetch_logout_page(page_url)
        online_record = self._fetch_online_record(username)
        source_mac = ""
        if source_ip:
            source_mac = _get_terminal_mac_for_ip(source_ip)

        return _build_portal_terminal_params(
            page_url=page_url,
            page_text=page_text,
            online_record=online_record,
            source_ip=source_ip,
            source_mac=source_mac,
            js_version=str(self.auth.get("logout_js_version") or self.auth.get("js_version") or "4.1.3"),
        )

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

    def _get_unbind_url(self, logout_url: str) -> str:
        configured_url = str(self.auth.get("unbind_url") or "").strip()
        if configured_url:
            return configured_url

        parsed = urlparse(logout_url)
        if not parsed.scheme or not parsed.netloc:
            return ""

        path = parsed.path.rstrip("/")
        if path.endswith("/logout"):
            unbind_path = f"{path.removesuffix('/logout')}/mac/unbind"
            return urlunparse(parsed._replace(path=unbind_path, query="", fragment=""))

        return ""

    def _get_logout_page_url(self) -> str:
        configured_url = str(self.auth.get("logout_page_url") or "").strip()
        if configured_url:
            return configured_url

        login_url = str(self.auth.get("login_url") or "").strip()
        parsed = urlparse(login_url)
        if not parsed.scheme or not parsed.hostname:
            return ""

        return urlunparse((parsed.scheme, parsed.hostname, "/a79.htm", "", "", ""))

    def _fetch_logout_page(self, page_url: str) -> str:
        if not page_url:
            return ""

        try:
            response = self.session.get(
                page_url,
                timeout=int(self.auth["timeout_seconds"]),
                headers=self._portal_headers(page_url),
            )
        except requests.RequestException as exc:
            self.logger.info(
                "宿舍区 Dr.COM 退出页参数获取失败：type=%s reason=%s",
                type(exc).__name__,
                _safe_exception_summary(exc),
            )
            return ""

        if not 200 <= response.status_code < 300:
            self.logger.info("宿舍区 Dr.COM 退出页参数获取失败：HTTP 状态码=%s", response.status_code)
            return ""

        return response.text

    def _fetch_online_record(self, username: str) -> dict[str, Any]:
        portal_api = self._get_portal_api_url()
        if not portal_api:
            return {}

        try:
            response = self.session.get(
                f"{portal_api}online_list",
                params={"callback": "dr9999"},
                timeout=int(self.auth["timeout_seconds"]),
                headers=self._portal_headers(self._get_logout_page_url()),
            )
        except requests.RequestException as exc:
            self.logger.info(
                "宿舍区 Dr.COM 在线列表获取失败：type=%s reason=%s",
                type(exc).__name__,
                _safe_exception_summary(exc),
            )
            return {}

        if not 200 <= response.status_code < 300:
            self.logger.info("宿舍区 Dr.COM 在线列表获取失败：HTTP 状态码=%s", response.status_code)
            return {}

        parsed = self.parse_jsonp_response(response.text)
        record = _select_online_record(parsed, username)
        if record:
            self.logger.info(
                "宿舍区 Dr.COM 在线列表命中当前会话：online_ip=%s online_mac=%s nas_ip=%s",
                record.get("online_ip"),
                record.get("online_mac"),
                record.get("nas_ip"),
            )
        return record

    def _get_portal_api_url(self) -> str:
        login_url = str(self.auth.get("login_url") or "").strip()
        parsed = urlparse(login_url)
        if not parsed.scheme or not parsed.netloc:
            return ""

        path = parsed.path.rstrip("/")
        if path.endswith("/login"):
            api_path = f"{path.removesuffix('/login')}/"
            return urlunparse(parsed._replace(path=api_path, query="", fragment=""))

        if path.endswith("/"):
            return urlunparse(parsed._replace(query="", fragment=""))

        return ""

    def _portal_headers(self, page_url: str = "") -> dict[str, str]:
        referer = _portal_referer(page_url or self._get_logout_page_url() or str(self.auth.get("login_url") or ""))
        return {"User-Agent": USER_AGENT, "Referer": referer}

    def _request_logout_unbind(
        self,
        unbind_url: str,
        params: dict[str, str],
        timeout_seconds: int,
    ) -> None:
        if not unbind_url:
            self.logger.info("宿舍区 Dr.COM MAC 解绑接口无法从 logout_url 推导，跳过 unbind")
            return

        try:
            response = self.session.get(
                unbind_url,
                params=params,
                timeout=timeout_seconds,
                headers=self._portal_headers(),
            )
        except requests.RequestException as exc:
            self.logger.info(
                "宿舍区 Dr.COM MAC 解绑请求异常，继续尝试退出：type=%s reason=%s",
                type(exc).__name__,
                _safe_exception_summary(exc),
            )
            return

        preview = redact_sensitive_text(response.text[:200])
        self.logger.info("宿舍区 Dr.COM MAC 解绑 HTTP 状态码=%s", response.status_code)
        self.logger.info("宿舍区 Dr.COM MAC 解绑响应前 200 字=%s", preview)

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

            if _contains_password_error(message):
                return False
            if _contains_existing_session_success(message):
                return True

            for key in ("success", "result", "ret_code", "code"):
                if key not in values:
                    continue
                result = _parse_result_value(values[key])
                if result is not None:
                    return result

            if _contains_failure(message):
                return False
            if _contains_success(message):
                return True

            return None

        text = str(parsed_or_text)
        if _contains_failure(text):
            return False
        if _contains_success(text):
            return True
        return None

    def is_inactive_logout_response(self, parsed_or_text: Any) -> bool:
        if isinstance(parsed_or_text, dict):
            values = {
                str(key).lower(): value for key, value in parsed_or_text.items()
            }
            message = " ".join(str(value) for value in values.values())
            result_value = values.get("result", values.get("ret_code", values.get("code")))
            result = _parse_result_value(result_value)
            return result is not True and _contains_inactive_logout_message(message)

        return _contains_inactive_logout_message(str(parsed_or_text))


def _build_portal_terminal_params(
    page_url: str,
    page_text: str,
    online_record: dict[str, Any],
    source_ip: str,
    source_mac: str,
    js_version: str,
) -> PortalTerminalParams:
    query = _parse_url_query(page_url)
    page_vars = _parse_portal_page_vars(page_text)

    page_ip = (
        _first_query_value(query, _IP_QUERY_NAMES)
        or _normalize_ip(page_vars.get("v46ip", ""))
        or _normalize_ip(page_vars.get("ss5", ""))
        or _normalize_ip(page_vars.get("v4ip", ""))
        or _hex_ip_to_dotted(page_vars.get("ss3", ""))
    )
    online_ip = _normalize_ip(str(online_record.get("online_ip") or ""))
    terminal_ip = online_ip or page_ip or _normalize_ip(source_ip)

    page_mac = (
        _normalize_mac(_first_query_value(query, _MAC_QUERY_NAMES))
        or _normalize_mac(page_vars.get("ss4", ""))
        or _normalize_mac(page_vars.get("olmac", ""))
    )
    fallback_mac = _normalize_mac(str(online_record.get("online_mac") or "")) or source_mac
    terminal_mac = page_mac or fallback_mac or "000000000000"

    terminal_vlan = (
        _first_query_value(query, ("vlan", "vlanid"))
        or str(page_vars.get("vlanid") or "").strip()
        or "0"
    )
    terminal_ac_ip = (
        _first_query_value(query, _AC_IP_QUERY_NAMES)
        or _nas_ip_to_dotted(online_record.get("nas_ip"))
    )
    terminal_ac_name = _first_query_value(query, _AC_NAME_QUERY_NAMES)

    return PortalTerminalParams(
        ip=terminal_ip,
        mac=terminal_mac,
        vlan=terminal_vlan,
        wlan_ac_ip=terminal_ac_ip,
        wlan_ac_name=terminal_ac_name,
        js_version=js_version or "4.1.3",
        page_url=page_url,
    )


_IP_QUERY_NAMES = (
    "ip",
    "wlanuserip",
    "userip",
    "user-ip",
    "client_ip",
    "UserIP",
    "uip",
    "station_ip",
)
_MAC_QUERY_NAMES = (
    "mac",
    "usermac",
    "wlanusermac",
    "umac",
    "client_mac",
    "station_mac",
)
_AC_IP_QUERY_NAMES = ("wlanacip", "acip", "switchip", "nasip", "nas-ip")
_AC_NAME_QUERY_NAMES = ("wlanacname", "sysname", "nasname", "nas-name")
_PORTAL_VAR_RE = re.compile(
    r"\b(?P<name>v46ip|ss5|v4ip|ss3|ss4|olmac|vlanid)\s*=\s*"
    r"(?P<value>'[^']*'|\"[^\"]*\"|[^;,\s]+)"
)


def _parse_url_query(url: str) -> dict[str, list[str]]:
    parsed = urlparse(url)
    return parse_qs(parsed.query, keep_blank_values=True)


def _first_query_value(query: dict[str, list[str]], names: tuple[str, ...]) -> str:
    for name in names:
        values = query.get(name)
        if not values:
            continue
        value = values[0].strip()
        if value:
            return value
    return ""


def _parse_portal_page_vars(text: str) -> dict[str, str]:
    vars_: dict[str, str] = {}
    for match in _PORTAL_VAR_RE.finditer(text):
        raw_value = match.group("value").strip()
        if len(raw_value) >= 2 and raw_value[0] in ("'", '"') and raw_value[-1] == raw_value[0]:
            raw_value = raw_value[1:-1]
        vars_[match.group("name")] = raw_value.strip()
    return vars_


def _select_online_record(parsed: Any, username: str) -> dict[str, Any]:
    if not isinstance(parsed, dict):
        return {}

    records = parsed.get("list")
    if not isinstance(records, list):
        return {}

    dict_records = [record for record in records if isinstance(record, dict)]
    if not dict_records:
        return {}

    username = str(username)
    for record in dict_records:
        if str(record.get("user_account") or "") == username and str(record.get("is_owner_ip") or "") == "1":
            return record

    for record in dict_records:
        if str(record.get("is_owner_ip") or "") == "1":
            return record

    for record in dict_records:
        if str(record.get("user_account") or "") == username:
            return record

    return dict_records[0]


def _ip_to_parse_int(ip: str) -> str:
    normalized = _normalize_ip(ip)
    if not normalized:
        return "0"
    return str(int(IPv4Address(normalized)))


def _nas_ip_to_dotted(value: Any) -> str:
    if value in (None, ""):
        return ""

    try:
        number = int(str(value))
        if number < 0 or number > 0xFFFFFFFF:
            return ""
        return str(IPv4Address(number.to_bytes(4, "little")))
    except (ValueError, OverflowError, AddressValueError):
        return ""


def _hex_ip_to_dotted(value: str) -> str:
    normalized = re.sub(r"[^0-9A-Fa-f]", "", value)
    if len(normalized) != 8:
        return ""

    try:
        return ".".join(str(int(normalized[index : index + 2], 16)) for index in range(0, 8, 2))
    except ValueError:
        return ""


def _normalize_ip(value: str) -> str:
    candidate = value.strip()
    if not candidate:
        return ""
    try:
        return str(IPv4Address(candidate))
    except AddressValueError:
        return ""


def _portal_referer(url: str) -> str:
    parsed = urlparse(url)
    if not parsed.scheme or not parsed.netloc:
        return "http://172.30.255.42/"
    return urlunparse(parsed._replace(path="/", params="", query="", fragment=""))


def _parse_result_value(value: Any) -> bool | None:
    if value is None:
        return None
    if isinstance(value, bool):
        return value

    normalized = str(value).strip().lower()
    if normalized in ("1", "true", "ok", "success"):
        return True
    if _is_negative_result(value):
        return False
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
        "已登录",
        "已登陆",
        "logged in",
        "online",
    )
    return any(word in lowered for word in success_words)


def _contains_existing_session_success(text: str) -> bool:
    lowered = text.lower()
    success_words = (
        "已经在线",
        "已在线",
        "already online",
        "already logged in",
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
        "not online",
        "not logged in",
        "页面已过期",
        "欠费",
        "不存在",
        "错误",
    )
    return any(word in lowered for word in failure_words)


def _contains_password_error(text: str) -> bool:
    lowered = text.lower()
    password_words = (
        "password",
        "passwd",
        "密码",
        "口令",
    )
    error_words = (
        "wrong",
        "incorrect",
        "invalid",
        "error",
        "错误",
        "不正确",
        "不匹配",
        "失败",
    )
    return any(word in lowered for word in password_words) and any(
        word in lowered for word in error_words
    )


def _contains_inactive_logout_message(text: str) -> bool:
    lowered = text.lower()
    inactive_words = (
        "不在线",
        "未在线",
        "未登录",
        "未登陆",
        "没有登录",
        "没有登陆",
        "no active",
        "no session",
        "not online",
        "not logged in",
        "already logged out",
    )
    return any(word in lowered for word in inactive_words)


def _is_negative_result(value: Any) -> bool:
    if isinstance(value, bool):
        return not value
    normalized = str(value).strip().lower()
    return normalized in (
        "0",
        "false",
        "fail",
        "failed",
        "error",
        "-1",
        "offline",
        "inactive",
        "not_online",
        "not online",
        "not_logged_in",
        "not logged in",
        "already_logged_out",
        "already logged out",
    )


def _classify_failed_login_response(parsed_or_text: Any) -> str:
    text = _response_text_for_classification(parsed_or_text)
    if _contains_password_error(text):
        return "password_error"
    return "server_failed"


def _response_text_for_classification(parsed_or_text: Any) -> str:
    if isinstance(parsed_or_text, dict):
        return " ".join(str(value) for value in parsed_or_text.values())
    return str(parsed_or_text)


def _login_request_exception_reason(exc: requests.RequestException) -> str:
    if isinstance(exc, (requests.Timeout, requests.ConnectionError)):
        return "gateway_unreachable"
    return "request_exception"


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


def _add_terminal_mac_param(params: dict[str, str], source_ip: str, logger: Any) -> None:
    mac = _get_terminal_mac_for_ip(source_ip)
    if mac:
        params["wlan_user_mac"] = mac
    else:
        logger.info("宿舍区 Dr.COM 参数未能获取终端 MAC 地址：source_ip=%s", source_ip)


def _get_terminal_mac_for_ip(source_ip: str) -> str:
    try:
        result = subprocess.run(
            ["/sbin/ifconfig"],
            check=False,
            capture_output=True,
            text=True,
            timeout=3,
        )
    except (OSError, subprocess.SubprocessError):
        return ""

    if result.returncode != 0:
        return ""

    return _parse_ifconfig_mac_for_ip(result.stdout, source_ip)


def _parse_ifconfig_mac_for_ip(ifconfig_output: str, source_ip: str) -> str:
    current_ips: list[str] = []
    current_mac = ""

    for line in ifconfig_output.splitlines():
        interface_match = re.match(r"^\S+:", line)
        if interface_match:
            matched_mac = _mac_for_interface_block(current_ips, current_mac, source_ip)
            if matched_mac:
                return matched_mac
            current_ips = []
            current_mac = ""
            continue

        stripped = line.strip()
        if stripped.startswith("ether "):
            parts = stripped.split()
            if len(parts) >= 2:
                current_mac = _normalize_mac(parts[1])
        elif stripped.startswith("inet "):
            parts = stripped.split()
            if len(parts) >= 2:
                current_ips.append(parts[1])

    return _mac_for_interface_block(current_ips, current_mac, source_ip)


def _mac_for_interface_block(ips: list[str], mac: str, source_ip: str) -> str:
    if source_ip in ips:
        return mac
    return ""


def _normalize_mac(value: str) -> str:
    normalized = re.sub(r"[^0-9A-Fa-f]", "", value).lower()
    if len(normalized) == 12:
        return normalized
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
