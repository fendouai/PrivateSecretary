# 正式发布清单

本文档面向 PrivateSecretary 的**正式对外发布**，不是开发构建清单。

当前状态：`3.2.1`、ad-hoc 签名、Apple Silicon 单架构、直接安装包未生成、未 notarize、未建立更新通道。  
当前版本可以自用和开源分发源码，但**还不适合作为普通用户下载即用的正式二进制发布**。

---

## 0. 发布目标

建议第一条正式发布线：

- 产品名：PrivateSecretary
- Bundle ID：`com.privatesecretary.app`（不要再改）
- 分发方式：Developer ID 签名的 notarized DMG
- 最低系统：macOS 14（当前 Package 声明）
- 架构：Apple Silicon + Intel universal binary
- 许可：MIT（代码）+ 第三方 notices
- 更新：Sparkle 2 appcast（可选但从正式版开始建议有）
- 不上架 Mac App Store（第一版）

Mac App Store 是另一条路线，需要 App Sandbox、App Store 审核、后台登录项改造和本地 LLM 进程模型改造，不建议与第一版混做。

---

## 1. P0：签名、公证、Gatekeeper

### 1.1 Apple Developer Program

- [ ] 加入 Apple Developer Program（$99/年）
- [ ] 创建 Developer ID Application 证书
- [ ] 如需 pkg：创建 Developer ID Installer 证书
- [ ] 记录 Team ID
- [ ] 在构建机安装证书和中间证书
- [ ] 建立 `notarytool` keychain profile，不把密码写入仓库

### 1.2 替换 ad-hoc 签名

当前 `scripts/install.sh` 使用：

```bash
codesign --force --deep --sign - --timestamp=none "$APP"
```

正式构建必须改为：

```bash
IDENTITY="Developer ID Application: Your Name (TEAMID)"
codesign --force --options runtime --timestamp \
  --sign "$IDENTITY" "$APP/Contents/Helpers/secretaryd"
codesign --force --options runtime --timestamp \
  --sign "$IDENTITY" "$APP/Contents/Helpers/secretary-mcp"
codesign --force --options runtime --timestamp \
  --sign "$IDENTITY" "$APP/Contents/Helpers/secretary"
codesign --force --options runtime --timestamp \
  --sign "$IDENTITY" "$APP/Contents/MacOS/PrivateSecretary"
codesign --force --options runtime --timestamp \
  --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
```

要求：

- [ ] 每个 helper 单独签名，不能只 sign 外层 app
- [ ] 开启 hardened runtime
- [ ] 不加 `get-task-allow`
- [ ] entitlements 最小化
- [ ] 不使用 `--deep` 作为正式签名方式（`--deep` 只用于 verify）
- [ ] `codesign -dv` 显示 TeamIdentifier 和 Developer ID
- [ ] `spctl -a -vvv -t exec` 通过

### 1.3 Notarization

```bash
ditto -c -k --keepParent "$APP" PrivateSecretary.zip
xcrun notarytool submit PrivateSecretary.zip \
  --keychain-profile "ps-notary" --wait
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl -a -vvv -t exec "$APP"
```

要求：

- [ ] notarization 成功，不是 `Invalid`
- [ ] staple 成功
- [ ] 在**没有开发者证书的干净 Mac/VM**上双击可启动
- [ ] 离线启动通过
- [ ] Gatekeeper 不提示“无法验证开发者”
- [ ] DMG 本身也签名、notarize、staple
- [ ] 生成 SHA-256 checksum

---

## 2. P0：构建与版本

### 2.1 Universal binary

当前产物：

```text
Mach-O thin (arm64)
```

正式版：

```bash
swift build -c release --arch arm64 --arch x86_64
lipo -info .build/release/PrivateSecretary
```

- [ ] arm64 + x86_64
- [ ] 所有 helper 都是 universal
- [ ] 在 Intel Mac 或 Rosetta 环境验证
- [ ] `LSMinimumSystemVersion` 与 Package platforms 一致

### 2.2 版本与元数据

