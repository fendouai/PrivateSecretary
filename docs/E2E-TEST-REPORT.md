# 本地 E2E 测试报告

**日期**：2026-11-07  
**版本**：PrivateSecretary 3.1.0  
**结论**：**本地软件栈 E2E 已全部通过**。硬件采集（TCC ScreenCaptureKit）和真实 Codex 模型闭环未在本机完成，原因见第 5 节。

## 1. 执行命令

```bash
./scripts/e2e-test.sh
```

结果：

```text
== build ==
== fresh home + daemon (capture off) ==
== socket ingest + messages ==
== MCP full organizer journey ==
== CLI views, dashboard and final state ==
E2E TEST PASSED (software stack; capture was intentionally off)
```

该脚本也包含在：

```bash
make verify
```

## 2. 覆盖范围

### 2.1 全新环境 + daemon

- 新建临时 home；
- `secretary init` 初始化 SQLite schema v3；
- 启动 `secretaryd --capture off`；
- 等待 Unix socket 出现；
- 通过 socket 查询 `status`，确认 `capture.state=disabled`；
- 通过 socket 摄入一条手动候选，生成 episode + todo；
- 通过 socket 写入 email / Lark 两条消息；
- SIGTERM 停止 daemon，确认退出码 0 和 `capture-status.json`。

### 2.2 MCP 全流程

真实启动 `secretary-mcp` 子进程，通过 stdio JSON-RPC：

- initialize：server name = `private-secretary`；
- tools/list：**19 个工具**；
- `get_status`：episodes=1、contacts=2；
- `list_todos`：1 个 open todo；
- `get_brief`：timeline、1 open todo、2 unread messages、2 contacts；
- `import_messages`：1 条新消息 + 1 条重复（imported=1, duplicates=1）；
- `list_messages(query:"benchmark")`：message_fts 命中 1 条；
- `list_contacts`：取得 source/target；
- `merge_contacts`：频道与消息重挂到 target，source 消失；
- `update_todo`：open → done；
- `generate_daily_digest`：日报 stats.todoCount=1；
- `get_digest`：found=true，Markdown 含“待办”；
- `list_todos(open)`：0 条；
- 关闭 stdin，进程退出码 0，stderr 无协议污染。

### 2.3 CLI + dashboard

- `timeline`、`brief`、`todos --status all`、`contacts`、`messages --search benchmark`；
- `consolidate`、`digest`；
- `dashboard --output` 生成 HTML，含 Timeline / Open todos；
- 最终 `status --json`：
  - episodes=1；
  - openTodos=0；
  - contacts=2；
  - messages>=3；
  - capture.state=stopped。

## 3. 关联的自动化测试

除 E2E 脚本外：

```bash
make test
```

- **188 个 Swift Testing 测试**通过；
- 真实 Vision OCR；
- 真实 whisper.cpp `ggml-base.bin` 转写；
- MCP 进程测试；
- CLI 进程测试；
- 安装/卸载/清除；
- 2k / 10k soak。

详细见 [测试报告](TEST-REPORT.md)。

## 4. 当前硬件状态

`secretary doctor` 在本机输出：

```text
screen_recording_tcc: Not granted
asr: whisperModel is empty (default home)
capture_daemon: not running (outside E2E)
```

因此：

- **没有**进行真实屏幕变化帧 + 系统音频的 live capture E2E；
- **没有**验证 TCC 授权后 ANE/GPU 的长期功耗；
- **没有**验证真实 LaunchAgent 登录会话（安装脚本在隔离 HOME 中做了打包/加载前置验证，但未对真实用户 GUI 会话 bootstrap）。

TCC 是操作系统人工授权，自动化测试不能代替用户点击授权；授权后可按 [运维手册](OPERATIONS.md) 运行 `secretaryd --capture system` 验证。

## 5. Codex 模型闭环

尝试用真实 Codex CLI + MCP server 做模型驱动 E2E，但被本机 Codex 账户状态阻塞：

1. 默认配置的 `gpt-6.1-sol` 不被当前 ChatGPT 账户支持；
2. 切换到本机 models cache 中的 `gpt-5.6-sol` 后，账户返回 usage limit（2026-11-12 恢复）。

因此：

- **MCP 协议/进程/工具 E2E 已通过**；
- **真实 Codex 模型调用 + 工具选择**未在本机完成；这是账户/usage 限制，不是 MCP 失败；
- Codex 账户恢复额度或使用可用 API key 后，可直接按 MCP-API 文档重跑。

## 6. 未覆盖清单

| 项目 | 状态 | 原因 |
|---|---|---|
| 真实 ScreenCaptureKit 帧/系统音频 | 未完成 | Screen Recording TCC 未授权 |
| 麦克风采集 | 未完成 | 默认关闭、未授权 |
| 真实 LaunchAgent 登录启动 | 未完成 | 不修改真实用户会话 |
| 第三方渠道 API（Email/Lark/WeChat） | 未完成 | 无账号/不引入外部写权限；通过 CLI/socket/MCP 模拟 |
| Codex 模型驱动 MCP 工具 | 阻塞 | 账户模型不支持 + usage limit |
| 多显示器 | 未实现 | 只采集主显示器 |
| 24h 稳定性 | 未完成 | 需要授权后长跑 |

## 7. 复现

```bash
./scripts/e2e-test.sh
make test
make smoke
make install-test
EVENTS=10000 QUERIES=100 DAYS=7 ./scripts/soak-test.sh
make verify
```
