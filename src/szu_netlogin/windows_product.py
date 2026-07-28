"""Windows product service joining configuration, providers, and coordinator."""

from __future__ import annotations

import socket
import os
import subprocess
import sys
import threading
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable

from .config import (
    DEFAULT_CONFIG_PATH,
    load_config,
    provider_configuration,
    teaching_account,
)
from .contracts import AuthOutcome, AuthResult, CredentialHandle, NetworkContext, SessionState
from .coordinator import CampusNetworkCoordinator, CoordinatorSettings
from .password_store import get_provider_password
from .portal_detect import classify_network_environment, probe_gateway
from .platform_paths import get_user_log_dir
from .platform_paths import open_path_with_default_app
from .providers import DormDrcomProvider, TeachingSRunProvider
from .srun_portal import RequestsSRunTransport
from .state import describe_pause_state, is_paused, pause, resume

try:
    import fcntl
except ImportError:  # pragma: no cover - Windows
    fcntl = None  # type: ignore[assignment]
try:
    import msvcrt
except ImportError:  # pragma: no cover - POSIX
    msvcrt = None  # type: ignore[assignment]


@dataclass(frozen=True)
class EnvironmentSnapshot:
    contexts: dict[str, NetworkContext]
    category: str


_IN_PROCESS_AUTH_LOCK = threading.Lock()


class ProcessAuthenticationLock:
    """Non-blocking user-level lock shared by GUI and CLI processes."""

    def __init__(self, path: Path | None = None) -> None:
        self.path = path or (get_user_log_dir() / "campus-auth-operation.lock")
        self._handle = None
        self._thread_locked = False

    def acquire(self) -> bool:
        if not _IN_PROCESS_AUTH_LOCK.acquire(blocking=False):
            return False
        self._thread_locked = True
        try:
            self.path.parent.mkdir(parents=True, exist_ok=True)
            handle = self.path.open("a+b")
        except OSError:
            _IN_PROCESS_AUTH_LOCK.release()
            self._thread_locked = False
            return False
        if handle.seek(0, os.SEEK_END) == 0:
            handle.write(b"0")
            handle.flush()
        try:
            if os.name == "nt" and msvcrt is not None:
                handle.seek(0)
                msvcrt.locking(handle.fileno(), msvcrt.LK_NBLCK, 1)
            elif fcntl is not None:
                fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            else:
                raise OSError("no supported process lock")
        except (OSError, BlockingIOError):
            handle.close()
            _IN_PROCESS_AUTH_LOCK.release()
            self._thread_locked = False
            return False
        self._handle = handle
        return True

    def release(self) -> None:
        handle, self._handle = self._handle, None
        if handle is None:
            return
        try:
            if os.name == "nt" and msvcrt is not None:
                handle.seek(0)
                msvcrt.locking(handle.fileno(), msvcrt.LK_UNLCK, 1)
            elif fcntl is not None:
                fcntl.flock(handle.fileno(), fcntl.LOCK_UN)
        finally:
            handle.close()
            if self._thread_locked:
                _IN_PROCESS_AUTH_LOCK.release()
                self._thread_locked = False


class WindowsEnvironmentDetector:
    """Credential-free environment detector; network calls are injectable in tests."""

    def __init__(
        self,
        teaching_transport_factory: Callable[[], RequestsSRunTransport] = RequestsSRunTransport,
    ) -> None:
        self.teaching_transport_factory = teaching_transport_factory

    def detect(self, config: dict[str, Any], generation: int) -> EnvironmentSnapshot:
        dorm_enabled = provider_configuration(config, "dorm")["enabled"]
        teaching_enabled = provider_configuration(config, "teaching")["enabled"]
        if dorm_enabled:
            dorm_status = probe_gateway(config)
            dorm_environment = classify_network_environment(config, dorm_status)
            dorm_context = NetworkContext(
                generation,
                portal_url=str((config.get("auth") or {}).get("login_url") or ""),
                source_ip=dorm_status.source_ip,
                source_route_bound=dorm_environment.auto_login_available,
                portal_identity_verified=dorm_environment.auto_login_available,
            )
        else:
            dorm_context = NetworkContext(generation)
        teaching_context = (
            self._teaching_context(config, generation)
            if teaching_enabled
            else NetworkContext(generation)
        )
        if teaching_context.portal_identity_verified and dorm_context.portal_identity_verified:
            category = "ambiguous"
        elif teaching_context.portal_identity_verified:
            category = "teaching"
        elif dorm_context.portal_identity_verified:
            category = "dorm"
        else:
            category = "nonCampus"
        return EnvironmentSnapshot(
            {"dorm": dorm_context, "teaching": teaching_context},
            category,
        )

    def _teaching_context(self, config: dict[str, Any], generation: int) -> NetworkContext:
        network = config.get("network") or {}
        host = str(network.get("portalHost") or "net.szu.edu.cn")
        timeout = float(network.get("timeout_seconds") or 3)
        portal_url = f"https://{host}/srun_portal_pc"
        try:
            with socket.create_connection((host, 443), timeout=timeout) as connection:
                source_ip = str(connection.getsockname()[0])
            response = self.teaching_transport_factory().get(
                "/srun_portal_pc", {}, source_ip=source_ip, timeout=timeout
            )
            if not 200 <= response.status_code < 300:
                raise OSError("teaching portal unavailable")
            html = response.body.decode("utf-8", errors="replace")
        except Exception:
            return NetworkContext(generation, portal_url=portal_url)
        return NetworkContext(
            generation,
            portal_url=portal_url,
            portal_html=html,
            source_ip=source_ip,
            source_route_bound=True,
            portal_identity_verified=True,
        )


