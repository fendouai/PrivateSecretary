# ADR 0006：用 app bundle 承载捕获 daemon 的 TCC 身份

- 状态：Accepted
- 日期：2026-11-06

## 背景

ScreenCaptureKit 需要 Screen Recording TCC。裸可执行文件从 LaunchAgent 启动时，没有稳定的 bundle 身份，系统更新、重编译或路径变化后授权容易失效。

## 决策

- `install.sh` 创建 `PrivateSecretaryCapture.app`；
- Info.plist 使用 `com.privatesecretary.capture`；
- LaunchAgent 指向 `.app/Contents/MacOS/secretaryd`；
- 对 app 做 ad-hoc codesign；
- `--request-permissions` 入口可让用户从 app 身份触发请求；
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

正式分发使用 Developer ID 签名 + notarization，或迁移为 SwiftUI menu bar app。
