import Foundation

/// **一切从这一张表生成**：CLI 解析、`--help`、`describe --json`、安全分级，
/// 以及（Phase 5）MCP 工具表。命令表之外不得手写第二份命令描述——
/// 手写的那份两个版本之内必然漂移，而 agent 拿着漂移的 schema 只会得到自己解释不了的退出码 3。
enum ControlCommandClass: String, Codable, CaseIterable {
    /// 静默放行（无 token 的调用方读不到浏览器 URL / 标题）
    case read
    /// 静默执行，但可见（Phase 2 的状态栏闪烁 + 撤销登记）
    case mutate
    /// 会毁掉用户的东西（关 pane / 关屏幕）：按 (peer, 类) 确认一次
    case destructive
    /// 会打开需要键盘交互的面板 / 弹出菜单：**经 socket 一律拒绝**
    case interactive
    /// 触碰用户的隐私或别人的 tty（send-text、读浏览器 URL）：Phase 4
    case sensitive

    var requiresConsent: Bool { self == .destructive || self == .sensitive }
    var isMutation: Bool { self != .read }
}

struct ControlArgSpec: Codable, Equatable {
    enum Kind: String, Codable { case string, int, double, bool, enumeration }

    var name: String
    var kind: Kind
    var required: Bool
    var positional: Bool
    /// 可以重复给（`--env A=1 --env B=2`）：值收成数组。
    /// 刻意不做"逗号分隔"——环境变量的值里本来就可能有逗号
    var repeatable: Bool
    var values: [String]?
    var defaultValue: String?
    var help: String

    init(_ name: String, _ kind: Kind, help: String, required: Bool = false,
         positional: Bool = false, repeatable: Bool = false,
         values: [String]? = nil, defaultValue: String? = nil) {
        self.name = name
        self.kind = kind
        self.required = required
        self.positional = positional
        self.repeatable = repeatable
        self.values = values
        self.defaultValue = defaultValue
        self.help = help
    }
}

struct ControlCommandSpec: Codable, Equatable {
    /// 线上的命令名：顶层命令 = `state`，名词-动词层 = `pane.new`（点号）。
    /// **只有这一处拼接**：CLI 的 `pane new`、`--help`、describe、MCP 全部由它派生
    var name: String
    /// 名词（`pane` / `workspace` / `screen` / `app`）；顶层命令为 nil
    var group: String?
    /// 动词（`new` / `set-layout` / `state`）
    var verb: String
    /// 命令行里敲的形式（`pane new`）——与 `name` 同源，不可能各写各的
    var cli: String
    var summary: String
    var cls: ControlCommandClass
    /// 同样的输入跑两次结果一致（Phase 5 映射成 MCP 的 idempotentHint）
    var idempotent: Bool
    var acceptsTarget: Bool
    /// 完全在 CLI 侧完成，不经 socket（`install-cli`、`--help`）
    var local: Bool
    /// CLI 要先把 `-f <文件>`（或标准输入）读进来，塞进 `spec` 参数再发。
    /// **服务端绝不去读调用方的文件系统**：两个进程的 cwd 与权限本来就不一样，
    /// 而"服务端替你 open 一个路径"是个能被滥用的原语
    var readsFile: Bool
    var args: [ControlArgSpec]
    var examples: [String]
    /// 查询类命令内嵌一段真实的（节选）输出样例——
    /// 这是 wezterm 的 `--help` 缺、kitty 的文档有的那一项，能替 agent 省掉每个会话一次探路调用
    var outputSample: String?

    /// 非 `read` 类（它触碰隐私 / 别人的 tty），但**什么都不改**：`pane capture-text`。
    /// 见 `honorsMutationFlags`——这两件事必须分开说，否则"敏感"会被当成"会改东西"
    var readOnlyEffect: Bool

    /// 这条命令真的**实现了** `--dry-run` / `--fail-if-noop`。
    ///
    /// 两个开关是从名词-动词层"先算 diff 再决定动不动手"的形状里长出来的（出口是
    /// `ControlCommandRunner.commit()`）。`action <wm-action>` 是快捷键平价直通车，
    /// 直通 `perform()`：既算不出 diff，也没有"预演"这回事。
    /// 静默接受它的后果是双份的——一次"预演"真的落了刀，而 `--dry-run` 还顺手
    /// 把破坏性命令的确认闸门一起关掉了。
    /// **`readOnlyEffect` 的命令一律不认这两个开关**，而且这不只是"没意义"那么简单：
    /// `--dry-run` 在 `handle()` 里同时是**免确认**的理由（预演什么都不改，所以不问用户）。
    /// 一条什么都不改、却会把别人 shell 屏幕上的字回给调用方的命令要是认了 `--dry-run`，
    /// 那个开关就成了绕过确认闸门、照样拿到全部内容的后门
    var honorsMutationFlags: Bool { group != nil && cls.isMutation && !readOnlyEffect }

    init(group: String? = nil, _ verb: String, summary: String, cls: ControlCommandClass,
         idempotent: Bool, acceptsTarget: Bool, local: Bool = false, readsFile: Bool = false,
         readOnlyEffect: Bool = false,
         args: [ControlArgSpec], examples: [String], outputSample: String? = nil) {
        self.name = group.map { "\($0).\(verb)" } ?? verb
        self.group = group
        self.verb = verb
        self.cli = group.map { "\($0) \(verb)" } ?? verb
        self.summary = summary
        self.cls = cls
        self.idempotent = idempotent
        self.acceptsTarget = acceptsTarget
        self.local = local
        self.readsFile = readsFile
        self.readOnlyEffect = readOnlyEffect
        self.args = args
        self.examples = examples
        self.outputSample = outputSample
    }
}

enum ControlCommandTable {
    // MARK: 命令

