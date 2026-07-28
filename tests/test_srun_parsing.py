from __future__ import annotations

import unittest
from pathlib import Path

from src.szu_netlogin.srun_jsonp import JSONPError, MAX_JSONP_BYTES, decode_jsonp
from src.szu_netlogin.srun_portal import PortalDiscoveryError, discover_portal


FIXTURES = Path(__file__).parents[1] / "protocol-spec" / "fixtures"


class SRunJSONPTests(unittest.TestCase):
    def test_parses_exact_callback_with_whitespace_and_semicolon(self) -> None:
        value = decode_jsonp('  cb_1({"error":"ok"});\n', "cb_1")
        self.assertEqual(value, {"error": "ok"})

    def test_rejects_wrong_callback(self) -> None:
        with self.assertRaises(JSONPError):
            decode_jsonp('wrong({"error":"ok"})', "expected")

    def test_rejects_trailing_script_fixture(self) -> None:
        payload = (FIXTURES / "malformed_response.txt").read_bytes()
        with self.assertRaises(JSONPError):
            decode_jsonp(payload, "_szu_cb_expected")

    def test_rejects_oversized_response(self) -> None:
        with self.assertRaises(JSONPError):
            decode_jsonp(b"x" * (MAX_JSONP_BYTES + 1), "cb")

    def test_rejects_non_object(self) -> None:
        with self.assertRaises(JSONPError):
            decode_jsonp("cb([1,2,3])", "cb")

    def test_decodes_gb18030_object(self) -> None:
        payload = 'cb({"message":"\u6d4b\u8bd5"})'.encode("gb18030")
        self.assertEqual(decode_jsonp(payload, "cb")["message"], "测试")


class PortalDiscoveryTests(unittest.TestCase):
    def test_acid_five_fixture(self) -> None:
        html = (FIXTURES / "portal_acid_5_sanitized.html").read_text(encoding="utf-8")
        result = discover_portal(
            "https://net.szu.edu.cn/srun_portal_pc", html, "198.51.100.27"
        )
        self.assertEqual((result.acid, result.client_ip), ("5", "198.51.100.27"))

    def test_dynamic_acid_fixture(self) -> None:
        html = (FIXTURES / "portal_dynamic_acid_sanitized.html").read_text(encoding="utf-8")
        result = discover_portal(
            "https://net.szu.edu.cn/srun_portal_pc", html, "203.0.113.41"
        )
        self.assertEqual((result.acid, result.client_ip), ("17", "203.0.113.41"))

    def test_url_and_page_conflict_fails_closed(self) -> None:
        html = (FIXTURES / "portal_dynamic_acid_sanitized.html").read_text(encoding="utf-8")
        with self.assertRaisesRegex(PortalDiscoveryError, "SRUN_CONFIG_CONFLICT"):
            discover_portal(
                "https://net.szu.edu.cn/srun_portal_pc?ac_id=5&ip=203.0.113.41",
                html,
                "203.0.113.41",
            )

    def test_route_and_page_ip_conflict_fails_closed(self) -> None:
        html = (FIXTURES / "portal_acid_5_sanitized.html").read_text(encoding="utf-8")
        with self.assertRaisesRegex(PortalDiscoveryError, "SRUN_CONFIG_CONFLICT"):
            discover_portal("https://net.szu.edu.cn/srun_portal_pc", html, "198.51.100.99")

    def test_missing_acid_never_uses_a_constant(self) -> None:
        with self.assertRaisesRegex(PortalDiscoveryError, "SRUN_CONFIG_MISSING_ACID"):
            discover_portal(
                "https://net.szu.edu.cn/srun_portal_pc", "<html></html>", "198.51.100.27"
            )

    def test_unverified_host_is_rejected(self) -> None:
        with self.assertRaisesRegex(PortalDiscoveryError, "ENV_PORTAL_IDENTITY_UNVERIFIED"):
            discover_portal("https://portal.invalid/?ac_id=5", "", "198.51.100.27")


if __name__ == "__main__":
    unittest.main()
