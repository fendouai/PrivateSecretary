# 本地 LLM 接入

PrivateSecretary 的 LLM 处理是**可选、纯本地**的。当前接入：

```text
Ollama 0.40.15
Qwen2.5 1.5B Instruct Q4_K_M
  ↓ localhost:11434
scripts/llm-bridge.py
  ↓ stdin JSON / stdout JSON
ModelCommandClient (intentGate.model / factGate.model)
```

不调用云端 API，不发送音频/OCR 文本到外网。

## 1. 一键安装

```bash
PRIVATE_SECRETARY_HOME="$HOME/.private-secretary"   ./scripts/install-local-llm.sh
```

脚本会：

1. 安装 `com.privatesecretary.ollama` LaunchAgent，登录后自动启动；
2. 下载/检查 `qwen2.5:1.5b-instruct-q4_K_M`；
3. 写入 `intentGate.model` / `factGate.model` 配置；
4. 通过 localhost 验证模型。

手动检查：

```bash
/usr/bin/curl -s http://127.0.0.1:11434/api/tags
ollama list
make llm-test
```

如果只想使用已有的 Ollama 服务：

```bash
./scripts/install-local-llm.sh --no-service
```

## 2. 配置 PrivateSecretary

编辑 `~/.private-secretary/config.json`（测试环境为 `/tmp/ps-real-test/config.json`）：

```json
{
  "intentGate": {
    "model": {
      "enabled": true,
      "executable": "/usr/bin/python3",
      "arguments": ["/Users/you/GitHub/PrivateSecretary/scripts/llm-bridge.py"],
      "timeoutSeconds": 120,
      "maxOutputBytes": 2097152
    }
  },
  "factGate": {
    "model": {
      "enabled": true,
      "executable": "/usr/bin/python3",
      "arguments": ["/Users/you/GitHub/PrivateSecretary/scripts/llm-bridge.py"],
      "timeoutSeconds": 120,
      "maxOutputBytes": 2097152
    }
  }
}
```

重启 daemon 后，`secretary status` 应显示：

```text
Models: intent=/usr/bin/python3 extraction=/usr/bin/python3
```

模型失败时自动回退规则；不会阻塞基础 OCR/ASR。

## 3. 直接测试 bridge

```bash
printf '%s' '{"task":"classify_intent","version":1,"text":"帮我记一下明天下午三点和欧阳确认预算"}' \
  | ./scripts/llm-bridge.py

printf '%s' '{"task":"extract_facts","version":1,"episode":{"application":"Notes","window_title":"test","transcript":"决定：本周五前完成 OCR 与 ASR 联合验收","ocr_text":""}}' \
  | ./scripts/llm-bridge.py
```

`llm-bridge.py` 只监听本机 `127.0.0.1:11434`，通过 Ollama 的 `/api/chat` 调用模型。

## 4. 当前验证

```text
Models: intent=/usr/bin/python3 extraction=/usr/bin/python3
```

真实手动 ingest：

```text
帮我记一下明天下午三点和欧阳确认量子计算预算
  → intent explicit
  → todo 记一下明天下午三点和欧阳确认量子计算预算
  → LLM fact: 明天下午三点，我将与欧阳确认量子计算的预算。
```

## 5. 注意

- 1.5B 模型是轻量结构化模型，不应依赖它做复杂推理；
- 事实必须经过置信度/review 门；
- 模型不可用时规则引擎继续工作；
- Ollama 模型权重不在 Git 仓库中；
- 更换模型只需设置 `PRIVATE_SECRETARY_LLM_MODEL` 或修改 bridge 默认模型。
