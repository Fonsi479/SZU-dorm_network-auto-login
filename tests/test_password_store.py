from __future__ import annotations

import tempfile
import os
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

from src.szu_netlogin.password_store import describe_password_source, get_password, set_password


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

    def test_keychain_write_falls_back_to_security_cli(self) -> None:
        keyring = Mock()
        keyring.set_password.side_effect = RuntimeError("Security Auth Failure")
        completed = Mock(returncode=0, stdout="", stderr="")
        config = {
            "user": {"username": "student-id"},
            "security": {
                "password_source": "keychain",
                "keychain_service": "custom-service",
            },
        }

        with (
            patch("src.szu_netlogin.password_store._load_keyring", return_value=keyring),
            patch("src.szu_netlogin.password_store.subprocess.run", return_value=completed) as run,
        ):
            set_password(config, "secret")

        args, kwargs = run.call_args
        self.assertEqual(args[0][-2], "-X")
        self.assertNotIn("secret", args[0])
        self.assertEqual(args[0][-1], "secret".encode("utf-8").hex())

    def test_locked_keychain_falls_back_to_private_file(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            password_file = Path(temp_dir) / "password.yaml"
            config = {
                "user": {"username": "student-id"},
                "security": {
                    "password_source": "keychain",
                    "keychain_service": "custom-service",
                    "password_file": str(password_file),
                },
            }

            with patch(
                "src.szu_netlogin.password_store._set_keychain_password",
                side_effect=RuntimeError("keychain locked"),
            ):
                set_password(config, "secret")

            self.assertEqual(get_password(config), "secret")
            self.assertEqual(password_file.stat().st_mode & 0o777, 0o600)
            self.assertIn("钥匙串不可用时回退", describe_password_source(config))

    def test_keychain_write_reports_both_backends_failing(self) -> None:
        keyring = Mock()
        keyring.set_password.side_effect = RuntimeError("Security Auth Failure")
        completed = Mock(returncode=44, stdout="", stderr="keychain locked")

        with (
            patch("src.szu_netlogin.password_store._load_keyring", return_value=keyring),
            patch("src.szu_netlogin.password_store.subprocess.run", return_value=completed),
            self.assertRaisesRegex(RuntimeError, "keychain locked"),
        ):
            set_password("student-id", "secret")

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

    def test_private_file_does_not_replace_destination_when_permissions_cannot_be_set(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            password_file = Path(temp_dir) / "password.yaml"
            password_file.write_text("password: old\n", encoding="utf-8")
            config = {"security": {"password_source": "private_file", "password_file": str(password_file)}}
            with patch("src.szu_netlogin.password_store.os.chmod", side_effect=OSError("denied")):
                with self.assertRaises(OSError):
                    set_password(config, "secret")
            self.assertEqual(password_file.read_text(encoding="utf-8"), "password: old\n")


if __name__ == "__main__":
    unittest.main()
