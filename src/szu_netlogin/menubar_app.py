"""macOS menu bar client for the SZU dorm netlogin control layer."""

from __future__ import annotations

import logging
import os
import subprocess
import sys
import threading
import time
import traceback
from importlib.util import find_spec
from dataclasses import dataclass
from datetime import datetime
from logging.handlers import QueueHandler, QueueListener, RotatingFileHandler
from pathlib import Path
from queue import Empty, Queue
from typing import Any, Callable

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
    from src.szu_netlogin.config import (
        ConfigError,
        DEFAULT_CONFIG_PATH,
        PROJECT_HOME_ENV,
        PROJECT_ROOT,
        load_config,
    )
    from src.szu_netlogin.password_store import describe_password_source, set_password
    from src.szu_netlogin.portal_detect import (
        NetworkStatus,
        classify_network_environment,
        probe_network,
    )
    from src.szu_netlogin.state import is_paused
else:
    from .config import (
        ConfigError,
        DEFAULT_CONFIG_PATH,
        PROJECT_HOME_ENV,
        PROJECT_ROOT,
        load_config,
    )
    from .password_store import describe_password_source, set_password
    from .portal_detect import NetworkStatus, classify_network_environment, probe_network
    from .state import is_paused

try:
    import rumps
except Exception as exc:  # pragma: no cover - exercised on machines missing GUI deps
    rumps = None  # type: ignore[assignment]
    RUMPS_IMPORT_ERROR: Exception | None = exc
else:
    RUMPS_IMPORT_ERROR = None

try:
    from Foundation import NSThread
    from PyObjCTools import AppHelper
except Exception:  # pragma: no cover - exercised on machines missing GUI deps
    NSThread = None  # type: ignore[assignment]
    AppHelper = None  # type: ignore[assignment]


MENUBAR_LOG_FILE = PROJECT_ROOT / "logs" / "menubar.log"
MENUBAR_ERR_LOG_FILE = Path.home() / "Library" / "Logs" / "szu-netlogin" / "menubar-err.log"
CONTROL_MODULE = "src.szu_netlogin.control"
CONTROL_DISPATCH_ARG = "--szu-netlogin-control"
USERNAME_PLACEHOLDER = "你的校园卡号，不要写密码"
RumpsAppBase = rumps.App if rumps is not None else object
MENUBAR_LOG_LISTENERS: list[QueueListener] = []
STATUS_REFRESH_SECONDS = 30
WATCHDOG_INTERVAL_SECONDS = 5
AUTO_LOGIN_INITIAL_DELAY_SECONDS = 5
AUTO_LOGIN_BACKOFF_SECONDS = (120, 300, 600, 900)
MENUBAR_LOG_MAX_BYTES = 1_000_000
MENUBAR_LOG_BACKUP_COUNT = 5


@dataclass(frozen=True)
class StatusRefreshResult:
    paused: bool
    network_status: NetworkStatus
    config_error: str = ""
    network_probe_enabled: bool = True
    environment_label: str = ""
    auto_login_available: bool = True


class PeriodicDeadline:
    """Wall-clock schedule that becomes due immediately after a long sleep gap."""

    def __init__(
        self,
        interval_seconds: float,
        initial_delay_seconds: float,
        clock: Callable[[], float] = time.time,
    ) -> None:
        self.interval_seconds = interval_seconds
        self._clock = clock
        self._deadline = clock() + initial_delay_seconds

    def consume_if_due(self) -> bool:
        now = self._clock()
        if now < self._deadline:
            return False
        self._deadline = now + self.interval_seconds
        return True


class AutoLoginBackoff:
    """Auto-login schedule that backs off after consecutive failed attempts."""

    def __init__(
        self,
        intervals_seconds: tuple[int, ...],
        initial_delay_seconds: float,
        clock: Callable[[], float] = time.time,
    ) -> None:
        self._intervals = intervals_seconds
        self._clock = clock
        self._failure_index = 0
        self._deadline = clock() + initial_delay_seconds

    @property
    def current_interval_seconds(self) -> int:
        return self._intervals[self._failure_index]

    def consume_if_due(self) -> bool:
        now = self._clock()
        if now < self._deadline:
            return False
        self._deadline = now + self.current_interval_seconds
        return True

    def record_success(self) -> None:
        self._failure_index = 0
        self._deadline = self._clock() + self.current_interval_seconds

    def record_failure(self) -> None:
        self._failure_index = min(self._failure_index + 1, len(self._intervals) - 1)
        self._deadline = self._clock() + self.current_interval_seconds


