from __future__ import annotations

import unittest
import threading
from pathlib import Path
from queue import Queue
from tempfile import TemporaryDirectory
from unittest.mock import Mock, patch

from src.szu_netlogin.menubar_app import (
    AutoLoginBackoff,
    PeriodicDeadline,
    SzuDormMenubarApp,
    StatusRefreshResult,
    auto_login_state_label,
    extract_login_reason,
    extract_logout_title,
    extract_report_path,
    format_interval,
    is_launchagent_installed,
    should_start_auto_login,
)
from src.szu_netlogin.portal_detect import NetworkStatus


class FakeTimer:
    def __init__(self) -> None:
        self.started = False
        self.stopped = False
        self._alive = True

    def is_alive(self) -> bool:
        return self._alive

    def start(self) -> None:
        self.started = True
        self._alive = True

    def stop(self) -> None:
        self.stopped = True
        self._alive = False


class PeriodicDeadlineTests(unittest.TestCase):
    def test_becomes_due_immediately_after_long_sleep_gap(self) -> None:
        now = [100.0]
        schedule = PeriodicDeadline(120, 5, clock=lambda: now[0])

        self.assertFalse(schedule.consume_if_due())
        now[0] = 105.0
        self.assertTrue(schedule.consume_if_due())

        now[0] = 10_000.0
        self.assertTrue(schedule.consume_if_due())
        self.assertFalse(schedule.consume_if_due())


class AutoLoginGateTests(unittest.TestCase):
    def test_gateway_unreachable_stops_auto_login(self) -> None:
        result = StatusRefreshResult(False, NetworkStatus(False, False))

        self.assertFalse(should_start_auto_login(False, result))
        self.assertEqual(auto_login_state_label(False, result), "非宿舍网络，自动登录停用")

    def test_gateway_reachable_allows_auto_login_check(self) -> None:
        result = StatusRefreshResult(False, NetworkStatus(True, False))

        self.assertTrue(should_start_auto_login(False, result))
        self.assertEqual(auto_login_state_label(False, result), "运行中")

    def test_online_gateway_does_not_start_auto_login_check(self) -> None:
        result = StatusRefreshResult(False, NetworkStatus(True, True))

        self.assertFalse(should_start_auto_login(False, result))

    def test_unknown_status_waits_for_refresh_before_auto_login(self) -> None:
        self.assertFalse(should_start_auto_login(False, None))

    def test_config_error_stops_auto_login_check(self) -> None:
        result = StatusRefreshResult(False, NetworkStatus(False, False), "config missing")

        self.assertFalse(should_start_auto_login(False, result))

    def test_paused_still_stops_auto_login(self) -> None:
        result = StatusRefreshResult(True, NetworkStatus(True, False))

        self.assertFalse(should_start_auto_login(True, result))
        self.assertEqual(auto_login_state_label(True, result), "已暂停")

    def test_disabled_network_probe_stops_auto_login(self) -> None:
        result = StatusRefreshResult(
            False,
            NetworkStatus(True, False),
            network_probe_enabled=False,
        )

        self.assertFalse(should_start_auto_login(False, result))
        self.assertEqual(auto_login_state_label(False, result), "联网状态探测已关闭")

    def test_environment_gate_stops_auto_login(self) -> None:
        result = StatusRefreshResult(
            False,
            NetworkStatus(True, False),
            environment_label="非宿舍网络",
            auto_login_available=False,
        )

        self.assertFalse(should_start_auto_login(False, result))
        self.assertEqual(auto_login_state_label(False, result), "非宿舍网络，自动登录停用")

    def test_auto_login_worker_skips_control_process_when_paused(self) -> None:
        app = SzuDormMenubarApp.__new__(SzuDormMenubarApp)
        app.logger = Mock()
        app._background_results = Queue()
        app._worker_lock = threading.Lock()
        app._auto_login_in_progress = True
        app._run_control_process = Mock()

        with patch("src.szu_netlogin.menubar_app.is_paused", return_value=True):
            app._auto_login_worker()

        app._run_control_process.assert_not_called()
        self.assertFalse(app._auto_login_in_progress)
        self.assertEqual(app._background_results.get_nowait(), ("auto_login", 0))
        app.logger.info.assert_any_call("自动登录检查启动前检测到已暂停，跳过本轮。")

    def test_watchdog_waits_for_status_before_consuming_auto_login_deadline(self) -> None:
        app = SzuDormMenubarApp.__new__(SzuDormMenubarApp)
        app.logger = Mock()
        app.timer = FakeTimer()
        app._network_probe_enabled = True
        app._last_status_result = None
        app._auto_login_schedule = Mock()
        app._drain_background_results = Mock()

        with patch("src.szu_netlogin.menubar_app.is_main_thread", return_value=True):
            app._watchdog_tick(None)

        app._auto_login_schedule.consume_if_due.assert_not_called()


