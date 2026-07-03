"""Windows desktop client for SZU Dorm NetLogin."""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
import threading
import time
import traceback
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from queue import Empty, Queue
from typing import Any

import tkinter as tk
from tkinter import messagebox, simpledialog, ttk
from tkinter.scrolledtext import ScrolledText


if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from src.szu_netlogin.config import (  # noqa: E402
    ConfigError,
    DEFAULT_CONFIG_PATH,
    PROJECT_HOME_ENV,
    PROJECT_ROOT,
    load_config,
)
from src.szu_netlogin.logger import LOG_FILE, get_logger, redact_sensitive_text  # noqa: E402
from src.szu_netlogin.password_store import (  # noqa: E402
    describe_password_source,
    set_password,
)
from src.szu_netlogin.platform_paths import (  # noqa: E402
    open_path_with_default_app,
    run_subprocess_hidden,
)
from src.szu_netlogin.portal_detect import (  # noqa: E402
    NetworkStatus,
    classify_network_environment,
    probe_network,
)
from src.szu_netlogin.state import describe_pause_state, is_paused  # noqa: E402


APP_NAME = "SZU Dorm Login"
CONTROL_MODULE = "src.szu_netlogin.control"
CONTROL_DISPATCH_ARG = "--szu-netlogin-control"
STATUS_REFRESH_SECONDS = 30
WATCHDOG_INTERVAL_SECONDS = 1
AUTO_LOGIN_INITIAL_DELAY_SECONDS = 5
AUTO_LOGIN_BACKOFF_SECONDS = (120, 300, 600, 900)
USERNAME_PLACEHOLDER = "你的校园卡号，不要写密码"


@dataclass(frozen=True)
class DesktopStatusResult:
    paused: bool
    network_status: NetworkStatus
    config_error: str = ""
    network_probe_enabled: bool = True
    environment_label: str = ""
    auto_login_available: bool = True


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


