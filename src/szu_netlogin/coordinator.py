"""Single fail-closed coordinator for dorm and teaching providers."""

from __future__ import annotations

import threading
import time
from dataclasses import dataclass
from collections.abc import Callable, Iterable
from typing import Mapping

from .contracts import (
    AuthOutcome,
    AuthResult,
    CredentialLoader,
    NetworkAuthProvider,
    NetworkContext,
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
        self._failures: dict[str, int] = {}
        self._backoff_until: dict[str, float] = {}
        self._fatal: dict[str, str] = {}

    def advance_generation(self) -> int:
        old_generation = self.generation
        self.generation += 1
        for provider in self.providers.values():
            provider.cancel_pending_operations(old_generation)
        self._backoff_until.clear()
        return self.generation

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
        username: str,
        credential_loader: CredentialLoader,
        *,
        requested_provider: str = "auto",
        manual: bool = False,
    ) -> AuthResult:
        if not self._lock.acquire(blocking=False):
            return self._blocked("auto", "OPERATION_IN_PROGRESS")
        try:
            generations = {item.generation for item in self._contexts(context)}
            if generations != {self.generation}:
                return self._blocked("auto", "ENV_NETWORK_CHANGED")
            if self.settings.paused:
                return self._blocked("auto", "OPERATION_CANCELLED")
            if not manual and not self.settings.automatic_enabled:
                return self._blocked("auto", "OPERATION_CANCELLED")

            probes = [
                provider.probe_environment(self._context_for(context, provider.provider_id))
                for provider in self.providers.values()
            ]
            if any(probe.support == Support.AMBIGUOUS for probe in probes):
                return self._blocked("auto", "ENV_AMBIGUOUS")
            verified = [probe for probe in probes if probe.support == Support.VERIFIED]
            if len(verified) != 1:
                return self._blocked("auto", "ENV_AMBIGUOUS" if len(verified) > 1 else "ENV_NON_CAMPUS")
            probe = verified[0]
            provider = self.providers[probe.provider_id]
            provider_context = self._context_for(context, probe.provider_id)
            if requested_provider not in {"auto", probe.provider_id}:
                return self._blocked(probe.provider_id, "ENV_AMBIGUOUS")
            if not self._provider_enabled(probe.provider_id):
                return self._blocked(probe.provider_id, "PROVIDER_DISABLED")
            if probe.provider_id in self._fatal:
                return self._blocked(probe.provider_id, self._fatal[probe.provider_id])
            if self.clock() < self._backoff_until.get(probe.provider_id, 0):
                return self._blocked(probe.provider_id, "PROVIDER_BACKING_OFF")

            session = provider.session_status(provider_context, probe, username)
            if provider_context.generation != self.generation:
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

            credential = credential_loader()
            if credential is None or not credential.reveal():
                return self._blocked(probe.provider_id, "CRED_MISSING")
            if provider_context.generation != self.generation:
                return self._blocked(probe.provider_id, "ENV_NETWORK_CHANGED")
            result = provider.login(provider_context, probe, username, credential)
            if provider_context.generation != self.generation:
                return self._blocked(probe.provider_id, "ENV_NETWORK_CHANGED")
            self._record_result(result)
            return result
        finally:
            self._lock.release()

    def logout(
        self,
        context: NetworkContext | Mapping[str, NetworkContext],
        username: str,
        *,
        requested_provider: str,
    ) -> AuthResult:
        if not self._lock.acquire(blocking=False):
            return self._blocked(requested_provider, "OPERATION_IN_PROGRESS")
        try:
            generations = {item.generation for item in self._contexts(context)}
            if generations != {self.generation}:
                return self._blocked(requested_provider, "ENV_NETWORK_CHANGED")
            provider = self.providers.get(requested_provider)
            if provider is None:
                return self._blocked(requested_provider, "ENV_NON_CAMPUS")
            if not self._provider_enabled(requested_provider):
                return self._blocked(requested_provider, "PROVIDER_DISABLED")
            provider_context = self._context_for(context, requested_provider)
            probe = provider.probe_environment(provider_context)
            if probe.support != Support.VERIFIED:
                return self._blocked(requested_provider, probe.error_code or "ENV_AMBIGUOUS")
            result = provider.logout(provider_context, probe, username)
            if provider_context.generation != self.generation:
                return self._blocked(requested_provider, "ENV_NETWORK_CHANGED")
            return result
        finally:
            self._lock.release()

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