    static let commands: [ControlCommandSpec] = [
        ControlCommandSpec(
            "state",
            summary: "读整个会话：扁平 pane 数组 + 引用句柄的屏幕/工作区骨架",
            cls: .read, idempotent: true, acceptsTarget: true, local: false,
            args: [
                ControlArgSpec("fields", .string,
                               help: "只输出这些 pane 字段（逗号分隔，如 handle,cwd,title）"),
            ],
            examples: [
                "quickterm state",
                "quickterm state --json | jq '.data.panes[] | select(.focused)'",
                "quickterm state -t 2 --fields handle,title,cwd",
            ],
            outputSample: stateSample),
        ControlCommandSpec(
            "list",
            summary: "列出 screens / workspaces / panes",
            cls: .read, idempotent: true, acceptsTarget: true, local: false,
            args: [
                ControlArgSpec("what", .enumeration, help: "要列的东西", required: true,
                               positional: true, values: ["screens", "workspaces", "panes"]),
                ControlArgSpec("fields", .string, help: "只输出这些字段（逗号分隔）"),
            ],
            examples: [
                "quickterm list panes",
                "quickterm list workspaces -t 2",
                "quickterm list panes --json | jq -r '.data.panes[].handle'",
            ],
            outputSample: listSample),
        ControlCommandSpec(
            "get",
            summary: "读单个 pane 的完整记录",
            cls: .read, idempotent: true, acceptsTarget: true, local: false,
            args: [],
            examples: [
                "quickterm get -t t7",
                "quickterm get -t @self",
                "quickterm get -t 'title:~nvim'",
            ],
            outputSample: getSample),
        ControlCommandSpec(
            "action",
            summary: "执行一个 WM 动作（快捷键平价直通车；全部 \(WMAction.allCases.count) 个）",
            cls: .mutate, idempotent: false, acceptsTarget: true, local: false,
            args: [
                ControlArgSpec("name", .string, help: "动作名（kebab-case，见 --list）",
                               required: true, positional: true),
                ControlArgSpec("list", .bool, help: "列出全部动作及其分级，不执行"),
                ControlArgSpec("precise", .bool, help: "精细步长（等价按住 Shift 的 resize-*）"),
            ],
            examples: [
                "quickterm action new-terminal",
                "quickterm action goto-workspace-3 -t 2",
                "quickterm action --list --json",
            ],
            outputSample: nil),
        ControlCommandSpec(
            "describe",
            summary: "把整个控制面当作机器可读的 schema 吐出来（agent 每个会话读一次即可）",
            cls: .read, idempotent: true, acceptsTarget: false, local: false,
            args: [],
            examples: [
                "quickterm describe --json",
                "quickterm describe --json | jq '.commands[].name'",
            ],
            outputSample: nil),
        ControlCommandSpec(
            "version",
            summary: "打印 CLI 与运行中 QuickTerm 的版本、协议版本、socket 路径",
            cls: .read, idempotent: true, acceptsTarget: false, local: false,
            args: [],
            examples: ["quickterm version", "quickterm version --json"],
            outputSample: nil),
        ControlCommandSpec(
            "install-cli",
            summary: "把 quickterm（可选 qt 别名）软链到 PATH——绝不弹管理员密码",
            cls: .read, idempotent: true, acceptsTarget: false, local: true,
            args: [
                ControlArgSpec("alias", .string, help: "另建一个短别名（通常是 qt）"),
                ControlArgSpec("dir", .string, help: "安装目录（默认 /usr/local/bin，不可写则 ~/.local/bin）"),
            ],
            examples: [
                "quickterm install-cli",
                "quickterm install-cli --alias qt",
            ],
            outputSample: nil),

        // MARK: —— Phase 2：名词-动词层（**绝对设值，绝不 toggle**）——
        // agent 看不到状态，重试一次 toggle 会把自己撤销。这一层的每条命令跑两次结果一致，
        // 第二次在 `--fail-if-noop` 下退 7。`action <wm-action>` 是唯一保留 toggle 语义的直通车。

        ControlCommandSpec(
            group: "pane", "new",
            summary: "新建一个 pane（终端 / 浏览器 / 文件管理器），可指定 cwd、命令、环境与落点",
            cls: .mutate, idempotent: false, acceptsTarget: true,
            args: [
                ControlArgSpec("kind", .enumeration, help: "pane 种类",
                               values: ["terminal", "browser", "file-manager"], defaultValue: "terminal"),
                ControlArgSpec("cwd", .string, help: "起始目录（支持 ~；默认继承锚点 pane）"),
                ControlArgSpec("require-cwd", .bool,
                               help: "--cwd 用不上就**报错**（默认是照常开 pane 并回一条 cwd_denied 告警）："
                                   + "受保护目录（~/Desktop ~/Documents ~/Downloads）缺少隐私授权时会走到这一步"),
                ControlArgSpec("cmd", .string, help: "要跑的命令（引擎会 wait-after-command；默认退出即关 pane）"),
                ControlArgSpec("hold", .bool, help: "命令退出后**不**关闭 pane（默认关闭）"),
                ControlArgSpec("env", .string, help: "额外环境变量 KEY=VALUE（可重复给）", repeatable: true),
                ControlArgSpec("url", .string, help: "浏览器 pane 打开的网址（--kind browser）"),
                ControlArgSpec("at", .string, help: "落点锚 pane（目标语法；默认焦点 pane）"),
                ControlArgSpec("where", .enumeration, help: "相对锚点的方位",
                               values: ["right", "left", "up", "down", "stack"], defaultValue: "right"),
            ],
            examples: [
                "quickterm pane new --cwd ~/proj --cmd 'npm run dev' --at t1 --where right",
                "quickterm pane new --kind browser --url http://localhost:3000 --at t1 --where down",
                "quickterm pane new --kind file-manager --cwd ~/proj",
                "quickterm pane new --cmd 'tail -f log' --hold --env RUST_LOG=debug",
                "quickterm pane new --cwd ~/Downloads --require-cwd   # 目录用不上就退 5，绝不静默落在别处",
            ],
            outputSample: paneMutationSample),
        ControlCommandSpec(
            group: "pane", "close",
            summary: "关掉一个 pane（会结束其中的进程；破坏性，按调用方确认一次）",
            cls: .destructive, idempotent: false, acceptsTarget: true,
            args: [
                ControlArgSpec("force", .bool, help: "跳过 QuickTerm 自己那句「仍有进程在运行」的确认"),
            ],
            examples: [
                "quickterm pane close -t t7",
                "quickterm pane close -t b3 --force",
            ],
            outputSample: nil),
        ControlCommandSpec(
            group: "pane", "focus",
            summary: "把键盘焦点交给一个 pane（幂等：已经是它就什么都不做）",
            cls: .mutate, idempotent: true, acceptsTarget: true,
            args: [
                ControlArgSpec("where", .enumeration, help: "相对当前焦点的方向（不写就用 -t）",
                               positional: true,
                               values: ["left", "right", "up", "down", "next", "prev"]),
            ],
            examples: [
                "quickterm pane focus -t t7",
                "quickterm pane focus right",
            ],
            outputSample: nil),
        ControlCommandSpec(
            group: "pane", "move",
            summary: "把 pane 移到别的工作区 / 屏幕（可指定落点；默认不跟随切换）",
            cls: .mutate, idempotent: false, acceptsTarget: true,
            args: [
                ControlArgSpec("to", .string, help: "目标 screen:workspace（如 2:4、:3、@next）", required: true),
                ControlArgSpec("at", .string, help: "目标工作区里的锚 pane"),
                ControlArgSpec("where", .enumeration, help: "相对锚点的方位",
                               values: ["right", "left", "up", "down", "stack"], defaultValue: "right"),
                ControlArgSpec("follow", .bool, help: "同时切到目标工作区 / 屏幕（默认不跟随）"),
                ControlArgSpec("no-follow", .bool, help: "显式不跟随（默认行为）"),
            ],
            examples: [
                "quickterm pane move -t t7 --to :4",
                "quickterm pane move -t t7 --to 2:1 --at t9 --where down --follow",
            ],
            outputSample: nil),
        ControlCommandSpec(
            group: "pane", "swap",
            summary: "两个 pane 互换位置（幂等：换完再换回来要再发一次，位置本身是绝对的）",
            cls: .mutate, idempotent: false, acceptsTarget: true,
            args: [
                ControlArgSpec("with", .string, help: "对手 pane（目标语法）", required: true),
            ],
            examples: ["quickterm pane swap -t t7 --with t2"],
            outputSample: nil),
        ControlCommandSpec(
            group: "pane", "set",
            summary: "绝对设值：zoom / float / 列宽（同样的命令跑两次结果一致）",
            cls: .mutate, idempotent: true, acceptsTarget: true,
            args: [
                ControlArgSpec("zoom", .enumeration, help: "本 pane 是否占满内容区", values: ["on", "off"]),
                ControlArgSpec("float", .enumeration, help: "本 pane 是否浮动", values: ["on", "off"]),
                ControlArgSpec("width", .double, help: "scrolling 列宽因子（0.25–0.90，绝对值）"),
                ControlArgSpec("ratio", .double,
                               help: "dwindle 最近父 split 的比例（\(SpecLimits.ratioRange.lowerBound)–\(SpecLimits.ratioRange.upperBound)，绝对值；越界报错）"),
                ControlArgSpec("title", .string,
                               help: "终端 pane 的标题（= 右键「Change Terminal Title」）；"
                                   + "空串 \"\" 清掉覆盖、回到 shell 自己报的那个。"
                                   + "设完就能用 -t 'title:~<正则>' 寻址它"),
            ],
            examples: [
                "quickterm pane set -t t7 --zoom on",
                "quickterm pane set -t t7 --float off --width 0.33",
                "quickterm pane set -t t7 --title 'build · web'   # 之后 -t 'title:~build' 就能找到它",
                "quickterm pane set -t t7 --title ''              # 交还给 shell",
            ],
            outputSample: nil),
        ControlCommandSpec(
            group: "pane", "resize",
            summary: "调尺寸（= 鼠标拖分隔条 / 拖列宽 / ⌘⌃方向键能做的那几件事）："
                + "比例、点数、列宽因子；到边界即无操作（退 7）",
            cls: .mutate, idempotent: false, acceptsTarget: true,
            args: [
                ControlArgSpec("width", .string, help: "scrolling 列宽因子：增量（+0.05）或绝对值（0.33）"),
                ControlArgSpec("ratio", .string, help: "dwindle 分裂比例：增量（+0.1）或绝对值（0.5）"),
                ControlArgSpec("points", .string,
                               help: "改用**点**：+120 = 把这条分隔条往右/下挪 120pt，120 = 把 a 那一侧设成 120pt"
                                   + "（scrolling 则是列宽点数）"),
                ControlArgSpec("dir", .enumeration,
                               help: "按方向调，等价于 ⌘⌃方向键 / ⌘右键拖拽：就近的同向分隔条，"
                                   + "步长 --points（默认 100）；与 --split 互斥",
                               values: ["left", "right", "up", "down"]),
                ControlArgSpec("split", .string,
                               help: "dwindle：指名调哪一条分隔条（树路径 a/b 点号连接，根那条写 root）；"
                                   + "不写 = 本 pane 的父分裂；与 --dir 互斥"),
            ],
            examples: [
                "quickterm pane resize -t t7 --width +0.05",
                "quickterm pane resize -t t8 --ratio 0.5",
                "quickterm pane resize -t t8 --points +120",
                "quickterm pane resize -t t8 --split root --ratio 0.3",
                "quickterm pane resize -t t7 --dir right --points 100",
            ],
            outputSample: resizeSample),
        ControlCommandSpec(
            group: "pane", "capture-text",
            summary: "读一个终端 pane **当前屏幕上的文字**（可选再带上若干行历史）——"
                + "默认关闭，每个调用进程确认一次",
            cls: .sensitive, idempotent: true, acceptsTarget: true, readOnlyEffect: true,
            args: [
                ControlArgSpec("scrollback", .int,
                               help: "可视区之上再带回多少行历史（0–\(ControlCaptureLimits.maxScrollback)，默认 0 = 只要可视区）",
                               defaultValue: "0"),
            ],
            examples: [
                "quickterm pane capture-text -t t7",
                "quickterm pane capture-text -t t7 --scrollback 200",
                "quickterm pane capture-text -t t7 --json | jq -r .data.text",
            ],
            outputSample: captureTextSample),

        // MARK: —— 浏览器 pane 的标签 ——
        // `-t` 指的永远是 **pane**（`b3`），`--tab` 才指 pane 里的那一个标签。
        // 标签有两种写法，都在 `state` / `get` 的 `tabList` 里回显：序号（1 起，会随开关标签移动）
        // 与 id（标签活着就不变）。**没有 token 的调用方读不到标题与网址**——
        // 与 pane 级 url / title 同一条打码规则，别处开个后门等于没打码。

        ControlCommandSpec(
            group: "browser", "open",
            summary: "在浏览器 pane 里新开一个标签并打开网址",
            cls: .mutate, idempotent: false, acceptsTarget: true,
            args: [
                ControlArgSpec("url", .string, help: "要打开的网址（不写 = 浏览器主页）"),
                ControlArgSpec("activate", .enumeration,
                               help: "新标签是否立刻成为当前标签", values: ["on", "off"],
                               defaultValue: "on"),
            ],
            examples: [
                "quickterm browser open -t b3 --url http://localhost:3000",
                "quickterm browser open -t b3 --url https://example.com --activate off",
            ],
            outputSample: browserSample),
        ControlCommandSpec(
            group: "browser", "goto",
            summary: "把某个标签导航到一个网址（绝对设值：已经在那儿就什么都不做）",
            cls: .mutate, idempotent: true, acceptsTarget: true,
            args: [
                ControlArgSpec("url", .string, help: "要打开的网址", required: true),
                ControlArgSpec("tab", .string, help: ControlTabRef.help, defaultValue: "@active"),
            ],
            examples: [
                "quickterm browser goto -t b3 --url http://localhost:5173",
                "quickterm browser goto -t b3 --tab 2 --url https://example.com",
                "quickterm browser goto -t b3 --tab '#8A1F' --url https://example.com",
            ],
            outputSample: nil),
        ControlCommandSpec(
            group: "browser", "reload",
            summary: "重新加载某个标签（`--hard` 连缓存一起绕过）",
            cls: .mutate, idempotent: true, acceptsTarget: true,
            args: [
                ControlArgSpec("tab", .string, help: ControlTabRef.help, defaultValue: "@active"),
                ControlArgSpec("hard", .bool, help: "绕过缓存（等价 ⌘⇧R）"),
            ],
            examples: [
                "quickterm browser reload -t b3",
                "quickterm browser reload -t b3 --tab 1 --hard",
            ],
            outputSample: nil),
        ControlCommandSpec(
            group: "browser", "close",
            summary: "关掉标签（破坏性）。**关掉最后一个标签 = 关掉整个 pane**——与 ⌘W 逐字一致",
            cls: .destructive, idempotent: false, acceptsTarget: true,
            args: [
                ControlArgSpec("tab", .string, help: ControlTabRef.help, defaultValue: "@active"),
                ControlArgSpec("others", .bool,
                               help: "反过来：**除了** --tab 指的那个，其余标签全关掉（本身不会关 pane）"),
                ControlArgSpec("force", .bool,
                               help: "只在「关到最后一个标签因而要关 pane」时有意义："
                                   + "跳过 QuickTerm 那句「仍有进程在运行」的确认"),
            ],
            examples: [
                "quickterm browser close -t b3                 # 关当前标签",
                "quickterm browser close -t b3 --tab 1         # 关第一个标签",
                "quickterm browser close -t b3 --others        # 只留当前这一个",
            ],
            outputSample: nil),

        ControlCommandSpec(
            group: "workspace", "goto",
            summary: "切到某个工作区（幂等）",
            cls: .mutate, idempotent: true, acceptsTarget: true,
            args: [
                ControlArgSpec("index", .int, help: "工作区序号（1 起）", required: true, positional: true),
            ],
            examples: ["quickterm workspace goto 3", "quickterm workspace goto 1 -t 2"],
            outputSample: nil),
        ControlCommandSpec(
            group: "workspace", "set-layout",
            summary: "把某个工作区设成 scrolling / dwindle —— **非活动工作区也能设**（toggle-layout 做不到）",
            cls: .mutate, idempotent: true, acceptsTarget: true,
            args: [
                ControlArgSpec("layout", .enumeration, help: "布局", required: true, positional: true,
                               values: ["scrolling", "dwindle"]),
            ],
            examples: [
                "quickterm workspace set-layout dwindle -t :4",
                "quickterm workspace set-layout scrolling -t 2:1",
            ],
            outputSample: nil),
        ControlCommandSpec(
            group: "workspace", "set",
            summary: "绝对设值：给工作区起名（同样的命令跑两次结果一致）",
            cls: .mutate, idempotent: true, acceptsTarget: true,
            args: [
                ControlArgSpec("title", .string,
                               help: "工作区的名字（= 右键工作区胶囊改名）；空串 \"\" 清掉，胶囊回到序号。"
                                   + "名字跟着**槽位**走，不跟着里面那堆 pane：clear、关掉最后一个 pane "
                                   + "都不会动它。改得动它的只有这条命令、右键改名，"
                                   + "以及一份**写了 title 的** spec（`spec dump` 出来的就写了）"),
            ],
            examples: [
                "quickterm workspace set --title dev",
                "quickterm workspace set -t 2:4 --title 'web · 日志'",
                "quickterm workspace set -t :4 --title ''            # 清掉名字",
            ],
            outputSample: nil),
        ControlCommandSpec(
            group: "workspace", "equalize",
            summary: "把工作区里的列宽 / split 比例全部等分（幂等）",
            cls: .mutate, idempotent: true, acceptsTarget: true,
            args: [],
            examples: ["quickterm workspace equalize -t :2"],
            outputSample: nil),
        ControlCommandSpec(
            group: "workspace", "clear",
            summary: "关掉一个工作区里的所有 pane（破坏性）",
            cls: .destructive, idempotent: true, acceptsTarget: true,
            args: [
                ControlArgSpec("force", .bool,
                               help: "已无作用：控制面的确认闸门已按整个工作区问过一次（与 screen close 同）"),
            ],
            examples: ["quickterm workspace clear -t :5"],
            outputSample: nil),
        ControlCommandSpec(
            group: "workspace", "count",
            summary: "设置工作区个数（1–10）：改写 config.toml 的 workspaces，由配置监听落地",
            cls: .mutate, idempotent: true, acceptsTarget: false,
            args: [
                ControlArgSpec("n", .int, help: "个数（1–10）", required: true, positional: true),
            ],
            examples: ["quickterm workspace count 8"],
            outputSample: nil),

        ControlCommandSpec(
            group: "screen", "new",
            summary: "新建一个屏幕（窗口），可指定显示器",
            cls: .mutate, idempotent: false, acceptsTarget: false,
            args: [
                ControlArgSpec("display", .string, help: "显示器：uuid:<…> / name:<…> / 1 起序号"),
                ControlArgSpec("inherit-cwd-from", .string, help: "新屏幕首个终端继承这个 pane 的目录"),
            ],
            examples: [
                "quickterm screen new",
                "quickterm screen new --display 'name:Studio Display' --inherit-cwd-from t1",
            ],
            outputSample: nil),
        ControlCommandSpec(
            group: "screen", "close",
            summary: "关掉一个屏幕连同它的所有 pane（破坏性）",
            cls: .destructive, idempotent: false, acceptsTarget: true,
            args: [
                ControlArgSpec("force", .bool, help: "跳过 QuickTerm 自己那句关屏幕确认"),
            ],
            examples: ["quickterm screen close -t 2 --force"],
            outputSample: nil),
        ControlCommandSpec(
            group: "screen", "move",
            summary: "把一个屏幕搬到另一台显示器（幂等：已经在那台就什么都不做）",
            cls: .mutate, idempotent: true, acceptsTarget: true,
            args: [
                ControlArgSpec("display", .string, help: "显示器：uuid:<…> / name:<…> / 1 起序号", required: true),
            ],
            examples: ["quickterm screen move -t 2 --display 1"],
            outputSample: nil),
        ControlCommandSpec(
            group: "screen", "focus",
            summary: "把某个屏幕的窗口置前并设为 key（幂等）",
            cls: .mutate, idempotent: true, acceptsTarget: true,
            args: [],
            examples: ["quickterm screen focus -t 2"],
            outputSample: nil),
        ControlCommandSpec(
            group: "screen", "set",
            summary: "绝对设值：全屏 / 在所有桌面显示 / 每屏可见列数",
            cls: .mutate, idempotent: true, acceptsTarget: true,
            args: [
                ControlArgSpec("fullscreen", .enumeration, help: "非原生全屏", values: ["on", "off"]),
                ControlArgSpec("join-all-spaces", .enumeration, help: "在所有桌面显示", values: ["on", "off"]),
                ControlArgSpec("visible-columns", .int, help: "scrolling 每屏可见列数（1–6）"),
            ],
            examples: [
                "quickterm screen set -t 1 --fullscreen off --visible-columns 3",
                "quickterm screen set -t 2 --join-all-spaces on",
            ],
            outputSample: nil),

        ControlCommandSpec(
            group: "app", "get",
            summary: "读进程级设置（主题 / 背景 / 间隙 / 透明 / 状态条 / 可见列数 / 控制面）",
            cls: .read, idempotent: true, acceptsTarget: true,
            args: [
                ControlArgSpec("key", .string, help: "只读某一项（不写 = 全部）", positional: true),
            ],
            examples: ["quickterm app get", "quickterm app get theme"],
            outputSample: appGetSample),
        ControlCommandSpec(
            group: "app", "set",
            summary: "绝对设值的进程级设置（这就是那 5 个模态面板动作在 socket 上的替代路径）",
            cls: .mutate, idempotent: true, acceptsTarget: true,
            args: [
                ControlArgSpec("key", .enumeration, help: "设置项", required: true, positional: true,
                               values: ControlAppSetting.allCases.map(\.rawValue)),
                ControlArgSpec("value", .string, help: "值（见 app get 的 choices）", required: true, positional: true),
            ],
            examples: [
                "quickterm app set theme tokyo-night",
                "quickterm app set gaps off",
                "quickterm app set visible-columns 3 -t 2",
            ],
            outputSample: nil),

        // MARK: —— Phase 3：一次性组合（`quickterm.workspace/1`）——
        // 一次调用摆好整个工作区，而不是发 N 条 pane new 再逐条调宽度：
        // N 条命令 = N 次重排、N 次动画、N 个失败点，中途失败还会留下一个谁也说不清的半成品。

        ControlCommandSpec(
            group: "spec", "dump",
            summary: "把一个工作区 / 一块屏幕 / 整个会话吐成 \(SpecSchema.workspace) 的 JSON",
            cls: .read, idempotent: true, acceptsTarget: true,
            args: [
                ControlArgSpec("all", .bool, help: "整个会话（\(SpecSchema.session)）"),
                ControlArgSpec("relocatable", .bool, help: "home 下的路径写成 ~/…（换台机器也能用）"),
                ControlArgSpec("include-ids", .bool,
                               help: "附上 id / handle / title（给 diff 与 --reuse 用，别的模式忽略 id；不参与不动点比较）"),
            ],
            examples: [
                "quickterm spec dump > dev.json                # 当前工作区",
                "quickterm spec dump -t 1:2 > dev.json",
                "quickterm spec dump -t 1 --relocatable > screen.json   # -t 只写屏幕 = 整块屏幕",
                "quickterm spec dump --all > session.json",
            ],
            outputSample: specSample),
        ControlCommandSpec(
            group: "spec", "validate",
            summary: "只校验一份 spec：认得的键、取值范围、工作区序号落不落得下去（什么都不改）",
            cls: .read, idempotent: true, acceptsTarget: true, readsFile: true,
            args: [
                ControlArgSpec("file", .string, help: "spec 文件（- 或不写 = 读标准输入）"),
                ControlArgSpec("spec", .string, help: "直接给 spec 的 JSON 正文（-f 的替代）"),
            ],
            examples: [
                "quickterm spec validate -f dev.json",
                "quickterm spec dump | quickterm spec validate",
                "quickterm spec validate --spec '{\"columns\":[{},{}]}'",
            ],
            outputSample: nil),
        ControlCommandSpec(
            group: "spec", "apply",
            summary: "把一份 spec 落到目标上；--replace 是破坏性的（会先确认），--dry-run 只给 diff",
            cls: .destructive, idempotent: true, acceptsTarget: true, readsFile: true,
            args: [
                ControlArgSpec("file", .string, help: "spec 文件（- 或不写 = 读标准输入）"),
                ControlArgSpec("spec", .string, help: "直接给 spec 的 JSON 正文（-f 的替代）"),
                ControlArgSpec("into-empty", .bool,
                               help: "默认：只往空工作区里放；非空一律拒绝（退出码 4），毁不掉任何东西"),
                ControlArgSpec("replace", .bool,
                               help: "覆盖：原有 pane 全部关掉（**破坏性**，会先确认；整份一模一样时是空操作）"),
                ControlArgSpec("reuse", .bool,
                               help: "能对上的 pane 原地留着（跑着的 dev server 不会被重启），其余关掉 / 新建"),
                ControlArgSpec("require-cwd", .bool,
                               help: "spec 里有目录用不上就**报错**（默认照铺并回 cwd_denied 告警）："
                                   + "受保护目录缺少隐私授权时会走到这一步"),
            ],
            examples: [
                "quickterm spec apply -f dev.json --dry-run           # 先看 diff，再决定",
                "quickterm spec apply -f dev.json -t 2:4 --replace",
                "quickterm spec apply -f dev.json --reuse",
                "quickterm spec apply -t :5 --spec '{\"columns\":[{\"panes\":[{}]},{\"panes\":[{},{}]}]}'",
            ],
            outputSample: specApplySample),

        // MARK: —— Phase 4：事件流 ——
        // 长轮询是**主形式**：一条永不结束的流对模型来说是昂贵的（每一条都进上下文，
        // 还得自己盯着），而 `poll --since` 一次调用就回答"我上次看之后发生了什么"。
        // **任何事件都不携带 pane 的输出内容**——那是隐私外泄面与流控复杂度的所在地。

        ControlCommandSpec(
            group: "events", "poll",
            summary: "长轮询：拿回 --since 之后错过的那一批事件就返回（agent 该用的形式）",
            cls: .read, idempotent: true, acceptsTarget: false,
            args: [
                ControlArgSpec("since", .int,
                               help: "上次拿到的 seq（不写 = 当前 seq，即只等接下来发生的事）"),
                ControlArgSpec("timeout", .string, help: "没有事件时最多等多久（5s / 500ms / 2m）",
                               defaultValue: "5s"),
                ControlArgSpec("limit", .int,
                               help: "一次最多回多少条（截断时回的 seq 只走到最后一条送出去的事件，"
                                   + "且带 truncated=true：拿它立刻再轮一次，一条都不会漏）",
                               defaultValue: String(ControlEventLimits.maxBatch)),
                ControlArgSpec("types", .string,
                               help: "只要这些类型（逗号分隔，如 pane.opened,focus.changed）"),
            ],
            examples: [
                "quickterm events poll --since 412",
                "quickterm events poll --since 412 --timeout 30s",
                "quickterm events poll --types pane.opened,pane.closed --timeout 0",
                "quickterm events poll --since $(quickterm state --json | jq .seq)",
            ],
            outputSample: eventsSample),
        ControlCommandSpec(
            group: "events", "follow",
            summary: "NDJSON 流：连接保持打开，事件一条条推过来（给人和 shell 脚本；Ctrl-C 结束）",
            cls: .read, idempotent: true, acceptsTarget: false,
            args: [
                ControlArgSpec("since", .int, help: "先补上这个 seq 之后已经发生的那一段（不写 = 只推新的）"),
                ControlArgSpec("limit", .int,
                               help: "每一批最多多少条（截断的部分不会丢：下一批接着推）",
                               defaultValue: String(ControlEventLimits.maxBatch)),
                ControlArgSpec("types", .string, help: "只要这些类型（逗号分隔）"),
            ],
            examples: [
                "quickterm events follow",
                "quickterm events follow --types focus.changed",
                "quickterm events follow --json | jq -r '.data.events[].type'",
            ],
            outputSample: nil),

        // MARK: —— Phase 4：向 pane 注入文本 ——
        // 这是整个控制面里唯一一条能让别人的 shell 执行任意命令的命令。默认关闭，
        // 打开之后仍然每次确认（往调用方自己那个 pane 写除外）。

        ControlCommandSpec(
            group: "input", "send-text",
            summary: "把文本当作键盘输入送进一个终端 pane —— **等于在那个 shell 里打字**（默认关闭）",
            cls: .sensitive, idempotent: false, acceptsTarget: true,
            args: [
                ControlArgSpec("text", .string, help: "要送的文本（控制字符一律拒绝）",
                               required: true, positional: true),
                ControlArgSpec("enter", .bool,
                               help: "文本之后再送一个回车 —— **这是让它执行的唯一方式**（默认不送）"),
            ],
            examples: [
                "quickterm input send-text 'git status' -t @self",
                "quickterm input send-text 'git status' -t @self --enter",
                "quickterm input send-text 'npm run dev' -t t7 --enter   # 别的 pane：每次都要确认",
            ],
            outputSample: sendTextSample),

        // MARK: —— Phase 5：MCP（stdio）——
        // 工具表**从这张命令表生成**（`MCPToolMap`）。手写一份工具描述两个版本之内必然漂移，
        // 而漂移的代价是 agent 拿着过期 schema 得到自己解释不了的错误。

        ControlCommandSpec(
            "mcp",
            summary: "在标准输入输出上跑一个 MCP 服务（工具表由本命令表生成；供 Claude Code / Codex 挂载）",
            cls: .read, idempotent: true, acceptsTarget: false, local: true,
            args: [
                ControlArgSpec("list-tools", .bool, help: "只打印工具表（JSON）就退出，不进 stdio 循环"),
            ],
            examples: [
                "quickterm mcp                       # 由 MCP 宿主拉起，别在终端里手敲",
                "quickterm mcp --list-tools          # 看一眼会暴露出去的工具与它们的注解",
                "quickterm mcp --list-tools | jq -r '.tools[].name'",
            ],
            outputSample: nil),
    ]

