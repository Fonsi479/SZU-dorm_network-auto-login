from __future__ import annotations

import threading
import unittest

from src.szu_netlogin.contracts import (
    AuthOutcome,
    AuthResult,
    CredentialHandle,
    NetworkContext,
    ProviderProbe,
    SessionResult,
    SessionState,
    Support,
)
from src.szu_netlogin.coordinator import CampusNetworkCoordinator, CoordinatorSettings


class StubProvider:
    def __init__(self, provider_id, support=Support.VERIFIED, session=SessionState.OFFLINE, login_result=None):
        self.provider_id = provider_id
        self.support = support
        self.session = session
        self.login_result = login_result or AuthResult(AuthOutcome.SUCCEEDED, provider_id)
        self.probe_calls = 0
        self.login_calls = 0
        self.session_calls = 0
        self.cancelled = []

    def probe_environment(self, context):
        self.probe_calls += 1
        return ProviderProbe(self.provider_id, self.support, source_ip="198.51.100.1")

    def session_status(self, context, probe, username):
        self.session_calls += 1
        return SessionResult(self.session, account_match=True if self.session == SessionState.ONLINE else None)

    def login(self, context, probe, username, credential):
        self.login_calls += 1
        return self.login_result

    def logout(self, context, probe, username):
        return AuthResult(AuthOutcome.SUCCEEDED, self.provider_id)

    def cancel_pending_operations(self, generation):
        self.cancelled.append(generation)


class CredentialSpy:
    def __init__(self):
        self.calls = 0

    def __call__(self):
        self.calls += 1
        return CredentialHandle("synthetic-only")


