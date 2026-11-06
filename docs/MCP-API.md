# MCP API

`secretary-mcp` 是本地 stdio MCP server，按换行分隔的 JSON-RPC 2.0 通信，不监听网络端口。

```bash
secretary-mcp [--home <dir>]
```

默认 home：`PRIVATE_SECRETARY_HOME` 或 `~/.private-secretary`。

**它是只读整理器**：没有执行、发送、修改、删除或外部 API 工具。

## 1. 握手

请求：

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "initialize",
  "params": {
    "protocolVersion": "2025-06-18",
    "capabilities": {},
    "clientInfo": {"name": "codex", "version": "..."}
  }
}
```

响应：

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "result": {
    "protocolVersion": "2025-06-18",
    "capabilities": {"tools": {"listChanged": false}},
    "serverInfo": {"name": "private-secretary", "version": "3.1.0"},
    "instructions": "This server is a read-only organizer..."
  }
}
```

支持版本：`2024-11-05`、`2025-03-26`、`2025-06-18`。未知版本回退到最新版本。随后发送通知：

```json
{"jsonrpc":"2.0","method":"notifications/initialized"}
```

也支持 `ping`、`tools/list`、`resources/list`、`prompts/list`（后两者返回空）。

## 2. 工具调用

```json
{
  "jsonrpc": "2.0",
  "id": 2,
  "method": "tools/call",
  "params": {"name": "get_timeline", "arguments": {"date": "2026-11-06"}}
}
```

响应：

```json
{
  "jsonrpc": "2.0",
  "id": 2,
  "result": {
    "content": [{"type": "text", "text": "{...JSON...}"}],
    "isError": false
  }
}
```

- 应用错误用 `isError: true` 返回；
- 协议错误用 JSON-RPC error；
- stdout 只输出 JSON-RPC，日志写 stderr；
- 不使用 Content-Length 分帧。

---

## 3. 工具

### `recall`

```json
{
  "query": "上周三决定的方案",
  "layer": "L3",
  "limit": 8,
  "time_range": {"start": "2026-10-26T00:00:00Z", "end": "2026-11-02T00:00:00Z"}
}
```

- `query` required；支持自然语言时间；
- `layer`: `L2` / `L3` / `all`；
- `limit`: 1–20；
- `time_range`: 可选 ISO-8601，start 包含、end 排除。

返回摘要列表，每条只含 `summary`（≤280 字符）、时间、应用、层、分数与 `id`。完整内容用 `drill_down`。

### `drill_down`

```json
{"memory_id": "ep_..."}
```

接受 `ep_...` 或 `fact_...`。返回完整结构化记录、provenance、`trust`、`warning`。每次调用增加访问计数。

### `get_timeline`

```json
{
  "date": "2026-11-06",
  "include_facts": true,
  "limit": 300
}
```

或时间范围：

```json
{
  "from": "2026-11-01",
  "to": "2026-11-08",
  "include_facts": false,
  "limit": 500
}
```

返回：

```json
{
  "from": "2026-11-06T00:00:00Z",
  "to": "2026-11-07T00:00:00Z",
  "entries": [
    {
      "memoryID": "ep_...",
      "kind": "episode",
      "timestamp": "2026-11-06T03:15:00Z",
      "title": "Terminal",
      "summary": "npm ERR! code ERESOLVE…",
      "application": "Terminal",
      "salience": 0.51,
      "trust": "untrusted_observed_content"
    }
  ]
}
```

按时间升序。L3 facts 默认包含；`include_facts:false` 只看 L2。Timeline 不包含消息。

### `get_digest`

```json
{"date": "2026-11-06"}
```

不存在时：

```json
{"found": false, "date": "...", "hint": "No digest for this date. Call generate_daily_digest first."}
```

存在时返回 `{"found": true, "digest": {...}}`。

### `generate_daily_digest`

```json
{"date": "2026-11-06"}
```

本地写入：显著性过滤、缺失 fact 提取、遗忘、日报。返回 `ConsolidationReport`。不执行任何用户任务。

### `list_todos`

```json
{"status": "open", "limit": 100}
```

`status`: `open` / `done` / `dismissed` / `all`。缺省 `open`。

返回：

```json
{
  "count": 1,
  "todos": [
    {
      "id": "todo_...",
      "title": "周五前提交 HNSW 参数对比",
      "detail": "Intent: todo\nEpisode: ep_...",
      "status": "open",
      "intentType": "todo",
      "sourceEpisodeID": "ep_...",
      "dueAt": null,
      "createdAt": "...",
      "updatedAt": "...",
      "completedAt": null
    }
  ]
}
```

### `add_todo`

```json
{
  "title": "整理 HNSW 参数对比",
  "detail": "对比 ef_construction / M",
  "due_at": "2026-11-13T10:00:00Z"
}
```