    /// 名词分组的出现顺序（`--help` 与 `describe` 用同一份）
    static var groups: [String] {
        var out: [String] = []
        for spec in commands { if let g = spec.group, !out.contains(g) { out.append(g) } }
        return out
    }

    static func commands(inGroup group: String) -> [ControlCommandSpec] {
        commands.filter { $0.group == group }
    }

    /// 线名（`pane.new`）与命令行写法（`pane new`）都认——两边是同一处生成的，查得到同一条
    static func command(_ name: String) -> ControlCommandSpec? {
        let normalized = name.replacingOccurrences(of: " ", with: ".")
        return commands.first { $0.name == normalized }
    }

    /// 全局开关（每条子命令都能用）
    static let globalFlags: [ControlArgSpec] = [
        ControlArgSpec("target", .string, help: "目标 screen:workspace.pane（-t）"),
        ControlArgSpec("json", .bool, help: "强制 JSON 输出（stdout 非 TTY 时本来就是 JSON）"),
        ControlArgSpec("plain", .bool, help: "强制人类可读输出"),
        ControlArgSpec("socket", .string, help: "指定 socket 路径（默认读 QUICKTERM_SOCKET）"),
        ControlArgSpec("help", .bool, help: "帮助（每条子命令都以 EXAMPLES 结尾）"),
        ControlArgSpec("dry-run", .bool, help: "只报告会改什么，什么都不改（仅变更类命令）"),
        ControlArgSpec("fail-if-noop", .bool, help: "已经是目标状态时退出码 7，而不是静默成功"),
    ]

