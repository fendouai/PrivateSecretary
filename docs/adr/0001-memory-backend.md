# ADR 0001：使用嵌入式 SQLite 作为记忆后端

- 状态：Accepted
- 日期：2026-11-06

## 背景

PRD 首选 Wax（单文件、Metal HNSW、原生 MCP），备选 CP Memory（SQLite、治理状态）。
实现需要一个可测试、可离线构建、没有未固定第三方二进制依赖的后端。

## 决策

实现 CP-Memory 风格的本地 SQLite 后端：

- 单文件 `~/.private-secretary/secretary.sqlite`；
- WAL + FTS5；
- facts/episodes/todos/contacts/messages 治理状态；
- 显式 schema 迁移；
- 检索走存储投影，不向上暴露完整记录。

`MemoryStore` 是替换边界。接入 Wax 时保留领域模型、pipeline、MCP、Skill，仅替换 repository/检索实现。

## 后果

正面：

- 无外部依赖，构建稳定；
- FTS5 + SQL 查询可测试；
- 事务、幂等消息去重、review 状态容易实现；
- 10k 规模 p95 43ms，满足目标。

负面：

- 需要自己维护 BM25/向量融合与 schema；
- 未复用 Wax 的 HNSW 性能；
- 没有 Wax 的多 agent 共享文件格式；
- 超过 100k 记忆需要 ANN 或更细的预过滤。

## 不选用的替代

- 直接依赖 Wax：需要未固定的 Swift 包版本/格式，且其治理状态是否满足 L3 review 未验证。
- 自建向量数据库：PRD 明确不建议，调试成本高于价值。
- 远端记忆：违反本地优先。
