# Windows 桌面客户端

入口文件：`szu_windows_desktop.py`。

用户应从发布包根目录运行 `one_click_install_and_run.bat`，以后使用桌面快捷方式。客户端通过 `pythonw.exe` 启动；所有后台控制命令、PowerShell 与 netsh 调用均使用隐藏窗口模式。

界面与 macOS 状态栏客户端完全独立：

- “概览”页：网络状态、登录控制、账号密码与 Windows 开机自启
- “诊断与日志”页：配置、日志、报告、暂停重置与脱敏输出
- 关闭窗口：取消仍在运行的控制命令并停止本次后台检查

开发验证：

```powershell
py -3 -m unittest tests.test_windows_desktop
py -3 -m py_compile apps\windows_desktop\szu_windows_desktop.py
```
