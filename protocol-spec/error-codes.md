# 稳定错误码

错误码进入 CLI、日志和 UI 映射；不得把服务器原始消息直接当稳定 API。

| 代码 | 含义 | 自动重试 |
|---|---|---:|
| `ENV_NON_CAMPUS` | 已确认非校园网络 | 否 |
| `ENV_AMBIGUOUS` | 多 Provider/证据冲突 | 否 |
| `ENV_SOURCE_ROUTE_UNVERIFIED` | 源接口/IP 无法约束 | 否 |
| `ENV_PORTAL_IDENTITY_UNVERIFIED` | 域名/证书/入口身份未验证 | 否 |
| `ENV_NETWORK_CHANGED` | generation 已变化 | 新 generation 重试 |
| `CFG_INVALID` | 配置无效 | 否 |
| `CRED_MISSING` | 凭据缺失 | 否 |
| `CRED_STORE_FAILURE` | 系统安全存储失败 | 否 |
| `CRED_MIGRATION_REQUIRED` | 发现旧明文凭据 | 否 |
| `SESSION_ONLINE` | 已在线，无需登录 | 否 |
| `SESSION_OFFLINE` | 明确离线 | 由调度决定 |
| `SESSION_UNKNOWN` | 状态无法确认 | 否 |
| `SRUN_CONFIG_MISSING_ACID` | 入口缺 ACID | 否 |
| `SRUN_CONFIG_MISSING_IP` | 入口缺客户端 IP | 否 |
| `SRUN_CONFIG_CONFLICT` | URL/CONFIG/Challenge 不一致 | 否 |
| `SRUN_JSONP_MALFORMED` | JSONP 格式错误 | 退避后有限重试 |
| `SRUN_CHALLENGE_FAILED` | Challenge 获取失败 | 视网络原因 |
| `SRUN_CHALLENGE_EXPIRED` | Challenge 过期 | 立即重新取一次，随后退避 |
| `SRUN_CRYPTO_VECTOR_MISMATCH` | 加密实现不符合向量 | 否，阻断发布 |
| `AUTH_BAD_PASSWORD` | 密码错误 | 否 |
| `AUTH_ACCOUNT_NOT_FOUND` | 账号不存在 | 否 |
| `AUTH_IP_ALREADY_ONLINE` | IP 已在线 | 先查状态，不盲重试 |
| `AUTH_DEVICE_LIMIT` | 设备数超限 | 否 |
| `AUTH_ACCOUNT_BLOCKED` | 欠费/产品不可用/账号限制 | 否 |
| `AUTH_PRODUCT_SUFFIX_INVALID` | 产品后缀错误 | 否 |
| `AUTH_SERVER_RATE_LIMIT` | 服务端限流 | 长退避 |
| `AUTH_NOT_CONFIRMED` | ACK 后状态仍非在线 | 退避 |
| `NET_DNS_FAILED` | DNS 失败 | 是 |
| `NET_TIMEOUT` | 超时 | 是 |
| `NET_TLS_FAILED` | TLS/证书失败 | 否，禁止降级 |
| `NET_PROXY_INTERCEPTED` | 代理/重定向异常 | 否 |
| `OPERATION_IN_PROGRESS` | 已有认证操作 | 否 |
| `OPERATION_CANCELLED` | 用户/切网/退出取消 | 否 |
| `INTERNAL_ERROR` | 未分类内部错误 | 否，需报告 |
