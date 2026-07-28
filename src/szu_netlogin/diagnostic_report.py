"""Generate a local diagnostic report for SZU Dorm NetLogin."""

from __future__ import annotations

import plistlib
import os
import subprocess
import sys
from datetime import datetime
from pathlib import Path
from typing import Any

from .config import ConfigError, DEFAULT_CONFIG_PATH, PROJECT_HOME_ENV, PROJECT_ROOT, load_config
from .logger import LOG_FILE, redact_sensitive_text
from .portal_detect import (
    NetworkStatus,
    classify_network_environment,
    probe_network,
)
from .state import PAUSE_FLAG_FILE, describe_pause_state


LAUNCHAGENT_PLIST = Path.home() / "Library" / "LaunchAgents" / "com.szu-netlogin.dorm-drcom.plist"
MENUBAR_LOG_FILE = PROJECT_ROOT / "logs" / "menubar.log"
LAUNCHAGENT_OUT_LOG = Path.home() / "Library" / "Logs" / "szu-netlogin" / "launchagent.out.log"
LAUNCHAGENT_ERR_LOG = Path.home() / "Library" / "Logs" / "szu-netlogin" / "launchagent.err.log"
REPORT_LOG_LINES = 80


def create_diagnostic_report() -> Path:
    report_dir = PROJECT_ROOT / "logs"
    report_dir.mkdir(parents=True, exist_ok=True)
    timestamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    report_path = report_dir / f"diagnostic-report-{timestamp}.txt"
    _write_private_report(report_path, build_diagnostic_report())
    return report_path


def build_diagnostic_report() -> str:
    timestamp = datetime.now().astimezone().isoformat(timespec="seconds")
    lines: list[str] = [
        "SZU Dorm NetLogin 诊断报告",
        f"生成时间：{timestamp}",
        "",
        "== 项目与配置 ==",
        f"项目目录：{PROJECT_ROOT}",
        f"配置文件：{DEFAULT_CONFIG_PATH}",
        f"{PROJECT_HOME_ENV}：{_env_value(PROJECT_HOME_ENV)}",
    ]

    config, config_error = _load_config()
    if config_error:
        lines.append(f"配置检查：失败，{config_error}")
    else:
        lines.append("配置检查：通过")

    lines.extend(["", "== 暂停状态 =="])
    lines.append(f"当前暂停：{describe_pause_state()}")
    lines.append(f"暂停标记：{PAUSE_FLAG_FILE}")

    lines.extend(["", "== 网络探测 =="])
    status = _probe_network(config)
    if status is None:
        lines.append("网络探测：跳过，配置不可用")
    else:
        environment = classify_network_environment(config, status)
        lines.extend(
            [
                f"网络环境：{environment.label}",
                f"自动登录可用：{_yes_no(environment.auto_login_available)}",
                f"当前 Wi-Fi：{_mask_identifier(environment.wifi_ssid)}",
                f"宿舍区网关是否可达：{_yes_no(status.gateway_reachable)}",
                f"网关地址：{_mask_identifier(status.gateway_host)}",
                f"网关失败原因：{status.gateway_reason or '-'}",
                f"源 IP：{_mask_identifier(status.source_ip)}",
                f"外网是否可用：{_yes_no(status.campus_internet_ok)}",
                f"外网检测 route：{status.internet_route or '-'}",
                f"外网检测原因：{status.internet_reason or '-'}",
            ]
        )

    if sys.platform == "darwin":
        lines.extend(["", "== LaunchAgent =="])
        launchagents = _find_auto_login_launchagents()
        lines.append(f"标准 plist：{LAUNCHAGENT_PLIST}")
        lines.append(f"标准 plist 是否存在：{_yes_no(LAUNCHAGENT_PLIST.exists())}")
        lines.append(f"自动登录 LaunchAgent 数量：{len(launchagents)}")
        for plist_path in launchagents:
            lines.append(f"- {plist_path}")
        if len(launchagents) > 1:
            lines.append("提醒：检测到多个相关 LaunchAgent，建议只保留一个。")
    else:
        lines.extend(["", "== 桌面客户端 =="])
        lines.append("当前平台不使用 macOS LaunchAgent；Windows 版由桌面客户端运行后台检查。")

    lines.extend(["", "== 最近脱敏日志 =="])
    _append_log_tail(lines, "登录日志", LOG_FILE)
    if sys.platform == "darwin":
        _append_log_tail(lines, "状态栏日志", MENUBAR_LOG_FILE)
        _append_log_tail(lines, "LaunchAgent stdout", LAUNCHAGENT_OUT_LOG)
        _append_log_tail(lines, "LaunchAgent stderr", LAUNCHAGENT_ERR_LOG)

    return "\n".join(lines) + "\n"


def _load_config() -> tuple[dict[str, Any] | None, str]:
    try:
        return load_config(), ""
    except ConfigError as exc:
        return None, str(exc)


def _probe_network(config: dict[str, Any] | None) -> NetworkStatus | None:
    if config is None:
        return None
    try:
        return probe_network(config)
    except Exception as exc:
        return NetworkStatus(
            gateway_reachable=False,
            campus_internet_ok=False,
            gateway_reason=f"probe_error:{type(exc).__name__}",
            internet_reason=str(exc).replace("\n", " ")[:160],
        )