def get_menubar_logger() -> logging.Logger:
    MENUBAR_LOG_FILE.parent.mkdir(parents=True, exist_ok=True)
    MENUBAR_ERR_LOG_FILE.parent.mkdir(parents=True, exist_ok=True)

    logger = logging.getLogger("szu_netlogin_menubar")
    logger.setLevel(logging.INFO)
    logger.propagate = False

    if any(isinstance(handler, QueueHandler) for handler in logger.handlers):
        return logger

    formatter = logging.Formatter("%(asctime)s [%(levelname)s] %(message)s")
    handlers: list[logging.Handler] = []

    handler = SafeRotatingFileHandler(
        MENUBAR_LOG_FILE,
        maxBytes=MENUBAR_LOG_MAX_BYTES,
        backupCount=MENUBAR_LOG_BACKUP_COUNT,
        encoding="utf-8",
        delay=True,
    )
    handler.setFormatter(formatter)
    handlers.append(handler)

    error_handler = SafeRotatingFileHandler(
        MENUBAR_ERR_LOG_FILE,
        maxBytes=MENUBAR_LOG_MAX_BYTES,
        backupCount=MENUBAR_LOG_BACKUP_COUNT,
        encoding="utf-8",
        delay=True,
    )
    error_handler.setLevel(logging.ERROR)
    error_handler.setFormatter(formatter)
    handlers.append(error_handler)

    log_queue: Queue[logging.LogRecord] = Queue()
    logger.addHandler(QueueHandler(log_queue))
    listener = QueueListener(log_queue, *handlers, respect_handler_level=True)
    listener.start()
    MENUBAR_LOG_LISTENERS.append(listener)

    return logger


class SafeRotatingFileHandler(RotatingFileHandler):
    def emit(self, record: logging.LogRecord) -> None:
        try:
            super().emit(record)
        except OSError:
            pass


def install_exception_logging(logger: logging.Logger) -> None:
    def log_unhandled_exception(
        exc_type: type[BaseException],
        exc_value: BaseException,
        exc_traceback: Any,
    ) -> None:
        logger.error(
            "状态栏客户端未处理异常：%s",
            exc_value,
            exc_info=(exc_type, exc_value, exc_traceback),
        )

    sys.excepthook = log_unhandled_exception


