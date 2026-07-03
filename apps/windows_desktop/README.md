# Windows 桌面客户端

Windows 搬运包只保留一个首次安装入口：

```bat
one_click_install_and_run.bat
```

它会自动完成：

- 优先从清华镜像安装 Python 3.12.10
- 使用清华 PyPI 镜像安装依赖
- 创建本地运行环境 `.venv-szu-dorm-login`
- 创建桌面快捷方式 `SZU Dorm Login`
- 启动客户端

以后直接双击桌面上的 `SZU Dorm Login`。桌面快捷方式使用 `pythonw.exe`，不会常驻黑色命令行窗口。

macOS 状态栏客户端仍在 `src/szu_netlogin/menubar_app.py`，不和 Windows 搬运包混在一起。