    /// 每条变更命令都认的两个全局开关的 key（服务端按它们分流）
    enum Flag {
        static let dryRun = "dry-run"
        static let failIfNoop = "fail-if-noop"
        static let force = "force"
    }

    // MARK: WMAction 的安全分级

    /// 打开覆盖面板 / 弹出菜单，之后要靠方向键与回车才能用完——**经 socket 执行等于把 UI 卡在半路**。
    /// `web-extensions` 也在内：`NSMenu.popUp` 会跑一个事件跟踪循环，直接把主线程连同控制服务一起卡住
    /// （比另外 5 个更糟：它连"用户按 Esc"都没有明显的提示）。
    /// 这些动作的替代路径留给 Phase 2 的 `app set theme …` / `app set background …`。
    static let interactiveActions: Set<WMAction> = [
        .themePicker, .backgroundMenu, .keybindingHelp, .mainMenu, .openSettings, .webExtensions,
    ]

    /// 会毁掉用户东西的动作：关闭 pane 会结束其中的进程
    static let destructiveActions: Set<WMAction> = [.closePane]

    static func actionClass(_ action: WMAction) -> ControlCommandClass {
        if interactiveActions.contains(action) { return .interactive }
        if destructiveActions.contains(action) { return .destructive }
        return .mutate
    }

