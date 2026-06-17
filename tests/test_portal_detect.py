from __future__ import annotations

import unittest
from unittest.mock import Mock, patch

from src.szu_netlogin.portal_detect import InternetProbe, _probe_campus_internet


class CampusInternetProbeTests(unittest.TestCase):
    @patch("src.szu_netlogin.portal_detect.get_logger")
    @patch("src.szu_netlogin.portal_detect._build_session")
    @patch("src.szu_netlogin.portal_detect._probe_urls")
    def test_system_fallback_success_does_not_log_overall_unavailable(
        self,
        probe_urls: Mock,
        _build_session: Mock,
        get_logger: Mock,
    ) -> None:
        probe_urls.side_effect = [
            InternetProbe(False, "www.baidu.com=timeout", route="campus_source"),
            InternetProbe(True, "ok", route="system_default"),
        ]
        logger = get_logger.return_value

        result = _probe_campus_internet({}, "172.24.9.84", 3)

        self.assertTrue(result.ok)
        messages = [str(call.args[0]) for call in logger.info.call_args_list]
        self.assertFalse(any("检测：不可用" in message for message in messages))
        logger.debug.assert_called_once()
        self.assertFalse(probe_urls.call_args_list[0].kwargs["log_failure"])
        self.assertFalse(probe_urls.call_args_list[1].kwargs["log_failure"])

    @patch("src.szu_netlogin.portal_detect.get_logger")
    @patch("src.szu_netlogin.portal_detect._build_session")
    @patch("src.szu_netlogin.portal_detect._probe_urls")
    def test_both_routes_failing_logs_one_overall_failure(
        self,
        probe_urls: Mock,
        _build_session: Mock,
        get_logger: Mock,
    ) -> None:
        probe_urls.side_effect = [
            InternetProbe(False, "baidu=timeout", route="campus_source"),
            InternetProbe(False, "baidu=connection_failed", route="system_default"),
        ]
        logger = get_logger.return_value

        result = _probe_campus_internet({}, "172.24.9.84", 3)

        self.assertFalse(result.ok)
        unavailable_calls = [
            call for call in logger.info.call_args_list if "检测：不可用" in str(call.args[0])
        ]
        self.assertEqual(len(unavailable_calls), 1)


if __name__ == "__main__":
    unittest.main()
