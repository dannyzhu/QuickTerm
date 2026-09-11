# quickterm 控制面（CLI / AI agent）

QuickTerm 内置一个 Unix domain socket 控制面，随包提供 `quickterm` 命令行工具。
**先做一次 `quickterm describe --json`**（整个控制面的机器可读 schema），之后不必再反复读 `--help`。

## 装好它

```
quickterm install-cli --alias qt        # 软链到 /usr/local/bin，不可写则 ~/.local/bin
```
也可以走菜单：QuickTerm → 安装 quickterm 命令行工具…
二进制在 `QuickTerm.app/Contents/SharedSupport/quickterm`
（**不是** `Contents/MacOS`：APFS 大小写不敏感，`quickterm` 会覆盖掉主可执行文件 `QuickTerm`）。
**永远不会请求管理员权限**；升级或移动 QuickTerm.app 之后重新跑一次。

## 在 pane 里零配置

每个新建 pane 的环境里都有：

| 变量 | 含义 |
|---|---|
| `QUICKTERM_SOCKET` | 控制 socket 路径 |
| `QUICKTERM_PANE` | 本 pane 的 UUID —— `-t @self` 就靠它 |
| `QUICKTERM_SCREEN` / `QUICKTERM_WORKSPACE` | **创建时**的序号（提示值；pane 移动后不更新） |
| `QUICKTERM_TOKEN` | 来源证明，**不是权限边界**（见下） |
| `QUICKTERM_PANE_TOKEN` | **每 pane 一枚**、可验证的来源标记。只用在一处：`input send-text` 写自己那个 pane 时免确认 |

在任意 pane 里 `env | grep QUICKTERM` 就能看到。

## 命令面

查询与直通（Phase 1）：

```
quickterm state   [-t 目标] [--fields a,b]
quickterm list    screens|workspaces|panes [-t 目标] [--fields a,b]
quickterm get     -t 目标
quickterm action  <wm-action> [-t 目标] [--precise]
quickterm action  --list
quickterm describe [--json]
quickterm version
quickterm install-cli [--alias qt] [--dir 目录]
```

名词-动词层（Phase 2，**这一层才是给 agent 用的**）：

```
quickterm pane      new|close|focus|move|swap|set|resize|capture-text
quickterm browser   open|goto|reload|close          # 浏览器 pane 里的标签
quickterm workspace goto|set-layout|equalize|clear|count
quickterm screen    new|close|move|focus|set
quickterm app       get|set
```

一次性组合（Phase 3）：

```
quickterm spec dump     [-t 目标] [--all] [--relocatable] [--include-ids]
quickterm spec validate [-f 文件 | --spec JSON]
quickterm spec apply    [-f 文件 | --spec JSON] [-t 目标]
                        [--into-empty | --replace | --reuse] [--dry-run]
```

事件与打字（Phase 4）：

```
quickterm events poll   [--since <seq>] [--timeout 5s] [--limit N] [--types a,b]
quickterm events follow [--since <seq>] [--types a,b]
quickterm input send-text <文本> -t 目标 [--enter]
```

MCP（Phase 5）：

```
quickterm mcp                    # stdio MCP 服务；由宿主拉起，别在终端里手敲
quickterm mcp --list-tools       # 工具表本身（JSON）
```

`action` 是**快捷键平价的直通车**：全部 67 个 `WMAction` 原样直达 `perform()`，
所以「快捷键能做的，命令行都能做」在第一天就成立，而且结构上不可能漂移。
但它保留的是**快捷键语义**（全是 toggle、全是"作用于焦点"）。

**名词-动词层全是绝对设值**——这是整个 Phase 2 的定规：

| 别写 | 要写 | 为什么 |
|---|---|---|
| `action toggle-zoom` | `pane set -t t7 --zoom on` | agent 看不到状态；重试一次 toggle 会把自己撤销 |
| `action toggle-layout` | `workspace set-layout dwindle -t :4` | toggle 只能作用于**活动**工作区，而且没法指定目标 |
| `action move-to-workspace-3` | `pane move -t t7 --to :3 [--follow]` | 前者只搬焦点 pane，而且强制跟随切换 |
| `action resize-right` | `pane set -t t7 --width 0.33`（或 `pane resize -t t7 --dir right`） | 绝对值可重放，增量不行 |
| `action theme-picker` | `app set theme tokyo-night` | 面板要靠方向键选，经 socket 执行等于把 UI 卡在半路 |

