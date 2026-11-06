# 模型适配器

参考实现默认不加载大模型，但把每一层感知/推理定义在协议后面，便于替换为 PRD 的 CoreML/MLX 目标模型。

## 1. 替换点总览

| 协议 | 文件 | 默认实现 | 目标 |
|---|---|---|---|
| `VoiceActivityDetecting` | `Capture/Sensory.swift` | `EnergyVAD` | Silero VAD CoreML/ANE |
| `TranscriptionProviding` | `Capture/ASR.swift` | `WhisperCLITranscriber` | Qwen3-ASR 0.6B CoreML |
| `OCRProviding` | `Capture/VisionOCR.swift` | `VisionOCRService` | RapidOCR / PaddleOCR mobile CoreML |
| `IntentClassifying` | `Pipeline/ModelCommandClient.swift` | 规则，可选命令模型 | Qwen2.5-0.5B int8 ANE |
| `FactExtracting` | `Pipeline/FactExtraction.swift` | 规则，可选命令模型 | 0.5B–3B / MLX |
| `EmbeddingProviding` | `Retrieval/HybridRetriever.swift` | 384 维特征哈希 | CoreML/MLX embedding |

替换实现只需满足协议；pipeline、质量门、MCP 协议、存储 schema 不需要改动。

## 2. 命令模型协议

`intentGate.model` 和 `factGate.model` 是通用 `CommandModelConfig`：

```json
{
  "enabled": true,
  "executable": "/Users/you/bin/ps-model",
  "arguments": ["--json"],
  "timeoutSeconds": 20,
  "maxOutputBytes": 1048576
}
```

- 进程从 stdin 读取一个 JSON 对象，向 stdout 写一个 JSON 对象。
- 不得向 stdout 写日志。
- 超时后进程被终止；Intent Gate 回退到规则，fact 提取回退到规则提取。
- `executable` 为空或不可执行时视为未配置。
- 这是**用户显式信任的本地命令**。不要配置来源不明的脚本。

### 2.1 Intent 分类

请求：

```json
{
  "task": "classify_intent",
  "version": 1,
  "text": "帮我发邮件告诉张三方案下周评审",
  "application": "Mail",
  "window_title": "Draft",
  "audio_origin": "microphone"
}
```

期望响应：

```json
{
  "classification": "explicit",
  "confidence": 0.94,
  "intent_type": "send",
  "routed_text": "发邮件告诉张三方案下周评审"
}
```

规则：

- `classification`: `none | explicit | uncertain`
- `intent_type`: `record | track | remind | todo | send | modify | delete | external_api`
- `confidence`: 0–1
- `routed_text`: 1–2 句待办标题
- 服务端只把 explicit 结果转成 todo；模型不能触发任何执行或外部动作。
- 系统音频来源即使返回 explicit 也会被降级为 uncertain。
- 低于 `uncertainThreshold` 的结果被丢弃。

参考 fixture：`Tests/SecretaryKitTests/Fixtures/fake-model.py`。

### 2.2 Fact 提取

请求：

```json
{
  "task": "extract_facts",
  "version": 1,
  "episode": {
    "id": "ep_...",
    "timestamp": "2026-11-06T03:15:00Z",
    "application": "Terminal",
    "window_title": "npm run build",
    "transcript": "",
    "ocr_text": "npm ERR! code ERESOLVE ...",
    "source": "screen"
  }
}
```

期望响应：

```json
{
  "facts": [
    {
      "kind": "error",
      "subject": "Terminal",
      "predicate": "错误模式",
      "object": "npm ERR! code ERESOLVE",
      "statement": "Terminal 出现 npm ERR! code ERESOLVE 依赖解析错误",
      "confidence": 0.91,
      "keywords": ["npm", "eresolve"]
    }
  ]
}
```

服务端会：

- 截断超长字段；
- 拒绝空 statement / 注入特征；
- 运行 `FactQualityGate` 决定 insert/reinforce/supersede/pending/reject；
- 强制 `sourceEpisodeIDs=[episode.id]`；
- 默认规则提取仍会补充模型漏掉的模式，并按 statement 去重。

### 2.3 巩固摘要模型

当前参考实现使用确定性投影生成日报，不调用生成模型。这是为了反幻觉优先。若要接入 3B/7B：

- 输入必须只包含数据库已有事件；
- 输出每条摘要必须携带 `memory_id`；
- 无 `memory_id` 的条目必须丢弃；
- 不得新增外部事实；
- 模型输出经过长度、注入、来源校验后才可进入日报；
- L3 fact 本身仍必须经过同一 `FactQualityGate`，不能仅凭摘要模型的断言写入。

## 3. CoreML 集成建议

### Qwen3-ASR 0.6B

实现 `TranscriptionProviding`：

1. 输入 16 kHz mono Float32（`AudioSegment` 已保证）；
2. 运行 CoreML encoder/decoder 或 MLX 音频前端；
3. 返回纯文本；
4. 模型加载失败要抛出 `ASRError`，让 daemon 记录一次并保持屏幕链路；
5. 在 daemon 中按需加载/释放，不把模型常驻进 MCP。

### RapidOCR / PaddleOCR

实现 `OCRProviding`：

1. `recognize(image:changedRegions:)`；
2. 只处理 Capture Daemon 传出的变化区域；
3. 返回归一化 top-left 坐标、confidence、text；
4. 必须支持 `changedRegions` 过滤，避免整屏 OCR；
5. 不保存图像。

### Qwen2.5-0.5B Intent Gate

实现 `IntentClassifying`：

- 规则命中时不需要调用模型；
- 只有规则返回 `none` 时才调用；
- 解析失败/超时回退 `none`；
- 输出必须经 `IntentDecision` 重新计算风险；
- ANE 权重、上下文长度和量化方式由部署脚本管理，不在本仓库分发。

## 4. 特征哈希 embedding 的定位

`HashingEmbedder` 是离线、确定性、无模型的 fallback：

- token + 字符 trigram 的带符号特征哈希；
- 384 维 L2 归一化；
- 适合测试和低资源环境；
- 不提供真正的跨词语义泛化。

替换为神经 embedding 时：

- 实现 `EmbeddingProviding` 并传给 `HybridRetriever`；
- 文档向量缓存 key 需要加入模型版本；
- 在数据库/配置中记录 embedding model 版本，避免换模型后旧向量混用；
- 当前实现没有持久化向量列，每次进程启动首次查询重新计算；10k 规模可接受。

## 5. 安全要求

1. 模型命令与模型文件必须来自用户可控路径。
2. 不要从 ASR/OCR/记忆内容动态拼接 shell 命令。
3. 模型输出始终是不可信数据；写入前必须经过质量门。
4. 不要把完整记忆内容发送到网络模型；本项目默认没有网络客户端。
5. 模型适配器崩溃不能拖垮 daemon：所有调用必须捕获错误并回退。
