# Changelog

## v3.2.1 — 2026-11-07

### Added

- 本地 LLM 接入：Ollama + Qwen2.5 1.5B → `scripts/llm-bridge.py` → intent/fact model adapter；纯 localhost。
- Gmail inbox OCR extractor：从 Chrome Gmail 可见 inbox 行提取 sender / subject / time，写入 ContactMessage；纯规则、本地、无网络。
- CLI `secretary message extract-gmail <episode_id>`，可重处理已采集 episode。


真实采集验证与小修复。

- 真实 OCR/ASR 采集测试：7 episodes、3 facts、1 todo、1 contact、2 messages。
- 修复 LaunchAgent consolidate 模板占位符导致的 CLI 路径错误。
- 菜单栏改为 `NSStatusItem` + AppKit 窗口；刘海屏遮挡时自动切 Dock/窗口 fallback。
- 增加真实采集 E2E 报告和截图。
- 测试增至 193 个 Swift Testing 测试。

## v3.2.0 — 2026-11-07

菜单栏 App + 多 Agent 接入 + 可复制上下文。

### Added

- SwiftUI menu bar App `PrivateSecretary.app`：Overview、Timeline、Todos、Contacts、Messages、Settings、权限 onboarding、服务启停、Dashboard、Copy as Context。
- 单 app bundle 内嵌 `secretaryd` / `secretary-mcp` / `secretary`，TCC 身份统一为 `com.privatesecretary.app`。
- `com.privatesecretary.menubar` LaunchAgent。
- `ContextExporter` + `secretary context`：生成可粘贴给 agent 的 Markdown。
- `scripts/install-agent.sh`：Codex / Claude Desktop / Cursor / generic MCP 配置。
- `AGENT-INTEGRATION.md`、`AGENT-POLICY.md`、generic MCP 示例。
- `make app-test`、`make agent-test`。
- 真实采集验证：ScreenCaptureKit 屏幕 OCR + 系统音频 whisper.cpp，7 episodes / 3 facts / 1 todo / 1 contact / 2 messages。
- 修复 LaunchAgent consolidate 模板占位符，新增 install-test 断言。
- 菜单栏 App 改为 `NSStatusItem` + AppKit 窗口；刘海屏 status item 被遮挡时自动切 Dock/窗口 fallback。

### Changed

- 安装脚本从 `PrivateSecretaryCapture.app` 迁移到统一的 `PrivateSecretary.app`。
- MCP 工具仍为 19 个只读整理器；多 Agent 共用 stdio MCP。
- 测试增至 189 个 Swift Testing 测试。

## v3.1.0 — 2026-11-06

只读整理器。

### Changed

- 移除任务执行：删除 claim/complete/cancel、执行日志、任务风险/确认策略与 L4 程序性记忆。
- 显式意图现在生成 `TodoItem`，状态只由用户通过 CLI/MCP 显式变更。
- MCP 从执行工具转为 19 个只读整理器工具：timeline、todos、contacts、messages、recall、digest、review、status。
- Codex Skill 改为只读：不执行、不发送、不修改、不删除、不调用外部 API。
- 数据 schema 升到 v3；旧 `tasks` 迁移为 `todos`，删除 `execution_logs` 和 `procedural_patterns`。
- 日报“意图与任务”改为“待办”，统计移除 L4。
- 测试、文档、安装脚本同步为只读版本。

### Added

- `get_timeline` / CLI `timeline`：L2+L3 按时间排序的记忆视图。
- `get_brief` / CLI `brief`：一次返回 timeline、open todos、未读消息、联系人。
- `dashboard`：自包含只读 HTML（CSP、HTML 转义、0600），无 JS/远程资源。
- `todos` / `todo add|update|delete` 与 MCP `list_todos` / `add_todo` / `update_todo`。
- contacts / contact_channels / messages / message_fts schema。
- `list_contacts` / `upsert_contact` / `list_messages` / `record_message` / `mark_message_read`。
- 跨频道联系人合并、external_id/内容哈希去重、未读状态。
- `message import` / `import_messages`：JSON/JSONL 批量归档；`merge_contacts` 合并重复联系人；`list_messages(query:)` FTS 搜索。
- 并发同 external_id 去重、导入错误报告、Unicode/随机输入鲁棒性测试。
- Unix socket `message` / `contact` 写入协议。
- 189 个 Swift Testing 测试与 organizer/robustness 测试套件。
- 独立 `scripts/e2e-test.sh`：socket → SQLite → MCP 19 tools → CLI → dashboard → digest 全软件栈 E2E。

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
