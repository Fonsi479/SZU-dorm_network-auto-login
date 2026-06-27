from __future__ import annotations

import argparse
import unittest
from unittest.mock import Mock, patch

from src.szu_netlogin import login


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


if __name__ == "__main__":
    unittest.main()
