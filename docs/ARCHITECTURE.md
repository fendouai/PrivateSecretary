# 架构与实现

本文描述 PrivateSecretary v3.1（只读整理版）的实际结构。产品方案见 [PRD v3.1](PRD-v3.1.md)。

## 1. 设计约束

1. **只读**：没有发送、修改、删除、外部 API 调用或任务执行。
2. **本地优先**：无网络客户端；模型命令由用户显式配置。
3. **写入时结构化**：L2 在摄入时生成，L3 在写入路径与质量门后产生。
4. **原始信号不长期化**：长期 schema 中没有音频/图像 BLOB。
5. **可治理**：L3 事实有状态、来源、取代链和 review。
6. **可替换模型**：VAD/ASR/OCR/Intent/Fact/Embedding 均在协议后。
7. **离线可测试**：规则、质量门、检索、巩固和联系人聚合无需模型。

## 2. 进程与线程

```text
┌────────────────────────────────────────────────────────────┐
│ secretaryd (LaunchAgent)                                   │
│                                                            │
│  SCStreamOutput(screen) ─ Vision OCR ─┐                    │
│  SCStreamOutput(audio) ─ VAD/segment ─┤                    │
│  ASR queue ───────────────────────────┼─ ingest queue       │
│                                       │      │             │
│  UnixSocketServer (0600) ─ ingest ────┘      ▼             │
│                       ├─ message ─────► ContactBook        │
│                       └─ contact ─────►                    │
│                                              SQLite (WAL)   │
└────────────────────────────────────────────────────────────┘
                         ▲
                         │ newline JSON / Unix socket
┌────────────────────────┴───────────────────────────────────┐
│ secretary-mcp (stdio)                                      │
│  MCPRouter → MemoryService → SQLite (WAL, separate process) │
└───────────────▲────────────────────────────▲───────────────┘
                │ JSON-RPC                   │
   PrivateSecretary.app (SwiftUI)      Codex / Claude / Cursor
   ├─ direct read of MemoryService      / generic MCP host
   ├─ permission onboarding             └─ Agent Policy / Skill
   ├─ local todo/read writes
   └─ copy context / dashboard
```

- Capture 与 Preprocessing 合并在 `secretaryd` 内，避免第二个 TCC 身份与音频帧 IPC。
- `PrivateSecretary.app` 是 SwiftUI 菜单栏壳：直接通过 `MemoryService` 读 SQLite，管理 LaunchAgent/内嵌 daemon，展示权限、timeline、todos、contacts、messages；不持有采集线程。
- MCP 独立进程，通过 WAL 并发只读；`generate_daily_digest`、todo/message 写操作使用短事务。
- `MemoryStore` 用单连接 + `NSLock`，写事务 `BEGIN IMMEDIATE`；读取投影避免反序列化全量 transcript。
- Capture screen/audio 各有串行队列；ASR、ingest 串行；intent gate 与向量缓存内部加锁。

## 3. 数据流

### 3.1 摄入

```text
CandidatePacket
  │ exclusions / empty / symbolic / duplicate
  ▼
salience score (reward/error/novelty/emotion/goal/access)
  │
  ▼
L2 Episode INSERT
  ├─ Fact extraction (rules/model) → FactQualityGate → L3
  └─ IntentGate
        ├─ none / uncertain: audit only
        ├─ system audio: no todo
        └─ explicit + allowed source: TodoItem (no execution)
```

规则：

- **先保存 L2，再提取 L3**；
- **intent 只读 transcript，不读 OCR**；
- **系统音频不生成 todo**；
- **没有 claim/execute**；
- 去重在 L2 前完成（最近 120s，Jaccard）；
- 排除应用在 OCR 前跳过。

### 3.2 时间线

`MemoryService.timeline(in:includeFacts:limit:)`：

- L2：查询时间范围内 episodes（含 archived 摘要），时间戳 `startedAt`；
- L3：查询 active facts，按 `createdAt`（来源事件时间）落入范围；
- 按时间戳升序返回；最多 `limit` 条，取最近 limit 条后升序；
- 每条只含摘要 ≤240 字符、来源 id、trust。

Timeline 不经过相关性排序，不混入消息；消息是独立视图。`dailyBrief` 把 timeline、open todos、unread messages、contacts 组合成一个只读快照；`DashboardRenderer` 把它渲染为自包含、HTML 转义、CSP 限制的只读 HTML；`ContextExporter` 生成裁剪后的 Markdown，供菜单栏 App 或 CLI `secretary context` 复制给 agent。

