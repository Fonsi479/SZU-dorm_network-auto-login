# Windows 桌面客户端

入口文件：`szu_windows_desktop.py`；最终用户运行 PyInstaller 生成的 `SZU Dorm Login.exe`，无需 Python 或命令行。

界面与 macOS 状态栏客户端完全独立：

- “概览”页：门户会话、网络状态、登录控制、账号密码与 Windows 开机自启。
- “诊断与日志”页：配置、日志、报告、暂停重置与脱敏输出。
- 关闭窗口：停止状态刷新；源码模式下还会终止仍在运行的隐藏控制子进程。

冻结版在后台工作线程内执行控制动作并把输出送回 GUI，避免 `--windowed` 程序缺少标准输出，也避免单文件程序每次点击按钮都重新解压运行时。

开发验证：

```powershell
py -3 -m unittest tests.test_windows_desktop
py -3 -m py_compile apps\windows_desktop\szu_windows_desktop.py
py -3 scripts\build_windows_exe.py --version 1.2.0
```