class WindowsCampusService:
    def __init__(
        self,
        *,
        config_loader: Callable[[], dict[str, Any]] = load_config,
        detector: WindowsEnvironmentDetector | Any | None = None,
        provider_factory: Callable[[dict[str, Any]], dict[str, Any]] | None = None,
        process_lock: ProcessAuthenticationLock | Any | None = None,
        coordinator_factory: Callable[..., CampusNetworkCoordinator] = CampusNetworkCoordinator,
    ) -> None:
        self.config_loader = config_loader
        self.detector = detector or WindowsEnvironmentDetector()
        self.provider_factory = provider_factory or self._default_providers
        self.process_lock = process_lock or ProcessAuthenticationLock()
        self.coordinator_factory = coordinator_factory
        self.generation = 0
        self._providers: dict[str, Any] | None = None
        self._coordinator: CampusNetworkCoordinator | None = None
        self._config_fingerprint = ""
        self._runtime_lock = threading.RLock()

    def status(self) -> dict[str, Any]:
        if not self.process_lock.acquire():
            return self._stale_status("OPERATION_IN_PROGRESS")
        try:
            return self._status_locked()
        finally:
            self.process_lock.release()

    def _status_locked(self) -> dict[str, Any]:
        start_generation = self.generation
        config = self.config_loader()
        snapshot = self.detector.detect(config, start_generation)
        _providers, coordinator = self._runtime(config)
        status = coordinator.status(snapshot.contexts, self._usernames(config))
        if status.error_code:
            return self._stale_status(status.error_code)
        if status.generation != self.generation:
            return self._stale_status("ENV_NETWORK_CHANGED")

        provider_status: dict[str, dict[str, Any]] = {}
        for provider_id in ("dorm", "teaching"):
            item = status.providers.get(provider_id)
            if item is None:
                return self._stale_status("INTERNAL_ERROR")
            provider_status[provider_id] = {
                "enabled": item.enabled,
                "state": item.session.state.value,
                "errorCode": item.session.error_code or None,
                "account": self._mask_account(self._username(config, provider_id)),
                "accountMatch": item.session.account_match,
            }
        return {
            "networkContext": status.network_context,
            "paused": is_paused(),
            "pauseDescription": describe_pause_state(),
            "providers": provider_status,
            "generation": status.generation,
            "autoLoginProvider": status.auto_login_provider,
        }

    def check(self) -> dict[str, Any]:
        return self.status()

    def login(self, requested_provider: str = "auto", *, manual: bool = False) -> AuthResult:
        if not self.process_lock.acquire():
            return AuthResult(AuthOutcome.BLOCKED, requested_provider, error_code="OPERATION_IN_PROGRESS")
        try:
            return self._login_locked(requested_provider, manual=manual)
        finally:
            self.process_lock.release()

    def _login_locked(self, requested_provider: str, *, manual: bool) -> AuthResult:
        config = self.config_loader()
        snapshot = self.detector.detect(config, self.generation)
        _providers, coordinator = self._runtime(config)

        def credential_loader(provider_id: str):
            def open_credential() -> CredentialHandle | None:
                secret = get_provider_password(config, provider_id)
                return CredentialHandle(secret) if secret else None

            return open_credential

        return coordinator.login(
            snapshot.contexts,
            self._usernames(config),
            {
                provider_id: credential_loader(provider_id)
                for provider_id in ("dorm", "teaching")
            },
            requested_provider=requested_provider,
            manual=manual,
        )

    def logout(self, requested_provider: str) -> AuthResult:
        if not self.process_lock.acquire():
            return AuthResult(AuthOutcome.BLOCKED, requested_provider, error_code="OPERATION_IN_PROGRESS")
        try:
            return self._logout_locked(requested_provider)
        finally:
            self.process_lock.release()

    def _logout_locked(self, requested_provider: str) -> AuthResult:
        config = self.config_loader()
        snapshot = self.detector.detect(config, self.generation)
        _providers, coordinator = self._runtime(config)
        return coordinator.logout(
            snapshot.contexts,
            self._usernames(config),
            requested_provider=requested_provider,
        )

    def network_changed(self) -> int:
        with self._runtime_lock:
            if self._coordinator is None:
                self.generation += 1
            else:
                self.generation = self._coordinator.advance_generation()
            return self.generation

    cancel_pending_operations = network_changed

    @staticmethod
    def pause() -> None:
        pause()

    @staticmethod
    def resume() -> None:
        resume()

    @staticmethod
    def open_settings() -> None:
        if getattr(sys, "frozen", False):
            gui = Path(sys.executable).resolve().with_name("SZU Campus Network.exe")
            if not gui.is_file():
                raise FileNotFoundError(gui)
            subprocess.Popen(
                [str(gui)],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                close_fds=True,
            )
            return
        open_path_with_default_app(DEFAULT_CONFIG_PATH)

    @staticmethod
    def _default_providers(config: dict[str, Any]) -> dict[str, Any]:
        return {
            "dorm": DormDrcomProvider(config),
            "teaching": TeachingSRunProvider(),
        }

    def _runtime(
        self, config: dict[str, Any]
    ) -> tuple[dict[str, Any], CampusNetworkCoordinator]:
        fingerprint = repr((config.get("auth"), config.get("network"), config.get("providers")))
        settings = CoordinatorSettings(
            dorm_enabled=provider_configuration(config, "dorm")["enabled"],
            teaching_enabled=provider_configuration(config, "teaching")["enabled"],
            automatic_enabled=bool((config.get("general") or {}).get("autoDetect", True)),
            paused=is_paused(),
        )
        with self._runtime_lock:
            if self._providers is None or fingerprint != self._config_fingerprint:
                self._providers = self.provider_factory(config)
                self._config_fingerprint = fingerprint
            if self._coordinator is None:
                self._coordinator = self.coordinator_factory(
                    self._providers.values(), settings=settings
                )
                self._coordinator.generation = self.generation
            else:
                self._coordinator.update_runtime(self._providers.values(), settings)
            return self._providers, self._coordinator

    def _stale_status(self, code: str) -> dict[str, Any]:
        return {
            "networkContext": "unknown",
            "paused": is_paused(),
            "pauseDescription": describe_pause_state(),
            "providers": {
                provider_id: {
                    "enabled": False,
                    "state": SessionState.BLOCKED.value,
                    "errorCode": code,
                    "account": "****",
                    "accountMatch": None,
                }
                for provider_id in ("dorm", "teaching")
            },
            "generation": self.generation,
            "autoLoginProvider": None,
        }

    @staticmethod
    def _username(config: dict[str, Any], provider_id: str) -> str:
        if provider_id == "teaching":
            return teaching_account(config)
        if provider_id == "dorm":
            return provider_configuration(config, "dorm")["account_label"]
        return ""

    @classmethod
    def _usernames(cls, config: dict[str, Any]) -> dict[str, str]:
        return {
            provider_id: cls._username(config, provider_id)
            for provider_id in ("dorm", "teaching")
        }

    @staticmethod
    def _mask_account(account: str) -> str:
        local, separator, suffix = account.partition("@")
        masked = "****" if len(local) < 3 else local[:1] + "***" + local[-1:]
        return masked + (separator + suffix if separator else "")