    /// 该动作被 socket 拒绝时给的具体去处
    static func interactiveHint(_ action: WMAction) -> String {
        switch action {
        case .themePicker: "主题面板要靠键盘选择；改主题请写 ~/.config/quickterm/config.toml 的 theme（Phase 2 会有 app set theme）"
        case .backgroundMenu: "背景面板要靠键盘选择（Phase 2 会有 app set background）"
        case .keybindingHelp, .mainMenu: "这是给人看的覆盖面板；机器要的清单在 quickterm describe --json"
        case .openSettings: "它会拉起外部编辑器；直接编辑 ~/.config/quickterm/config.toml 即可"
        case .webExtensions: "它会弹出 NSMenu 并占住主线程；扩展管理请在 QuickTerm 里操作"
        default: "该动作需要键盘交互，不能经 socket 执行"
        }
    }

    struct ActionDoc: Codable, Equatable {
        var name: String
        var cls: ControlCommandClass
        var helpZH: String
        /// 英文说明。**中英两份并列**：describe 的输出会被原样粘进中英混排的 agent 提示里
        var helpEN: String
        var browserOnly: Bool
        var terminalOnly: Bool
        var workspace: Int?
        var hint: String?
    }

    /// 全部 WMAction 的机器可读清单（`describe` 与 `action --list` 同一出处；
    /// `ControlActionTests` 钉死它与 `WMAction.allCases` 逐一对应）
    static var actionDocs: [ActionDoc] {
        WMAction.allCases.map { action in
            let cls = actionClass(action)
            return ActionDoc(
                name: action.rawValue,
                cls: cls,
                helpZH: action.help,
                helpEN: action.helpEN,
                browserOnly: action.browserOnly,
                terminalOnly: action.terminalOnly,
                workspace: action.workspaceIndex.map { $0 + 1 },
                hint: cls == .interactive ? interactiveHint(action) : nil)
        }
    }

