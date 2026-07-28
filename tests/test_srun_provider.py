from __future__ import annotations

import unittest
from collections import deque
from pathlib import Path

from src.szu_netlogin.contracts import AuthOutcome, CredentialHandle, NetworkContext, SessionState, Support
from src.szu_netlogin.providers.teaching_srun import TeachingSRunProvider
from src.szu_netlogin.srun_portal import TransportResponse


FIXTURES = Path(__file__).parents[1] / "protocol-spec" / "fixtures"


class QueueTransport:
    def __init__(self, responses: list[bytes]) -> None:
        self.responses = deque(responses)
        self.requests: list[tuple[str, dict[str, str], str]] = []

    def get(self, path, query, *, source_ip, timeout):
        self.requests.append((path, dict(query), source_ip))
        return TransportResponse(200, self.responses.popleft(), {})


class TeachingSRunProviderTests(unittest.TestCase):
    def context(self) -> NetworkContext:
        html = (FIXTURES / "portal_acid_5_sanitized.html").read_text(encoding="utf-8")
        return NetworkContext(
            0,
            portal_url="https://net.szu.edu.cn/srun_portal_pc",
            portal_html=html,
            source_ip="198.51.100.27",
            source_route_bound=True,
            portal_identity_verified=True,
        )

    def test_probe_is_verified_without_transport_or_credentials(self) -> None:
        transport = QueueTransport([])
        provider = TeachingSRunProvider(transport)
        probe = provider.probe_environment(self.context())
        self.assertEqual(probe.support, Support.VERIFIED)
        self.assertEqual(probe.acid, "5")
        self.assertEqual(transport.requests, [])

    def test_probe_requires_bound_source_route(self) -> None:
        context = self.context()
        context = NetworkContext(**{**context.__dict__, "source_route_bound": False})
        probe = TeachingSRunProvider(QueueTransport([])).probe_environment(context)
        self.assertEqual(probe.error_code, "ENV_SOURCE_ROUTE_UNVERIFIED")

    def test_complete_login_requires_post_ack_online_status(self) -> None:
        callbacks = iter(["_szu_cb_7f31", "_szu_cb_d911", "_szu_cb_9001"])
        transport = QueueTransport(
            [
                (FIXTURES / "challenge_success.jsonp").read_bytes(),
                (FIXTURES / "login_success.jsonp").read_bytes(),
                (FIXTURES / "status_online.jsonp").read_bytes(),
            ]
        )
        provider = TeachingSRunProvider(
            transport, callback_factory=lambda: next(callbacks), clock_ms=lambda: 1
        )
        probe = provider.probe_environment(self.context())
        result = provider.login(
            self.context(), probe, "student-REDACTED@hlw", CredentialHandle("synthetic-only")
        )
        self.assertEqual(result.outcome, AuthOutcome.SUCCEEDED)
        self.assertEqual([item[0] for item in transport.requests], [
            "/cgi-bin/get_challenge", "/cgi-bin/srun_portal", "/cgi-bin/rad_user_info"
        ])
        login_query = transport.requests[1][1]
        self.assertEqual(login_query["ac_id"], "5")
        self.assertTrue(login_query["password"].startswith("{MD5}"))
        self.assertTrue(login_query["info"].startswith("{SRBX1}"))

    def test_ack_without_online_confirmation_fails(self) -> None:
        callbacks = iter(["_szu_cb_7f31", "_szu_cb_d911", "_szu_cb_9002"])
        transport = QueueTransport([
            (FIXTURES / "challenge_success.jsonp").read_bytes(),
            (FIXTURES / "login_success.jsonp").read_bytes(),
            (FIXTURES / "status_offline.jsonp").read_bytes(),
        ])
        provider = TeachingSRunProvider(transport, callback_factory=lambda: next(callbacks))
        probe = provider.probe_environment(self.context())
        result = provider.login(self.context(), probe, "synthetic", CredentialHandle("synthetic-only"))
        self.assertEqual(result.error_code, "AUTH_NOT_CONFIRMED")

    def test_status_unknown_is_not_offline(self) -> None:
        transport = QueueTransport([b'_szu_cb_unknown({"error":"mystery"});'])
        provider = TeachingSRunProvider(transport, callback_factory=lambda: "_szu_cb_unknown")
        probe = provider.probe_environment(self.context())
        result = provider.session_status(self.context(), probe, "synthetic")
        self.assertEqual(result.state, SessionState.UNKNOWN)

    def test_logout_is_disabled_without_request(self) -> None:
        transport = QueueTransport([])
        provider = TeachingSRunProvider(transport)
        probe = provider.probe_environment(self.context())
        result = provider.logout(self.context(), probe, "synthetic")
        self.assertEqual(result.error_code, "SRUN_LOGOUT_DISABLED")
        self.assertEqual(transport.requests, [])


if __name__ == "__main__":
    unittest.main()
