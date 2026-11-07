# ADR 0006：用 app bundle 承载捕获 daemon 的 TCC 身份

- 状态：Accepted
- 日期：2026-11-06

## 背景

ScreenCaptureKit 需要 Screen Recording TCC。裸可执行文件从 LaunchAgent 启动时，没有稳定的 bundle 身份，系统更新、重编译或路径变化后授权容易失效。

## 决策

- `install.sh` 创建单个 `PrivateSecretary.app`：菜单栏 UI + `Contents/Helpers/secretaryd`/`secretary-mcp`/`secretary`；
- Info.plist 使用 `com.privatesecretary.app`，`LSUIElement=true`；
- daemon LaunchAgent 指向 `.app/Contents/Helpers/secretaryd`；
- 菜单栏 App 的 Overview → Permissions 触发 Screen Recording/Microphone 请求；
- 对 app 做 ad-hoc codesign；
- 文档明确重编译/重签后可能需要重新授权。

## 后果

正面：

- TCC 身份更稳定、可识别；
- 用户能在系统设置中看到明确 app；
- 可以把麦克风 usage description 放进 Info.plist。

负面：

- 重编译后 ad-hoc cdhash 变化，可能需要重新授权；
- 没有 Developer ID/公证，不适合公开分发；
- LaunchAgent 仍以当前用户运行，不是沙箱 app。

## 后续

正式分发使用 Developer ID 签名 + notarization；菜单栏 App 已落地，后续只需稳定签名与登录项分发。
