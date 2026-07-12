# SZU Dorm Login for macOS

深圳大学宿舍区 Dr.COM / ePortal 自动登录工具。macOS 版从 `2.0.0` 开始使用纯 Swift 重写，不包含 Python 解释器、PyInstaller、rumps 或 PyObjC。

## 平台已经完全分离

| 平台 | Git 分支 | 技术栈 | 发布物 |
|---|---|---|---|
| macOS | `main` | Swift、AppKit、SwiftUI、Security、ServiceManagement | 原生 `.app` |
| Windows | `windows` | Python、Tkinter、requests、keyring | 独立 Windows 压缩包 |

两个平台拥有独立的界面、启动机制、构建脚本、测试和 Release。`main` 不再携带 Python 客户端；Windows 的 Python 源码仍完整保留在 `windows` 分支。

如需开发 Windows 版：

```bash
git switch windows
```

## macOS 功能

- 自动检测宿舍区网关和校园网出口，网络已连接时不会重复登录
- 只有网关可达且源 IP 落在配置的校园网段时，才允许后台发送账号密码
- Dr.COM 登录请求使用 Swift BSD Socket，并显式绑定已检测的校园网源 IP
- 支持登录、退出、暂停/恢复自动登录和关闭/开启联网探测
- 登录失败后按 2/5/10/15 分钟退避重试，系统唤醒后立即补检
- 使用 macOS Keychain 保存密码，配置文件和日志不保存密码
- 使用 ServiceManagement 原生管理“登录时启动”，不再安装 Python LaunchAgent
- 原生设置窗口、通知、诊断报告和脱敏轮转日志
- 可自动导入 `1.x` 版 `config.yaml`，并提示移除旧 Python LaunchAgent

本项目仅面向深圳大学宿舍区 Dr.COM / ePortal，不处理教学区网络或 srun。

## 系统要求

- macOS 13 或更新版本
- 本地构建需要 Apple Swift 工具链；安装 Xcode Command Line Tools 即可
- 运行打包后的 App 不需要 Python，也不需要额外安装依赖

## 构建、验证和运行

在仓库根目录执行：

```bash
bash scripts/build_app.sh
bash scripts/verify_app.sh
bash scripts/open_menubar_app.sh
```

生成结果：

```text
dist/SZU Dorm Login.app
```

构建脚本默认生成当前 Mac 架构的 App。验证会检查：

- Swift 核心行为检查
- Bundle 元数据与版本
- 代码签名完整性
- 可执行架构
- App 内没有 Python 文件或 `libpython` 链接

源码开发时可直接运行：

```bash
bash scripts/run_menubar.sh
```

运行纯 Swift 核心检查：

```bash
bash scripts/run_swift_checks.sh
```

## 首次使用

打开 App 后，从状态栏的“账号与凭据 → 打开设置…”填写校园网账号。密码在设置窗口或“修改密码…”中保存，实际写入 macOS Keychain。

原生配置文件位于：

```text
~/Library/Application Support/szu-netlogin/config.json
```

日志位于：

```text
~/Library/Logs/szu-netlogin/netlogin.log
```

诊断报告位于：

```text
~/Library/Logs/szu-netlogin/diagnostics/
```

配置示例见 [`config.example.json`](config.example.json)。通常直接使用设置窗口即可，不需要手工编辑 JSON。

## 从 Python macOS 版迁移

第一次启动 Swift App 时会按以下顺序处理旧数据：

1. 如果尚无 `config.json`，读取 `~/Library/Application Support/szu-netlogin/config.yaml`。
2. 兼容读取 `SZU_NETLOGIN_HOME/config.yaml` 或开发目录中的 `config.yaml`。
3. 把账号、网关、网段、门户参数和 Keychain 服务名写入权限为 `0600` 的 `config.json`。
4. 继续使用原有 `szu-netlogin` Keychain 项目，不复制或显示密码。
5. 如果检测到旧 Python LaunchAgent，明确询问后再移除，并迁移为 ServiceManagement 登录项。

旧配置不会被自动删除，可以在确认新版本工作正常后自行备份或清理。

## 状态栏结构

- 当前网络状态和探测详情
- 立即登录
- 退出当前账号
- 自动登录
- 联网状态探测
- 账号与凭据
  - 打开设置
  - 修改账号
  - 修改密码
- 诊断与维护
  - 生成诊断报告
  - 打开配置文件
  - 打开日志目录
  - 重置暂停状态
  - 运行原生自检
- 登录时启动
- 退出应用

## 命令行入口

打包后的 Swift 可执行文件也提供只读或控制入口：

```bash
"dist/SZU Dorm Login.app/Contents/MacOS/SZU Dorm Login" --version
"dist/SZU Dorm Login.app/Contents/MacOS/SZU Dorm Login" --self-test
"dist/SZU Dorm Login.app/Contents/MacOS/SZU Dorm Login" --ui-smoke-test
"dist/SZU Dorm Login.app/Contents/MacOS/SZU Dorm Login" --probe
"dist/SZU Dorm Login.app/Contents/MacOS/SZU Dorm Login" --session-status
"dist/SZU Dorm Login.app/Contents/MacOS/SZU Dorm Login" --login
"dist/SZU Dorm Login.app/Contents/MacOS/SZU Dorm Login" --check-and-login
"dist/SZU Dorm Login.app/Contents/MacOS/SZU Dorm Login" --logout
"dist/SZU Dorm Login.app/Contents/MacOS/SZU Dorm Login" --diagnostic-report
"dist/SZU Dorm Login.app/Contents/MacOS/SZU Dorm Login" --launch-at-login-status
"dist/SZU Dorm Login.app/Contents/MacOS/SZU Dorm Login" --auto-login-status
"dist/SZU Dorm Login.app/Contents/MacOS/SZU Dorm Login" --pause-auto-login
"dist/SZU Dorm Login.app/Contents/MacOS/SZU Dorm Login" --resume-auto-login
```

## 源码结构

```text
macos/Package.swift                       Swift Package
macos/Sources/SZUNetCore/                 配置、网络、Dr.COM、Keychain、状态和诊断核心
macos/Sources/SZUDormLogin/                可测试的 AppKit/SwiftUI 应用层
macos/Sources/SZUDormLoginExecutable/      极薄的应用启动入口
macos/Tests/                               Swift Testing 自动化测试
macos/Resources/Info.plist                 App Bundle 元数据
scripts/build_app.sh                       Swift release 构建和 App 打包
scripts/verify_app.sh                      App 完整性与无 Python 验证
config.example.json                        可公开的原生配置示例
```

## 安全边界

- 后台自动登录必须同时满足“宿舍区网关可达”和“源 IP 位于配置的校园网段”
- 手动点击登录由用户明确触发，不经过自动登录环境门控
- 密码只从 Keychain 读取，并在 HTTP 参数构造后直接发送给配置的 Dr.COM 地址
- 日志会隐藏账号、密码和完整登录 URL
- App 不需要 `sudo`，也不安装系统级守护进程

公开仓库或 Release 中不要包含真实 `config.json`、旧 `config.yaml`、日志、诊断报告、账号密码、Token 或本机绝对路径。

## Release 约定

- macOS Release：从 `main` 构建，只包含原生 Swift `.app` 和 macOS 源码
- Windows Release：从 `windows` 分支构建，只包含 Python Windows 客户端
- 两个平台不复用安装包，也不把另一平台的桌面代码混入 Release

## 致谢

- [1136623363/SZU-Drcom](https://github.com/1136623363/SZU-Drcom)
- [Sleepstars/SZU-login](https://github.com/Sleepstars/SZU-login)

本项目采用 MIT License。
