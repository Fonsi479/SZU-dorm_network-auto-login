from __future__ import annotations

import unittest
from unittest.mock import Mock, patch

from src.szu_netlogin.portal_detect import (
    GatewayProbe,
    InternetProbe,
    NetworkStatus,
    _probe_campus_internet,
    check_gateway_reachable,
    check_internet,
)


class CampusInternetProbeTests(unittest.TestCase):
    @patch("src.szu_netlogin.portal_detect.probe_network")
    def test_check_internet_defers_timeout_to_probe_network(
        self,
        probe_network: Mock,
    ) -> None:
        config = {"network": {"timeout_seconds": 9}}
        probe_network.return_value = NetworkStatus(True, True)

        self.assertTrue(check_internet(config))

        probe_network.assert_called_once_with(config, timeout_seconds=None)

    @patch("src.szu_netlogin.portal_detect._probe_gateway")
    def test_check_gateway_reachable_uses_configured_timeout(
        self,
        probe_gateway: Mock,
    ) -> None:
        config = {"network": {"timeout_seconds": 9}}
        probe_gateway.return_value = GatewayProbe(True)

        self.assertTrue(check_gateway_reachable(config))

        probe_gateway.assert_called_once_with(config, 9)

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
