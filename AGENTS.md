# SZU Campus Network 工作边界

## 职责

- 负责宿舍区 Dr.COM / ePortal 与教学区 SRun 的环境识别、状态读取、显式登录、自动登录门控和凭据保存。
- Teaching Provider 默认关闭；在现场契约完成验证前不得发送 Teaching 注销请求。
- 不负责远程控制、Codex 用量、项目保护或 CodexButler 导航。
- 当前不在校园网环境：默认只做 fake、mock、静态审计和离线 UI 测试，不执行真实 Portal 登录/退出。

## 目录

- `macos/Sources/SZUNetCore/`：双 Provider、Coordinator、状态机、持久化与 Keychain。
- `macos/Sources/SZUNETFeature/`：CLI-only 可选消费端；不依赖 Core，不拥有认证、凭据、设置或自动登录生命周期。
- `macos/Sources/SZUDormLogin/`：独立 macOS App 的薄入口和菜单栏 UI。
- `macos/Tests/`：Core、App 与 Feature 测试。
- `src/szu_netlogin/`：Windows/Python 双 Provider、Coordinator 与 JSON CLI。
- `apps/windows_desktop/`：独立 Windows Tk GUI。
- `protocol-spec/`：两平台共享的 Schema、Fixture 与合成向量。

## 构建与测试

```bash
cd macos
swift build --disable-automatic-resolution
swift test --disable-automatic-resolution
cd ..
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -v
```

不要用真实账号或真实校园网请求作为自动化测试。

## 公共接口

- JSON CLI 与 `SZUNETFeature` 只能交换脱敏状态和高层命令，不接受或返回密码。
- 独立 SZUNET App 是 Provider、Coordinator、凭据、设置与最终 Bundle 的唯一所有者。
- CodexButler 只是可选消费者，不得复制 Provider 或创建第二套认证所有者。
- `SZUNETFeature` 只能通过已安装 App 内的 `szu-campus-netctl --json` 通信；不得回退到进程内 Core、配置路径或 Keychain。
- 双平台 product service 的 status/check/login/logout 与 Provider 选择必须经唯一 Coordinator；service 不得直接调用 Provider 的 probe/session/auth API。

## 数据兼容

- 旧独立 App Bundle ID 保持 `com.szu-netlogin.dorm-login`。
- 旧 Keychain service 保持 `szu-netlogin`，不得静默改名、复制或删除源项。
- macOS App 名称与 Bundle ID 为升级兼容而保留；外层产品与 Release 名称使用 `SZU Campus Network`。

## 禁止边界

- 模块关闭时不得探测 Portal、读取密码、创建主动刷新任务或发送登录请求。
- 不修改 Shadowrocket、Tailscale、远程 helper 或 Codex 数据。
- 日志不得包含密码、Cookie、Portal 响应正文或完整账号查询参数。
- 不改变 Bundle ID、Keychain service、数据目录或登录项，除非有明确可回滚迁移要求。

## 验证校园网功能

- 默认运行两平台测试，重点覆盖环境门控、零凭据读取、Provider 互斥、取消、退避与脱敏。
- 只有用户明确说明处于校园网且授权后，才可执行真实探测；登录或退出仍需再次确认。
