from __future__ import annotations

import os
import subprocess
import threading
import tkinter as tk
import unittest
from pathlib import Path
from queue import Queue
from tempfile import TemporaryDirectory
from unittest.mock import Mock, patch

from apps.windows_desktop.szu_windows_desktop import (
    AutoLoginBackoff,
    DEFAULT_CONFIG_TEMPLATE,
    DesktopStatusResult,
    SzuDormWindowsApp,
    get_windows_startup_link,
    hidden_popen_options,
    is_windows_startup_enabled,
    portal_session_label,
    run_frozen_control_action,
    run_frozen_self_test,
    set_windows_startup_enabled,
    should_start_auto_login,
)
from src.szu_netlogin.config import _parse_yaml, validate_config
from src.szu_netlogin.dorm_drcom_client import PortalSessionFact
from src.szu_netlogin.portal_detect import NetworkStatus


class WindowsStartupTests(unittest.TestCase):
    def test_startup_detection_and_removal_are_idempotent(self) -> None:
        with TemporaryDirectory() as temp_dir:
            startup_dir = Path(temp_dir)
            link = get_windows_startup_link(startup_dir)
            self.assertFalse(is_windows_startup_enabled(startup_dir))

            link.touch()
            self.assertTrue(is_windows_startup_enabled(startup_dir))
            self.assertFalse(set_windows_startup_enabled(False, startup_dir))
            self.assertFalse(link.exists())
            self.assertFalse(set_windows_startup_enabled(False, startup_dir))

    def test_startup_install_uses_hidden_powershell_and_verifies_link(self) -> None:
        with TemporaryDirectory() as temp_dir:
            startup_dir = Path(temp_dir) / "Startup"
            launcher = (Path("C:/Python/pythonw.exe"), '"C:/SZUNET/client.py"', Path("C:/SZUNET"))

            def fake_run(command, **kwargs):
                self.assertEqual(command[0], "powershell")
                self.assertIn("-NonInteractive", command)
                env = kwargs["env"]
                Path(env["SZU_STARTUP_LINK"]).touch()
                self.assertEqual(env["SZU_STARTUP_TARGET"], str(launcher[0]))
                self.assertEqual(env["SZU_STARTUP_ARGS"], launcher[1])
                return subprocess.CompletedProcess(command, 0, "", "")

            with patch(
                "apps.windows_desktop.szu_windows_desktop.run_subprocess_hidden",
                side_effect=fake_run,
            ) as run_hidden:
                self.assertTrue(set_windows_startup_enabled(True, startup_dir, launcher))

            run_hidden.assert_called_once()
            self.assertTrue(is_windows_startup_enabled(startup_dir))

    def test_startup_install_reports_powershell_failure(self) -> None:
        with TemporaryDirectory() as temp_dir:
            launcher = (Path("pythonw.exe"), '"client.py"', Path("."))
            failed = subprocess.CompletedProcess(["powershell"], 1, "", "access denied")
            with patch(
                "apps.windows_desktop.szu_windows_desktop.run_subprocess_hidden",
                return_value=failed,
            ):
                with self.assertRaisesRegex(RuntimeError, "access denied"):
                    set_windows_startup_enabled(True, Path(temp_dir), launcher)

    def test_non_windows_popen_options_are_empty(self) -> None:
        with patch("apps.windows_desktop.szu_windows_desktop.os.name", "posix"):
            self.assertEqual(hidden_popen_options(), {})

    def test_windows_popen_options_hide_child_console(self) -> None:
        startup_info = Mock(dwFlags=0, wShowWindow=None)
        with (
            patch("apps.windows_desktop.szu_windows_desktop.os.name", "nt"),
            patch(
                "apps.windows_desktop.szu_windows_desktop.subprocess.STARTUPINFO",
                return_value=startup_info,
                create=True,
            ),
            patch(
                "apps.windows_desktop.szu_windows_desktop.subprocess.STARTF_USESHOWWINDOW",
                1,
                create=True,
            ),
            patch(
                "apps.windows_desktop.szu_windows_desktop.subprocess.CREATE_NO_WINDOW",
                0x08000000,
                create=True,
            ),
        ):
            options = hidden_popen_options()

        self.assertEqual(options["creationflags"], 0x08000000)
        self.assertIs(options["startupinfo"], startup_info)
        self.assertEqual(startup_info.dwFlags, 1)
        self.assertEqual(startup_info.wShowWindow, 0)


