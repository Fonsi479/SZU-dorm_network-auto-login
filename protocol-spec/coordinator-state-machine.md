# CampusNetworkCoordinator 状态机

## 状态

```text
idle
probing(generation)
ambiguous
nonCampus
supported(provider)
checkingSession(provider)
online(provider)
offline(provider)
authorizingCredentialUse(provider)
loggingIn(provider)
backingOff(provider, until)
paused
cancelled
fatal(provider, error)
```

## 事件

- appStarted / networkChanged / wake / manualCheck
- autoToggleChanged / providerToggleChanged / pause / resume
- manualLogin / logout
- probeSucceeded / probeFailed
- statusOnline / statusOffline / statusUnknown
- loginSucceeded / loginFailed / cancelled
- generationChanged

## 选择算法

1. 创建新的 `networkGeneration`，取消旧 generation 全部任务。
2. 运行无凭据探测。
3. 分别询问 Provider 的 `supports()`，不并发发送认证请求。
4. 选择结果：
   - 0 个支持：`nonCampus` 或 `ambiguous`；
   - 1 个 verified 支持：进入该 Provider；
   - 2 个支持或证据冲突：`ambiguous`，停止；
   - probable/unknown：仅显示诊断，不自动登录。
5. Provider 开关关闭则不认证。
6. 状态必须明确 `offline` 才能进入凭据授权。
7. 登录后再次状态核验，ACK 不是最终结果。

## 四种开关组合

| Dorm | Teaching | 行为 |
|---|---|---|
| 关 | 关 | 仅无凭据诊断；手动登录也提示先启用 Provider |
| 开 | 关 | 只允许 Dorm；Teaching 证据出现时不尝试 Dorm |
| 关 | 开 | 只允许 Teaching；Dorm 证据出现时不尝试 Teaching |
| 开 | 开 | 识别并只选唯一 Provider；不明确则停止 |

## 退避

- 每个 Provider 独立失败计数：2/5/10/15 分钟封顶，并加 0–15% 抖动。
- 网络 generation 变化清除“旧网络”的退避，但不清除凭据/账号类 fatal 状态。
- 密码错误、账号不存在、欠费、设备超限、产品无效：不自动重试。
- DNS/超时/临时 5xx 可重试；TLS/证书错误视为 fatal，禁止降级。

## 并发不变量

- 全局最多一个认证操作。
- 同一 generation 只允许一个状态查询链。
- Provider 内不能产生未托管后台循环。
- UI 退出时取消所有 Task/线程并等待有限清理时间。
