"""Control commands for the future macOS status bar UI."""

from __future__ import annotations

import argparse
import getpass
import json
import plistlib
import subprocess
import sys
from pathlib import Path
from typing import Any

from .config import ConfigError, DEFAULT_CONFIG_PATH, PROJECT_ROOT, load_config
from .logger import LOG_FILE, get_logger
from .password_store import describe_password_source, has_password, set_password
from .portal_detect import NetworkStatus, probe_network
from .state import PAUSE_FLAG_FILE, is_paused, pause, resume


LAUNCHAGENT_PLIST = Path.home() / "Library" / "LaunchAgents" / "com.szu-netlogin.dorm-drcom.plist"
USERNAME_PLACEHOLDER = "你的校园卡号，不要写密码"


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="深圳大学宿舍区校园网控制命令")
    subparsers = parser.add_subparsers(dest="command", required=True)

    subparsers.add_parser("pause", help="暂停自动登录")
    subparsers.add_parser("resume", help="恢复自动登录")
    subparsers.add_parser("status", help="查看当前状态")
    subparsers.add_parser("login-now", help="立即登录")
    subparsers.add_parser("check-and-login", help="检查校园网出口，不通时自动登录")
    subparsers.add_parser("diagnose", help="诊断当前网络状态")
    subparsers.add_parser("logout", help="退出校园网账号并暂停自动登录")

    username_parser = subparsers.add_parser("set-username", help="修改 config.yaml 里的学号")
    username_parser.add_argument("username", help="校园卡号/学号")

    subparsers.add_parser("set-password", help="保存密码到 macOS Keychain")
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

    if args.command == "logout":
        return logout_now()

    if args.command == "set-username":
        return set_username(args.username)

    if args.command == "set-password":
        return set_password_interactive()

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
    launchagents = find_auto_login_launchagents()
    network_status = probe_network(config) if config else NetworkStatus(False, False)

    print("SZU Netlogin 状态")
    print(f"当前是否暂停：{_yes_no(is_paused())}")
    print(f"外网是否可用：{_yes_no(network_status.campus_internet_ok)}")
    print(f"宿舍区网关是否可达：{_yes_no(network_status.gateway_reachable)}")
    print(f"config.yaml 是否存在：{_yes_no(config_exists)}")
    print(f"是否已设置账号：{_yes_no(_is_username_set(username))}")
    print(f"是否已设置密码：{_yes_no(has_password(config) if config and _is_username_set(username) else False)}")
    print(f"LaunchAgent 是否可能已安装：{_yes_no(LAUNCHAGENT_PLIST.exists() or bool(launchagents))}")
    print(f"自动登录 LaunchAgent 数量：{len(launchagents)}")
    for plist_path in launchagents:
        print(f"- {plist_path}")
    if len(launchagents) > 1:
        print("提醒：检测到多个后台自动登录 LaunchAgent，请只保留一个。不会自动删除任何 plist。")

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


def logout_now() -> int:
    from .dorm_drcom_client import DormDrcomClient

    try:
        pause()
    except OSError as exc:
        print(f"退出前暂停自动登录失败，未发送注销请求：无法写入暂停标记 {PAUSE_FLAG_FILE}：{exc}")
        return 1
    if not is_paused():
        print("退出前暂停自动登录失败，未发送注销请求：暂停标记没有写入。")
        return 1
    logger = get_logger()
    logger.info("已先暂停自动登录，再尝试退出校园网账号")
    print("已先暂停自动登录，再尝试退出校园网账号")
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
            print("当前没有可退出的校园网会话，自动登录保持暂停")
            return 0

        if _verify_campus_logged_out(config):
            print("已退出校园网账号，校园网出口已断开，自动登录保持暂停")
        else:
            print("已退出校园网账号，自动登录保持暂停")
        return 0
    if result.status == "failed":
        if _verify_campus_logged_out(config):
            print("退出接口返回失败，但校园网出口已经断开；按已退出处理。")
            print("自动登录仍保持暂停，避免马上重新登录。")
            return 0
        print(f"退出校园网账号失败：{_logout_failure_reason(result.reason)}")
        print("自动登录仍保持暂停，避免马上重新登录。")
        return 1

    if _verify_campus_logged_out(config):
        print("退出接口结果不确定，但校园网出口已经断开；按已退出处理。")
        print("自动登录仍保持暂停，避免马上重新登录。")
        return 0

    print(f"退出校园网账号结果不确定：{_logout_failure_reason(result.reason)}")
    print("自动登录仍保持暂停，避免马上重新登录。")
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

    password = getpass.getpass("请输入校园网密码（不会显示）：")
    if not password:
        print("密码不能为空，未保存。")
        return 2

    try:
        set_password(config, password)
    except Exception as exc:
        print(f"保存到 macOS Keychain 失败：{exc}")
        return 1

    print("密码已保存到 macOS Keychain。")
    security = config.get("security") or {}
    if str(security.get("password_source", "env")) != "keychain":
        print(f"提醒：当前配置的密码来源是 {describe_password_source(config)}，登录时不会读取刚保存的 Keychain 密码。")
    return 0


def open_path(path: Path, must_exist: bool) -> int:
    if must_exist and not path.exists():
        print(f"路径不存在：{path}")
        return 2

    try:
        subprocess.run(["open", str(path)], check=False)
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


def _logout_failure_reason(reason: str) -> str:
    if reason == "logout_url_invalid":
        return "auth.logout_url 不是有效的 HTTP 地址。"
    if reason == "request_exception":
        return "请求退出接口时发生网络异常。"
    if reason == "server_failed":
        return "退出接口返回失败。"
    if reason == "server_unknown":
        return "退出接口响应无法判断。"
    if reason.startswith("http_status_"):
        return f"HTTP 状态码 {reason.removeprefix('http_status_')}。"
    return reason or "未知原因。"


def _verify_campus_logged_out(config: dict[str, Any]) -> bool:
    try:
        status = probe_network(config)
    except Exception as exc:
        get_logger().info("退出后校园网状态确认失败：%s", exc)
        return False
    return status.gateway_reachable and not status.campus_internet_ok


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
        ending = "\n" if text.endswith("\n") else ""
        return f"{text}{ending}user:\n  username: {new_value}\n"

    insert_at = user_section_index + 1
    lines.insert(insert_at, f"  username: {new_value}\n")
    return "".join(lines)


def _yes_no(value: bool) -> str:
    return "是" if value else "否"


if __name__ == "__main__":
    raise SystemExit(main())
