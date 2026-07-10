from __future__ import annotations

import unittest
from unittest.mock import patch

from src.szu_netlogin import control
from src.szu_netlogin.portal_detect import NetworkStatus


class ControlTests(unittest.TestCase):
    def test_logout_verification_requires_captive_portal_evidence(self) -> None:
        config = {"network": {}}
        with patch(
            "src.szu_netlogin.control.probe_network",
            return_value=NetworkStatus(True, False, internet_reason="www.baidu.com=timeout"),
        ):
            self.assertFalse(control._verify_campus_logged_out(config))

        with patch(
            "src.szu_netlogin.control.probe_network",
            return_value=NetworkStatus(True, False, internet_portal_redirect=True),
        ):
            self.assertTrue(control._verify_campus_logged_out(config))

    def test_replace_username_adds_separator_after_non_newline_content(self) -> None:
        result = control._replace_username("auth:\n  type: dorm_drcom", "student-id")
        self.assertEqual(result, 'auth:\n  type: dorm_drcom\nuser:\n  username: "student-id"\n')


if __name__ == "__main__":
    unittest.main()
