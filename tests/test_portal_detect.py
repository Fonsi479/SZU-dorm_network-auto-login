from __future__ import annotations

import unittest
from unittest.mock import Mock, patch

from src.szu_netlogin.portal_detect import (
    GatewayProbe,
    InternetProbe,
    NetworkStatus,
    _probe_campus_internet,
    _probe_gateway,
    classify_network_environment,
    check_gateway_reachable,
    check_internet,
    is_allowed_campus_source_ip,
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

    def test_default_campus_source_cidr_rejects_tun_address(self) -> None:
        self.assertTrue(is_allowed_campus_source_ip({}, "172.24.182.13"))
        self.assertFalse(is_allowed_campus_source_ip({}, "198.18.0.1"))

    def test_invalid_configured_cidr_fails_closed(self) -> None:
        config = {"network": {"campus_source_cidrs": ["bad-cidr"]}}

        self.assertFalse(is_allowed_campus_source_ip(config, "198.18.0.1"))
        self.assertFalse(is_allowed_campus_source_ip(config, "172.24.182.13"))

    def test_partly_invalid_configured_cidr_fails_closed(self) -> None:
        config = {"network": {"campus_source_cidrs": ["172.16.0.0/12", "bad-cidr"]}}

        self.assertFalse(is_allowed_campus_source_ip(config, "172.24.182.13"))

    @patch("src.szu_netlogin.portal_detect.get_logger")
    @patch("src.szu_netlogin.portal_detect.socket.create_connection")
    def test_gateway_probe_ignores_non_campus_source_ip(
        self,
        create_connection: Mock,
        _get_logger: Mock,
    ) -> None:
        sock = Mock()
        sock.getsockname.return_value = ("198.18.0.1", 54321)
        create_connection.return_value.__enter__.return_value = sock

        result = _probe_gateway({"network": {"dorm_gateway_hosts": ["172.30.255.42"]}}, 3)

        self.assertFalse(result.reachable)
        self.assertEqual(result.source_ip, "198.18.0.1")
        self.assertIn("source_ip_not_allowed", result.reason)

    @patch("src.szu_netlogin.portal_detect.get_current_wifi_ssid", return_value="SZU_CTC&CMCC")
    def test_environment_allows_configured_dorm_wifi(self, _ssid: Mock) -> None:
        config = {
            "network": {
                "campus_wifi_names": ["SZU_CTC&CMCC"],
                "campus_source_cidrs": ["172.16.0.0/12"],
            }
        }
        status = NetworkStatus(True, False, source_ip="172.24.182.13")

        environment = classify_network_environment(config, status)

        self.assertEqual(environment.label, "宿舍网络")
        self.assertTrue(environment.auto_login_available)

    @patch("src.szu_netlogin.portal_detect.get_current_wifi_ssid", return_value="")
    def test_environment_marks_proxy_source_as_non_dorm(self, _ssid: Mock) -> None:
        status = NetworkStatus(
            False,
            False,
            source_ip="198.18.0.1",
            gateway_reason="172.30.255.42=source_ip_not_allowed:198.18.0.1",
        )

        environment = classify_network_environment({}, status)

        self.assertEqual(environment.label, "非宿舍网络（疑似代理/VPN）")
        self.assertFalse(environment.auto_login_available)


if __name__ == "__main__":
    unittest.main()
