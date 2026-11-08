# 登录自启与 24/7 采集

PrivateSecretary 的 24/7 运行由四个 LaunchAgent 组成。所有 plist 位于：

```text
~/Library/LaunchAgents/
```

| Label | 作用 | 启动方式 |
|---|---|---|
| `com.privatesecretary.daemon` | 屏幕/系统音频采集 + SQLite 写入 | `RunAtLoad` + `KeepAlive` |
| `com.privatesecretary.menubar` | 菜单栏 App / 人的入口 | `RunAtLoad`，崩溃重启 |
| `com.privatesecretary.consolidate` | 每日巩固/摘要 | 每天 02:30 |
| `com.privatesecretary.ollama` | 本地 LLM 服务 | `RunAtLoad` + `KeepAlive` |

采集 daemon 使用 App bundle 内的 helper：

```text
PrivateSecretary.app/Contents/Helpers/secretaryd
```

这样 TCC 身份归一到 `PrivateSecretary.app`，Screen Recording 授权不会因为外部 `bin/secretaryd` 而失效。

## 安装

正常安装：

```bash
./scripts/install.sh
```

本地 LLM：

```bash
./scripts/install-local-llm.sh
```

安装完成后：

```bash
launchctl list | grep private
```

应看到：

```text
com.privatesecretary.daemon
com.privatesecretary.menubar
com.privatesecretary.consolidate
com.privatesecretary.ollama
```

## 验证采集 daemon

不需要先打开 App：

```bash
launchctl print gui/$(id -u)/com.privatesecretary.daemon
pgrep -fl 'PrivateSecretary.app/Contents/Helpers/secretaryd'
secretary status
```

期望：

```text
Capture: running — system audio + screen deltas
```

TCC 已授权时，daemon 单独启动也能拿到 Screen Recording；App 不需要保持前台。

## 验证 App

```bash
launchctl print gui/$(id -u)/com.privatesecretary.menubar
pgrep -fl 'PrivateSecretary.app/Contents/MacOS/PrivateSecretary'
```

App 崩溃后 LaunchAgent 会自动重启；用户主动 Quit 不会强制拉起。

## 崩溃恢复

daemon 的 `KeepAlive` 为 `true`，测试方式：

```bash
pkill -f 'PrivateSecretary.app/Contents/Helpers/secretaryd'
sleep 3
pgrep -fl 'PrivateSecretary.app/Contents/Helpers/secretaryd'
```

会出现新的 PID，`secretary status` 仍是 `running`。

## 数据目录

生产默认：

```text
~/.private-secretary
```

不要把 24/7 数据放在 `/tmp`，系统重启会清理。测试环境与生产环境应使用不同 home。

## 停止 / 临时维护

```bash
launchctl bootout gui/$(id -u)/com.privatesecretary.daemon
launchctl bootout gui/$(id -u)/com.privatesecretary.ollama
```

恢复：

```bash
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.privatesecretary.daemon.plist
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.privatesecretary.ollama.plist
```

## 故障排查

- `Capture: capture_unavailable`：先检查系统设置中的 Screen Recording；
- `Models: intent=rules`：Ollama 未运行或 config 未启用；
- `lastFrameAt` 长时间不更新：检查显示器是否休眠，或 `launchctl print` 是否在重启循环；
- ad-hoc 签名重建后 TCC 失效：重新授权一次 Screen Recording；
- 本机 Homebrew `brew services` 不可用不影响 Ollama；项目使用自己的 LaunchAgent。

## 当前验证记录

- daemon 在 App 不运行时独立启动并采集通过；
- daemon 被杀后由 launchd 自动拉起，`Capture: running`；
- menubar App 被杀后自动重启；
- 数据已迁移到持久目录 `~/.private-secretary`；
- 本地 LLM 与采集 daemon 同时运行，`Models: intent=/usr/bin/python3 extraction=/usr/bin/python3`。
