from __future__ import annotations

import tempfile
import unittest
from pathlib import Path
from unittest.mock import ANY, Mock, patch

from src.szu_netlogin.contracts import (
    AuthOutcome,
    AuthResult,
    NetworkContext,
    ProviderProbe,
    SessionResult,
    SessionState,
    Support,
)
from src.szu_netlogin.windows_product import (
    EnvironmentSnapshot,
    WindowsEnvironmentDetector,
    WindowsCampusService,
    get_process_service,
    set_process_service_for_testing,
    set_provider_enabled,
)
from src.szu_netlogin.portal_detect import SourceAddressAdapter
from src.szu_netlogin.srun_portal import RequestsSRunTransport


def config():
    return {
        "general": {"autoDetect": True},
        "providers": {
            "dorm": {"enabled": True, "accountLabel": "synthetic-dorm", "credentialRef": "provider:dorm:test"},
            "teaching": {"enabled": False, "accountLabel": "synthetic-teaching", "credentialRef": "provider:teaching:test", "accountSuffixMode": "none"},
        },
        "user": {"username": "synthetic-dorm"},
        "security": {"keychain_service": "szu-netlogin"},
    }


class FakeDetector:
    def __init__(self, category="dorm"):
        self.category = category

    def detect(self, config, generation):
        supported = NetworkContext(generation, source_ip="198.51.100.1", source_route_bound=True, portal_identity_verified=True)
        blocked = NetworkContext(generation)
        return EnvironmentSnapshot(
            {"dorm": supported if self.category == "dorm" else blocked,
             "teaching": supported if self.category == "teaching" else blocked},
            self.category,
        )


class FakeProvider:
    def __init__(self, provider_id, *, session=SessionState.OFFLINE, login_result=None):
        self.provider_id = provider_id
        self.session = session
        self.login_calls = 0
        self.login_result = login_result or AuthResult(
            AuthOutcome.SUCCEEDED, provider_id, session_state=SessionState.ONLINE
        )
        self.cancelled = []
        self.session_hook = None

    def probe_environment(self, context):
        return ProviderProbe(self.provider_id, Support.VERIFIED if context.portal_identity_verified else Support.UNSUPPORTED)

    def session_status(self, context, probe, username):
        if self.session_hook:
            self.session_hook()
        return SessionResult(self.session, account_match=self.session == SessionState.ONLINE)

    def login(self, context, probe, username, credential):
        self.login_calls += 1
        return self.login_result

    def logout(self, context, probe, username):
        if self.provider_id == "teaching":
            return AuthResult(AuthOutcome.BLOCKED, self.provider_id, error_code="SRUN_LOGOUT_DISABLED")
        return AuthResult(AuthOutcome.SUCCEEDED, self.provider_id, session_state=SessionState.OFFLINE)

    def cancel_pending_operations(self, generation):
        self.cancelled.append(generation)


class FakeProcessLock:
    def __init__(self, allowed=True):
        self.allowed = allowed
        self.acquires = 0
        self.releases = 0

    def acquire(self):
        self.acquires += 1
        return self.allowed

    def release(self):
        self.releases += 1


