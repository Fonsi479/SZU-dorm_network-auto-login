from __future__ import annotations

import unittest
from unittest.mock import patch

from src.szu_netlogin.dorm_drcom_client import (
    DormDrcomClient,
    PortalTerminalParams,
    _build_portal_terminal_params,
    _ip_to_parse_int,
    _parse_ifconfig_mac_for_ip,
)


class DormDrcomResponseTests(unittest.TestCase):
    def setUp(self) -> None:
        self.client = DormDrcomClient({"auth": {}})

    def test_structured_success_wins_over_password_message(self) -> None:
        result = self.client.is_success_response(
            {"result": 1, "message": "密码即将到期，已登录"}
        )

        self.assertIs(result, True)

    def test_structured_failure_wins_over_success_message(self) -> None:
        result = self.client.is_success_response(
            {"result": 0, "message": "登录成功"}
        )

        self.assertIs(result, False)

    def test_password_error_without_result_is_still_failure(self) -> None:
        result = self.client.is_success_response({"message": "密码错误"})

        self.assertIs(result, False)

    def test_password_expiry_login_message_without_result_is_success(self) -> None:
        result = self.client.is_success_response({"message": "密码即将到期，已登录"})

        self.assertIs(result, True)

    def test_inactive_logout_accepts_offline_result_string(self) -> None:
        result = self.client.is_inactive_logout_response(
            {"result": "offline", "message": "用户不在线"}
        )

        self.assertIs(result, True)

    def test_inactive_logout_does_not_override_positive_result(self) -> None:
        result = self.client.is_inactive_logout_response(
            {"result": 1, "message": "用户不在线"}
        )

        self.assertIs(result, False)

    @patch("src.szu_netlogin.dorm_drcom_client.get_logger")
    @patch("src.szu_netlogin.dorm_drcom_client._get_source_ip", return_value="198.18.0.1")
    def test_login_skips_non_campus_source_ip(self, _get_source_ip, _get_logger) -> None:
        client = DormDrcomClient(
            {
                "auth": {
                    "login_url": "http://172.30.255.42:801/eportal/portal/login",
                    "callback": "dr1003",
                    "login_method": "1",
                    "account_prefix": ",1,",
                    "timeout_seconds": 8,
                },
                "network": {"campus_source_cidrs": ["172.16.0.0/12"]},
            }
        )

        with patch.object(client.session, "get") as get:
            result = client.login("student-id", "password")

        self.assertIs(result, False)
        get.assert_not_called()

    def test_parse_ifconfig_mac_for_source_ip(self) -> None:
        ifconfig_output = """
lo0: flags=8049<UP,LOOPBACK,RUNNING,MULTICAST> mtu 16384
    inet 127.0.0.1 netmask 0xff000000
en0: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500
    ether 9e:b5:6a:20:11:e4
    inet 172.24.182.13 netmask 0xffff0000 broadcast 172.24.255.255
utun4: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST> mtu 4064
    inet 198.18.0.1 --> 198.18.0.1 netmask 0xffffff00
"""

        mac = _parse_ifconfig_mac_for_ip(ifconfig_output, "172.24.182.13")

        self.assertEqual(mac, "9eb56a2011e4")

    def test_ip_to_parse_int_matches_portal_javascript(self) -> None:
        self.assertEqual(_ip_to_parse_int("172.17.100.6"), "2886820870")
        self.assertEqual(_ip_to_parse_int("172.24.182.13"), "2887300621")

    def test_logout_terminal_uses_online_record_to_avoid_stale_page_ip(self) -> None:
        terminal = _build_portal_terminal_params(
            page_url=(
                "http://172.30.255.42/a79.htm?"
                "wlanuserip=172.17.100.6&wlanacname=&wlanacip=172.30.255.41"
            ),
            page_text="""
v46ip='172.24.182.13'                          ;
vlanid="0"   ;ss4="000000000000";ss5="172.24.182.13"  ;
""",
            online_record={
                "online_ip": "172.24.182.13",
                "online_mac": "9eb56a2011e4",
                "nas_ip": "704585388",
                "user_account": "481505",
                "is_owner_ip": "1",
            },
            source_ip="172.24.182.13",
            source_mac="9eb56a2011e4",
            js_version="4.1.3",
        )

        self.assertEqual(terminal.ip, "172.24.182.13")
        self.assertEqual(terminal.mac, "000000000000")
        self.assertEqual(terminal.wlan_ac_ip, "172.30.255.41")

    def test_logout_terminal_uses_nas_ip_when_page_has_no_ac_ip(self) -> None:
        terminal = _build_portal_terminal_params(
            page_url="http://172.30.255.42/a79.htm",
            page_text="v46ip='172.24.182.13';vlanid=\"0\";ss4=\"000000000000\";",
            online_record={
                "online_ip": "172.24.182.13",
                "online_mac": "9eb56a2011e4",
                "nas_ip": "704585388",
            },
            source_ip="172.24.182.13",
            source_mac="9eb56a2011e4",
            js_version="4.1.3",
        )

        self.assertEqual(terminal.wlan_ac_ip, "172.30.255.41")

    def test_logout_params_match_official_portal_flow(self) -> None:
        client = DormDrcomClient(_test_config())
        terminal = PortalTerminalParams(
            ip="172.24.182.13",
            mac="000000000000",
            vlan="0",
            wlan_ac_ip="172.30.255.41",
            wlan_ac_name="",
            js_version="4.1.3",
        )

        unbind_params = client.build_unbind_params("481505", terminal)
        logout_params = client.build_logout_params("481505", terminal)

        self.assertEqual(unbind_params["callback"], "dr1003")
        self.assertEqual(unbind_params["user_account"], "481505")
        self.assertEqual(unbind_params["wlan_user_ip"], "2887300621")
        self.assertEqual(unbind_params["wlan_user_mac"], "000000000000")
        self.assertEqual(logout_params["callback"], "dr1004")
        self.assertEqual(logout_params["user_account"], "drcom")
        self.assertEqual(logout_params["user_password"], "123")
        self.assertEqual(logout_params["wlan_user_ip"], "172.24.182.13")
        self.assertEqual(logout_params["wlan_ac_ip"], "172.30.255.41")

    @patch("src.szu_netlogin.dorm_drcom_client._get_source_ip", return_value="")
    def test_logout_calls_unbind_before_logout(self, _get_source_ip) -> None:
        client = DormDrcomClient(_test_config())
        terminal = PortalTerminalParams(
            ip="172.24.182.13",
            mac="000000000000",
            vlan="0",
            wlan_ac_ip="172.30.255.41",
            wlan_ac_name="",
            js_version="4.1.3",
        )
        responses = [
            _Response('dr1003({"result":0,"msg":"无法获取终端MAC地址！"});'),
            _Response('dr1004({"result":1,"msg":"Portal协议注销成功！"});'),
        ]

        with patch.object(client, "discover_logout_terminal_params", return_value=terminal):
            with patch.object(client.session, "get", side_effect=responses) as get:
                result = client.logout("481505")

        self.assertEqual(result.status, "success")
        urls = [call.args[0] for call in get.call_args_list]
        self.assertEqual(
            urls,
            [
                "http://172.30.255.42:801/eportal/portal/mac/unbind",
                "http://172.30.255.42:801/eportal/portal/logout",
            ],
        )
        self.assertEqual(get.call_args_list[0].kwargs["params"]["user_account"], "481505")
        self.assertEqual(get.call_args_list[1].kwargs["params"]["user_account"], "drcom")

    @patch(
        "src.szu_netlogin.dorm_drcom_client._get_terminal_mac_for_ip",
        return_value="9eb56a2011e4",
    )
    @patch("src.szu_netlogin.dorm_drcom_client._get_source_ip", return_value="172.24.182.13")
    def test_login_params_include_terminal_ip_and_mac(self, _get_source_ip, _get_mac) -> None:
        client = DormDrcomClient(_test_config())
        response = _Response('dr1003({"result":1,"msg":"Portal协议认证成功！"});')

        with patch.object(client.session, "get", return_value=response) as get:
            result = client.login("student-id", "password")

        self.assertIs(result, True)
        params = get.call_args.kwargs["params"]
        self.assertEqual(params["wlan_user_ip"], "172.24.182.13")
        self.assertEqual(params["wlan_user_mac"], "9eb56a2011e4")


class _Response:
    status_code = 200

    def __init__(self, text: str) -> None:
        self.text = text


def _test_config() -> dict:
    return {
        "auth": {
            "login_url": "http://172.30.255.42:801/eportal/portal/login",
            "callback": "dr1003",
            "logout_callback": "dr1004",
            "login_method": "1",
            "account_prefix": ",1,",
            "timeout_seconds": 8,
        },
        "network": {"campus_source_cidrs": ["172.16.0.0/12"]},
    }


if __name__ == "__main__":
    unittest.main()
