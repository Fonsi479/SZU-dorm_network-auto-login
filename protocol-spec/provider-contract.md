# NetworkAuthProvider 契约

## 接口

```text
providerID
probeEnvironment(context) -> ProviderProbe
supports(context) -> SupportDecision
sessionStatus(context) -> SessionResult
login(context, credentialHandle) -> AuthResult
logout(context) -> AuthResult
cancelPendingOperations(generation)
diagnostics(context) -> SanitizedDiagnostics
```

## 前置条件

- `login()` 只能由 Coordinator 调用。
- Coordinator 已验证：网络 generation 未变化、Provider 唯一、门户身份可信、源路由可约束、用户开关开启、会话明确离线。
- Provider 接收的是不可打印的 `CredentialHandle`，而不是 UI 传来的字符串密码。

## ProviderProbe

```text
provider
support: supported | unsupported | ambiguous
confidence: verified | probable | unknown
portalIdentity
sourceInterface
sourceIP
clientIP
acID
evidence[]
expiresAt
sanitizedDiagnostics
```

## SessionResult

```text
state: online | offline | unknown | blocked
accountMatch: true | false | unknown
clientIP
product
serverCode
message
retryable
```

`unknown` 不得被 Coordinator 当作 `offline`。

## AuthResult

```text
outcome: succeeded | unchanged | failed | cancelled | blocked
provider
sessionState
accountState
clientIP
acID
errorCode
serverCode
retryable
message
sanitizedDiagnostics
timestamp
```

## 安全不变量

1. Provider 不修改 DNS、路由、代理、VPN 或系统证书。
2. Provider 不记录凭据、Challenge、Info、Checksum、完整 URL。
3. 登录前后二次检查 generation；切网后结果作废。
4. 状态失败不会自动触发登录。
5. Provider 不能递归重试；只返回 `retryable`，由 Coordinator 统一退避。
6. HTTP 重定向必须由环境探测器显式处理，认证请求默认禁止跨主机重定向。