class SzuDormMenubarApp(RumpsAppBase):
    def __init__(self) -> None:
        self.logger = get_menubar_logger()
        self._refresh_in_progress = False
        self._auto_login_in_progress = False
        self._network_probe_enabled = True
        self._last_status_result: StatusRefreshResult | None = None
        self._worker_lock = threading.Lock()
        self._background_results: Queue[tuple[str, Any]] = Queue()
        self._auto_login_schedule = AutoLoginBackoff(
            AUTO_LOGIN_BACKOFF_SECONDS,
            AUTO_LOGIN_INITIAL_DELAY_SECONDS,
        )
        self._warn_if_config_missing()
        self._warn_if_optional_dependencies_missing()

        self.status_item = rumps.MenuItem("状态：正在检查...")
        self.login_item = rumps.MenuItem("立即登录", callback=self.login_now)
        self.logout_item = rumps.MenuItem("退出账号（手动恢复）", callback=self.logout_now)
        self.logout_hint_item = rumps.MenuItem("退出账号会先暂停自动登录，避免马上重新登录")
        self.pause_item = rumps.MenuItem("暂停自动登录", callback=self.toggle_pause)
        self.network_probe_item = rumps.MenuItem(
            "关闭联网状态探测",
            callback=self.toggle_network_probe,
        )
        self.username_item = rumps.MenuItem("修改账号", callback=self.change_username)
        self.password_item = rumps.MenuItem("修改密码", callback=self.change_password)
        self.diagnostic_report_item = rumps.MenuItem(
            "生成诊断报告",
            callback=self.generate_diagnostic_report,
        )
        self.open_config_item = rumps.MenuItem("打开配置文件", callback=self.open_config)
        self.open_log_item = rumps.MenuItem("打开日志", callback=self.open_log)
        self.reset_pause_item = rumps.MenuItem("重置暂停状态", callback=self.reset_pause)
        self.check_dependencies_item = rumps.MenuItem("检查依赖", callback=self.check_dependencies)
        self.install_item = rumps.MenuItem("安装开机自启", callback=self.install_launchagent)
        self.uninstall_item = rumps.MenuItem("卸载开机自启", callback=self.uninstall_launchagent)
        self.reinstall_item = rumps.MenuItem("重装开机自启", callback=self.reinstall_launchagent)
        self.quit_item = rumps.MenuItem("退出状态栏客户端", callback=self.quit_app)

        super().__init__(
            name="SZU Dorm",
            title="SZU Dorm",
            menu=[
                self.status_item,
                self.login_item,
                self.logout_item,
                self.logout_hint_item,
                self.pause_item,
                self.network_probe_item,
                self.username_item,
                self.password_item,
                self.diagnostic_report_item,
                self.open_config_item,
                self.open_log_item,
                self.reset_pause_item,
                self.check_dependencies_item,
                self.install_item,
                self.uninstall_item,
                self.reinstall_item,
                self.quit_item,
            ],
            quit_button=None,
        )

        self.timer = rumps.Timer(self.refresh_status, STATUS_REFRESH_SECONDS)
        self.timer.start()
        self.watchdog_timer = rumps.Timer(self._watchdog_tick, WATCHDOG_INTERVAL_SECONDS)
        self.watchdog_timer.start()
        self.refresh_status(None)

    def _warn_if_config_missing(self) -> None:
        if DEFAULT_CONFIG_PATH.exists():
            return

        message = (
            f"找不到配置文件：{DEFAULT_CONFIG_PATH}\n"
            f"当前项目目录：{PROJECT_ROOT}\n"
            f"如项目不在默认位置，请先设置环境变量 {PROJECT_HOME_ENV}。"
        )
        self.logger.error("找不到 config.yaml：%s", DEFAULT_CONFIG_PATH)
        rumps.alert("SZU Dorm 配置缺失", message)

    def _warn_if_optional_dependencies_missing(self) -> None:
        missing_messages: list[str] = []

        if find_spec("keyring") is None:
            missing_messages.append("keyring：未安装")

        if not missing_messages:
            return

        message = "以下依赖缺失，部分功能可能不可用：\n" + "\n".join(missing_messages)
        self.logger.error("依赖缺失：%s", "；".join(missing_messages))
        rumps.alert("SZU Dorm 依赖缺失", message)

    def refresh_status(self, _sender: Any) -> None:
        with self._worker_lock:
            if self._refresh_in_progress:
                return
            self._refresh_in_progress = True

        threading.Thread(
            target=self._refresh_status_worker,
            name="szu-status-refresh",
            daemon=True,
        ).start()

    def _refresh_status_worker(self) -> None:
        try:
            paused = is_paused()
            if not self._network_probe_enabled:
                self._background_results.put(
                    (
                        "status",
                        StatusRefreshResult(
                            paused,
                            NetworkStatus(False, False),
                            network_probe_enabled=False,
                        ),
                    )
                )
                return

            config, config_error = self._load_config_for_status()
            network_status = probe_network(config) if config else NetworkStatus(False, False)
            environment = classify_network_environment(config, network_status)
            self._background_results.put(
                (
                    "status",
                    StatusRefreshResult(
                        paused,
                        network_status,
                        config_error,
                        environment_label=environment.label,
                        auto_login_available=environment.auto_login_available,
                    ),
                )
            )
        except Exception as exc:
            self._background_results.put(
                ("background_error", ("刷新状态失败", exc, traceback.format_exc()))
            )
        finally:
            with self._worker_lock:
                self._refresh_in_progress = False

    def _apply_status_result(self, result: StatusRefreshResult) -> None:
        self._last_status_result = result
        run_label = auto_login_state_label(result.paused, result)
        self._update_network_probe_item_title()
        self.pause_item.title = "恢复自动登录" if result.paused else "暂停自动登录"

        if not result.network_probe_enabled:
            self.status_item.title = f"状态：{run_label}"
            self.logger.info(
                "状态刷新：联网状态探测已关闭，时间=%s",
                datetime.now().strftime("%H:%M:%S"),
            )
            return

        campus_label = (
            "校园网出口已连通" if result.network_status.campus_internet_ok else "校园网出口未连通"
        )
        gateway_label = "网关可达" if result.network_status.gateway_reachable else "网关不可达"
        environment_label = result.environment_label or "网络环境未知"
        self.status_item.title = (
            f"状态：{run_label}｜{environment_label}｜{campus_label}｜{gateway_label}"
        )
        message = (
            f"状态刷新：{run_label}，{environment_label}，{campus_label}，{gateway_label}，"
            f"source_ip={result.network_status.source_ip or '-'}，"
            f"时间={datetime.now().strftime('%H:%M:%S')}"
        )
        if result.config_error:
            message += f"，配置提示={result.config_error}"
        self.logger.info(message)
        if result.network_status.campus_internet_ok:
            self._auto_login_schedule.record_success()

    def _watchdog_tick(self, _sender: Any) -> None:
        if not is_main_thread():
            run_on_main_thread(self._watchdog_tick, _sender)
            return

        self._drain_background_results()

        if self._network_probe_enabled and not self.timer.is_alive():
            self.logger.warning("状态刷新定时器已停止，正在重新启动。")
            self.timer.start()

        if not self._network_probe_enabled:
            return

        if self._last_status_result is None:
            return

        if not self._auto_login_schedule.consume_if_due():
            return

        if should_start_auto_login(is_paused(), self._last_status_result):
            self._start_auto_login_check()
            return

        if is_non_campus_status(self._last_status_result):
            label = self._last_status_result.environment_label or "非宿舍网络"
            self.logger.info("当前不是宿舍区校园网：%s，本轮自动登录已停止。", label)

    def _start_auto_login_check(self) -> None:
        with self._worker_lock:
            if self._auto_login_in_progress:
                return
            self._auto_login_in_progress = True

        threading.Thread(
            target=self._auto_login_worker,
            name="szu-auto-login",
            daemon=True,
        ).start()

    def _auto_login_worker(self) -> None:
        try:
            if is_paused():
                self.logger.info("自动登录检查启动前检测到已暂停，跳过本轮。")
                self._background_results.put(("auto_login", 0))
                return

            result = self._run_control_process(["check-and-login"], timeout=80)
            self._background_results.put(("auto_login", result))
        except Exception as exc:
            self._background_results.put(
                ("background_error", ("自动登录检查失败", exc, traceback.format_exc()))
            )
        finally:
            with self._worker_lock:
                self._auto_login_in_progress = False

    def _drain_background_results(self) -> None:
        if not is_main_thread():
            run_on_main_thread(self._drain_background_results)
            return

        while True:
            try:
                kind, payload = self._background_results.get_nowait()
            except Empty:
                return

            if kind == "status":
                if not self._network_probe_enabled and payload.network_probe_enabled:
                    self.logger.info("忽略已关闭探测后的旧状态刷新结果。")
                    continue
                self._apply_status_result(payload)
                continue

            if kind == "auto_login":
                returncode = payload.returncode if hasattr(payload, "returncode") else int(payload)
                if returncode == 0:
                    self._auto_login_schedule.record_success()
                    self.logger.info("后台自动登录检查完成。")
                else:
                    self._auto_login_schedule.record_failure()
                    output = short_output(payload) if hasattr(payload, "returncode") else ""
                    reason = extract_login_reason(output)
                    interval = self._auto_login_schedule.current_interval_seconds
                    self.logger.warning(
                        "后台自动登录检查返回失败：returncode=%s reason=%s next_interval=%s",
                        returncode,
                        reason or "-",
                        interval,
                    )
                    rumps.notification(
                        "SZU Dorm",
                        f"自动登录失败：{reason or '原因未知'}",
                        f"下次自动检查约 {format_interval(interval)} 后重试。",
                    )
                self.refresh_status(None)
                continue

            title, exc, formatted_traceback = payload
            message = str(exc) or type(exc).__name__
            self.logger.error("%s：%s\n%s", title, message, formatted_traceback)

    def login_now(self, _sender: Any) -> None:
        try:
            self.logger.info("用户点击：立即登录")
            result = self._run_control_process(["login-now"], timeout=60)
            output = f"{result.stdout}\n{result.stderr}"

            if result.returncode == 0:
                self._auto_login_schedule.record_success()
                title = "登录成功"
                detail = "自动重试退避已重置。"
            elif "不确定" in output:
                title = f"结果不确定：{extract_login_reason(output) or '服务器响应不确定'}"
                detail = "详情可查看日志。"
            else:
                title = f"登录失败：{extract_login_reason(output) or '原因未知'}"
                detail = "详情可查看日志。"

            self.logger.info("立即登录完成：returncode=%s result=%s", result.returncode, title)
            rumps.notification("SZU Dorm", title, detail)
            if result.returncode != 0:
                rumps.alert(title, short_output(result) or "详情可查看日志。")
            self.refresh_status(None)
        except Exception as exc:
            self._handle_exception("立即登录失败", exc)

    def logout_now(self, _sender: Any) -> None:
        try:
            self.logger.info("用户点击：退出校园网账号")
            self._logout_with_pause("manual")
        except Exception as exc:
            self._handle_exception("退出校园网账号失败", exc)

    def _logout_with_pause(self, pause_for: str) -> None:
        result = self._run_control_process(["logout", "--pause-for", pause_for], timeout=35)
        output = short_output(result)
        title = extract_logout_title(output, result.returncode)

        self.logger.info("退出完成：returncode=%s result=%s", result.returncode, title)
        rumps.notification("SZU Dorm", title, extract_logout_detail(output))
        if result.returncode != 0:
            rumps.alert(title, output or "详情可查看日志。")
        self.refresh_status(None)

    def toggle_pause(self, _sender: Any) -> None:
        try:
            command = "resume" if is_paused() else "pause"
            self.logger.info("用户点击：%s", "恢复自动登录" if command == "resume" else "暂停自动登录")
            self._run_control([command], timeout=20)
            if command == "resume":
                rumps.notification("SZU Dorm", "已恢复自动登录", "状态已刷新。")
            else:
                rumps.notification("SZU Dorm", "已暂停自动登录", "状态已刷新。")
            self.refresh_status(None)
        except Exception as exc:
            self._handle_exception("切换暂停状态失败", exc)

    def toggle_network_probe(self, _sender: Any) -> None:
        try:
            enable = not self._network_probe_enabled
            self.logger.info("用户点击：%s", "开启联网状态探测" if enable else "关闭联网状态探测")
            self._set_network_probe_enabled(enable)
            if enable:
                rumps.notification("SZU Dorm", "已开启联网状态探测", "将每 30 秒刷新状态。")
            else:
                rumps.notification("SZU Dorm", "已关闭联网状态探测", "已停止周期性网关和外网检测。")
        except Exception as exc:
            self._handle_exception("切换联网状态探测失败", exc)

    def change_username(self, _sender: Any) -> None:
        try:
            response = rumps.Window(
                message="请输入校园网账号：",
                title="修改账号",
                ok="保存",
                cancel="取消",
                dimensions=(320, 120),
            ).run()
            if not response.clicked:
                return

            username = response.text.strip()
            if not username:
                rumps.alert("修改账号失败", "账号不能为空。")
                return

            self._run_control(["set-username", username], timeout=20)
            self.logger.info("账号已修改：username=%s", mask_username(username))
            rumps.notification("SZU Dorm", "账号已保存", f"当前账号：{mask_username(username)}")
            self.refresh_status(None)
        except Exception as exc:
            self._handle_exception("修改账号失败", exc)

    def change_password(self, _sender: Any) -> None:
        try:
            config = load_config()
            username = get_username(config)
            if not is_username_set(username):
                rumps.alert("修改密码失败", "请先设置校园网账号。")
                return

            security = config.get("security") or {}
            if str(security.get("password_source", "env")) == "env":
                rumps.alert(
                    "修改密码失败",
                    f"当前密码来源是 {describe_password_source(config)}，"
                    "请在 shell/LaunchAgent 中设置它，或把 security.password_source 改为 keychain/private_file。",
                )
                return

            response = rumps.Window(
                message=f"请输入 {mask_username(username)} 的校园网密码：",
                title="修改密码",
                ok="保存",
                cancel="取消",
                dimensions=(320, 120),
                secure=True,
            ).run()
            if not response.clicked:
                return

            password = response.text
            if not password:
                rumps.alert("修改密码失败", "密码不能为空，未保存。")
                return

            password_source_label = describe_password_source(config)
            set_password(config, password)
            self.logger.info(
                "密码已保存：source=%s username=%s",
                password_source_label,
                mask_username(username),
            )
            rumps.notification("SZU Dorm", "密码已保存", f"已保存到 {password_source_label}。")
            self.refresh_status(None)
        except ValueError as exc:
            rumps.alert("修改密码失败", str(exc))
        except Exception as exc:
            self._handle_exception("修改密码失败", exc)

    def generate_diagnostic_report(self, _sender: Any) -> None:
        try:
            self.logger.info("用户点击：生成诊断报告")
            result = self._run_control_process(["generate-diagnostic-report"], timeout=45)
            if result.returncode != 0:
                raise RuntimeError(short_output(result))

            report_path = extract_report_path(result.stdout)
            if report_path:
                subprocess.run(["open", report_path], check=False, timeout=10)
            rumps.notification("SZU Dorm", "诊断报告已生成", report_path or "已写入 logs 目录。")
        except Exception as exc:
            self._handle_exception("生成诊断报告失败", exc)

    def open_config(self, _sender: Any) -> None:
        self._run_simple_control_action("open-config", "打开配置文件失败")

    def open_log(self, _sender: Any) -> None:
        self._run_simple_control_action("open-log", "打开日志失败")

    def reset_pause(self, _sender: Any) -> None:
        try:
            self.logger.info("用户点击：重置暂停状态")
            self._run_control(["reset-pause"], timeout=20)
            self._auto_login_schedule.record_success()
            rumps.notification("SZU Dorm", "暂停状态已重置", "自动登录已恢复。")
            self.refresh_status(None)
        except Exception as exc:
            self._handle_exception("重置暂停状态失败", exc)

    def check_dependencies(self, _sender: Any) -> None:
        try:
            self.logger.info("用户点击：检查依赖")
            result = self._run_control_process(["check-dependencies"], timeout=30)
            output = short_output(result)
            if result.returncode == 0:
                rumps.notification("SZU Dorm", "依赖检查通过", "常见依赖可用。")
                return
            rumps.alert("依赖检查失败", output or "详情可查看日志。")
        except Exception as exc:
            self._handle_exception("检查依赖失败", exc)

    def install_launchagent(self, _sender: Any) -> None:
        self._run_launchagent_script(
            PROJECT_ROOT / "scripts" / "install_launchagent.sh",
            missing_message="未找到安装脚本",
            success_message="开机自启安装完成",
        )

    def uninstall_launchagent(self, _sender: Any) -> None:
        self._run_launchagent_script(
            PROJECT_ROOT / "scripts" / "uninstall_launchagent.sh",
            missing_message="未找到卸载脚本",
            success_message="开机自启卸载完成",
        )

    def reinstall_launchagent(self, _sender: Any) -> None:
        try:
            self.logger.info("用户点击：重装开机自启")
            uninstall_script = PROJECT_ROOT / "scripts" / "uninstall_launchagent.sh"
            install_script = PROJECT_ROOT / "scripts" / "install_launchagent.sh"
            for script_path in (uninstall_script, install_script):
                if not script_path.exists():
                    raise RuntimeError(f"未找到脚本：{script_path}")
                result = subprocess.run(
                    [str(script_path)],
                    cwd=PROJECT_ROOT,
                    check=False,
                    capture_output=True,
                    text=True,
                    timeout=60,
                )
                self._log_completed_process(script_path.name, result)
                if result.returncode != 0:
                    raise RuntimeError(short_output(result))

            rumps.notification("SZU Dorm", "开机自启已重装", "LaunchAgent 已重新安装。")
            self.refresh_status(None)
        except Exception as exc:
            self._handle_exception("重装开机自启失败", exc)

    def quit_app(self, _sender: Any) -> None:
        self.logger.info("用户退出状态栏客户端。")
        self._set_network_probe_enabled(False, refresh=False)
        self._stop_timer(self.watchdog_timer, "watchdog 定时器")
        rumps.quit_application()

    def _set_network_probe_enabled(self, enabled: bool, refresh: bool = True) -> None:
        self._network_probe_enabled = enabled
        self._update_network_probe_item_title()

        if enabled:
            if not self.timer.is_alive():
                self.timer.start()
            if refresh:
                self.refresh_status(None)
            return

        self._stop_timer(self.timer, "状态刷新定时器")
        if refresh:
            self._apply_status_result(
                StatusRefreshResult(
                    is_paused(),
                    NetworkStatus(False, False),
                    network_probe_enabled=False,
                )
            )

    def _stop_timer(self, timer: Any, label: str) -> None:
        try:
            if timer.is_alive():
                timer.stop()
        except Exception as exc:
            self.logger.warning("%s停止失败：%s", label, exc)

    def _update_network_probe_item_title(self) -> None:
        self.network_probe_item.title = (
            "关闭联网状态探测" if self._network_probe_enabled else "开启联网状态探测"
        )

    def _run_simple_control_action(self, command: str, error_title: str) -> None:
        try:
            self.logger.info("用户点击：%s", command)
            self._run_control([command], timeout=20)
        except Exception as exc:
            self._handle_exception(error_title, exc)

    def _run_launchagent_script(
        self,
        script_path: Path,
        missing_message: str,
        success_message: str,
    ) -> None:
        try:
            if not script_path.exists():
                self.logger.warning("%s：%s", missing_message, script_path)
                rumps.alert("SZU Dorm", missing_message)
                return

            self.logger.info("运行脚本：%s", script_path.name)
            result = subprocess.run(
                [str(script_path)],
                cwd=PROJECT_ROOT,
                check=False,
                capture_output=True,
                text=True,
                timeout=60,
            )
            self._log_completed_process(script_path.name, result)
            if result.returncode != 0:
                raise RuntimeError(short_output(result))

            rumps.notification("SZU Dorm", success_message, "操作已完成。")
            self.refresh_status(None)
        except Exception as exc:
            self._handle_exception(f"{success_message}失败", exc)

    def _run_control(self, args: list[str], timeout: int) -> subprocess.CompletedProcess[str]:
        result = self._run_control_process(args, timeout)
        if result.returncode not in (0,):
            raise RuntimeError(short_output(result))
        return result

    def _run_control_process(
        self,
        args: list[str],
        timeout: int,
    ) -> subprocess.CompletedProcess[str]:
        command = [*build_control_command(), *args]
        try:
            result = subprocess.run(
                command,
                cwd=PROJECT_ROOT,
                env=build_control_env(),
                check=False,
                capture_output=True,
                text=True,
                timeout=timeout,
            )
        except subprocess.TimeoutExpired as exc:
            raise RuntimeError(f"命令超时：{mask_command(args)}") from exc

        self._log_completed_process(mask_command(args), result)
        return result

    def _log_completed_process(
        self,
        label: str,
        result: subprocess.CompletedProcess[str],
    ) -> None:
        self.logger.info("命令完成：%s returncode=%s", label, result.returncode)
        output = short_output(result)
        if output:
            self.logger.info("命令输出：%s", output)

    def _load_config_for_status(self) -> tuple[dict[str, Any] | None, str]:
        try:
            return load_config(), ""
        except ConfigError as exc:
            return None, str(exc)

    def _handle_exception(self, title: str, exc: Exception) -> None:
        message = str(exc) or type(exc).__name__
        self.logger.error("%s：%s\n%s", title, message, traceback.format_exc())
        rumps.alert(title, message)


