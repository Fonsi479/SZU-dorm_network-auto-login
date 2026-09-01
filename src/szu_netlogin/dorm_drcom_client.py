"""Dorm-area Dr.COM / ePortal login client for Shenzhen University."""

from __future__ import annotations

import json
import re
import socket
import time
from dataclasses import dataclass
from ipaddress import IPv4Address, AddressValueError
from typing import Any, Literal
from urllib.parse import parse_qs, urlparse, urlunparse

import requests

from .config import ConfigError, normalize_gateway_host, validate_portal_endpoint
from .logger import get_logger, redact_sensitive_text
from .portal_detect import SourceAddressAdapter, is_campus_source_ip

LoginStatus = Literal["success", "failed", "unknown"]
LogoutStatus = Literal["success", "failed", "unknown"]
PortalSessionState = Literal["online", "offline", "unknown"]
USER_AGENT = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
    "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0 Safari/537.36"
)
DORM_ONLINE_DEVICE_LIMIT = 3


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


@dataclass(frozen=True)
class PortalStatusResult:
    readable: bool = False
    declared_online: bool | None = None
    account: str = ""
    ip: str = ""
    mac: str = ""
    vlan: str = "0"
    wlan_ac_ip: str = ""
    wlan_ac_name: str = ""


@dataclass(frozen=True)
class PortalOnlineListResult:
    readable: bool = False
    exact_record: dict[str, Any] | None = None
    # Raw records are retained only inside the client for logout compatibility;
    # callers receive the aggregate count below and never device identities.
    account_records: tuple[dict[str, Any], ...] = ()
    device_count: int | None = None
    count_reliable: bool = False


