"""macOS menu bar client for the SZU dorm netlogin control layer."""

from __future__ import annotations

import logging
import os
import subprocess
import sys
import traceback
from datetime import datetime
from pathlib import Path
from typing import Any

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
    from src.szu_netlogin.config import (
        ConfigError,
        DEFAULT_CONFIG_PATH,
        PROJECT_HOME_ENV,
        PROJECT_ROOT,
        load_config,
    )
    from src.szu_netlogin.password_store import set_password
    from src.szu_netlogin.portal_detect import check_gateway_reachable, check_internet
    from src.szu_netlogin.state import is_paused
else:
    from .config import (
        ConfigError,
        DEFAULT_CONFIG_PATH,
        PROJECT_HOME_ENV,
        PROJECT_ROOT,
        load_config,
    )
    from .password_store import set_password
    from .portal_detect import check_gateway_reachable, check_internet
    from .state import is_paused

try:
    import rumps
except Exception as exc:  # pragma: no cover - exercised on machines missing GUI deps
    rumps = None  # type: ignore[assignment]
    RUMPS_IMPORT_ERROR: Exception | None = exc
else:
    RUMPS_IMPORT_ERROR = None


MENUBAR_LOG_FILE = PROJECT_ROOT / "logs" / "menubar.log"
MENUBAR_ERR_LOG_FILE = Path.home() / "Library" / "Logs" / "szu-netlogin" / "menubar-err.log"
CONTROL_MODULE = "src.szu_netlogin.control"
USERNAME_PLACEHOLDER = "你的校园卡号，不要写密码"
RumpsAppBase = rumps.App if rumps is not None else object