def get_username(config: dict[str, Any]) -> str:
    return str((config.get("user") or {}).get("username") or "").strip()


def is_username_set(username: str) -> bool:
    return bool(username and username != USERNAME_PLACEHOLDER)


def is_non_campus_status(result: StatusRefreshResult | None) -> bool:
    if result is None or result.config_error:
        return False
    if not result.network_probe_enabled:
        return False
    return (not result.auto_login_available) or not result.network_status.gateway_reachable


def should_start_auto_login(paused: bool, result: StatusRefreshResult | None) -> bool:
    if paused:
        return False
    if result is None or result.config_error or not result.network_probe_enabled:
        return False
    if not result.auto_login_available:
        return False
    return result.network_status.maybe_need_login


def auto_login_state_label(paused: bool, result: StatusRefreshResult) -> str:
    if not result.network_probe_enabled:
        return "联网状态探测已关闭"
    if paused:
        return "已暂停"
    if is_non_campus_status(result):
        return "非宿舍网络，自动登录停用"
    return "运行中"


def is_main_thread() -> bool:
    if NSThread is not None:
        try:
            return bool(NSThread.isMainThread())
        except Exception:
            pass
    return threading.current_thread() is threading.main_thread()


def run_on_main_thread(callback: Callable[..., None], *args: Any) -> None:
    if is_main_thread() or AppHelper is None:
        callback(*args)
        return
    AppHelper.callAfter(callback, *args)


