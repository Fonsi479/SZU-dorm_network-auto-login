"""Small one-shot diagnostics for the dorm Dr.COM network path."""

from __future__ import annotations

from .config import ConfigError, load_config
from .portal_detect import classify_network_environment, probe_network


def main() -> int:
    try:
        config = load_config()
    except ConfigError as exc:
        print(f"配置检查失败：{exc}")
        return 2

    status = probe_network(config)
    environment = classify_network_environment(config, status)

    print(f"网络环境：{environment.label}")
    print(f"自动登录可用：{'是' if environment.auto_login_available else '否'}")
    print(f"当前 Wi-Fi：{environment.wifi_ssid or '-'}")
    print(f"源路由已验证：{'是' if status.source_ip else '否'}")
    print(f"外网：{'可用' if status.campus_internet_ok else '不可用'}")
    print(f"宿舍区网关：{'可连接' if status.gateway_reachable else '不可连接'}")
    print(f"网关原因：{status.gateway_reason or '-'}")
    print(f"外网检测路径：{status.internet_route or '-'}")
    print(f"外网原因：{status.internet_reason or '-'}")
    print(f"是否可能需要登录：{'是' if status.maybe_need_login else '否'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
