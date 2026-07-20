"""Control commands shared by the Windows desktop client and CLI."""

from __future__ import annotations

import argparse
import getpass
import json
import plistlib
import subprocess
import sys
from importlib.util import find_spec
from pathlib import Path
from typing import Any

from .config import ConfigError, DEFAULT_CONFIG_PATH, PROJECT_HOME_ENV, PROJECT_ROOT, load_config
from .logger import LOG_FILE, get_logger
from .password_store import describe_password_source, has_password, set_password
from .platform_paths import open_path_with_default_app
from .portal_detect import (
    NetworkStatus,
    classify_network_environment,
    probe_gateway,
    probe_internet,
)
from .state import PAUSE_FLAG_FILE, describe_pause_state, is_paused, pause, resume


LAUNCHAGENT_PLIST = Path.home() / "Library" / "LaunchAgents" / "com.szu-netlogin.dorm-drcom.plist"
USERNAME_PLACEHOLDER = "你的校园卡号，不要写密码"


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="深圳大学宿舍区校园网控制命令")
    subparsers = parser.add_subparsers(dest="command", required=True)

    subparsers.add_parser("pause", help="暂停自动登录")
    subparsers.add_parser("resume", help="恢复自动登录")
    subparsers.add_parser("status", help="查看当前状态")
    subparsers.add_parser("login-now", help="立即登录")
    subparsers.add_parser("check-and-login", help="检查门户会话，确认离线时自动登录")
    subparsers.add_parser("diagnose", help="诊断当前网络状态")
    subparsers.add_parser("generate-diagnostic-report", help="生成一键诊断报告")

    logout_parser = subparsers.add_parser("logout", help="退出校园网账号并暂停自动登录")
    logout_parser.add_argument(
        "--pause-for",
        choices=("manual", "30m", "next-boot"),
        default="manual",
        help="退出后自动登录保持暂停的时长",
    )

    username_parser = subparsers.add_parser("set-username", help="修改 config.yaml 里的学号")
    username_parser.add_argument("username", help="校园卡号/学号")

    subparsers.add_parser("set-password", help="按 config.yaml 的密码来源保存密码")
    subparsers.add_parser("reset-pause", help="重置暂停状态")
    subparsers.add_parser("check-dependencies", help="检查常见依赖是否可用")
    subparsers.add_parser("set-project-home-env", help="写入 launchctl SZU_NETLOGIN_HOME")
    subparsers.add_parser("open-config", help="打开 config.yaml")
    subparsers.add_parser("open-log", help="打开日志文件")
    subparsers.add_parser("open-project", help="打开项目目录")

    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)

    if args.command == "pause":
        try:
            pause()
        except OSError as exc:
            print(f"暂停自动登录失败：无法写入暂停标记 {PAUSE_FLAG_FILE}：{exc}")
            return 1
        if not is_paused():
            print("暂停自动登录失败：暂停标记没有写入。")
            return 1
        get_logger().info("已暂停自动登录：%s", PAUSE_FLAG_FILE)
        print("已暂停自动登录")
        print(f"暂停标记：{PAUSE_FLAG_FILE}")
        return 0

    if args.command == "resume":
        try:
            resume()
        except OSError as exc:
            print(f"恢复自动登录失败：无法删除暂停标记 {PAUSE_FLAG_FILE}：{exc}")
            return 1
        if is_paused():
            print("恢复自动登录失败：暂停标记仍然存在。")
            return 1
        get_logger().info("已恢复自动登录：%s", PAUSE_FLAG_FILE)
        print("已恢复自动登录")
        return 0

    if args.command == "status":
        return print_status()

    if args.command == "login-now":
        return login_now()

    if args.command == "check-and-login":
        return check_and_login()

    if args.command == "diagnose":
        return diagnose_now()

    if args.command == "generate-diagnostic-report":
        return generate_diagnostic_report()

    if args.command == "logout":
        return logout_now(args.pause_for)

    if args.command == "set-username":
        return set_username(args.username)

    if args.command == "set-password":
        return set_password_interactive()

    if args.command == "reset-pause":
        return reset_pause()

    if args.command == "check-dependencies":
        return check_dependencies()

    if args.command == "set-project-home-env":
        return set_project_home_env()

    if args.command == "open-config":
        return open_path(DEFAULT_CONFIG_PATH, must_exist=True)

    if args.command == "open-log":
        return open_path(LOG_FILE, must_exist=True)

    if args.command == "open-project":
        return open_path(PROJECT_ROOT, must_exist=True)

    print("未知命令。")
    return 2


