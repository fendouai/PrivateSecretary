# 运维手册

## 1. 前置条件

- macOS 14+，Apple Silicon 推荐（M2/M3/M4，16 GB）。
- Swift 6.x 工具链。
- 可选：`whisper-cli` + whisper.cpp 模型（系统音频 ASR）。
- 可选：Codex CLI（MCP/Skill 注册）。

## 2. 构建与初始化

```bash
swift build -c release
.build/release/secretary init
```

默认目录：

```text
~/.private-secretary/
├── config.json
├── secretary.sqlite
├── cold/
├── logs/
├── exports/       # read-only HTML dashboards (0600 files)
├── run/secretaryd.sock
└── tmp/
```

可用 `--home` 或 `PRIVATE_SECRETARY_HOME` 切换。

## 3. 安装为 LaunchAgent

```bash
./scripts/install.sh
./scripts/install.sh --no-codex   # 不修改 Codex 配置
```

安装：

1. release 二进制；
2. `PrivateSecretary.app`（SwiftUI 菜单栏 App + TCC 身份 + 内嵌 daemon/MCP/CLI helper）；
3. `com.privatesecretary.daemon` 常驻；
4. `com.privatesecretary.consolidate` 每天 02:30；
5. `com.privatesecretary.menubar` 登录会话启动菜单栏 App；
6. Codex Skill + MCP server（除非 `--no-codex`）。

### 权限与数据来源

本产品不申请通讯录、日历、完全磁盘访问或辅助功能权限。唯一可能的 TCC 权限是：

- Screen Recording：实时屏幕帧 + 系统音频（ScreenCaptureKit）；
- Microphone：可选的麦克风输入。

只做文件/JSON/图片导入时不需要任何 TCC。ASR 和 Vision OCR 都在本机执行。

### Screen Recording 权限

```bash
./scripts/request-permissions.sh
```

或打开菜单栏 App → Overview → Permissions → Grant。也可以手动将以下 app 加入 Screen Recording：

```text
~/Library/Application Support/PrivateSecretary/PrivateSecretary.app
```

然后：

```bash
launchctl kickstart -k gui/$(id -u)/com.privatesecretary.daemon
secretary doctor
secretary status
```

`capture.state` 应为 `running`。拒绝授权时是 `capture_unavailable`，daemon 不崩溃、不重试；CLI/MCP 仍可读取历史数据。

### 菜单栏 App

```bash
open "$HOME/Library/Application Support/PrivateSecretary/PrivateSecretary.app"
```

- Overview：状态、计数、启动/重启/停止服务、权限、复制 Daily Brief；
- Timeline：按天浏览、复制单条记忆为 agent context；
- Todos：本地完成/重开/dismiss；
- Contacts / Messages：聚合、搜索、未读；
- Settings：路径、版本、模型、麦克风开关。

App 不执行 todo，不发送消息。

### 多 Agent

```bash
./scripts/install-agent.sh --host claude
./scripts/install-agent.sh --host cursor
./scripts/install-agent.sh --host generic --output mcp.json
```

同一个 `secretary-mcp` 可供多个 host 使用；详见 [Agent 接入](AGENT-INTEGRATION.md)。

### 麦克风（可选）

默认只采系统音频。可在菜单栏 App → Settings 打开，或编辑配置。启用：

```json
{"capture":{"microphoneEnabled":true}}
```

需要给同一个 app 授予 Microphone；未授权时自动退回系统音频。

## 4. 配置

`~/.private-secretary/config.json`，完整样例 [config.example.json](../config.example.json)。

修改后重启 daemon：

```bash
launchctl kickstart -k gui/$(id -u)/com.privatesecretary.daemon
```

关键项：

| 配置 | 说明 |
|---|---|
| `capture.whisperModel` | whisper.cpp 模型；空则 ASR 禁用 |
| `capture.microphoneEnabled` | 麦克风开关 |
| `capture.vadThreshold` | 能量 VAD 阈值 |
| `capture.frameDiffThreshold` | 屏幕变化阈值 |
| `privacy.excludedApplications` | OCR 前跳过的应用 |
| `intentGate.explicitThreshold` | todo 捕获阈值 |
| `factGate.minimumConfidence` | fact 质量门 |
| `salience.threshold` | 日报显著性阈值 |
| `salience.minimumRetentionDays` | 归档前保留天数 |
| `retrieval.defaultLimit` | recall 默认条数 |

没有执行相关阈值；v3.1 已经移除 `requires_confirmation`、`proceduralMinimum*` 等配置。

## 5. ASR

```bash
brew install whisper-cpp
mkdir -p ~/.private-secretary/models
curl -L -o ~/.private-secretary/models/ggml-base.bin \
  https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin
```

配置：

```json
{
  "capture": {
    "whisperBinary": "whisper-cli",
    "whisperModel": "~/.private-secretary/models/ggml-base.bin",
    "whisperLanguage": "zh"
  }
}
```

无 ASR 时屏幕 OCR 继续工作，音频段跳过。

## 6. 日常操作

### Brief / dashboard

```bash
secretary brief
secretary brief 2026-11-06 --json
secretary dashboard --open
secretary dashboard 2026-11-06 --output ~/Desktop/ps-brief.html
secretary context                 # 粘贴给 agent 的 Markdown 上下文
```

Dashboard 是 `~/.private-secretary/exports/` 下的自包含只读 HTML（0600）。

