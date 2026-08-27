# CodexProject Context 读取规则

本仓库只保存精简项目摘要和脱敏元数据，不保存项目源码。

## 默认读取

1. 读取 `current/` 中的精简摘要。
2. 只读取当前任务对应的 `modules/<模块>.md`。
3. 实施时进入该模块真实目录，遵守其 `AGENTS.md`。

除非任务明确需要，不递归读取 `archive/`、`raw/`、`handoffs/`、`automation/`、`logs/`、`cache/` 或 `backups/`，也不读取其他模块源码。

## 安全边界

- 当前不做真实校园网登录、退出或连通性测试。
- 禁止断开、退出或重配 Shadowrocket VPN。
- 不写入账号、密码、Cookie、Token、Key、会话正文或受保护数据。
- 不把元数据摘要当作源码事实；实现级判断必须在目标模块核验。
- 不随意删除文件；历史资料先归档。
