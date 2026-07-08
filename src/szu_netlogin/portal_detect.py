"""One-shot network checks for the dorm Dr.COM login command."""

from __future__ import annotations

import os
import socket
import subprocess
from dataclasses import dataclass
from typing import Any
from urllib.parse import urlparse

import requests
import urllib3
from requests.adapters import HTTPAdapter

from .logger import get_logger
from .platform_paths import run_subprocess_hidden


DEFAULT_TIMEOUT_SECONDS = 3
DEFAULT_MAX_TEST_URLS = 3
MIN_TEST_URLS = 2
DEFAULT_TEST_URLS = (
    "http://captive.apple.com/hotspot-detect.html",
    "http://www.baidu.com/",
    "https://www.baidu.com/",
)
USER_AGENT = (
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
    "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0 Safari/537.36"
)


@dataclass(frozen=True)
class NetworkStatus:
    gateway_reachable: bool
    campus_internet_ok: bool
    gateway_host: str = ""
    source_ip: str = ""
    gateway_reason: str = ""
    internet_reason: str = ""
    internet_route: str = ""

    @property
    def maybe_need_login(self) -> bool:
        return self.gateway_reachable and not self.campus_internet_ok


@dataclass(frozen=True)
class NetworkEnvironment:
    label: str
    is_dorm_network: bool
    auto_login_available: bool
    wifi_ssid: str = ""
    source_ip: str = ""
    reason: str = ""


@dataclass(frozen=True)
class GatewayProbe:
    reachable: bool
    host: str = ""
    source_ip: str = ""
    reason: str = ""


@dataclass(frozen=True)
class InternetProbe:
    ok: bool
    reason: str = ""
    portal_redirect: bool = False
    route: str = ""


def check_internet(
    config: dict[str, Any] | None = None,
    timeout_seconds: int | None = None,
) -> bool:
    """Return True when the dorm gateway path can reach outside URLs."""
    return probe_network(config, timeout_seconds=timeout_seconds).campus_internet_ok


def probe_network(
    config: dict[str, Any] | None = None,
    timeout_seconds: int | None = None,
) -> NetworkStatus:
    """Probe the dorm gateway path once and return a reusable status snapshot."""
    timeout = timeout_seconds if timeout_seconds is not None else _get_timeout_seconds(config)
    gateway = _probe_gateway(config, timeout)
    if not gateway.reachable:
        return NetworkStatus(
            gateway_reachable=False,
            campus_internet_ok=False,
            source_ip=gateway.source_ip,
            gateway_reason=gateway.reason,
            internet_reason="gateway_unreachable",
        )

    internet = _probe_campus_internet(config, gateway.source_ip, timeout)
    return NetworkStatus(
        gateway_reachable=True,
        campus_internet_ok=internet.ok,
        gateway_host=gateway.host,
        source_ip=gateway.source_ip,
        gateway_reason=gateway.reason,
        internet_reason=internet.reason,
        internet_route=internet.route,
    )


def classify_network_environment(
    config: dict[str, Any] | None,
    status: NetworkStatus,
) -> NetworkEnvironment:
    """Classify whether the current network is safe for dorm auto-login."""
    wifi_ssid = get_current_wifi_ssid()
    campus_wifi_names = _get_campus_wifi_names(config)
    on_configured_wifi = bool(wifi_ssid and wifi_ssid in campus_wifi_names)

    if status.gateway_reachable:
        return NetworkEnvironment(
            "宿舍网络",
            is_dorm_network=True,
            auto_login_available=True,
            wifi_ssid=wifi_ssid,
            source_ip=status.source_ip,
            reason="gateway_reachable",
        )

    if on_configured_wifi:
        return NetworkEnvironment(
            "宿舍 Wi-Fi，网关不可达",
            is_dorm_network=True,
            auto_login_available=False,
            wifi_ssid=wifi_ssid,
            source_ip=status.source_ip,
            reason=status.gateway_reason or "gateway_unreachable",
        )

    return NetworkEnvironment(
        "非宿舍网络",
        is_dorm_network=False,
        auto_login_available=False,
        wifi_ssid=wifi_ssid,
        source_ip=status.source_ip,
        reason=status.gateway_reason or "gateway_unreachable",
    )


