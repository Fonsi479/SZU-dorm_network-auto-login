# SZU Campus Network

深圳大学校园网本地客户端：保留宿舍区 Dr.COM / ePortal 基线，并新增教学区 SRun Provider。Dorm 与 Teaching 独立启用、独立保存凭据，由唯一 Coordinator 负责环境门控、互斥、取消、退避和 fatal 熔断。

> 当前 Teaching SRun 仅通过合成向量、离线 Fixture 与本地自动化验证。真实教学区登录、动态 ACID、现场源路由、账号产品后缀以及 SRun 注销均为 `PENDING_CAMPUS_VALIDATION`。Teaching 默认关闭，未证实的注销不会发送请求。

## 下载与版本

当前公开候选是 `2.0.0-beta.1`，不是生产稳定版。GitHub 自动生成的 `Source code` 包含完整双平台源码；普通用户应下载与系统对应的 ZIP，而不是源码包。

| 版本线 | macOS | Windows | 状态 |
|---|---|---|---|
| 2.0 Beta 1 | [`macos-v2.0.0-beta.1`](https://github.com/Fonsi479/SZU-dorm_network-auto-login/releases/tag/macos-v2.0.0-beta.1) | [`windows-v2.0.0-beta.1`](https://github.com/Fonsi479/SZU-dorm_network-auto-login/releases/tag/windows-v2.0.0-beta.1) | 双 Provider；Teaching 默认关闭；分平台 prerelease |
| 1.x Legacy | [`macos-v1.1.0`](https://github.com/Fonsi479/SZU-dorm_network-auto-login/releases/tag/macos-v1.1.0) | [`windows-v1.0.0`](https://github.com/Fonsi479/SZU-dorm_network-auto-login/releases/tag/windows-v1.0.0) | Dorm-only 历史归档，不含 v2 安全修复 |

macOS 与 Windows 始终使用独立 Tag、Release 和资产，但 v2 源码统一由 `main` 维护。完整分支、版本号和晋级规则见 [版本与发行策略](docs/VERSIONING_AND_RELEASES.md)。

注意：历史 `macos-v1.1.0` 实际是 Python/rumps 版本，不是当前 Swift App；它只为回滚与迁移保留。

## 安全原则

- `nonCampus`、`ambiguous`、`unknown`、Provider 关闭或会话状态未知时，读取凭据和认证请求均为 0。
- 手动登录与自动登录执行相同的环境、Portal 身份、源路由和明确离线门控；手动按钮不是绕过入口。
- macOS 使用 Keychain，Windows 使用 Credential Manager；配置、CLI、进程参数、日志和诊断中不保存密码。
- 认证请求绑定目标路由选出的源 IP；SRun 使用 HTTPS 默认 TLS 校验、固定 Portal 主机、禁用系统代理继承和跨主机重定向。
- 任意时刻最多一个认证操作。网络 generation 改变、暂停或退出会取消旧任务，旧结果不得继续发送后续请求。
- 不需要管理员权限，不修改 DNS、路由、VPN 或代理，不安装系统级守护进程，也不开放 localhost HTTP 端口。

完整说明见 [SECURITY.md](SECURITY.md) 与 [PRIVACY.md](PRIVACY.md)。

## Provider 与默认值

| Provider | 协议 | 默认 | 凭据 | 注销 |
|---|---|---:|---|---|
| Dorm | Dr.COM / ePortal | 开启 | 独立 credential reference | 保留已验证基线 |
| Teaching | SRun BX1 | 关闭 | 独立 credential reference | 禁用，等待现场验证 |

两个 Provider 可以分别关闭。两个都开启时，Coordinator 也只会选择唯一 verified Provider；若两者同时 verified，则返回 `ENV_AMBIGUOUS` 并停止。

## 独立发行

macOS 与 Windows 使用同一份协议契约、Fixture 和错误码，但构建物完全独立，不互相携带运行时或桌面代码。

### macOS

- macOS 13 或更新版本；原生 Swift、AppKit/SwiftUI、Network.framework、Security、ServiceManagement。
- 为兼容 1.x 升级、Bundle ID、Keychain 与登录项，App Bundle 仍名为 `SZU Dorm Login.app`；这不表示 v2 仅支持 Dorm。
- 最终 App 不依赖 Python，也不依赖 Codex 管家仓库或外部相对路径 Package。
- 状态栏提供 Dorm/Teaching 状态与开关、暂停/恢复、立即检查、明确登录、设置、诊断和退出。
- App 内附无密码 JSON CLI `szu-campus-netctl`，供脚本或 Codex 管家可选调用。

开发与验证：

```bash
cd macos
swift test --disable-automatic-resolution
swift build --configuration release --disable-automatic-resolution
cd ..
bash scripts/build_app.sh
bash scripts/verify_app.sh
```

App 产物：

```text
dist/SZU Dorm Login.app
```

### Windows

- Windows 10/11；Python 源码通过 PyInstaller 生成两个独立 PE，最终用户无需安装 Python。
- `SZU Campus Network.exe` 是 GUI；`szu-campus-netctl.exe` 是 JSON CLI。
- 密码只通过 GUI 写入 Windows Credential Manager；CLI 不接受密码字段、参数、环境变量或配置值。

源码检查（可在非 Windows 开发机运行）：

```bash
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -v
python3 scripts/verify_windows_package.py --package-root .
```

PE 必须在 Windows 或 Windows CI 中构建：

```powershell
py -3 -m pip install --require-hashes -r requirements-windows.lock
py -3 scripts\build_windows_exe.py --version 2.0.0
py -3 scripts\build_windows_package.py --version 2.0.0 --release-label beta.1
```

## JSON CLI 契约

CLI 从 stdin 读取一个 JSON 对象，stdout 只写一个 JSON 结果对象；stderr 仅允许脱敏诊断。请求不允许包含 `password`、`secret`、`token`、`cookie` 或凭据值。

示例：

```json
{"schemaVersion":1,"requestId":"local-status-1","command":"status","provider":"auto","interactive":false,"timeoutSeconds":15}
```

支持的高层命令为：

```text
status check login logout pause resume open-settings diagnostics
```

`login` 仍须经过 Coordinator 授权后才读取对应系统凭据。Teaching `logout` 返回 `SRUN_LOGOUT_DISABLED`。

## 配置与迁移

配置仅保存 Provider 开关、账号标签、credential reference 与非敏感网络参数，不保存密码。Teaching 在 v2 迁移后仍默认关闭。

macOS 配置与日志：

```text
~/Library/Application Support/szu-netlogin/config.json
~/Library/Logs/szu-netlogin/netlogin.log
```

Windows 配置与日志位于当前用户的本地应用数据目录。迁移不会自动恢复旧客户端、复制明文密码或删除旧文件；发现旧 macOS Python 配置/LaunchAgent 时只提供显式导入与清理路径。

操作前请阅读 [迁移与回滚](docs/MIGRATION_AND_ROLLBACK.md)。

## Codex 管家可选适配

独立 SZUNET App 是认证和凭据的唯一所有者。Codex 管家只能读取脱敏状态并发送高层命令；它不能读取密码，也不拥有 Provider、Coordinator、设置或最终 SZUNET App。

默认边界是稳定 JSON CLI。若本地 Swift Workspace 使用 `SZUNETFeature`，也只能复用公开契约和高层控制，认证实现仍位于本仓库。没有 localhost HTTP 服务。

详见 [Codex 管家适配边界](docs/CODEX_BUTLER_ADAPTER.md)。

## 现场验收边界

本仓库不会在开发机上主动运行真实校园登录、注销或循环探测，也不会断开或重配 Shadowrocket/VPN。返校后应从 Teaching 默认关闭开始，人工、小流量、逐项验证并记录脱敏证据。

- [返校验收清单](docs/CAMPUS_ACCEPTANCE_CHECKLIST.md)
- [发行检查清单](docs/RELEASE_CHECKLIST.md)
- [迁移与回滚](docs/MIGRATION_AND_ROLLBACK.md)

任何未执行的真实网络、Windows Defender/SmartScreen、Authenticode、Apple notarization 或无障碍设备验收都必须继续标为 `PENDING_CAMPUS_VALIDATION` 或 `BLOCKED`，不得写成通过。

## 源码结构

```text
macos/                         原生 Swift App、CLI、SZUNETFeature 与测试
apps/windows_desktop/          Windows Tk GUI
src/szu_netlogin/              Windows/Python Provider、Coordinator 与 CLI
protocol-spec/                 双平台共享 Schema、Fixture、向量和错误码
packaging/windows/             PyInstaller spec
scripts/                       平台构建、验证、SBOM 与发行脚本
docs/                          架构、验收、适配、迁移和发行说明
```

`reports/` 仅保存在开发机且被 Git 忽略；公开仓库和 GitHub Source archive 不包含本机验收记录。

## 分支与历史版本

| 分支 | 用途 | 状态 |
|---|---|---|
| `main` | v2 唯一源码主线：共享协议、macOS、Windows 与可选适配 | 当前维护 |
| `macswift` | macOS Swift 1.x Dorm-only | Legacy，只读保留 |
| `winpython` | Windows Python 1.x Dorm-only | Legacy，只读保留 |
| `macpython` | macOS Python 1.x | EOL 历史归档 |

v2 不再创建长期 `macos-v2` / `windows-v2` 源码分支；平台边界由构建目录、Tag 和 Release 资产保证。历史 Tag 不删除、不重写。

## 开源与第三方事实

项目采用 [MIT License](LICENSE)。SRun 实现为 clean-room 实现；公开 MIT 项目只用于协议事实和黑盒向量交叉验证，没有复制第三方实现源码。详见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

历史 Dorm 参考：

- [1136623363/SZU-Drcom](https://github.com/1136623363/SZU-Drcom)
- [Sleepstars/SZU-login](https://github.com/Sleepstars/SZU-login)
