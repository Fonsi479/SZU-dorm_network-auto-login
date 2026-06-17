# SZU Dorm NetLogin

深圳大学宿舍区 Dr.COM / ePortal 自动登录工具，适用于 macOS 本地使用。它可以在断网时自动检测宿舍区网关并尝试登录，也提供一个状态栏客户端用于手动登录、暂停、退出账号和查看日志。

## 功能

- 自动检测校园网出口连通性，校园网已登录时不会重复登录
- 只在宿舍区网关可达时尝试 Dr.COM / ePortal 登录
- 支持 macOS Keychain、环境变量或私有文件读取密码
- 提供命令行控制：登录、退出、暂停、恢复、诊断
- 提供 macOS 状态栏客户端；运行时会在后台自动检查，并在睡眠唤醒后补检
- 支持安装用户级 LaunchAgent，实现登录后自动检查
- 日志默认脱敏，不打印密码或完整登录 URL

## 适用范围

这个项目只面向深圳大学宿舍区 Dr.COM / ePortal 场景。

它不处理教学区网络，不处理 srun，不需要 `sudo`，也不会把密码写进 `config.yaml`。

## 安全说明

公开仓库应只提交源码、脚本、示例配置和文档。请不要提交以下内容：

- `config.yaml`
- `logs/`
- `build/`
- `dist/`
- `__pycache__/`
- `.DS_Store`
- 任何包含账号、密码、Token、本机用户名或绝对路径的文件

默认的 `.gitignore` 已经排除了这些本地文件。发布前可以用下面的命令做一次快速检查：

```bash
rg -n "password|token|secret|/Users/|username|account|学号|校园卡|@" .
```

如果输出来自 `config.example.yaml` 或 README 中的占位说明，需要人工判断；如果输出来自真实配置、日志或构建产物，请不要提交。

## 环境要求

- macOS
- Python 3.10+
- Python 依赖：`requests`
- 可选依赖：
  - `PyYAML`：更完整的 YAML 解析
  - `keyring`：跨平台 Keychain/keyring 访问
  - `rumps`：运行 macOS 状态栏客户端
  - `pyinstaller`：打包 `.app`

安装常用依赖：

```bash
python3 -m pip install requests PyYAML keyring rumps
```

如需打包 macOS App：

```bash
python3 -m pip install pyinstaller
```

## 快速开始

复制示例配置：

```bash
cp config.example.yaml config.yaml
```

设置校园网账号：

```bash
python3 -m src.szu_netlogin.control set-username 学号
```

设置密码：

```bash
python3 -m src.szu_netlogin.control set-password
```

密码会交互式输入，不会在终端回显。默认配置会把密码保存到 macOS Keychain，服务名为 `szu-netlogin`。

检查配置：

```bash
python3 -m src.szu_netlogin.login --dry-run
```

立即登录：

```bash
python3 -m src.szu_netlogin.login
```

只在校园网出口不可用且宿舍区网关可达时登录：

```bash
python3 -m src.szu_netlogin.login --check-and-login
```

## 常用命令

查看状态：

```bash
python3 -m src.szu_netlogin.control status
```

暂停自动登录：

```bash
python3 -m src.szu_netlogin.control pause
```

恢复自动登录：

```bash
python3 -m src.szu_netlogin.control resume
```

退出校园网账号：

```bash
python3 -m src.szu_netlogin.control logout
```

诊断当前校园网状态：

```bash
python3 -m src.szu_netlogin.control diagnose
```

打开配置、日志或项目目录：

```bash
python3 -m src.szu_netlogin.control open-config
python3 -m src.szu_netlogin.control open-log
python3 -m src.szu_netlogin.control open-project
```

## 密码来源

`config.example.yaml` 默认使用 Keychain：

```yaml
security:
  password_source: "keychain"
  keychain_service: "szu-netlogin"
```

也可以改用环境变量：

```yaml
security:
  password_source: "env"
  password_env_name: "SZU_NET_PASSWORD"
```

然后在当前终端设置：

```bash
export SZU_NET_PASSWORD='你的校园网密码'
```