def mask_username(username: str) -> str:
    username = username.strip()
    if not username:
        return "未设置"
    return f"**{username[-2:]}"


def mask_command(args: list[str]) -> str:
    if args[:1] == ["set-username"] and len(args) > 1:
        return f"set-username {mask_username(args[1])}"
    return " ".join(args)


def short_output(result: subprocess.CompletedProcess[str]) -> str:
    output = "\n".join(part.strip() for part in (result.stdout, result.stderr) if part.strip())
    return output.replace("\r", " ")[:1000]


def extract_login_reason(output: str) -> str:
    reasons = (
        "密码缺失",
        "密码错误",
        "网关不可达",
        "外网已通",
        "门户接口变化",
        "服务器响应不确定",
        "门户返回失败",
        "登录请求异常",
    )
    for reason in reasons:
        if reason in output:
            return reason
    return ""


def extract_logout_title(output: str, returncode: int) -> str:
    for line in output.splitlines():
        line = line.strip()
        if line.startswith("退出结果："):
            return line.removesuffix("。")
    if returncode == 0:
        return "已退出校园网账号"
    return "退出结果不确定"


def extract_logout_detail(output: str) -> str:
    for line in output.splitlines():
        line = line.strip()
        if line.startswith("自动登录："):
            return line
    return "自动登录已按所选策略暂停。"