def get_menubar_logger() -> logging.Logger:
    MENUBAR_LOG_FILE.parent.mkdir(parents=True, exist_ok=True)
    MENUBAR_ERR_LOG_FILE.parent.mkdir(parents=True, exist_ok=True)

    logger = logging.getLogger("szu_netlogin_menubar")
    logger.setLevel(logging.INFO)
    logger.propagate = False

    if not any(getattr(handler, "baseFilename", "") == str(MENUBAR_LOG_FILE) for handler in logger.handlers):
        handler = logging.FileHandler(MENUBAR_LOG_FILE, encoding="utf-8")
        handler.setFormatter(logging.Formatter("%(asctime)s [%(levelname)s] %(message)s"))
        logger.addHandler(handler)

    if not any(
        getattr(handler, "baseFilename", "") == str(MENUBAR_ERR_LOG_FILE)
        for handler in logger.handlers
    ):
        error_handler = logging.FileHandler(MENUBAR_ERR_LOG_FILE, encoding="utf-8")
        error_handler.setLevel(logging.ERROR)
        error_handler.setFormatter(logging.Formatter("%(asctime)s [%(levelname)s] %(message)s"))
        logger.addHandler(error_handler)

    return logger


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
        self._warn_if_config_missing()
        self._warn_if_optional_dependencies_missing()

        self.status_item = rumps.MenuItem("状态：正在检查...")
        self.login_item = rumps.MenuItem("立即登录", callback=self.login_now)
        self.logout_item = rumps.MenuItem("退出校园网账号", callback=self.logout_now)
        self.logout_hint_item = rumps.MenuItem("退出账号会自动暂停自动登录，避免马上重新登录")
        self.pause_item = rumps.MenuItem("暂停自动登录", callback=self.toggle_pause)
        self.username_item = rumps.MenuItem("修改账号", callback=self.change_username)
        self.password_item = rumps.MenuItem("修改密码", callback=self.change_password)
        self.open_config_item = rumps.MenuItem("打开配置文件", callback=self.open_config)
        self.open_log_item = rumps.MenuItem("打开日志", callback=self.open_log)
        self.install_item = rumps.MenuItem("安装开机自启", callback=self.install_launchagent)
        self.uninstall_item = rumps.MenuItem("卸载开机自启", callback=self.uninstall_launchagent)
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
                self.username_item,
                self.password_item,
                self.open_config_item,
                self.open_log_item,
                self.install_item,
                self.uninstall_item,
                self.quit_item,
            ],
            quit_button=None,
        )

        self.timer = rumps.Timer(self.refresh_status, 30)
        self.timer.start()
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

        try:
            import keyring  # type: ignore[import-not-found]  # noqa: F401
        except Exception as exc:
            missing_messages.append(f"keyring：{exc}")

        if not missing_messages:
            return

        message = "以下依赖缺失，部分功能可能不可用：\n" + "\n".join(missing_messages)
        self.logger.error("依赖缺失：%s", "；".join(missing_messages))
        rumps.alert("SZU Dorm 依赖缺失", message)

    def refresh_status(self, _sender: Any) -> None:
        try:
            config, config_error = self._load_config_for_status()
            paused = is_paused()
            online = check_internet(config)
            gateway_reachable = check_gateway_reachable(config)

            run_label = "已暂停" if paused else "运行中"
            online_label = "已联网" if online else "未联网"
            gateway_label = "网关可达" if gateway_reachable else "网关不可达"
            self.status_item.title = f"状态：{run_label}｜{online_label}｜{gateway_label}"
            self.pause_item.title = "恢复自动登录" if paused else "暂停自动登录"

            message = (
                f"状态刷新：{run_label}，{online_label}，{gateway_label}，"
                f"时间={datetime.now().strftime('%H:%M:%S')}"
            )
            if config_error:
                message += f"，配置提示={config_error}"
            self.logger.info(message)
        except Exception as exc:
            self._handle_exception("刷新状态失败", exc)

    def login_now(self, _sender: Any) -> None:
        try:
            self.logger.info("用户点击：立即登录")
            result = self._run_control_process(["login-now"], timeout=60)
            output = f"{result.stdout}\n{result.stderr}"

            if result.returncode == 0:
                title = "登录成功"
            elif "不确定" in output:
                title = "结果不确定"
            else:
                title = "登录失败"

            self.logger.info("立即登录完成：returncode=%s result=%s", result.returncode, title)
            rumps.notification("SZU Dorm", title, "详情可查看日志。")
            if result.returncode != 0:
                rumps.alert(title, short_output(result) or "详情可查看日志。")
            self.refresh_status(None)
        except Exception as exc:
            self._handle_exception("立即登录失败", exc)

    def logout_now(self, _sender: Any) -> None:
        try:
            self.logger.info("用户点击：退出校园网账号")
            result = self._run_control_process(["logout"], timeout=30)
            output = f"{result.stdout}\n{result.stderr}"

            if result.returncode == 0:
                title = "已退出校园网账号"
            elif "不确定" in output:
                title = "结果不确定"
            else:
                title = "退出失败"

            self.logger.info("退出完成：returncode=%s result=%s", result.returncode, title)
            rumps.notification("SZU Dorm", title, "自动登录已暂停，避免马上重新登录。")
            if result.returncode != 0:
                rumps.alert(title, short_output(result) or "详情可查看日志。")
            self.refresh_status(None)
        except Exception as exc:
            self._handle_exception("退出校园网账号失败", exc)

    def toggle_pause(self, _sender: Any) -> None:
        try:
            command = "resume" if is_paused() else "pause"
            self.logger.info("用户点击：%s", "恢复自动登录" if command == "resume" else "暂停自动登录")
            self._run_control([command], timeout=20)
            if command == "resume":
                result = self._run_control_process(["check-and-login"], timeout=80)
                if result.returncode == 0:
                    rumps.notification("SZU Dorm", "已恢复自动登录", "已立即检查网络状态。")
                else:
                    rumps.alert("自动登录检查失败", short_output(result) or "详情可查看日志。")
            else:
                rumps.notification("SZU Dorm", "已暂停自动登录", "状态已刷新。")
            self.refresh_status(None)
        except Exception as exc:
            self._handle_exception("切换暂停状态失败", exc)

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

            set_password(config, password)
            self.logger.info("密码已保存到 macOS Keychain：username=%s", mask_username(username))
            security = config.get("security") or {}
            if str(security.get("password_source", "env")) != "keychain":
                source = str(security.get("password_source", "env"))
                rumps.alert(
                    "密码已保存，但当前不会读取",
                    f"密码已保存到 macOS Keychain，但 config.yaml 当前 password_source 是 {source}。"
                    "请改为 keychain，或改用对应的密码来源。",
                )
            else:
                rumps.notification("SZU Dorm", "密码已保存", "已保存到 macOS Keychain。")
            self.refresh_status(None)
        except Exception as exc:
            self._handle_exception("修改密码失败", exc)

    def open_config(self, _sender: Any) -> None:
        self._run_simple_control_action("open-config", "打开配置文件失败")

    def open_log(self, _sender: Any) -> None:
        self._run_simple_control_action("open-log", "打开日志失败")

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

    def quit_app(self, _sender: Any) -> None:
        self.logger.info("用户退出状态栏客户端。")
        rumps.quit_application()

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
        command = ["python3", "-m", CONTROL_MODULE, *args]
        try:
            env = os.environ.copy()
            env.setdefault(PROJECT_HOME_ENV, str(PROJECT_ROOT))
            result = subprocess.run(
                command,
                cwd=PROJECT_ROOT,
                env=env,
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
