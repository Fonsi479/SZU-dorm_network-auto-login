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

    @patch("src.szu_netlogin.portal_detect._build_session")
    @patch("src.szu_netlogin.portal_detect._probe_urls")
    def test_internet_probe_uses_default_network_path(
        self,
        probe_urls: Mock,
        build_session: Mock,
    ) -> None:
        probe_urls.return_value = InternetProbe(True, "ok", route="default")

        result = _probe_campus_internet({}, "172.24.9.84", 3)

        self.assertTrue(result.ok)
        self.assertEqual(result.route, "default")
        build_session.assert_called_once_with("", trust_env=True)
        self.assertEqual(probe_urls.call_args.kwargs["route"], "default")

    @patch("src.szu_netlogin.portal_detect._build_session")
    @patch("src.szu_netlogin.portal_detect._probe_urls")
    def test_default_path_failure_logs_once(
        self,
        probe_urls: Mock,
        _build_session: Mock,
    ) -> None:
        probe_urls.return_value = InternetProbe(False, "baidu=timeout", route="default")

        result = _probe_campus_internet({}, "172.24.9.84", 3)

        self.assertFalse(result.ok)
        self.assertEqual(result.route, "default")
        probe_urls.assert_called_once()

    @patch("src.szu_netlogin.portal_detect.get_logger")
    @patch("src.szu_netlogin.portal_detect.socket.create_connection")
    def test_gateway_probe_accepts_any_source_ip(
        self,
        create_connection: Mock,
        _get_logger: Mock,
    ) -> None:
        sock = Mock()
        sock.getsockname.return_value = ("198.18.0.1", 54321)
        create_connection.return_value.__enter__.return_value = sock

        result = _probe_gateway({"network": {"dorm_gateway_hosts": ["172.30.255.42"]}}, 3)

        self.assertTrue(result.reachable)
        self.assertEqual(result.source_ip, "198.18.0.1")

    @patch("src.szu_netlogin.portal_detect.get_current_wifi_ssid", return_value="SZU_CTC&CMCC")
    def test_environment_allows_configured_dorm_wifi(self, _ssid: Mock) -> None:
        config = {
            "network": {
                "campus_wifi_names": ["SZU_CTC&CMCC"],
            }
        }
        status = NetworkStatus(True, False, source_ip="172.24.182.13")

        environment = classify_network_environment(config, status)

        self.assertEqual(environment.label, "宿舍网络")
        self.assertTrue(environment.auto_login_available)

    @patch("src.szu_netlogin.portal_detect.get_current_wifi_ssid", return_value="")
    def test_environment_uses_gateway_reachability_without_source_ip_filter(self, _ssid: Mock) -> None:
        status = NetworkStatus(
            True,
            False,
            source_ip="198.18.0.1",
        )

        environment = classify_network_environment({}, status)

        self.assertEqual(environment.label, "宿舍网络")
        self.assertTrue(environment.auto_login_available)


if __name__ == "__main__":
    unittest.main()
