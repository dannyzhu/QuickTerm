# QuickTerm 控制面（CLI + AI agent）实现计划 Phase 1–5

> 用户已确认三项决策：① **默认开启**，模式 `ask`（读免确认；改静默但可见、可撤销；破坏性与敏感操作按调用方确认一次）；
> ② 主命令名 `quickterm`，另给可选短别名 `qt`，装到 `/usr/local/bin`（不可写则 `~/.local/bin` 并提示 PATH），**永不弹管理员密码**；
> ③ **`send-text` 要做**（Phase 4，默认关配置项打开后可用；注入 `@self` 免确认，注入其它 pane 一律确认）。
>
> 完整设计与调研原文（含 tmux/kitty/wezterm/zellij/hyprctl/iTerm2 逐条对照、JSON 样例、风险清单）见
> `/private/tmp/claude-501/-Users-Danny-Documents-workspace-quickterm/e6fdbbbb-fb93-44bb-86da-29bcc5a0b0b0/scratchpad/control-design-full.md`
> —— **实现前必须完整读一遍那份文件**，本文件只写决策与骨架。

## 0. 不变量（每个阶段都要守住）

- 现有全部测试保持通过；第一个窗口标题仍为 `QuickTerm`；焦点真相仍是窗口 first responder。
- **一切从一张命令表生成**：`Sources/Control/CommandTable.swift` 同时产出 CLI 解析、`--help`、`describe --json`、
  安全分级、Phase 5 的 MCP 工具表。命令表之外不得手写第二份命令描述。
- **只给绝对设值，不给 toggle**（`--zoom on|off`、`set-layout dwindle`、`--width 0.33`）。agent 看不到状态，
  重试一次 toggle 会把自己撤销。`action <wm-action>` 是唯一的例外（它就是快捷键语义的直通车）。
- 目标匹配到多个 → **报错并列出候选**，绝不"取第一个"。
- 所有 JSON 走 `JSONEncoder`，禁止手拼（yabai 曾因手拼出的尾逗号打断所有下游管道）。
- 控制命令一律回到主线程执行；socket 回调线程不得直接碰 `@Published`。`perform()` 是可重入的
  （引擎回调也会调它），串行化要用标志位而不是队列锁。
- 破坏性命令前先 `flushPendingCloses()`；关闭是 0.28s 两段动画，焦点重试最长 0.75s。

## 1. 寻址

`screen:workspace.pane`，每段可省，向右默认取上下文。

- **screen**：1 起序号（与窗口标题一致）、`#uuid`（`MainWindowController.windowID`）、`@current`/`@primary`。
- **workspace**：1 起序号（与 ⌘1..0 一致，内部 0 起绝不外泄）、`@active`/`@next`/`@prev`。
- **pane**：短句柄 `t7`/`b3`（进程内稳定，类型前缀）、`#uuid` 或 ≥4 位前缀、关系式
  `@focused`（默认）/`@left @right @up @down`/`@next @prev`/`@self`（读 `QUICKTERM_PANE`）、
  谓词 `title:~<regex>`/`cwd:<prefix>`/`kind:terminal|browser`/`role:file-manager`。
- 正在淡出（`model.closingPanes`）的 pane 不可寻址。

## 2. 传输

`~/Library/Application Support/QuickTerm/control.sock`，`AF_UNIX`/`SOCK_STREAM`，目录 `0700`、socket `0600`，
绑定前检查符号链接与父目录权限，启动时探测后清理陈旧 socket。**注意 `sun_path` 只有 104 字节**：路径过长时
回退到 `$TMPDIR/quickterm.sock` 并记日志。用 BSD socket + `DispatchSource`（不用 `NWListener`，因为需要
`getsockopt(LOCAL_PEERCRED/LOCAL_PEERPID)`）。**绝不做转义序列通道**，绝不监听 TCP。

协议：NDJSON，一行一个 JSON 对象，`id` 关联请求与响应，连接可复用（事件流就是保持打开的同一条连接）。
`v` 不匹配 → 退出码 8 并同时报出两边版本。

CLI 目标：新目录 `CLI/`（因为 app target 的 `sources:` 是整个 `Sources`，再放一个 `main.swift` 会被编进 app）；
线材类型放 `Sources/Control/Wire/`，两个 target 都列入。构建后拷进 `QuickTerm.app/Contents/MacOS/`。

