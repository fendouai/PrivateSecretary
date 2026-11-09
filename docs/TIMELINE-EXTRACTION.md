# Timeline → Todo / Message 抽取

Timeline 是原始记忆层；Todos、Contacts、Messages 是从 Timeline 派生出来的结构化列表。

## 当前链路

```text
L2 Episode
  ├─ 原生笔记类 App / 手动输入 / 麦克风
  │    → 本地 LLM extract_todos → TodoItem
  ├─ Gmail inbox 可见行
  │    → 确定性 OCR 行解析 → Contact + ContactMessage
  └─ Mail / Slack / Lark / 微信等原生通信 App
       → 本地 LLM extract_messages → Contact + ContactMessage
```

## 做了什么

### Todo

- 只处理：Notes、TextEdit、Obsidian、Notion、Pages、Numbers、Word、Excel、手动输入、麦克风；
- 不处理：OpenCode/终端/浏览器文档/音乐播放器/登录窗口；
- 不再把界面文字、广告、他人泛泛建议当 todo；
- 标题接近已存在的 todo 时去重；
- 提取结果写入 `todos`，并保留来源 episode。

### Message / Contact

- Gmail 只处理**收件箱可见行**，使用确定性 OCR 行解析；
- 浏览器文档页面不再交给 LLM 生成假消息；
- 原生 Mail / Slack / Lark / 微信等才走 LLM 消息抽取；
- 统一 Contact，消息去重，并写入 `messages`；
- 不解析广告/公众号文章为私信。

## 命令

回填最近 7 天：

```bash
secretary organize --since 7d --limit 2000
```

预览：

```bash
secretary organize --since 7d --limit 2000 --dry-run
```

强制重跑：

```bash
secretary organize --since 7d --limit 2000 --force
```

JSON：

```bash
secretary organize --since 7d --json
```

## 自动运行

安装 `com.privatesecretary.organizer` LaunchAgent：

```text
每 5 分钟
  → secretary organize --since 2d --limit 300
```

处理过的 episode 记录在：

```text
~/.private-secretary/run/organizer-state.json
```

因此不会每 5 分钟重复调用模型。新 episode 才会进入抽取。

## 过滤原则

噪音源明确排除：

- Private Secretary 自己；
- loginwindow；
- QQ音乐；
- UserNotificationCenter；
- 浏览器文档/博客页面；
- OpenCode/终端屏幕文字；
- 广告、公众号文章、系统通知。

Todo 和 Message 宁少勿滥；宁可留空，也不把界面文字塞进列表。

## 当前验证

真实生产库回填结果：

```text
713 episodes scanned
7 episodes organized
Todos:     3 open（1 explicit + 2 从文本编辑抽取）
Messages:  10 real Gmail inbox rows
Contacts:  10
```

早期一次过宽抽取产生的 27 条假 todo 和 24 条假消息已清理。

## 说明

- 本地模型是 Qwen2.5 1.5B，适合结构化，不适合复杂判断；
- 对低质量候选，Source 过滤和去重比模型更重要；
- 原生通信 App 尚未逐一适配，当前真实消息主要来自 Gmail OCR；
- 后续可以把 organizer 合入 daemon 或在 App 里增加“Extract now”。
