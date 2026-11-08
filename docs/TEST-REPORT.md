# 测试报告 — PrivateSecretary v3.2.1

**版本**：3.2.1（只读整理版 + 菜单栏 App + 多 Agent）
**日期**：2026-11-06  
**结论**：全部自动化测试、进程冒烟、隔离安装、lint 与 10k soak 通过。未自动化的部分是 TCC 授权后的真实 ScreenCaptureKit 实拍和第三方渠道适配器联调。

---

## 1. 环境

| 项目 | 值 |
|---|---|
| 机器 | MacBook Air M4，10 核，16 GB |
| macOS | 26.6.2（25G83），arm64 |
| Swift | 6.2.3（Command Line Tools，无 Xcode） |
| 数据库 | SQLite 3.51.0，WAL + FTS5 |
| Codex CLI | 0.154.0（隔离 CODEX_HOME 注册测试） |
| 真实 ASR | whisper.cpp `ggml-base.bin`（本机验证，不随仓库分发） |
| OCR | Apple Vision，真实图片 fixture |

Command Line Tools 未把 `Testing.framework` 加入 SwiftPM 默认模块路径；`scripts/test.sh` 会建立符号链接，`Package.swift` 仅在 framework 存在时添加 `-F/-rpath`。Xcode 环境不需要。

---

## 2. 自动化测试

```bash
PRIVATE_SECRETARY_TEST_WHISPER_MODEL=/path/to/ggml-base.bin \
  ./scripts/test.sh
```

```text
✔ Test run with 189 tests in 0 suites passed after 2.692 seconds.
```

| 文件 | 测试数 | 覆盖 |
|---|---:|---|
| `TextAndTimeTests.swift` | 29 | 规范化、中文 bigram、注入、时间解析、日期边界 |
| `MCPRouterTests.swift` | 19 | 19 个整理器工具、brief、批量导入、merge、错误 |
| `PerceptionTests.swift` | 17 | L0、VAD、分段、差分、Vision OCR、WAV、真实 ASR |
| `StorageTests.swift` | 17 | schema、FTS、todo 状态、contact/message、cold、purge |
| `IntentGateTests.swift` | 16 | todo 捕获、系统音频不生成、去重、节流、模型回退 |
| `FactGateTests.swift` | 15 | 去重、矛盾、取代、review、注入、同 episode 去重 |
| `InfrastructureTests.swift` | 14 | socket、锁、配置、候选默认值、模型命令、权限 |
| `PipelineTests.swift` | 14 | L2/L3/todo、重复、排除、系统音频、隐私 |
| `RetrievalTests.swift` | 13 | 混合检索、层/时间过滤、折叠、drill-down、归档 |
| `ConsolidationTests.swift` | 10 | 日报、显著性、todo 投影、遗忘、幂等、转义 |
| `OrganizerExtendedTests.swift` | 9 | JSONL 导入、FTS 消息搜索、merge、brief、dashboard、context、并发去重 |
| `OrganizerTests.swift` | 6 | timeline、排序/范围、联系人/消息便捷 API、v2→v3 迁移 |
| `ProcessIntegrationTests.swift` | 5 | MCP、CLI、daemon、TCC、brief/dashboard/import/context/merge |
| `RobustnessTests.swift` | 5 | 400 条随机时间查询、超长输入、无效导入、Unicode |
| **合计** | **189** | |

### 已验证行为

**只读边界**

- `tools/list` 恰好 19 个工具；
- 不存在 `claim_task` / `complete_task` / `cancel_task` / `get_pending_tasks` / `get_procedural_pattern`；
- MCP initialize instructions 明确 never executes；
- Skill 与 lint 强制只读不变量；
- todo 状态只能通过 `update_todo` 显式修改；
- 消息写入是归档，不发送。

**Brief / dashboard / import**

- `get_brief` 一次返回 timeline/openTodos/unreadMessages/contacts；
- `secretary brief` 与 `--json`；
- `secretary dashboard` 生成自包含 HTML，含 Timeline/Open todos/Unread messages/Contacts，XSS payload 被转义，CSP 存在，文件权限 0600；
- `message import` 支持 JSONL/JSON 数组/单对象，统计 imported/duplicates/failed；
- `merge_contacts` 移动消息和 handle，删除 source；
- `list_messages` 的 `query` 走 message_fts；
- 并发 8 次同一 external_id 只插入一条消息。