## 3. 安全（默认开 + ask）

- socket 权限 + `LOCAL_PEERCRED` 同 uid 校验（硬拒）。
- `QUICKTERM_TOKEN`（每次启动重新生成）注入每个新建 pane 的环境：**这是来源证明，不是权限边界**，
  代码注释必须写明，任何"有 token 就跳过确认"的写法都是错的。
- 四级：`read` 静默（**无 token 的调用方读不到浏览器 URL/标题，一律 redacted**）·
  `mutate` 静默但**状态栏闪一下**注明命令与来源 pane，并登记 `AppDelegate.undoManager`（⌘Z 可撤销）·
  `destructive`（`pane close`/`screen close`/`workspace clear`/`spec apply --replace`）与
  `sensitive`（`send-text`、读浏览器 URL）**按 (peer pid, 命令类) 确认一次**，对话框显示真实进程名与来源 pane。
- 确认对话框不能用会卡死主线程的嵌套 runloop 方案（应用里已有多处 `runModal`）；主线程被卡住时
  连确认框都弹不出来，因此要有限流与"忙时拒绝"。

## 4. 分阶段

### Phase 1 — socket + 查询 + 全动作直通 + describe
socket 与线材、`quickterm`/`qt` 二进制与安装、`state`/`list`/`get`（扁平 pane 数组 + 引用句柄的工作区骨架）、
`action <wm-action>`（全部 67 个；5 个模态面板类归 `interactive` 拒绝执行；破坏性的走确认）、`describe --json`、
`--help`（每条子命令以示例结尾、查询类内嵌 JSON 样例）、环境变量注入、`[control]` 配置段、短句柄注册表。

### Phase 2 — 名词-动词层 + 确认 UI + 撤销
`pane new/close/focus/move/swap/set/resize`、`workspace goto/set-layout/equalize/clear/count`、
`screen new/close/move/focus/set`、`app get/set`；每个 toggle 都补绝对设值；`--dry-run`、`--fail-if-noop`、
状态栏可见性、控制日志、撤销登记、限流、模态忙时保护。
需要把 `insertNewPane`/`removeFromAnyWorkspace`/`removeFromActiveLayout`/`clearZoom` 从 private 放宽到 internal
（重新实现它们的不变量必然出 bug）。

### Phase 3 — spec dump/apply（一次性组合）
公开 schema `quickterm.workspace/1`（+ `quickterm.screen/1`、`quickterm.session/1`），与 v5 存档之间做投影对，
**各自独立演进**；`spec dump/apply/validate`，`--into-empty`/`--replace`/`--reuse`/`--dry-run`（带可读 diff）。
落地时一次性构造 `ScrollingStrip`/`SplitTree` 值再赋给 `model.layouts[i]`：一次重排、一次动画、一次存档。
**不要走 `applyArchive`/`restore(from:)`**——那是整窗口、为新建窗口写的，会跳过 `BrowserPaneView.paneWillClose`。

### Phase 4 — 事件流 + send-text
每次状态变更递增 `seq`（`state` 里返回，便于 agent 判断快照是否过期）；`events poll --since --timeout`（主形式）
与 `events follow`（NDJSON 流）；类型化事件（pane.opened/closed、focus.changed、workspace.changed、layout.changed、
screen.opened/closed、pane.title/cwd.changed）——**任何事件都不得携带 pane 的输出内容**。
`send-text`：配置 `[control] send-text = true` 才可用，`sensitive` 级；注入 `@self` 免确认，其它 pane 每次确认；
拒绝控制字符；换行只能通过显式 `--enter`。

### Phase 5 — MCP server + 文档
`quickterm mcp`（stdio），9 个粗粒度工具，带 `readOnlyHint`/`destructiveHint`/`idempotentHint` 与 `outputSchema`，
全部由同一张命令表生成（手写必然漂移，用例要钉死这一点）。补 67 个动作的 `helpEN`、
`docs/agents/quickterm-cli.md`、README（英/中）小节。

## 5. 交付

每个 Phase：分支 → 实现 → 定向测试 → 全套 → 对抗评审 → 修正 → 全套 → 提交 → 合入 main。
五个阶段全部完成后重新 Debug 构建并重启应用，README 与 porting-notes 补齐，再考虑发版。
