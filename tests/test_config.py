from __future__ import annotations

import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

from src.szu_netlogin import config as config_module
from src.szu_netlogin.config import (
    PROJECT_HOME_ENV,
    ConfigError,
    _parse_simple_yaml,
    validate_config,
)


class ProjectRootTests(unittest.TestCase):
    def test_project_home_env_overrides_default_root(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            with patch.dict(os.environ, {PROJECT_HOME_ENV: temp_dir}):
                self.assertEqual(config_module.get_project_root(), Path(temp_dir).resolve())

    def test_frozen_app_uses_app_home_without_scanning_executable_parents(self) -> None:
        app_home = Path("/tmp/szu-netlogin-app-home")

        with (
            patch.dict(os.environ, {}, clear=True),
            patch.object(config_module.sys, "frozen", True, create=True),
            patch.object(config_module, "DEFAULT_APP_PROJECT_ROOT", app_home),
            patch.object(
                config_module,
                "_find_project_root_from_executable",
                side_effect=AssertionError("should not scan executable parents"),
            ),
        ):
            self.assertEqual(config_module.get_project_root(), app_home)


class SimpleYamlParserTests(unittest.TestCase):
    def test_strips_inline_comments_outside_quotes(self) -> None:
        data = _parse_simple_yaml(
            """
auth:
  callback: "dr1003"  # login callback
  quoted_hash: "value # still value"
  plain: dr1004 # logout callback
"""
        )

        self.assertEqual(data["auth"]["callback"], "dr1003")
        self.assertEqual(data["auth"]["quoted_hash"], "value # still value")
        self.assertEqual(data["auth"]["plain"], "dr1004")

    def test_parses_inline_lists_and_dicts(self) -> None:
        data = _parse_simple_yaml(
            """
network:
  max_test_urls: 3
  inline_list: [1, 2, "three"]
  inline_dict: {enabled: true, retries: 2}
"""
        )

        self.assertEqual(data["network"]["inline_list"], [1, 2, "three"])
        self.assertEqual(data["network"]["inline_dict"], {"enabled": True, "retries": 2})

    def test_parses_deeper_nested_dicts(self) -> None:
        data = _parse_simple_yaml(
            """
network:
  nested_section:
    child:
      enabled: true
      count: 2
"""
        )

        self.assertEqual(
            data["network"]["nested_section"],
            {"child": {"enabled": True, "count": 2}},
        )

    def test_parses_block_lists_under_nested_keys(self) -> None:
        data = _parse_simple_yaml(
            """
network:
  test_urls:
    - "http://captive.apple.com/hotspot-detect.html"
    - "https://www.baidu.com/"
"""
        )

        self.assertEqual(
            data["network"]["test_urls"],
            [
                "http://captive.apple.com/hotspot-detect.html",
                "https://www.baidu.com/",
            ],
        )

    def test_parses_literal_and_folded_block_scalars(self) -> None:
        data = _parse_simple_yaml(
            """
security:
  literal: |
    first line
    second line
  folded: >
    first line
    second line
"""
        )

        self.assertEqual(data["security"]["literal"], "first line\nsecond line")
        self.assertEqual(data["security"]["folded"], "first line second line")

    def test_rejects_anchors_and_aliases_without_pyyaml(self) -> None:
        with self.assertRaisesRegex(ConfigError, "PyYAML"):
            _parse_simple_yaml(
                """
defaults: &defaults
  timeout: 3
network:
  <<: *defaults
"""
            )


class ConfigValidationTests(unittest.TestCase):
    def test_rejects_non_positive_or_non_numeric_auth_timeout(self) -> None:
        for value in ("eight", 0, -1):
            config = _valid_config()
            config["auth"]["timeout_seconds"] = value
            with self.assertRaisesRegex(ConfigError, "timeout_seconds"):
                validate_config(config)

    def test_rejects_scalar_gateway_hosts(self) -> None:
        config = _valid_config()
        config["network"]["dorm_gateway_hosts"] = "172.30.255.42"
        with self.assertRaisesRegex(ConfigError, "dorm_gateway_hosts"):
            validate_config(config)

    def test_fallback_yaml_decodes_doubled_single_quote(self) -> None:
        self.assertEqual(
            _parse_simple_yaml("network:\n  campus_wifi_names: ['John''s WiFi']\n")["network"]["campus_wifi_names"],
            ["John's WiFi"],
        )
    def test_rejects_invalid_logout_discovery_urls(self) -> None:
        config = _valid_config()
        config["auth"]["logout_page_url"] = "172.30.255.42/a79.htm"

        with self.assertRaisesRegex(ConfigError, "logout_page_url"):
            validate_config(config)

        config = _valid_config()
        config["auth"]["unbind_url"] = "172.30.255.42/unbind"

        with self.assertRaisesRegex(ConfigError, "unbind_url"):
            validate_config(config)

    def test_portal_urls_bind_to_the_exact_gateway_origin(self) -> None:
        malicious = (
            "http://student:password@172.30.255.42:801/eportal/portal/login",
            "http://2130706433:801/eportal/portal/login",
            "http://172.30.255.42:0801/eportal/portal/login",
            "http://172.30.255.42:802/eportal/portal/login",
            "https://172.30.255.42:801/eportal/portal/login",
            "http://172.30.255.42:801/eportal/portal/%2e%2e/login",
            "http://172.30.255.43:801/eportal/portal/login",
        )
        for login_url in malicious:
            config = _valid_config()
            config["auth"]["login_url"] = login_url
            with self.subTest(login_url=login_url), self.assertRaises(ConfigError):
                validate_config(config)

    def test_config_cannot_authorize_a_new_gateway_with_a_new_host_list(self) -> None:
        config = _valid_config()
        config["network"]["dorm_gateway_hosts"] = ["192.0.2.55"]
        config["auth"]["login_url"] = "http://192.0.2.55:801/eportal/portal/login"
        with self.assertRaisesRegex(ConfigError, "内建宿舍网关"):
            validate_config(config)

    def test_same_gateway_wrong_portal_paths_are_rejected(self) -> None:
        config = _valid_config()
        for field_name, path in {
            "login_url": "/eportal/portal/evil",
            "logout_url": "/eportal/portal/other",
            "logout_page_url": "/a79.htm/evil",
            "unbind_url": "/eportal/portal/mac/other",
        }.items():
            config = _valid_config()
            config["auth"][field_name] = f"http://172.30.255.42:801{path}"
            with self.subTest(field_name=field_name), self.assertRaisesRegex(ConfigError, field_name):
                validate_config(config)

    def test_logout_page_and_unbind_cannot_cross_login_origin(self) -> None:
        valid_paths = {
            "logout_url": "/eportal/portal/logout",
            "logout_page_url": "/a79.htm",
            "unbind_url": "/eportal/portal/mac/unbind",
        }
        for field_name, path in valid_paths.items():
            config = _valid_config()
            config["auth"][field_name] = f"http://172.30.255.43:801{path}"
            with self.subTest(field_name=field_name), self.assertRaisesRegex(ConfigError, field_name):
                validate_config(config)

    def test_normal_portal_urls_keep_the_gateway_port(self) -> None:
        config = _valid_config()
        # This test is about URL normalization, not password-source policy;
        # use the only supported Windows source so it is platform neutral.
        config["security"] = {
            "password_source": "keychain",
            "keychain_service": "szu-netlogin",
            "keychain_account": "student-id",
        }
        config["auth"].update(
            {
                "logout_url": "http://172.30.255.42:801/eportal/portal/logout",
                "logout_page_url": "http://172.30.255.42:801/a79.htm",
                "unbind_url": "http://172.30.255.42:801/eportal/portal/mac/unbind",
            }
        )
        validate_config(config)


class PasswordSourceTests(unittest.TestCase):
    def test_windows_rejects_environment_and_private_file_sources(self) -> None:
        for source in ("env", "private_file"):
            config = _valid_config()
            config["security"]["password_source"] = source
            config["security"]["password_file"] = "password.yaml"
            with patch.object(config_module.os, "name", "nt"):
                with self.assertRaisesRegex(ConfigError, "Credential Manager"):
                    validate_config(config)

    def test_macos_keychain_uses_security_command_without_keyring(self) -> None:
        config = _valid_config()
        config["security"] = {
            "password_source": "keychain",
            "keychain_service": "szu-netlogin",
            "keychain_account": "student-id",
        }

        with (
            patch.object(config_module.sys, "platform", "darwin"),
            patch("src.szu_netlogin.config._load_keyring") as load_keyring,
            patch("src.szu_netlogin.config.subprocess.run") as run,
        ):
            run.return_value = Mock(returncode=0, stdout="secret\n")

            self.assertEqual(config_module.get_password(config), "secret")

        load_keyring.assert_not_called()


def _valid_config() -> dict:
    return {
        "auth": {
            "type": "dorm_drcom",
            "login_url": "http://172.30.255.42:801/eportal/portal/login",
            "callback": "dr1003",
            "login_method": "1",
            "account_prefix": ",1,",
            "timeout_seconds": 8,
        },
        "user": {"username": "student-id"},
        "network": {
            "test_urls": ["http://captive.apple.com/hotspot-detect.html"],
        },
        "security": {
            "password_source": "env",
            "password_env_name": "SZU_NET_PASSWORD",
        },
    }


if __name__ == "__main__":
    unittest.main()
