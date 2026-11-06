# ADR 0007：转为只读整理器，移除任务执行和 L4

- 状态：Accepted
- 日期：2026-11-06
- 取代：ADR 0003（执行来源策略）、ADR 0004（MCP Tasks 降级）

## 背景

v3.0 的 Intent Gate 会把明确意图变成可 claim/execute 的任务，并允许低副作用动作自动执行。这带来：

- 高风险动作确认流程；
- claim/complete 状态机、执行日志、失败恢复；
- L4 程序性记忆蒸馏；
- Skill 必须判断何时执行。

产品方向调整为：用户需要的是可回顾、可整理的上下文，而不是一个会替自己行动的本地代理。

## 决策

1. 移除任务执行、claim/complete/cancel、执行日志、L4。
2. 显式意图只生成 `TodoItem`，状态由用户显式更新。
3. 新增 timeline 读模型（L2+L3）。
4. 新增 contacts/contact_channels/messages，聚合跨渠道只读归档。
5. MCP 移除执行工具，增加 timeline/todo/contact/message 工具。
6. Skill 改为只读，明确禁止发送、回复、修改、删除、外部 API。
7. 数据迁移把旧 `tasks` 转为 `todos`，删除 execution/procedural 表。

## 后果

正面：

- 外部副作用面几乎为零；
- 安全边界简单；
- 无 claim 崩溃/租约问题；
- 更贴合“整理并呈现”的用户价值。

负面：

- 失去自动执行能力；
- 需要外部渠道适配器完成消息同步；
- L4 被移除，程序性学习能力不存在。

## 不再恢复的默认能力

任何未来执行能力都必须重新定义安全边界，不能简单恢复 v3.0 的 claim/complete 工具。
