"""Shared, printable-safe contracts for campus authentication providers."""

from __future__ import annotations

from dataclasses import dataclass, field
from enum import Enum
from typing import Any, Callable, Protocol


class Support(str, Enum):
    VERIFIED = "verified"
    UNSUPPORTED = "unsupported"
    AMBIGUOUS = "ambiguous"
    UNKNOWN = "unknown"


class SessionState(str, Enum):
    ONLINE = "online"
    OFFLINE = "offline"
    UNKNOWN = "unknown"
    BLOCKED = "blocked"


class AuthOutcome(str, Enum):
    SUCCEEDED = "succeeded"
    UNCHANGED = "unchanged"
    FAILED = "failed"
    CANCELLED = "cancelled"
    BLOCKED = "blocked"


@dataclass(frozen=True)
class NetworkContext:
    generation: int
    portal_url: str = ""
    portal_html: str = ""
    source_ip: str = ""
    source_interface: str = ""
    source_route_bound: bool = False
    portal_identity_verified: bool = False


@dataclass(frozen=True)
class ProviderProbe:
    provider_id: str
    support: Support
    source_ip: str = ""
    client_ip: str = ""
    acid: str = ""
    portal_host: str = ""
    evidence: tuple[str, ...] = ()
    error_code: str = ""
    data: Any = field(default=None, repr=False, compare=False)


@dataclass(frozen=True)
class SessionResult:
    state: SessionState
    account_match: bool | None = None
    client_ip: str = ""
    product: str = ""
    server_code: str = ""
    error_code: str = ""
    retryable: bool = False


@dataclass(frozen=True)
class AuthResult:
    outcome: AuthOutcome
    provider_id: str
    session_state: SessionState = SessionState.UNKNOWN
    client_ip: str = ""
    acid: str = ""
    error_code: str = ""
    server_code: str = ""
    retryable: bool = False


class CredentialHandle:
    """A short-lived secret wrapper whose repr/str never reveal the secret."""

    __slots__ = ("__secret",)

    def __init__(self, secret: str) -> None:
        self.__secret = secret

    def reveal(self) -> str:
        return self.__secret

    def __repr__(self) -> str:
        return "CredentialHandle(<redacted>)"

    __str__ = __repr__


CredentialLoader = Callable[[], CredentialHandle | None]


class NetworkAuthProvider(Protocol):
    provider_id: str

    def probe_environment(self, context: NetworkContext) -> ProviderProbe: ...

    def session_status(
        self, context: NetworkContext, probe: ProviderProbe, username: str
    ) -> SessionResult: ...

    def login(
        self,
        context: NetworkContext,
        probe: ProviderProbe,
        username: str,
        credential: CredentialHandle,
    ) -> AuthResult: ...

    def logout(self, context: NetworkContext, probe: ProviderProbe, username: str) -> AuthResult: ...

    def cancel_pending_operations(self, generation: int) -> None: ...
