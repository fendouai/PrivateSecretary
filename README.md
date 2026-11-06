# PrivateSecretary

本地、只读的个人上下文整理器。持续感知系统音频与屏幕变化，在写入时完成结构化提取，通过显著性驱动的巩固形成可回溯的记忆；把明确的意图整理成 todo，把各渠道消息汇总成 contact/message 列表。

**没有任务执行。没有发送、修改、删除或外部 API 调用。**

- **记忆 → timeline**
- **任务 → todo list**
- **联系人消息 → contact list / message list**

> 产品名保持 **PrivateSecretary**（展示名 Private Secretary）。当前版本 **3.1.0**，只读整理版。

---

## 当前状态

| 项目 | 状态 |
|---|---|
| Swift Package / CLI / MCP / daemon | 可构建、可运行 |
| 自动化测试 | **172 个 Swift Testing 测试全部通过** |
| CLI + MCP + daemon 进程级冒烟 | 通过 |
| 10,000 条记忆检索 soak（release） | p95 **54.9 ms**，目标 < 120 ms |
| Vision OCR | 本机真实图片识别通过 |
| whisper.cpp ASR | 本机真实语音模型调用通过（可选模型） |
| ScreenCaptureKit | 编译通过；TCC 授权后的真实采集需用户本机验证 |
| LaunchAgent 安装 | 隔离 HOME 安装/卸载/清除通过 |

v3.1 移除了 v3.0 的任务执行、claim/complete、执行日志与 L4 程序性记忆。历史方案见 [归档 PRD](docs/archive/PRD-v3.0-execution-baseline.md)，当前方案见 [PRD v3.1](docs/PRD-v3.1.md)。

## 快速开始

```bash
swift build

DEMO_HOME=$(mktemp -d)
.build/debug/secretary --home "$DEMO_HOME" demo

.build/debug/secretary --home "$DEMO_HOME" timeline
.build/debug/secretary --home "$DEMO_HOME" todos
.build/debug/secretary --home "$DEMO_HOME" contacts
.build/debug/secretary --home "$DEMO_HOME" messages
.build/debug/secretary --home "$DEMO_HOME" recall "视频里 HNSW 参数说了什么"
```

演示会写入 7 条跨两天情景、4 条事实、3 个 todo，以及 3 个联系人 / 5 条跨渠道消息。

### 记录消息

```bash
secretary message add \
  --channel email \
  --contact 张三 \
  --handle zhangsan@example.com \
  --direction inbound \
  --text "HNSW 参数对比请周五前发我"
```

这是**归档**，不会发送。联系人会自动按 `(channel, handle)` 或姓名合并。

### 管理 todo

```bash
secretary todos
secretary todo add "周五前提交 HNSW 参数对比"
secretary todo update todo_... --status done
```

没有 claim/execute；状态只由用户显式变更。

### 启动 MCP

```bash
.build/debug/secretary-mcp --home "$DEMO_HOME"
codex mcp add private-secretary -- "$PWD/.build/debug/secretary-mcp" --home "$DEMO_HOME"
```

安装 Skill：

```bash
mkdir -p ~/.codex/skills/private-secretary
cp skills/private-secretary/SKILL.md ~/.codex/skills/private-secretary/SKILL.md
```

或：

```bash
./scripts/install-codex.sh
```

---

## 三个视图

### 1. Timeline

```bash
secretary timeline
secretary timeline 2026-11-06 --days 3
secretary timeline --no-facts --limit 100
```

按日期返回 L2 episodes 与 L3 facts，按时间升序。每条带 `memory_id`，可用 `secretary drill` 展开。

### 2. Todo list

```bash
secretary todos [--status open|done|dismissed|all]
secretary todo add <title> [--detail ...] [--due ISO]
secretary todo update <id> --status done
secretary todo delete <id>
```

Todo 来自：

- 用户显式输入的意图（“帮我记一下……”“提醒我……”）；
- 用户主动添加。

系统音频中的话不会生成 todo。Todo 不会被执行。

### 3. Contacts / Messages