class NetworkProbeToggleTests(unittest.TestCase):
    def test_cancel_active_process_terminates_running_control_command(self) -> None:
        app = SzuDormMenubarApp.__new__(SzuDormMenubarApp)
        app.logger = Mock()
        app._active_process_lock = threading.Lock()
        app._active_process = Mock()
        app._active_process.poll.return_value = None
        app._terminate_process = Mock()

        app._cancel_active_control_process()

        app._terminate_process.assert_called_once_with(app._active_process)

    def test_refresh_status_worker_does_not_probe_when_disabled(self) -> None:
        app = SzuDormMenubarApp.__new__(SzuDormMenubarApp)
        app.logger = Mock()
        app._background_results = Queue()
        app._worker_lock = threading.Lock()
        app._refresh_in_progress = True
        app._network_probe_enabled = False

        with (
            patch("src.szu_netlogin.menubar_app.is_paused", return_value=True),
            patch("src.szu_netlogin.menubar_app.load_config") as load_config,
            patch("src.szu_netlogin.menubar_app.probe_network") as probe_network,
        ):
            app._refresh_status_worker()

        load_config.assert_not_called()
        probe_network.assert_not_called()
        self.assertFalse(app._refresh_in_progress)
        kind, payload = app._background_results.get_nowait()
        self.assertEqual(kind, "status")
        self.assertFalse(payload.network_probe_enabled)
        self.assertTrue(payload.paused)

    def test_quit_app_disables_network_probe_and_stops_timers(self) -> None:
        app = SzuDormMenubarApp.__new__(SzuDormMenubarApp)
        app.logger = Mock()
        app._network_probe_enabled = True
        app.timer = FakeTimer()
        app.watchdog_timer = FakeTimer()
        app.network_probe_item = Mock(title="")

        with patch("src.szu_netlogin.menubar_app.rumps") as rumps:
            app.quit_app(None)

        self.assertFalse(app._network_probe_enabled)
        self.assertTrue(app.timer.stopped)
        self.assertTrue(app.watchdog_timer.stopped)
        self.assertEqual(app.network_probe_item.title, "联网状态探测")
        self.assertEqual(app.network_probe_item.state, 0)
        rumps.quit_application.assert_called_once_with()