同一条设值命令跑两次，第二次什么都不做（`changed:false`）；
加上 `--fail-if-noop` 时第二次是**退出码 7**——这正是"我以为我改了，其实没有"的信号。

### 每条变更命令都认的两个开关

- `--dry-run`：只回 `changes`（一份 diff），**一个字节都不改**。动真格之前先预演。
  （只有名词-动词层认这两个开关；`action <wm-action>` 是直通车，带上会退出码 3。）
- `--fail-if-noop`：已经是目标状态时退出码 7，而不是静默成功。

变更类响应是统一的信封：

```json
{"ok":true,"seq":415,"resolved":{"screen":1,"workspace":2,"pane":"t9"},
 "data":{"command":"pane.set","applied":true,"changed":true,"dryRun":false,
   "changes":[{"path":"1:2.t9.zoom","from":"off","to":"on"}],
   "pane":{"handle":"t9","…":"…"},"undo":"控制面：pane set"}}
```

### 落点（`--at` / `--where`）

`--where right|left|up|down|stack` 走的就是鼠标拖放那一套落点算法（同一份代码），
`--at` 是锚点 pane：`quickterm pane new --cwd ~/proj --cmd 'npm run dev' --at t1 --where right`。
`--cmd` 建出来的 pane 在命令退出时自己关掉（`--hold` 可以让它留着）。

### 尺寸：读得到，也调得动

**每一条读命令都带尺寸。** `state` / `list panes` / `get` 里每个 pane 都有一段 `size`：

```json
"size":{"rect":[0.3,0,0.7,0.7],"points":[1086,630],"cols":135,"rows":33,
        "split":"vertical","ratio":0.7}
```

- `rect` = 工作区布局区里的归一化矩形 `[x,y,w,h]`，**左上角为原点**，由模型里的
  比例 / 列宽算出来（不是读 frame，所以重排期间也不会给出上一帧的数）；
  scrolling 的横向单位是"一个视口宽"，条带溢出时 `x+w` 会大于 1。**`rect` 是准的那个**。
- `points` = 这个 pane 的**槽位**点尺寸。底是工作区布局区 = 窗口内容区去掉顶部状态条、
  再去掉外圈那一圈 pane-gap 留白——正是分裂树真正铺开的那块地，也是 `--points` 换算和
  分隔条夹取踩的同一块底。槽位里面还有每个 pane 自己的一圈留白和终端 pane-padding，
  终端画布比槽位小：要网格就看 `cols`/`rows`（引擎量的），别拿 points 去除字宽。
  窗口还没挂上时整字段没有。
- dwindle 另给 `split`/`ratio`（最近那条分隔条的方向与比例）；
  scrolling 另给 `width`（列宽因子）与 `share`（列内份额 = 1/列内 pane 数）。
- `hidden: true` = 本工作区有 pane 被 zoom，而这一片不是它：**它现在屏幕上一点位置都没有**，
  所以不给 `points`。`rect`/`ratio`/`width` 照旧是底下那层平铺——`pane resize` 调的就是它，
  取消 zoom 也回到它。被 zoom 的那一片则报满整块布局区。

dwindle 工作区的骨架就是那棵树，**和 `spec dump` 一套词**（`split`/`ratio`/`a`/`b`），
叶子装句柄：

```json
{"index":3,"layout":"dwindle","panes":["t8","b3"],
 "tree":{"split":"vertical","ratio":0.62,"a":{"pane":"t8"},"b":{"pane":"b3"}}}
```

**调尺寸与鼠标同权**，三条路对应鼠标的三种手势：

```sh
quickterm pane resize -t t8 --ratio 0.62              # = 把那条分隔条拖到 62%
quickterm pane resize -t t8 --points +120             # = 把它往右/下拖 120pt（裸数字 = a 侧设成 N pt）
quickterm pane resize -t t8 --split root --ratio 0.3  # = 去拖祖先那条分隔条（路径 a/b，根写 root）
quickterm pane resize -t t7 --dir right --points 100  # = 按一次 ⌘⌃→（也是 ⌘右键拖拽那条路）
quickterm pane resize -t t7 --width +0.05             # scrolling 列宽因子（--points 则按点数）
```