@dataclass(frozen=True)
class PortalSessionFact:
    state: PortalSessionState = "unknown"
    account: str = ""
    ip: str = ""
    mac: str = ""
    vlan: str = "0"
    wlan_ac_ip: str = ""
    wlan_ac_name: str = ""
    status_was_readable: bool = False
    online_list_was_readable: bool = False
    exact_online_record_present: bool | None = None
    online_device_count: int | None = None
    online_device_limit: int = DORM_ONLINE_DEVICE_LIMIT
    account_prefix: str = ""

    def matches(self, username: str, source_ip: str) -> bool:
        expected_account = _normalize_account(username, self.account_prefix)
        expected_ip = _normalize_ip(source_ip)
        account_matches = not expected_account or _normalize_account(self.account, self.account_prefix) == expected_account
        ip_matches = not expected_ip or self.ip == expected_ip
        return self.state == "online" and account_matches and ip_matches


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
        server_mac: str = "",
    ) -> dict[str, str]:
        terminal = terminal or self.discover_logout_terminal_params(username)
        return {
            "callback": str(self.auth.get("unbind_callback") or self.auth.get("callback") or "dr1003"),
            "user_account": username,
            # MAC unbind uses only a server-reported session MAC.  The page's
            # all-zero sentinel remains reserved for the logout request body.
            "wlan_user_mac": _normalize_mac(server_mac) or terminal.mac,
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

    def login_with_result(
        self,
        username: str,
        password: str,
        known_source_ip: str = "",
    ) -> LoginResult:
        params = self.build_login_params(username, password)
        timeout_seconds = int(self.auth["timeout_seconds"])
        login_url = self._safe_portal_url(str(self.auth.get("login_url") or ""), "login_url")
        if not login_url:
            return LoginResult("failed", "portal_url_invalid")
        source_ip = _normalize_ip(known_source_ip) or _get_source_ip(
            login_url,
            timeout_seconds,
        )
        if not is_campus_source_ip(self.config, source_ip):
            self.logger.warning(
                "宿舍区 Dr.COM 登录停止：源 IP 未通过校园网段校验 source_ip_present=%s",
                bool(source_ip),
            )
            return LoginResult("failed", "source_ip_unverified", source_ip=source_ip)

        params["wlan_user_ip"] = source_ip
        # The live portal page owns terminal MAC selection.  Reading a Windows
        # adapter MAC here is wrong for private/randomized MACs and can also
        # select a virtual interface.  Login therefore deliberately omits
        # wlan_user_mac, matching the current macOS client and deployed page.
        adapter = SourceAddressAdapter(source_ip)
        self.session.mount("http://", adapter)
        self.session.mount("https://", adapter)

        try:
            response = self.session.get(
                login_url,
                params=params,
                timeout=timeout_seconds,
                allow_redirects=False,
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
            verified = self.verify_login(username, source_ip)
            if verified is not True:
                return LoginResult(
                    "unknown",
                    "login_not_confirmed" if verified is False else "session_verification_unavailable",
                    http_status=response.status_code,
                    source_ip=source_ip,
                )
            return LoginResult(
                "success",
                "session_verified",
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

    def verify_login(self, username: str, source_ip: str) -> bool | None:
        """Confirm an accepted login against the portal session itself."""
        saw_definitive_mismatch = False
        for delay in (0.0, 0.35, 0.9):
            if delay:
                time.sleep(delay)
            fact = self.session_fact(username, source_ip)
            if fact.matches(username, source_ip):
                return True
            if fact.state in ("online", "offline"):
                saw_definitive_mismatch = True
        return False if saw_definitive_mismatch else None

    def session_fact(self, username: str, source_ip: str) -> PortalSessionFact:
        """Read the exact portal session without consulting VPN adapters or the internet."""
        source_ip = _normalize_ip(source_ip)
        if source_ip:
            adapter = SourceAddressAdapter(source_ip)
            self.session.mount("http://", adapter)
            self.session.mount("https://", adapter)

        status = self._fetch_portal_status()
        account_prefix = str(self.auth.get("account_prefix") or "").strip()
        # The configured username is the account whose device limit matters.
        # A status endpoint can describe another account on a shared gateway;
        # never let that response redirect the online-list query.
        expected_account = _normalize_account(username, account_prefix)
        expected_ip = status.ip or source_ip
        online_list = self._fetch_online_list(
            expected_account,
            expected_ip,
            account_prefix=account_prefix,
        )
        record = online_list.exact_record or {}

        account = _normalize_account(
            str(record.get("user_account") or expected_account), account_prefix
        )
        ip = _normalize_ip(str(record.get("online_ip") or "")) or expected_ip
        status_mac = _normalize_mac(status.mac)
        record_mac = _normalize_mac(str(record.get("online_mac") or ""))
        mac = (
            _non_sentinel_mac(record_mac)
            or _non_sentinel_mac(status_mac)
            or status_mac
            or record_mac
        )
        wlan_ac_ip = status.wlan_ac_ip or _nas_ip_to_dotted(record.get("nas_ip"))

        if status.declared_online is False:
            state: PortalSessionState = "offline"
        elif status.declared_online is True:
            state = "online"
        elif online_list.exact_record is not None:
            state = "online"
        elif online_list.readable and expected_account and expected_ip:
            state = "offline"
        else:
            state = "unknown"

        fact = PortalSessionFact(
            state=state,
            account=account,
            ip=ip,
            mac=mac,
            vlan=status.vlan or "0",
            wlan_ac_ip=wlan_ac_ip,
            wlan_ac_name=status.wlan_ac_name,
            status_was_readable=status.readable,
            online_list_was_readable=online_list.readable,
            exact_online_record_present=(
                online_list.exact_record is not None if online_list.readable else None
            ),
            online_device_count=online_list.device_count,
            online_device_limit=DORM_ONLINE_DEVICE_LIMIT,
            account_prefix=account_prefix,
        )
        self.logger.info(
            "门户会话事实：state=%s account_match=%s ip_match=%s mac_source=%s online_device_count=%s",
            fact.state,
            _normalize_account(fact.account, account_prefix)
            == _normalize_account(username, account_prefix),
            fact.ip == source_ip,
            "server" if fact.mac else "missing",
            fact.online_device_count if fact.online_device_count is not None else "unknown",
        )
        return fact

    def logout(self, username: str) -> LogoutResult:
        logout_url = self._get_logout_url()
        if not logout_url:
            configured = str(self.auth.get("logout_url") or "").strip()
            reason = "logout_url_invalid" if configured else "logout_url_not_configured"
            self.logger.info("宿舍区 Dr.COM 退出接口不可用：%s", reason)
            return LogoutResult("failed", reason)

        if not logout_url.startswith(("http://", "https://")):
            self.logger.info("宿舍区 Dr.COM 退出接口配置无效：auth.logout_url 不是 HTTP 地址")
            return LogoutResult("failed", "logout_url_invalid")

        timeout_seconds = int(self.auth["timeout_seconds"])
        source_ip = _normalize_ip(_get_source_ip(logout_url, timeout_seconds))
        if not is_campus_source_ip(self.config, source_ip):
            self.logger.warning(
                "宿舍区 Dr.COM 退出停止：源 IP 未通过校园网段校验 source_ip_present=%s",
                bool(source_ip),
            )
            return LogoutResult("failed", "source_ip_unverified")

        adapter = SourceAddressAdapter(source_ip)
        self.session.mount("http://", adapter)
        self.session.mount("https://", adapter)

        before = self.session_fact(username, source_ip)
        if before.state == "offline":
            return LogoutResult("success", "already_logged_out")
        if before.state == "unknown":
            return LogoutResult("unknown", "session_state_unknown")

        terminal = self.discover_logout_terminal_params(
            username,
            source_ip=source_ip,
            session_fact=before,
        )
        self.logger.info(
            "宿舍区 Dr.COM 退出终端参数已解析：ip_present=%s mac_present=%s vlan=%s ac_ip_present=%s page_present=%s",
            bool(terminal.ip),
            bool(_non_sentinel_mac(terminal.mac)),
            terminal.vlan,
            bool(terminal.wlan_ac_ip),
            bool(terminal.page_url),
        )
        if not terminal.ip:
            self.logger.info("宿舍区 Dr.COM 退出失败：无法确定当前终端 IP")
            return LogoutResult("failed", "terminal_ip_not_found")

        if before.mac:
            unbind_url = self._get_unbind_url(logout_url)
            unbind_params = self.build_unbind_params(
                before.account or username,
                terminal,
                server_mac=before.mac,
            )
            unbind_ack = self._request_logout_unbind(
                unbind_url,
                unbind_params,
                timeout_seconds,
            )
            if unbind_ack is True and self._verified_session_state(username, source_ip) == "offline":
                return LogoutResult("success", "unbind_verified")
        else:
            self.logger.info("门户未提供当前会话 MAC，跳过 MAC 解绑并继续注销。")

        params = self.build_logout_params(username, terminal)

        try:
            response = self.session.get(
                logout_url,
                params=params,
                timeout=timeout_seconds,
                allow_redirects=False,
                headers=self._portal_headers(terminal.page_url),
            )
        except requests.RequestException as exc:
            self.logger.error(
                "宿舍区 Dr.COM 退出请求异常：type=%s reason=%s",
                type(exc).__name__,
                _safe_exception_summary(exc),
            )
            state = self._verified_session_state(username, source_ip)
            if state == "offline":
                return LogoutResult("success", "portal_logout_verified")
            return LogoutResult("failed", "request_exception")

        preview = redact_sensitive_text(response.text[:200])
        self.logger.info("宿舍区 Dr.COM 退出请求完成：请求成功=True")
        self.logger.info("宿舍区 Dr.COM 退出 HTTP 状态码=%s", response.status_code)
        self.logger.info("宿舍区 Dr.COM 退出响应前 200 字=%s", preview)

        parsed = self.parse_jsonp_response(response.text) if 200 <= response.status_code < 300 else None
        acknowledgement = self.is_success_response(parsed) if parsed is not None else None
        inactive = self.is_inactive_logout_response(parsed) if parsed is not None else False
        state = self._verified_session_state(username, source_ip)

        if state == "offline":
            self.logger.info("宿舍区 Dr.COM 退出判断结果：门户会话已确认离线")
            return LogoutResult(
                "success",
                "already_logged_out" if inactive else "portal_logout_verified",
            )
        if state == "online":
            self.logger.info("宿舍区 Dr.COM 退出判断结果：门户会话仍在线")
            return LogoutResult(
                "failed",
                "server_failed" if acknowledgement is False else "logout_not_confirmed",
            )
        if response.status_code >= 500 or acknowledgement is None:
            self.logger.info("宿舍区 Dr.COM 退出判断结果：会话验证不可用")
            return LogoutResult("unknown", "session_verification_unavailable")
        return LogoutResult("failed", "server_failed")

    def _verified_session_state(
        self,
        username: str,
        source_ip: str,
    ) -> PortalSessionState:
        last_state: PortalSessionState = "unknown"
        for delay in (0.0, 0.35, 0.9):
            if delay:
                time.sleep(delay)
            last_state = self.session_fact(username, source_ip).state
            if last_state == "offline":
                return "offline"
        return last_state

    def discover_logout_terminal_params(
        self,
        username: str,
        source_ip: str = "",
        session_fact: PortalSessionFact | None = None,
    ) -> PortalTerminalParams:
        page_url = self._get_logout_page_url()
        page_text = self._fetch_logout_page(page_url)
        if session_fact is None:
            online_record = self._fetch_online_record(username, source_ip)
        else:
            online_record = {
                "user_account": session_fact.account,
                "online_ip": session_fact.ip,
                "online_mac": session_fact.mac,
            }

        return _build_portal_terminal_params(
            page_url=page_url,
            page_text=page_text,
            online_record=online_record,
            source_ip=source_ip,
            js_version=str(self.auth.get("logout_js_version") or self.auth.get("js_version") or "4.1.3"),
        )

    def _safe_portal_url(self, value: str, field_name: str) -> str:
        try:
            expected_origin = None
            if field_name != "login_url":
                login = validate_portal_endpoint(
                    self.config,
                    str(self.auth.get("login_url") or ""),
                    "login_url",
                )
                expected_origin = (
                    login.scheme.lower(),
                    normalize_gateway_host(login.hostname or ""),
                    login.port or 0,
                )
            validate_portal_endpoint(
                self.config,
                value,
                field_name,
                expected_origin=expected_origin,
            )
        except ConfigError:
            self.logger.warning("宿舍区 Dr.COM %s 配置不安全，拒绝请求", field_name)
            return ""
        return value.strip()

    def _get_logout_url(self) -> str:
        configured_url = str(self.auth.get("logout_url") or "").strip()
        if configured_url:
            return self._safe_portal_url(configured_url, "logout_url")

        login_url = str(self.auth.get("login_url") or "").strip()
        parsed = urlparse(login_url)
        if not parsed.scheme or not parsed.netloc:
            return ""

        path = parsed.path.rstrip("/")
        if not path.endswith("/login"):
            return ""

        logout_path = f"{path.removesuffix('/login')}/logout"
        inferred_url = urlunparse(parsed._replace(path=logout_path, query="", fragment=""))
        validated = self._safe_portal_url(inferred_url, "logout_url")
        if validated:
            self.logger.info("宿舍区 Dr.COM 退出接口未显式配置，已从 login_url 推导。")
        return validated

    def _get_unbind_url(self, logout_url: str) -> str:
        configured_url = str(self.auth.get("unbind_url") or "").strip()
        if configured_url:
            return self._safe_portal_url(configured_url, "unbind_url")

        parsed = urlparse(logout_url)
        if not parsed.scheme or not parsed.netloc:
            return ""

        path = parsed.path.rstrip("/")
        if path.endswith("/logout"):
            unbind_path = f"{path.removesuffix('/logout')}/mac/unbind"
            return self._safe_portal_url(
                urlunparse(parsed._replace(path=unbind_path, query="", fragment="")),
                "unbind_url",
            )

        return ""

    def _get_logout_page_url(self) -> str:
        configured_url = str(self.auth.get("logout_page_url") or "").strip()
        if configured_url:
            return self._safe_portal_url(configured_url, "logout_page_url")

        login_url = str(self.auth.get("login_url") or "").strip()
        parsed = urlparse(login_url)
        if not parsed.scheme or not parsed.hostname:
            return ""

        return self._safe_portal_url(
            urlunparse((parsed.scheme, parsed.netloc, "/a79.htm", "", "", "")),
            "logout_page_url",
        )

    def _fetch_logout_page(self, page_url: str) -> str:
        if not page_url:
            return ""

        try:
            response = self.session.get(
                page_url,
                timeout=int(self.auth["timeout_seconds"]),
                allow_redirects=False,
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

    def _fetch_portal_status(self) -> PortalStatusResult:
        status_url = self._get_status_url()
        if not status_url:
            return PortalStatusResult()

        try:
            response = self.session.get(
                status_url,
                params={"callback": "dr1002"},
                timeout=int(self.auth["timeout_seconds"]),
                allow_redirects=False,
                headers=self._portal_headers(),
            )
        except requests.RequestException as exc:
            self.logger.info(
                "宿舍区 Dr.COM 会话状态获取失败：type=%s reason=%s",
                type(exc).__name__,
                _safe_exception_summary(exc),
            )
            return PortalStatusResult()

        if not 200 <= response.status_code < 300:
            self.logger.info("宿舍区 Dr.COM 会话状态获取失败：HTTP 状态码=%s", response.status_code)
            return PortalStatusResult()

        parsed = self.parse_jsonp_response(response.text)
        if not isinstance(parsed, dict):
            return PortalStatusResult()

        return PortalStatusResult(
            readable=True,
            declared_online=_parse_result_value(parsed.get("result")),
            account=_first_mapping_value(parsed, ("uid", "user_account", "account")),
            ip=_normalize_ip(
                _first_mapping_value(parsed, ("v46ip", "ss5", "v4ip", "olip"))
            ),
            mac=_normalize_mac(_first_mapping_value(parsed, ("ss4", "olmac"))),
            vlan=_first_mapping_value(parsed, ("vlanid", "cvid", "pvid")) or "0",
            wlan_ac_ip=_normalize_ip(
                _first_mapping_value(parsed, ("wlanacip", "AC", "opip"))
            ),
            wlan_ac_name=_first_mapping_value(parsed, ("wlanacname",)),
        )

    def _fetch_online_list(
        self,
        expected_account: str,
        expected_ip: str,
        *,
        account_prefix: str = "",
    ) -> PortalOnlineListResult:
        portal_api = self._get_portal_api_url()
        if not portal_api:
            return PortalOnlineListResult()

        try:
            response = self.session.get(
                f"{portal_api}online_list",
                params={"callback": "dr9999"},
                timeout=int(self.auth["timeout_seconds"]),
                allow_redirects=False,
                headers=self._portal_headers(self._get_logout_page_url()),
            )
        except requests.RequestException as exc:
            self.logger.info(
                "宿舍区 Dr.COM 在线列表获取失败：type=%s reason=%s",
                type(exc).__name__,
                _safe_exception_summary(exc),
            )
            return PortalOnlineListResult()

        if not 200 <= response.status_code < 300:
            self.logger.info("宿舍区 Dr.COM 在线列表获取失败：HTTP 状态码=%s", response.status_code)
            return PortalOnlineListResult()

        parsed = self.parse_jsonp_response(response.text)
        if not isinstance(parsed, dict) or not isinstance(parsed.get("list"), list):
            return PortalOnlineListResult()

        records = parsed.get("list")
        account_records, device_count, count_reliable = _account_online_records(
            records,
            expected_account,
            account_prefix=account_prefix,
        )
        record = _select_online_record(
            parsed,
            expected_account,
            expected_ip,
            account_prefix=account_prefix,
        )
        if record:
            self.logger.info(
                "宿舍区 Dr.COM 在线列表已读取：当前会话命中=%s 账号设备计数=%s",
                True,
                device_count if count_reliable else "unknown",
            )
        else:
            self.logger.info(
                "宿舍区 Dr.COM 在线列表已读取：当前会话命中=%s 账号设备计数=%s",
                False,
                device_count if count_reliable else "unknown",
            )
        return PortalOnlineListResult(
            readable=True,
            exact_record=record or None,
            account_records=tuple(account_records),
            device_count=device_count if count_reliable else None,
            count_reliable=count_reliable,
        )

    def _fetch_online_record(self, username: str, source_ip: str = "") -> dict[str, Any]:
        """Compatibility wrapper that only returns an exact account/IP record."""
        return self._fetch_online_list(
            username,
            _normalize_ip(source_ip),
            account_prefix=str(self.auth.get("account_prefix") or "").strip(),
        ).exact_record or {}

    def _get_portal_api_url(self) -> str:
        login_url = str(self.auth.get("login_url") or "").strip()
        parsed = urlparse(login_url)
        if not parsed.scheme or not parsed.netloc:
            return ""

        path = parsed.path.rstrip("/")
        if path.endswith("/login"):
            api_path = f"{path.removesuffix('/login')}/"
        elif path.endswith("/"):
            api_path = path
        else:
            return ""
        return self._safe_portal_url(
            urlunparse(parsed._replace(path=api_path, query="", fragment="")),
            "portal_api_url",
        )

    def _get_status_url(self) -> str:
        page_url = self._get_logout_page_url()
        parsed = urlparse(page_url)
        if not parsed.scheme or not parsed.netloc:
            return ""
        return self._safe_portal_url(
            urlunparse(parsed._replace(path="/drcom/chkstatus", query="", fragment="")),
            "status_url",
        )

    def _get_status_url(self) -> str:
        page_url = self._get_logout_page_url()
        parsed = urlparse(page_url)
        if not parsed.scheme or not parsed.netloc:
            return ""
        return urlunparse(parsed._replace(path="/drcom/chkstatus", query="", fragment=""))

    def _portal_headers(self, page_url: str = "") -> dict[str, str]:
        referer = _portal_referer(page_url or self._get_logout_page_url() or str(self.auth.get("login_url") or ""))
        return {"User-Agent": USER_AGENT, "Referer": referer}

    def _request_logout_unbind(
        self,
        unbind_url: str,
        params: dict[str, str],
        timeout_seconds: int,
    ) -> bool | None:
        if not unbind_url:
            self.logger.info("宿舍区 Dr.COM MAC 解绑接口无法从 logout_url 推导，跳过 unbind")
            return None

        try:
            response = self.session.get(
                unbind_url,
                params=params,
                timeout=timeout_seconds,
                allow_redirects=False,
                headers=self._portal_headers(),
            )
        except requests.RequestException as exc:
            self.logger.info(
                "宿舍区 Dr.COM MAC 解绑请求异常，继续尝试退出：type=%s reason=%s",
                type(exc).__name__,
                _safe_exception_summary(exc),
            )
            return None

        preview = redact_sensitive_text(response.text[:200])
        self.logger.info("宿舍区 Dr.COM MAC 解绑 HTTP 状态码=%s", response.status_code)
        self.logger.info("宿舍区 Dr.COM MAC 解绑响应前 200 字=%s", preview)
        if not 200 <= response.status_code < 300:
            return None
        return self.is_success_response(self.parse_jsonp_response(response.text))

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
    # The browser page/query describes the terminal identity used by the
    # logout request.  online_list is only a fallback for a missing page value.
    terminal_ip = page_ip or online_ip or _normalize_ip(source_ip)

    page_mac = _normalize_mac(_first_query_value(query, _MAC_QUERY_NAMES))
    variable_mac = _normalize_mac(page_vars.get("ss4", "") or page_vars.get("olmac", ""))
    online_mac = _normalize_mac(str(online_record.get("online_mac") or ""))
    # Preserve the page's all-zero sentinel.  Replacing it with a local or
    # online-list MAC changes the browser's wire request and can break logout.
    terminal_mac = (
        page_mac
        or variable_mac
        or _non_sentinel_mac(online_mac)
        or online_mac
        or "000000000000"
    )

    terminal_vlan = (
        _first_query_value(query, ("vlan", "vlanid"))
        or str(page_vars.get("vlanid") or "").strip()
        or "0"
    )
    # Browser code reads AC identity from redirect parameters; online_list's
    # NAS value is session metadata and must not be manufactured into this body.
    terminal_ac_ip = _first_query_value(query, _AC_IP_QUERY_NAMES)
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


def _first_mapping_value(mapping: dict[str, Any], names: tuple[str, ...]) -> str:
    for name in names:
        value = mapping.get(name)
        if value not in (None, ""):
            return str(value).strip()
    return ""


def _parse_portal_page_vars(text: str) -> dict[str, str]:
    vars_: dict[str, str] = {}
    for match in _PORTAL_VAR_RE.finditer(text):
        raw_value = match.group("value").strip()
        if len(raw_value) >= 2 and raw_value[0] in ("'", '"') and raw_value[-1] == raw_value[0]:
            raw_value = raw_value[1:-1]
        vars_[match.group("name")] = raw_value.strip()
    return vars_


def _select_online_record(
    parsed: Any,
    username: str,
    source_ip: str,
    *,
    account_prefix: str = "",
) -> dict[str, Any]:
    if not isinstance(parsed, dict):
        return {}

    records = parsed.get("list")
    if not isinstance(records, list):
        return {}

    dict_records = [record for record in records if isinstance(record, dict)]
    if not dict_records:
        return {}

    username = _normalize_account(str(username), account_prefix)
    source_ip = _normalize_ip(source_ip)
    if not username or not source_ip:
        return {}

    for record in dict_records:
        if (
            _normalize_account(str(record.get("user_account") or ""), account_prefix)
            == username
            and _normalize_ip(str(record.get("online_ip") or "")) == source_ip
        ):
            return record

    return {}


def _account_online_records(
    records: Any,
    username: str,
    *,
    account_prefix: str = "",
) -> tuple[list[dict[str, Any]], int | None, bool]:
    """Return same-account records and a conservative device count.

    The portal has historically returned a loose ``list`` payload.  A count is
    considered reliable only when every entry can be parsed and every
    same-account entry has a usable server identity (non-sentinel MAC or valid
    IP).  Any malformed row, or an identity-less row for the target account,
    makes the aggregate unknown rather than risking a fourth login that could
    evict another device.  Well-formed rows for other accounts do not affect
    the target account's count.
    """

    if not isinstance(records, list):
        return [], None, False

    expected_account = _normalize_account(username, account_prefix)
    if not expected_account:
        return [], None, False

    account_records: list[dict[str, Any]] = []
    server_macs: set[str] = set()
    mac_ips: set[str] = set()
    fallback_ips: set[str] = set()
    for record in records:
        if not isinstance(record, dict):
            return [], None, False

        account = _normalize_account(
            str(record.get("user_account") or record.get("username") or ""),
            account_prefix,
        )
        if not account:
            return [], None, False

        if account != expected_account:
            continue
        mac, ip = _online_record_server_identity(record)
        if not mac and not ip:
            return [], None, False
        account_records.append(record)
        if mac:
            # A real server MAC is the strongest device identity.  Remember
            # its IP as well so a duplicate row that lost its MAC does not
            # become a second counted device.
            server_macs.add(mac)
            if ip:
                mac_ips.add(ip)
        elif ip:
            fallback_ips.add(ip)

    fallback_ips.difference_update(mac_ips)
    count = len(server_macs) + len(fallback_ips)
    # The public protocol deliberately exposes only the fixed 0...3 budget.
    # Any portal anomaly above the supported limit remains "full" without
    # expanding the schema or UI into a device-list surface.
    return account_records, min(count, DORM_ONLINE_DEVICE_LIMIT), True


def _online_record_server_identity(record: dict[str, Any]) -> tuple[str, str]:
    """Return normalized ``(mac, ip)`` values from a server row."""

    mac = ""
    for key in ("online_mac", "wlan_user_mac", "mac", "user_mac", "olmac"):
        mac = _non_sentinel_mac(str(record.get(key) or ""))
        if mac:
            break

    ip = ""
    for key in ("online_ip", "wlan_user_ip", "ip", "v46ip", "client_ip"):
        ip = _normalize_ip(str(record.get(key) or ""))
        if ip:
            break
    return mac, ip


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


def _normalize_account(value: str, account_prefix: str = "") -> str:
    """Canonicalize a portal account for comparisons only.

    Dr.COM commonly returns ``user_account`` with the configured login prefix
    (for example ``,1,481505``) while config stores just ``481505``.  Remove
    whitespace and that exact configured prefix; never use this helper to
    build a login request.
    """

    normalized = "".join(str(value or "").split())
    prefix = "".join(str(account_prefix or "").split())
    if prefix and normalized.startswith(prefix):
        normalized = normalized[len(prefix) :]
    return normalized


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


def _normalize_mac(value: str) -> str:
    normalized = re.sub(r"[^0-9A-Fa-f]", "", value).lower()
    if len(normalized) == 12:
        return normalized
    return ""


def _non_sentinel_mac(value: str) -> str:
    normalized = _normalize_mac(value)
    return "" if normalized == "000000000000" else normalized


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