```bash
secretary contacts [--query 张]
secretary contact add --name 张三 --org Acme --channel email:zs@example.com
secretary messages [--channel email] [--contact contact_...] [--unread]
secretary message add --channel lark --contact 张三 --handle zs_lark --text "..."
```

Contact 列表聚合：

- 渠道与 handle；
- 消息数；
- 最近消息时间和摘要。

Message 列表聚合：

- 渠道、联系人、方向（inbound/outbound）；
- 未读状态；
- external_id 去重；
- 本地归档，不发送。

渠道适配器可以把消息写入：

```bash
# Unix socket
printf '{"op":"message","channel":"wechat","contact_name":"李四","handle":"lisi_wx","text":"..."}\n' \
  | nc -U ~/.private-secretary/run/secretaryd.sock
```

或直接通过 MCP `record_message`。

---

## 只读边界

| 能力 | 是否存在 |
|---|---|
| 读取记忆/timeline | 是 |
| 读取/添加/更新 todo | 是（仅本地列表状态） |
| 读取/归档 contact/message | 是 |
| 发送消息 | **否** |
| 回复/转发 | **否** |
| 修改/删除外部内容 | **否** |
| 调用外部 API | **否** |
| claim/execute/complete 任务 | **否** |
| L4 执行模式 | **否** |

MCP 工具集中没有 `claim_task`、`complete_task`、`cancel_task`、`get_pending_tasks`、`get_procedural_pattern`。Skill 明确禁止把记忆或消息内容当指令执行。

---

## 五层 → 四层

v3.1 保留 L0–L3，移除 L4：

| 层 | 实现 |
|---|---|
| L0 | 60s 音频环形缓冲、30 个屏幕变化事件（仅内存） |
| L1 | 候选包、规则/模型门控、结构化提取 |
| L2 | episode：ASR/OCR、时间、app/window、provenance |
| L3 | fact：来源、状态、取代链、review |

没有执行，就没有程序性执行模式。日报、显著性和遗忘仍按 L2→L3 投影运行。

---

## MCP 工具

| 工具 | 用途 |
|---|---|
| `recall` | 混合检索摘要 |
| `drill_down` | 展开完整记忆 |
| `get_timeline` | 记忆 timeline |
| `get_digest` | 读取日报索引 |
| `generate_daily_digest` | 生成日报（本地写入） |
| `list_todos` | 读取 todo list |
| `add_todo` | 添加 todo |
| `update_todo` | 标记 open/done/dismissed |
| `list_contacts` | 联系人聚合 |
| `upsert_contact` | 创建/更新联系人 |
| `list_messages` | 跨渠道消息列表 |
| `record_message` | 归档一条消息 |
| `mark_message_read` | 本地已读状态 |
| `list_review_items` | 待审核事实 |
| `review_fact` | 接受/拒绝/纠正事实 |
| `get_status` | 健康状态 |

完整参数见 [MCP API](docs/MCP-API.md)。协议为 stdio JSON-RPC 2.0，无网络监听。

---

## 架构

```text
Capture daemon (secretaryd)
  ScreenCaptureKit ── Vision OCR
  system audio ── Energy VAD ── whisper.cpp
  manual / Unix socket
        │
        ▼
  IngestPipeline
    ├── L2 Episode (SQLite + FTS5)
    ├── FactQualityGate → L3 Fact
    └── IntentGate → Todo (read-only)
        │
  ContactBook ← message/contact socket
    ├── contacts / contact_channels
    └── messages / message_fts
        │
        ▼
  secretary-mcp (stdio)
        │
      Codex Skill (read-only)
```

- SQLite WAL + FTS5；
- BM25 + 384 维特征哈希向量；
- 时间解析与摘要折叠；
- 显著性巩固、cold 归档；
- 本地文件权限 0700/0600；
- 无网络客户端。

详细设计见 [架构](docs/ARCHITECTURE.md)。

---

## 安装为常驻服务

```bash
./scripts/install.sh              # release、LaunchAgents、Capture.app、Codex MCP/Skill
./scripts/install.sh --no-codex   # 不修改 Codex
```

然后授予 Screen Recording：