夹取规则也是同一条：`--ratio` / `--points` 走分隔条拖拽那条（两侧各留 10pt，
与拖拽同一个函数、同一块底，命令行够不到鼠标够不到的地方），`--dir` 走快捷键那条（0.1–0.9），
列宽走 `0.25–0.90`。到边界就是空操作（`--fail-if-noop` 退 7）。
`--dir`（就近同向那条）与 `--split`（指名哪一条）互斥，一起给会报错而**不会**悄悄调另一条。
组合工作区时把尺寸直接写进 spec（`columns[].width` / `tree` 每层的 `ratio`），
`spec dump → apply → dump` 连非默认比例都是逐字节不动点。

### 给 pane 起个名字：`pane set --title`

```sh
quickterm pane set -t t7 --title 'build · web'   # = 右键「Change Terminal Title」
quickterm get -t 'title:~build'                  # 之后就能按标题寻址它
quickterm pane set -t t7 --title ''              # 空串 = 交还给 shell
```

绝对设值：跑两次结果一样，第二次 `changed:false`（带 `--fail-if-noop` 时退 7）。
标题会出现在 `state` / `list` / `get` 的 `title` 字段里，而 **`title:~<正则>` 是一等的寻址写法**——
给几个长期存在的 pane 起名字，比每次都去查一串句柄稳得多（句柄会随 pane 关掉而回收）。
只有终端 pane 能设：浏览器 pane 的标题来自网页，设了也会被下一次导航盖掉。
这样设下的标题还会直接画在 pane 的上边框上（最长 20 字；配置 `[appearance] pane-title = false` 关掉）。

### 浏览器标签：`browser`

```sh
quickterm browser open   -t b3 --url http://localhost:3000   # 新标签
quickterm browser goto   -t b3 --url http://localhost:5173   # 当前标签换网址
quickterm browser goto   -t b3 --tab 2 --url https://a.b     # 指定标签
quickterm browser reload -t b3 --tab 1 [--hard]              # 刷新（--hard 绕过缓存）
quickterm browser close  -t b3 [--tab 1 | --others] [--force]
```

- **`-t` 指 pane（`b3`），`--tab` 指 pane 里的标签。** 标签有三种写法：
  **1 起的序号**（会随开关标签移位）、**`#<id 或 ≥4 位前缀>`**（标签活着就不变，agent 该用这个）、
  **`@active`（默认）/ `@last`**。三种都能在 `state` / `get` 的 `tabList` 里原样读到：

  ```sh
  quickterm get -t b3 --json | jq '.data.pane.tabList'
  # [{"index":1,"id":"8A1F…","active":true,"title":"docs","url":"https://…"}]
  ```

- `browser goto` 是**绝对设值**：已经在那个网址上就什么都不做（`--fail-if-noop` 退 7）。
  要强制重新取一次用 `browser reload`——"换网址"与"刷新"是两个不同的意图。
  比的是**规范化之后**的网址：`http://localhost:3000` 与 WebKit 落地后报的
  `http://localhost:3000/` 是同一个页面（scheme / 主机名大小写、默认端口同理）。
  到此为止——路径末尾的斜杠（`/a` 与 `/a/`）、query 的顺序、fragment 都是**不同的页面**。
  同一条规则也用在 `spec apply --reuse` 的浏览器 pane 匹配上，
  所以手写 spec 里的 `"url":"http://localhost:3000"` 不会每次都把 pane 拆了重建。
- **`browser close` 关掉最后一个标签时会关掉整个 pane**，与 ⌘W 逐字一致（Chrome 语义）。
  它是破坏性的，会先要求确认；`--others` 则永远留下 `--tab` 指的那一个，不会关 pane。
- **打码规则一个字都不松**：没有 `QUICKTERM_TOKEN` 的调用方读到的 `tabList` 里，
  `title` / `url` 是 `<redacted>`（`index` / `id` / `active` 照给——那是寻址要用的），
  变更信封里的 diff 同样打码。对这类调用方 **`goto` 不再是幂等的**：它一律当成一次改动
  （`changed` 恒真、照常加载），否则一条 `--dry-run --fail-if-noop` 就成了
  「这个标签是不是正停在某网址上」的是/否探测器——而它本来连那个网址都读不到。
- **网址与标题不进系统日志**：应用内的活动日志面板里写全（看的人就是你本人），
  但镜像进统一日志（OSLog）的那一份只留路径（`1:2.b3.tab1.url 已变更`）。
  那份日志落在 `/var/db/diagnostics`，应用退出后还在、`sysdiagnose` 会打包带走。
  终端标题（`pane set --title` / `pane close`）同理。

### 读终端屏幕：`pane capture-text`

