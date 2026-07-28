"""Adapter that preserves the existing source-bound Dr.COM implementation."""

from __future__ import annotations

from collections.abc import Callable

from ..contracts import (
    AuthOutcome,
    AuthResult,
    CredentialHandle,
    NetworkContext,
    ProviderProbe,
    SessionResult,
    SessionState,
    Support,
)
from ..dorm_drcom_client import DormDrcomClient


class DormDrcomProvider:
    provider_id = "dorm"

    def __init__(self, config: dict, client_factory: Callable[[dict], DormDrcomClient] = DormDrcomClient) -> None:
        self.config = config
        self.client = client_factory(config)
        self._cancelled_generations: set[int] = set()

    def probe_environment(self, context: NetworkContext) -> ProviderProbe:
        if not context.portal_identity_verified:
            return ProviderProbe(self.provider_id, Support.UNSUPPORTED, error_code="ENV_PORTAL_IDENTITY_UNVERIFIED")
        if not context.source_route_bound or not context.source_ip:
            return ProviderProbe(self.provider_id, Support.UNSUPPORTED, error_code="ENV_SOURCE_ROUTE_UNVERIFIED")
        return ProviderProbe(
            self.provider_id,
            Support.VERIFIED,
            source_ip=context.source_ip,
            client_ip=context.source_ip,
            portal_host="dorm-gateway",
            evidence=("gateway", "source-route"),
        )

    def session_status(
        self, context: NetworkContext, probe: ProviderProbe, username: str
    ) -> SessionResult:
        if context.generation in self._cancelled_generations:
            return SessionResult(SessionState.BLOCKED, error_code="OPERATION_CANCELLED")
        fact = self.client.session_fact(username, probe.source_ip)
        if fact.state == "online":
            return SessionResult(
                SessionState.ONLINE,
                account_match=fact.matches(username, probe.source_ip),
                client_ip=fact.ip,
            )
        if fact.state == "offline":
            return SessionResult(SessionState.OFFLINE)
        return SessionResult(SessionState.UNKNOWN, error_code="SESSION_UNKNOWN")

    def login(
        self,
        context: NetworkContext,
        probe: ProviderProbe,
        username: str,
        credential: CredentialHandle,
    ) -> AuthResult:
        if context.generation in self._cancelled_generations:
            return AuthResult(AuthOutcome.CANCELLED, self.provider_id, error_code="OPERATION_CANCELLED")
        result = self.client.login_with_result(
            username,
            credential.reveal(),
            known_source_ip=probe.source_ip,
        )
        if result.status == "success":
            return AuthResult(
                AuthOutcome.SUCCEEDED,
                self.provider_id,
                session_state=SessionState.ONLINE,
                client_ip=result.source_ip,
            )
        return AuthResult(
            AuthOutcome.FAILED if result.status == "failed" else AuthOutcome.BLOCKED,
            self.provider_id,
            error_code=result.reason or "AUTH_NOT_CONFIRMED",
            client_ip=result.source_ip,
            retryable=result.reason in {"gateway_unreachable", "request_exception", "server_response_uncertain"},
        )

    def logout(self, context: NetworkContext, probe: ProviderProbe, username: str) -> AuthResult:
        result = self.client.logout(username)
        return AuthResult(
            AuthOutcome.SUCCEEDED if result.status == "success" else AuthOutcome.FAILED,
            self.provider_id,
            session_state=SessionState.OFFLINE if result.status == "success" else SessionState.UNKNOWN,
            error_code="" if result.status == "success" else result.reason,
        )

    def cancel_pending_operations(self, generation: int) -> None:
        self._cancelled_generations.add(generation)