    // MARK: 输出样例（`--help` 内嵌；`ControlWireTests` 会把它们重新 parse 一遍）

    static let stateSample = """
    {"ok":true,"seq":412,"data":{
      "schema":"quickterm.state/1",
      "app":{"version":"1.5.8","protocol":1,"workspaceCount":5},
      "screens":[{"index":1,"id":"3F2A9C…","title":"QuickTerm","key":true,"activeWorkspace":2,
        "visibleColumns":2,"fullscreen":false,
        "workspaces":[{"index":1,"layout":"scrolling","empty":true,"panes":[]},
                      {"index":2,"title":"dev","layout":"scrolling","empty":false,"panes":["t1","t2"],
                       "columns":[{"width":0.485,"panes":["t1"]},{"width":0.485,"panes":["t2"]}]},
                      {"index":3,"layout":"dwindle","empty":false,"panes":["t8","b3"],
                       "tree":{"split":"vertical","ratio":0.62,
                               "a":{"pane":"t8"},"b":{"pane":"b3"}}}]}],
      "panes":[{"handle":"t1","id":"9C1B4E…","kind":"terminal","role":"shell","screen":1,
                "workspace":2,"at":{"column":0,"row":0},
                "size":{"rect":[0,0,0.485,1],"points":[776,900],"cols":96,"rows":48,
                        "width":0.485,"share":1},
                "title":"nvim  ~/proj",
                "cwd":"/Users/danny/proj","focused":true,"busy":true,"float":false,"zoom":false},
               {"handle":"b3","id":"41EE07…","kind":"browser","screen":1,"workspace":2,
                "title":"<redacted>","url":"<redacted>","tabs":2,"focused":false}]}}
    """