class MenubarMenuTests(unittest.TestCase):
    def test_login_prompts_for_missing_password_then_starts_login(self) -> None:
        app = SzuDormMenubarApp.__new__(SzuDormMenubarApp)
        app.logger = Mock()
        app.login_item = Mock(title="立即登录")
        app._prompt_and_save_password = Mock(return_value=True)
        app._set_login_busy = Mock()
        app._run_menu_action = Mock()
        config = {"user": {"username": "481505"}, "security": {"password_source": "keychain"}}

        with (
            patch("src.szu_netlogin.menubar_app.load_config", return_value=config),
            patch("src.szu_netlogin.menubar_app.has_password", return_value=False),
        ):
            app.login_now(None)

        app._prompt_and_save_password.assert_called_once_with(config, "481505")
        app._set_login_busy.assert_called_once_with(True)
        app._run_menu_action.assert_called_once()

    def test_login_cancelled_password_prompt_does_not_start_command(self) -> None:
        app = SzuDormMenubarApp.__new__(SzuDormMenubarApp)
        app.logger = Mock()
        app.login_item = Mock(title="立即登录")
        app._prompt_and_save_password = Mock(return_value=False)
        app._set_login_busy = Mock()
        app._run_menu_action = Mock()
        config = {"user": {"username": "481505"}, "security": {"password_source": "keychain"}}

        with (
            patch("src.szu_netlogin.menubar_app.load_config", return_value=config),
            patch("src.szu_netlogin.menubar_app.has_password", return_value=False),
        ):
            app.login_now(None)

        app._run_menu_action.assert_not_called()
        app._set_login_busy.assert_not_called()

    def test_diagnostics_are_grouped_and_launchagent_uses_one_dynamic_item(self) -> None:
        class FakeMenuItem:
            def __init__(self, title: str, callback=None) -> None:
                self.title = title
                self.callback = callback
                self.children = []
                self.state = 0

            def add(self, item) -> None:
                self.children.append(item)

        class FakeTimer:
            def __init__(self, callback, interval) -> None:
                self.callback = callback
                self.interval = interval

            def start(self) -> None:
                return None

            def is_alive(self) -> bool:
                return True

        with (
            patch("src.szu_netlogin.menubar_app.rumps.MenuItem", side_effect=FakeMenuItem),
            patch("src.szu_netlogin.menubar_app.rumps.Timer", side_effect=FakeTimer),
            patch("src.szu_netlogin.menubar_app.rumps.App.__init__", return_value=None) as app_init,
            patch("src.szu_netlogin.menubar_app.get_menubar_logger", return_value=Mock()),
            patch.object(SzuDormMenubarApp, "_warn_if_config_missing"),
            patch.object(SzuDormMenubarApp, "_warn_if_optional_dependencies_missing"),
            patch.object(SzuDormMenubarApp, "refresh_status"),
            patch("src.szu_netlogin.menubar_app.is_launchagent_installed", return_value=False),
        ):
            SzuDormMenubarApp()

        menu = app_init.call_args.kwargs["menu"]
        titles = [item.title if item is not None else None for item in menu]
        self.assertIn("诊断与维护", titles)
        self.assertIn("开机自动运行", titles)
        self.assertIn("账号与凭据", titles)
        self.assertEqual(titles.count(None), 3)
        diagnostics = next(
            item for item in menu if item is not None and item.title == "诊断与维护"
        )
        self.assertEqual(
            [item.title for item in diagnostics.children],
            ["生成诊断报告", "打开配置文件", "打开日志", "重置暂停状态", "检查依赖"],
        )
        for child in diagnostics.children:
            self.assertNotIn(child, menu)
        account = next(item for item in menu if item is not None and item.title == "账号与凭据")
        self.assertEqual([item.title for item in account.children], ["修改账号", "修改密码"])
        self.assertEqual(next(item for item in menu if item is not None and item.title == "自动登录").state, 1)
        self.assertEqual(next(item for item in menu if item is not None and item.title == "联网状态探测").state, 1)
        self.assertEqual(next(item for item in menu if item is not None and item.title == "开机自动运行").state, 0)
        self.assertNotIn("退出账号（暂停 30 分钟）", titles)
        self.assertNotIn("退出账号（下次开机恢复）", titles)
        self.assertNotIn("写入 SZU_NETLOGIN_HOME", titles)

    def test_launchagent_installation_detection_supports_current_and_legacy_labels(self) -> None:
        with TemporaryDirectory() as temp_dir:
            launchagents_dir = Path(temp_dir)
            self.assertFalse(is_launchagent_installed(launchagents_dir))

            for label in (
                "com.szu-netlogin.dorm-drcom",
                "com.fonsi.szu-dorm-drcom",
                "com.szu.autologin",
            ):
                plist_path = launchagents_dir / f"{label}.plist"
                plist_path.touch()
                self.assertTrue(is_launchagent_installed(launchagents_dir))
                plist_path.unlink()

    def test_launchagent_toggle_selects_the_opposite_of_current_state(self) -> None:
        for installed in (False, True):
            with self.subTest(installed=installed):
                app = SzuDormMenubarApp.__new__(SzuDormMenubarApp)
                app.logger = Mock()
                app._change_launchagent_installation = Mock(return_value=not installed)
                app._finish_launchagent_change = Mock()

                def run_now(action, completion) -> None:
                    completion(action())

                app._run_menu_action = Mock(side_effect=run_now)
                with patch(
                    "src.szu_netlogin.menubar_app.is_launchagent_installed",
                    return_value=installed,
                ):
                    app.toggle_launchagent(None)

                app._change_launchagent_installation.assert_called_once_with(not installed)
                app._finish_launchagent_change.assert_called_once_with(not installed)


class AutoLoginBackoffTests(unittest.TestCase):
    def test_failure_extends_interval_and_success_resets(self) -> None:
        now = [100.0]
        schedule = AutoLoginBackoff((120, 300, 600, 900), 5, clock=lambda: now[0])

        self.assertFalse(schedule.consume_if_due())
        now[0] = 105.0
        self.assertTrue(schedule.consume_if_due())
        self.assertEqual(schedule.current_interval_seconds, 120)

        schedule.record_failure()
        self.assertEqual(schedule.current_interval_seconds, 300)

        schedule.record_failure()
        self.assertEqual(schedule.current_interval_seconds, 600)

        schedule.record_failure()
        self.assertEqual(schedule.current_interval_seconds, 900)

        schedule.record_success()
        self.assertEqual(schedule.current_interval_seconds, 120)


class OutputParsingTests(unittest.TestCase):
    def test_extract_login_reason(self) -> None:
        self.assertEqual(extract_login_reason("登录结果：失败。原因：密码错误。"), "密码错误")

    def test_extract_logout_title(self) -> None:
        self.assertEqual(
            extract_logout_title("退出结果：接口返回成功但仍可上网。\n", 1),
            "退出结果：接口返回成功但仍可上网",
        )

    def test_extract_report_path(self) -> None:
        self.assertEqual(
            extract_report_path("诊断报告已生成：/tmp/report.txt\n"),
            "/tmp/report.txt",
        )

    def test_format_interval(self) -> None:
        self.assertEqual(format_interval(300), "5 分钟")


if __name__ == "__main__":
    unittest.main()