### 3.3 巩固

```text
day's L2 episodes
  → cluster (app + ≤10min gap)
  → significance filter (threshold, max 4/cluster)
  → missing fact extraction (shared FactWriter)
  → digest: key episodes + facts + todos
  → forget(): weight < threshold → cold JSONL
```

v3.1 没有 L4 蒸馏。日报是数据库投影，不做自由生成。

### 3.4 检索

```text
query
  ├─ temporal parser → DateInterval + stripped query
  ├─ BM25 (FTS5) ─────────────┐
  ├─ vector (384d, cached) ───┼─ weighted score
  ├─ recency / salience ──────┘
  ▼
top summaries → drill_down only on request
```

```text
score = 0.52×lexical + 0.30×vector + 0.10×recency + 0.08×salience
```

- 有查询词时，词法与向量都不足的候选被过滤；
- L3 时间过滤接受 `fact.createdAt` 或 `fact.updatedAt` 落入范围；
- 折叠摘要 ≤280 字符；
- `drill_down` 增加 access count，反馈遗忘权重。

## 4. 存储 schema（v3）

数据库：`~/.private-secretary/secretary.sqlite`，WAL，`user_version=3`。

| 表 | 关键列 |
|---|---|
| `episodes` | id, started_at, ended_at, app, window, source, origin, transcript, ocr_text, ocr_regions, summary, keywords, salience, signals, provenance, access, archived, trust |
| `episode_fts` | FTS5(episode_id, search_text) |
| `semantic_facts` | id, kind, subject, predicate, object_value, statement, confidence, salience, status, trust, sources, supersedes_id, superseded_by_id, evidence_count |
| `fact_fts` | FTS5(fact_id, search_text) |
| `todos` | id, title, detail, status, intent_type, source_episode_id, due_at, timestamps |
| `contacts` | id, display_name, normalized_name, organization, notes, timestamps |
| `contact_channels` | contact_id, channel, handle; UNIQUE(channel, handle) |
| `messages` | id, contact_id, channel, direction, text, timestamp, is_read, thread, external_id, dedupe_key; UNIQUE(channel, dedupe_key) |
| `message_fts` | FTS5(message_id, search_text) |
| `digests` | date, generated_at, markdown, entries, stats |
| `intent_audits` | classification, confidence, intent_type, episode, reason, policy |
| `meta` | key/value |

没有音频/图像 BLOB。

### 4.1 旧 schema 迁移

从 v2 启动时：

1. 创建 v3 表；
2. 将旧 `tasks` 复制到 `todos`：completed→done，cancelled/failed→dismissed，其余 open；
3. 删除 `execution_logs`、`procedural_patterns`、`tasks`；
4. 设置 `user_version=3`。

## 5. 状态机

### Episode

```text
hot ──retention low + age ≥ minRetention──► archived (cold JSONL)
```

归档后摘要仍可检索，drill-down 可从 cold 恢复全文。

### SemanticFact

```text
active ──higher-confidence conflict──► superseded
new conflict ──ambiguous──► pending_review ──accept/correct──► active
                                           └─reject──► retracted
```

### Todo

```text
open ⇄ done
open ⇄ dismissed
```

状态只由用户显式操作（CLI/MCP）。没有 claim、没有执行者、没有自动完成。

### Contact / Message

- Contact 由 `(channel, handle)` 优先匹配，否则按 normalized name；
- Message 的 dedupe key：`external_id` 或内容哈希；
- 唯一约束 `(channel, dedupe_key)`；
- 未读状态仅本地。

## 6. 消息聚合

`recordMessage` 单事务：

1. 按 handle 或姓名查找 contact；
2. 不存在则创建；
3. 插入/忽略 channel handle；
4. 计算 dedupe key；
5. 存在则返回已有 message（幂等）；
6. 插入 message + FTS；
7. 更新 contact 时间。

`listContacts` 用聚合查询返回消息数、最近消息时间和摘要；`listMessages` 按 timestamp 倒序，可 filter channel/contact/unread/query（message_fts）。

`mergeContacts` 在一个事务中把 source 的消息和 channel handles 移到 target，再删除 source；`importMessages` 支持 JSON 数组/JSONL 批量归档并去重。

**不发送消息。** 这是归档 API。

