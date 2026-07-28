"""Fail-closed SRun portal discovery and a source-bound HTTPS transport."""

from __future__ import annotations

import ipaddress
import re
from dataclasses import dataclass
from typing import Mapping, Protocol
from urllib.parse import parse_qs, urljoin, urlparse

import requests

from .portal_detect import SourceAddressAdapter


SRUN_PORTAL_HOST = "net.szu.edu.cn"
_ACID_PAIR = re.compile(r"(?i)(?:[\"']?(?:ac_id|acid)[\"']?)\s*[:=]\s*[\"']?([0-9]{1,8})[\"']?")
_IP_PAIR = re.compile(r"(?i)(?:[\"']?(?:ip|client_ip|wlanuserip)[\"']?)\s*[:=]\s*[\"']?([0-9a-f:.]{3,45})[\"']?")


class PortalDiscoveryError(ValueError):
    def __init__(self, error_code: str) -> None:
        super().__init__(error_code)
        self.error_code = error_code


@dataclass(frozen=True)
class PortalDiscovery:
    acid: str
    client_ip: str
    portal_host: str
    evidence: tuple[str, ...]


@dataclass(frozen=True)
class TransportResponse:
    status_code: int
    body: bytes
    headers: Mapping[str, str]


class SRunTransport(Protocol):
    def get(
        self, path: str, query: Mapping[str, str], *, source_ip: str, timeout: float
    ) -> TransportResponse: ...


def discover_portal(portal_url: str, html: str, source_ip: str) -> PortalDiscovery:
    parsed = urlparse(portal_url)
    host = (parsed.hostname or "").lower()
    if host != SRUN_PORTAL_HOST:
        raise PortalDiscoveryError("ENV_PORTAL_IDENTITY_UNVERIFIED")

    acid_values: list[tuple[str, str]] = []
    ip_values: list[tuple[str, str]] = []
    query = parse_qs(parsed.query, keep_blank_values=False)
    for key in ("ac_id", "acid"):
        acid_values.extend(("url", item) for item in query.get(key, []))
    for key in ("ip", "client_ip", "wlanuserip"):
        ip_values.extend(("url", item) for item in query.get(key, []))
    acid_values.extend(("html", item) for item in _ACID_PAIR.findall(html))
    ip_values.extend(("html", item) for item in _IP_PAIR.findall(html))
    if source_ip:
        ip_values.append(("route", source_ip))

    acids = {_valid_acid(value) for _, value in acid_values}
    ips = {_valid_ip(value) for _, value in ip_values}
    if not acids:
        raise PortalDiscoveryError("SRUN_CONFIG_MISSING_ACID")
    if not ips:
        raise PortalDiscoveryError("SRUN_CONFIG_MISSING_IP")
    if len(acids) != 1 or len(ips) != 1:
        raise PortalDiscoveryError("SRUN_CONFIG_CONFLICT")
    evidence = tuple(f"{kind}:{'acid' if (kind, value) in acid_values else 'ip'}" for kind, value in acid_values + ip_values)
    return PortalDiscovery(acids.pop(), ips.pop(), host, evidence)


class RequestsSRunTransport:
    """HTTPS-only, no-proxy, redirect-blocking transport with source binding."""

    def __init__(self, base_url: str = "https://net.szu.edu.cn") -> None:
        parsed = urlparse(base_url)
        if parsed.scheme != "https" or (parsed.hostname or "").lower() != SRUN_PORTAL_HOST:
            raise ValueError("SRun base URL must be verified HTTPS portal host")
        self.base_url = base_url.rstrip("/") + "/"
        self.session = requests.Session()
        self.session.trust_env = False

    def get(
        self, path: str, query: Mapping[str, str], *, source_ip: str, timeout: float
    ) -> TransportResponse:
        _valid_ip(source_ip)
        adapter = SourceAddressAdapter(source_ip)
        self.session.mount("https://", adapter)
        target = urljoin(self.base_url, path.lstrip("/"))
        if (urlparse(target).hostname or "").lower() != SRUN_PORTAL_HOST:
            raise ValueError("cross-host authentication request blocked")
        response = self.session.get(
            target,
            params=dict(query),
            timeout=timeout,
            allow_redirects=False,
        )
        if 300 <= response.status_code < 400:
            raise requests.TooManyRedirects("authentication redirect blocked")
        return TransportResponse(response.status_code, response.content, dict(response.headers))


def _valid_acid(value: str) -> str:
    value = value.strip()
    if not re.fullmatch(r"[0-9]{1,8}", value):
        raise PortalDiscoveryError("SRUN_CONFIG_MISSING_ACID")
    return value


def _valid_ip(value: str) -> str:
    try:
        parsed = ipaddress.ip_address(value.strip())
    except ValueError as exc:
        raise PortalDiscoveryError("SRUN_CONFIG_MISSING_IP") from exc
    if parsed.version != 4:
        raise PortalDiscoveryError("SRUN_CONFIG_MISSING_IP")
    return str(parsed)