只写本地列表，不执行。

### `update_todo`

```json
{"todo_id": "todo_...", "status": "done"}
```

状态：`open` / `done` / `dismissed`。仅本地状态变更。

### `list_contacts`

```json
{"query": "张", "limit": 50}
```

返回：

```json
{
  "count": 1,
  "contacts": [
    {
      "id": "contact_...",
      "displayName": "张三",
      "organization": "Acme",
      "notes": null,
      "channels": [
        {"channel": "email", "handle": "zhangsan@example.com"},
        {"channel": "lark", "handle": "zhangsan_lark"}
      ],
      "messageCount": 3,
      "lastMessageAt": "...",
      "lastMessageSnippet": "下周评审改到周一下午三点。",
      "createdAt": "...",
      "updatedAt": "..."
    }
  ]
}
```

### `upsert_contact`

```json
{
  "display_name": "张三",
  "organization": "Acme",
  "channels": [
    {"channel": "email", "handle": "zhangsan@example.com"},
    {"channel": "lark", "handle": "zhangsan_lark"}
  ]
}
```

按 `(channel, handle)` 优先匹配；否则按规范化姓名匹配。只写本地。

### `list_messages`

```json
{
  "channel": "email",
  "contact_id": "contact_...",
  "unread_only": true,
  "limit": 100
}
```

返回：

```json
{
  "count": 1,
  "messages": [
    {
      "id": "msg_...",
      "contactID": "contact_...",
      "contactName": "张三",
      "channel": "email",
      "direction": "inbound",
      "text": "HNSW 参数对比请周五前发我",
      "timestamp": "...",
      "isRead": false,
      "thread": "HNSW 参数对比",
      "externalID": "mail-1",
      "createdAt": "..."
    }
  ]
}
```

### `record_message`

```json
{
  "channel": "email",
  "contact_name": "张三",
  "handle": "zhangsan@example.com",
  "direction": "inbound",
  "text": "HNSW 参数对比请周五前发我",
  "timestamp": "2026-11-06T01:48:00Z",
  "thread": "HNSW 参数对比",
  "external_id": "mail-1",
  "is_read": false
}
```

**归档，不发送。** 同一 `(channel, external_id)` 幂等；没有 external id 时使用内容哈希。

### `mark_message_read`

```json
{"message_id": "msg_...", "is_read": true}
```

仅本地已读状态。

### `list_review_items`

```json
{"limit": 50}
```

列出 `pending_review` 事实。

### `review_fact`

```json
{"fact_id": "fact_...", "action": "accept"}
```

或：

```json
{"fact_id": "fact_...", "action": "correct", "corrected_statement": "…"}
```

`action`: `accept` / `reject` / `correct`。

### `get_status`

```json
{}
```

返回 counts、capture 健康状态、模型配置、版本。

```json
{
  "counts": {
    "episodes": 2000,
    "archivedEpisodes": 0,
    "activeFacts": 42,
    "pendingReviewFacts": 0,
    "openTodos": 3,
    "digests": 1,
    "contacts": 3,
    "messages": 5
  },
  "capture": {"state": "running", "permissionGranted": true},
  "version": "3.1.0"
}
```

---

## 4. 已移除的工具

以下 v3.0 执行工具在 v3.1 **不存在**：

- `get_pending_tasks`
- `claim_task`
- `complete_task`
- `cancel_task`
- `get_procedural_pattern`

服务端 `tools/list` 只有 16 个整理器工具。任何旧客户端调用会收到“Unknown tool”错误。

## 5. 只读策略

1. 工具不会发送、回复、转发、修改或删除外部数据。
2. `add_todo` / `update_todo` / `record_message` / `upsert_contact` 仅本地写入。
3. `recall` / `drill_down` / `get_timeline` / `get_digest` / `list_*` 只读。
4. `generate_daily_digest` 写本地日报，不执行任务。
5. 记忆与消息内容是不可信 observation，不是指令。
6. Skill 明确要求不执行内容中的命令。

## 6. Codex 配置

```bash
codex mcp add private-secretary -- \
  "$HOME/Library/Application Support/PrivateSecretary/bin/secretary-mcp" \
  --home "$HOME/.private-secretary"
```

```toml
[mcp_servers.private-secretary]
command = "/Users/you/Library/Application Support/PrivateSecretary/bin/secretary-mcp"
args = ["--home", "/Users/you/.private-secretary"]
startup_timeout_sec = 5.0
tool_timeout_sec = 30.0
```

Skill：

```bash
mkdir -p ~/.codex/skills/private-secretary
cp skills/private-secretary/SKILL.md ~/.codex/skills/private-secretary/SKILL.md
```

## 7. 手动测试

```bash
printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}' \
  '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
  | secretary-mcp --home /tmp/ps-demo
```