```sh
quickterm pane capture-text -t t7                      # 可视区
quickterm pane capture-text -t t7 --scrollback 200     # 再往上带 200 行历史
quickterm pane capture-text -t t7 --json | jq -r .data.text
```

回的是那个 pane **此刻屏幕上的文字**（外加引擎量到的 `cols` × `rows`），
用来回答"我刚起的那条命令到底跑成什么样了"——事件流里永远不会有 pane 的输出。

**它是 `sensitive`，不是 `read`**，因为一个 shell 的可视区里可能有 token、
刚敲进去还没回车的密码、私有代码。四道闸门各自独立：

- 默认**关闭**：`[control] capture-text = true` 之前一律拒绝（退出码 5）。
  它与 `send-text` 是**两个**开关，打开一个绝不会顺带打开另一个。
- 调用方必须带着本次启动的 `QUICKTERM_TOKEN`（浏览器网址打码用的同一枚）——
  在 QuickTerm 的 pane 里跑就是自动的；读不到浏览器标题的调用方一律读不到终端屏幕。
- 每个调用进程要用户在 QuickTerm 里**确认一次**（框里写明是"读取哪个 pane 屏幕上的全部文字"）。
  没有"读自己那个 pane 免确认"的豁免：一个进程本来就读不到自己 tty 的回滚缓冲。
- 正文**只在那一条响应里出现一次**：不进活动日志、不进事件流、不进统一日志。

它什么都不改，因此**不认 `--dry-run` / `--fail-if-noop`**（带了退 3）：
`--dry-run` 在别处同时意味着免确认，在这里就成了绕过闸门拿到全部内容的后门。

### 工作目录用不上时：`cwd_denied` 与 `--require-cwd`

macOS 把 `~/Desktop` `~/Documents` `~/Downloads` 划成受保护目录，授权按**代码签名身份**记账。
没有授权时 QuickTerm 不会把这个目录交给引擎（否则启动会挂死，见 `WorkingDirectoryGate`），
shell 于是起在默认目录。这件事**不再是静默的**：

```sh
quickterm pane new --cwd ~/Downloads
# ⚠️ 工作目录 /Users/you/Downloads 没能用上：…（cwd_denied）
#    → 在系统设置 ▸ 隐私与安全性 ▸ 文件与文件夹里给 QuickTerm 勾上对应的项…
```

```json
{"ok":true,"data":{"command":"pane.new","applied":true,
  "warnings":[{"code":"cwd_denied","path":"/Users/you/Downloads",
               "message":"…","hint":"…"}]}}
```

- 默认**照常开 pane 并带一条告警**：命令确实成功了，把它变成失败会让每一个不在乎
  目录的脚本跟着挂掉。**在 `code` 上分支**（`cwd_denied` 是稳定的），别去匹配文案。
- 受不了这种回退的脚本加 **`--require-cwd`**：目录用不上就退出码 5，而且**一个 pane 都不建**。
  `spec apply` 同样认这个开关（预检阶段就失败，一个 pane 都不动）。
- 只对**真的会用到 cwd 的 pane** 生效：浏览器 pane 不消费 `--cwd`（它只要一个网址），
  所以 `pane new --kind browser --cwd ~/Downloads` 既不告警也不会被 `--require-cwd` 拦下——
  一律带 `--cwd "$PWD"` 的脚本不会因为当前目录恰好受保护就开不出浏览器 pane。

## 一次性组合：`spec`

**要摆好一整个工作区，用 `spec apply`，别发 N 条 `pane new`。**
N 条命令 = N 次重排、N 次动画、N 个失败点，中途失败还会留下一个谁也说不清的半成品；
`spec apply` 是一次算完、一次落地（先把整个布局值算好，再一次赋给模型）。

公开格式是 `quickterm.workspace/1`（外加 `quickterm.screen/1` / `quickterm.session/1`
两个信封，原样复用同一套词汇）。**每个字段都可省**，所以两行就是一份合法的 spec：

```json
{"columns":[{"panes":[{}]},{"panes":[{},{}]}]}
```

完整一点的一份（scrolling：列 × 列内纵栈）：

```json
{ "schema": "quickterm.workspace/1", "layout": "scrolling", "visibleColumns": 3,
  "columns": [
    {"width":0.33,"panes":[{"kind":"terminal","cwd":"~/proj","cmd":"nvim ."}]},
    {"width":0.33,"panes":[{"kind":"terminal","cwd":"~/proj","cmd":"npm run dev","hold":true,
                            "env":{"NODE_ENV":"development"}},
                           {"kind":"terminal","cwd":"~/proj"}]},
    {"width":0.33,"panes":[{"kind":"browser","url":"http://localhost:3000"}]}],
  "focus": {"column":0,"row":0} }
```