- [ ] `CFBundleShortVersionString` 升级，例如 `3.3.0` 或 `1.0.0`
- [ ] `CFBundleVersion` 单调递增
- [ ] `PrivateSecretaryVersion.current` 与 Info.plist 一致
- [ ] `CHANGELOG.md` 对应版本
- [ ] `NSHumanReadableCopyright`
- [ ] App icon `.icns`
- [ ] `CFBundleDisplayName`
- [ ] `LSApplicationCategoryType`
- [ ] 隐私用途描述完整：Screen Recording、Microphone
- [ ] 不再保留开发期 `codex` 调试配置或测试路径

### 2.3 构建可复现

- [ ] release 脚本不接受未签名产物
- [ ] 记录 Swift、macOS SDK、Xcode/CLT 版本
- [ ] 产出 checksum、SBOM/依赖清单
- [ ] 构建日志归档
- [ ] 源码 tag 与二进制 tag 对应

---

## 3. P0：安装包与分发

### 3.1 DMG

- [ ] 创建 DMG（app + Applications symlink + LICENSE + README）
- [ ] DMG 使用 Developer ID 签名
- [ ] DMG notarize + staple
- [ ] 首次打开为拖拽安装，不要求 sudo
- [ ] 卸载说明
- [ ] 不把用户数据写入 app bundle
- [ ] 用户数据固定 `~/.private-secretary`

### 3.2 分发渠道

至少选择：

- [ ] GitHub Releases
- [ ] 项目官网下载页
- [ ] Homebrew Cask（可选）
- [ ] SHA-256 与 release notes
- [ ] 旧版本归档与回滚说明

### 3.3 更新机制

正式版建议 Sparkle 2：

- [ ] 生成 EdDSA 密钥，私钥离线保存
- [ ] `SUFeedURL` + `SUPublicEDKey` 写入 Info.plist
- [ ] appcast.xml 使用 HTTPS
- [ ] 每个更新包签名
- [ ] 测试 beta → stable 升级
- [ ] 测试旧数据 schema 迁移
- [ ] 测试升级后 TCC 不被重置

如果第一版不做自动更新，必须：

- [ ] App 内检查新版本
- [ ] 下载页明确提示手动升级
- [ ] 升级前自动备份数据库

---

## 4. P0：TCC、升级与 24/7

这是本项目最容易被忽略、也最容易导致用户流失的部分。

- [ ] 正式签名后测试 Screen Recording 授权在升级后保持有效
- [ ] 从 ad-hoc 版升级到 Developer ID 版，接受一次重新授权
- [ ] 升级不改变 bundle ID、Team ID、安装路径
- [ ] 升级不改变 helper 的 TCC 责任进程结构
- [ ] 登录自启 LaunchAgent / SMAppService 在重启后工作
- [ ] 首次启动引导用户授权
- [ ] 拒绝授权时 App 不崩溃，仍可读已有数据
- [ ] 休眠/唤醒后 capture 恢复
- [ ] 显示器休眠/切换后恢复
- [ ] 多显示器、刘海屏、外接屏
- [ ] 安全输入（密码框）跳过 OCR
- [ ] 连续运行 24–72 小时 soak
- [ ] 升级、卸载、重装、保留数据

---

## 5. P1：首次启动与产品体验

- [ ] Welcome / 隐私说明 / 只读边界
- [ ] 选择数据目录（默认 `~/.private-secretary`）
- [ ] Screen Recording 授权引导
- [ ] Microphone 可选，不强制
- [ ] 本地 LLM 可选：检测 Ollama / 模型；不可用则规则 fallback
- [ ] 模型下载不由 App 静默执行
- [ ] 采集开关、暂停、退出
- [ ] 菜单栏图标在刘海屏可见或 fallback
- [ ] Dock / 窗口入口（当前菜单栏 App 容易找不到）
- [ ] 诊断页：capture 状态、last frame、DB 路径、日志导出
- [ ] 支持导出脱敏诊断包
- [ ] 崩溃/错误提示可理解
- [ ] 首次索引/历史数据为空时的 empty state
- [ ] 实时活动指标（已实现）文档化

---

## 6. P1：隐私、法律、第三方

