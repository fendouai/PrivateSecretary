# macOS 授权指引

PrivateSecretary 只可能请求 **两项** macOS TCC 权限：

1. **Screen Recording / 屏幕与系统音频录制**：实时屏幕帧 + 系统音频（ScreenCaptureKit）。
2. **Microphone**：可选的麦克风输入。

不申请通讯录、日历、提醒事项、完全磁盘访问、辅助功能、定位、相机等权限。

## 0. 先安装 App

在仓库目录执行：

```bash
./scripts/install.sh
open "$HOME/Library/Application Support/PrivateSecretary/PrivateSecretary.app"
```

安装后的 App 路径：

```text
~/Library/Application Support/PrivateSecretary/PrivateSecretary.app
```

TCC 身份：

```text
com.privatesecretary.app
```

> 只用 CLI/MCP 导入文本、JSON、图片/音频文件时，**不需要任何 TCC 权限**。  
> 只有“自动看屏幕/听系统声音”才需要 Screen Recording。

## 1. 授予 Screen Recording

### 方式 A：从 App 触发（推荐）

1. 点击菜单栏的 Private Secretary 图标；
2. 打开 **Overview → Permissions**；
3. 点击 **Screen Recording → Grant**；
4. macOS 弹出提示后，打开 **System Settings**；
5. 打开 **Private Secretary** 的开关。

macOS 14 路径：

```text
System Settings → Privacy & Security → Screen Recording
```

macOS 15 及以后：

```text
System Settings → Privacy & Security → Screen & System Audio Recording
```

### 方式 B：手动添加

1. 先启动一次 App，让系统登记它；
2. 打开上述系统设置；
3. 点击 `+`；
4. 按 `Cmd+Shift+G`，粘贴：

```text
~/Library/Application Support/PrivateSecretary/
```

5. 选择 `PrivateSecretary.app`；
6. 打开开关。

### 授权后必须重启采集服务

macOS 通常要求重新启动使用屏幕权限的进程：

- App 内点击 **Restart Service**；或

```bash
launchctl kickstart -k gui/$(id -u)/com.privatesecretary.daemon
```

如果系统提示 “Quit & Reopen”，先退出 App，再重新打开。

## 2. 授予 Microphone（可选）

只有在需要麦克风输入时才授权。系统音频由 Screen Recording 覆盖，不需要 Microphone。

1. App → **Settings** → 打开 **Microphone capture**；
2. App → **Overview → Permissions → Microphone → Grant**；
3. 或打开：

```text
System Settings → Privacy & Security → Microphone
```

4. 打开 **Private Secretary**；
5. 重启采集服务。

> macOS 15 才支持 ScreenCaptureKit 的 microphone stream；macOS 14 会继续使用系统音频。

## 3. 验证

```bash
BIN="$HOME/Library/Application Support/PrivateSecretary/bin/secretary"
"$BIN" --home "$HOME/.private-secretary" doctor
"$BIN" --home "$HOME/.private-secretary" status
```

期望：

```text
screen_recording_tcc: granted
capture.state: running
```

App 的 Overview 应显示：

```text
Capture service: Running
```

如果显示 `capture_unavailable`：

1. 确认系统设置中的开关已打开；
2. 完全退出并重新打开 App；
3. 重启 daemon：

```bash
launchctl kickstart -k gui/$(id -u)/com.privatesecretary.daemon
```

## 4. App 不在系统设置列表中

1. 先通过 `open "$HOME/Library/Application Support/PrivateSecretary/PrivateSecretary.app"` 启动一次；
2. 再打开系统设置；
3. 使用 `+` 手动添加 `PrivateSecretary.app`；
4. 如果仍然异常，可重置该项 TCC 后重试：

```bash
tccutil reset ScreenCapture com.privatesecretary.app
tccutil reset Microphone com.privatesecretary.app
```

> 重置会清除已有授权，只建议在排障时使用。

## 5. 关于重新安装与签名

当前安装包是 **ad-hoc 签名**。重新编译/重新安装后，macOS 可能把它当成新的 app，需要重新授权。

正式分发建议使用 Developer ID 签名 + notarization，并保持 bundle id 与路径稳定，以减少重复授权。

## 6. 权限与数据流

| 数据 | 来源 | 权限 |
|---|---|---|
| 语音文本 | 本地 whisper.cpp | 系统音频：Screen Recording；麦克风：Microphone |
| OCR 文本 | 本地 Apple Vision | 实时屏幕：Screen Recording |
| 导入文本/JSON | 用户主动导入 | 无 |
| 联系人/消息 | 本地归档和导入 | 无平台 API、无通讯录权限 |

所有 ASR/OCR 处理都在本机完成；不上传音频、图片或文本。
