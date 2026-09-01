# CLI JSON 契约

## 调用方式

```text
szu-campus-netctl --json
```

命令从 stdin 读取单个 JSON 对象，stdout 输出单个符合 `command_result.schema.json` 的对象。不得把密码放进参数、stdin、环境变量或配置。

## 请求

```json
{
  "schemaVersion": 1,
  "requestId": "uuid-or-host-request-id",
  "command": "status|check|login|force-login|logout|pause|resume|open-settings|diagnostics",
  "provider": "auto|dorm|teaching",
  "interactive": true,
  "timeoutSeconds": 15
}
```

- `login` 仍受环境安全门控。
- `force-login` 只接受明确的人工交互请求，用于用户确认后的 Dorm 三设备切换；自动登录和 `interactive=false` 必须安全阻止。服务端自行选择被下线的旧设备。
- `interactive=false` 时，缺凭据或需用户确认直接返回错误，不弹窗。
- `diagnostics` 默认只返回摘要；导出文件需要用户交互。
- `status` 与 `diagnostics` 在一次性 CLI 进程内执行只读刷新，不能复用空的进程内缓存。
- 响应可选字段 `automaticEnabled` 与 `ownerAppRunning` 分别表示自动登录总门和独立 App 当前运行态；`onlineDeviceCount` 与 `onlineDeviceLimit` 表示服务端返回的 Dorm 在线设备聚合（上限固定为 3）。旧客户端可忽略这些字段。
- `resume` 同时恢复自动登录总门、清除暂停状态并确认独立 App 已启动，启动失败不得返回 `succeeded`。
- `open-settings` 只有在系统接受独立 App 的启动或设置路由后才返回成功。

## 退出码

| 码 | 含义 |
|---:|---|
| 0 | succeeded/unchanged |
| 2 | blocked/配置或环境问题 |
| 3 | 认证失败 |
| 4 | 网络瞬态失败 |
| 5 | 版本不兼容 |
| 130 | cancelled |
| 70 | internal error |

## 安全

- stderr 只允许事件码和脱敏消息。
- stdout 不混入日志。
- 命令超时后应取消底层任务，而不是仅停止等待。
- Codex 管家不得以 shell 字符串拼接调用；使用参数数组和 stdin JSON。
