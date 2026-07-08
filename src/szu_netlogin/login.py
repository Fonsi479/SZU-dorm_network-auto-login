"""Command line entry point for dorm Dr.COM login."""

from __future__ import annotations

import argparse
import os
from typing import Any, TextIO

from .config import ConfigError, get_password_env_name, load_config
from .dorm_drcom_client import DormDrcomClient
from .logger import LOG_FILE, get_logger
from .password_store import describe_password_source, get_password, has_password
from .platform_paths import get_user_log_dir
from .portal_detect import classify_network_environment, probe_network
from .state import is_paused

try:
    import fcntl
except ImportError:  # pragma: no cover - Windows
    fcntl = None  # type: ignore[assignment]

try:
    import msvcrt
except ImportError:  # pragma: no cover - POSIX
    msvcrt = None  # type: ignore[assignment]


LOCK_FILE = get_user_log_dir() / "szu-dorm-drcom.lock"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="深圳大学宿舍区校园网 Dr.COM 自动登录")
    parser.add_argument("--dry-run", action="store_true", help="只检查配置，不发起登录请求")
    parser.add_argument(
        "--check-and-login",
        action="store_true",
        help="先检查外网是否已可用，不可用时再尝试登录",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()

    if args.check_and_login and is_paused():
        logger = get_logger()
        print("当前已暂停，跳过自动登录")
        logger.info("当前已暂停，跳过自动登录")
        return 0

    logger = get_logger()
    logger.info("========== 本次运行开始 ==========")
    lock_handle: TextIO | None = None

    if args.check_and_login:
        lock_handle = acquire_lock(logger)
        if lock_handle is None:
            print("已有一次自动检查正在运行，本次直接退出。")
            logger.info("自动检查跳过：已有一次自动检查正在运行")
            return 0

    try:
        try:
            config = load_config()
        except ConfigError as exc:
            print(f"配置检查失败：{exc}")
            logger.error("配置检查失败：%s", exc)
            logger.info("登录失败")
            return 2

        username = str(config["user"]["username"]).strip()
        password_source_label = describe_password_source(config)

        print("已读取 config.yaml。")
        print("当前模式：深圳大学宿舍区 Dr.COM / ePortal。")

        if args.dry_run:
            logger.info("运行模式：dry-run")
            print("dry-run 检查通过：配置格式正常。")
            print(f"密码将从 {password_source_label} 读取。")
            if not has_password(config):
                print(f"提醒：还没有从 {password_source_label} 读取到密码。")
                _print_password_setup_hint(config)
            return 0

        if args.check_and_login:
            logger.info("运行模式：check-and-login")
            print("正在检查外网是否已经可用...")
            network_status = probe_network(config)
            if network_status.campus_internet_ok:
                print("外网已经可用，不需要登录。")
                print("登录跳过原因：外网已通。")
                print("如果只是想测试登录接口，请运行：python3 -m src.szu_netlogin.login")
                logger.info("外网已可用，退出")
                return 0

            gateway_hosts = ((config.get("network") or {}).get("dorm_gateway_hosts") or ["172.30.255.42"])
            gateway_label = ", ".join(str(host) for host in gateway_hosts)
            print(f"当前外网不可用，已检查宿舍区网关 {gateway_label}:801...")
            if not network_status.gateway_reachable:
                environment = classify_network_environment(config, network_status)
                reason_label = login_failure_reason_label(
                    _network_login_skip_reason(network_status.gateway_reason)
                )
                print(f"当前网络环境：{environment.label}")
                print(f"登录跳过原因：{reason_label}。")
                logger.info("自动登录停止本轮：%s", reason_label)
                return 0

            if is_paused():
                print("当前已暂停，跳过自动登录")
                logger.info("自动登录执行前检测到已暂停，跳过自动登录")
                return 0

            print("宿舍区网关可访问，准备尝试宿舍区 Dr.COM 登录。")
            logger.info("需要登录，尝试登录")
        else:
            logger.info("运行模式：直接登录")

        password = get_password(config)
        if not password:
            print(f"当前密码来源：{password_source_label}")
            _print_password_setup_hint(config)
            print("登录失败原因：密码缺失。")
            logger.warning("登录失败：password_missing")
            logger.info("登录失败")
            return 2

        print("正在尝试宿舍区 Dr.COM 登录...")
        result = DormDrcomClient(config).login_with_result(username, password)

        if result.status == "success":
            print("登录结果：成功。")
            logger.info("登录成功")
            return 0
        if result.status == "failed":
            reason_label = login_failure_reason_label(result.reason)
            print(f"登录结果：失败。原因：{reason_label}。")
            print(f"脱敏日志：{LOG_FILE}")
            logger.info("登录失败：%s", result.reason)
            return 1

        reason_label = login_failure_reason_label(result.reason)
        print(f"登录结果：不确定。原因：{reason_label}。")
        print(f"服务器响应已写入脱敏日志：{LOG_FILE}")
        logger.info("登录失败：%s", result.reason)
        return 1
    finally:
        if lock_handle is not None:
            lock_handle.close()


def acquire_lock(logger) -> TextIO | None:
    LOCK_FILE.parent.mkdir(parents=True, exist_ok=True)
    lock_handle = LOCK_FILE.open("w", encoding="utf-8")

    try:
        _lock_file_nonblocking(lock_handle)
    except (BlockingIOError, OSError):
        logger.info("锁文件已被占用，跳过本次运行：%s", LOCK_FILE)
        lock_handle.close()
        return None

    lock_handle.write(str(os.getpid()))
    lock_handle.flush()
    logger.info("已获取自动检查锁：%s", LOCK_FILE)
    return lock_handle


def _lock_file_nonblocking(lock_handle: TextIO) -> None:
    if fcntl is not None:
        fcntl.flock(lock_handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        return

    if msvcrt is not None:
        lock_handle.seek(0)
        msvcrt.locking(lock_handle.fileno(), msvcrt.LK_NBLCK, 1)
        return

    raise OSError("当前平台不支持文件锁。")


def _print_password_setup_hint(config: dict[str, Any]) -> None:
    security = config.get("security") or {}
    password_source = str(security.get("password_source", "env"))
    if password_source == "env":
        print(f"可以临时运行：export {get_password_env_name(config)}='你的校园网密码'")
        return
    if password_source == "keychain":
        print("请先运行：python3 -m src.szu_netlogin.control set-password")
        return
    if password_source == "private_file":
        print("请先运行：python3 -m src.szu_netlogin.control set-password")
        print(f"或在私有密码文件中写入密码：{security.get('password_file')}")
        return
    print("请检查 config.yaml 的 security.password_source。")


def login_failure_reason_label(reason: str) -> str:
    labels = {
        "password_missing": "密码缺失",
        "password_error": "密码错误",
        "gateway_unreachable": "网关不可达",
        "internet_already_ok": "外网已通",
        "portal_interface_changed": "门户接口变化",
        "server_response_uncertain": "服务器响应不确定",
        "server_failed": "门户返回失败",
        "request_exception": "登录请求异常",
    }
    if reason.startswith("http_status_"):
        return f"HTTP 状态码 {reason.removeprefix('http_status_')}"
    return labels.get(reason, reason or "未知原因")


def _network_login_skip_reason(gateway_reason: str) -> str:
    return "gateway_unreachable"


if __name__ == "__main__":
    raise SystemExit(main())