**菜单栏 App / 多 Agent**
- `make install-test` 验证 `PrivateSecretary.app` 结构、helper、Info.plist、LSUIElement、三个 LaunchAgent、卸载/保留/清除；
- App 二进制启动 smoke（本地进程保持运行 3 秒）；
- `make agent-test` 验证 Claude Desktop、Cursor、generic 配置，保留无关 key、权限 0600、Codex 配置输出、独立客户端 MCP initialize/tools/list。

**Timeline**

- 指定日期/范围只返回范围内 L2/L3；
- 按时间升序；
- `include_facts:false` 只返回 episode；
- limit 取最近 N 条后按时间升序；
- 每条有 memory_id、摘要、trust。

**Todos**

- 显式意图生成 open todo；
- 系统音频 explicit 降级，不生成 todo；
- done/open/dismissed 状态机；
- 手工 add、删除；
- 日报以 `[ ]` 列出 todo，并带 id；
- 删除 episode 会删除派生 todo。

**Contacts / Messages**

- 同一 handle 跨频道合并联系人；
- 同名兜底；
- 消息 external_id 幂等去重；
- 无 external_id 内容哈希去重；
- `list_messages` 按 channel/contact/unread 过滤；
- 未读状态；
- contact 聚合消息数与最近摘要；
- MCP 工具端到端。

**记忆与安全**

- 质量门：低置信/低显著拒绝、重复 reinforce、矛盾 supersede/review；
- 注入不进入 L3/todo；
- 系统音频不生成 todo；
- recall 摘要折叠；drill-down 全文；
- cold 归档可恢复；
- forget 清 cold、单来源 fact、todo；
- purge 清空 + `secure_delete` + VACUUM；
- 文件权限 0700/0600。

**进程/安装/协议**

- MCP 子进程 initialize → tools/list → tools/call；
- CLI demo/recall/timeline/todos/contacts/messages/digest；
- daemon socket status/ingest/message，SIGTERM 优雅退出；
- 隔离 HOME 安装：二进制、`PrivateSecretary.app`、内嵌 helpers、3 个 LaunchAgent、卸载保留记忆、--purge；
- `make agent-test`：Claude Desktop / Cursor / generic 配置、0600、既有 key 保留、Codex print、独立 MCP 握手；
- Codex `mcp add/list` 在隔离 CODEX_HOME 成功。

---

## 3. 进程冒烟

```bash
./scripts/smoke-test.sh
```

```text
== build ==
== CLI organizer ==
== MCP stdio ==
== daemon socket ==
== Codex registration (isolated CODEX_HOME) ==
SMOKE TEST PASSED
```

验证了：

- demo 产生 7 episodes / 3 todos / 3 contacts / 5 messages；
- `brief`、`dashboard` 输出正常；
- `todos --status all` 返回 3；
- 更新 todo 为 done；
- timeline/contacts/messages/digest；
- MCP 19 工具与 brief/dashboard/import/merge；
- daemon ingest 产生 open todo，message 写入成功。

## 4. 安装测试

```bash
./scripts/install-test.sh
```

```text
INSTALL TEST PASSED
```

覆盖：3 个二进制、`PrivateSecretary.app`（菜单栏 executable + 内嵌 daemon/MCP/CLI）、Info.plist bundle id `com.privatesecretary.app`、3 个 LaunchAgent 渲染无占位符、plutil、记忆初始化、卸载保留数据、--purge。

未触碰真实用户 LaunchAgents 或全局 Codex 配置。

## 5. 性能

Release，真实 pipeline + 100 次混合检索：

### 2,000 事件

```text
accepted=2000/2000 ingest=208/s p50=7.2ms p95=10.0ms max=10.4ms db=3964KiB
SOAK PASSED
```

### 10,000 事件（目标规模）

```text
accepted=10000/10000 ingest=78/s p50=44.5ms p95=55.4ms max=58.4ms db=19116KiB
SOAK PASSED (p95 target 120ms)
```

结论：10k 检索 p95 55.4 ms，低于 120 ms 目标；DB 约 19 MB。Ingest 78/s 足以处理稀疏桌面感知；并发 release build 时略有下降，不影响目标。

