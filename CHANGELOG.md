# Changelog

## v3.1.0 — 2026-11-06

只读整理器。

### Changed

- 移除任务执行：删除 claim/complete/cancel、执行日志、任务风险/确认策略与 L4 程序性记忆。
- 显式意图现在生成 `TodoItem`，状态只由用户通过 CLI/MCP 显式变更。
- MCP 从执行工具转为 16 个只读整理器工具：timeline、todos、contacts、messages、recall、digest、review、status。
- Codex Skill 改为只读：不执行、不发送、不修改、不删除、不调用外部 API。
- 数据 schema 升到 v3；旧 `tasks` 迁移为 `todos`，删除 `execution_logs` 和 `procedural_patterns`。
- 日报“意图与任务”改为“待办”，统计移除 L4。
- 测试、文档、安装脚本同步为只读版本。

### Added

- `get_timeline` / CLI `timeline`：L2+L3 按时间排序的记忆视图。
- `todos` / `todo add|update|delete` 与 MCP `list_todos` / `add_todo` / `update_todo`。
- contacts / contact_channels / messages / message_fts schema。
- `list_contacts` / `upsert_contact` / `list_messages` / `record_message` / `mark_message_read`。
- 跨频道联系人合并、external_id/内容哈希去重、未读状态。
- Unix socket `message` / `contact` 写入协议。
- 172 个 Swift Testing 测试与 organizer 测试套件。

### Removed

- `get_pending_tasks`、`claim_task`、`complete_task`、`cancel_task`、`get_procedural_pattern`。
- `SecretaryTask`、`TaskRisk`、`TaskStatus`、`ExecutionLog`、`ProceduralPattern`、L4。
- 自动执行、确认循环、任务 lease。

### Known limitations

- TCC 授权后的真实 ScreenCaptureKit 实拍未自动化。
- 渠道适配器不在仓库内，只提供本地写入协议。
- 联系人同名可能误合并；消息无单条删除工具。
- SQLite 未加密，依赖 FileVault 与 0700/0600。

## v3.0.0 — 2026-11-06

执行型秘书的历史实现：五层记忆、任务直执、L4 程序性蒸馏。方案见
[docs/archive/PRD-v3.0-execution-baseline.md](docs/archive/PRD-v3.0-execution-baseline.md)。
