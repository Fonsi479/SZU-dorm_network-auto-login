"""Single fail-closed coordinator for dorm and teaching providers."""

from __future__ import annotations

import threading
import time
from dataclasses import dataclass
from collections.abc import Callable, Iterable, Mapping

from .contracts import (
    AuthOutcome,
    AuthResult,
    CredentialLoader,
    NetworkAuthProvider,
    NetworkContext,
    ProviderProbe,
    SessionResult,
    SessionState,
    Support,
)


_FATAL_CODES = {
    "AUTH_BAD_PASSWORD",
    "AUTH_ACCOUNT_NOT_FOUND",
    "AUTH_DEVICE_LIMIT",
    "AUTH_ACCOUNT_BLOCKED",
    "AUTH_PRODUCT_SUFFIX_INVALID",
    "NET_TLS_FAILED",
}
_BACKOFF_SECONDS = (120, 300, 600, 900)


@dataclass
class CoordinatorSettings:
    dorm_enabled: bool = True
    teaching_enabled: bool = False
    automatic_enabled: bool = True
    paused: bool = False


@dataclass(frozen=True)
class CoordinatorProviderStatus:
    enabled: bool
    session: SessionResult


@dataclass(frozen=True)
class CoordinatorStatus:
    network_context: str
    providers: Mapping[str, CoordinatorProviderStatus]
    generation: int
    auto_login_provider: str | None = None
    error_code: str = ""