    /// `pane resize` 的回声：diff 的路径与 `state` 里的 JSON 同形（`1:2.tree.a.ratio`）
    static let resizeSample = """
    {"ok":true,"seq":418,"resolved":{"screen":1,"workspace":3,"pane":"t8"},
     "data":{"command":"pane.resize","applied":true,"changed":true,"dryRun":false,
       "changes":[{"path":"1:3.tree.ratio","from":"0.620","to":"0.700"}],
       "pane":{"handle":"t8","size":{"rect":[0,0,1,0.7],"points":[1552,630],"cols":192,"rows":33,
                                     "split":"vertical","ratio":0.7}},
       "undo":"控制面：pane resize"}}
    """

    static let listSample = """
    {"ok":true,"seq":412,"data":{"panes":[
      {"handle":"t1","kind":"terminal","screen":1,"workspace":2,"title":"zsh","focused":true},
      {"handle":"b3","kind":"browser","screen":1,"workspace":2,"title":"<redacted>"}]}}
    """

    /// 变更类命令的统一信封（`--dry-run` 时 `applied:false` 且 `changes` 就是那份 diff）
    static let paneMutationSample = """
    {"ok":true,"seq":415,"resolved":{"screen":1,"workspace":2,"pane":"t9"},
     "data":{"command":"pane.new","applied":true,"changed":true,"dryRun":false,
       "changes":[{"path":"1:2","from":"2 panes","to":"3 panes"}],
       "pane":{"handle":"t9","id":"C40D…","kind":"terminal","role":"shell","screen":1,
               "workspace":2,"at":{"column":2,"row":0},"cwd":"/Users/danny/proj"},
       "focusPending":true,"undo":"控制面：pane new"}}
    """

