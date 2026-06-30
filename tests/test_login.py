from __future__ import annotations

import argparse
import unittest
from unittest.mock import Mock, patch

from src.szu_netlogin import login
from src.szu_netlogin.portal_detect import NetworkStatus


class LoginLockTests(unittest.TestCase):
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
                "src.szu_netlogin.login.probe_network",
                return_value=NetworkStatus(gateway_reachable=True, campus_internet_ok=False),
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


if __name__ == "__main__":
    unittest.main()