def extract_report_path(output: str) -> str:
    for line in output.splitlines():
        if "诊断报告已生成：" not in line:
            continue
        return line.split("诊断报告已生成：", 1)[1].strip()
    return ""


def format_interval(seconds: int) -> str:
    if seconds % 60 == 0:
        return f"{seconds // 60} 分钟"
    return f"{seconds} 秒"


def build_control_command() -> list[str]:
    if getattr(sys, "frozen", False):
        return [sys.executable, CONTROL_DISPATCH_ARG]
    return [sys.executable, "-m", CONTROL_MODULE]


def build_control_env() -> dict[str, str]:
    env = os.environ.copy()
    env[PROJECT_HOME_ENV] = str(PROJECT_ROOT)

    pythonpath = env.get("PYTHONPATH")
    env["PYTHONPATH"] = (
        str(PROJECT_ROOT)
        if not pythonpath
        else os.pathsep.join([str(PROJECT_ROOT), pythonpath])
    )
    return env


def run_control_dispatch() -> int:
    if __package__ in (None, ""):
        from src.szu_netlogin import control
    else:
        from . import control

    return control.main(sys.argv[2:])


def show_startup_alert(title: str, message: str) -> None:
    if rumps is not None:
        try:
            rumps.alert(title, message)
            return
        except Exception:
            pass

    script = (
        'display dialog '
        f'{osascript_quote(message)} '
        f'with title {osascript_quote(title)} '
        'buttons {"好"} default button "好"'
    )
    try:
        subprocess.run(["/usr/bin/osascript", "-e", script], check=False, timeout=10)
    except Exception:
        print(f"{title}: {message}")