class WindowsProductTests(unittest.TestCase):
    def tearDown(self):
        set_process_service_for_testing(None)

    def service(self, configuration=None, category="dorm", providers=None, process_lock=None):
        configuration = configuration or config()
        providers = providers or {"dorm": FakeProvider("dorm"), "teaching": FakeProvider("teaching")}
        return WindowsCampusService(
            config_loader=lambda: configuration,
            detector=FakeDetector(category),
            provider_factory=lambda _: providers,
            process_lock=process_lock or FakeProcessLock(),
        )

    def test_status_never_reads_credentials(self):
        with patch("src.szu_netlogin.windows_product.get_provider_password") as get_password:
            status = self.service().status()
        get_password.assert_not_called()
        self.assertEqual(status["networkContext"], "dorm")
        self.assertFalse(status["providers"]["teaching"]["enabled"])

    def test_process_service_is_reused(self):
        service = self.service()
        set_process_service_for_testing(service)
        self.assertIs(get_process_service(), service)
        self.assertIs(get_process_service(), service)

    def test_dorm_login_reads_credential_only_after_offline(self):
        with patch("src.szu_netlogin.windows_product.get_provider_password", return_value="synthetic-only") as get_password:
            result = self.service().login("auto")
        self.assertEqual(result.outcome, AuthOutcome.SUCCEEDED)
        get_password.assert_called_once_with(ANY, "dorm")

    def test_teaching_disabled_blocks_without_credential_read(self):
        with patch("src.szu_netlogin.windows_product.get_provider_password") as get_password:
            result = self.service(category="teaching").login("auto")
        self.assertEqual(result.error_code, "PROVIDER_DISABLED")
        get_password.assert_not_called()

    def test_disabled_providers_perform_zero_environment_probes(self):
        configuration = config()
        configuration["providers"]["dorm"]["enabled"] = False
        configuration["providers"]["teaching"]["enabled"] = False
        transport_factory = Mock()
        detector = WindowsEnvironmentDetector(teaching_transport_factory=transport_factory)
        with patch("src.szu_netlogin.windows_product.probe_gateway") as dorm_probe:
            snapshot = detector.detect(configuration, 0)
        dorm_probe.assert_not_called()
        transport_factory.assert_not_called()
        self.assertEqual(snapshot.category, "nonCampus")

    def test_disabled_teaching_performs_zero_teaching_portal_requests(self):
        configuration = config()
        transport_factory = Mock()
        detector = WindowsEnvironmentDetector(teaching_transport_factory=transport_factory)
        with (
            patch("src.szu_netlogin.windows_product.probe_gateway") as dorm_probe,
            patch("src.szu_netlogin.windows_product.classify_network_environment") as classify,
        ):
            dorm_probe.return_value = Mock(source_ip="", gateway_reachable=False)
            classify.return_value = Mock(auto_login_available=False)
            detector.detect(configuration, 0)
        dorm_probe.assert_called_once()
        transport_factory.assert_not_called()

    def test_disabled_dorm_performs_zero_gateway_requests(self):
        configuration = config()
        configuration["providers"]["dorm"]["enabled"] = False
        configuration["providers"]["teaching"]["enabled"] = True
        detector = WindowsEnvironmentDetector()
        with (
            patch("src.szu_netlogin.windows_product.probe_gateway") as dorm_probe,
            patch.object(detector, "_teaching_context", return_value=NetworkContext(0)),
        ):
            detector.detect(configuration, 0)
        dorm_probe.assert_not_called()

    def test_disabled_dorm_logout_sends_zero_provider_requests(self):
        configuration = config()
        configuration["providers"]["dorm"]["enabled"] = False
        dorm = FakeProvider("dorm")
        dorm.logout = Mock(wraps=dorm.logout)
        result = self.service(
            configuration,
            providers={"dorm": dorm, "teaching": FakeProvider("teaching")},
        ).logout("dorm")
        self.assertEqual(result.error_code, "PROVIDER_DISABLED")
        dorm.logout.assert_not_called()

    def test_teaching_logout_stays_disabled(self):
        configuration = config()
        configuration["providers"]["teaching"]["enabled"] = True
        result = self.service(configuration, category="teaching").logout("teaching")
        self.assertEqual(result.error_code, "SRUN_LOGOUT_DISABLED")

    def test_provider_toggle_updates_only_selected_switch(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "config.yaml"
            path.write_text("providers:\n  dorm:\n    enabled: true\n  teaching:\n    enabled: false\n", encoding="utf-8")
            set_provider_enabled("teaching", True, path=path)
            text = path.read_text(encoding="utf-8")
            self.assertIn("dorm:\n    enabled: true", text)
            self.assertIn("teaching:\n    enabled: true", text)

    def test_service_reuses_coordinator_and_preserves_backoff(self):
        provider = FakeProvider(
            "dorm",
            login_result=AuthResult(
                AuthOutcome.FAILED, "dorm", error_code="NET_TIMEOUT", retryable=True
            ),
        )
        service = self.service(providers={"dorm": provider, "teaching": FakeProvider("teaching")})
        with patch("src.szu_netlogin.windows_product.get_provider_password", return_value="synthetic"):
            first = service.login("auto")
            coordinator_id = id(service._coordinator)
            second = service.login("auto")
        self.assertTrue(first.retryable)
        self.assertEqual(second.error_code, "PROVIDER_BACKING_OFF")
        self.assertEqual(id(service._coordinator), coordinator_id)

    def test_service_preserves_fatal_state(self):
        provider = FakeProvider(
            "dorm",
            login_result=AuthResult(
                AuthOutcome.FAILED, "dorm", error_code="AUTH_BAD_PASSWORD"
            ),
        )
        service = self.service(providers={"dorm": provider, "teaching": FakeProvider("teaching")})
        with patch("src.szu_netlogin.windows_product.get_provider_password", return_value="synthetic"):
            service.login("auto")
            result = service.login("auto")
        self.assertEqual(result.error_code, "AUTH_BAD_PASSWORD")
        self.assertEqual(provider.login_calls, 1)

    def test_process_lock_rejects_login_and_logout(self):
        lock = FakeProcessLock(allowed=False)
        service = self.service(process_lock=lock)
        self.assertEqual(service.login("auto").error_code, "OPERATION_IN_PROGRESS")
        self.assertEqual(service.logout("dorm").error_code, "OPERATION_IN_PROGRESS")
        self.assertEqual(lock.releases, 0)

    def test_generation_change_cancels_old_provider_and_suppresses_stale_status(self):
        dorm = FakeProvider("dorm")
        service = self.service(providers={"dorm": dorm, "teaching": FakeProvider("teaching")})
        service.status()
        dorm.session_hook = service.network_changed
        status = service.status()
        self.assertEqual(status["networkContext"], "unknown")
        self.assertEqual(status["providers"]["dorm"]["errorCode"], "ENV_NETWORK_CHANGED")
        self.assertEqual(dorm.cancelled, [0])

    def test_status_selects_teaching_only_when_enabled_verified_and_offline(self):
        configuration = config()
        configuration["providers"]["dorm"]["enabled"] = False
        configuration["providers"]["teaching"]["enabled"] = True
        status = self.service(configuration, category="teaching").status()
        self.assertEqual(status["autoLoginProvider"], "teaching")

    def test_windows_srun_transport_disables_proxy_and_mounts_source_adapter(self):
        session = Mock()
        response = Mock(status_code=200, content=b"ok", headers={})
        session.get.return_value = response
        with patch("src.szu_netlogin.srun_portal.requests.Session", return_value=session):
            transport = RequestsSRunTransport()
            transport.get("/srun_portal_pc", {}, source_ip="198.51.100.27", timeout=3)
        self.assertFalse(session.trust_env)
        adapter = session.mount.call_args.args[1]
        self.assertIsInstance(adapter, SourceAddressAdapter)
        self.assertEqual(adapter.source_ip, "198.51.100.27")
        self.assertFalse(session.get.call_args.kwargs["allow_redirects"])
        self.assertNotIn("verify", session.get.call_args.kwargs)


if __name__ == "__main__":
    unittest.main()
