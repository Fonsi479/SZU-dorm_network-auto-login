from __future__ import annotations

import unittest

from src.szu_netlogin.menubar_app import PeriodicDeadline


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


if __name__ == "__main__":
    unittest.main()