## 6. 安全验收

| 检查 | 结果 |
|---|---|
| 无执行/发送/外部 API 工具 | 通过 |
| dashboard XSS 转义/CSP/0600 | 通过 |
| 批量导入去重 | 通过 |
| 并发消息去重 | 通过 |
| 联系人 merge | 通过 |
| 系统音频不生成 todo | 通过 |
| 注入不生成 fact/todo | 通过 |
| todo 状态仅用户显式变更 | 通过 |
| 联系人 handle 合并 | 通过 |
| 消息幂等去重 | 通过 |
| 原始像素/音频无长期 BLOB | 通过 |
| 密码管理器 OCR 前排除 | 通过（代码审查 + pipeline） |
| Secure Input 跳过 OCR | 实现；系统行为未自动化 |
| TCC 拒绝不崩溃、不重试 | 通过 |
| 文件权限 | 通过 |
| forget/purge | 通过 |
| v2→v3 迁移 | 通过 |

## 7. 未自动化/未执行

| 项目 | 原因 | 建议 |
|---|---|---|
| TCC 授权后的 SCK 实拍 | 需手动授权，自动化不能弹窗 | 授权后运行 daemon 检查 status |
| 长时间采集稳定性 | 需 24h+ 真实会话 | 观察内存/日志 |
| 第三方渠道适配器（Email/Lark/WeChat） | 本仓库仅提供写入协议 | 接入只读适配器后联调 |
| 真实 Codex 模型调用 | 需已登录交互会话 | 重启 Codex，触发 skill |
| CoreML/ANE 功耗 | 默认 whisper/Vision/规则 | 替换模型后按目标机测 |
| 多显示器 | 仅主显示器 | 后续扩展 |
| macOS 14/15 | 测试机 macOS 26 | 目标版本回归 |

## 8. 与 v3.1 验收标准对照

| 验收 | 状态 |
|---|---|
| timeline 日期/范围/排序 | 通过 |
| todo 显式意图捕获、手工管理 | 通过 |
| 无执行工具/POLICY | 通过 |
| 联系人跨频道聚合 | 通过 |
| 消息 external id 去重 | 通过 |
| recall 折叠/drill 展开 | 通过 |
| 日报含 todo/memory_id | 通过 |
| 注入不进入 L3/todo | 通过 |
| 系统音频不生成 todo | 通过 |
| 归档/遗忘/purge | 通过 |
| brief/dashboard | 通过 |
| import/merge | 通过 |
| 测试/soak | 通过 |

## 9. 残余风险

1. TCC 实拍和长期稳定性未验证。
2. 渠道适配器可信性由用户负责，恶意适配器可写入伪造消息。
3. 联系人同名可能误合并。
4. Prompt injection 检测是启发式。
5. 只支持主显示器。
6. SQLite 明文，依赖 FileVault 和权限。
7. 无单条消息删除工具（可 purge）。
8. Swift Testing 的 CLT 路径适配属于环境 workaround。

## 9.1 真实采集

真实屏幕 OCR、系统音频 ASR、App UI（Peekaboo）、MCP 真实数据测试见 [真实采集 E2E 报告](REAL-DATA-E2E-REPORT.md)。本轮真实数据为 5 episodes、2 facts、1 todo、1 contact、2 messages、2 digests。

## 10. E2E

本地软件栈 E2E 单独记录在 [E2E 测试报告](E2E-TEST-REPORT.md)：

```bash
./scripts/e2e-test.sh
```

覆盖全新 home、daemon socket、SQLite、MCP 19 tools、CLI、dashboard、digest 和最终状态。
真实 TCC 采集与 Codex 模型闭环未完成，原因在该报告第 4–6 节。

## 11. 复现

```bash
./scripts/lint.sh
PRIVATE_SECRETARY_TEST_WHISPER_MODEL=/path/to/ggml-base.bin ./scripts/test.sh
./scripts/smoke-test.sh
./scripts/e2e-test.sh
./scripts/app-smoke-test.sh
./scripts/install-test.sh
./scripts/agent-integration-test.sh
EVENTS=10000 QUERIES=100 DAYS=7 ./scripts/soak-test.sh
./scripts/verify.sh
```
