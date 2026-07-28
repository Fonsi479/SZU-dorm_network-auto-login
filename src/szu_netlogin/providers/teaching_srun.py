"""Clean-room teaching-area SRun provider with an injected transport."""

from __future__ import annotations

import itertools
import time
from collections.abc import Callable
from typing import Any

import requests

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
from ..srun_crypto import derive_login_fields
from ..srun_jsonp import JSONPError, decode_jsonp
from ..srun_portal import (
    PortalDiscoveryError,
    RequestsSRunTransport,
    SRunTransport,
    discover_portal,
)


_FATAL_SERVER_CODES = {
    "E2531": "AUTH_BAD_PASSWORD",
    "password_error": "AUTH_BAD_PASSWORD",
    "user_not_exists": "AUTH_ACCOUNT_NOT_FOUND",
    "auth_error": "AUTH_ACCOUNT_BLOCKED",
    "product_error": "AUTH_PRODUCT_SUFFIX_INVALID",
    "users_limit": "AUTH_DEVICE_LIMIT",
}


class TeachingSRunProvider:
    provider_id = "teaching"

    def __init__(
        self,
        transport: SRunTransport | None = None,
        *,
        callback_factory: Callable[[], str] | None = None,
        clock_ms: Callable[[], int] | None = None,
        timeout: float = 8,
    ) -> None:
        self.transport = transport or RequestsSRunTransport()
        counter = itertools.count(1)
        self.callback_factory = callback_factory or (lambda: f"_szu_cb_{next(counter):08x}")
        self.clock_ms = clock_ms or (lambda: int(time.time() * 1000))
        self.timeout = timeout
        self._cancelled_generations: set[int] = set()

    def probe_environment(self, context: NetworkContext) -> ProviderProbe:
        if not context.portal_identity_verified:
            return self._blocked_probe("ENV_PORTAL_IDENTITY_UNVERIFIED")
        if not context.source_route_bound or not context.source_ip:
            return self._blocked_probe("ENV_SOURCE_ROUTE_UNVERIFIED")
        try:
            discovery = discover_portal(context.portal_url, context.portal_html, context.source_ip)
        except PortalDiscoveryError as exc:
            support = Support.AMBIGUOUS if exc.error_code == "SRUN_CONFIG_CONFLICT" else Support.UNSUPPORTED
            return ProviderProbe(self.provider_id, support, error_code=exc.error_code)
        return ProviderProbe(
            self.provider_id,
            Support.VERIFIED,
            source_ip=context.source_ip,
            client_ip=discovery.client_ip,
            acid=discovery.acid,
            portal_host=discovery.portal_host,
            evidence=discovery.evidence,
            data=discovery,
        )

    def session_status(
        self, context: NetworkContext, probe: ProviderProbe, username: str
    ) -> SessionResult:
        if self._is_cancelled(context):
            return SessionResult(SessionState.BLOCKED, error_code="OPERATION_CANCELLED")
        callback = self.callback_factory()
        try:
            response = self.transport.get(
                "/cgi-bin/rad_user_info",
                {"callback": callback, "_": str(self.clock_ms())},
                source_ip=probe.source_ip,
                timeout=self.timeout,
            )
            if not 200 <= response.status_code < 300:
                return SessionResult(
                    SessionState.UNKNOWN,
                    error_code="NET_TIMEOUT" if response.status_code >= 500 else "SESSION_UNKNOWN",
                    retryable=response.status_code >= 500,
                )
            payload = decode_jsonp(response.body, callback)
        except JSONPError:
            return SessionResult(SessionState.UNKNOWN, error_code="SRUN_JSONP_MALFORMED", retryable=True)
        except requests.exceptions.SSLError:
            return SessionResult(SessionState.BLOCKED, error_code="NET_TLS_FAILED")
        except requests.RequestException:
            return SessionResult(SessionState.UNKNOWN, error_code="NET_TIMEOUT", retryable=True)
        except Exception:
            return SessionResult(SessionState.UNKNOWN, error_code="INTERNAL_ERROR")

        server_code = str(payload.get("error") or payload.get("res") or "")
        online_ip = str(payload.get("online_ip") or payload.get("client_ip") or "")
        account = str(payload.get("user_name") or payload.get("username") or "")
        if server_code == "ok" and online_ip and account:
            return SessionResult(
                SessionState.ONLINE,
                account_match=account == username,
                client_ip=online_ip,
                product=str(payload.get("products_name") or ""),
                server_code=server_code,
            )
        if server_code in {"not_online_error", "not_online", "offline"}:
            return SessionResult(SessionState.OFFLINE, account_match=None, server_code=server_code)
        return SessionResult(SessionState.UNKNOWN, error_code="SESSION_UNKNOWN", server_code=server_code)

    def login(
        self,
        context: NetworkContext,
        probe: ProviderProbe,
        username: str,
        credential: CredentialHandle,
    ) -> AuthResult:
        if self._is_cancelled(context):
            return self._result(AuthOutcome.CANCELLED, probe, "OPERATION_CANCELLED")
        challenge_callback = self.callback_factory()
        try:
            challenge_response = self.transport.get(
                "/cgi-bin/get_challenge",
                {
                    "callback": challenge_callback,
                    "username": username,
                    "ip": probe.client_ip,
                    "_": str(self.clock_ms()),
                },
                source_ip=probe.source_ip,
                timeout=self.timeout,
            )
            challenge_payload = decode_jsonp(challenge_response.body, challenge_callback)
        except JSONPError:
            return self._result(AuthOutcome.FAILED, probe, "SRUN_JSONP_MALFORMED", retryable=True)
        except requests.exceptions.SSLError:
            return self._result(AuthOutcome.BLOCKED, probe, "NET_TLS_FAILED")
        except requests.RequestException:
            return self._result(AuthOutcome.FAILED, probe, "NET_TIMEOUT", retryable=True)
        except Exception:
            return self._result(AuthOutcome.FAILED, probe, "INTERNAL_ERROR")
        challenge = str(challenge_payload.get("challenge") or "")
        challenge_ip = str(challenge_payload.get("client_ip") or "")
        if str(challenge_payload.get("error") or "") != "ok" or not challenge:
            return self._result(AuthOutcome.FAILED, probe, "SRUN_CHALLENGE_FAILED")
        if challenge_ip != probe.client_ip:
            return self._result(AuthOutcome.BLOCKED, probe, "SRUN_CONFIG_CONFLICT")
        if self._is_cancelled(context):
            return self._result(AuthOutcome.CANCELLED, probe, "OPERATION_CANCELLED")

        fields = derive_login_fields(
            username=username,
            password=credential.reveal(),
            ip=probe.client_ip,
            acid=probe.acid,
            challenge=challenge,
        )
        login_callback = self.callback_factory()
        query = {
            "action": "login",
            "username": username,
            "password": fields.password,
            "info": fields.info,
            "chksum": fields.checksum,
            "ac_id": probe.acid,
            "ip": probe.client_ip,
            "n": "200",
            "type": "1",
            "enc_ver": "srun_bx1",
            "double_stack": "0",
            "callback": login_callback,
            "_": str(self.clock_ms()),
        }
        try:
            response = self.transport.get(
                "/cgi-bin/srun_portal",
                query,
                source_ip=probe.source_ip,
                timeout=self.timeout,
            )
            ack = decode_jsonp(response.body, login_callback)
        except JSONPError:
            return self._result(AuthOutcome.FAILED, probe, "SRUN_JSONP_MALFORMED", retryable=True)
        except requests.exceptions.SSLError:
            return self._result(AuthOutcome.BLOCKED, probe, "NET_TLS_FAILED")
        except requests.RequestException:
            return self._result(AuthOutcome.FAILED, probe, "NET_TIMEOUT", retryable=True)
        except Exception:
            return self._result(AuthOutcome.FAILED, probe, "INTERNAL_ERROR")
        if self._is_cancelled(context):
            return self._result(AuthOutcome.CANCELLED, probe, "OPERATION_CANCELLED")

        server_code = str(ack.get("error") or ack.get("res") or "")
        if server_code not in {"ok", "ip_already_online_error"}:
            error_code = _FATAL_SERVER_CODES.get(server_code, "AUTH_NOT_CONFIRMED")
            return self._result(AuthOutcome.FAILED, probe, error_code, server_code=server_code)
        verified = self.session_status(context, probe, username)
        if verified.state == SessionState.ONLINE and verified.account_match is True:
            return AuthResult(
                AuthOutcome.SUCCEEDED,
                self.provider_id,
                session_state=SessionState.ONLINE,
                client_ip=probe.client_ip,
                acid=probe.acid,
                server_code=server_code,
            )
        return self._result(
            AuthOutcome.FAILED,
            probe,
            "AUTH_NOT_CONFIRMED" if verified.state != SessionState.UNKNOWN else "SESSION_UNKNOWN",
            retryable=verified.retryable,
            server_code=server_code,
        )

    def logout(self, context: NetworkContext, probe: ProviderProbe, username: str) -> AuthResult:
        return self._result(AuthOutcome.BLOCKED, probe, "SRUN_LOGOUT_DISABLED")

    def cancel_pending_operations(self, generation: int) -> None:
        self._cancelled_generations.add(generation)

    def _is_cancelled(self, context: NetworkContext) -> bool:
        return context.generation in self._cancelled_generations

    def _blocked_probe(self, code: str) -> ProviderProbe:
        return ProviderProbe(self.provider_id, Support.UNSUPPORTED, error_code=code)

    def _result(
        self,
        outcome: AuthOutcome,
        probe: ProviderProbe,
        error_code: str,
        *,
        retryable: bool = False,
        server_code: str = "",
    ) -> AuthResult:
        return AuthResult(
            outcome,
            self.provider_id,
            client_ip=probe.client_ip,
            acid=probe.acid,
            error_code=error_code,
            server_code=server_code,
            retryable=retryable,
        )
