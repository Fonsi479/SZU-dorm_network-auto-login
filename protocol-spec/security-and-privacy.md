# 安全与隐私设计

## 威胁模型

| 威胁 | 主要控制 |
|---|---|
| 密码泄露 | Keychain/Credential Manager；无明文配置；延迟读取；不进 CLI/环境变量 |
| 完整认证 URL 泄露 | 结构化请求；日志只记事件码；URL query 全部屏蔽 |
| Challenge/Info/Checksum 泄露 | 敏感字段类型，不允许 `CustomStringConvertible`/repr；Redactor 测试 |
| 非校园网误发凭据 | EnvironmentClassifier + PortalIdentityVerifier + source binding + fail-closed |
| 多网卡选错出口 | 目标路由解析、源地址/接口绑定、generation 二次校验 |
| MITM/恶意代理 | TLS 验证、固定 host、代理绕过、重定向限制、不允许 verify=false |
| DNS 劫持 | 证书/Host/SNI 校验；可选 IP 仅改变解析，不改变身份 |
| 配置/诊断越权 | 用户专属目录、0600/ACL、最小字段、导出预览 |
| 进程列表/历史 | 禁止密码参数；CLI 使用凭据引用 |
| 崩溃报告 | 敏感对象不进入异常字符串；关闭请求体/URL采集 |
| 依赖投毒 | lockfile、SBOM、Action 固定 SHA、哈希、最少依赖 |
| 更新劫持 | 签名、公证/Authenticode、HTTPS、版本和哈希验证 |
| 无限重试/账号封禁 | 状态未知不登录、退避、fatal 错误熔断、请求预算 |
| Codex 管家越权 | 只读/高层命令；不读凭据；无开放端口 |

## 请求预算

每个 network generation 默认：

- 门户发现最多 3 次无凭据请求；
- 状态查询最多 2 次；
- Challenge 1 次，过期最多补取 1 次；
- 登录 1 次；
- 登录后状态确认最多 3 次、带短延迟；
- 超出预算进入退避。

## 日志允许字段

版本、平台、Provider、网络类别、generation、事件码、耗时、HTTP 状态码、重试次数、掩码后的账号/地址。禁止：query、body、Cookie、Authorization、密码、哈希、Challenge、Info、Checksum、完整 IP/SSID（默认）。

## 隐私保留

- 普通日志默认 7 天或 5 MB 轮转。
- 诊断包由用户主动生成，应用不自动上传。
- 不收集遥测；若未来加入，必须单独 opt-in 和隐私说明。
