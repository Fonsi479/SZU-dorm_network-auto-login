from __future__ import annotations

import argparse
import unittest
from unittest.mock import Mock, patch

from src.szu_netlogin import login
from src.szu_netlogin.portal_detect import NetworkEnvironment, NetworkStatus


class LoginLockTests(unittest.TestCase):
    def test_manual_login_non_campus_reads_zero_credentials_and_sends_zero_auth_requests(self) -> None:
        logger = Mock()
        config = {"user": {"username": "student-id"}, "network": {}}
        client_class = Mock()
        get_password = Mock()
        with (
            patch(
                "src.szu_netlogin.login.parse_args",
                return_value=argparse.Namespace(check_and_login=False, dry_run=False),
            ),
            patch("src.szu_netlogin.login.get_logger", return_value=logger),
            patch("src.szu_netlogin.login.load_config", return_value=config),
            patch("src.szu_netlogin.login.describe_password_source", return_value="credential-manager"),
            patch(
                "src.szu_netlogin.login.probe_gateway",
                return_value=NetworkStatus(False, False, gateway_reason="gateway_unreachable"),
            ),
            patch(
                "src.szu_netlogin.login.classify_network_environment",
                return_value=NetworkEnvironment("非校园网", False, False),
            ),
            patch("src.szu_netlogin.login.get_password", get_password),
            patch("src.szu_netlogin.login.DormDrcomClient", client_class),
            patch("builtins.print"),
        ):
            result = login.main()

        self.assertEqual(result, 0)
        get_password.assert_not_called()
        client_class.assert_not_called()

    def test_manual_login_unknown_session_reads_zero_credentials(self) -> None:
        logger = Mock()
        config = {"user": {"username": "student-id"}, "network": {}}
        client = Mock()
        client.session_fact.return_value = Mock(state="unknown", matches=Mock(return_value=False))
        get_password = Mock()
        with (
            patch(
                "src.szu_netlogin.login.parse_args",
                return_value=argparse.Namespace(check_and_login=False, dry_run=False),
            ),
            patch("src.szu_netlogin.login.get_logger", return_value=logger),
            patch("src.szu_netlogin.login.load_config", return_value=config),
            patch("src.szu_netlogin.login.describe_password_source", return_value="credential-manager"),
            patch(
                "src.szu_netlogin.login.probe_gateway",
                return_value=NetworkStatus(True, False, source_ip="172.24.1.2"),
            ),
            patch(
                "src.szu_netlogin.login.classify_network_environment",
                return_value=NetworkEnvironment("宿舍网络", True, True),
            ),
            patch("src.szu_netlogin.login.get_password", get_password),
            patch("src.szu_netlogin.login.DormDrcomClient", return_value=client),
            patch("builtins.print"),
        ):
            result = login.main()

        self.assertEqual(result, 0)
        get_password.assert_not_called()
        client.login_with_result.assert_not_called()

    def test_lock_contention_logs_skip_instead_of_login_failure(self) -> None:
        logger = Mock()

        with (
            patch(
                "src.szu_netlogin.login.parse_args",
                return_value=argparse.Namespace(check_and_login=True, dry_run=False),
            ),
            patch("src.szu_netlogin.login.is_paused", return_value=False),
            patch("src.szu_netlogin.login.get_logger", return_value=logger),
            patch("src.szu_netlogin.login.acquire_lock", return_value=None),
            patch("builtins.print"),
        ):
            result = login.main()

        self.assertEqual(result, 0)
        logger.info.assert_any_call("自动检查跳过：已有一次自动检查正在运行")
        self.assertNotIn("登录失败", [call.args[0] for call in logger.info.call_args_list])

    def test_check_and_login_rechecks_pause_before_real_login(self) -> None:
        logger = Mock()
        lock_handle = Mock()
        config = {"user": {"username": "student-id"}}

        with (
            patch(
                "src.szu_netlogin.login.parse_args",
                return_value=argparse.Namespace(check_and_login=True, dry_run=False),
            ),
            patch("src.szu_netlogin.login.is_paused", side_effect=[False, True]),
            patch("src.szu_netlogin.login.get_logger", return_value=logger),
            patch("src.szu_netlogin.login.acquire_lock", return_value=lock_handle),
            patch("src.szu_netlogin.login.load_config", return_value=config),
            patch("src.szu_netlogin.login.describe_password_source", return_value="env"),
            patch(
                "src.szu_netlogin.login.probe_gateway",
                return_value=NetworkStatus(
                    gateway_reachable=True,
                    campus_internet_ok=False,
                    source_ip="172.24.1.2",
                ),
            ),
            patch("src.szu_netlogin.login.get_password") as get_password,
            patch("src.szu_netlogin.login.DormDrcomClient") as client_class,
            patch("builtins.print"),
        ):
            result = login.main()

        self.assertEqual(result, 0)
        logger.info.assert_any_call("自动登录执行前检测到已暂停，跳过自动登录")
        get_password.assert_not_called()
        client_class.assert_not_called()
        lock_handle.close.assert_called_once()

    def test_login_failure_reason_labels_are_user_facing(self) -> None:
        self.assertEqual(login.login_failure_reason_label("password_missing"), "密码缺失")
        self.assertEqual(login.login_failure_reason_label("password_error"), "密码错误")


if __name__ == "__main__":
    unittest.main()