class WindowsAppLifecycleTests(unittest.TestCase):
    def test_status_refresh_skips_default_internet_until_portal_online(self) -> None:
        app = SzuDormWindowsApp.__new__(SzuDormWindowsApp)
        app._closing = False
        app._messages = Queue()
        app._status_lock = threading.Lock()
        app._refresh_in_progress = True
        app.logger = Mock()
        app._load_config_for_status = Mock(
            return_value=(
                {
                    "user": {"username": "481505"},
                    "auth": {},
                    "network": {},
                },
                "",
            )
        )
        gateway = NetworkStatus(True, False, source_ip="172.24.182.13")
        environment = Mock(label="宿舍网络", auto_login_available=True)

        with (
            patch("apps.windows_desktop.szu_windows_desktop.is_paused", return_value=False),
            patch(
                "apps.windows_desktop.szu_windows_desktop.probe_gateway",
                return_value=gateway,
            ),
            patch(
                "apps.windows_desktop.szu_windows_desktop.classify_network_environment",
                return_value=environment,
            ),
            patch("apps.windows_desktop.szu_windows_desktop.DormDrcomClient") as client,
            patch("apps.windows_desktop.szu_windows_desktop.probe_internet") as internet,
        ):
            client.return_value.session_fact.return_value = PortalSessionFact(
                state="offline",
                account="481505",
                ip="172.24.182.13",
            )
            app._refresh_status_worker()

        internet.assert_not_called()
        kind, result = app._messages.get_nowait()
        self.assertEqual(kind, "status")
        self.assertEqual(result.portal_session_state, "offline")

    def test_frozen_control_action_captures_output_for_windowed_gui(self) -> None:
        def fake_main(args):
            print("门户状态：离线")
            return 0

        with patch("src.szu_netlogin.control.main", side_effect=fake_main):
            result = run_frozen_control_action(["status"])

        self.assertEqual(result.returncode, 0)
        self.assertIn("门户状态：离线", result.stdout)

    def test_frozen_self_test_checks_embedded_config_without_network(self) -> None:
        self.assertEqual(run_frozen_self_test(), 0)

    def test_auto_login_requires_confirmed_portal_offline(self) -> None:
        offline = DesktopStatusResult(
            False,
            NetworkStatus(True, True, source_ip="172.24.182.13"),
            auto_login_available=True,
            portal_session_state="offline",
        )
        unknown = DesktopStatusResult(
            False,
            NetworkStatus(True, False, source_ip="172.24.182.13"),
            auto_login_available=True,
            portal_session_state="unknown",
        )

        self.assertTrue(should_start_auto_login(False, offline))
        self.assertFalse(should_start_auto_login(False, unknown))
        self.assertFalse(should_start_auto_login(True, offline))
        self.assertEqual(portal_session_label(offline), "已确认离线")

    def test_offline_transition_can_open_one_immediate_attempt(self) -> None:
        now = [100.0]
        schedule = AutoLoginBackoff((120, 300), 60, clock=lambda: now[0])
        self.assertFalse(schedule.consume_if_due())

        schedule.allow_immediate_attempt()

        self.assertTrue(schedule.consume_if_due())
        self.assertFalse(schedule.consume_if_due())

    @unittest.skipUnless(os.environ.get("SZU_RUN_TK_SMOKE") == "1", "需要真实 Tk 桌面会话")
    def test_ui_builds_with_two_tabs_and_dynamic_startup_button(self) -> None:
        root = tk.Tk()
        root.withdraw()
        try:
            app = SzuDormWindowsApp.__new__(SzuDormWindowsApp)
            app.root = root
            app._status_vars = {}
            app._command_buttons = []

            app._build_ui()
            root.update_idletasks()

            self.assertEqual(len(app.notebook.tabs()), 2)
            self.assertIn(app.startup_button.cget("text"), ("安装开机自启", "卸载开机自启"))
            self.assertEqual(app.open_diagnostics_button.cget("text"), "打开诊断工具")
        finally:
            root.destroy()

    def test_stale_status_result_is_ignored_after_probe_is_disabled(self) -> None:
        app = SzuDormWindowsApp.__new__(SzuDormWindowsApp)
        app._closing = False
        app._network_probe_enabled = False
        app._messages = Queue()
        app._messages.put(
            (
                "status",
                DesktopStatusResult(False, NetworkStatus(True, True), network_probe_enabled=True),
            )
        )
        app.logger = Mock()
        app.root = Mock()
        app.root.after.return_value = "drain-id"
        app._apply_status_result = Mock()

        app._drain_messages()

        app._apply_status_result.assert_not_called()
        self.assertEqual(app._drain_after_id, "drain-id")

    def test_background_auto_login_does_not_disable_manual_buttons(self) -> None:
        app = SzuDormWindowsApp.__new__(SzuDormWindowsApp)
        app._command_lock = threading.Lock()
        app._command_in_progress = False
        app._set_command_buttons_enabled = Mock()
        app._append_output = Mock()

        self.assertTrue(app._begin_command("后台自动检查", show_dialog=False))

        app._set_command_buttons_enabled.assert_not_called()

    def test_refresh_error_schedules_retry(self) -> None:
        app = SzuDormWindowsApp.__new__(SzuDormWindowsApp)
        app._closing = False
        app._messages = Queue()
        app._messages.put(("error", ("刷新状态失败", RuntimeError("offline"), "trace")))
        app.logger = Mock()
        app.root = Mock()
        app.root.after.return_value = "drain-id"
        app.header_state_var = Mock()
        app._append_output = Mock()
        app._schedule_next_status_refresh = Mock()

        app._drain_messages()

        app._schedule_next_status_refresh.assert_called_once_with()
        app.header_state_var.set.assert_called_once_with("状态刷新失败，将自动重试")

    def test_close_cancels_process_callbacks_and_window(self) -> None:
        app = SzuDormWindowsApp.__new__(SzuDormWindowsApp)
        app._closing = False
        app._network_probe_enabled = True
        app._status_after_id = "status"
        app._drain_after_id = "drain"
        app._watchdog_after_id = "watchdog"
        app._cancel_active_control_process = Mock()
        app.root = Mock()

        app._close()

        self.assertTrue(app._closing)
        self.assertFalse(app._network_probe_enabled)
        app._cancel_active_control_process.assert_called_once_with()
        self.assertEqual(
            [call.args[0] for call in app.root.after_cancel.call_args_list],
            ["status", "drain", "watchdog"],
        )
        app.root.destroy.assert_called_once_with()

    def test_cancel_active_process_terminates_running_process(self) -> None:
        app = SzuDormWindowsApp.__new__(SzuDormWindowsApp)
        app.logger = Mock()
        app._active_process_lock = threading.Lock()
        app._active_process = Mock()
        app._active_process.poll.return_value = None
        app._terminate_process = Mock()

        app._cancel_active_control_process()

        app._terminate_process.assert_called_once_with(app._active_process)


class WindowsFallbackConfigTests(unittest.TestCase):
    def test_embedded_config_matches_current_schema(self) -> None:
        config = _parse_yaml(DEFAULT_CONFIG_TEMPLATE)
        config["user"]["username"] = "12345678"

        validate_config(config)

        self.assertEqual(config["network"]["campus_source_networks"], ["172.16.0.0/12"])
        self.assertNotIn("campus_source_cidrs", config["network"])


if __name__ == "__main__":
    unittest.main()
