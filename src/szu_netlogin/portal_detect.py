"""One-shot network checks for the dorm Dr.COM login command."""

from __future__ import annotations

import socket
from typing import Any

import requests

from .logger import get_logger


DEFAULT_TIMEOUT_SECONDS = 5


def check_internet(
    config: dict[str, Any] | None = None,
    timeout_seconds: int = DEFAULT_TIMEOUT_SECONDS,
) -> bool:
    """Return True when one configured outside URL proves outside access works."""
    logger = get_logger()
    urls = _get_test_urls(config)
    session = requests.Session()
    session.trust_env = False

    for url in urls:
        try:
            response = session.get(
                url,
                timeout=timeout_seconds,
                allow_redirects=False,
                headers={"User-Agent": _user_agent()},
            )
        except requests.RequestException as exc:
            logger.info(
                "外网检测异常：type=%s reason=%s",
                type(exc).__name__,
                _short_reason(exc),
            )
            continue

        location = response.headers.get("Location", "")
        preview = response.text[:120].replace("\n", " ").replace("\r", " ")
        logger.info("外网检测：请求完成 HTTP 状态码=%s", response.status_code)

        if _looks_like_portal(location) or _looks_like_portal(response.url):
            logger.info("外网检测：疑似被认证页拦截，继续检测下一个地址。")
            continue

        if _is_successful_connectivity_response(url, response.status_code, preview):
            return True

    return False


def check_gateway_reachable(
    config: dict[str, Any] | None = None,
    timeout_seconds: int = DEFAULT_TIMEOUT_SECONDS,
) -> bool:
    """Return True when one dorm gateway host accepts a TCP connection."""
    logger = get_logger()
    hosts = _get_gateway_hosts(config)

    for host in hosts:
        try:
            with socket.create_connection((host, 801), timeout=timeout_seconds):
                logger.info("宿舍区网关检测：可连接 host=%s port=801", host)
                return True
        except OSError as exc:
            logger.info(
                "宿舍区网关检测异常：type=%s reason=%s",
                type(exc).__name__,
                _short_reason(exc),
            )

    return False


def maybe_need_login(config: dict[str, Any] | None = None) -> bool:
    """Return True when internet is unavailable and the dorm gateway is reachable."""
    timeout_seconds = _get_timeout_seconds(config)
    if check_internet(config, timeout_seconds=timeout_seconds):
        return False
    return check_gateway_reachable(config, timeout_seconds=timeout_seconds)


def _get_test_urls(config: dict[str, Any] | None) -> list[str]:
    urls = ((config or {}).get("network") or {}).get("test_urls") or []
    return [str(url) for url in urls] or [
        "https://www.baidu.com/",
        "http://captive.apple.com/hotspot-detect.html",
    ]


def _get_gateway_hosts(config: dict[str, Any] | None) -> list[str]:
    hosts = ((config or {}).get("network") or {}).get("dorm_gateway_hosts") or []
    return [str(host) for host in hosts] or ["172.30.255.42"]


def _get_timeout_seconds(config: dict[str, Any] | None) -> int:
    value = ((config or {}).get("auth") or {}).get("timeout_seconds", DEFAULT_TIMEOUT_SECONDS)
    try:
        return int(value)
    except (TypeError, ValueError):
        return DEFAULT_TIMEOUT_SECONDS


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


def _user_agent() -> str:
    return (
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
        "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0 Safari/537.36"
    )
