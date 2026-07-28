from __future__ import annotations

import types
import unittest
from unittest.mock import patch

from src.szu_netlogin import password_store
from src.szu_netlogin.logger import redact_sensitive_text


class LoggingSecurityTests(unittest.TestCase):
    def test_srun_derived_fields_and_authentication_url_are_redacted(self) -> None:
        synthetic = (
            "challenge=012345 chksum=abcdef info={SRBX1}opaque "
            "password={MD5}deadbeef username=synthetic-user "
            "https://net.szu.edu.cn/cgi-bin/srun_portal?action=login&chksum=abcdef"
        )
        output = redact_sensitive_text(synthetic)
        for forbidden in ("012345", "abcdef", "opaque", "deadbeef", "synthetic-user", "action=login"):
            self.assertNotIn(forbidden, output)

    def test_json_srun_fields_are_redacted(self) -> None:
        output = redact_sensitive_text(
            '{"challenge":"synthetic-token","info":"derived","chksum":"checksum","user_name":"account"}'
        )
        for forbidden in ("synthetic-token", "derived", "checksum", "account"):
            self.assertNotIn(forbidden, output)


class WindowsCredentialBackendTests(unittest.TestCase):
    def test_windows_rejects_non_credential_manager_keyring_backend(self) -> None:
        class PlaintextBackend:
            pass

        fake_keyring = types.SimpleNamespace(get_keyring=lambda: PlaintextBackend())
        with (
            patch.object(password_store.os, "name", "nt"),
            patch.dict("sys.modules", {"keyring": fake_keyring}),
        ):
            with self.assertRaisesRegex(RuntimeError, "Credential Manager"):
                password_store._load_keyring()

    def test_windows_legacy_lookup_does_not_fall_back_to_environment(self) -> None:
        with (
            patch.object(password_store.os, "name", "nt"),
            patch.object(password_store, "_get_keyring_password", return_value=""),
            patch.dict(password_store.os.environ, {password_store.PASSWORD_ENV_NAME: "synthetic-env"}),
        ):
            self.assertEqual(password_store.get_password("synthetic-user"), "")


if __name__ == "__main__":
    unittest.main()
