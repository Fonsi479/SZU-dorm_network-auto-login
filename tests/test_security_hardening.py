from __future__ import annotations

import types
import unittest
import logging
from unittest.mock import patch

from src.szu_netlogin import password_store
from src.szu_netlogin.logger import _RedactingFormatter, redact_sensitive_text


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

    def test_portal_device_identity_fields_are_redacted(self) -> None:
        synthetic = (
            '{"online_ip":"172.24.1.10","online_mac":"aabbccddeeff",'
            '"nas_ip":"704585388","wlan_user_ip":"172.24.1.10",'
            '"wlan_user_mac":"aa:bb:cc:dd:ee:ff","ac_ip":"172.30.255.41"}'
        )
        output = redact_sensitive_text(synthetic)
        for forbidden in (
            "172.24.1.10",
            "aabbccddeeff",
            "704585388",
            "aa:bb:cc:dd:ee:ff",
            "172.30.255.41",
        ):
            self.assertNotIn(forbidden, output)
        self.assertIn("device_id_redacted", output)

    def test_persisted_log_formatter_redacts_keyed_device_identity(self) -> None:
        record = logging.LogRecord(
            "campus-test",
            logging.INFO,
            __file__,
            1,
            "route source_ip=%s online_mac=%s",
            ("172.24.1.10", "aabbccddeeff"),
            None,
        )
        output = _RedactingFormatter("%(message)s").format(record)
        self.assertNotIn("172.24.1.10", output)
        self.assertNotIn("aabbccddeeff", output)
        self.assertIn("device_id_redacted", output)


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