def set_provider_enabled(
    provider_id: str, enabled: bool, *, path: Path = DEFAULT_CONFIG_PATH
) -> None:
    if provider_id not in {"dorm", "teaching"}:
        raise ValueError("provider must be dorm or teaching")
    text = path.read_text(encoding="utf-8")
    lines = text.splitlines(keepends=True)
    in_providers = False
    in_target = False
    replaced = False
    for index, line in enumerate(lines):
        stripped = line.strip()
        indent = len(line) - len(line.lstrip(" "))
        if indent == 0:
            in_providers = stripped == "providers:"
            in_target = False
        elif in_providers and indent == 2 and stripped.endswith(":"):
            in_target = stripped == f"{provider_id}:"
        elif in_target and indent == 4 and stripped.startswith("enabled:"):
            newline = "\n" if line.endswith("\n") else ""
            lines[index] = f"    enabled: {'true' if enabled else 'false'}{newline}"
            replaced = True
            break
    if not replaced:
        raise ValueError(f"providers.{provider_id}.enabled not found")
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text("".join(lines), encoding="utf-8")
    temporary.replace(path)


_PROCESS_SERVICE: WindowsCampusService | None = None
_PROCESS_SERVICE_LOCK = threading.Lock()


def get_process_service() -> WindowsCampusService:
    global _PROCESS_SERVICE
    with _PROCESS_SERVICE_LOCK:
        if _PROCESS_SERVICE is None:
            _PROCESS_SERVICE = WindowsCampusService()
        return _PROCESS_SERVICE


def set_process_service_for_testing(service: WindowsCampusService | None) -> None:
    global _PROCESS_SERVICE
    with _PROCESS_SERVICE_LOCK:
        _PROCESS_SERVICE = service