class CoordinatorTests(unittest.TestCase):
    def context(self):
        return NetworkContext(0)

    def test_teaching_is_disabled_by_default_with_zero_credential_reads(self):
        spy = CredentialSpy()
        provider = StubProvider("teaching")
        result = CampusNetworkCoordinator([provider]).login(
            self.context(), "synthetic", spy
        )
        self.assertEqual(result.error_code, "PROVIDER_DISABLED")
        self.assertEqual(spy.calls, 0)
        self.assertEqual(provider.probe_calls, 0)

    def test_explicit_disabled_provider_is_not_probed(self):
        dorm = StubProvider("dorm", support=Support.UNSUPPORTED)
        teaching = StubProvider("teaching")
        result = CampusNetworkCoordinator([dorm, teaching]).login(
            self.context(),
            "synthetic",
            CredentialSpy(),
            requested_provider="teaching",
        )
        self.assertEqual(result.error_code, "PROVIDER_DISABLED")
        self.assertEqual(teaching.probe_calls, 0)

    def test_non_campus_has_zero_credential_reads(self):
        spy = CredentialSpy()
        result = CampusNetworkCoordinator([
            StubProvider("dorm", support=Support.UNSUPPORTED)
        ]).login(self.context(), "synthetic", spy)
        self.assertEqual(result.error_code, "ENV_NON_CAMPUS")
        self.assertEqual(spy.calls, 0)

    def test_two_verified_providers_are_ambiguous(self):
        spy = CredentialSpy()
        result = CampusNetworkCoordinator([
            StubProvider("dorm"), StubProvider("teaching")
        ], settings=CoordinatorSettings(teaching_enabled=True)).login(self.context(), "synthetic", spy)
        self.assertEqual(result.error_code, "ENV_AMBIGUOUS")
        self.assertEqual(spy.calls, 0)

    def test_unknown_session_has_zero_credential_reads(self):
        spy = CredentialSpy()
        provider = StubProvider("dorm", session=SessionState.UNKNOWN)
        result = CampusNetworkCoordinator([provider]).login(self.context(), "synthetic", spy)
        self.assertEqual(result.error_code, "SESSION_UNKNOWN")
        self.assertEqual((spy.calls, provider.login_calls), (0, 0))

    def test_already_online_has_zero_credential_reads(self):
        spy = CredentialSpy()
        provider = StubProvider("dorm", session=SessionState.ONLINE)
        result = CampusNetworkCoordinator([provider]).login(self.context(), "synthetic", spy)
        self.assertEqual(result.outcome, AuthOutcome.UNCHANGED)
        self.assertEqual((spy.calls, provider.login_calls), (0, 0))

    def test_offline_reads_one_credential_and_logs_in_once(self):
        spy = CredentialSpy()
        provider = StubProvider("dorm")
        result = CampusNetworkCoordinator([provider]).login(self.context(), "synthetic", spy)
        self.assertEqual(result.outcome, AuthOutcome.SUCCEEDED)
        self.assertEqual((spy.calls, provider.login_calls), (1, 1))

    def test_stale_generation_has_zero_credential_reads(self):
        spy = CredentialSpy()
        coordinator = CampusNetworkCoordinator([StubProvider("dorm")])
        coordinator.advance_generation()
        result = coordinator.login(self.context(), "synthetic", spy)
        self.assertEqual(result.error_code, "ENV_NETWORK_CHANGED")
        self.assertEqual(spy.calls, 0)

    def test_generation_change_after_session_check_prevents_credential_read(self):
        reached_state_check = threading.Event()
        release_state_check = threading.Event()

        class RacingSession:
            account_match = None
            error_code = ""

            def __init__(self):
                self.reads = 0

            @property
            def state(self):
                self.reads += 1
                if self.reads == 2:
                    reached_state_check.set()
                    release_state_check.wait(timeout=2)
                return SessionState.OFFLINE

        class RacingProvider(StubProvider):
            def session_status(self, context, probe, username):
                return RacingSession()

        spy = CredentialSpy()
        coordinator = CampusNetworkCoordinator([RacingProvider("dorm")])
        results = []
        thread = threading.Thread(
            target=lambda: results.append(
                coordinator.login(self.context(), "synthetic", spy)
            )
        )
        thread.start()
        self.assertTrue(reached_state_check.wait(timeout=1))
        coordinator.advance_generation()
        release_state_check.set()
        thread.join(timeout=2)

        self.assertFalse(thread.is_alive())
        self.assertEqual(results[0].error_code, "ENV_NETWORK_CHANGED")
        self.assertEqual(spy.calls, 0)

    def test_retryable_failure_enters_provider_backoff(self):
        now = [100.0]
        provider = StubProvider(
            "dorm",
            login_result=AuthResult(AuthOutcome.FAILED, "dorm", error_code="NET_TIMEOUT", retryable=True),
        )
        coordinator = CampusNetworkCoordinator([provider], clock=lambda: now[0])
        coordinator.login(self.context(), "synthetic", CredentialSpy())
        second_spy = CredentialSpy()
        result = coordinator.login(self.context(), "synthetic", second_spy)
        self.assertEqual(result.error_code, "PROVIDER_BACKING_OFF")
        self.assertEqual(second_spy.calls, 0)

    def test_fatal_failure_stays_fused_across_generation(self):
        provider = StubProvider(
            "dorm",
            login_result=AuthResult(AuthOutcome.FAILED, "dorm", error_code="AUTH_BAD_PASSWORD"),
        )
        coordinator = CampusNetworkCoordinator([provider])
        coordinator.login(self.context(), "synthetic", CredentialSpy())
        coordinator.advance_generation()
        spy = CredentialSpy()
        result = coordinator.login(NetworkContext(1), "synthetic", spy)
        self.assertEqual(result.error_code, "AUTH_BAD_PASSWORD")
        self.assertEqual(spy.calls, 0)

    def test_logout_is_rejected_while_login_is_in_progress(self):
        started = threading.Event()
        release = threading.Event()

        class BlockingProvider(StubProvider):
            def login(self, context, probe, username, credential):
                started.set()
                release.wait(timeout=2)
                return AuthResult(AuthOutcome.SUCCEEDED, self.provider_id)

        provider = BlockingProvider("dorm")
        coordinator = CampusNetworkCoordinator([provider])
        thread = threading.Thread(
            target=lambda: coordinator.login(self.context(), "synthetic", CredentialSpy())
        )
        thread.start()
        self.assertTrue(started.wait(timeout=1))
        result = coordinator.logout(self.context(), "synthetic", requested_provider="dorm")
        release.set()
        thread.join(timeout=2)
        self.assertEqual(result.error_code, "OPERATION_IN_PROGRESS")

    def test_status_is_rejected_while_login_is_in_progress(self):
        started = threading.Event()
        release = threading.Event()

        class BlockingProvider(StubProvider):
            def login(self, context, probe, username, credential):
                started.set()
                release.wait(timeout=2)
                return AuthResult(AuthOutcome.SUCCEEDED, self.provider_id)

        provider = BlockingProvider("dorm")
        coordinator = CampusNetworkCoordinator([provider])
        thread = threading.Thread(
            target=lambda: coordinator.login(
                self.context(), "synthetic", CredentialSpy()
            )
        )
        thread.start()
        self.assertTrue(started.wait(timeout=1))
        status = coordinator.status(self.context(), "synthetic")
        release.set()
        thread.join(timeout=2)
        self.assertEqual(status.error_code, "OPERATION_IN_PROGRESS")
        self.assertFalse(thread.is_alive())

    def test_status_owns_provider_selection_without_credentials(self):
        dorm = StubProvider("dorm", session=SessionState.OFFLINE)
        teaching = StubProvider("teaching", support=Support.UNSUPPORTED)
        coordinator = CampusNetworkCoordinator([dorm, teaching])

        status = coordinator.status(
            {"dorm": self.context(), "teaching": self.context()},
            {"dorm": "synthetic-dorm", "teaching": "synthetic-teaching"},
        )

        self.assertEqual(status.network_context, "dorm")
        self.assertEqual(status.auto_login_provider, "dorm")
        self.assertEqual(status.providers["dorm"].session.state, SessionState.OFFLINE)
        self.assertFalse(status.providers["teaching"].enabled)
        self.assertEqual((dorm.session_calls, teaching.session_calls), (1, 0))

    def test_status_generation_change_returns_no_stale_provider_data(self):
        reached_state_check = threading.Event()
        release_state_check = threading.Event()

        class RacingSession:
            account_match = None
            error_code = ""

            @property
            def state(self):
                reached_state_check.set()
                release_state_check.wait(timeout=2)
                return SessionState.OFFLINE

        class RacingProvider(StubProvider):
            def session_status(self, context, probe, username):
                return RacingSession()

        coordinator = CampusNetworkCoordinator([RacingProvider("dorm")])
        statuses = []
        thread = threading.Thread(
            target=lambda: statuses.append(
                coordinator.status(self.context(), "synthetic")
            )
        )
        thread.start()
        self.assertTrue(reached_state_check.wait(timeout=1))
        new_generation = coordinator.advance_generation()
        release_state_check.set()
        thread.join(timeout=2)

        self.assertFalse(thread.is_alive())
        self.assertEqual(statuses[0].error_code, "ENV_NETWORK_CHANGED")
        self.assertEqual(statuses[0].generation, new_generation)
        self.assertEqual(statuses[0].providers, {})

    def test_login_mapping_opens_only_coordinator_selected_credential(self):
        dorm = StubProvider("dorm")
        teaching = StubProvider("teaching", support=Support.UNSUPPORTED)
        dorm_spy = CredentialSpy()
        teaching_spy = CredentialSpy()
        coordinator = CampusNetworkCoordinator([dorm, teaching])

        result = coordinator.login(
            {"dorm": self.context(), "teaching": self.context()},
            {"dorm": "synthetic-dorm", "teaching": "synthetic-teaching"},
            {"dorm": dorm_spy, "teaching": teaching_spy},
        )

        self.assertEqual(result.outcome, AuthOutcome.SUCCEEDED)
        self.assertEqual((dorm_spy.calls, teaching_spy.calls), (1, 0))

    def test_auto_logout_selection_stays_inside_coordinator(self):
        dorm = StubProvider("dorm")
        teaching = StubProvider("teaching", support=Support.UNSUPPORTED)
        coordinator = CampusNetworkCoordinator([dorm, teaching])

        result = coordinator.logout(
            {"dorm": self.context(), "teaching": self.context()},
            {"dorm": "synthetic-dorm", "teaching": "synthetic-teaching"},
            requested_provider="auto",
        )

        self.assertEqual(result.outcome, AuthOutcome.SUCCEEDED)
        self.assertEqual(result.provider_id, "dorm")


if __name__ == "__main__":
    unittest.main()