class CampusNetworkCoordinator:
    def __init__(
        self,
        providers: Iterable[NetworkAuthProvider],
        *,
        settings: CoordinatorSettings | None = None,
        clock: Callable[[], float] = time.monotonic,
        jitter: Callable[[], float] = lambda: 0.0,
    ) -> None:
        self.providers = {provider.provider_id: provider for provider in providers}
        self.settings = settings or CoordinatorSettings()
        self.clock = clock
        self.jitter = jitter
        self.generation = 0
        self._lock = threading.Lock()
        self._generation_lock = threading.RLock()
        self._failures: dict[str, int] = {}
        self._backoff_until: dict[str, float] = {}
        self._fatal: dict[str, str] = {}

    def advance_generation(self) -> int:
        with self._generation_lock:
            old_generation = self.generation
            self.generation += 1
            new_generation = self.generation
        for provider in self.providers.values():
            provider.cancel_pending_operations(old_generation)
        self._backoff_until.clear()
        return new_generation

    def update_runtime(
        self,
        providers: Iterable[NetworkAuthProvider],
        settings: CoordinatorSettings,
    ) -> None:
        """Refresh runtime dependencies without resetting safety history."""
        self.providers = {provider.provider_id: provider for provider in providers}
        self.settings = settings

    def login(
        self,
        context: NetworkContext | Mapping[str, NetworkContext],
        username: str | Mapping[str, str],
        credential_loader: CredentialLoader | Mapping[str, CredentialLoader],
        *,
        requested_provider: str = "auto",
        manual: bool = False,
    ) -> AuthResult:
        if not self._lock.acquire(blocking=False):
            return self._blocked("auto", "OPERATION_IN_PROGRESS")
        try:
            operation_generation = self._current_generation()
            generations = {item.generation for item in self._contexts(context)}
            if generations != {operation_generation}:
                return self._blocked("auto", "ENV_NETWORK_CHANGED")
            if self.settings.paused:
                return self._blocked("auto", "OPERATION_CANCELLED")
            if not manual and not self.settings.automatic_enabled:
                return self._blocked("auto", "OPERATION_CANCELLED")

            provider, probe, error_code = self._select_provider(context, requested_provider)
            if error_code:
                return self._blocked(probe.provider_id if probe else "auto", error_code)
            assert provider is not None and probe is not None
            if not self._contexts_are_current(context, operation_generation):
                return self._blocked(probe.provider_id, "ENV_NETWORK_CHANGED")
            provider_context = self._context_for(context, probe.provider_id)
            if not self._provider_enabled(probe.provider_id):
                return self._blocked(probe.provider_id, "PROVIDER_DISABLED")
            if probe.provider_id in self._fatal:
                return self._blocked(probe.provider_id, self._fatal[probe.provider_id])
            if self.clock() < self._backoff_until.get(probe.provider_id, 0):
                return self._blocked(probe.provider_id, "PROVIDER_BACKING_OFF")

            selected_username = self._username_for(username, probe.provider_id)
            session = provider.session_status(provider_context, probe, selected_username)
            if not self._contexts_are_current(context, operation_generation):
                return self._blocked(probe.provider_id, "ENV_NETWORK_CHANGED")
            if session.state == SessionState.ONLINE and session.account_match is True:
                return AuthResult(
                    AuthOutcome.UNCHANGED,
                    probe.provider_id,
                    session_state=SessionState.ONLINE,
                    error_code="SESSION_ONLINE",
                )
            if session.state != SessionState.OFFLINE:
                return self._blocked(probe.provider_id, session.error_code or "SESSION_UNKNOWN")

            with self._generation_lock:
                if self.generation != operation_generation:
                    return self._blocked(probe.provider_id, "ENV_NETWORK_CHANGED")
                credential = self._credential_for(
                    credential_loader, probe.provider_id
                )
                if credential is None or not credential.reveal():
                    return self._blocked(probe.provider_id, "CRED_MISSING")
            if not self._contexts_are_current(context, operation_generation):
                return self._blocked(probe.provider_id, "ENV_NETWORK_CHANGED")
            result = provider.login(provider_context, probe, selected_username, credential)
            if not self._contexts_are_current(context, operation_generation):
                return self._blocked(probe.provider_id, "ENV_NETWORK_CHANGED")
            self._record_result(result)
            return result
        finally:
            self._lock.release()

    def logout(
        self,
        context: NetworkContext | Mapping[str, NetworkContext],
        username: str | Mapping[str, str],
        *,
        requested_provider: str,
    ) -> AuthResult:
        if not self._lock.acquire(blocking=False):
            return self._blocked(requested_provider, "OPERATION_IN_PROGRESS")
        try:
            operation_generation = self._current_generation()
            generations = {item.generation for item in self._contexts(context)}
            if generations != {operation_generation}:
                return self._blocked(requested_provider, "ENV_NETWORK_CHANGED")
            if requested_provider == "auto":
                provider, probe, error_code = self._select_provider(context, requested_provider)
                if error_code:
                    return self._blocked(probe.provider_id if probe else "auto", error_code)
                assert provider is not None and probe is not None
                provider_id = probe.provider_id
            else:
                provider_id = requested_provider
                provider = self.providers.get(provider_id)
                if provider is None:
                    return self._blocked(provider_id, "ENV_NON_CAMPUS")
                if not self._provider_enabled(provider_id):
                    return self._blocked(provider_id, "PROVIDER_DISABLED")
                probe = provider.probe_environment(self._context_for(context, provider_id))
                if probe.support != Support.VERIFIED:
                    return self._blocked(provider_id, probe.error_code or "ENV_AMBIGUOUS")
            if not self._contexts_are_current(context, operation_generation):
                return self._blocked(provider_id, "ENV_NETWORK_CHANGED")
            if not self._provider_enabled(provider_id):
                return self._blocked(provider_id, "PROVIDER_DISABLED")
            provider_context = self._context_for(context, provider_id)
            result = provider.logout(
                provider_context,
                probe,
                self._username_for(username, provider_id),
            )
            if not self._contexts_are_current(context, operation_generation):
                return self._blocked(provider_id, "ENV_NETWORK_CHANGED")
            return result
        finally:
            self._lock.release()

    def status(
        self,
        context: NetworkContext | Mapping[str, NetworkContext],
        usernames: str | Mapping[str, str],
    ) -> CoordinatorStatus:
        if not self._lock.acquire(blocking=False):
            return self._status_error("OPERATION_IN_PROGRESS")
        try:
            operation_generation = self._current_generation()
            if not self._contexts_are_current(context, operation_generation):
                return self._status_error("ENV_NETWORK_CHANGED")
            probes = self._probe_all(context)
            if not self._contexts_are_current(context, operation_generation):
                return self._status_error("ENV_NETWORK_CHANGED")

            network_context = self._network_context(probes)
            provider_status: dict[str, CoordinatorProviderStatus] = {}
            verified = {
                probe.provider_id: probe
                for probe in probes
                if probe.support == Support.VERIFIED
            }
            environment_ambiguous = network_context == "ambiguous"
            for provider_id, provider in self.providers.items():
                enabled = self._provider_enabled(provider_id)
                probe = next(
                    (item for item in probes if item.provider_id == provider_id),
                    ProviderProbe(provider_id, Support.UNSUPPORTED, error_code="ENV_NON_CAMPUS"),
                )
                if not enabled:
                    session = SessionResult(SessionState.BLOCKED, error_code="PROVIDER_DISABLED")
                elif environment_ambiguous:
                    session = SessionResult(SessionState.BLOCKED, error_code="ENV_AMBIGUOUS")
                elif probe.support != Support.VERIFIED:
                    session = SessionResult(
                        SessionState.UNKNOWN,
                        error_code=probe.error_code or "ENV_NON_CAMPUS",
                    )
                else:
                    provider_context = self._context_for(context, provider_id)
                    session = provider.session_status(
                        provider_context,
                        probe,
                        self._username_for(usernames, provider_id),
                    )
                    if not self._contexts_are_current(
                        context, operation_generation
                    ):
                        return self._status_error("ENV_NETWORK_CHANGED")
                provider_status[provider_id] = CoordinatorProviderStatus(enabled, session)

            auto_login_provider = None
            if len(verified) == 1 and not environment_ambiguous:
                provider_id = next(iter(verified))
                status = provider_status.get(provider_id)
                if status and status.enabled and status.session.state == SessionState.OFFLINE:
                    auto_login_provider = provider_id
            with self._generation_lock:
                if self.generation != operation_generation:
                    return self._status_error("ENV_NETWORK_CHANGED")
                return CoordinatorStatus(
                    network_context=network_context,
                    providers=provider_status,
                    generation=operation_generation,
                    auto_login_provider=auto_login_provider,
                )
        finally:
            self._lock.release()

    def _select_provider(
        self,
        context: NetworkContext | Mapping[str, NetworkContext],
        requested_provider: str,
    ) -> tuple[NetworkAuthProvider | None, ProviderProbe | None, str]:
        probes = self._probe_all(context)
        disabled_by_id = {
            probe.provider_id: probe
            for probe in probes
            if probe.error_code == "PROVIDER_DISABLED"
        }
        if requested_provider != "auto" and requested_provider in disabled_by_id:
            return None, disabled_by_id[requested_provider], "PROVIDER_DISABLED"
        if any(probe.support == Support.AMBIGUOUS for probe in probes):
            return None, None, "ENV_AMBIGUOUS"
        verified = [probe for probe in probes if probe.support == Support.VERIFIED]
        if len(verified) != 1:
            disabled = [
                probe
                for probe in probes
                if probe.error_code == "PROVIDER_DISABLED"
                and self._context_for(
                    context, probe.provider_id
                ).portal_identity_verified
            ]
            if not verified and len(disabled) == 1:
                return None, disabled[0], "PROVIDER_DISABLED"
            if (
                not verified
                and len(self.providers) == 1
                and len(disabled_by_id) == 1
            ):
                disabled_probe = next(iter(disabled_by_id.values()))
                return None, disabled_probe, "PROVIDER_DISABLED"
            return None, None, "ENV_AMBIGUOUS" if len(verified) > 1 else "ENV_NON_CAMPUS"
        probe = verified[0]
        if requested_provider not in {"auto", probe.provider_id}:
            return None, probe, "ENV_AMBIGUOUS"
        return self.providers[probe.provider_id], probe, ""

    def _probe_all(
        self,
        context: NetworkContext | Mapping[str, NetworkContext],
    ) -> list[ProviderProbe]:
        probes: list[ProviderProbe] = []
        for provider in self.providers.values():
            if not self._provider_enabled(provider.provider_id):
                probes.append(
                    ProviderProbe(
                        provider.provider_id,
                        Support.UNSUPPORTED,
                        error_code="PROVIDER_DISABLED",
                    )
                )
                continue
            probes.append(
                provider.probe_environment(
                    self._context_for(context, provider.provider_id)
                )
            )
        return probes

    @staticmethod
    def _network_context(probes: Iterable[ProviderProbe]) -> str:
        probes = list(probes)
        verified = [probe for probe in probes if probe.support == Support.VERIFIED]
        if any(probe.support == Support.AMBIGUOUS for probe in probes) or len(verified) > 1:
            return "ambiguous"
        return verified[0].provider_id if verified else "nonCampus"

    def _contexts_are_current(
        self,
        context: NetworkContext | Mapping[str, NetworkContext],
        expected_generation: int,
    ) -> bool:
        with self._generation_lock:
            return (
                self.generation == expected_generation
                and {item.generation for item in self._contexts(context)}
                == {expected_generation}
            )

    def _current_generation(self) -> int:
        with self._generation_lock:
            return self.generation

    @staticmethod
    def _username_for(username: str | Mapping[str, str], provider_id: str) -> str:
        return username.get(provider_id, "") if isinstance(username, Mapping) else username

    @staticmethod
    def _credential_for(
        credential_loader: CredentialLoader | Mapping[str, CredentialLoader],
        provider_id: str,
    ):
        if isinstance(credential_loader, Mapping):
            loader = credential_loader.get(provider_id)
            return loader() if loader else None
        return credential_loader()

    def _status_error(self, error_code: str) -> CoordinatorStatus:
        return CoordinatorStatus(
            network_context="unknown",
            providers={},
            generation=self.generation,
            error_code=error_code,
        )

    def _provider_enabled(self, provider_id: str) -> bool:
        if provider_id == "dorm":
            return self.settings.dorm_enabled
        if provider_id == "teaching":
            return self.settings.teaching_enabled
        return False

    @staticmethod
    def _context_for(
        context: NetworkContext | Mapping[str, NetworkContext], provider_id: str
    ) -> NetworkContext:
        if isinstance(context, NetworkContext):
            return context
        return context.get(provider_id, NetworkContext(-1))

    @staticmethod
    def _contexts(
        context: NetworkContext | Mapping[str, NetworkContext]
    ) -> tuple[NetworkContext, ...]:
        if isinstance(context, NetworkContext):
            return (context,)
        return tuple(context.values()) or (NetworkContext(-1),)

    def _record_result(self, result: AuthResult) -> None:
        provider_id = result.provider_id
        if result.outcome in {AuthOutcome.SUCCEEDED, AuthOutcome.UNCHANGED}:
            self._failures.pop(provider_id, None)
            self._backoff_until.pop(provider_id, None)
            return
        if result.error_code in _FATAL_CODES:
            self._fatal[provider_id] = result.error_code
            return
        if result.retryable:
            count = self._failures.get(provider_id, 0) + 1
            self._failures[provider_id] = count
            base = _BACKOFF_SECONDS[min(count - 1, len(_BACKOFF_SECONDS) - 1)]
            jitter = min(max(self.jitter(), 0.0), 0.15)
            self._backoff_until[provider_id] = self.clock() + base * (1 + jitter)

    @staticmethod
    def _blocked(provider_id: str, error_code: str) -> AuthResult:
        return AuthResult(AuthOutcome.BLOCKED, provider_id, error_code=error_code)
