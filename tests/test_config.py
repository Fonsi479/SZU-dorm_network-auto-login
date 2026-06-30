from __future__ import annotations

import unittest

from src.szu_netlogin.config import ConfigError, _parse_simple_yaml, validate_config


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
    def test_rejects_invalid_campus_source_cidr(self) -> None:
        config = _valid_config()
        config["network"]["campus_source_cidrs"] = ["bad-cidr"]

        with self.assertRaisesRegex(ConfigError, "campus_source_cidrs"):
            validate_config(config)

    def test_rejects_empty_campus_source_cidr_list(self) -> None:
        config = _valid_config()
        config["network"]["campus_source_cidrs"] = []

        with self.assertRaisesRegex(ConfigError, "campus_source_cidrs"):
            validate_config(config)

    def test_rejects_invalid_logout_discovery_urls(self) -> None:
        config = _valid_config()
        config["auth"]["logout_page_url"] = "172.30.255.42/a79.htm"

        with self.assertRaisesRegex(ConfigError, "logout_page_url"):
            validate_config(config)

        config = _valid_config()
        config["auth"]["unbind_url"] = "172.30.255.42/unbind"

        with self.assertRaisesRegex(ConfigError, "unbind_url"):
            validate_config(config)


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
            "campus_source_cidrs": ["172.16.0.0/12"],
        },
        "security": {
            "password_source": "env",
            "password_env_name": "SZU_NET_PASSWORD",
        },
    }


if __name__ == "__main__":
    unittest.main()
