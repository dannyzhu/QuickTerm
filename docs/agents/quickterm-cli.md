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

在任意 pane 里 `env | grep QUICKTERM` 就能看到。

## Phase 1 的命令面

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

`action` 是**快捷键平价的直通车**：全部 67 个 `WMAction` 原样直达 `perform()`，
所以「快捷键能做的，命令行都能做」在第一天就成立，而且结构上不可能漂移。
Phase 2 会补上绝对设值的名词-动词层（`pane set --zoom on` 之类），
**到时候请优先用那一层**：agent 看不到状态，重试一次 toggle 会把自己撤销。

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
- **mutate** 静默执行（Phase 2 起状态栏可见 + ⌘Z 可撤销）。
- **destructive**（`close-pane`）按 (调用进程 pid, 命令类) **在 QuickTerm 里确认一次**；
  确认框显示的进程名与 pid 来自内核（`LOCAL_PEERPID`），所以抄走 token 也伪装不了；
  框里那句"自称来自 pane t3"是**调用方自报的**，服务端验不了，所以写明是自称。
  确认框里点名的是**解析好的那一个 pane**（句柄 + 标题 + 屏幕/工作区），
  批准之后落刀前还会再核一次身份——确认期间焦点被别的命令挪走了就整条 busy 掉，什么都不做。
  10 秒无人应答 → 退出码 4，去 QuickTerm 里批准后重试。
  用户面前挂着别的对话框时，**所有**变更类命令都返回 `busy`（退出码 6）。
- **interactive**（`theme-picker` `next-background` `keybind-help` `main-menu` `open-settings`
  `web-extensions`）**一律拒绝**：它们会打开需要键盘交互的面板或弹出菜单。
- 连接必须与 QuickTerm 同 uid（`LOCAL_PEERCRED` 硬校验）；socket 0600、目录 0700。
- **`QUICKTERM_TOKEN` 是来源证明，不是权限边界。** 环境变量可继承、可读取；
  它只回答"这条命令来自 QuickTerm 开的 pane"，**任何"有 token 就跳过确认"的写法都是错的**。

真正的威胁不是别的用户，是**被利用的代理**：pane 里的 agent 读到一个被投毒的网页 /
README / CI 日志，然后被指使去跑 `quickterm` 命令。所以确认闸门从第一版就在。

## 给 agent 的经验法则

1. 会话开始读一次 `quickterm describe --json`，别反复读 `--help`。
2. 按**句柄或 `#uuid`** 寻址，别跨两条命令去指"那个焦点 pane"——焦点交接是异步的。
3. 变更命令的响应里已经带了受影响的子树与新的 `seq`，**不要**再补一次 `state`。
4. 拿到退出码 3 时读 `candidates`，别重试同一个模糊目标。
5. `--fields` 能把 `state` 的体积压下来；六屏会话的完整 JSON 会吃掉大量上下文。