def get_current_wifi_ssid() -> str:
    if os.name == "nt":
        return _get_windows_wifi_ssid()

    device = _get_wifi_device()
    if not device:
        return ""

    try:
        result = subprocess.run(
            ["/usr/sbin/networksetup", "-getairportnetwork", device],
            check=False,
            capture_output=True,
            text=True,
            timeout=3,
        )
    except (OSError, subprocess.SubprocessError):
        return ""

    if result.returncode != 0:
        return ""

    text = result.stdout.strip()
    if ":" not in text or "not associated" in text.lower():
        return ""
    return text.split(":", 1)[1].strip()


def _get_windows_wifi_ssid() -> str:
    try:
        result = run_subprocess_hidden(
            ["netsh", "wlan", "show", "interfaces"],
            check=False,
            capture_output=True,
            text=True,
            timeout=3,
        )
    except (OSError, subprocess.SubprocessError):
        return ""

    if result.returncode != 0:
        return ""

    for line in result.stdout.splitlines():
        stripped = line.strip()
        if not stripped.lower().startswith("ssid") or stripped.lower().startswith("bssid"):
            continue
        if ":" not in stripped:
            continue
        return stripped.split(":", 1)[1].strip()
    return ""


def _probe_campus_internet(
    config: dict[str, Any] | None,
    source_ip: str,
    timeout_seconds: int,
) -> InternetProbe:
    urls = _get_test_urls(config)
    session = _build_session("", trust_env=True)
    try:
        return _probe_urls(
            session,
            urls,
            timeout_seconds,
            route="default",
            source_ip=source_ip,
        )
    finally:
        session.close()


def _probe_urls(
    session: requests.Session,
    urls: list[str],
    timeout_seconds: int,
    route: str,
    source_ip: str,
    log_failure: bool = True,
) -> InternetProbe:
    logger = get_logger()
    failures: list[str] = []
    portal_redirect = False

    for url in urls:
        try:
            response = session.get(
                url,
                timeout=timeout_seconds,
                allow_redirects=False,
                headers={"User-Agent": USER_AGENT},
            )
        except requests.RequestException as exc:
            failures.append(f"{_url_label(url)}={_request_failure_reason(exc)}")
            continue

        location = response.headers.get("Location", "")
        preview = response.text[:120].replace("\n", " ").replace("\r", " ")

        if _looks_like_portal(location) or _looks_like_portal(response.url):
            portal_redirect = True
            failures.append(f"{_url_label(url)}=portal_redirect")
            continue

        if _is_successful_connectivity_response(url, response.status_code, preview):
            logger.info(
                "校园网出口检测：可用 route=%s source_ip=%s url=%s status=%s",
                route,
                source_ip or "-",
                _url_label(url),
                response.status_code,
            )
            return InternetProbe(True, "ok", route=route)

        failures.append(f"{_url_label(url)}=http_{response.status_code}")

    reason = "; ".join(failures) if failures else "no_test_url"
    if log_failure:
        _log_probe_failure(route, source_ip, reason)
    return InternetProbe(False, reason, portal_redirect=portal_redirect, route=route)


def _log_probe_failure(route: str, source_ip: str, reason: str) -> None:
    get_logger().info(
        "校园网出口检测：不可用 route=%s source_ip=%s reason=%s",
        route,
        source_ip or "-",
        reason,
    )


class SourceAddressAdapter(HTTPAdapter):
    def __init__(self, source_ip: str, **kwargs: Any) -> None:
        self.source_ip = source_ip
        super().__init__(**kwargs)

    def init_poolmanager(
        self,
        connections: int,
        maxsize: int,
        block: bool = False,
        **pool_kwargs: Any,
    ) -> None:
        pool_kwargs["source_address"] = (self.source_ip, 0)
        self.poolmanager = urllib3.PoolManager(
            num_pools=connections,
            maxsize=maxsize,
            block=block,
            **pool_kwargs,
        )


def _build_session(source_ip: str, trust_env: bool = False) -> requests.Session:
    session = requests.Session()
    session.trust_env = trust_env
    if source_ip:
        adapter = SourceAddressAdapter(source_ip)
        session.mount("http://", adapter)
        session.mount("https://", adapter)
    return session


def _probe_gateway(
    config: dict[str, Any] | None,
    timeout_seconds: int,
) -> GatewayProbe:
    logger = get_logger()
    failures: list[str] = []
    last_source_ip = ""

    for host in _get_gateway_hosts(config):
        try:
            with socket.create_connection((host, 801), timeout=timeout_seconds) as sock:
                source_ip = str(sock.getsockname()[0])
                last_source_ip = source_ip
                logger.info(
                    "宿舍区网关检测：可连接 host=%s port=801 source_ip=%s",
                    host,
                    source_ip,
                )
                return GatewayProbe(True, host, source_ip)
        except OSError as exc:
            failures.append(f"{host}={_short_reason(exc)}")
            continue

    reason = "; ".join(failures) if failures else "no_gateway_host"
    logger.info("宿舍区网关检测：不可连接 reason=%s", reason)
    return GatewayProbe(False, source_ip=last_source_ip, reason=reason)