还可以改用私有密码文件：

```yaml
security:
  password_source: "private_file"
  password_file: "~/.szu-netlogin/password.yaml"
```

私有密码文件不要提交到 GitHub。

## 状态栏客户端

启动状态栏客户端：

```bash
./scripts/run_menubar.sh
```

或直接运行：

```bash
python3 -m src.szu_netlogin.menubar_app
```

状态栏会显示 `SZU Dorm`，菜单里可以立即登录、退出账号、暂停或恢复自动登录、修改账号、修改密码、打开配置和日志、安装或卸载开机自启。只要状态栏客户端正在运行，它每 2 分钟会在后台检查一次，长时间睡眠后也会在唤醒时尽快补检；安装 LaunchAgent 后，即使没有打开状态栏客户端也能自动检查。

状态栏客户端日志：

```bash
tail -n 80 logs/menubar.log
```

登录日志：

```bash
tail -n 80 ~/Library/Logs/szu-netlogin/netlogin.log
```

## 开机自启

安装用户级 LaunchAgent：

```bash
./scripts/install_launchagent.sh
```

安装后会在 macOS 登录后运行一次，之后每 2 分钟检查一次：

```bash
python3 -m src.szu_netlogin.login --check-and-login
```

卸载：

```bash
./scripts/uninstall_launchagent.sh
```

LaunchAgent 标签为 `com.szu-netlogin.dorm-drcom`，对应用户级 plist 路径：

```text
~/Library/LaunchAgents/com.szu-netlogin.dorm-drcom.plist
```

查看 launchd 输出：

```bash
tail -n 80 ~/Library/Logs/szu-netlogin/launchagent.out.log
tail -n 80 ~/Library/Logs/szu-netlogin/launchagent.err.log
```

## 打包 macOS App

状态栏客户端可以通过 PyInstaller 打包成 `.app`：

```bash
bash scripts/build_app.sh
```

生成结果：

```text
dist/SZU Dorm Login.app
```

打开 App：

```bash
bash scripts/open_menubar_app.sh
```

`.app` 运行时会读取项目目录中的 `config.yaml`。项目目录查找顺序：

1. 环境变量 `SZU_NETLOGIN_HOME`
2. 打包后默认目录 `~/Projects/szu-netlogin`

如果项目不在默认目录，可以先设置：

```bash
launchctl setenv SZU_NETLOGIN_HOME "/path/to/szu-netlogin"
```

如果 macOS 提示无法验证开发者，请在系统设置的隐私与安全性页面允许打开。确认是 quarantine 标记导致时，也可以手动移除：

```bash
xattr -dr com.apple.quarantine "dist/SZU Dorm Login.app"
```

## 公开发布建议

建议只发布源码包，不发布本地生成的 `dist/` 和 `build/`。一个干净的源码包可以这样生成：

```bash
git archive --format=zip --output=szu-dorm-netlogin-source.zip HEAD
```

如果当前目录还没有初始化 Git，可以用 `zip` 手动排除本地文件：

```bash
zip -r szu-dorm-netlogin-source.zip . \
  -x "config.yaml" "logs/*" "build/*" "dist/*" "__pycache__/*" "src/**/__pycache__/*" ".DS_Store"
```

## 项目结构

```text
src/szu_netlogin/        核心登录、检测、控制和状态栏代码
scripts/                 本地运行、打包、LaunchAgent 安装脚本
launchd/                 LaunchAgent 模板
packaging/               PyInstaller 配置
config.example.yaml      可公开的示例配置
diagnose.py              兼容诊断入口
```

## 注意

校园网接口可能会调整。如果登录或退出失败，先运行诊断命令并查看脱敏日志，再根据新的门户接口更新 `config.example.yaml` 或自己的 `config.yaml`。默认会先检查宿舍区网关对应的源地址；如果该路径直连超时，还会按 macOS 的系统代理/VPN 路径复核，避免把浏览器实际可上网的情况误报为不可用。若只想检测校园网直连路径，可把 `network.allow_system_fallback` 设为 `false`。