def print_status() -> int:
    config_exists = DEFAULT_CONFIG_PATH.exists()
    config, config_error = _load_config_for_status()
    username = _get_username(config)
    launchagents = find_auto_login_launchagents() if sys.platform == "darwin" else []
    network_status = probe_gateway(config) if config else NetworkStatus(False, False)
    portal_session = "unknown"
    if config and _is_username_set(username):
        from .dorm_drcom_client import DormDrcomClient

        fact = DormDrcomClient(config).session_fact(username, network_status.source_ip)
        portal_session = fact.state
        if fact.matches(username, network_status.source_ip):
            network_status = probe_internet(config, network_status)

    print("SZU Netlogin 状态")
    print(f"当前暂停状态：{describe_pause_state()}")
    print(f"校园网门户会话：{portal_session}")
    print(f"默认网络出口是否可用：{_yes_no(network_status.campus_internet_ok)}")
    print(f"宿舍区网关是否可达：{_yes_no(network_status.gateway_reachable)}")
    print(f"当前网络环境：{classify_network_environment(config, network_status).label}")
    print(f"源 IP：{network_status.source_ip or '-'}")
    print(f"config.yaml 是否存在：{_yes_no(config_exists)}")
    print(f"是否已设置账号：{_yes_no(_is_username_set(username))}")
    print(f"是否已设置密码：{_yes_no(has_password(config) if config and _is_username_set(username) else False)}")
    if sys.platform == "darwin":
        print(f"LaunchAgent 是否可能已安装：{_yes_no(LAUNCHAGENT_PLIST.exists() or bool(launchagents))}")
        print(f"自动登录 LaunchAgent 数量：{len(launchagents)}")
        for plist_path in launchagents:
            print(f"- {plist_path}")
        if len(launchagents) > 1:
            print("提醒：检测到多个后台自动登录 LaunchAgent，请只保留一个。不会自动删除任何 plist。")
    else:
        print("后台自动检查：Windows 桌面客户端打开时运行")

    if config_error:
        print(f"配置提示：{config_error}")

    return 0


def login_now() -> int:
    from . import login

    if is_paused():
        if sys.stdin.isatty():
            answer = input("当前已暂停，是否仍然手动登录？[y/N] ").strip().lower()
            if answer not in ("y", "yes"):
                print("已取消手动登录，暂停状态不改变。")
                return 0
        else:
            print("当前已暂停；非交互模式将继续手动登录，暂停状态不改变。")

    old_argv = sys.argv[:]
    sys.argv = [old_argv[0]]
    try:
        return login.main()
    finally:
        sys.argv = old_argv


def check_and_login() -> int:
    from . import login

    old_argv = sys.argv[:]
    sys.argv = [old_argv[0], "--check-and-login"]
    try:
        return login.main()
    finally:
        sys.argv = old_argv


def diagnose_now() -> int:
    from . import diagnose

    return diagnose.main()


def generate_diagnostic_report() -> int:
    from .diagnostic_report import create_diagnostic_report

    report_path = create_diagnostic_report()
    print(f"诊断报告已生成：{report_path}")
    return 0


def logout_now(pause_for: str = "manual") -> int:
    from .dorm_drcom_client import DormDrcomClient

    try:
        _pause_for_logout(pause_for)
    except OSError as exc:
        print(f"退出前暂停自动登录失败，未发送注销请求：无法写入暂停标记 {PAUSE_FLAG_FILE}：{exc}")
        return 1
    if not is_paused():
        print("退出前暂停自动登录失败，未发送注销请求：暂停标记没有写入。")
        return 1
    logger = get_logger()
    logger.info("已先暂停自动登录，再尝试退出校园网账号")
    print("已先暂停自动登录，再尝试退出校园网账号")
    print(f"暂停策略：{describe_pause_state()}")
    print(f"暂停标记：{PAUSE_FLAG_FILE}")

    try:
        config = load_config()
    except ConfigError as exc:
        print(f"配置检查失败，未发送注销请求：{exc}")
        print("自动登录会保持暂停，避免自动重登。")
        return 2

    username = _get_username(config)
    if not _is_username_set(username):
        print("请先设置账号，未发送注销请求。")
        print("自动登录会保持暂停，避免自动重登。")
        return 2

    result = DormDrcomClient(config).logout(username)
    if result.reason == "logout_url_not_configured":
        print("尚未配置退出接口，请先抓取 logout 请求或填写 config.yaml 的 auth.logout_url")
        print("自动登录仍保持暂停，避免马上重新登录。")
        return 2

    if result.status == "success":
        if result.reason == "already_logged_out":
            print("退出结果：当前没有可退出的校园网会话。")
            print(f"自动登录：{describe_pause_state()}")
            return 0

        if result.reason in ("portal_logout_verified", "unbind_verified"):
            print("退出结果：门户会话已确认离线。")
            print(f"自动登录：{describe_pause_state()}")
            return 0

        if _verify_campus_logged_out(config):
            print("退出结果：已确认断开。")
            print(f"自动登录：{describe_pause_state()}")
            return 0

        print("退出结果：接口返回成功但仍可上网。")
        print(f"自动登录：{describe_pause_state()}")
        return 1
    if result.status == "failed":
        if _verify_campus_logged_out(config):
            print("退出结果：接口返回失败，但已确认断开。")
            print(f"自动登录：{describe_pause_state()}")
            return 0
        print(f"退出校园网账号失败：{_logout_failure_reason(result.reason)}")
        print(f"自动登录：{describe_pause_state()}")
        return 1

    if _verify_campus_logged_out(config):
        print("退出结果：结果不确定，但已确认断开。")
        print(f"自动登录：{describe_pause_state()}")
        return 0

    print(f"退出结果：结果不确定。{_logout_failure_reason(result.reason)}")
    print(f"自动登录：{describe_pause_state()}")
    return 1


