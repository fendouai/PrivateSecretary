# ADR 0003：按来源限制自动执行，系统音频永不自动执行

- 状态：Superseded by [ADR 0007](0007-read-only-organizer.md)（v3.1 移除执行后不再适用）
- 日期：2026-11-06

## 背景

全天候系统音频包含会议、视频、他人的对话。即使出现“帮我记一下”，也不一定是用户在对系统说话。
PRD 允许麦克风/混合来源，并在风险一节要求降低误触发。

## 决策

- `AudioOrigin`：`microphone | mixed | manual | system`。
- 只有 microphone/mixed/manual 允许 `auto`。
- system 来源即使规则或模型返回 explicit，也降级为 uncertain，不创建任务。
- 风险边界由 `IntentType` 决定：
  - auto：record / track / remind / todo；
  - confirm_required：send / modify / delete / external_api。
- 模型不能覆盖 `requires_confirmation`。

## 后果

正面：

- 极大降低“会议里别人的话”意外执行；
- 安全边界可测试、可审计；
- 与 Skill 的双重硬编码一致。

负面：

- 只采系统音频的默认配置下，用户不能通过说话自动创建任务；
- 用户要获得语音直执，需要启用麦克风并授予权限；
- mixed 来源仍可能混入系统音频，需用户知晓。

## 备选

- 只靠 0.5B 门控：confidence 高时仍可能误判，不可接受。
- 系统音频也自动执行：违反“高副作用不可逆”的产品原则。