- [ ] 隐私政策（收集什么、存储在哪、是否联网、删除方式）
- [ ] 服务条款 / EULA（如需要）
- [ ] 安全说明和漏洞披露流程（已有 SECURITY.md）
- [ ] MIT LICENSE（已有）
- [ ] 第三方 notices：
  - [ ] whisper.cpp
  - [ ] Ollama（如引导安装）
  - [ ] Qwen2.5 模型许可证
  - [ ] 其他 Swift/系统依赖
- [ ] 不把模型权重放进仓库或 App，除非确认许可
- [ ] 不上传默认 telemetry；如加入崩溃上报，必须 opt-in
- [ ] 本地 LLM 只访问 localhost
- [ ] 数据删除、purge、备份说明
- [ ] 商标/名称检索
- [ ] App Store 隐私标签（仅 MAS 需要）
- [ ] 出口合规/加密声明（如使用加密通信或备份）

---

## 7. P1：质量门禁

当前基线：

```text
200 Swift Testing
make verify
GitHub Actions macOS
```

正式发布前补充：

- [ ] 干净 macOS 14/15/26 测试
- [ ] Apple Silicon + Intel
- [ ] 真实 TCC 首次授权/拒绝/恢复
- [ ] 签名后的 app E2E（不只是 debug 构建）
- [ ] XCUITest 或等价 UI 自动化
- [ ] 安装/升级/回滚测试
- [ ] DB 损坏恢复测试
- [ ] 磁盘满测试
- [ ] 无网络测试
- [ ] Ollama 不存在/模型缺失/端口占用
- [ ] MCP 多 Agent 并发
- [ ] 10k/100k 记忆检索
- [ ] 24–72h soak、功耗、内存、CPU
- [ ] 模糊测试：导入 JSON/JSONL、OCR 文本、MCP 参数
- [ ] 安全审计：路径、SQL、prompt injection、TCC
- [ ] 依赖漏洞扫描
- [ ] 发布构建开启全部 warning 检查

---

## 8. P1：支持与运营

- [ ] 官网/下载页
- [ ] 快速开始 + FAQ
- [ ] 权限排障文档（已有 PERMISSIONS.md）
- [ ] 版本兼容矩阵
- [ ] Known Issues
- [ ] 支持邮箱/Issue 模板
- [ ] Release notes 模板
- [ ] Security advisory 流程
- [ ] 回滚/下架流程
- [ ] 发布节奏（建议每月/每两月）
- [ ] 用户反馈渠道
- [ ] 数据迁移公告

---

## 9. 发布前最终门禁

只有全部满足才打正式 tag：

- [ ] Developer ID 签名
- [ ] Hardened runtime
- [ ] Notarization + staple
- [ ] Gatekeeper 干净机通过
- [ ] Universal binary
- [ ] DMG 可安装/可卸载
- [ ] 升级保留数据和 TCC
- [ ] 登录自启/休眠唤醒稳定
- [ ] 200+ 测试和 soak 通过
- [ ] 隐私政策/第三方 notices
- [ ] 版本号、CHANGELOG、tag 对齐
- [ ] SHA-256、release notes、回滚包
- [ ] 官网/GitHub Release 同步

---

## 10. 建议排期

| 阶段 | 内容 | 估算 |
|---|---|---|
| 1 | Apple Developer + 证书 + 签名脚本 | 1–2 天 |
| 2 | universal build + notarize + DMG | 1–2 天 |
| 3 | 升级/TCC/登录/休眠 QA | 2–4 天 |
| 4 | 首次启动、诊断、隐私政策 | 2–3 天 |
| 5 | Sparkle 更新通道 | 1–2 天 |
| 6 | beta 测试与修复 | 1 周 |
| 7 | 正式发布 | 1 天 |

小团队第一版约 **2–3 周**；如果上 Mac App Store，另加 2–4 周甚至更久。

---

## 11. 当前最关键的 5 个阻塞项

1. **ad-hoc 签名**：`spctl` 当前 rejected，普通用户无法直接打开；
2. **未 notarize**：没有 Gatekeeper 信任链；
3. **单架构**：目前只有 arm64；
4. **无正式 DMG/更新通道**；
5. **无正式隐私政策/首次启动引导**。

先把这 5 项做完，再谈官网、Homebrew、App Store 和跨平台。
