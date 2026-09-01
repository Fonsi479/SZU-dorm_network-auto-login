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
from ..dorm_drcom_client import DORM_ONLINE_DEVICE_LIMIT, DormDrcomClient


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
        online_device_count = _optional_nonnegative_int(
            getattr(fact, "online_device_count", None)
        )
        online_device_limit = _optional_positive_int(
            getattr(fact, "online_device_limit", DORM_ONLINE_DEVICE_LIMIT)
        ) or DORM_ONLINE_DEVICE_LIMIT
        exact_online_record_present = _optional_bool(
            getattr(fact, "exact_online_record_present", None)
        )
        if fact.state == "online":
            return SessionResult(
                SessionState.ONLINE,
                account_match=fact.matches(username, probe.source_ip),
                exact_online_record_present=exact_online_record_present,
                client_ip=fact.ip,
                online_device_count=online_device_count,
                online_device_limit=online_device_limit,
            )
        if fact.state == "offline":
            # A local offline status is actionable only when the portal's
            # account-wide list was readable and yielded a trustworthy count.
            # Unknown counts fail closed before any credential is opened.
            if online_device_count is None:
                return SessionResult(
                    SessionState.UNKNOWN,
                    exact_online_record_present=exact_online_record_present,
                    error_code="SESSION_UNKNOWN",
                    online_device_limit=DORM_ONLINE_DEVICE_LIMIT,
                )
            if online_device_count >= DORM_ONLINE_DEVICE_LIMIT:
                return SessionResult(
                    SessionState.OFFLINE,
                    exact_online_record_present=exact_online_record_present,
                    error_code="AUTH_DEVICE_LIMIT",
                    online_device_count=online_device_count,
                    online_device_limit=online_device_limit,
                )
            return SessionResult(
                SessionState.OFFLINE,
                exact_online_record_present=exact_online_record_present,
                online_device_count=online_device_count,
                online_device_limit=online_device_limit,
            )
        return SessionResult(
            SessionState.UNKNOWN,
            exact_online_record_present=exact_online_record_present,
            error_code="SESSION_UNKNOWN",
            online_device_count=online_device_count,
            online_device_limit=online_device_limit,
        )

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
            # login_with_result already performs its normal confirmation
            # retries.  Read one richer session fact here so the successful
            # result carries the latest account-wide occupancy (n/3) without
            # a second retry loop or any local MAC lookup.
            session_fact = getattr(self.client, "session_fact", None)
            if callable(session_fact):
                confirmed = session_fact(username, result.source_ip or probe.source_ip)
                confirmed_ip = result.source_ip or probe.source_ip
                confirmed_count = _optional_nonnegative_int(
                    getattr(confirmed, "online_device_count", None)
                )
                confirmed_limit = _optional_positive_int(
                    getattr(confirmed, "online_device_limit", DORM_ONLINE_DEVICE_LIMIT)
                ) or DORM_ONLINE_DEVICE_LIMIT
                if not confirmed.matches(username, confirmed_ip):
                    return AuthResult(
                        AuthOutcome.FAILED,
                        self.provider_id,
                        session_state=SessionState.UNKNOWN,
                        client_ip=getattr(confirmed, "ip", "") or confirmed_ip,
                        online_device_count=confirmed_count,
                        online_device_limit=confirmed_limit,
                        error_code="AUTH_NOT_CONFIRMED",
                        retryable=getattr(confirmed, "state", "unknown") == "unknown",
                    )
            return AuthResult(
                AuthOutcome.SUCCEEDED,
                self.provider_id,
                session_state=SessionState.ONLINE,
                client_ip=result.source_ip,
                online_device_count=(
                    confirmed_count if callable(session_fact) else None
                ),
                online_device_limit=(
                    confirmed_limit
                    if callable(session_fact)
                    else DORM_ONLINE_DEVICE_LIMIT
                ),
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


def _optional_nonnegative_int(value: object) -> int | None:
    if isinstance(value, bool):
        return None
    if isinstance(value, int) and value >= 0:
        return value
    return None


def _optional_positive_int(value: object) -> int | None:
    if isinstance(value, bool):
        return None
    if isinstance(value, int) and value > 0:
        return value
    return None


def _optional_bool(value: object) -> bool | None:
    return value if isinstance(value, bool) else None