class SzuDormWindowsApp:
    def __init__(self, root: tk.Tk) -> None:
        self.root = root
        self.logger = get_logger()
        self._messages: Queue[tuple[str, Any]] = Queue()
        self._status_lock = threading.Lock()
        self._command_lock = threading.Lock()
        self._refresh_in_progress = False
        self._command_in_progress = False
        self._network_probe_enabled = True
        self._last_status_result: DesktopStatusResult | None = None
        self._status_after_id: str | None = None
        self._auto_login_schedule = AutoLoginBackoff(
            AUTO_LOGIN_BACKOFF_SECONDS,
            AUTO_LOGIN_INITIAL_DELAY_SECONDS,
        )
        self._status_vars: dict[str, tk.StringVar] = {}
        self._command_buttons: list[ttk.Button] = []

        self._ensure_initial_config_file()
        self._build_ui()
        self.root.protocol("WM_DELETE_WINDOW", self._close)
        self.root.after(100, self.refresh_status)
        self.root.after(100, self._drain_messages)
        self.root.after(WATCHDOG_INTERVAL_SECONDS * 1000, self._watchdog_tick)

    def _build_ui(self) -> None:
        self.root.title(APP_NAME)
        self.root.minsize(760, 560)

        style = ttk.Style(self.root)
        try:
            style.theme_use("clam")
        except tk.TclError:
            pass
        style.configure("Title.TLabel", font=("Segoe UI", 16, "bold"))
        style.configure("StatusName.TLabel", foreground="#445")
        style.configure("StatusValue.TLabel", font=("Segoe UI", 10))

        main = ttk.Frame(self.root, padding=16)
        main.pack(fill=tk.BOTH, expand=True)
        main.columnconfigure(0, weight=1)
        main.rowconfigure(3, weight=1)

        ttk.Label(main, text="SZU Dorm Login", style="Title.TLabel").grid(
            row=0,
            column=0,
            sticky="w",
        )

        status_frame = ttk.LabelFrame(main, text="当前状态", padding=12)
        status_frame.grid(row=1, column=0, sticky="ew", pady=(12, 10))
        status_frame.columnconfigure(1, weight=1)
        self._add_status_row(status_frame, 0, "自动登录", "run_state")
        self._add_status_row(status_frame, 1, "暂停状态", "pause_state")
        self._add_status_row(status_frame, 2, "网络环境", "environment")
        self._add_status_row(status_frame, 3, "校园网出口", "internet")
        self._add_status_row(status_frame, 4, "宿舍网关", "gateway")
        self._add_status_row(status_frame, 5, "源 IP", "source_ip")
        self._add_status_row(status_frame, 6, "配置文件", "config")
        self._add_status_row(status_frame, 7, "更新时间", "updated_at")

        button_frame = ttk.Frame(main)
        button_frame.grid(row=2, column=0, sticky="ew", pady=(0, 10))
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
        self.password_button = self._add_button(button_frame, 1, 3, "修改密码", self.change_password)

        self.config_button = self._add_button(button_frame, 2, 0, "打开配置", self.open_config)
        self.log_button = self._add_button(button_frame, 2, 1, "打开日志", self.open_log)
        self.report_button = self._add_button(
            button_frame,
            2,
            2,
            "诊断报告",
            lambda: self._run_control_action(
                ["generate-diagnostic-report"],
                "生成诊断报告",
                timeout=60,
            ),
        )
        self.reset_pause_button = self._add_button(
            button_frame,
            2,
            3,
            "重置暂停",
            lambda: self._run_control_action(["reset-pause"], "重置暂停", timeout=30),
        )

        output_frame = ttk.LabelFrame(main, text="运行输出", padding=8)
        output_frame.grid(row=3, column=0, sticky="nsew")
        output_frame.rowconfigure(0, weight=1)
        output_frame.columnconfigure(0, weight=1)
        self.output = ScrolledText(output_frame, height=10, wrap=tk.WORD, state=tk.DISABLED)
        self.output.grid(row=0, column=0, sticky="nsew")

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
    ) -> ttk.Button:
        button = ttk.Button(parent, text=text, command=command)
        button.grid(row=row, column=column, sticky="ew", padx=4, pady=4)
        self._command_buttons.append(button)
        return button

    def refresh_status(self) -> None:
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
            paused = is_paused()
            config, config_error = self._load_config_for_status()
            network_status = probe_network(config) if config else NetworkStatus(False, False)
            environment = classify_network_environment(config, network_status)
            self._messages.put(
                (
                    "status",
                    DesktopStatusResult(
                        paused,
                        network_status,
                        config_error,
                        environment_label=environment.label,
                        auto_login_available=environment.auto_login_available,
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
        campus_label = "已连通" if result.network_status.campus_internet_ok else "未连通"
        gateway_label = "可达" if result.network_status.gateway_reachable else "不可达"
        config_label = str(DEFAULT_CONFIG_PATH) if not result.config_error else result.config_error

        self._status_vars["run_state"].set(run_label)
        self._status_vars["pause_state"].set(describe_pause_state())
        self._status_vars["environment"].set(result.environment_label or "网络环境未知")
        self._status_vars["internet"].set(campus_label)
        self._status_vars["gateway"].set(gateway_label)
        self._status_vars["source_ip"].set(result.network_status.source_ip or "-")
        self._status_vars["config"].set(config_label)
        self._status_vars["updated_at"].set(datetime.now().strftime("%Y-%m-%d %H:%M:%S"))
        self.pause_button.configure(text="恢复自动登录" if result.paused else "暂停自动登录")
        self.probe_button.configure(
            text="关闭联网探测" if self._network_probe_enabled else "开启联网探测"
        )

        if result.network_status.campus_internet_ok:
            self._auto_login_schedule.record_success()

        self._schedule_next_status_refresh()

    def _schedule_next_status_refresh(self) -> None:
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

        self.root.after(WATCHDOG_INTERVAL_SECONDS * 1000, self._watchdog_tick)

    def _run_control_action(
        self,
        args: list[str],
        label: str,
        timeout: int,
        show_dialog: bool = True,
        auto_login: bool = False,
    ) -> None:
        with self._command_lock:
            if self._command_in_progress:
                if show_dialog:
                    messagebox.showinfo(APP_NAME, "已有操作正在执行，请稍后再试。")
                return
            self._command_in_progress = True

        self._set_command_buttons_enabled(False)
        self._append_output(f"> {label}")
        threading.Thread(
            target=self._control_worker,
            args=(args, label, timeout, show_dialog, auto_login),
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
            result = run_control_process(args, timeout)
            self._messages.put(("command_result", (label, args, result, show_dialog, auto_login)))
        except Exception as exc:
            self._messages.put(("command_error", (label, exc, traceback.format_exc(), show_dialog)))

    def _finish_command(self) -> None:
        with self._command_lock:
            self._command_in_progress = False
        self._set_command_buttons_enabled(True)

    def _set_command_buttons_enabled(self, enabled: bool) -> None:
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

    def change_password(self) -> None:
        try:
            config = load_config()
        except ConfigError as exc:
            messagebox.showwarning(APP_NAME, f"配置检查失败：{exc}")
            return

        username = get_username(config)
        if not is_username_set(username):
            messagebox.showwarning(APP_NAME, "请先设置校园网账号。")
            return

        security = config.get("security") or {}
        if str(security.get("password_source", "env")) == "env":
            messagebox.showwarning(
                APP_NAME,
                f"当前密码来源是 {describe_password_source(config)}，请在系统环境变量中设置，"
                "或把 security.password_source 改为 keychain/private_file。",
            )
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

        try:
            set_password(config, password)
        except Exception as exc:
            messagebox.showerror(APP_NAME, f"保存密码失败：{exc}")
            return

        messagebox.showinfo(APP_NAME, f"密码已保存到 {describe_password_source(config)}。")
        self._append_output(f"密码已保存：{describe_password_source(config)}")
        self.refresh_status()

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
        while True:
            try:
                kind, payload = self._messages.get_nowait()
            except Empty:
                break

            if kind == "status":
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

            title, exc, formatted_traceback = payload
            self.logger.error("%s：%s\n%s", title, exc, formatted_traceback)
            self._append_output(f"{title}：{exc}")

        self.root.after(100, self._drain_messages)

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
        self._network_probe_enabled = False
        if self._status_after_id is not None:
            try:
                self.root.after_cancel(self._status_after_id)
            except tk.TclError:
                pass
        self.root.destroy()


def run_control_process(args: list[str], timeout: int) -> subprocess.CompletedProcess[str]:
    PROJECT_ROOT.mkdir(parents=True, exist_ok=True)
    try:
        return run_subprocess_hidden(
            [*build_control_command(), *args],
            cwd=PROJECT_ROOT,
            env=build_control_env(),
            check=False,
            capture_output=True,
            text=True,
            stdin=subprocess.DEVNULL,
            timeout=timeout,
        )
    except subprocess.TimeoutExpired as exc:
        raise RuntimeError(f"命令超时：{mask_command(args)}") from exc


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
    if not result.auto_login_available:
        return False
    return result.network_status.maybe_need_login


def is_non_campus_status(result: DesktopStatusResult | None) -> bool:
    if result is None or result.config_error or not result.network_probe_enabled:
        return False
    return (not result.auto_login_available) or not result.network_status.gateway_reachable


def auto_login_state_label(paused: bool, result: DesktopStatusResult) -> str:
    if not result.network_probe_enabled:
        return "联网状态探测已关闭"
    if paused:
        return "已暂停"
    if is_non_campus_status(result):
        return "非宿舍网络，自动登录停用"
    return "运行中"


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


DEFAULT_CONFIG_TEMPLATE = """auth:
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
  dorm_gateway_hosts:
    - "172.30.255.42"
  campus_wifi_names:
    - "SZU_CTC&CMCC"
  timeout_seconds: 3
  max_test_urls: 3
  campus_source_cidrs:
    - "172.16.0.0/12"
  allow_system_fallback: true
  test_urls:
    - "http://captive.apple.com/hotspot-detect.html"
    - "http://www.baidu.com/"
    - "https://www.baidu.com/"

security:
  password_source: "keychain"
  password_env_name: "SZU_NET_PASSWORD"
  keychain_service: "szu-netlogin"
  keychain_account: ""
  password_file: "~/.szu-netlogin/password.yaml"
"""


def main() -> None:
    if len(sys.argv) > 1 and sys.argv[1] == CONTROL_DISPATCH_ARG:
        raise SystemExit(run_control_dispatch())

    root = tk.Tk()
    SzuDormWindowsApp(root)
    root.mainloop()


if __name__ == "__main__":
    main()