dwindle 则是一棵分裂树（`split` = `horizontal` 时 a 左 b 右，`vertical` 时 a 上 b 下）：

```json
{ "layout":"dwindle",
  "tree":{"split":"horizontal","ratio":0.6,
          "a":{"pane":{"cwd":"~/proj"}},
          "b":{"split":"vertical","ratio":0.5,
               "a":{"pane":{"cmd":"htop","hold":true}},
               "b":{"pane":{"kind":"browser","url":"http://localhost:3000"}}}},
  "focus":{"path":"b.a"} }
```

默认值：`kind` = terminal，`ratio` = 0.5，`width` = 按每屏可见列数折算，
`cwd` = 继承锚点 pane 的目录，`focus` = 第一个 pane。字段表在 `quickterm spec apply --help`
与 `describe --json` 的 `specSchema` 里（两处同一出处）。

三种模式：

| 模式 | 语义 |
|---|---|
| `--into-empty`（默认） | 只往**空**工作区里放；非空一律拒绝（退出码 4）。**毁不掉任何东西** |
| `--replace` | 覆盖：原有 pane 全部走真正的关闭路径（**破坏性**，会先确认）。整份一模一样时是空操作 |
| `--reuse` | 能对上的 pane 原地留着（跑着的 dev server 不会被重启），其余关掉 / 新建 |

典型工作流——**dump 一份已知好用的，改两个字段，再落回去**：

```sh
quickterm spec dump -t 1:2 > dev.json          # 打印的就是那份 spec 本身，可以直接重定向
vi dev.json                                     # 比如把某一列的 width 改成 0.5
quickterm spec apply -f dev.json -t 2:4 --dry-run   # 先看 diff：只报几何变化就说明不会重建 pane
quickterm spec apply -f dev.json -t 2:4 --reuse
```

几条一定要知道的：

- `cmd` / `env` / `hold` **只进不出**：活着的 surface 不记得自己是被什么命令拉起来的，
  `spec dump` 因此不会回吐 `cmd`。写了 `cmd` 的那一格，`--reuse` 会把对得上的 pane 原地留着
  （**不重跑**，重试不会重启 dev server）；`--replace` 的语义是拆了重建，那条命令会被重新拉起来。
- `--include-ids` 里的 `id` 是"就要这一个 pane"的指名道姓，**只有 `--reuse` 认它**：
  否则 dump 一份带 id 的、改掉某个 `cwd` 再 `--replace`，每一格都会靠 id 对上，改动被整份丢掉。
- `dump → apply → dump` 是**不动点**：dump 出来的东西落回去，再 dump 一次逐字节相同。
- 认不得的键一律报错（写错 `colums` 不会被静默忽略），数值越界报错并给出范围，**绝不静默夹紧**。
- 没有 token 的调用方读不到浏览器 pane 的网址（`redacted:true`，与 `state` 同一条规则）：
  这样一份 dump 再 apply 回去时，浏览器 pane 会开在主页而不是原来的网址。
- `spec apply` **不搬窗口**：屏幕信封里的 `display` / `frame` 只在 dump 里回显，
  要搬窗口请用 `quickterm screen move`。
- 落刀之后才失败会报 `partial_apply`（退出码 1）：工作区**已经被改过**，
  重新 `spec dump` 看一眼现状再决定怎么收拾——绝不会假装什么都没发生。

## 事件：`seq` 与 `events poll`

每一条成功的变更都会推进一个全局单调的 `seq`（`state` 与每条响应里回的就是它）。
**两处的 seq 是同一条尺子**：拿变更响应回的 seq 去 poll，不会漏掉自己那条命令产生的事件。

```sh
seq=$(quickterm state --json | jq .seq)
quickterm events poll --since "$seq" --timeout 30s     # 一次调用回答"我上次看之后发生了什么"
```

- **`events poll` 才是 agent 该用的形式**（一次请求-应答，长轮询）。
  `events follow` 是给人和 shell 脚本的 NDJSON 流——一条永不结束的流对模型是纯负担：
  每一条都进上下文，还得自己盯着。
