from __future__ import annotations

import inspect
import tempfile
import threading
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
    ProcessAuthenticationLock,
    WindowsEnvironmentDetector,
    WindowsCampusService,
    get_process_service,
    set_provider_account,
    set_process_service_for_testing,
    set_provider_enabled,
)
from src.szu_netlogin.portal_detect import InternetProbe, SourceAddressAdapter
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
    def __init__(self, provider_id, *, session=SessionState.OFFLINE, login_result=None, session_result=None):
        self.provider_id = provider_id
        self.session = session
        self.login_calls = 0
        self.login_result = login_result or AuthResult(
            AuthOutcome.SUCCEEDED, provider_id, session_state=SessionState.ONLINE
        )
        self.session_result = session_result
        self.cancelled = []
        self.session_hook = None

    def probe_environment(self, context):
        return ProviderProbe(self.provider_id, Support.VERIFIED if context.portal_identity_verified else Support.UNSUPPORTED)

    def session_status(self, context, probe, username):
        if self.session_hook:
            self.session_hook()
        if self.session_result is not None:
            return self.session_result
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
    def setUp(self):
        # Product tests own their pause state; a developer VM may contain a
        # legitimate user pause marker that must neither affect nor be removed
        # by the suite.
        self.pause_patcher = patch(
            "src.szu_netlogin.windows_product.is_paused",
            return_value=False,
        )
        self.pause_patcher.start()

    def tearDown(self):
        set_process_service_for_testing(None)
        self.pause_patcher.stop()

    def service(
        self,
        configuration=None,
        category="dorm",
        providers=None,
        process_lock=None,
        direct_egress_probe=None,
    ):
        configuration = configuration or config()
        providers = providers or {"dorm": FakeProvider("dorm"), "teaching": FakeProvider("teaching")}
        kwargs = {}
        if direct_egress_probe is not None:
            kwargs["direct_egress_probe"] = direct_egress_probe
        return WindowsCampusService(
            config_loader=lambda: configuration,
            detector=FakeDetector(category),
            provider_factory=lambda _: providers,
            process_lock=process_lock or FakeProcessLock(),
            **kwargs,
        )

    def test_status_never_reads_credentials(self):
        with patch("src.szu_netlogin.windows_product.get_provider_password") as get_password:
            status = self.service().status()
        get_password.assert_not_called()
        self.assertEqual(status["networkContext"], "dorm")
        self.assertFalse(status["providers"]["teaching"]["enabled"])

    def test_service_source_cannot_regain_provider_selection_or_status_ownership(self):
        source = inspect.getsource(WindowsCampusService)
        for forbidden in (
            "_selected_provider",
            ".probe_environment(",
            ".session_status(",
        ):
            self.assertNotIn(forbidden, source)
        for required in (
            "coordinator.status(",
            "coordinator.login(",
            "coordinator.logout(",
        ):
            self.assertIn(required, source)

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

    def test_dorm_device_limit_reads_zero_credentials_and_sends_zero_login(self):
        provider = FakeProvider(
            "dorm",
            session_result=SessionResult(
                SessionState.UNKNOWN,
                error_code="AUTH_DEVICE_LIMIT",
                online_device_count=3,
                online_device_limit=3,
            ),
        )
        service = self.service(
            providers={"dorm": provider, "teaching": FakeProvider("teaching")}
        )
        with patch("src.szu_netlogin.windows_product.get_provider_password") as get_password:
            result = service.login("dorm", manual=True)
        self.assertEqual(result.error_code, "AUTH_DEVICE_LIMIT")
        self.assertEqual((provider.login_calls, get_password.call_count), (0, 0))

    def test_recovery_logs_in_once_when_direct_egress_fails_and_exact_record_is_absent(self):
        provider = FakeProvider(
            "dorm",
            session_result=SessionResult(
                SessionState.ONLINE,
                account_match=False,
                exact_online_record_present=False,
                online_device_count=2,
                online_device_limit=3,
            ),
        )
        direct = Mock(return_value=InternetProbe(False, "timeout", route="campus-direct"))
        service = self.service(
            providers={"dorm": provider, "teaching": FakeProvider("teaching")},
            direct_egress_probe=direct,
        )
        with patch(
            "src.szu_netlogin.windows_product.get_provider_password",
            return_value="synthetic-only",
        ) as get_password:
            result = service.recover_automatically()

        self.assertEqual(result.outcome, AuthOutcome.SUCCEEDED)
        self.assertEqual((get_password.call_count, provider.login_calls), (1, 1))
        direct.assert_called_once_with(ANY, "198.51.100.1")

    def test_recovery_direct_success_never_reads_credentials_or_logs_in(self):
        provider = FakeProvider(
            "dorm",
            session_result=SessionResult(
                SessionState.ONLINE,
                account_match=True,
                exact_online_record_present=True,
                online_device_count=1,
                online_device_limit=3,
            ),
        )
        service = self.service(
            providers={"dorm": provider, "teaching": FakeProvider("teaching")},
            direct_egress_probe=lambda _config, _source: InternetProbe(
                True, "ok", route="campus-direct"
            ),
        )
        with patch("src.szu_netlogin.windows_product.get_provider_password") as get_password:
            result = service.recover_automatically()

        self.assertEqual(result.error_code, "SESSION_ONLINE")
        self.assertEqual((get_password.call_count, provider.login_calls), (0, 0))

    def test_recovery_existing_record_or_full_count_never_reads_credentials(self):
        direct = lambda _config, _source: InternetProbe(
            False, "timeout", route="campus-direct"
        )
        existing = FakeProvider(
            "dorm",
            session_result=SessionResult(
                SessionState.ONLINE,
                account_match=True,
                exact_online_record_present=True,
                online_device_count=1,
                online_device_limit=3,
            ),
        )
        full = FakeProvider(
            "dorm",
            session_result=SessionResult(
                SessionState.ONLINE,
                account_match=False,
                exact_online_record_present=False,
                online_device_count=3,
                online_device_limit=3,
            ),
        )
        with patch("src.szu_netlogin.windows_product.get_provider_password") as get_password:
            existing_result = self.service(
                providers={"dorm": existing, "teaching": FakeProvider("teaching")},
                direct_egress_probe=direct,
            ).recover_automatically()
            full_result = self.service(
                providers={"dorm": full, "teaching": FakeProvider("teaching")},
                direct_egress_probe=direct,
            ).recover_automatically()

        self.assertEqual(existing_result.error_code, "NET_CAMPUS_EGRESS_UNAVAILABLE")
        self.assertEqual(full_result.error_code, "AUTH_DEVICE_LIMIT")
        self.assertEqual((get_password.call_count, existing.login_calls, full.login_calls), (0, 0, 0))

    def test_force_login_is_explicit_and_dorm_only(self):
        provider = FakeProvider(
            "dorm",
            session_result=SessionResult(
                SessionState.UNKNOWN,
                error_code="AUTH_DEVICE_LIMIT",
                online_device_count=3,
                online_device_limit=3,
            ),
        )
        service = self.service(
            providers={"dorm": provider, "teaching": FakeProvider("teaching")}
        )
        with patch("src.szu_netlogin.windows_product.get_provider_password", return_value="synthetic"):
            result = service.force_login("dorm")
        self.assertEqual(result.outcome, AuthOutcome.SUCCEEDED)
        self.assertEqual(provider.login_calls, 1)
        self.assertEqual(
            service.force_login("teaching").error_code,
            "AUTH_DEVICE_REPLACEMENT_UNSUPPORTED",
        )

    def test_status_contains_aggregate_device_budget_without_identities(self):
        provider = FakeProvider(
            "dorm",
            session_result=SessionResult(
                SessionState.UNKNOWN,
                error_code="AUTH_DEVICE_LIMIT",
                online_device_count=3,
                online_device_limit=3,
            ),
        )
        status = self.service(
            providers={"dorm": provider, "teaching": FakeProvider("teaching")}
        ).status()
        dorm = status["providers"]["dorm"]
        self.assertEqual((dorm["onlineDeviceCount"], dorm["onlineDeviceLimit"]), (3, 3))
        self.assertNotIn("mac", str(dorm).lower())

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

    def test_provider_accounts_are_independent_and_dorm_keeps_legacy_value_in_sync(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "config.yaml"
            path.write_text(
                "providers:\n"
                "  dorm:\n    accountLabel: \"old-dorm\"\n"
                "  teaching:\n    accountLabel: \"old-teaching\"\n"
                "user:\n  username: \"old-dorm\"\n",
                encoding="utf-8",
            )
            set_provider_account("teaching", "new-teaching", path=path)
            set_provider_account("dorm", "new-dorm", path=path)
            text = path.read_text(encoding="utf-8")

        self.assertIn('accountLabel: "new-teaching"', text)
        self.assertIn('accountLabel: "new-dorm"', text)
        self.assertIn('username: "new-dorm"', text)

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

    def test_process_lock_rejects_status_login_and_logout(self):
        lock = FakeProcessLock(allowed=False)
        service = self.service(process_lock=lock)
        self.assertEqual(
            service.status()["providers"]["dorm"]["errorCode"],
            "OPERATION_IN_PROGRESS",
        )
        self.assertEqual(service.login("auto").error_code, "OPERATION_IN_PROGRESS")
        self.assertEqual(service.logout("dorm").error_code, "OPERATION_IN_PROGRESS")
        self.assertEqual(lock.releases, 0)

    def test_status_is_rejected_while_authentication_holds_process_lock(self):
        started = threading.Event()
        release = threading.Event()

        class BlockingProvider(FakeProvider):
            def login(self, context, probe, username, credential):
                started.set()
                release.wait(timeout=2)
                return super().login(context, probe, username, credential)

        with tempfile.TemporaryDirectory() as directory:
            service = self.service(
                providers={
                    "dorm": BlockingProvider("dorm"),
                    "teaching": FakeProvider("teaching"),
                },
                process_lock=ProcessAuthenticationLock(
                    Path(directory) / "campus-auth-operation.lock"
                ),
            )
            results = []
            with patch(
                "src.szu_netlogin.windows_product.get_provider_password",
                return_value="synthetic-only",
            ):
                thread = threading.Thread(target=lambda: results.append(service.login("auto")))
                thread.start()
                try:
                    self.assertTrue(started.wait(timeout=1))
                    status = service.status()
                finally:
                    release.set()
                    thread.join(timeout=2)

        self.assertFalse(thread.is_alive())
        self.assertEqual(results[0].outcome, AuthOutcome.SUCCEEDED)
        self.assertEqual(
            status["providers"]["dorm"]["errorCode"],
            "OPERATION_IN_PROGRESS",
        )

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