def check_gateway_reachable(
    config: dict[str, Any] | None = None,
    timeout_seconds: int | None = None,
) -> bool:
    """Return True when one dorm gateway host accepts a TCP connection."""
    timeout = timeout_seconds if timeout_seconds is not None else _get_timeout_seconds(config)
    return _probe_gateway(config, timeout).reachable


def maybe_need_login(config: dict[str, Any] | None = None) -> bool:
    """Return True when internet is unavailable and the dorm gateway is reachable."""
    return probe_network(config).maybe_need_login


def _get_test_urls(config: dict[str, Any] | None) -> list[str]:
    urls = ((config or {}).get("network") or {}).get("test_urls") or []
    candidates = [str(url).strip() for url in urls if str(url).strip()]
    candidates.extend(DEFAULT_TEST_URLS)
    normalized_urls: list[str] = []
    seen: set[str] = set()
    for url in candidates:
        if url in seen:
            continue
        seen.add(url)
        normalized_urls.append(url)
    return normalized_urls[:_get_max_test_urls(config)]


def _get_gateway_hosts(config: dict[str, Any] | None) -> list[str]:
    hosts = ((config or {}).get("network") or {}).get("dorm_gateway_hosts") or []
    return [str(host) for host in hosts] or ["172.30.255.42"]


def _get_campus_wifi_names(config: dict[str, Any] | None) -> set[str]:
    names = ((config or {}).get("network") or {}).get("campus_wifi_names") or []
    return {str(name).strip() for name in names if str(name).strip()}


def _get_timeout_seconds(config: dict[str, Any] | None) -> int:
    network = (config or {}).get("network") or {}
    value = network.get("timeout_seconds", network.get("check_timeout_seconds", DEFAULT_TIMEOUT_SECONDS))
    try:
        timeout = int(value)
    except (TypeError, ValueError):
        return DEFAULT_TIMEOUT_SECONDS
    return max(1, timeout)


def _get_max_test_urls(config: dict[str, Any] | None) -> int:
    network = (config or {}).get("network") or {}
    value = network.get("max_test_urls", DEFAULT_MAX_TEST_URLS)
    try:
        max_urls = int(value)
    except (TypeError, ValueError):
        return DEFAULT_MAX_TEST_URLS
    return max(MIN_TEST_URLS, max_urls)


def _looks_like_portal(text: str) -> bool:
    lowered = text.lower()
    return any(word in lowered for word in ("portal", "drcom", "eportal", "172.30.255.42"))


def _is_successful_connectivity_response(url: str, status_code: int, preview: str) -> bool:
    lowered_url = url.lower()
    lowered_preview = preview.lower()

    if "baidu.com" in lowered_url:
        return status_code == 200 and not _looks_like_portal(preview)

    if "captive.apple.com/hotspot-detect.html" in lowered_url:
        return status_code == 200 and "success" in lowered_preview

    if status_code in (301, 302, 303, 307, 308):
        return False

    return 200 <= status_code < 300 and not _looks_like_portal(preview)


def _short_reason(exc: BaseException) -> str:
    return str(exc).replace("\n", " ")[:160]


def _request_failure_reason(exc: requests.RequestException) -> str:
    if isinstance(exc, requests.Timeout):
        return "timeout"
    if isinstance(exc, requests.ConnectionError):
        return "connection_failed"
    return type(exc).__name__


def _url_label(url: str) -> str:
    parsed = urlparse(url)
    return parsed.hostname or url[:40]


def _get_wifi_device() -> str:
    try:
        result = subprocess.run(
            ["/usr/sbin/networksetup", "-listallhardwareports"],
            check=False,
            capture_output=True,
            text=True,
            timeout=3,
        )
    except (OSError, subprocess.SubprocessError):
        return "en0"

    if result.returncode != 0:
        return "en0"

    lines = result.stdout.splitlines()
    for index, line in enumerate(lines):
        if line.strip() != "Hardware Port: Wi-Fi":
            continue
        for candidate in lines[index + 1 : index + 4]:
            stripped = candidate.strip()
            if stripped.startswith("Device:"):
                return stripped.split(":", 1)[1].strip()

    return "en0"
