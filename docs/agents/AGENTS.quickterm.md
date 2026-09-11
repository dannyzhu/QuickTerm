# QuickTerm 控制面（给 AI agent 的说明）

> 把本文件复制到你项目根目录的 `AGENTS.md`（或追加进去），或者放到 `~/.codex/AGENTS.md` 让它对所有项目生效。
> 适用于 Codex CLI、Claude Code，以及任何能执行 shell 的 agent。

你正运行在 **QuickTerm** 里 —— 一个 macOS 平铺终端。你可以用 `quickterm` 命令**操作你周围的界面**：
屏幕（窗口）、工作区、pane（终端 / 浏览器 / 文件管理器）。

## 先做这一件事

```bash
quickterm describe --json
```

一次拿到全部：命令、参数类型与可选值、安全分级、退出码、事件类型、工作区规格 schema、以及 67 个快捷键动作。
**读这一份就够了，不要反复翻 `--help`。** 命令不存在（`command not found`）说明这台机器没装 QuickTerm 命令行，
或者用户没把它装到 PATH —— 那就别用本文件的任何内容。

## 你是谁、你在哪

每个 pane 的环境里都有这些（不用问用户）：

| 变量 | 含义 |
|---|---|
| `QUICKTERM_PANE` | 本 pane 的 UUID —— `-t @self` 就靠它 |
| `QUICKTERM_SOCKET` | 控制 socket 路径 |
| `QUICKTERM_SCREEN` / `QUICKTERM_WORKSPACE` | 创建时的屏幕 / 工作区序号（**提示值**，pane 被移走后不更新） |

想知道"现在什么样"，永远用 `quickterm state --json`，别依赖后两个变量。

## 寻址

`screen:workspace.pane`，每段可省。常用写法：

- `t7` / `b3` —— **短句柄**（`t`=终端，`b`=浏览器），`state` 里每个 pane 都有，人和你都该用这个
- `@self` —— 你自己所在的 pane；`@focused` —— 当前焦点 pane
- `@left @right @up @down` / `@next @prev` —— 相对位置
- `1:3` —— 1 号屏幕的 3 号工作区；`#<uuid 前缀>` —— 跨重启稳定的 id
- 谓词：`cwd:~/proj`、`title:~regex`、`kind:terminal`

**匹配到多个会报错并列出候选**，不会替你猜。

## 常用命令

```bash
quickterm state --json                  # 全部：屏幕 / 工作区 / pane / 每个 pane 的尺寸
quickterm list panes                    # 人看的表格
quickterm get -t t7                     # 单个 pane 的细节

quickterm pane new --cwd "$PWD" --cmd "npm run dev" --at @self --where right
quickterm pane new --kind browser --url http://localhost:3000 --at @self --where down
quickterm pane focus -t t7
quickterm pane set -t t7 --zoom on      # 绝对设值：on/off，不是切换
quickterm pane resize -t t7 --ratio 0.6 # 也可 --points +120 / --dir right
quickterm pane move -t t7 --to 1:3
quickterm workspace set-layout dwindle -t 1:3
quickterm workspace goto 2
```

浏览器 pane 里的**标签**（`-t` 指 pane，`--tab` 指标签）：

```bash
quickterm browser open   -t b3 --url http://localhost:3000   # 新开一个标签
quickterm browser goto   -t b3 --url http://localhost:5173   # 当前标签换网址（绝对设值）
quickterm browser goto   -t b3 --tab 2 --url https://example.com
quickterm browser reload -t b3 --hard                        # 绕过缓存
quickterm browser close  -t b3 --tab 1                       # 破坏性：会弹确认
quickterm browser close  -t b3 --others                      # 只留当前这一个
```

`--tab` 认四种写法：`1`（1 起的序号）、`#<id 前缀>`、`@active`（默认）、`@last`。
序号与 id 都在 `state` / `get` 的 `tabList` 里。
**关掉最后一个标签 = 关掉整个 pane**（和 ⌘W 一样）。

给 pane 起名，之后就能按名字找它：

```bash
quickterm pane set -t t7 --title 'build · web'   # 之后 -t 'title:~build' 就能命中
quickterm pane set -t t7 --title ''              # 交还给 shell
```

一条命令拼出整个工作区（**最高效的用法**）：

