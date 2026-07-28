"""Password-free JSON stdin/stdout control surface for the Windows product."""

from __future__ import annotations

import argparse
import json
import sys
from datetime import datetime, timezone
from typing import Any, TextIO

if __package__ in (None, ""):
    from pathlib import Path

    sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from src.szu_netlogin.contracts import AuthOutcome, AuthResult, SessionState
from src.szu_netlogin.windows_product import WindowsCampusService, get_process_service


_COMMANDS = {
    "status", "check", "login", "logout", "pause", "resume", "open-settings", "diagnostics"
}
_PROVIDERS = {"auto", "dorm", "teaching"}
_FORBIDDEN_KEYS = {"password", "secret", "token", "cookie", "authorization", "credentialvalue"}


class RequestError(ValueError):
    pass


def validate_request(request: Any) -> dict[str, Any]:
    if not isinstance(request, dict):
        raise RequestError("request must be one JSON object")
    if _contains_forbidden_key(request):
        raise RequestError("secret-bearing fields are forbidden")
    allowed = {"schemaVersion", "requestId", "command", "provider", "interactive", "timeoutSeconds"}
    if set(request) - allowed:
        raise RequestError("request contains unsupported fields")
    if request.get("schemaVersion") != 1:
        raise RequestError("unsupported schema version")
    request_id = str(request.get("requestId") or "")
    if not 1 <= len(request_id) <= 128:
        raise RequestError("requestId is required")
    if request.get("command") not in _COMMANDS:
        raise RequestError("unsupported command")
    if request.get("provider", "auto") not in _PROVIDERS:
        raise RequestError("unsupported provider")
    timeout = request.get("timeoutSeconds", 15)
    if isinstance(timeout, bool) or not isinstance(timeout, (int, float)) or not 1 <= timeout <= 120:
        raise RequestError("timeoutSeconds is invalid")
    return request


def execute(request: dict[str, Any], service: WindowsCampusService) -> tuple[dict[str, Any], int]:
    request = validate_request(request)
    command = request["command"]
    provider = request.get("provider", "auto")
    network_context = "unknown"
    diagnostics: dict[str, Any] = {}
    if command in {"status", "check", "diagnostics"}:
        status = service.status() if command != "check" else service.check()
        network_context = status.get("networkContext", "unknown")
        diagnostics = status
        result = AuthResult(AuthOutcome.UNCHANGED, provider)
    elif command == "login":
        result = service.login(provider, manual=bool(request.get("interactive", False)))
    elif command == "logout":
        result = service.logout(provider)
    elif command == "pause":
        service.pause()
        result = AuthResult(AuthOutcome.SUCCEEDED, provider)
    elif command == "open-settings":
        service.open_settings()
        result = AuthResult(AuthOutcome.SUCCEEDED, provider)
    else:
        service.resume()
        result = AuthResult(AuthOutcome.SUCCEEDED, provider)

    payload = _result_payload(request["requestId"], result, network_context, diagnostics)
    return payload, _exit_code(result)


def run(
    stdin: TextIO = sys.stdin,
    stdout: TextIO = sys.stdout,
    *,
    service: WindowsCampusService | None = None,
) -> int:
    try:
        request = json.load(stdin)
        payload, exit_code = execute(request, service or get_process_service())
    except (json.JSONDecodeError, RequestError):
        payload = _error_payload("invalid-request", "CFG_INVALID")
        exit_code = 2
    except Exception:
        payload = _error_payload("internal-error", "INTERNAL_ERROR")
        exit_code = 70
    stdout.write(json.dumps(payload, ensure_ascii=True, separators=(",", ":")) + "\n")
    return exit_code


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(add_help=True)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--json", action="store_true")
    mode.add_argument("--self-test", action="store_true")
    args = parser.parse_args(argv)
    if args.self_test:
        validate_request(
            {
                "schemaVersion": 1,
                "requestId": "offline-self-test",
                "command": "status",
                "provider": "auto",
                "interactive": False,
                "timeoutSeconds": 15,
            }
        )
        return 0
    return run()


def _contains_forbidden_key(value: Any) -> bool:
    if isinstance(value, dict):
        return any(str(key).lower() in _FORBIDDEN_KEYS or _contains_forbidden_key(item) for key, item in value.items())
    if isinstance(value, list):
        return any(_contains_forbidden_key(item) for item in value)
    return False


def _result_payload(request_id, result, network_context, diagnostics):
    return {
        "schemaVersion": 1,
        "requestId": request_id,
        "outcome": result.outcome.value,
        "provider": result.provider_id if result.provider_id in _PROVIDERS else "none",
        "networkContext": network_context if network_context in {"dorm", "teaching", "otherCampus", "nonCampus", "ambiguous", "unknown"} else "unknown",
        "sessionState": result.session_state.value,
        "errorCode": result.error_code or None,
        "retryable": result.retryable,
        "message": result.error_code or result.outcome.value,
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "sanitizedDiagnostics": diagnostics,
    }


def _error_payload(request_id, code):
    return _result_payload(
        request_id,
        AuthResult(AuthOutcome.BLOCKED, "none", session_state=SessionState.BLOCKED, error_code=code),
        "unknown",
        {},
    )


def _exit_code(result: AuthResult) -> int:
    if result.outcome in {AuthOutcome.SUCCEEDED, AuthOutcome.UNCHANGED}:
        return 0
    if result.outcome == AuthOutcome.CANCELLED:
        return 130
    if result.outcome == AuthOutcome.FAILED:
        return 4 if result.retryable else 3
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