def set_username(username: str) -> int:
    username = username.strip()
    if not username:
        print("学号不能为空。")
        return 2

    if not DEFAULT_CONFIG_PATH.exists():
        print(f"找不到 config.yaml：{DEFAULT_CONFIG_PATH}")
        return 2

    text = DEFAULT_CONFIG_PATH.read_text(encoding="utf-8")
    updated = _replace_username(text, username)
    DEFAULT_CONFIG_PATH.write_text(updated, encoding="utf-8")
    print("已更新 config.yaml 里的 user.username。")
    return 0


def set_password_interactive() -> int:
    try:
        config = load_config()
    except ConfigError as exc:
        print(f"配置检查失败：{exc}")
        return 2

    username = _get_username(config)
    if not _is_username_set(username):
        print("请先设置账号：python3 -m src.szu_netlogin.control set-username 学号")
        return 2

    security = config.get("security") or {}
    if str(security.get("password_source", "env")) == "env":
        print(
            f"保存密码失败：当前密码来源是 {describe_password_source(config)}，"
            "请在 shell/LaunchAgent 中设置它，或把 security.password_source 改为 keychain/private_file。"
        )
        return 2

    password = getpass.getpass("请输入校园网密码（不会显示）：")
    if not password:
        print("密码不能为空，未保存。")
        return 2

    password_source_label = describe_password_source(config)
    try:
        set_password(config, password)
    except ValueError as exc:
        print(f"保存密码失败：{exc}")
        return 2
    except Exception as exc:
        print(f"保存密码失败：{exc}")
        return 1

    print(f"密码已保存到 {password_source_label}。")
    return 0


def reset_pause() -> int:
    try:
        resume()
    except OSError as exc:
        print(f"重置暂停状态失败：{exc}")
        return 1

    if is_paused():
        print("重置暂停状态失败：暂停标记仍然存在。")
        return 1

    print("已重置暂停状态，自动登录已恢复。")
    return 0


def check_dependencies() -> int:
    checks = [
        ("requests", "必要依赖"),
        ("urllib3", "必要依赖"),
        ("keyring", "系统凭据库密码依赖"),
    ]
    required_modules = {"requests", "urllib3"}
    if sys.platform == "darwin":
        checks.extend(
            [
                ("rumps", "状态栏依赖"),
                ("objc", "状态栏依赖"),
                ("Foundation", "状态栏依赖"),
                ("AppKit", "状态栏依赖"),
            ]
        )
        required_modules.update(("rumps", "objc", "Foundation", "AppKit"))

    missing: list[str] = []

    print("依赖检查")
    for module_name, label in checks:
        available = find_spec(module_name) is not None
        print(f"- {module_name}（{label}）：{'可用' if available else '缺失'}")
        if not available and module_name in required_modules:
            missing.append(module_name)

    if missing:
        print("依赖检查失败：" + ", ".join(missing))
        return 1

    print("依赖检查通过。")
    return 0


def set_project_home_env() -> int:
    if sys.platform != "darwin":
        print(f"{PROJECT_HOME_ENV} 的 launchctl 写入仅用于 macOS LaunchAgent。")
        return 2

    try:
        result = subprocess.run(
            ["launchctl", "setenv", PROJECT_HOME_ENV, str(PROJECT_ROOT)],
            check=False,
            capture_output=True,
            text=True,
            timeout=10,
        )
    except OSError as exc:
        print(f"写入 {PROJECT_HOME_ENV} 失败：{exc}")
        return 1

    if result.returncode != 0:
        output = (result.stderr or result.stdout).strip()
        print(f"写入 {PROJECT_HOME_ENV} 失败：{output or result.returncode}")
        return 1

    print(f"已写入 {PROJECT_HOME_ENV}={PROJECT_ROOT}")
    return 0


