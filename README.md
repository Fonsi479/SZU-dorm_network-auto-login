# SZU Dorm NetLogin — Windows

深圳大学宿舍区 Dr.COM / ePortal 自动登录图形客户端，当前版本为 `1.2.0`。Windows 与 macOS 使用独立代码、测试和发布包。

## 最简单的使用方式

1. 解压 `SZU-Dorm-Login-Windows-v1.2.0.zip`。
2. 双击 `SZU Dorm Login.exe`。不需要安装 Python，不会弹出命令行窗口，也不需要管理员权限。
3. 首次运行，在“概览”页依次点击“修改账号”和“修改密码”。密码保存在 Windows 系统凭据库。
4. 如需登录 Windows 后自动运行，点击“安装开机自启”。

当前测试包没有商业代码签名证书。若 SmartScreen 显示“未知发布者”，请先核对发布包内 `SHA256.txt`；正式公开分发前应补充 Authenticode 签名。

## 本次协议与网络修补

- 登录请求不再读取或提交本机网卡 MAC。门户页面负责终端 MAC；这样不会误用随机 MAC、物理网卡或虚拟网卡地址。
- MAC 解绑只使用 `chkstatus` / `online_list` 返回的精确会话 MAC；门户注销仍保留页面提供的全零 MAC 占位。
- 自动登录不再由“百度能否打开”决定。只有宿舍网关可达、源 IP 位于配置的校园网段、且门户精确确认当前账号/IP 离线时，才会发送凭据。
- 登录和退出接口的 ACK 都不是最终成功依据；客户端会重新读取 `/drcom/chkstatus` 和精确匹配的 `online_list` 会话。
- 不枚举、不识别、不关闭也不配置 VPN/代理。默认网络出口探测只在门户已确认在线后用于界面展示，不参与自动登录决策。
- 从在线首次变为离线时立即开放一次登录尝试；失败后按 2/5/10/15 分钟退避，避免紧密重试。

两份仍可访问的深圳大学开源脚本也直接调用宿舍 ePortal 登录接口而不读取本机 MAC：[1136623363/SZU-Drcom](https://github.com/1136623363/SZU-Drcom) 和 [munanfan/DrcomAutoLogin](https://github.com/munanfan/DrcomAutoLogin)。它们仅用于核对接口形态；本项目没有沿用其明文密码、外网探测或高频循环设计。

## 图形界面

“概览”页显示：

- 自动登录与暂停状态
- 宿舍网络环境、门户会话、默认网络出口
- 宿舍网关、系统实际选中的源 IP
- 配置路径、开机自启和更新时间

常用操作包括立即登录、检查并登录、退出账号、暂停/恢复自动登录、修改账号/密码和安装/卸载开机自启。“诊断与日志”页提供脱敏日志与诊断报告。

## 本地数据

配置文件：

```text
%APPDATA%\SZU Dorm NetLogin\config.yaml
```

日志文件：

```text
%LOCALAPPDATA%\SZU Dorm NetLogin\Logs\netlogin.log
```

开机自启快捷方式：

```text
%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\SZU Dorm Login.lnk
```

密码不会写入 `config.yaml` 或日志；默认使用 `keyring` 的 Windows 凭据库后端。

## 开发与发布验证

源码测试：

```powershell
py -3 -m pip install -r requirements.txt
py -3 -m unittest discover -s tests
py -3 scripts\verify_windows_package.py
```

Windows 单文件 GUI 构建：

```powershell
py -3 -m pip install -r requirements-build.txt
py -3 scripts\build_windows_exe.py --version 1.2.0
py -3 scripts\build_windows_package.py --version 1.2.0
```

最终产物为：

```text
dist\windows-app\SZU Dorm Login.exe
dist\release\SZU-Dorm-Login-Windows-v1.2.0.zip
```

PyInstaller 必须在 Windows 上生成 Windows 可执行文件，因此仓库的 `windows-ci` 会在 `windows-latest` 上完成打包、无窗口自检和上传。所有测试使用 mock/静态网络数据，不执行真实校园网登录、退出或 VPN 操作。

## 平台边界

- `main`：原生 Swift macOS 客户端。
- `winpython` / `windows`：本 Windows 图形客户端。
- 发布包只包含 `SZU Dorm Login.exe`、`README.txt`、许可证和 SHA-256，不包含 `.py`、`.bat`、PowerShell 或 macOS 文件。

本工具只面向深圳大学宿舍区 Dr.COM / ePortal，不处理教学区 srun，也不用于绕过学校的账号或设备限制。