- 回来的 `seq` 就是**下一次 `--since` 该给的值**，哪怕这一批是空的（`timedOut: true` 不是错误）。
- 缓冲是环形的：`missed: true` 意味着中间被挤掉了事件，手里的快照不完整，**重新读一次 `state`**。
- 九种事件：`pane.opened` `pane.closed` `focus.changed` `workspace.changed` `layout.changed`
  `screen.opened` `screen.closed` `pane.title.changed` `pane.cwd.changed`。
- **任何事件都不携带 pane 的输出内容**——只有结构、标题与 cwd，浏览器 pane 的标题 / cwd
  对没有 token 的调用方与 `state` 一样打码。想看输出，去那个 pane 里自己看。
- 有些变更（`app set theme`、`screen set --fullscreen`）会推进 `seq` 却没有对应的类型化事件：
  那时你只知道"快照过期了"，具体变了什么要重新读 `state`。
- **回的 `data.seq` 是游标，照着它一直轮下去就不会漏。** 一批被 `--limit` 截断时它只走到
  最后一条真的送出去的事件，同时带 `truncated: true`——看到它就拿这个 seq 立刻再轮一次，
  不必等下一次 timeout。（`missed` 说的是另一件事：事件已经被挤出缓冲，再也拿不回来了，重读 `state`。）

## 向别人的 shell 打字：`input send-text`

```sh
quickterm input send-text 'git status' -t @self --enter
```

**这条命令等于在那个 tty 上打字**——那个 shell 可能是 root，可能是一条活着的 ssh 会话。
所以：

- 默认**关闭**：`~/.config/quickterm/config.toml` 里 `[control] send-text = true` 之前一律拒绝（退出码 5）。
- 写调用方**自己**那个 pane 免确认（那个 tty 本来就是它自己的）。判定只认**可验证的**那一枚：
  请求带来的 `QUICKTERM_PANE_TOKEN` 要与 `-t` **真正解析到的那个 pane** 现算的 HMAC 对得上。
  自报的 `QUICKTERM_PANE` 不参与判定（服务端验不了它），所以把它改成别人的 UUID 也换不来免确认。
- 写**任何**别的 pane 每次都要用户确认，而且这次批准**不进缓存**；
  确认框里会列出**要打进去的正文**（净化并截断）以及后面跟不跟回车——
  用户批准的是"这一串字"，不是笼统的"允许打字"。
- 控制字符一律拒绝（不是过滤，是拒绝）；**换行只能靠显式的 `--enter`**——
  没有 `--enter` 的文本只是躺在命令行上，不会执行。
- `-t` 是必须的：没有"往当前焦点那个 pane 里打字"这种写法。
- 文本本身**不进活动日志**（日志只记"多少个字符 + 有没有回车"）。

## MCP：`quickterm mcp`

同一张命令表还生成一个 stdio 的 MCP 服务，**13 个粗粒度工具**（不是一个命令一个工具）：

```sh
claude mcp add quickterm -- /usr/local/bin/quickterm mcp     # Claude Code
codex mcp add quickterm -- /usr/local/bin/quickterm mcp      # Codex CLI
quickterm mcp --list-tools | jq -r '.tools[].name'           # 看一眼会暴露出去的东西
```

工具：`quickterm_describe` `quickterm_state` `quickterm_action` `quickterm_new_pane`
`quickterm_focus` `quickterm_arrange` `quickterm_close` `quickterm_browser`
`quickterm_read_terminal` `quickterm_dump_spec` `quickterm_apply_spec`
`quickterm_poll_events` `quickterm_send_text`。

- 每个工具背后是命令表里的哪几条命令，写在它的 `description` 里，也在
  `quickterm describe --json` 的 `mcpTools` 里。参数名与 CLI 一模一样（`target` / `dry-run` / …）。
- 注解是**机械地**从安全分级映射的：`read` → `readOnlyHint`，
  `destructive` / `sensitive` → `destructiveHint`，`idempotent` → `idempotentHint`。
  宿主靠它自动放行读、对破坏性调用弹确认——这是 QuickTerm 自己的确认闸门之外**独立的第二道闸**。
- MCP 这一层**没有任何自己的特权**：每次 `tools/call` 走的都是同一条 socket、同一套确认、限流与活动日志。
- `events follow`（流）与 `install-cli`（造软链）刻意不上 MCP；`spec` 只能内联给
  （MCP 这一侧没有 `-f`：读文件永远是调用方那一边的事）。
- **什么时候用哪个**：交互式的一次性控制用 MCP（宿主那一层能替你把闸门做好）；
  批量组合用 CLI —— 工具表是每次会话都要付的上下文税（约 64 KB 的 schema），
  而 CLI 不调用就不占一个 token。

