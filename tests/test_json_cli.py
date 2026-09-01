from __future__ import annotations

import io
import json
import unittest

from src.szu_netlogin.contracts import AuthOutcome, AuthResult
from src.szu_netlogin.json_cli import main, run, validate_request, RequestError


class FakeService:
    def __init__(self):
        self.login_calls = []
        self.force_login_calls = []
        self.open_settings_calls = 0

    def status(self):
        return {"networkContext": "dorm", "providers": {}, "paused": False}

    check = status

    def login(self, provider, manual=False):
        self.login_calls.append((provider, manual))
        return AuthResult(AuthOutcome.SUCCEEDED, "dorm")

    def force_login(self, provider):
        self.force_login_calls.append(provider)
        return AuthResult(
            AuthOutcome.SUCCEEDED,
            "dorm",
            online_device_count=3,
            online_device_limit=3,
        )

    def logout(self, provider):
        return AuthResult(AuthOutcome.BLOCKED, "teaching", error_code="SRUN_LOGOUT_DISABLED")

    def pause(self):
        pass

    def resume(self):
        pass

    def open_settings(self):
        self.open_settings_calls += 1


def request(command="status", **extra):
    value = {"schemaVersion": 1, "requestId": "synthetic-request", "command": command,
             "provider": "auto", "interactive": False, "timeoutSeconds": 15}
    value.update(extra)
    return value


class JSONCLITests(unittest.TestCase):
    def test_frozen_self_test_is_offline(self):
        self.assertEqual(main(["--self-test"]), 0)

    def invoke(self, payload, service=None):
        stdin = io.StringIO(json.dumps(payload))
        stdout = io.StringIO()
        code = run(stdin, stdout, service=service or FakeService())
        lines = stdout.getvalue().splitlines()
        self.assertEqual(len(lines), 1)
        return code, json.loads(lines[0])

    def test_status_emits_one_schema_result(self):
        code, result = self.invoke(request())
        self.assertEqual(code, 0)
        self.assertEqual(result["networkContext"], "dorm")
        self.assertEqual(result["requestId"], "synthetic-request")

    def test_login_contains_no_secret_and_calls_service(self):
        service = FakeService()
        code, result = self.invoke(request("login", provider="dorm"), service)
        self.assertEqual(code, 0)
        self.assertEqual(service.login_calls, [("dorm", False)])
        self.assertNotIn("password", json.dumps(result).lower())

    def test_force_login_requires_interactive_confirmation(self):
        service = FakeService()
        code, result = self.invoke(request("force-login"), service)
        self.assertEqual(code, 2)
        self.assertEqual(result["errorCode"], "AUTH_DEVICE_REPLACEMENT_UNSUPPORTED")
        self.assertEqual(service.force_login_calls, [])

    def test_force_login_dispatches_once_and_returns_aggregate_budget(self):
        service = FakeService()
        code, result = self.invoke(
            request("force-login", provider="dorm", interactive=True), service
        )
        self.assertEqual(code, 0)
        self.assertEqual(service.force_login_calls, ["dorm"])
        self.assertEqual((result["onlineDeviceCount"], result["onlineDeviceLimit"]), (3, 3))
        self.assertNotIn("mac", json.dumps(result).lower())

    def test_rejects_password_field_without_echoing_value(self):
        code, result = self.invoke({**request("login"), "password": "must-not-echo"})
        self.assertEqual(code, 2)
        self.assertEqual(result["errorCode"], "CFG_INVALID")
        self.assertNotIn("must-not-echo", json.dumps(result))

    def test_rejects_nested_secret_field(self):
        with self.assertRaises(RequestError):
            validate_request({**request(), "extra": {"token": "synthetic"}})

    def test_teaching_logout_reports_disabled(self):
        code, result = self.invoke(request("logout", provider="teaching"))
        self.assertEqual(code, 2)
        self.assertEqual(result["errorCode"], "SRUN_LOGOUT_DISABLED")

    def test_open_settings_uses_high_level_service_command(self):
        service = FakeService()
        code, result = self.invoke(request("open-settings"), service)
        self.assertEqual(code, 0)
        self.assertEqual(service.open_settings_calls, 1)
        self.assertEqual(result["outcome"], "succeeded")


if __name__ == "__main__":
    unittest.main()
