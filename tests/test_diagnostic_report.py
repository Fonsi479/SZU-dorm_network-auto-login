from __future__ import annotations

import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from src.szu_netlogin import diagnostic_report
from src.szu_netlogin.portal_detect import NetworkEnvironment, NetworkStatus


class DiagnosticReportTests(unittest.TestCase):
    def test_create_report_includes_network_and_redacted_logs(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            login_log = root / "netlogin.log"
            login_log.write_text("user_password=secret user_account=student\n", encoding="utf-8")

            status = NetworkStatus(
                gateway_reachable=True,
                campus_internet_ok=False,
                gateway_host="172.30.255.42",
                source_ip="172.24.182.13",
                internet_route="default",
            )
            environment = NetworkEnvironment("宿舍网络", True, True, "SZU_CTC&CMCC", "172.24.182.13")

            with (
                patch("src.szu_netlogin.diagnostic_report.PROJECT_ROOT", root),
                patch("src.szu_netlogin.diagnostic_report.DEFAULT_CONFIG_PATH", root / "config.yaml"),
                patch("src.szu_netlogin.diagnostic_report.LOG_FILE", login_log),
                patch("src.szu_netlogin.diagnostic_report.MENUBAR_LOG_FILE", root / "menubar.log"),
                patch("src.szu_netlogin.diagnostic_report.LAUNCHAGENT_OUT_LOG", root / "out.log"),
                patch("src.szu_netlogin.diagnostic_report.LAUNCHAGENT_ERR_LOG", root / "err.log"),
                patch("src.szu_netlogin.diagnostic_report._load_config", return_value=({}, "")),
                patch("src.szu_netlogin.diagnostic_report.probe_network", return_value=status),
                patch(
                    "src.szu_netlogin.diagnostic_report.classify_network_environment",
                    return_value=environment,
                ),
                patch("src.szu_netlogin.diagnostic_report.describe_pause_state", return_value="未暂停"),
                patch("src.szu_netlogin.diagnostic_report._find_auto_login_launchagents", return_value=[]),
            ):
                report_path = diagnostic_report.create_diagnostic_report()

            text = report_path.read_text(encoding="utf-8")
            self.assertIn("网络环境：宿舍网络", text)
            self.assertIn("宿舍区网关是否可达：是", text)
            self.assertIn("user_password=***", text)
            self.assertIn("user_account=***", text)
            self.assertNotIn("SZU_CTC&CMCC", text)
            self.assertNotIn("172.24.182.13", text)
            if os.name != "nt":
                self.assertEqual(report_path.stat().st_mode & 0o777, 0o600)

    def test_windows_acl_failure_is_fail_closed(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            report_path = Path(temp_dir) / "report.txt"
            with (
                patch.object(diagnostic_report.os, "name", "nt"),
                patch.object(
                    diagnostic_report,
                    "_windows_current_user_sid",
                    return_value="S-1-5-21-1000",
                ),
                patch.object(
                    diagnostic_report.subprocess,
                    "run",
                    return_value=type("Result", (), {"returncode": 1})(),
                ),
            ):
                with self.assertRaisesRegex(OSError, "ACL"):
                    diagnostic_report._write_private_report(report_path, "synthetic report")

    def test_windows_acl_does_not_decode_localized_command_output(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            report_path = Path(temp_dir) / "report.txt"
            with (
                patch.object(diagnostic_report.os, "name", "nt"),
                patch.object(
                    diagnostic_report,
                    "_windows_current_user_sid",
                    return_value="S-1-5-21-1000",
                ),
                patch.object(
                    diagnostic_report.subprocess,
                    "run",
                    return_value=type("Result", (), {"returncode": 0})(),
                ) as run,
            ):
                diagnostic_report._write_private_report(report_path, "synthetic report")

            kwargs = run.call_args.kwargs
            self.assertIs(kwargs["stdout"], diagnostic_report.subprocess.DEVNULL)
            self.assertIs(kwargs["stderr"], diagnostic_report.subprocess.DEVNULL)
            self.assertNotIn("text", kwargs)
            self.assertNotIn("encoding", kwargs)
            self.assertIn("*S-1-5-21-1000:(R,W)", run.call_args.args[0])


if __name__ == "__main__":
    unittest.main()
