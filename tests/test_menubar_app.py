from __future__ import annotations

import unittest

from src.szu_netlogin.menubar_app import (
    PeriodicDeadline,
    StatusRefreshResult,
    auto_login_state_label,
    should_start_auto_login,
)
from src.szu_netlogin.portal_detect import NetworkStatus


class PeriodicDeadlineTests(unittest.TestCase):
    def test_becomes_due_immediately_after_long_sleep_gap(self) -> None:
        now = [100.0]
        schedule = PeriodicDeadline(120, 5, clock=lambda: now[0])

        self.assertFalse(schedule.consume_if_due())
        now[0] = 105.0
        self.assertTrue(schedule.consume_if_due())

        now[0] = 10_000.0
        self.assertTrue(schedule.consume_if_due())
        self.assertFalse(schedule.consume_if_due())


class AutoLoginGateTests(unittest.TestCase):
    def test_gateway_unreachable_stops_auto_login(self) -> None:
        result = StatusRefreshResult(False, NetworkStatus(False, False))

        self.assertFalse(should_start_auto_login(False, result))
        self.assertEqual(auto_login_state_label(False, result), "非校园网，自动登录停用")

    def test_gateway_reachable_allows_auto_login_check(self) -> None:
        result = StatusRefreshResult(False, NetworkStatus(True, False))

        self.assertTrue(should_start_auto_login(False, result))
        self.assertEqual(auto_login_state_label(False, result), "运行中")

    def test_online_gateway_does_not_start_auto_login_check(self) -> None:
        result = StatusRefreshResult(False, NetworkStatus(True, True))

        self.assertFalse(should_start_auto_login(False, result))

    def test_unknown_status_waits_for_refresh_before_auto_login(self) -> None:
        self.assertFalse(should_start_auto_login(False, None))

    def test_config_error_stops_auto_login_check(self) -> None:
        result = StatusRefreshResult(False, NetworkStatus(False, False), "config missing")

        self.assertFalse(should_start_auto_login(False, result))

    def test_paused_still_stops_auto_login(self) -> None:
        result = StatusRefreshResult(True, NetworkStatus(True, False))

        self.assertFalse(should_start_auto_login(True, result))
        self.assertEqual(auto_login_state_label(True, result), "已暂停")


if __name__ == "__main__":
    unittest.main()
