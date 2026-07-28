from __future__ import annotations

import unittest
from unittest.mock import patch

from src.szu_netlogin.dorm_drcom_client import (
    DormDrcomClient,
    PortalOnlineListResult,
    PortalSessionFact,
    PortalStatusResult,
    PortalTerminalParams,
    _build_portal_terminal_params,
    _ip_to_parse_int,
    _select_online_record,
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
        result = self.client.is_success_response({"result": 0, "message": "登录成功"})
        self.assertIs(result, False)

    def test_existing_online_session_counts_as_success(self) -> None:
        result = self.client.is_success_response(
            {"result": 0, "msg": "IP: 172.24.59.154 已经在线！", "ret_code": 2}
        )
        self.assertIs(result, True)

    def test_password_error_without_result_is_still_failure(self) -> None:
        self.assertIs(self.client.is_success_response({"message": "密码错误"}), False)

    def test_password_expiry_login_message_without_result_is_success(self) -> None:
        self.assertIs(
            self.client.is_success_response({"message": "密码即将到期，已登录"}),
            True,
        )

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

    @patch("src.szu_netlogin.dorm_drcom_client._get_source_ip", return_value="198.18.0.1")
    def test_login_rejects_unverified_source_without_request(self, _get_source_ip) -> None:
        client = DormDrcomClient(_test_config())
        with patch.object(client.session, "get") as get:
            result = client.login_with_result("student-id", "password")

        self.assertEqual(result.status, "failed")
        self.assertEqual(result.reason, "source_ip_unverified")
        get.assert_not_called()

    @patch("src.szu_netlogin.dorm_drcom_client._get_source_ip", return_value="172.24.182.13")
    def test_login_omits_local_mac_and_verifies_session(self, _get_source_ip) -> None:
        client = DormDrcomClient(_test_config())
        response = _Response('dr1003({"result":1,"msg":"Portal协议认证成功！"});')

        with (
            patch.object(client, "verify_login", return_value=True) as verify,
            patch.object(client.session, "get", return_value=response) as get,
        ):
            result = client.login("student-id", "password")

        self.assertIs(result, True)
        params = get.call_args.kwargs["params"]
        self.assertEqual(params["wlan_user_ip"], "172.24.182.13")
        self.assertNotIn("wlan_user_mac", params)
        verify.assert_called_once_with("student-id", "172.24.182.13")

    @patch("src.szu_netlogin.dorm_drcom_client._get_source_ip", return_value="172.24.182.13")
    def test_login_ack_without_session_confirmation_is_unknown(self, _get_source_ip) -> None:
        client = DormDrcomClient(_test_config())
        response = _Response('dr1003({"result":1,"msg":"Portal协议认证成功！"});')

        with (
            patch.object(client, "verify_login", return_value=False),
            patch.object(client.session, "get", return_value=response),
        ):
            result = client.login_with_result("student-id", "password")

        self.assertEqual(result.status, "unknown")
        self.assertEqual(result.reason, "login_not_confirmed")

    @patch("src.szu_netlogin.dorm_drcom_client._get_source_ip", return_value="172.24.182.13")
    def test_login_with_result_classifies_password_error(self, _get_source_ip) -> None:
        client = DormDrcomClient(_test_config())
        response = _Response('dr1003({"result":0,"msg":"密码错误"});')
        with patch.object(client.session, "get", return_value=response):
            result = client.login_with_result("student-id", "password")
        self.assertEqual(result.status, "failed")
        self.assertEqual(result.reason, "password_error")

    @patch("src.szu_netlogin.dorm_drcom_client._get_source_ip", return_value="172.24.182.13")
    def test_login_with_result_classifies_server_uncertain(self, _get_source_ip) -> None:
        client = DormDrcomClient(_test_config())
        with patch.object(
            client.session,
            "get",
            return_value=_Response("temporary unavailable", status_code=503),
        ):
            result = client.login_with_result("student-id", "password")
        self.assertEqual(result.status, "unknown")
        self.assertEqual(result.reason, "server_response_uncertain")


class PortalSessionTests(unittest.TestCase):
    def test_session_fact_uses_exact_server_identity(self) -> None:
        client = DormDrcomClient(_test_config())
        status = PortalStatusResult(
            readable=True,
            declared_online=True,
            account="481505",
            ip="172.24.182.13",
            mac="000000000000",
        )
        online = PortalOnlineListResult(
            readable=True,
            exact_record={
                "user_account": "481505",
                "online_ip": "172.24.182.13",
                "online_mac": "9eb56a2011e4",
            },
        )
        with (
            patch.object(client, "_fetch_portal_status", return_value=status),
            patch.object(client, "_fetch_online_list", return_value=online),
        ):
            fact = client.session_fact("481505", "172.24.182.13")

        self.assertEqual(fact.state, "online")
        self.assertTrue(fact.matches("481505", "172.24.182.13"))
        self.assertEqual(fact.mac, "9eb56a2011e4")

    def test_readable_online_list_without_exact_identity_is_offline(self) -> None:
        client = DormDrcomClient(_test_config())
        with (
            patch.object(client, "_fetch_portal_status", return_value=PortalStatusResult()),
            patch.object(
                client,
                "_fetch_online_list",
                return_value=PortalOnlineListResult(readable=True),
            ),
        ):
            fact = client.session_fact("481505", "172.24.182.13")
        self.assertEqual(fact.state, "offline")

    def test_online_record_selection_never_falls_back_to_other_device(self) -> None:
        parsed = {
            "list": [
                {
                    "user_account": "481505",
                    "online_ip": "172.24.1.10",
                    "online_mac": "aaaaaaaaaaaa",
                    "is_owner_ip": "1",
                },
                {
                    "user_account": "other",
                    "online_ip": "172.24.182.13",
                    "online_mac": "bbbbbbbbbbbb",
                },
            ]
        }
        self.assertEqual(_select_online_record(parsed, "481505", "172.24.182.13"), {})

    def test_verify_login_retries_until_exact_session_appears(self) -> None:
        client = DormDrcomClient(_test_config())
        facts = [
            PortalSessionFact(state="unknown"),
            PortalSessionFact(
                state="online",
                account="481505",
                ip="172.24.182.13",
            ),
        ]
        with (
            patch.object(client, "session_fact", side_effect=facts),
            patch("src.szu_netlogin.dorm_drcom_client.time.sleep"),
        ):
            result = client.verify_login("481505", "172.24.182.13")
        self.assertIs(result, True)


class PortalLogoutTests(unittest.TestCase):
    def test_ip_to_parse_int_matches_portal_javascript(self) -> None:
        self.assertEqual(_ip_to_parse_int("172.17.100.6"), "2886820870")
        self.assertEqual(_ip_to_parse_int("172.24.182.13"), "2887300621")

    def test_portal_page_identity_outranks_online_list(self) -> None:
        terminal = _build_portal_terminal_params(
            page_url=(
                "http://172.30.255.42/a79.htm?"
                "wlanuserip=172.17.100.6&wlanacname=&wlanacip=172.30.255.41"
            ),
            page_text='v46ip="172.24.182.13";vlanid="0";ss4="000000000000";',
            online_record={
                "online_ip": "172.24.182.13",
                "online_mac": "9eb56a2011e4",
                "nas_ip": "704585388",
            },
            source_ip="172.24.182.13",
            js_version="4.1.3",
        )
        self.assertEqual(terminal.ip, "172.17.100.6")
        self.assertEqual(terminal.mac, "000000000000")
        self.assertEqual(terminal.wlan_ac_ip, "172.30.255.41")

    def test_online_list_nas_does_not_manufacture_logout_ac_ip(self) -> None:
        terminal = _build_portal_terminal_params(
            page_url="http://172.30.255.42/a79.htm",
            page_text='v46ip="172.24.182.13";vlanid="0";ss4="000000000000";',
            online_record={
                "online_ip": "172.24.182.13",
                "online_mac": "9eb56a2011e4",
                "nas_ip": "704585388",
            },
            source_ip="172.24.182.13",
            js_version="4.1.3",
        )
        self.assertEqual(terminal.wlan_ac_ip, "")

    def test_unbind_uses_server_mac_while_logout_preserves_page_sentinel(self) -> None:
        client = DormDrcomClient(_test_config())
        terminal = PortalTerminalParams(
            ip="172.24.182.13",
            mac="000000000000",
            vlan="0",
            wlan_ac_ip="",
            js_version="4.1.3",
        )
        unbind = client.build_unbind_params(
            "481505",
            terminal,
            server_mac="9eb56a2011e4",
        )
        logout = client.build_logout_params("481505", terminal)
        self.assertEqual(unbind["wlan_user_mac"], "9eb56a2011e4")
        self.assertEqual(logout["wlan_user_mac"], "000000000000")

    @patch("src.szu_netlogin.dorm_drcom_client._get_source_ip", return_value="172.24.182.13")
    def test_logout_calls_server_mac_unbind_before_portal_logout(self, _get_source_ip) -> None:
        client = DormDrcomClient(_test_config())
        before = PortalSessionFact(
            state="online",
            account="481505",
            ip="172.24.182.13",
            mac="9eb56a2011e4",
        )
        terminal = PortalTerminalParams(
            ip="172.24.182.13",
            mac="000000000000",
            vlan="0",
            js_version="4.1.3",
        )
        responses = [
            _Response('dr1003({"result":0,"msg":"mac不存在"});'),
            _Response('dr1004({"result":1,"msg":"Portal协议注销成功！"});'),
        ]
        with (
            patch.object(client, "session_fact", return_value=before),
            patch.object(client, "discover_logout_terminal_params", return_value=terminal),
            patch.object(client, "_verified_session_state", return_value="offline"),
            patch.object(client.session, "get", side_effect=responses) as get,
        ):
            result = client.logout("481505")

        self.assertEqual(result.status, "success")
        self.assertEqual(result.reason, "portal_logout_verified")
        self.assertEqual(
            [call.args[0] for call in get.call_args_list],
            [
                "http://172.30.255.42:801/eportal/portal/mac/unbind",
                "http://172.30.255.42:801/eportal/portal/logout",
            ],
        )
        self.assertEqual(get.call_args_list[0].kwargs["params"]["wlan_user_mac"], "9eb56a2011e4")
        self.assertEqual(get.call_args_list[1].kwargs["params"]["wlan_user_mac"], "000000000000")


class _Response:
    def __init__(self, text: str, status_code: int = 200) -> None:
        self.text = text
        self.status_code = status_code


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
        "network": {"campus_source_networks": ["172.16.0.0/12"]},
    }


if __name__ == "__main__":
    unittest.main()