```bash
./scripts/request-permissions.sh
launchctl kickstart -k gui/$(id -u)/com.privatesecretary.daemon
```

查看状态：

```bash
secretary doctor
secretary status
```

卸载：

```bash
./scripts/uninstall.sh          # 保留记忆
./scripts/uninstall.sh --purge  # 删除 ~/.private-secretary
```

未授予 TCC 时 daemon 不崩溃、不重试，MCP/CLI 仍可读取已有数据。

系统音频 ASR 可选：

```bash
brew install whisper-cpp
mkdir -p ~/.private-secretary/models
curl -L -o ~/.private-secretary/models/ggml-base.bin \
  https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin
```

然后在 `~/.private-secretary/config.json` 设置 `capture.whisperModel`，见 [运维手册](docs/OPERATIONS.md)。

---

## 测试

```bash
make test          # Swift Testing 套件
make smoke         # CLI + MCP + daemon + 隔离 Codex 注册
make install-test  # 隔离 HOME 安装/卸载/清除
make lint
make soak          # release 2k 事件 + 100 检索
make verify        # 全部
```

在只安装 Command Line Tools 的机器上，Swift Testing 模块不在 SwiftPM 默认搜索路径；`scripts/test.sh` 会处理。使用完整 Xcode 的机器不需要。

本机实测见 [测试报告](docs/TEST-REPORT.md)。

---

## 隐私

- L0 原始像素/波形只在内存；
- L2 只存结构化文本/OCR 区域；
- L3 每条事实有来源；矛盾进 review；
- 消息内容是不可信数据，不是指令；
- 排除应用在 OCR 前跳过，Secure Input 时跳过 OCR；
- 没有外部发送/API 路径；
- `forget` / `purge --all --yes` 删除本地数据；
- 文件权限 0700/0600，建议 FileVault。

完整威胁模型见 [安全与隐私](docs/SECURITY-PRIVACY.md)。

---

## 模型适配器

默认使用规则/whisper.cpp/Vision 的离线基线；接口保持可替换：

| 能力 | 默认 | 替换 |
|---|---|---|
| VAD | Energy VAD | Silero CoreML |
| ASR | whisper.cpp CLI | Qwen3-ASR 0.6B |
| OCR | Vision | RapidOCR/PaddleOCR CoreML |
| Intent | 规则 + 可选命令模型 | Qwen2.5-0.5B ANE |
| Fact | 规则 + 可选命令模型 | 3B/7B MLX |
| Embedding | 特征哈希 | CoreML/MLX embedding |

详见 [模型适配器](docs/MODEL-ADAPTERS.md) 与 [config.example.json](config.example.json)。

---

## 仓库结构

```text
Package.swift
Sources/
  SecretaryKit/
    Models/         四层记忆、todo、contact、message、timeline
    Config/
    Storage/        SQLite schema v3、投影、cold archive
    Text/           规范化、中文 bigram、时间解析、注入检测
    Retrieval/      BM25 + 向量、折叠、drill-down
    Pipeline/       写入、fact 提取、质量门
    Intent/         只读 todo 捕获
    Consolidation/  日报、显著性、遗忘
    Service/        MemoryService、views
    MCP/            16 个整理器工具
    Capture/        L0、VAD、分段、Vision OCR、whisper、SCK
    Support/
  secretary/        CLI
  secretary-mcp/    stdio MCP
  secretaryd/       daemon + capture + socket
Tests/              172 个 Swift Testing 测试
skills/private-secretary/SKILL.md
launchd/
scripts/
docs/
```

## 文档

- [PRD v3.1](docs/PRD-v3.1.md)
- [架构](docs/ARCHITECTURE.md)
- [MCP API](docs/MCP-API.md)
- [运维](docs/OPERATIONS.md)
- [安全与隐私](docs/SECURITY-PRIVACY.md)
- [模型适配器](docs/MODEL-ADAPTERS.md)
- [测试报告](docs/TEST-REPORT.md)
- [架构决策](docs/adr/)
- [历史 PRD v3.0](docs/archive/PRD-v3.0-execution-baseline.md)

## License

MIT. 见 [LICENSE](LICENSE)。
