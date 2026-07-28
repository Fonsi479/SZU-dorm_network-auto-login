from __future__ import annotations

import unittest
from unittest.mock import patch

from src.szu_netlogin import control
from src.szu_netlogin.dorm_drcom_client import PortalSessionFact
from src.szu_netlogin.portal_detect import NetworkStatus


class ControlTests(unittest.TestCase):
    def test_logout_verification_uses_portal_session_not_internet(self) -> None:
        config = {"user": {"username": "481505"}, "network": {}}
        with (
            patch(
                "src.szu_netlogin.control.probe_gateway",
                return_value=NetworkStatus(True, False, source_ip="172.24.182.13"),
            ),
            patch("src.szu_netlogin.dorm_drcom_client.DormDrcomClient") as client,
        ):
            client.return_value.session_fact.return_value = PortalSessionFact(state="online")
            self.assertFalse(control._verify_campus_logged_out(config))

            client.return_value.session_fact.return_value = PortalSessionFact(state="offline")
            self.assertTrue(control._verify_campus_logged_out(config))

    def test_replace_username_adds_separator_after_non_newline_content(self) -> None:
        result = control._replace_username("auth:\n  type: dorm_drcom", "student-id")
        self.assertEqual(result, 'auth:\n  type: dorm_drcom\nuser:\n  username: "student-id"\n')


if __name__ == "__main__":
    unittest.main()