```bash
cat <<'EOF' | quickterm spec apply -t 1:4 --into-empty -f -
{"schema":"quickterm.workspace/1","layout":"scrolling","columns":[
  {"width":0.3,"panes":[{"cwd":"~/proj","cmd":"nvim ."}]},
  {"width":0.4,"panes":[{"cwd":"~/proj","cmd":"npm run dev","hold":true},{"cwd":"~/proj"}]},
  {"width":0.3,"panes":[{"kind":"browser","url":"http://localhost:3000"}]}]}
EOF
```

先导出现有布局改两行再装回去，比从零写更稳：

```bash
quickterm spec dump -t 1:2 > /tmp/ws.json
quickterm spec apply -f /tmp/ws.json --dry-run   # 先看会改什么
```

## 规矩（照做，能少踩坑）

1. **只用绝对设值，别指望 toggle。** `pane set --zoom on` 而不是 `action toggle-zoom`。
   你看不到当前状态，一条 toggle 重试一次就把自己撤销了。所有 `pane set` / `workspace set-layout`
   都是幂等的：重复执行结果相同，加 `--fail-if-noop` 时"已经是目标状态"会退出码 7。
2. **动之前先 `--dry-run`**，尤其是 `spec apply`。它只报告会改什么，什么都不动。
3. **地址要用句柄或 uuid，别跨命令依赖"当前焦点"。** 两条命令之间焦点可能已经变了。
4. **组合布局用 `spec apply`，不要连发 N 条 `pane new`。** 前者一次重排、一次动画；后者界面会闪，
   而且中途失败会留下半成品。
5. **别刷命令。** 有限流。要等界面变化就用 `quickterm events poll --since <seq> --timeout 10`
   （`state` 的返回里有 `seq`），不要轮询 `state`。
6. **`--cwd` 要给真实路径**（`"$PWD"` 或 `~/proj`），`.` 会被拒绝。
   `~/Desktop`、`~/Documents`、`~/Downloads` 是 macOS 的受保护目录：QuickTerm 没拿到
   「文件与文件夹」授权时用不上，pane 照开但 shell 起在别处——响应里会带一条
   `warnings[].code == "cwd_denied"`（**读这个 code，别读文案**）。目录不对就宁可失败的话加 `--require-cwd`。
7. **错误要读 JSON。** 失败时 stderr 是带稳定 `code` 的 JSON，退出码有含义（3=参数/目标错，
   4=用户拒绝或超时，7=无变化）。别去匹配中文提示文字。

## 会被拦下来的事

- **破坏性操作**（`pane close`、`screen close`、`workspace clear`、`spec apply --replace`）
  会在 QuickTerm 里**弹确认框**，按"调用进程"记一次。用户拒绝 → 退出码 4。别重试，去问用户。
- **`input send-text`（往 pane 里打字）默认关闭**，要用户在配置里打开 `[control] send-text = true`。
  即便打开：写**你自己**那个 pane 免确认，写别的 pane **每次都要用户确认**——
  因为那等于在别人的 shell 里执行命令（可能是 root，也可能是一条活着的 ssh 会话）。
  要跑命令，优先 `pane new --cmd "..."`，不要往别人的终端里塞字符。
- **打开面板类的动作**（主题选择器、主菜单等）一律被拒绝：它们需要键盘交互，经 socket 执行只会把界面卡在半路。
- **读终端屏幕上的文字（`pane capture-text`）默认关闭**，要用户写 `[control] capture-text = true`。
  即便打开：必须带 `QUICKTERM_TOKEN`，而且**每个调用进程都要用户确认一次**——包括读你自己那个 pane。
  （`send-text` 写自己免确认，读没有这个豁免：屏幕上可能停着用户把 pane 交给你之前敲的东西。）
  它什么都不改，所以不认 `--dry-run` / `--fail-if-noop`。
  要自己命令的输出，用 `pane new --cmd "..."` 或直接在本地跑，别去读别人的屏幕。
- **浏览器 pane 的网址与标题**对没有 `QUICKTERM_TOKEN` 的调用方显示为 `<redacted>`——
  逐标签的 `tabList` 也一样。你在 pane 里跑就有这个变量。

## 建议的工作方式

- 开发服务：`pane new --cwd "$PWD" --cmd "npm run dev" --hold --at @self --where right`，
  日志就在旁边，用户随时能看见——比你把输出塞进自己的上下文好得多。
- 要用户看网页：`pane new --kind browser --url ...`，别去开系统浏览器。
- 布局乱了：`quickterm spec dump -t <工作区> > /tmp/before.json`，改完出问题能一键还原。
- 干完活别留垃圾 pane；但**关 pane 会弹确认**，所以更好的做法是问用户要不要关，而不是自己去关。
