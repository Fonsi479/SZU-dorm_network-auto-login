from __future__ import annotations

import tempfile
import os
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

from src.szu_netlogin.password_store import get_password, set_password


class PasswordStoreTests(unittest.TestCase):
    def test_set_password_uses_configured_keychain_target(self) -> None:
        keyring = Mock()
        config = {
            "user": {"username": "student-id"},
            "security": {
                "password_source": "keychain",
                "keychain_service": "custom-service",
                "keychain_account": "custom-account",
            },
        }

        with patch("src.szu_netlogin.password_store._load_keyring", return_value=keyring):
            set_password(config, "secret")

        keyring.set_password.assert_called_once_with(
            "custom-service",
            "custom-account",
            "secret",
        )

    @unittest.skipIf(os.name == "nt", "Windows intentionally requires the credential store")
    def test_set_password_writes_private_file_source(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            password_file = Path(temp_dir) / "password.yaml"
            config = {
                "user": {"username": "student-id"},
                "security": {
                    "password_source": "private_file",
                    "password_file": str(password_file),
                },
            }

            set_password(config, 'pa:ss # "word"')

            self.assertEqual(get_password(config), 'pa:ss # "word"')
            self.assertEqual(password_file.stat().st_mode & 0o777, 0o600)

    def test_set_password_refuses_env_source(self) -> None:
        config = {
            "user": {"username": "student-id"},
            "security": {
                "password_source": "env",
                "password_env_name": "SZU_NET_PASSWORD",
            },
        }

        with self.assertRaisesRegex(ValueError, "环境变量 SZU_NET_PASSWORD"):
            set_password(config, "secret")

    @unittest.skipIf(os.name == "nt", "Windows intentionally requires the credential store")
    def test_private_file_does_not_replace_destination_when_permissions_cannot_be_set(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            password_file = Path(temp_dir) / "password.yaml"
            password_file.write_text("password: old\n", encoding="utf-8")
            config = {"security": {"password_source": "private_file", "password_file": str(password_file)}}
            with patch("src.szu_netlogin.password_store.os.chmod", side_effect=OSError("denied")):
                with self.assertRaises(OSError):
                    set_password(config, "secret")
            self.assertEqual(password_file.read_text(encoding="utf-8"), "password: old\n")

    def test_windows_rejects_private_file_password_source(self) -> None:
        config = {
            "security": {
                "password_source": "private_file",
                "password_file": "password.yaml",
            }
        }
        with patch("src.szu_netlogin.password_store.os.name", "nt"):
            with self.assertRaisesRegex(ValueError, "Windows 不支持 private_file"):
                set_password(config, "secret")


if __name__ == "__main__":
    unittest.main()