## 寻址

`screen:workspace.pane`，每段可省，向右默认取上下文。

- **screen**：1 起序号（= 窗口标题）、`#uuid:`（注意冒号）、`@current`、`@primary`
- **workspace**：1 起序号（= ⌘1..0）、`@active`、`@next`、`@prev`
- **pane**：`t7`/`b3` 短句柄、`#uuid`（≥4 位前缀）、`@focused`（默认）、`@self`、
  `@left @right @up @down`、`@next @prev`
- **谓词**：`title:~<regex>`、`cwd:<prefix>`、`kind:terminal|browser`、`role:file-manager`
  - `title:~` 的正则整条命令共用 200ms 匹配预算，超时报 `bad_target`（退出码 3）而不是把主线程钉死：
    嵌套量词（`(a|aa)+`、`(.|.)+`）在 ICU 上是指数级的。**别写嵌套量词**，或者直接用句柄。
  - `expose-browser` 打码生效时，浏览器 pane **不进 `title:~` 的候选池**——
    否则谓词就成了逐字符探测被打码标题的通道。

消歧规则（不留"看情况"）：裸数字是**屏幕**（pane 句柄一律带类型前缀）；裸 `#uuid` 是 **pane**，
要按 uuid 指屏幕必须写 `#uuid:`；谓词里的 `:`/`.` 不会被当成分隔符。

**匹配到多个一律报错并列出候选（退出码 3），绝不取第一个。**

"当前"的解析顺序：显式 `-t` → 调用方所在 pane（`QUICKTERM_PANE`）→
应用在前台时的 key 窗口 → 最近一次 key 的窗口 → 第一个屏幕。
每条响应都回显 `resolved`，不必再发一次查询就知道打中了哪里。

## 输出与错误

- stdout 是 TTY → 人话；不是 TTY → JSON。**agent 不必加任何开关**。
- 错误一律是 **stderr 上的 JSON**，带稳定 `code` 与 `exit`。**绝不要去匹配文案。**
- 退出码：0 成功 · 1 失败 · 2 没在运行 · 3 目标非法/有歧义 · 4 需要确认 ·
  5 被拒 · 6 忙/限流 · 7 无操作 · 8 协议版本不匹配

## 安全

默认**开**，模式 `ask`（`~/.config/quickterm/config.toml` 的 `[control]` 段可改）。
`mode` 只有三档：`off`（不监听）· `readonly`（只读）· `ask`（默认；`on` 是 `ask` 的别名）。
**没有"免确认"档**：确认闸门只能靠 `off` / `readonly` 绕开，写错一个值也只会回落到 `ask`。

- **read** 静默；但**没有来源 token 的调用方读不到浏览器 pane 的网址与标题**（`<redacted>`）——
  浏览器 pane 里装着用户已登录的会话，`quickterm state` 本身就是一个外泄面。
- **mutate** 静默执行，但**可见**：状态栏闪一下（写明命令与自称来源 pane），
  完整记录在 QuickTerm ▸「控制面活动…」里；布局类变更登记到 UndoManager，
  Edit ▸ 撤销（⌘Z）能整份回滚。（焦点在终端 pane 上时 ⌘Z 归终端，用菜单项那一条。）
  变更命令按来源限流，超了是退出码 6 并带 `retryAfterMs`。
- **destructive**（`close-pane`、`pane close`、`workspace clear`、`screen close`）按 (调用进程 pid, 命令类) **在 QuickTerm 里确认一次**；
  确认框显示的进程名与 pid 来自内核（`LOCAL_PEERPID`），所以抄走 token 也伪装不了；
  框里那句"自称来自 pane t3"是**调用方自报的**，服务端验不了，所以写明是自称。
  确认框里点名的是**解析好的那一个 pane**（句柄 + 标题 + 屏幕/工作区），
  批准之后落刀前还会再核一次身份——确认期间焦点被别的命令挪走了就整条 busy 掉，什么都不做。
  10 秒无人应答 → 退出码 4，去 QuickTerm 里批准后重试。
  用户面前挂着别的对话框时，**所有**变更类命令都返回 `busy`（退出码 6）。