    static let appGetSample = """
    {"ok":true,"seq":412,"data":{"settings":[
      {"key":"theme","value":"tokyo-night","choices":["tokyo-night","gruvbox","…"]},
      {"key":"gaps","value":"on","choices":["on","off"]},
      {"key":"visible-columns","value":"2","choices":["1","2","3","4","5","6"]}]}}
    """

    /// `spec dump` 打印的**就是这份文件本身**（不套响应信封）：
    /// `quickterm spec dump > w.json` 要能直接喂回 `spec apply -f w.json`
    static let specSample = """
    {"schema":"quickterm.workspace/1","layout":"scrolling","visibleColumns":3,
     "columns":[
       {"width":0.33,"panes":[{"kind":"terminal","cwd":"/Users/danny/proj"}]},
       {"width":0.33,"panes":[{"kind":"terminal","cwd":"/Users/danny/proj"},
                              {"kind":"terminal","cwd":"/Users/danny/proj/www"}]},
       {"width":0.33,"panes":[{"kind":"browser","url":"http://localhost:3000"}]}],
     "focus":{"column":0,"row":0}}
    """

    /// dwindle 形态（同一套词汇）——`spec` 组的帮助与 describe 都印它
    static let specTreeSample = """
    {"schema":"quickterm.workspace/1","layout":"dwindle",
     "tree":{"split":"horizontal","ratio":0.6,
             "a":{"pane":{"cwd":"~/proj"}},
             "b":{"split":"vertical","ratio":0.5,
                  "a":{"pane":{"cmd":"htop","hold":true}},
                  "b":{"pane":{"kind":"browser","url":"http://localhost:3000"}}}},
     "focus":{"path":"b.a"}}
    """

    static let specApplySample = """
    {"ok":true,"seq":418,"resolved":{"screen":1,"workspace":2,"pane":"t9"},
     "data":{"command":"spec.apply","applied":true,"changed":true,"dryRun":false,
       "changes":[{"path":"1:2.panes","from":"2 个","to":"4 个（新建 3，关掉 1，留用 1）"}],
       "spec":{"mode":"reuse","scope":"workspace","created":["t9","t10","b4"],
               "reused":["t3"],"closed":["t4"]}}}
    """

    /// `events poll` / `events follow` 的一批。`data.seq` 就是**下一次 `--since` 该给的值**
    /// （被 `--limit` 截断时它只走到最后一条真的送出去的事件，同时带 `truncated:true`）
    static let eventsSample = """
    {"ok":true,"seq":420,"data":{"schema":"quickterm.events/1","seq":420,"oldest":301,
     "events":[
      {"seq":418,"ts":"2026-09-10T09:12:03.221Z","type":"pane.opened","pane":"t9","paneID":"C40D…",
       "kind":"terminal","screen":1,"workspace":2,"cwd":"/Users/danny/proj"},
      {"seq":419,"ts":"2026-09-10T09:12:03.402Z","type":"focus.changed","pane":"t9","screen":1,"workspace":2},
      {"seq":420,"ts":"2026-09-10T09:12:07.118Z","type":"layout.changed","screen":1,"workspace":2,
       "layout":"dwindle"}]}}
    """

    static let sendTextSample = """
    {"ok":true,"seq":421,"resolved":{"screen":1,"workspace":2,"pane":"t7"},
     "data":{"command":"input.send-text","applied":true,"changed":true,"dryRun":false,
       "changes":[{"path":"1:2.t7","from":"(键盘输入)","to":"12 个字符 + 回车"}],
       "pane":{"handle":"t7","kind":"terminal","screen":1,"workspace":2}}}
    """

    /// `pane capture-text` 的回声。**text 只在这里出现一次**：不进日志、不进事件流
    static let captureTextSample = """
    {"ok":true,"seq":430,"resolved":{"screen":1,"workspace":2,"pane":"t7"},
     "data":{"command":"pane.capture-text","cols":96,"rows":24,"lines":3,"scrollback":0,
       "pane":{"handle":"t7","kind":"terminal","screen":1,"workspace":2},
       "text":"~/proj $ npm test\\n  12 passing\\n~/proj $ "}}
    """

    /// 浏览器标签类命令的回声：`pane.tabList` 就是下一条 `--tab` 该写的东西
    static let browserSample = """
    {"ok":true,"seq":432,"resolved":{"screen":1,"workspace":2,"pane":"b3"},
     "data":{"command":"browser.open","applied":true,"changed":true,"dryRun":false,
       "changes":[{"path":"1:2.b3.tabs","from":"2 个","to":"3 个"}],
       "pane":{"handle":"b3","kind":"browser","screen":1,"workspace":2,"tabs":3,
         "tabList":[{"index":1,"id":"8A1F…","active":false,"title":"QuickTerm","url":"https://…"},
                    {"index":2,"id":"C40D…","active":false,"title":"docs","url":"https://…"},
                    {"index":3,"id":"F17B…","active":true,"title":"","url":"http://localhost:3000",
                     "loading":true}]}}}
    """

    static let getSample = """
    {"ok":true,"seq":412,"resolved":{"screen":1,"workspace":2,"pane":"t7"},
     "data":{"pane":{"handle":"t7","id":"C40D…","kind":"terminal","role":"shell",
       "screen":1,"workspace":2,"at":{"column":2,"row":0},
       "size":{"rect":[0.97,0,0.485,1],"points":[776,900],"cols":96,"rows":48,
               "width":0.485,"share":1},
       "title":"npm run dev",
       "cwd":"/Users/danny/proj","focused":false,"busy":true,"float":false,"zoom":false}}}
    """
}

/// `app get` / `app set` 认的设置项。**枚举即清单**：命令表的 values、describe、
/// 服务端的 switch 全从这里来，不可能出现"帮助里有、实现里没有"的项
enum ControlAppSetting: String, Codable, CaseIterable {
    case theme
    case background
    case gaps
    case opacity
    case bar
    case visibleColumns = "visible-columns"

    var help: String {
        switch self {
        case .theme: "配色主题名（app get theme 的 choices 里列出全部）"
        case .background: "壁纸：名字、1 起序号或 none"
        case .gaps: "pane 间隙 on|off"
        case .opacity: "透明 / 磨砂 on|off"
        case .bar: "顶部状态条 on|off（按屏幕；-t 指定）"
        case .visibleColumns: "scrolling 每屏可见列数 1–6（按屏幕；-t 指定）"
        }
    }

    /// 作用在某一块屏幕上（其余是进程级）
    var isPerScreen: Bool { self == .bar || self == .visibleColumns }
}