### Timeline

```bash
secretary timeline
secretary timeline 2026-11-06
secretary timeline 2026-11-06 --days 3 --no-facts
secretary timeline --limit 100 --json
```

### Todos

```bash
secretary todos
secretary todos --status all
secretary todo add "周五前提交 HNSW 参数对比" --detail "含 ef/M 取舍"
secretary todo update todo_... --status done
secretary todo delete todo_...
```

只读边界：todo 只被列出/标记，不被执行。

### 联系人

```bash
secretary contacts
secretary contacts --query 张
secretary contact add --name 张三 --org Acme \
  --channel email:zhangsan@example.com,lark:zhangsan_lark
```

### 消息

```bash
secretary messages
secretary messages --channel email --unread
secretary message add \
  --channel email --contact 张三 --handle zhangsan@example.com \
  --direction inbound --text "HNSW 参数对比请周五前发我" \
  --external-id mail-1

secretary message import --file messages.jsonl --channel email
secretary messages --search benchmark
secretary contact merge <source_id> --into <target_id>
```

`message add` / `message import` 是归档，不会发送。渠道适配器应通过 CLI、Unix socket 或 MCP `record_message` / `import_messages` 写入。

### 记忆

```bash
secretary recall "上周三决定的方案" --layer L3
secretary drill ep_...
secretary digest 2026-11-06
secretary consolidate --yesterday
secretary review list
secretary review correct fact_... --statement "..."
secretary forget ep_...
secretary purge --all --yes
```

## 7. 渠道适配器

推荐每个渠道一个只读同步器：

1. 从 Email/Lark/WeChat/Telegram 读取消息；
2. 只提取字段：channel、contact_name、handle、direction、text、timestamp、external_id、thread；
3. 写入本地：
   - CLI `secretary message add`；
   - Unix socket：

     ```json
     {"op":"message","channel":"lark","contact_name":"张三","handle":"zhangsan_lark","direction":"inbound","text":"..."}
     ```

   - MCP `record_message` / `import_messages`。
4. 不授予发送/回复权限。

JSONL 每条至少包含 `contact_name` 与 `text`；`channel` 可在每条或通过 `--channel` 提供。

重复消息由 `(channel, external_id/dedupe_key)` 唯一约束去重。联系人按 handle 优先合并。

## 8. 日志与状态

| 文件 | 内容 |
|---|---|
| `logs/secretaryd.out.log` | launchd stdout |
| `logs/secretaryd.err.log` | daemon 日志 |
| `logs/consolidate.*.log` | 夜间巩固 |
| `run/capture-status.json` | 采集健康 |
| `run/secretaryd.sock` | 本地 socket（0600） |

```bash
launchctl print gui/$(id -u)/com.privatesecretary.daemon
launchctl kickstart -k gui/$(id -u)/com.privatesecretary.daemon
tail -100 ~/.private-secretary/logs/secretaryd.err.log
```

`PRIVATE_SECRETARY_LOG_LEVEL=debug` 可提高日志级别。

## 9. 备份/恢复

```bash
./scripts/backup.sh
./scripts/backup.sh /Volumes/Backup/ps-2026-11-06
```

包含 `config.json`、checkpoint 后的 SQLite、`cold/`；不含二进制、日志、临时文件。

恢复时先停 daemon，再放回文件并重新启动。

## 10. 升级

```bash
git pull
swift build -c release
./scripts/install.sh
```

v3.1 迁移会把旧 `tasks` 转为 `todos`，删除 execution/procedural 表；升级前备份。

## 11. 卸载

```bash
./scripts/uninstall.sh
./scripts/uninstall.sh --purge
```

`--purge` 永久删除记忆目录，不进废纸篓。

## 12. 故障排查

### `capture_unavailable`

- Screen Recording 未授权或授权给错 app；
- app 路径/签名变化；
- 无显示器/无头会话；
- 查看 `secretaryd.err.log`。

### MCP 无响应

- 手动运行 `secretary-mcp --home ...`；
- 确保 stdout 只有 JSON-RPC；
- `codex mcp list`；
- 工具超时建议 30s。

### SQLite busy

- WAL + 4s busy timeout；
- 避免手工长事务；
- 备份前 checkpoint。

### Timeline 为空

- 指定日期没有 episode；
- 时间范围/时区；
- `secretary status` 查看计数。

### 联系人不合并

- 是否使用同一 handle；
- 同名不同 handle 默认按姓名兜底，可能误合并；
- 明确指定 `--channel`/`--handle`。

### 消息重复

- 是否有 `external_id`；
- 无 external id 时使用内容哈希，同一秒内容相同会去重。

### ASR 不工作

- `secretary doctor`；
- `whisper-cli -m MODEL -f sample.wav -l zh -nt -np`；
- `capture.vadThreshold` 调整。

### Codex 看不到 todo

- 调用 `list_todos`，不是旧 `get_pending_tasks`；
- 检查 Skill 是否安装；
- 旧 v3.0 执行工具已移除。

## 13. 资源

- daemon 常驻主要是 SCK + 60s 16k float ring；
- whisper 模型仅语音段调用；
- 无执行队列/L4 模型；
- 屏幕差分在 64×36 缩略图上完成，OCR 节流；
- ANE/CoreML 功耗需按目标模型实测。

## 12. 验证命令

```bash
make test
make smoke
make e2e
make app-test
make install-test
make agent-test
make verify
```