- **sensitive**（`input send-text`、`pane capture-text`）**一条命令一个开关，默认全关**，
  确认的缓存也是一条命令一份——批准过"读屏幕"绝不等于顺手批准"往 shell 里打字"。
  - `input send-text`（`[control] send-text = true`）：只有写调用方自己那个 pane 免确认，
    而且要靠每 pane 一枚的 `QUICKTERM_PANE_TOKEN` 证明这一点（自报的 `QUICKTERM_PANE` 不算数）；
    写**任何**别的 pane 每次都要确认（框里带正文），且这次批准不进缓存。
  - `pane capture-text`（`[control] capture-text = true`）：**没有自读豁免**，
    调用方还必须带着 `QUICKTERM_TOKEN`（与浏览器打码同一枚），然后每个调用进程确认一次；
    不认 `--dry-run`（那会变成绕过确认的后门）；正文不进任何长期留存的记录。
- **interactive**（`theme-picker` `next-background` `keybind-help` `main-menu` `open-settings`
  `web-extensions`）**一律拒绝**：它们会打开需要键盘交互的面板或弹出菜单。
- 连接必须与 QuickTerm 同 uid（`LOCAL_PEERCRED` 硬校验）；socket 0600、目录 0700。
- **`QUICKTERM_TOKEN` 是来源证明，不是权限边界。** 每次启动只有一枚、注入每一个 pane，
  所以它只回答"这条命令来自**某个** QuickTerm pane"，**任何"有 token 就跳过确认"的写法都是错的**。
- **`QUICKTERM_PANE_TOKEN` 每 pane 一枚**（`HMAC(每次启动的密钥, paneID)`），
  能回答上面那枚答不了的"来自**哪一个** pane"。它只被用在 `input send-text` 的自写豁免上，
  同样不是权限边界：拿到它只等于"我在这个 pane 里"。

真正的威胁不是别的用户，是**被利用的代理**：pane 里的 agent 读到一个被投毒的网页 /
README / CI 日志，然后被指使去跑 `quickterm` 命令。所以确认闸门从第一版就在。

## 给 agent 的经验法则

1. 会话开始读一次 `quickterm describe --json`，别反复读 `--help`。
2. 按**句柄或 `#uuid`** 寻址，别跨两条命令去指"那个焦点 pane"——焦点交接是异步的。
3. 变更命令的响应里已经带了受影响的子树与新的 `seq`，**不要**再补一次 `state`。
4. 拿到退出码 3 时读 `candidates`，别重试同一个模糊目标。
5. `--fields` 能把 `state` 的体积压下来；六屏会话的完整 JSON 会吃掉大量上下文。
6. **优先用名词-动词层，别用 `action`**：前者是绝对设值，可重放；后者是 toggle，重试会把自己撤销。
7. 破坏性命令（`pane close` / `workspace clear` / `screen close`）之前先 `--dry-run` 看一眼 `changes`。
8. 退出码 7 不是错误，是"你要的状态已经成立"。只有在你**需要知道自己是否真的改了**时才加 `--fail-if-noop`。
9. **批量组合走 `spec apply`，不要发 N 条 `pane new`**；`spec apply --replace` 之前先 `--dry-run`。
10. 想改一份已有布局：`spec dump` → 改字段 → `spec apply --reuse`，别推倒重来（`--replace` 会把跑着的进程一起结束）。
11. 要等一件事发生，用 `events poll --since <seq> --timeout 30s`，**别去轮询 `state`**：
    一次调用就回答"我上次看之后发生了什么"，而轮 `state` 是每次都把整份快照塞进上下文。
12. 事件里没有、也永远不会有 pane 的输出内容。要读屏幕上的字用 `pane capture-text`
    （用户要先在 `[control]` 里打开它并确认一次）；要可靠地拿一条命令的输出，
    还是 `pane new --cmd 'cmd > /tmp/out' --hold` 落到文件里最稳。
13. `input send-text` 不是"运行一条命令"的 API：它是**在别人的键盘上打字**。
    要跑东西，优先 `pane new --cmd`——那条路有明确的进程边界，也不会撞进一个正在等你输入密码的 shell。
14. 给长期存在的 pane 起名字（`pane set --title`），之后用 `-t 'title:~…'` 寻址——
    句柄会随 pane 关掉而回收，名字不会。
15. 浏览器标签用 `--tab #<id>`（从 `tabList` 里抄），别用序号：开一个新标签就把序号全挪了。
16. 交互式的一次性控制挂 `quickterm mcp`（宿主那一层会替你确认）；
    批量组合直接用 CLI——工具表是每次会话都要付的上下文税，CLI 不调用就不占一个 token。
