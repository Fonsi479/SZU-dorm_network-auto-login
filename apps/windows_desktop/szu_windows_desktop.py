"""Windows desktop client for SZU Dorm NetLogin."""

from __future__ import annotations

import os
import io
import shutil
import subprocess
import sys
import threading
import time
import traceback
from contextlib import redirect_stderr, redirect_stdout
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from queue import Empty, Queue
from typing import Any, Callable

import tkinter as tk
from tkinter import messagebox, simpledialog, ttk
from tkinter.scrolledtext import ScrolledText


if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from src.szu_netlogin.config import (  # noqa: E402
    _parse_yaml,
    ConfigError,
    DEFAULT_CONFIG_PATH,
    PROJECT_HOME_ENV,
    PROJECT_ROOT,
    load_config,
    provider_configuration,
    validate_config,
)
from src.szu_netlogin.logger import LOG_FILE, get_logger, redact_sensitive_text  # noqa: E402
from src.szu_netlogin.dorm_drcom_client import DormDrcomClient  # noqa: E402
from src.szu_netlogin.offline_fixture import run_offline_portal_self_test  # noqa: E402
from src.szu_netlogin.password_store import (  # noqa: E402
    credential_backend_status,
    describe_password_source,
    set_provider_password,
)
from src.szu_netlogin.windows_product import (  # noqa: E402
    WindowsCampusService,
    get_process_service,
)
from src.szu_netlogin.platform_paths import (  # noqa: E402
    open_path_with_default_app,
    run_subprocess_hidden,
)
from src.szu_netlogin.portal_detect import (  # noqa: E402
    NetworkStatus,
    classify_network_environment,
    probe_gateway,
    probe_internet,
)
from src.szu_netlogin.state import describe_pause_state, is_paused  # noqa: E402


APP_NAME = "SZU Campus Network"
APP_VERSION = "2.0.0"
CONTROL_MODULE = "src.szu_netlogin.control"
CONTROL_DISPATCH_ARG = "--szu-netlogin-control"
STATUS_REFRESH_SECONDS = 30
WATCHDOG_INTERVAL_SECONDS = 1
AUTO_LOGIN_INITIAL_DELAY_SECONDS = 5
AUTO_LOGIN_BACKOFF_SECONDS = (120, 300, 600, 900)
USERNAME_PLACEHOLDER = "你的校园卡号，不要写密码"
STARTUP_LINK_NAME = "SZU Campus Network.lnk"


@dataclass(frozen=True)
class DesktopStatusResult:
    paused: bool
    network_status: NetworkStatus
    config_error: str = ""
    network_probe_enabled: bool = True
    environment_label: str = ""
    auto_login_available: bool = True
    portal_session_state: str = "unknown"
    portal_session_matches: bool = False
    dorm_enabled: bool = True
    teaching_enabled: bool = False
    teaching_session_state: str = "disabled"
    auto_login_provider: str | None = None