def _find_auto_login_launchagents() -> list[Path]:
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


def _append_log_tail(lines: list[str], label: str, path: Path) -> None:
    lines.append("")
    lines.append(f"-- {label}: {path} --")
    if not path.exists():
        lines.append("日志不存在")
        return

    try:
        with path.open("r", encoding="utf-8", errors="replace") as file:
            tail = file.readlines()[-REPORT_LOG_LINES:]
    except OSError as exc:
        lines.append(f"读取失败：{exc}")
        return

    if not tail:
        lines.append("日志为空")
        return

    for line in tail:
        lines.append(redact_sensitive_text(line.rstrip()))


def _env_value(name: str) -> str:
    import os

    return os.environ.get(name) or "-"


def _yes_no(value: bool) -> str:
    return "是" if value else "否"


def _mask_identifier(value: str) -> str:
    value = value.strip()
    if not value:
        return "-"
    if "." in value:
        parts = value.split(".")
        if len(parts) == 4:
            return f"{parts[0]}.***.***.{parts[-1]}"
    if len(value) <= 4:
        return "****"
    return value[:2] + "***" + value[-2:]


def _write_private_report(path: Path, text: str) -> None:
    flags = os.O_WRONLY | os.O_CREAT | os.O_TRUNC
    descriptor = os.open(path, flags, 0o600)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as report:
            report.write(text)
            report.flush()
            os.fsync(report.fileno())
    except Exception:
        try:
            os.close(descriptor)
        except OSError:
            pass
        raise
    if os.name == "nt":
        _secure_windows_acl(path)
    else:
        os.chmod(path, 0o600)
        if path.stat().st_mode & 0o777 != 0o600:
            raise OSError("diagnostic report permissions are not owner-only")


def _secure_windows_acl(path: Path) -> None:
    principal_sid = _windows_current_user_sid()
    result = subprocess.run(
        [
            "icacls",
            str(path),
            "/inheritance:r",
            "/grant:r",
            f"*{principal_sid}:(R,W)",
        ],
        check=False,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        timeout=8,
    )
    if result.returncode != 0:
        raise OSError("cannot restrict diagnostic report ACL")


def _windows_current_user_sid() -> str:
    """Return the current process token's user SID without trusting environment names."""

    import ctypes
    import re
    from ctypes import wintypes

    token_query = 0x0008
    token_user_class = 1

    class SIDAndAttributes(ctypes.Structure):
        _fields_ = [
            ("sid", wintypes.LPVOID),
            ("attributes", wintypes.DWORD),
        ]

    kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
    advapi32 = ctypes.WinDLL("advapi32", use_last_error=True)

    kernel32.GetCurrentProcess.restype = wintypes.HANDLE
    kernel32.CloseHandle.argtypes = [wintypes.HANDLE]
    kernel32.CloseHandle.restype = wintypes.BOOL
    kernel32.LocalFree.argtypes = [ctypes.c_void_p]
    kernel32.LocalFree.restype = ctypes.c_void_p
    advapi32.OpenProcessToken.argtypes = [
        wintypes.HANDLE,
        wintypes.DWORD,
        ctypes.POINTER(wintypes.HANDLE),
    ]
    advapi32.OpenProcessToken.restype = wintypes.BOOL
    advapi32.GetTokenInformation.argtypes = [
        wintypes.HANDLE,
        ctypes.c_int,
        wintypes.LPVOID,
        wintypes.DWORD,
        ctypes.POINTER(wintypes.DWORD),
    ]
    advapi32.GetTokenInformation.restype = wintypes.BOOL
    advapi32.ConvertSidToStringSidW.argtypes = [
        wintypes.LPVOID,
        ctypes.POINTER(wintypes.LPWSTR),
    ]
    advapi32.ConvertSidToStringSidW.restype = wintypes.BOOL

    token = wintypes.HANDLE()
    if not advapi32.OpenProcessToken(
        kernel32.GetCurrentProcess(), token_query, ctypes.byref(token)
    ):
        raise ctypes.WinError(ctypes.get_last_error())

    try:
        required = wintypes.DWORD()
        advapi32.GetTokenInformation(
            token,
            token_user_class,
            None,
            0,
            ctypes.byref(required),
        )
        if required.value == 0:
            raise ctypes.WinError(ctypes.get_last_error())

        buffer = ctypes.create_string_buffer(required.value)
        if not advapi32.GetTokenInformation(
            token,
            token_user_class,
            buffer,
            required.value,
            ctypes.byref(required),
        ):
            raise ctypes.WinError(ctypes.get_last_error())

        token_user = ctypes.cast(
            buffer, ctypes.POINTER(SIDAndAttributes)
        ).contents
        string_sid = wintypes.LPWSTR()
        if not advapi32.ConvertSidToStringSidW(
            token_user.sid, ctypes.byref(string_sid)
        ):
            raise ctypes.WinError(ctypes.get_last_error())
        try:
            value = (string_sid.value or "").strip()
        finally:
            kernel32.LocalFree(ctypes.cast(string_sid, ctypes.c_void_p))
    finally:
        kernel32.CloseHandle(token)

    if re.fullmatch(r"S-\d-\d+(?:-\d+)+", value) is None:
        raise OSError("cannot determine report owner SID")
    return value
