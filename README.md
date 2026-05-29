# SZU Dorm NetLogin

深圳大学宿舍区 Dr.COM / ePortal 自动登录工具，适用于 macOS 本地使用。它可以在断网时自动检测宿舍区网关并尝试登录，也提供一个状态栏客户端用于手动登录、暂停、退出账号和查看日志。

这完全是vibe coding产物并借鉴了github上的一些开源项目（致谢名单附后），我自己debug了几轮，用起来几乎没什么问题了，有任何bug就自己修复吧，因为我也不懂代码哈哈哈

## 功能

- 自动检测外网连通性，已联网时不会重复登录
- 只在宿舍区网关可达时尝试 Dr.COM / ePortal 登录
- 支持 macOS Keychain、环境变量或私有文件读取密码
- 提供命令行控制：登录、退出、暂停、恢复、诊断
- 提供 macOS 状态栏客户端
- 支持安装用户级 LaunchAgent，实现登录后自动检查
- 日志默认脱敏，不打印密码或完整登录 URL

## 适用范围

这个项目只面向深圳大学宿舍区 Dr.COM / ePortal 场景。

它不处理教学区网络，不处理 srun，不需要 `sudo`，也不会把密码写进 `config.yaml`。


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
python3 -m src.szu_netlogin.control set-username 校园卡号
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

只在未联网且宿舍区网关可达时登录：

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

诊断当前网络状态：

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


## 状态栏客户端

启动状态栏客户端：

```bash
./scripts/run_menubar.sh
```

或直接运行：

```bash
python3 -m src.szu_netlogin.menubar_app
```

状态栏会显示 `SZU Dorm`，菜单里可以立即登录、退出账号、暂停或恢复自动登录、修改账号、修改密码、打开配置和日志、安装或卸载开机自启。

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

## 致谢 / Acknowledgements

本项目在实现过程中参考和借鉴了以下开源项目与工具，在此表示感谢：

* [1136623363/SZU-Drcom](https://github.com/1136623363/SZU-Drcom)
  提供了深圳大学宿舍区 Dr.COM / ePortal 自动登录场景的参考，尤其是宿舍区网关与登录流程相关思路。

* [Sleepstars/SZU-login](https://github.com/Sleepstars/SZU-login)
  提供了深圳大学教学区与宿舍区网络认证差异的参考，尤其是教学区 srun 与宿舍区 ePortal/Dr.COM 的区分、配置文件和自动检测思路。

* [ackness/szu-autoconnect](https://github.com/ackness/szu-autoconnect)
  提供了深大校园网自动联网、保持在线以及 UI 化控制的参考思路。

* [ceynri/szu-network-connecter](https://github.com/ceynri/szu-network-connecter)
  提供了深大校园网一键登录认证、浏览器插件交互和用户体验设计方面的参考。

* [Sleepstars/SZU_Utils](https://github.com/Sleepstars/SZU_Utils)
  提供了深大校园网实用脚本集合方面的参考。

* [jaredks/rumps](https://github.com/jaredks/rumps)
  本项目的 macOS 状态栏客户端如使用 Python 实现，可基于 rumps 构建菜单栏应用。

本项目主要面向个人学习与自用场景。若项目中存在直接引用、修改或复用上述项目代码的部分，请遵循对应项目的开源许可证要求，并在相关文件中保留原作者版权与许可证声明。

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

校园网接口可能会调整。如果登录或退出失败，先运行诊断命令并查看脱敏日志，再根据新的门户接口更新 `config.example.yaml` 或自己的 `config.yaml`。

## Disclaimer

本项目仅供个人学习、研究和自用，请在遵守学校网络管理规定和相关法律法规的前提下使用。  
作者不对因使用本项目造成的账号异常、网络限制、数据丢失或其他后果承担责任。  
请勿将本项目用于绕过学校网络管理、批量占用网络资源或其他违规用途。
