# ADR 0004：不依赖 MCP Tasks，采用会话拉取 + 幂等工具

- 状态：Superseded by [ADR 0007](0007-read-only-organizer.md)（v3.1 无任务执行）
- 日期：2026-11-06

## 背景

PRD 指出 Codex 当前不支持 MCP Tasks 扩展；长调用会阻塞当前轮次直到超时。
MCP sampling 已 deprecated，不能作为主动唤醒路径。

## 决策

- `secretary-mcp` 只实现普通 `tools/call`；
- `get_pending_tasks` 在会话开始时同步拉取；
- `claim_task` / `complete_task` / `cancel_task` 幂等；
- 不返回 task handle、不实现轮询协议、不依赖 sampling；
- 工具都在毫秒到秒级完成；
- 夜间巩固用 LaunchAgent，不使用 MCP。

## 后果

正面：

- 兼容当前 Codex/Cursor；
- 无后台异步副作用，安全面更小；
- 任务消费者崩溃时可重试幂等操作。

负面：

- 新任务不会实时唤醒 Codex；下一次会话才消费；
- 若 agent claim 后崩溃，任务会停在 claimed，当前需人工 cancel；
- 没有 MCP Tasks 的进度语义。

## 升级路径

Codex 支持 MCP Tasks 后，可保持现有工具契约，在 `secretary-mcp` 内增加 Tasks 适配层；任务表已经是状态机，可映射到异步任务。
