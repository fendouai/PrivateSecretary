# 登录自启与 24/7 采集

PrivateSecretary 使用“App 常驻 + App 内嵌 helper”的方式运行采集，而不是单独用 LaunchAgent 启动 daemon。

原因：Screen Recording 的 TCC 责任进程是 `PrivateSecretary.app`。只有把 helper 作为 App 的子进程启动，才能稳定继承 App 的授权；直接由 launchd 启动的独立 daemon 是另一个 TCC 身份，容易被拒绝。

## 运行时组成

| 组件 | 作用 | 启动方式 |
|---|---|---|
| `com.privatesecretary.menubar` | 菜单栏 App，TCC 责任进程 | `RunAtLoad`，崩溃重启 |
| App 内嵌 `secretaryd` | 屏幕/系统音频采集，App 子进程 | App 启动后自动拉起 |
| `com.privatesecretary.consolidate` | 每日巩固/摘要 | 每天 02:30 |
| `com.privatesecretary.ollama` | 本地 LLM 服务 | `RunAtLoad` + `KeepAlive` |

plist：

```text
~/Library/LaunchAgents/com.privatesecretary.menubar.plist
~/Library/LaunchAgents/com.privatesecretary.consolidate.plist
~/Library/LaunchAgents/com.privatesecretary.ollama.plist
```

采集 daemon 的进程形态：

```text
PrivateSecretary.app/Contents/Helpers/secretaryd --home ~/.private-secretary --capture system
```

它是 App 的子进程，不是独立 LaunchAgent。

## 登录时发生什么

1. launchd 启动 `com.privatesecretary.menubar`；
2. App 读取 `PRIVATE_SECRETARY_AUTOSTART=1`；
3. App 检查 capture socket；
4. 未运行时，启动内嵌 helper；
5. helper 继承 App 的 Screen Recording TCC 授权；
6. `capture-status.json` 变为 `running`。

## 安装

```bash
./scripts/install.sh
```

安装脚本只安装 menubar / consolidate 两个 LaunchAgent，**故意不安装独立 daemon LaunchAgent**。

本地 LLM：

```bash
./scripts/install-local-llm.sh
```

## 验证

```bash
launchctl print gui/$(id -u)/com.privatesecretary.menubar
pgrep -fl 'PrivateSecretary.app/Contents/Helpers/secretaryd'
secretary status
```

期望：

```text
Capture: running — system audio + screen deltas
Models: intent=/usr/bin/python3 extraction=/usr/bin/python3
```

## 崩溃恢复

- App 崩溃：menubar LaunchAgent 的 `KeepAlive.Crashed` 会重新启动 App；
- App 正常 Quit：不会强制拉起；
- helper 由 App 管理；App 重启后会重新拉起；
- 每日巩固由 launchd 独立调度。

## 屏幕权限

更新 App 后可能重新出现 Screen Recording 授权：

```text
System Settings → Privacy & Security → Screen Recording
→ 添加/勾选 PrivateSecretary.app
```

授权后重启 App（或从菜单选择 Restart Capture Service）。

## 数据目录

生产：

```text
~/.private-secretary
```

不要使用 `/tmp` 作为 24/7 数据目录。

## 故障排查

- `Capture: capture_unavailable`：Screen Recording 未授权，或更新后 TCC 失效；
- `Models: intent=rules`：Ollama 未运行或 config 未启用；
- helper 不存在：重新运行 `scripts/install.sh`；
- 独立 daemon LaunchAgent 被误装：删除 `com.privatesecretary.daemon.plist`，它会导致 TCC 身份不一致。

## 当前验证记录

- App 子进程 helper 采集通过；
- App 被杀后 LaunchAgent 自动重启；
- 数据在持久目录 `~/.private-secretary`；
- 本地 LLM 与采集同时运行；
- 更新 App 后 Screen Recording 需要重新授权一次。