def open_path(path: Path, must_exist: bool) -> int:
    if must_exist and not path.exists():
        print(f"路径不存在：{path}")
        return 2

    try:
        open_path_with_default_app(path)
    except OSError as exc:
        print(f"打开失败：{exc}")
        return 1

    print(f"已打开：{path}")
    return 0


def find_auto_login_launchagents() -> list[Path]:
    launchagents_dir = Path.home() / "Library" / "LaunchAgents"
    if not launchagents_dir.exists():
        return []

    matches: list[Path] = []
    for plist_path in sorted(launchagents_dir.glob("*.plist")):
        try:
            with plist_path.open("rb") as file:
                payload = plistlib.load(file)
        except (OSError, plistlib.InvalidFileException, ValueError):
            continue

        label = str(payload.get("Label") or "")
        arguments = payload.get("ProgramArguments")
        if not isinstance(arguments, list):
            arguments = []

        haystack = "\n".join([label, *(str(argument) for argument in arguments)]).lower()
        is_this_project = "src.szu_netlogin.login" in haystack and "--check-and-login" in haystack
        is_old_szu_autologin = "szu_auto_login" in haystack or "com.szu.autologin" in haystack

        if is_this_project or is_old_szu_autologin:
            matches.append(plist_path)

    return matches


def _load_config_for_status() -> tuple[dict[str, Any] | None, str]:
    try:
        return load_config(), ""
    except ConfigError as exc:
        return None, str(exc)


def _get_username(config: dict[str, Any] | None) -> str:
    if not config:
        return ""
    return str((config.get("user") or {}).get("username") or "").strip()


def _is_username_set(username: str) -> bool:
    return bool(username and username != USERNAME_PLACEHOLDER)


def _pause_for_logout(pause_for: str) -> None:
    if pause_for == "30m":
        pause(minutes=30)
        return
    if pause_for == "next-boot":
        pause(until_next_boot=True)
        return
    pause()


def _logout_failure_reason(reason: str) -> str:
    if reason == "logout_url_invalid":
        return "auth.logout_url 不是有效的 HTTP 地址。"
    if reason == "request_exception":
        return "请求退出接口时发生网络异常。"
    if reason == "terminal_ip_not_found":
        return "无法从门户页或在线列表确定当前终端 IP。"
    if reason == "source_ip_unverified":
        return "未确认处于校园网源地址，未发送注销请求。"
    if reason == "session_state_unknown":
        return "门户会话状态暂时无法确认，未发送注销请求。"
    if reason == "logout_not_confirmed":
        return "注销接口已调用，但门户仍报告会话在线。"
    if reason == "session_verification_unavailable":
        return "注销后无法读取门户会话状态。"
    if reason == "server_failed":
        return "退出接口返回失败。"
    if reason == "server_unknown":
        return "退出接口响应无法判断。"
    if reason.startswith("http_status_"):
        return f"HTTP 状态码 {reason.removeprefix('http_status_')}。"
    return reason or "未知原因。"


def _verify_campus_logged_out(config: dict[str, Any]) -> bool:
    try:
        from .dorm_drcom_client import DormDrcomClient

        username = _get_username(config)
        status = probe_gateway(config)
        if not status.gateway_reachable or not _is_username_set(username):
            return False
        fact = DormDrcomClient(config).session_fact(username, status.source_ip)
    except Exception as exc:
        get_logger().info("退出后校园网状态确认失败：%s", exc)
        return False
    # VPN/proxy reachability is intentionally irrelevant here.  Only the
    # portal's own session fact can confirm logout.
    return fact.state == "offline"


def _replace_username(text: str, username: str) -> str:
    lines = text.splitlines(keepends=True)
    in_user_section = False
    user_section_index: int | None = None
    new_value = json.dumps(username, ensure_ascii=False)

    for index, line in enumerate(lines):
        stripped = line.strip()
        indent = len(line) - len(line.lstrip(" "))

        if indent == 0 and stripped == "user:":
            in_user_section = True
            user_section_index = index
            continue

        if indent == 0 and stripped and not stripped.startswith("#"):
            in_user_section = False

        if in_user_section and indent == 2 and stripped.startswith("username:"):
            newline = "\n" if line.endswith("\n") else ""
            lines[index] = f"  username: {new_value}{newline}"
            return "".join(lines)

    if user_section_index is None:
        separator = "" if not text or text.endswith("\n") else "\n"
        return f"{text}{separator}user:\n  username: {new_value}\n"

    insert_at = user_section_index + 1
    lines.insert(insert_at, f"  username: {new_value}\n")
    return "".join(lines)


def _yes_no(value: bool) -> str:
    return "是" if value else "否"


if __name__ == "__main__":
    raise SystemExit(main())
