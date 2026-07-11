# SZU Dorm NetLogin

深圳大学宿舍区 Dr.COM / ePortal 自动登录工具。这个发布标签包含共享登录核心、命令行控制、macOS 状态栏客户端、LaunchAgent 自动检查脚本，以及 Windows 桌面客户端搬运包源码。

## 功能

- 自动检测校园网出口连通性，已登录时不会重复登录
- 只在宿舍区网关可达且源 IP 符合校园网网段时尝试登录
- 支持系统凭据库、环境变量或私有文件读取密码
- 提供命令行控制：登录、退出、暂停、恢复、诊断
- 提供 macOS 状态栏客户端，支持手动登录、退出账号、暂停恢复、诊断报告和日志入口
- 提供 Windows 桌面客户端，支持首次安装、桌面快捷方式、图形化登录、退出、暂停、诊断和后台检查
- 支持用户级 LaunchAgent，登录 macOS 后自动检查
- 登录失败会显示分级原因，后台自动登录连续失败时会按 2/5/10/15 分钟退避重试
- 日志默认脱敏，不打印密码或完整登录 URL

## 适用范围

这个项目只面向深圳大学宿舍区 Dr.COM / ePortal 场景。

它不处理教学区网络，不处理 srun，不需要 `sudo`，也不会把密码写进 `config.yaml`。

## 安全提醒

公开仓库只应提交源码、脚本、示例配置和文档。请不要提交 `config.yaml`、`logs/`、`build/`、`dist/`、私有密码文件、账号密码、Token 或本机绝对路径；这些本地文件已由默认 `.gitignore` 排除。

## 安装依赖

```bash
python3 -m pip install -r requirements.txt
```

如需打包 macOS App：

```bash
python3 -m pip install -r requirements-build.txt
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

默认配置会把密码保存到系统凭据库，服务名为 `szu-netlogin`。macOS 对应 Keychain；如果 `config.yaml` 改成 `private_file`，则会写入配置的私有密码文件；`env` 模式需要手动设置环境变量。

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

暂停或恢复自动登录：

```bash
python3 -m src.szu_netlogin.control pause
python3 -m src.szu_netlogin.control resume
```

退出校园网账号，并暂停自动登录直到手动恢复：

```bash
python3 -m src.szu_netlogin.control logout
```

退出后只暂停 30 分钟：

```bash
python3 -m src.szu_netlogin.control logout --pause-for 30m
```

退出后暂停到下次开机：

```bash
python3 -m src.szu_netlogin.control logout --pause-for next-boot
```

生成一键诊断报告：

```bash
python3 -m src.szu_netlogin.control generate-diagnostic-report
```

常见修复入口：

```bash
python3 -m src.szu_netlogin.control reset-pause
python3 -m src.szu_netlogin.control check-dependencies
python3 -m src.szu_netlogin.control set-project-home-env
```

打开配置、日志或项目目录：

```bash
python3 -m src.szu_netlogin.control open-config
python3 -m src.szu_netlogin.control open-log
python3 -m src.szu_netlogin.control open-project
```

## macOS 状态栏客户端

启动状态栏客户端：

```bash
./scripts/run_menubar.sh
```

或直接运行：

```bash
python3 -m src.szu_netlogin.menubar_app
```

状态栏会显示 `SZU Dorm`。只要状态栏客户端正在运行且联网状态探测已开启，它会每 30 秒刷新状态，并且只在“宿舍区网关可达且校园网出口不可用”时启动后台自动登录；长时间睡眠后也会在唤醒时尽快补检。

状态栏客户端日志：

```bash
tail -n 80 logs/menubar.log
```

登录日志：

```bash
tail -n 80 ~/Library/Logs/szu-netlogin/netlogin.log
```

## Windows 桌面客户端

Windows 搬运包只保留一个首次安装入口：

```bat
one_click_install_and_run.bat
```

使用方式：

1. 解压 Windows release 的 zip。
2. 双击 `one_click_install_and_run.bat`。
3. 以后直接双击桌面上的 `SZU Dorm Login`。

首次安装脚本会优先从清华镜像安装 Python 3.12.10，使用清华 PyPI 镜像安装依赖，创建本地运行环境 `.venv-szu-dorm-login`，并创建桌面快捷方式。桌面快捷方式使用 `pythonw.exe` 启动，不会常驻黑色命令行窗口。

Windows 桌面客户端源码位于：

```text
apps/windows_desktop/
```

## 开机自启

安装用户级 LaunchAgent：

```bash
./scripts/install_launchagent.sh
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

验证 App：

```bash
bash scripts/verify_app.sh
```

打开 App：

```bash
bash scripts/open_menubar_app.sh
```

`.app` 运行时会读取项目目录中的 `config.yaml`。项目目录查找顺序：

1. 环境变量 `SZU_NETLOGIN_HOME`
2. 打包后默认目录 `~/Library/Application Support/szu-netlogin`

如果你想指定其他配置目录，可以先设置：

```bash
launchctl setenv SZU_NETLOGIN_HOME "/path/to/szu-netlogin"
```

如果 macOS 提示无法验证开发者，请在系统设置的隐私与安全性页面允许打开。确认是 quarantine 标记导致时，也可以手动移除：

```bash
xattr -dr com.apple.quarantine "dist/SZU Dorm Login.app"
```

## GitHub Releases

- macOS release：包含 `SZU Dorm Login.app` 压缩包和对应源码包，不包含 Windows 桌面客户端。
- Windows release：单独发布 Windows 搬运包，和 macOS release 分开管理。

## 项目结构

```text
src/szu_netlogin/        核心登录、检测、控制和 macOS 状态栏代码
apps/windows_desktop/    Windows 桌面客户端
scripts/                 本地运行、打包、LaunchAgent 安装脚本
launchd/                 LaunchAgent 模板
packaging/               PyInstaller 配置
config.example.yaml      可公开的示例配置
diagnose.py              兼容诊断入口
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
  本项目的 macOS 状态栏客户端基于 rumps 构建。

本项目主要面向个人学习与自用场景。若项目中存在直接引用、修改或复用上述项目代码的部分，请遵循对应项目的开源许可证要求，并在相关文件中保留原作者版权与许可证声明。

## 注意

校园网接口可能会调整。如果登录或退出失败，先运行诊断命令并查看脱敏日志，再根据新的门户接口更新 `config.example.yaml` 或自己的 `config.yaml`。状态栏会检查宿舍区网关是否可达，并按系统默认网络路径检测外网是否可用。
