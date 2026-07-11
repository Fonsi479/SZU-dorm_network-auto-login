# SZU Dorm NetLogin — Windows

深圳大学宿舍区 Dr.COM / ePortal 自动登录工具的 Windows 独立版本，当前版本为 `1.1.0`。本分支只包含 Windows 桌面客户端、Windows 启动脚本和跨平台登录核心；macOS 状态栏客户端、LaunchAgent、`.app` 打包脚本均不在此分支。

## 功能

- 自动判断宿舍区网关、校园网源 IP 与外网连通状态，避免在非宿舍网络误发登录请求
- Windows 图形界面分为“概览”和“诊断与日志”，日常操作与维护入口互不干扰
- 支持立即登录、检查并登录、退出账号、暂停/恢复自动登录
- 支持修改账号与密码；密码默认交给 Windows 系统凭据库的 keyring 后端保存
- 支持动态“安装开机自启 / 卸载开机自启”，使用当前用户 Startup 快捷方式，不需要管理员权限
- 支持配置、日志、诊断报告、暂停状态重置和依赖检查
- 后台命令与 PowerShell/netsh 调用隐藏控制台窗口，关闭客户端时会取消仍在运行的控制命令
- 登录失败按 2/5/10/15 分钟退避重试，日志与界面输出均会脱敏

## 快速安装

1. 解压完整的 Windows release 压缩包，运行期间不要单独移动其中的源码文件。
2. 双击 `one_click_install_and_run.bat`。
3. 首次安装完成后，使用桌面快捷方式 `SZU Dorm Login`。

首次安装脚本会：

- 检查 Python 3.10 或更高版本；缺失时优先从清华镜像安装 Python 3.12
- 在解压目录创建独立环境 `.venv-szu-dorm-login`
- 通过清华 PyPI 镜像安装依赖
- 创建使用 `pythonw.exe` 的桌面快捷方式并启动客户端

以后无需再次运行安装脚本。若移动了解压目录，请重新运行安装脚本以更新桌面快捷方式。

## 使用界面

“概览”页显示自动登录、暂停状态、网络环境、校园网出口、宿舍网关、源 IP、配置路径、开机自启状态和更新时间。

常用按钮：

- `立即登录`：直接向宿舍区门户发起一次登录
- `检查并登录`：仅在符合宿舍网络条件且外网未通时登录
- `退出账号`：退出校园网，并暂停自动登录直到手动恢复
- `关闭/开启联网探测`：控制 30 秒一次的状态探测
- `安装/卸载开机自启`：切换当前 Windows 用户登录后的自动启动

“诊断与日志”页提供配置文件、日志、诊断报告、暂停状态重置，以及持续脱敏的运行输出。

## 本地文件

在 release 搬运包中，配置默认位于解压目录：

```text
config.yaml
```

日志默认位于：

```text
%LOCALAPPDATA%\SZU Dorm NetLogin\Logs\netlogin.log
```

开机自启快捷方式位于：

```text
%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\SZU Dorm Login.lnk
```

账号密码不会写进 `config.yaml`。默认 `security.password_source: keychain` 会使用 Windows 可用的 keyring 后端。

## 命令行诊断

在解压目录打开 PowerShell：

```powershell
.\.venv-szu-dorm-login\Scripts\python.exe -m src.szu_netlogin.control status
.\.venv-szu-dorm-login\Scripts\python.exe -m src.szu_netlogin.control check-dependencies
.\.venv-szu-dorm-login\Scripts\python.exe -m src.szu_netlogin.control generate-diagnostic-report
```

如果使用 Parallels Desktop：共享网络适合验证安装和窗口，但无法代表真实宿舍网络；校园网登录测试应切换为桥接 Wi-Fi，并确认 Windows 获得 `172.16.0.0/12` 范围内的地址。

## 开发与验证

```powershell
py -3 -m pip install -r requirements.txt
py -3 -m unittest discover -s tests
py -3 scripts\verify_windows_package.py
```

项目结构：

```text
apps/windows_desktop/        Windows Tk 桌面客户端
src/szu_netlogin/            登录、网络检测、控制与安全存储核心
tests/                       核心与 Windows 客户端回归测试
one_click_install_and_run.bat 首次安装入口
start_szu_dorm_login.bat      无控制台窗口启动入口
```

## 平台边界

- `main`：macOS 版本及其状态栏/LaunchAgent/`.app` 构建文件
- `windows`：本分支，只维护 Windows 客户端与 Windows 发布内容
- 两个平台使用独立发布包和标签，不生成混合压缩包

## 注意

本工具只面向深圳大学宿舍区 Dr.COM / ePortal，不处理教学区 srun。门户接口变化时，请先生成脱敏诊断报告，再更新配置或登录核心。
