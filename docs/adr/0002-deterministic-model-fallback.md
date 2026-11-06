# ADR 0002：确定性规则与可选模型，而不是强依赖本地 LLM

- 状态：Accepted
- 日期：2026-11-06

## 背景

目标模型为 Qwen3-ASR、RapidOCR CoreML、Qwen2.5-0.5B Intent、Qwen2.5-3B/7B 巩固。
仓库不能分发 GB 级权重，测试机也没有这些 CoreML 编译产物。

## 决策

默认提供确定性、可离线运行的基线：

- Energy VAD；
- whisper.cpp 命令适配器（可选模型）；
- Apple Vision OCR；
- 规则 Intent Gate；
- 规则 fact 提取；
- 特征哈希 embedding；
- 确定性日报投影。

同时定义 `VoiceActivityDetecting`、`TranscriptionProviding`、`OCRProviding`、`IntentClassifying`、`FactExtracting`、`EmbeddingProviding` 协议，并提供可配置的本地命令模型适配器。

## 后果

正面：

- 无模型也可跑通完整产品闭环；
- 安全策略、schema、MCP、任务状态可独立于模型测试；
- 模型替换不会改变记忆语义；
- 反幻觉优先：日报不依赖生成模型。

负面：

- 默认的语义召回只是特征哈希，不是真正语义 embedding；
- 规则覆盖率和 0.5B/3B 模型不同；
- 默认 ASR 质量取决于用户安装的 whisper 模型；
- 需要在目标机器单独验证 CoreML/ANE 性能与功耗。

## 风险缓释

`docs/MODEL-ADAPTERS.md` 给出每种替换的输入/输出合同与安全要求；测试 fake model fixture 验证命令适配器。
