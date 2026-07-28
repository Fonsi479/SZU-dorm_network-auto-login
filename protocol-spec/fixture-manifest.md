# Fixture 清单

所有 Fixture 均为 2026-07-28 人工构造的结构化 Mock，使用 RFC 5737 文档地址和不可复用随机串；不是深圳大学真实响应。

| 文件 | 场景 | 预期 |
|---|---|---|
| `portal_acid_5_sanitized.html` | 用户观察样本 ACID 5 | 解析 acid=5、文档 IP |
| `portal_dynamic_acid_sanitized.html` | 其他 ACID | 解析 acid=17，证明非固定常量 |
| `challenge_success.jsonp` | Challenge 成功 | 解析随机回调和 client_ip |
| `challenge_error.jsonp` | Challenge 失败 | 映射 `SRUN_CHALLENGE_FAILED` |
| `login_success.jsonp` | 登录 ACK 成功 | 仍需后续状态确认 |
| `already_online.jsonp` | IP 已在线 | 查询状态，不重复登录 |
| `login_failure.jsonp` | 密码错误 | `AUTH_BAD_PASSWORD`，不重试 |
| `status_online.jsonp` | `rad_user_info` 在线 | 账号/IP 匹配 |
| `status_offline.jsonp` | 离线 | 允许进入登录决策 |
| `malformed_response.txt` | 损坏 JSONP/尾随脚本 | 拒绝解析，不触发登录循环 |

新增真实 Fixture 时必须：脱敏、注明校区/接入类型/日期、删除 Cookie/Token/账号、替换 IP、人工复核许可证与隐私。