class AutoLoginBackoff:
    def __init__(
        self,
        intervals_seconds: tuple[int, ...],
        initial_delay_seconds: float,
        clock=time.time,
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

    def allow_immediate_attempt(self) -> None:
        """Open one immediate attempt after the first verified offline transition."""
        self._deadline = min(self._deadline, self._clock())


class SzuDormWindowsApp:
    def __init__(self, root: tk.Tk) -> None:
        self.root = root
        self.logger = get_logger()
        self.service = get_process_service()
        self._messages: Queue[tuple[str, Any]] = Queue()
        self._status_lock = threading.Lock()
        self._command_lock = threading.Lock()
        self._active_process_lock = threading.Lock()
        self._refresh_in_progress = False
        self._command_in_progress = False
        self._network_probe_enabled = True
        self._closing = False
        self._active_process: subprocess.Popen[str] | None = None
        self._last_status_result: DesktopStatusResult | None = None
        self._last_portal_session_state = "unknown"
        self._status_after_id: str | None = None
        self._drain_after_id: str | None = None
        self._watchdog_after_id: str | None = None
        self._auto_login_schedule = AutoLoginBackoff(
            AUTO_LOGIN_BACKOFF_SECONDS,
            AUTO_LOGIN_INITIAL_DELAY_SECONDS,
        )
        self._status_vars: dict[str, tk.StringVar] = {}
        self._command_buttons: list[ttk.Button] = []
        self._credential_backend_ok, self._credential_backend_label = credential_backend_status()

        self._ensure_initial_config_file()
        self._build_ui()
        self.root.protocol("WM_DELETE_WINDOW", self._close)
        self.root.after(100, self.refresh_status)
        self._drain_after_id = self.root.after(100, self._drain_messages)
        self._watchdog_after_id = self.root.after(
            WATCHDOG_INTERVAL_SECONDS * 1000,
            self._watchdog_tick,
        )

    def _build_ui(self) -> None:
        if not hasattr(self, "_credential_backend_ok"):
            self._credential_backend_ok, self._credential_backend_label = credential_backend_status()
        self.root.title(APP_NAME)
        self.root.geometry("900x680")
        self.root.minsize(820, 620)

        style = ttk.Style(self.root)
        try:
            style.theme_use("clam")
        except tk.TclError:
            pass
        style.configure("Title.TLabel", font=("Segoe UI", 18, "bold"))
        style.configure("Subtitle.TLabel", foreground="#5f6b7a")
        style.configure("State.TLabel", font=("Segoe UI", 10, "bold"), foreground="#176b3a")
        style.configure("StatusName.TLabel", foreground="#445", font=("Segoe UI", 10, "bold"))
        style.configure("StatusValue.TLabel", font=("Segoe UI", 10))
        style.configure("Primary.TButton", font=("Segoe UI", 10, "bold"))

        main = ttk.Frame(self.root, padding=16)
        main.pack(fill=tk.BOTH, expand=True)
        main.columnconfigure(0, weight=1)
        main.rowconfigure(1, weight=1)

        header = ttk.Frame(main)
        header.grid(row=0, column=0, sticky="ew", pady=(0, 12))
        header.columnconfigure(0, weight=1)
        title_group = ttk.Frame(header)
        title_group.grid(row=0, column=0, sticky="w")
        ttk.Label(title_group, text="SZU Campus Network", style="Title.TLabel").grid(
            row=0, column=0, sticky="w"
        )
        ttk.Label(
            title_group,
            text=f"Windows 独立客户端 v{APP_VERSION} · 宿舍/教学双 Provider",
            style="Subtitle.TLabel",
        ).grid(row=1, column=0, sticky="w", pady=(2, 0))
        self.header_state_var = tk.StringVar(value="正在检查网络…")
        ttk.Label(header, textvariable=self.header_state_var, style="State.TLabel").grid(
            row=0, column=1, rowspan=2, sticky="e", padx=(16, 0)
        )

        self.notebook = ttk.Notebook(main)
        self.notebook.grid(row=1, column=0, sticky="nsew")

        overview = ttk.Frame(self.notebook, padding=14)
        diagnostics = ttk.Frame(self.notebook, padding=14)
        self.notebook.add(overview, text="概览")
        self.notebook.add(diagnostics, text="诊断与日志")
        overview.columnconfigure(0, weight=1)
        overview.rowconfigure(0, weight=1)
        diagnostics.columnconfigure(0, weight=1)
        diagnostics.rowconfigure(1, weight=1)

        status_frame = ttk.LabelFrame(overview, text="当前状态", padding=12)
        status_frame.grid(row=0, column=0, sticky="nsew", pady=(0, 12))
        status_frame.columnconfigure(1, weight=1)
        self._add_status_row(status_frame, 0, "自动登录", "run_state")
        self._add_status_row(status_frame, 1, "暂停状态", "pause_state")
        self._add_status_row(status_frame, 2, "网络环境", "environment")
        self._add_status_row(status_frame, 3, "门户会话", "portal_session")
        self._add_status_row(status_frame, 4, "宿舍 Provider", "dorm_provider")
        self._add_status_row(status_frame, 5, "教学 Provider", "teaching_provider")
        self._add_status_row(status_frame, 6, "默认网络出口", "internet")
        self._add_status_row(status_frame, 7, "宿舍网关", "gateway")
        self._add_status_row(status_frame, 8, "源 IP", "source_ip")
        self._add_status_row(status_frame, 9, "Credential Manager", "credential_backend")
        self._add_status_row(status_frame, 10, "配置文件", "config")
        self._add_status_row(status_frame, 11, "开机自启", "startup")
        self._add_status_row(status_frame, 12, "更新时间", "updated_at")

        button_frame = ttk.LabelFrame(overview, text="快捷操作", padding=8)
        button_frame.grid(row=1, column=0, sticky="ew")
        for index in range(4):
            button_frame.columnconfigure(index, weight=1)

        self.refresh_button = self._add_button(
            button_frame,
            0,
            0,
            "刷新状态",
            self.refresh_status,
        )
        self.login_button = self._add_button(
            button_frame,
            0,
            1,
            "立即登录",
            lambda: self._run_control_action(["login-now"], "立即登录", timeout=80),
            style="Primary.TButton",
        )
        self.check_login_button = self._add_button(
            button_frame,
            0,
            2,
            "检查并登录",
            lambda: self._run_control_action(["check-and-login"], "检查并登录", timeout=100),
        )
        self.logout_button = self._add_button(button_frame, 0, 3, "退出账号", self.logout_now)

        self.pause_button = self._add_button(button_frame, 1, 0, "暂停自动登录", self.toggle_pause)
        self.probe_button = self._add_button(
            button_frame,
            1,
            1,
            "关闭联网探测",
            self.toggle_network_probe,
        )
        self.username_button = self._add_button(button_frame, 1, 2, "修改账号", self.change_username)
        self.password_button = self._add_button(
            button_frame, 1, 3, "宿舍密码", lambda: self.change_password("dorm")
        )
        self.teaching_password_button = self._add_button(
            button_frame, 2, 0, "教学密码", lambda: self.change_password("teaching")
        )
        self.dorm_toggle_button = self._add_button(
            button_frame, 2, 1, "切换宿舍认证", lambda: self.toggle_provider("dorm")
        )
        self.teaching_toggle_button = self._add_button(
            button_frame, 2, 2, "切换教学认证", lambda: self.toggle_provider("teaching")
        )
        self.startup_button = self._add_button(
            button_frame,
            3,
            0,
            "安装开机自启",
            self.toggle_windows_startup,
            columnspan=2,
        )
        self.open_diagnostics_button = self._add_button(
            button_frame,
            3,
            2,
            "打开诊断工具",
            lambda: self.notebook.select(diagnostics),
            columnspan=2,
        )

        diagnostic_buttons = ttk.Frame(diagnostics)
        diagnostic_buttons.grid(row=0, column=0, sticky="ew", pady=(0, 10))
        for index in range(4):
            diagnostic_buttons.columnconfigure(index, weight=1)
        self.config_button = self._add_button(
            diagnostic_buttons, 0, 0, "打开配置", self.open_config
        )
        self.log_button = self._add_button(diagnostic_buttons, 0, 1, "打开日志", self.open_log)
        self.report_button = self._add_button(
            diagnostic_buttons,
            0,
            2,
            "诊断报告",
            lambda: self._run_control_action(
                ["generate-diagnostic-report"],
                "生成诊断报告",
                timeout=60,
            ),
        )
        self.reset_pause_button = self._add_button(
            diagnostic_buttons,
            0,
            3,
            "重置暂停",
            lambda: self._run_control_action(["reset-pause"], "重置暂停", timeout=30),
        )
        self.dependencies_button = self._add_button(
            diagnostic_buttons,
            1,
            0,
            "检查依赖",
            lambda: self._run_control_action(
                ["check-dependencies"],
                "检查依赖",
                timeout=30,
            ),
            columnspan=4,
        )

        output_frame = ttk.LabelFrame(diagnostics, text="脱敏运行输出", padding=8)
        output_frame.grid(row=1, column=0, sticky="nsew")
        output_frame.rowconfigure(0, weight=1)
        output_frame.columnconfigure(0, weight=1)
        self.output = ScrolledText(
            output_frame,
            height=10,
            wrap=tk.WORD,
            state=tk.DISABLED,
            font=("Consolas", 10),
            background="#111827",
            foreground="#e5e7eb",
            insertbackground="#f9fafb",
            selectbackground="#374151",
            relief=tk.FLAT,
            padx=10,
            pady=8,
        )
        self.output.grid(row=0, column=0, sticky="nsew")
        self._append_output("诊断输出将在这里显示；账号、密码和 URL 等敏感内容会自动脱敏。")

        self.footer_var = tk.StringVar(value=f"配置：{DEFAULT_CONFIG_PATH}")
        ttk.Label(main, textvariable=self.footer_var, style="Subtitle.TLabel").grid(
            row=2, column=0, sticky="w", pady=(10, 0)
        )
        self._update_startup_ui()
        if not self._credential_backend_ok:
            self.password_button.configure(state=tk.DISABLED)
            self.teaching_password_button.configure(state=tk.DISABLED)

    def _ensure_initial_config_file(self) -> None:
        if DEFAULT_CONFIG_PATH.exists():
            return
        try:
            create_config_from_example(DEFAULT_CONFIG_PATH)
        except OSError as exc:
            self.logger.warning("首次创建配置文件失败：%s", exc)

    def _add_status_row(self, parent: ttk.Frame, row: int, label: str, key: str) -> None:
        ttk.Label(parent, text=label, style="StatusName.TLabel").grid(
            row=row,
            column=0,
            sticky="nw",
            padx=(0, 12),
            pady=3,
        )
        value = tk.StringVar(value="-")
        self._status_vars[key] = value
        ttk.Label(
            parent,
            textvariable=value,
            style="StatusValue.TLabel",
            wraplength=560,
        ).grid(row=row, column=1, sticky="ew", pady=3)

    def _add_button(
        self,
        parent: ttk.Frame,
        row: int,
        column: int,
        text: str,
        command,
        *,
        columnspan: int = 1,
        style: str | None = None,
    ) -> ttk.Button:
        button = ttk.Button(parent, text=text, command=command, style=style)
        button.grid(
            row=row,
            column=column,
            columnspan=columnspan,
            sticky="ew",
            padx=4,
            pady=4,
        )
        self._command_buttons.append(button)
        return button

    def refresh_status(self) -> None:
        if self._closing:
            return
        if not self._network_probe_enabled:
            self._apply_status_result(
                DesktopStatusResult(
                    is_paused(),
                    NetworkStatus(False, False),
                    network_probe_enabled=False,
                )
            )
            return

        with self._status_lock:
            if self._refresh_in_progress:
                return
            self._refresh_in_progress = True

        threading.Thread(target=self._refresh_status_worker, daemon=True).start()

    def _refresh_status_worker(self) -> None:
        try:
            status = self.service.status()
            providers = status["providers"]
            dorm = providers["dorm"]
            teaching = providers["teaching"]
            active_id = status["networkContext"] if status["networkContext"] in providers else None
            active = providers.get(active_id, {})
            portal_session_state = str(active.get("state") or "unknown")
            portal_session_matches = (
                portal_session_state == "online" and active.get("accountMatch") is True
            )
            network_status = NetworkStatus(
                gateway_reachable=status["networkContext"] == "dorm",
                campus_internet_ok=False,
            )
            if self._closing:
                return
            self._messages.put(
                (
                    "status",
                    DesktopStatusResult(
                        bool(status["paused"]),
                        network_status,
                        "",
                        environment_label=status["networkContext"],
                        auto_login_available=status["autoLoginProvider"] is not None,
                        portal_session_state=portal_session_state,
                        portal_session_matches=portal_session_matches,
                        dorm_enabled=bool(dorm["enabled"]),
                        teaching_enabled=bool(teaching["enabled"]),
                        teaching_session_state=str(teaching["state"]),
                        auto_login_provider=status["autoLoginProvider"],
                    ),
                )
            )
        except Exception as exc:
            self._messages.put(("error", ("刷新状态失败", exc, traceback.format_exc())))
        finally:
            with self._status_lock:
                self._refresh_in_progress = False

    def _apply_status_result(self, result: DesktopStatusResult) -> None:
        self._last_status_result = result
        run_label = auto_login_state_label(result.paused, result)
        if result.portal_session_matches:
            campus_label = "可用" if result.network_status.campus_internet_ok else "门户在线，出口待确认"
        elif result.portal_session_state == "offline":
            campus_label = "门户离线，未探测"
        else:
            campus_label = "未探测"
        gateway_label = "可达" if result.network_status.gateway_reachable else "不可达"
        config_label = str(DEFAULT_CONFIG_PATH) if not result.config_error else result.config_error
        portal_label = portal_session_label(result)

        self._status_vars["run_state"].set(run_label)
        self._status_vars["pause_state"].set(describe_pause_state())
        self._status_vars["environment"].set(result.environment_label or "网络环境未知")
        self._status_vars["portal_session"].set(portal_label)
        self._status_vars["dorm_provider"].set(
            ("启用 · " + portal_label) if result.dorm_enabled else "已关闭"
        )
        self._status_vars["teaching_provider"].set(
            ("启用 · " + result.teaching_session_state) if result.teaching_enabled else "已关闭"
        )
        self._status_vars["internet"].set(campus_label)
        self._status_vars["gateway"].set(gateway_label)
        self._status_vars["source_ip"].set(result.network_status.source_ip or "-")
        self._status_vars["credential_backend"].set(self._credential_backend_label)
        self._status_vars["config"].set(config_label)
        self._status_vars["startup"].set(
            "已安装" if is_windows_startup_enabled() else "未安装"
        )
        self._status_vars["updated_at"].set(datetime.now().strftime("%Y-%m-%d %H:%M:%S"))
        self.header_state_var.set(run_label)
        self.pause_button.configure(text="恢复自动登录" if result.paused else "暂停自动登录")
        self.probe_button.configure(
            text="关闭联网探测" if self._network_probe_enabled else "开启联网探测"
        )
        self._update_startup_ui()

        transition_state = (
            f"{result.auto_login_provider}:offline"
            if result.auto_login_provider and result.portal_session_state == "offline"
            else ("online" if result.portal_session_matches else result.portal_session_state)
        )
        if transition_state.endswith(":offline") and self._last_portal_session_state != transition_state:
            self._auto_login_schedule.allow_immediate_attempt()
        self._last_portal_session_state = transition_state

        if result.portal_session_matches:
            self._auto_login_schedule.record_success()

        self._schedule_next_status_refresh()

    def _schedule_next_status_refresh(self) -> None:
        if self._closing:
            return
        if self._status_after_id is not None:
            try:
                self.root.after_cancel(self._status_after_id)
            except tk.TclError:
                pass
            self._status_after_id = None

        if self._network_probe_enabled:
            self._status_after_id = self.root.after(
                STATUS_REFRESH_SECONDS * 1000,
                self.refresh_status,
            )

    def _watchdog_tick(self) -> None:
        if self._closing:
            return
        self._update_startup_ui()
        if self._network_probe_enabled and self._auto_login_schedule.consume_if_due():
            if should_start_auto_login(is_paused(), self._last_status_result):
                self._run_control_action(
                    ["check-and-login"],
                    "后台自动检查",
                    timeout=100,
                    show_dialog=False,
                    auto_login=True,
                )
            elif is_non_campus_status(self._last_status_result):
                label = self._last_status_result.environment_label or "非宿舍网络"
                self.logger.info("当前不是宿舍区校园网：%s，本轮自动登录已停止。", label)

        self._watchdog_after_id = self.root.after(
            WATCHDOG_INTERVAL_SECONDS * 1000,
            self._watchdog_tick,
        )

    def _run_control_action(
        self,
        args: list[str],
        label: str,
        timeout: int,
        show_dialog: bool = True,
        auto_login: bool = False,
    ) -> None:
        if not self._begin_command(label, show_dialog):
            return

        threading.Thread(
            target=self._control_worker,
            args=(args, label, timeout, show_dialog, auto_login),
            daemon=True,
        ).start()

    def _begin_command(self, label: str, show_dialog: bool) -> bool:
        with self._command_lock:
            if self._command_in_progress:
                if show_dialog:
                    messagebox.showinfo(APP_NAME, "已有操作正在执行，请稍后再试。")
                return False
            self._command_in_progress = True

        if show_dialog:
            self._set_command_buttons_enabled(False)
        self._append_output(f"> {label}")
        return True

    def _run_local_action(
        self,
        action: Callable[[], Any],
        label: str,
        completion: Callable[[Any], None],
    ) -> None:
        if not self._begin_command(label, True):
            return

        def worker() -> None:
            try:
                self._messages.put(("local_result", (label, completion, action())))
            except Exception as exc:
                self._messages.put(("command_error", (label, exc, traceback.format_exc(), True)))

        threading.Thread(
            target=worker,
            name="szu-windows-local-action",
            daemon=True,
        ).start()

    def _control_worker(
        self,
        args: list[str],
        label: str,
        timeout: int,
        show_dialog: bool,
        auto_login: bool,
    ) -> None:
        try:
            result = self._run_control_process(args, timeout)
            self._messages.put(("command_result", (label, args, result, show_dialog, auto_login)))
        except Exception as exc:
            self._messages.put(("command_error", (label, exc, traceback.format_exc(), show_dialog)))

    def _finish_command(self) -> None:
        with self._command_lock:
            self._command_in_progress = False
        self._set_command_buttons_enabled(True)

    def _set_command_buttons_enabled(self, enabled: bool) -> None:
        if self._closing:
            return
        state = tk.NORMAL if enabled else tk.DISABLED
        for button in self._command_buttons:
            button.configure(state=state)

    def logout_now(self) -> None:
        if not messagebox.askyesno(APP_NAME, "退出账号会先暂停自动登录，确定继续吗？"):
            return
        self._run_control_action(
            ["logout", "--pause-for", "manual"],
            "退出校园网账号",
            timeout=60,
        )

    def toggle_pause(self) -> None:
        command = "resume" if is_paused() else "pause"
        label = "恢复自动登录" if command == "resume" else "暂停自动登录"
        self._run_control_action([command], label, timeout=30)

    def toggle_network_probe(self) -> None:
        self._network_probe_enabled = not self._network_probe_enabled
        if self._network_probe_enabled:
            self._append_output("已开启联网状态探测。")
            self.refresh_status()
            return

        if self._status_after_id is not None:
            try:
                self.root.after_cancel(self._status_after_id)
            except tk.TclError:
                pass
            self._status_after_id = None
        self._append_output("已关闭联网状态探测。")
        self._apply_status_result(
            DesktopStatusResult(
                is_paused(),
                NetworkStatus(False, False),
                network_probe_enabled=False,
            )
        )

    def change_username(self) -> None:
        username = simpledialog.askstring(APP_NAME, "请输入校园网账号：", parent=self.root)
        if username is None:
            return
        username = username.strip()
        if not username:
            messagebox.showwarning(APP_NAME, "账号不能为空。")
            return
        self._run_control_action(["set-username", username], "修改账号", timeout=30)

    def toggle_provider(self, provider_id: str) -> None:
        try:
            config = load_config()
            enabled = provider_configuration(config, provider_id)["enabled"]
        except ConfigError as exc:
            messagebox.showwarning(APP_NAME, f"配置检查失败：{exc}")
            return
        self._run_control_action(
            ["set-provider-enabled", provider_id, "false" if enabled else "true"],
            "切换 Provider",
            timeout=30,
        )

    def change_password(self, provider_id: str = "dorm") -> None:
        try:
            config = load_config()
        except ConfigError as exc:
            messagebox.showwarning(APP_NAME, f"配置检查失败：{exc}")
            return

        username = provider_configuration(config, provider_id)["account_label"]
        if not is_username_set(username):
            messagebox.showwarning(APP_NAME, "请先设置校园网账号。")
            return

        if not self._credential_backend_ok:
            messagebox.showwarning(APP_NAME, "Windows Credential Manager backend 不可用。")
            return

        password = simpledialog.askstring(
            APP_NAME,
            f"请输入 {mask_username(username)} 的校园网密码：",
            parent=self.root,
            show="*",
        )
        if password is None:
            return
        if not password:
            messagebox.showwarning(APP_NAME, "密码不能为空，未保存。")
            return

        password_source = describe_password_source(config)
        self._run_local_action(
            lambda: set_provider_password(config, provider_id, password),
            "保存密码",
            lambda _result: self._finish_password_change(password_source),
        )

    def _finish_password_change(self, password_source: str) -> None:
        messagebox.showinfo(APP_NAME, f"密码已保存到 {password_source}。")
        self._append_output(f"密码已保存：{password_source}")
        self.refresh_status()

    def toggle_windows_startup(self) -> None:
        enable = not is_windows_startup_enabled()
        label = "安装开机自启" if enable else "卸载开机自启"
        self._run_local_action(
            lambda: set_windows_startup_enabled(enable),
            label,
            self._finish_windows_startup_change,
        )

    def _finish_windows_startup_change(self, enabled: bool) -> None:
        self._update_startup_ui()
        self._status_vars["startup"].set("已安装" if enabled else "未安装")
        detail = "登录 Windows 后会自动启动客户端。" if enabled else "已移除启动快捷方式。"
        self._append_output(detail)
        messagebox.showinfo(APP_NAME, detail)

    def _update_startup_ui(self) -> None:
        enabled = is_windows_startup_enabled()
        button = getattr(self, "startup_button", None)
        if button is not None:
            button.configure(text="卸载开机自启" if enabled else "安装开机自启")

    def open_config(self) -> None:
        if not DEFAULT_CONFIG_PATH.exists() and not self._confirm_create_config():
            return
        self._open_path(DEFAULT_CONFIG_PATH)

    def open_log(self) -> None:
        if not LOG_FILE.exists():
            messagebox.showinfo(APP_NAME, f"日志还不存在：{LOG_FILE}")
            return
        self._open_path(LOG_FILE)

    def _open_path(self, path: Path) -> None:
        try:
            open_path_with_default_app(path)
        except OSError as exc:
            messagebox.showerror(APP_NAME, f"打开失败：{exc}")

    def _confirm_create_config(self) -> bool:
        if not messagebox.askyesno(
            APP_NAME,
            f"找不到配置文件：{DEFAULT_CONFIG_PATH}\n是否从示例配置创建？",
        ):
            return False

        try:
            create_config_from_example(DEFAULT_CONFIG_PATH)
        except OSError as exc:
            messagebox.showerror(APP_NAME, f"创建配置失败：{exc}")
            return False

        self._append_output(f"已创建配置文件：{DEFAULT_CONFIG_PATH}")
        return True

    def _load_config_for_status(self) -> tuple[dict[str, Any] | None, str]:
        try:
            return load_config(), ""
        except ConfigError as exc:
            return None, str(exc)

    def _drain_messages(self) -> None:
        if self._closing:
            return
        while True:
            try:
                kind, payload = self._messages.get_nowait()
            except Empty:
                break

            if kind == "status":
                if not self._network_probe_enabled and payload.network_probe_enabled:
                    self.logger.info("忽略已关闭探测后的旧状态刷新结果。")
                    continue
                self._apply_status_result(payload)
                continue

            if kind == "command_result":
                label, args, result, show_dialog, auto_login = payload
                self._handle_command_result(label, args, result, show_dialog, auto_login)
                continue

            if kind == "command_error":
                label, exc, formatted_traceback, show_dialog = payload
                self._finish_command()
                self.logger.error("%s失败：%s\n%s", label, exc, formatted_traceback)
                message = str(exc) or type(exc).__name__
                self._append_output(f"{label}失败：{message}")
                if show_dialog:
                    messagebox.showerror(APP_NAME, f"{label}失败：{message}")
                continue

            if kind == "local_result":
                _label, completion, result = payload
                self._finish_command()
                completion(result)
                continue

            title, exc, formatted_traceback = payload
            self.logger.error("%s：%s\n%s", title, exc, formatted_traceback)
            self._append_output(f"{title}：{exc}")
            if title == "刷新状态失败":
                self.header_state_var.set("状态刷新失败，将自动重试")
                self._schedule_next_status_refresh()

        self._drain_after_id = self.root.after(100, self._drain_messages)

    def _handle_command_result(
        self,
        label: str,
        args: list[str],
        result: subprocess.CompletedProcess[str],
        show_dialog: bool,
        auto_login: bool,
    ) -> None:
        self._finish_command()
        output = short_output(result)
        self.logger.info("命令完成：%s returncode=%s", mask_command(args), result.returncode)
        if output:
            self.logger.info("命令输出：%s", output)
            self._append_output(output)

        if auto_login:
            if result.returncode == 0:
                self._auto_login_schedule.record_success()
            else:
                self._auto_login_schedule.record_failure()
                self._append_output(
                    f"后台自动检查失败，下次约 {format_interval(self._auto_login_schedule.current_interval_seconds)} 后重试。"
                )
            self.refresh_status()
            return

        if show_dialog:
            if result.returncode == 0:
                messagebox.showinfo(APP_NAME, f"{label}完成。")
            else:
                messagebox.showwarning(APP_NAME, output or f"{label}失败。")

        if label == "生成诊断报告" and result.returncode == 0:
            report_path = extract_report_path(result.stdout)
            if report_path:
                self._open_path(Path(report_path))

        self.refresh_status()

    def _append_output(self, text: str) -> None:
        redacted = redact_sensitive_text(text).strip()
        if not redacted:
            return
        timestamp = datetime.now().strftime("%H:%M:%S")
        self.output.configure(state=tk.NORMAL)
        self.output.insert(tk.END, f"[{timestamp}] {redacted}\n")
        self.output.see(tk.END)
        self.output.configure(state=tk.DISABLED)

    def _close(self) -> None:
        if self._closing:
            return
        self._closing = True
        self._network_probe_enabled = False
        self.service.cancel_pending_operations()
        self._cancel_active_control_process()
        for after_id in (
            self._status_after_id,
            self._drain_after_id,
            self._watchdog_after_id,
        ):
            if after_id is None:
                continue
            try:
                self.root.after_cancel(after_id)
            except tk.TclError:
                pass
        self.root.destroy()

    def _run_control_process(
        self,
        args: list[str],
        timeout: int,
    ) -> subprocess.CompletedProcess[str]:
        # Keep one service/coordinator for the GUI lifetime in both source and
        # frozen builds. External CLI processes are serialized by the shared
        # user-level authentication lock.
        return run_frozen_control_action(args, service=self.service)

        PROJECT_ROOT.mkdir(parents=True, exist_ok=True)
        command = [*build_control_command(), *args]
        process: subprocess.Popen[str] | None = None
        try:
            process = subprocess.Popen(
                command,
                cwd=PROJECT_ROOT,
                env=build_control_env(),
                text=True,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                **hidden_popen_options(),
            )
            with self._active_process_lock:
                if self._closing:
                    self._terminate_process(process)
                    raise RuntimeError("客户端正在退出，已取消命令。")
                self._active_process = process
            stdout, stderr = process.communicate(timeout=timeout)
            return subprocess.CompletedProcess(command, process.returncode, stdout, stderr)
        except subprocess.TimeoutExpired as exc:
            if process is not None:
                self._terminate_process(process)
            raise RuntimeError(f"命令超时：{mask_command(args)}") from exc
        finally:
            if process is not None:
                with self._active_process_lock:
                    if self._active_process is process:
                        self._active_process = None

    def _cancel_active_control_process(self) -> None:
        with self._active_process_lock:
            process = self._active_process
        if process is not None and process.poll() is None:
            self.logger.info("正在取消运行中的控制命令。")
            self._terminate_process(process)

    @staticmethod
    def _terminate_process(process: subprocess.Popen[str]) -> None:
        try:
            process.terminate()
            process.wait(timeout=3)
        except (OSError, subprocess.TimeoutExpired):
            try:
                process.kill()
            except OSError:
                pass


def get_windows_startup_dir() -> Path:
    appdata = Path(os.environ.get("APPDATA") or Path.home() / "AppData" / "Roaming")
    return appdata / "Microsoft" / "Windows" / "Start Menu" / "Programs" / "Startup"


def get_windows_startup_link(startup_dir: Path | None = None) -> Path:
    return (startup_dir or get_windows_startup_dir()) / STARTUP_LINK_NAME


def is_windows_startup_enabled(startup_dir: Path | None = None) -> bool:
    return get_windows_startup_link(startup_dir).is_file()


def get_windows_launcher() -> tuple[Path, str, Path]:
    if getattr(sys, "frozen", False):
        executable = Path(sys.executable).resolve()
        return executable, "", executable.parent

    script_path = Path(__file__).resolve()
    executable = Path(sys.executable).resolve()
    pythonw = executable.with_name("pythonw.exe")
    if pythonw.is_file():
        executable = pythonw
    return executable, f'"{script_path}"', script_path.parents[2]


def set_windows_startup_enabled(
    enabled: bool,
    startup_dir: Path | None = None,
    launcher: tuple[Path, str, Path] | None = None,
) -> bool:
    startup_link = get_windows_startup_link(startup_dir)
    if not enabled:
        try:
            startup_link.unlink()
        except FileNotFoundError:
            pass
        if startup_link.exists():
            raise RuntimeError(f"无法移除开机自启快捷方式：{startup_link}")
        return False

    startup_link.parent.mkdir(parents=True, exist_ok=True)
    executable, arguments, working_directory = launcher or get_windows_launcher()
    env = os.environ.copy()
    env.update(
        {
            "SZU_STARTUP_LINK": str(startup_link),
            "SZU_STARTUP_TARGET": str(executable),
            "SZU_STARTUP_ARGS": arguments,
            "SZU_STARTUP_WORKDIR": str(working_directory),
        }
    )
    powershell_script = (
        "$w=New-Object -ComObject WScript.Shell;"
        "$s=$w.CreateShortcut($env:SZU_STARTUP_LINK);"
        "$s.TargetPath=$env:SZU_STARTUP_TARGET;"
        "$s.Arguments=$env:SZU_STARTUP_ARGS;"
        "$s.WorkingDirectory=$env:SZU_STARTUP_WORKDIR;"
        "$s.WindowStyle=7;"
        "$s.Save()"
    )
    try:
        result = run_subprocess_hidden(
            [
                "powershell",
                "-NoProfile",
                "-NonInteractive",
                "-ExecutionPolicy",
                "Bypass",
                "-Command",
                powershell_script,
            ],
            env=env,
            check=False,
            capture_output=True,
            text=True,
            stdin=subprocess.DEVNULL,
            timeout=15,
        )
    except (OSError, subprocess.SubprocessError) as exc:
        raise RuntimeError(f"创建开机自启快捷方式失败：{exc}") from exc

    if result.returncode != 0:
        detail = (result.stderr or result.stdout or "PowerShell 返回失败").strip()[:500]
        raise RuntimeError(f"创建开机自启快捷方式失败：{detail}")
    if not startup_link.is_file():
        raise RuntimeError(f"未能确认开机自启快捷方式已创建：{startup_link}")
    return True


def hidden_popen_options() -> dict[str, Any]:
    if os.name != "nt":
        return {}

    startupinfo = subprocess.STARTUPINFO()
    startupinfo.dwFlags |= subprocess.STARTF_USESHOWWINDOW
    startupinfo.wShowWindow = 0
    return {
        "creationflags": getattr(subprocess, "CREATE_NO_WINDOW", 0),
        "startupinfo": startupinfo,
    }


def build_control_command() -> list[str]:
    if getattr(sys, "frozen", False):
        return [sys.executable, CONTROL_DISPATCH_ARG]
    return [sys.executable, "-m", CONTROL_MODULE]


def run_frozen_control_action(
    args: list[str], *, service: WindowsCampusService | None = None
) -> subprocess.CompletedProcess[str]:
    from src.szu_netlogin import control

    stdout = io.StringIO()
    stderr = io.StringIO()
    with redirect_stdout(stdout), redirect_stderr(stderr):
        returncode = control.main(args, service=service or get_process_service())
    return subprocess.CompletedProcess(
        [sys.executable, *args],
        returncode,
        stdout.getvalue(),
        stderr.getvalue(),
    )


def build_control_env() -> dict[str, str]:
    env = os.environ.copy()
    env[PROJECT_HOME_ENV] = str(PROJECT_ROOT)
    env["PYTHONUTF8"] = "1"
    pythonpath = env.get("PYTHONPATH")
    env["PYTHONPATH"] = (
        str(PROJECT_ROOT)
        if not pythonpath
        else os.pathsep.join([str(PROJECT_ROOT), pythonpath])
    )
    return env


def create_config_from_example(target: Path) -> None:
    target.parent.mkdir(parents=True, exist_ok=True)
    source = bundled_path("config.example.yaml")
    if source.exists():
        shutil.copyfile(source, target)
        return
    target.write_text(DEFAULT_CONFIG_TEMPLATE, encoding="utf-8")


def bundled_path(name: str) -> Path:
    if getattr(sys, "frozen", False):
        return Path(getattr(sys, "_MEIPASS", Path(sys.executable).parent)) / name
    return PROJECT_ROOT / name


def get_username(config: dict[str, Any]) -> str:
    return str((config.get("user") or {}).get("username") or "").strip()


def is_username_set(username: str) -> bool:
    return bool(username and username != USERNAME_PLACEHOLDER)


def should_start_auto_login(paused: bool, result: DesktopStatusResult | None) -> bool:
    if paused:
        return False
    if result is None or result.config_error or not result.network_probe_enabled:
        return False
    return (
        result.auto_login_available
        and result.auto_login_provider in {"dorm", "teaching"}
        and result.portal_session_state == "offline"
        and not result.portal_session_matches
    )


def is_non_campus_status(result: DesktopStatusResult | None) -> bool:
    if result is None or result.config_error or not result.network_probe_enabled:
        return False
    return result.environment_label in {"nonCampus", "ambiguous", "unknown"}


def auto_login_state_label(paused: bool, result: DesktopStatusResult) -> str:
    if not result.network_probe_enabled:
        return "联网状态探测已关闭"
    if paused:
        return "已暂停"
    if is_non_campus_status(result):
        return "非宿舍网络，自动登录停用"
    if result.portal_session_matches:
        return "门户已登录"
    if result.portal_session_state == "online":
        return "检测到其他门户会话，自动登录停用"
    if result.portal_session_state == "unknown":
        return "等待门户确认，不发送账号密码"
    return "运行中"


def portal_session_label(result: DesktopStatusResult) -> str:
    if not result.network_probe_enabled:
        return "检测已关闭"
    if result.portal_session_matches:
        return "已登录（账号与 IP 已匹配）"
    if result.portal_session_state == "online":
        return "存在其他账号或 IP 的在线会话"
    if result.portal_session_state == "offline":
        return "已确认离线"
    return "暂时无法确认"


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
    return output.replace("\r", " ")[:1200]


def extract_report_path(output: str) -> str:
    for line in output.splitlines():
        if "诊断报告已生成：" in line:
            return line.split("诊断报告已生成：", 1)[1].strip()
    return ""


def format_interval(seconds: int) -> str:
    if seconds % 60 == 0:
        return f"{seconds // 60} 分钟"
    return f"{seconds} 秒"


def run_control_dispatch() -> int:
    from src.szu_netlogin import control

    return control.main(sys.argv[2:])


def run_frozen_self_test() -> int:
    """Exercise bundled data and portal lifecycle fixtures without a socket."""
    try:
        import keyring  # noqa: F401
        import requests  # noqa: F401

        template = bundled_path("config.example.yaml").read_text(encoding="utf-8")
        config = _parse_yaml(template)
        config["user"]["username"] = "123456"
        validate_config(config)
        if not run_offline_portal_self_test():
            return 1

        # Keep the retry policy deterministic in the frozen self-test too;
        # this catches accidental eager retries and failed backoff resets.
        now = [100.0]
        schedule = AutoLoginBackoff((120, 300), 60, clock=lambda: now[0])
        if schedule.consume_if_due():
            return 1
        now[0] = 160.0
        if not schedule.consume_if_due():
            return 1
        schedule.record_failure()
        if schedule.current_interval_seconds != 300:
            return 1
        schedule.record_success()
        if schedule.current_interval_seconds != 120:
            return 1
    except Exception:
        return 1
    return 0


DEFAULT_CONFIG_TEMPLATE = """schemaVersion: 1

general:
  autoDetect: true
  connectivityProbe: true
  launchAtLogin: false
  paused: false

providers:
  dorm:
    enabled: true
    accountLabel: "你的校园卡号，不要写密码"
    credentialRef: "provider:dorm:primary"
  teaching:
    enabled: false
    accountLabel: "你的校园卡号，不要写密码"
    credentialRef: "provider:teaching:primary"
    accountSuffixMode: "auto"
    customSuffix: ""

auth:
  type: dorm_drcom
  login_url: "http://172.30.255.42:801/eportal/portal/login"
  logout_url: ""
  logout_page_url: ""
  unbind_url: ""
  callback: "dr1003"
  logout_callback: "dr1004"
  logout_js_version: "4.1.3"
  login_method: "1"
  account_prefix: ",1,"
  timeout_seconds: 8

user:
  username: "你的校园卡号，不要写密码"

network:
  portalHost: "net.szu.edu.cn"
  dorm_gateway_hosts:
    - "172.30.255.42"
  campus_wifi_names:
    - "SZU_CTC&CMCC"
  timeout_seconds: 3
  max_test_urls: 3
  campus_source_networks:
    - "172.16.0.0/12"
  test_urls:
    - "http://captive.apple.com/hotspot-detect.html"
    - "http://www.baidu.com/"
    - "https://www.baidu.com/"

security:
  password_source: "keychain"
  keychain_service: "szu-netlogin"
  keychain_account: ""
"""


def main() -> None:
    if len(sys.argv) > 1 and sys.argv[1] == "--self-test":
        raise SystemExit(run_frozen_self_test())
    if len(sys.argv) > 1 and sys.argv[1] == CONTROL_DISPATCH_ARG:
        raise SystemExit(run_control_dispatch())

    root = tk.Tk()
    SzuDormWindowsApp(root)
    root.mainloop()


if __name__ == "__main__":
    main()
