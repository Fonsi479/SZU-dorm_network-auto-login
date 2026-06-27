from __future__ import annotations

import unittest
from unittest.mock import patch

from src.szu_netlogin.dorm_drcom_client import DormDrcomClient


class DormDrcomResponseTests(unittest.TestCase):
    def setUp(self) -> None:
        self.client = DormDrcomClient({"auth": {}})

    def test_structured_success_wins_over_password_message(self) -> None:
        result = self.client.is_success_response(
            {"result": 1, "message": "密码即将到期，已登录"}
        )

        self.assertIs(result, True)

    def test_structured_failure_wins_over_success_message(self) -> None:
        result = self.client.is_success_response(
            {"result": 0, "message": "登录成功"}
        )

        self.assertIs(result, False)

    def test_password_error_without_result_is_still_failure(self) -> None:
        result = self.client.is_success_response({"message": "密码错误"})

        self.assertIs(result, False)

    def test_password_expiry_login_message_without_result_is_success(self) -> None:
        result = self.client.is_success_response({"message": "密码即将到期，已登录"})

        self.assertIs(result, True)

    def test_inactive_logout_accepts_offline_result_string(self) -> None:
        result = self.client.is_inactive_logout_response(
            {"result": "offline", "message": "用户不在线"}
        )

        self.assertIs(result, True)

    def test_inactive_logout_does_not_override_positive_result(self) -> None:
        result = self.client.is_inactive_logout_response(
            {"result": 1, "message": "用户不在线"}
        )

        self.assertIs(result, False)

    @patch("src.szu_netlogin.dorm_drcom_client.get_logger")
    @patch("src.szu_netlogin.dorm_drcom_client._get_source_ip", return_value="198.18.0.1")
    def test_login_skips_non_campus_source_ip(self, _get_source_ip, _get_logger) -> None:
        client = DormDrcomClient(
            {
                "auth": {
                    "login_url": "http://172.30.255.42:801/eportal/portal/login",
                    "callback": "dr1003",
                    "login_method": "1",
                    "account_prefix": ",1,",
                    "timeout_seconds": 8,
                },
                "network": {"campus_source_cidrs": ["172.16.0.0/12"]},
            }
        )

        with patch.object(client.session, "get") as get:
            result = client.login("student-id", "password")

        self.assertIs(result, False)
        get.assert_not_called()


if __name__ == "__main__":
    unittest.main()