`EmailScreenExtractor` 在写入屏幕 episode 后，仅对 Gmail inbox 页面做确定性 OCR 行提取（sender / subject / time → ContactMessage），无网络、无邮箱密码；其他页面不处理。可用 `secretary message extract-gmail <episode_id>` 重处理旧 episode。

## 6.1 MCP / CLI 视图

MCP 的 19 个工具分为：

- 记忆：`recall`、`drill_down`、`get_timeline`、`get_digest`、`generate_daily_digest`、`get_brief`；
- todo：`list_todos`、`add_todo`、`update_todo`；
- contact/message：`list_contacts`、`upsert_contact`、`merge_contacts`、`list_messages`、`record_message`、`import_messages`、`mark_message_read`；
- 治理：`list_review_items`、`review_fact`；
- 状态：`get_status`。

CLI 额外提供 `secretary dashboard`（静态 HTML）、`secretary context`（粘贴给 agent 的 Markdown）与 `secretary message import`。

## 6.2 菜单栏 App

`Sources/PrivateSecretaryApp`：

- `NSStatusItem` + AppKit `NSWindow` 承载 SwiftUI views；LSUIElement；在刘海屏上若 status item 被 notch 遮挡，自动切到 regular app + Dock 窗口 fallback；
- Overview：状态、权限、服务启停、复制 Daily Brief、Dashboard；
- Timeline：按天读取 `brief`，点击 `drill_down`；
- Todos / Contacts / Messages：只读列表 + 本地状态写；
- Settings：路径、版本、模型、麦克风开关；
- `ContextExporter` 生成裁剪后的 Markdown 上下文；
- 内嵌 `Contents/Helpers/secretaryd`、`secretary-mcp`、`secretary`，TCC 身份统一到 `com.privatesecretary.app`。

## 6.3 多 Agent

`scripts/install-agent.sh` 生成/合并：

- Codex：`~/.codex` MCP + Skill；
- Claude Desktop：`~/Library/Application Support/Claude/claude_desktop_config.json`；
- Cursor：`~/.cursor/mcp.json`；
- generic：任意 MCP JSON。

所有 host 共用同一个 stdio MCP，配置写入 0600，保留无关 key。协议与边界见 [Agent 接入](AGENT-INTEGRATION.md)。

## 7. 安全边界

| 边界 | 实现 |
|---|---|
| 无执行 | 没有执行工具/日志/L4；Skill 只读 |
| 内容/指令分离 | OCR 不进入 intent；fact 注入拦截；MCP trust 标记 |
| 系统音频 | 不生成 todo |
| 写入门 | confidence/salience、去重、矛盾、injection |
| 联系人合并 | handle 优先；姓名兜底 |
| 消息去重 | external id/content hash + unique |
| TCC | preflight 失败即终态；socket/MCP 继续可用 |
| 密码管理器 | OCR 前排除；Secure Input 跳过 |
| 删除 | forget/purge；SQLite secure_delete + vacuum |

## 8. 失败模式

| 失败 | 行为 |
|---|---|
| Screen Recording 未授权 | `capture_unavailable`，不重试 |
| ASR 未配置 | 屏幕 OCR 继续，音频跳过 |
| SCK stream 停止 | 状态更新，daemon 不自动无限重启 capture |
| SQLite busy | busy timeout + WAL |
| 模型命令超时 | 规则回退 |
| 巩固提取失败 | 保留 L2，继续 digest |
| cold 损坏 | 跳坏行，摘要仍可检索 |
| SIGTERM | 停止 socket/capture，写 stopped |

## 9. 性能

Release、Apple M4、16 GB：见 [测试报告](TEST-REPORT.md) 的 soak 结果。关键手段：

- 检索投影只读必要列；
- 向量按 id 缓存；
- FTS 候选排序 + limit；
- 联系人列表聚合查询；
- 串行 ingest 避免写竞争。

## 10. 已知边界

1. 真实 TCC ScreenCaptureKit 实拍与长期稳定性需本机授权验证。
2. 只采集主显示器。
3. 默认模型是 whisper.cpp/Vision/规则；PRD 目标 CoreML 模型通过协议替换。
4. 特征哈希向量是离线兜底，不是神经 embedding。
5. SQLite 未加密，依赖 FileVault 与 0700/0600。
6. 渠道适配器不在本仓库；需要外部只读同步器通过 CLI/socket/MCP 写入。
7. 联系人同名合并可能误合并；handle 优先缓解。
8. L0 屏幕环是事件元数据，不是可回放帧。
