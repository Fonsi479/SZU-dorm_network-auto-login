# SZUNET 工作边界

## 职责

- 只负责宿舍区 Dr.COM / ePortal 环境识别、状态读取、手动登录/退出、自动登录门控和凭据保存。
- 不负责远程控制、Codex 用量、项目保护或 CodexButler 导航。
- 当前不在校园网环境：默认只做 fake、mock、静态审计和离线 UI 测试，不执行真实 Portal 登录/退出。

## 目录

- `macos/Sources/SZUNetCore/`：网络协议、状态机、持久化与 Keychain。
- `macos/Sources/SZUNETFeature/`：公共接口 `SZUNETModule`、`SZUNETFeatureStore`、`SZUNETFeatureView`。
- `macos/Sources/SZUDormLogin/`：独立 macOS App 的薄入口和菜单栏 UI。
- `macos/Tests/`：Core、App 与 Feature 测试。

## 构建与测试

```bash
cd "/Users/fonsi/Documents/CodexProject/SZUNET/macos"
swift build
swift test
```

不要用真实账号或真实校园网请求作为自动化测试。

## 公共接口

- `SZUNETModule`：configure、refresh、manualLogin、manualLogout、saveCredentials、runAutomaticLoginIfDue。
- `SZUNETFeatureStore`：`@Published snapshot`、启动/停止、周期刷新和明确操作。
- `SZUNETFeatureView`：可嵌入独立 App 或 CodexButler 的设置/详情页面。
- `SZUNETSnapshot.status`：启用、自动登录、环境、Portal、互联网、最后成功/失败和错误码。

## 数据兼容

- 旧独立 App Bundle ID 保持 `com.szu-netlogin.dorm-login`。
- 旧 Keychain service 保持 `szu-netlogin`；CodexButler 接管数据使用 `com.local.CodexQuotaBar.szu-netlogin`，不得静默改名或删除源项。
- CodexButler 注入目录保持 `~/Library/Application Support/CodexQuotaBar/Campus`。
- UserDefaults 键 `settings.campusFeatureEnabled` 与 `settings.campusAutoLoginEnabled` 由聚合壳保留。

## 禁止边界

- 模块关闭时不得探测 Portal、读取密码、创建主动刷新任务或发送登录请求。
- 不修改 Shadowrocket、Tailscale、远程 helper 或 Codex 数据。
- 日志不得包含密码、Cookie、Portal 响应正文或完整账号查询参数。
- 不改变 Bundle ID、Keychain service、数据目录或登录项，除非有明确可回滚迁移要求。

## 验证校园网功能

- 默认运行 `swift test`，重点覆盖双重环境门控、手动退出抑制、取消和退避。
- 只有用户明确说明处于校园网且授权后，才可执行真实探测；登录或退出仍需再次确认。
