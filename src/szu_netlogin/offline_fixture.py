"""Deterministic, socket-free portal fixture used by the frozen self-test.

The desktop package must prove that its login/session/logout handling still
understands the portal contract without making a request during startup.  The
fixture deliberately records every request and rejects any redirect-following
call so a future client change cannot silently turn this check into a network
probe.
"""

from __future__ import annotations

import json
from dataclasses import dataclass, field
from urllib.parse import urlsplit
from unittest.mock import patch

from .dorm_drcom_client import DormDrcomClient


GATEWAY = "172.30.255.42:801"
SOURCE_IP = "172.24.182.13"
USERNAME = "481505"


@dataclass
class _FixtureResponse:
    text: str
    status_code: int = 200
    url: str = ""
    headers: dict[str, str] = field(default_factory=dict)


class _OfflinePortalSession:
    """Small requests.Session substitute; it never opens a socket."""

    def __init__(self, mode: str = "normal") -> None:
        self.mode = mode
        self.online = False
        self.trust_env = False
        self.calls: list[tuple[str, dict[str, object]]] = []

    def mount(self, prefix: str, adapter: object) -> None:
        del adapter
        if prefix not in ("http://", "https://"):
            raise AssertionError(f"unexpected adapter prefix: {prefix}")

    def get(self, url: str, **kwargs: object) -> _FixtureResponse:
        parsed = urlsplit(url)
        if parsed.hostname != "172.30.255.42" or parsed.port != 801:
            raise AssertionError(f"fixture received an unbound URL: {url}")
        if kwargs.get("allow_redirects") is not False:
            raise AssertionError("portal requests must reject redirects")
        self.calls.append((url, kwargs))
        path = parsed.path.rstrip("/")

        if path.endswith("/login"):
            if self.mode == "redirect":
                return _FixtureResponse(
                    "redirect",
                    status_code=302,
                    url=url,
                    headers={"Location": "http://evil.example.invalid/collect"},
                )
            if self.mode == "error":
                return _FixtureResponse("temporarily unavailable", status_code=503, url=url)
            if self.mode == "login_failure":
                return _FixtureResponse('dr1003({"result":0,"msg":"密码错误"});', url=url)
            self.online = True
            return _FixtureResponse('dr1003({"result":1,"msg":"认证成功"});', url=url)

        if path.endswith("/drcom/chkstatus"):
            result = 1 if self.online else 0
            return _FixtureResponse(
                f'dr1002({{"result":{result},"uid":"{USERNAME}",'
                f'"v46ip":"{SOURCE_IP}","ss4":"000000000000"}});',
                url=url,
            )

        if path.endswith("/online_list"):
            records = json.dumps(
                [{
                    "user_account": USERNAME,
                    "online_ip": SOURCE_IP,
                    "online_mac": "9eb56a2011e4",
                }],
                separators=(",", ":"),
            ) if self.online else "[]"
            return _FixtureResponse(f"dr9999({{\"list\":{records}}});", url=url)

        if path.endswith("/a79.htm"):
            return _FixtureResponse(
                'v46ip="172.24.182.13";vlanid="0";ss4="000000000000";',
                url=url,
            )

        if path.endswith("/mac/unbind"):
            # Exercise the normal fallback path: a failed unbind must not
            # prevent the portal logout request from being attempted.
            return _FixtureResponse('dr1003({"result":0,"msg":"unbind failed"});', url=url)

        if path.endswith("/logout"):
            self.online = False
            return _FixtureResponse('dr1004({"result":1,"msg":"注销成功"});', url=url)

        raise AssertionError(f"unexpected fixture endpoint: {url}")


def _base_config() -> dict[str, object]:
    return {
        "auth": {
            "type": "dorm_drcom",
            "login_url": f"http://{GATEWAY}/eportal/portal/login",
            "logout_url": "",
            "logout_page_url": "",
            "unbind_url": "",
            "callback": "dr1003",
            "logout_callback": "dr1004",
            "logout_js_version": "4.1.3",
            "login_method": "1",
            "account_prefix": ",1,",
            "timeout_seconds": 1,
        },
        "user": {"username": USERNAME},
        "network": {
            "dorm_gateway_hosts": ["172.30.255.42"],
            "campus_source_networks": ["172.16.0.0/12"],
            "test_urls": ["http://example.invalid/"],
        },
        "security": {"password_source": "env", "password_env_name": "SZU_NET_PASSWORD"},
    }


def run_offline_portal_self_test() -> bool:
    """Exercise portal/session/login/logout ACK, failure and error paths offline."""
    config = _base_config()
    client = DormDrcomClient(config)
    normal_session = _OfflinePortalSession()
    client.session = normal_session

    # The fake response path is intentionally used for every portal read.  A
    # no-op sleep keeps this check fast while retaining production retry loops.
    with (
        patch("src.szu_netlogin.dorm_drcom_client.time.sleep"),
        patch("src.szu_netlogin.dorm_drcom_client._get_source_ip", return_value=SOURCE_IP),
    ):
        login = client.login_with_result(USERNAME, "fixture-password", known_source_ip=SOURCE_IP)
        if login.status != "success" or not normal_session.online:
            raise AssertionError(f"offline login fixture failed: {login}")

        logout = client.logout(USERNAME)
        if logout.status != "success" or normal_session.online:
            raise AssertionError(f"offline logout fixture failed: {logout}")

        error_client = DormDrcomClient(config)
        error_client.session = _OfflinePortalSession("error")
        error = error_client.login_with_result(USERNAME, "fixture-password", known_source_ip=SOURCE_IP)
        if (error.status, error.reason) != ("unknown", "server_response_uncertain"):
            raise AssertionError(f"offline error fixture failed: {error}")

        failure_client = DormDrcomClient(config)
        failure_client.session = _OfflinePortalSession("login_failure")
        failure = failure_client.login_with_result(USERNAME, "fixture-password", known_source_ip=SOURCE_IP)
        if (failure.status, failure.reason) != ("failed", "password_error"):
            raise AssertionError(f"offline ACK failure fixture failed: {failure}")

        redirect_client = DormDrcomClient(config)
        redirect_session = _OfflinePortalSession("redirect")
        redirect_client.session = redirect_session
        redirect = redirect_client.login_with_result(USERNAME, "fixture-password", known_source_ip=SOURCE_IP)
        if (redirect.status, redirect.reason) != ("failed", "portal_interface_changed"):
            raise AssertionError(f"offline redirect fixture failed: {redirect}")
        if len(redirect_session.calls) != 1 or any("evil.example.invalid" in url for url, _ in redirect_session.calls):
            raise AssertionError("portal redirect must not trigger a second or external request")

    calls = normal_session.calls
    if not calls or any(kwargs.get("allow_redirects") is not False for _, kwargs in calls):
        raise AssertionError("offline portal fixture did not enforce redirect rejection")
    if normal_session.trust_env:
        raise AssertionError("portal session must disable ambient proxy environment")
    return True