def osascript_quote(value: str) -> str:
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


def verify_required_dependencies(logger: logging.Logger) -> bool:
    missing_messages: list[str] = []

    if RUMPS_IMPORT_ERROR is not None:
        missing_messages.append(f"rumps：{RUMPS_IMPORT_ERROR}")

    for module_name in ("objc", "Foundation", "AppKit"):
        try:
            __import__(module_name)
        except Exception as exc:
            missing_messages.append(f"{module_name}：{exc}")

    if not missing_messages:
        return True

    message = "状态栏客户端无法启动，缺少必要依赖：\n" + "\n".join(missing_messages)
    logger.error("依赖缺失，状态栏客户端无法启动：%s", "；".join(missing_messages))
    show_startup_alert("SZU Dorm 依赖缺失", message)
    return False


def main() -> None:
    if len(sys.argv) > 1 and sys.argv[1] == CONTROL_DISPATCH_ARG:
        raise SystemExit(run_control_dispatch())

    logger = get_menubar_logger()
    install_exception_logging(logger)
    logger.info("状态栏客户端启动")
    if not verify_required_dependencies(logger):
        return
    try:
        SzuDormMenubarApp().run()
    except Exception as exc:
        message = str(exc) or type(exc).__name__
        logger.error("状态栏客户端启动后崩溃：%s\n%s", message, traceback.format_exc())
        show_startup_alert("SZU Dorm 启动失败", message)


if __name__ == "__main__":
    main()
