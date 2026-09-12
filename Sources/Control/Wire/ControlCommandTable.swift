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
            summary: "Read the whole session: a flat pane array plus a screen/workspace skeleton that refers to handles",
            cls: .read, idempotent: true, acceptsTarget: true, local: false,
            args: [
                ControlArgSpec("fields", .string,
                               help: "output only these pane fields (comma-separated, e.g. handle,cwd,title)"),
            ],
            examples: [
                "quickterm state",
                "quickterm state --json | jq '.data.panes[] | select(.focused)'",
                "quickterm state -t 2 --fields handle,title,cwd",
            ],
            outputSample: stateSample),
        ControlCommandSpec(
            "list",
            summary: "List screens / workspaces / panes",
            cls: .read, idempotent: true, acceptsTarget: true, local: false,
            args: [
                ControlArgSpec("what", .enumeration, help: "what to list", required: true,
                               positional: true, values: ["screens", "workspaces", "panes"]),
                ControlArgSpec("fields", .string, help: "output only these fields (comma-separated)"),
            ],
            examples: [
                "quickterm list panes",
                "quickterm list workspaces -t 2",
                "quickterm list panes --json | jq -r '.data.panes[].handle'",
            ],
            outputSample: listSample),
        ControlCommandSpec(
            "get",
            summary: "Read the full record of a single pane",
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
            summary: "Run a WM action (the keybinding-parity passthrough; all \(WMAction.allCases.count) of them)",
            cls: .mutate, idempotent: false, acceptsTarget: true, local: false,
            args: [
                ControlArgSpec("name", .string, help: "action name (kebab-case; see --list)",
                               required: true, positional: true),
                ControlArgSpec("list", .bool, help: "list every action with its safety class instead of running one"),
                ControlArgSpec("precise", .bool, help: "fine step (same as holding Shift for resize-*)"),
            ],
            examples: [
                "quickterm action new-terminal",
                "quickterm action goto-workspace-3 -t 2",
                "quickterm action --list --json",
            ],
            outputSample: nil),
        ControlCommandSpec(
            "describe",
            summary: "Dump the whole control plane as a machine-readable schema (one read per agent session is enough)",
            cls: .read, idempotent: true, acceptsTarget: false, local: false,
            args: [],
            examples: [
                "quickterm describe --json",
                "quickterm describe --json | jq '.commands[].name'",
            ],
            outputSample: nil),
        ControlCommandSpec(
            "version",
            summary: "Print the CLI and running QuickTerm versions, the protocol version and the socket path",
            cls: .read, idempotent: true, acceptsTarget: false, local: false,
            args: [],
            examples: ["quickterm version", "quickterm version --json"],
            outputSample: nil),
        ControlCommandSpec(
            "install-cli",
            summary: "Symlink quickterm (and optionally a qt alias) into PATH — never asks for an admin password",
            cls: .read, idempotent: true, acceptsTarget: false, local: true,
            args: [
                ControlArgSpec("alias", .string, help: "also create a short alias (usually qt)"),
                ControlArgSpec("dir", .string, help: "install directory (default /usr/local/bin, or ~/.local/bin when that is not writable)"),
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
            summary: "Create a pane (terminal / browser / file manager) with an optional cwd, command, environment and placement",
            cls: .mutate, idempotent: false, acceptsTarget: true,
            args: [
                ControlArgSpec("kind", .enumeration, help: "pane kind",
                               values: ["terminal", "browser", "file-manager"], defaultValue: "terminal"),
                ControlArgSpec("cwd", .string, help: "starting directory (~ is expanded; inherited from the anchor pane by default)"),
                ControlArgSpec("require-cwd", .bool,
                               help: "**fail** when --cwd cannot be used (by default the pane opens anyway and the reply carries a cwd_denied warning): "
                                   + "that is what happens for a protected directory (~/Desktop ~/Documents ~/Downloads) with no privacy permission granted"),
                ControlArgSpec("cmd", .string, help: "command to run (the engine sets wait-after-command; by default the pane closes when it exits)"),
                ControlArgSpec("hold", .bool, help: "do **not** close the pane when the command exits (it closes by default)"),
                ControlArgSpec("env", .string, help: "extra environment variable KEY=VALUE", repeatable: true),
                ControlArgSpec("url", .string, help: "URL for the browser pane to open (--kind browser)"),
                ControlArgSpec("at", .string, help: "anchor pane to place it next to (target syntax; defaults to the focused pane)"),
                ControlArgSpec("where", .enumeration, help: "side of the anchor to land on",
                               values: ["right", "left", "up", "down", "stack"], defaultValue: "right"),
            ],
            examples: [
                "quickterm pane new --cwd ~/proj --cmd 'npm run dev' --at t1 --where right",
                "quickterm pane new --kind browser --url http://localhost:3000 --at t1 --where down",
                "quickterm pane new --kind file-manager --cwd ~/proj",
                "quickterm pane new --cmd 'tail -f log' --hold --env RUST_LOG=debug",
                "quickterm pane new --cwd ~/Downloads --require-cwd   # exit 5 if the directory is unusable, never land elsewhere silently",
            ],
            outputSample: paneMutationSample),
        ControlCommandSpec(
            group: "pane", "close",
            summary: "Close a pane, killing the processes inside it (destructive; confirmed once per caller)",
            cls: .destructive, idempotent: false, acceptsTarget: true,
            args: [
                ControlArgSpec("force", .bool, help: "skip QuickTerm's own \"a process is still running\" prompt"),
            ],
            examples: [
                "quickterm pane close -t t7",
                "quickterm pane close -t b3 --force",
            ],
            outputSample: nil),
        ControlCommandSpec(
            group: "pane", "focus",
            summary: "Give keyboard focus to a pane (idempotent: does nothing when it is already focused)",
            cls: .mutate, idempotent: true, acceptsTarget: true,
            args: [
                ControlArgSpec("where", .enumeration, help: "direction relative to the current focus (omit it and use -t)",
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
            summary: "Move a pane to another workspace / screen, optionally at a chosen spot (does not follow by default)",
            cls: .mutate, idempotent: false, acceptsTarget: true,
            args: [
                ControlArgSpec("to", .string, help: "destination screen:workspace (e.g. 2:4, :3, @next)", required: true),
                ControlArgSpec("at", .string, help: "anchor pane inside the destination workspace"),
                ControlArgSpec("where", .enumeration, help: "side of the anchor to land on",
                               values: ["right", "left", "up", "down", "stack"], defaultValue: "right"),
                ControlArgSpec("follow", .bool, help: "switch to the destination workspace / screen as well (does not follow by default)"),
                ControlArgSpec("no-follow", .bool, help: "explicitly do not follow (the default)"),
            ],
            examples: [
                "quickterm pane move -t t7 --to :4",
                "quickterm pane move -t t7 --to 2:1 --at t9 --where down --follow",
            ],
            outputSample: nil),
        ControlCommandSpec(
            group: "pane", "swap",
            summary: "Swap two panes (positions are absolute: swapping them back takes a second call)",
            cls: .mutate, idempotent: false, acceptsTarget: true,
            args: [
                ControlArgSpec("with", .string, help: "the pane to swap with (target syntax)", required: true),
            ],
            examples: ["quickterm pane swap -t t7 --with t2"],
            outputSample: nil),
        ControlCommandSpec(
            group: "pane", "set",
            summary: "Absolute setters: zoom / float / column width (the same command twice lands the same result)",
            cls: .mutate, idempotent: true, acceptsTarget: true,
            args: [
                ControlArgSpec("zoom", .enumeration, help: "whether this pane fills the content area", values: ["on", "off"]),
                ControlArgSpec("float", .enumeration, help: "whether this pane floats", values: ["on", "off"]),
                ControlArgSpec("width", .double, help: "scrolling column width factor (0.25–0.90, absolute)"),
                ControlArgSpec("ratio", .double,
                               help: "ratio of the nearest parent split in dwindle (\(SpecLimits.ratioRange.lowerBound)–\(SpecLimits.ratioRange.upperBound), absolute; out of range is an error)"),
                ControlArgSpec("title", .string,
                               help: "title of a terminal pane (= the right-click \"Change Terminal Title\" item); "
                                   + "an empty string \"\" drops the override and hands the title back to the shell. "
                                   + "Once set, -t 'title:~<regex>' addresses this pane"),
            ],
            examples: [
                "quickterm pane set -t t7 --zoom on",
                "quickterm pane set -t t7 --float off --width 0.33",
                "quickterm pane set -t t7 --title 'build · web'   # -t 'title:~build' finds it afterwards",
                "quickterm pane set -t t7 --title ''              # hand the title back to the shell",
            ],
            outputSample: nil),
        ControlCommandSpec(
            group: "pane", "resize",
            summary: "Resize, the way dragging a divider or a column edge and ⌘⌃arrows do: "
                + "by ratio, by points, by column width factor; at the boundary it is a no-op (exit 7)",
            cls: .mutate, idempotent: false, acceptsTarget: true,
            args: [
                ControlArgSpec("width", .string, help: "scrolling column width factor: a delta (+0.05) or an absolute value (0.33)"),
                ControlArgSpec("ratio", .string, help: "dwindle split ratio: a delta (+0.1) or an absolute value (0.5)"),
                ControlArgSpec("points", .string,
                               help: "work in **points** instead: +120 moves this divider 120pt right/down, 120 sets the a side to 120pt"
                                   + " (in scrolling this is the column width in points)"),
                ControlArgSpec("dir", .enumeration,
                               help: "resize by direction, the same as ⌘⌃arrows or a ⌘right-drag: the nearest divider on that axis, "
                                   + "stepping by --points (default 100); mutually exclusive with --split",
                               values: ["left", "right", "up", "down"]),
                ControlArgSpec("split", .string,
                               help: "dwindle: name the divider to move (a tree path of a/b joined by dots; the root one is root); "
                                   + "omit it for this pane's own parent split; mutually exclusive with --dir"),
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
            summary: "Read **the text currently on screen** in a terminal pane, optionally with some scrollback — "
                + "off by default, and confirmed once per calling process",
            cls: .sensitive, idempotent: true, acceptsTarget: true, readOnlyEffect: true,
            args: [
                ControlArgSpec("scrollback", .int,
                               help: "how many scrollback lines above the viewport to include (0–\(ControlCaptureLimits.maxScrollback); the default 0 means the viewport only)",
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
            summary: "Open a new tab in a browser pane and load a URL",
            cls: .mutate, idempotent: false, acceptsTarget: true,
            args: [
                ControlArgSpec("url", .string, help: "URL to open (omit it for the browser home page)"),
                ControlArgSpec("activate", .enumeration,
                               help: "whether the new tab becomes the active tab right away", values: ["on", "off"],
                               defaultValue: "on"),
            ],
            examples: [
                "quickterm browser open -t b3 --url http://localhost:3000",
                "quickterm browser open -t b3 --url https://example.com --activate off",
            ],
            outputSample: browserSample),
        ControlCommandSpec(
            group: "browser", "goto",
            summary: "Navigate a tab to a URL (absolute setter: does nothing when it is already there)",
            cls: .mutate, idempotent: true, acceptsTarget: true,
            args: [
                ControlArgSpec("url", .string, help: "URL to open", required: true),
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
            summary: "Reload a tab (`--hard` bypasses the cache as well)",
            cls: .mutate, idempotent: true, acceptsTarget: true,
            args: [
                ControlArgSpec("tab", .string, help: ControlTabRef.help, defaultValue: "@active"),
                ControlArgSpec("hard", .bool, help: "bypass the cache (same as ⌘⇧R)"),
            ],
            examples: [
                "quickterm browser reload -t b3",
                "quickterm browser reload -t b3 --tab 1 --hard",
            ],
            outputSample: nil),
        ControlCommandSpec(
            group: "browser", "close",
            summary: "Close a tab (destructive). **Closing the last tab closes the whole pane** — exactly what ⌘W does",
            cls: .destructive, idempotent: false, acceptsTarget: true,
            args: [
                ControlArgSpec("tab", .string, help: ControlTabRef.help, defaultValue: "@active"),
                ControlArgSpec("others", .bool,
                               help: "the other way round: close every tab **except** the one --tab names (this alone never closes the pane)"),
                ControlArgSpec("force", .bool,
                               help: "only means anything when closing the last tab would close the pane: "
                                   + "skip QuickTerm's \"a process is still running\" prompt"),
            ],
            examples: [
                "quickterm browser close -t b3                 # close the active tab",
                "quickterm browser close -t b3 --tab 1         # close the first tab",
                "quickterm browser close -t b3 --others        # keep only the active one",
            ],
            outputSample: nil),

        ControlCommandSpec(
            group: "workspace", "goto",
            summary: "Switch to a workspace (idempotent)",
            cls: .mutate, idempotent: true, acceptsTarget: true,
            args: [
                ControlArgSpec("index", .int, help: "workspace index (1-based)", required: true, positional: true),
            ],
            examples: ["quickterm workspace goto 3", "quickterm workspace goto 1 -t 2"],
            outputSample: nil),
        ControlCommandSpec(
            group: "workspace", "set-layout",
            summary: "Set a workspace to scrolling / dwindle — **it works on inactive workspaces too**, which toggle-layout cannot do",
            cls: .mutate, idempotent: true, acceptsTarget: true,
            args: [
                ControlArgSpec("layout", .enumeration, help: "layout", required: true, positional: true,
                               values: ["scrolling", "dwindle"]),
            ],
            examples: [
                "quickterm workspace set-layout dwindle -t :4",
                "quickterm workspace set-layout scrolling -t 2:1",
            ],
            outputSample: nil),
        ControlCommandSpec(
            group: "workspace", "set",
            summary: "Absolute setter: name a workspace (the same command twice lands the same result)",
            cls: .mutate, idempotent: true, acceptsTarget: true,
            args: [
                ControlArgSpec("title", .string,
                               help: "name of the workspace (= renaming its pill from the right-click menu); an empty string \"\" clears it and the pill falls back to the index. "
                                   + "The name belongs to the **slot**, not to the panes inside it: workspace clear and closing the last pane "
                                   + "both leave it alone. The only things that change it are this command, a right-click rename, "
                                   + "and a spec that **carries a title** (the one `spec dump` writes does)"),
            ],
            examples: [
                "quickterm workspace set --title dev",
                "quickterm workspace set -t 2:4 --title 'web · logs'",
                "quickterm workspace set -t :4 --title ''            # clear the name",
            ],
            outputSample: nil),
        ControlCommandSpec(
            group: "workspace", "equalize",
            summary: "Equalize every column width and split ratio in a workspace (idempotent)",
            cls: .mutate, idempotent: true, acceptsTarget: true,
            args: [],
            examples: ["quickterm workspace equalize -t :2"],
            outputSample: nil),
        ControlCommandSpec(
            group: "workspace", "clear",
            summary: "Close every pane in a workspace (destructive)",
            cls: .destructive, idempotent: true, acceptsTarget: true,
            args: [
                ControlArgSpec("force", .bool,
                               help: "no longer does anything: the control plane already confirmed once for the whole workspace (same as screen close)"),
            ],
            examples: ["quickterm workspace clear -t :5"],
            outputSample: nil),
        ControlCommandSpec(
            group: "workspace", "count",
            summary: "Set how many workspaces there are (1–10): rewrites workspaces in config.toml, which the config watcher applies",
            cls: .mutate, idempotent: true, acceptsTarget: false,
            args: [
                ControlArgSpec("n", .int, help: "how many (1–10)", required: true, positional: true),
            ],
            examples: ["quickterm workspace count 8"],
            outputSample: nil),

        ControlCommandSpec(
            group: "screen", "new",
            summary: "Create a screen (a window), optionally on a chosen display",
            cls: .mutate, idempotent: false, acceptsTarget: false,
            args: [
                ControlArgSpec("display", .string, help: "display: uuid:<…> / name:<…> / 1-based index"),
                ControlArgSpec("inherit-cwd-from", .string, help: "the new screen's first terminal inherits this pane's directory"),
            ],
            examples: [
                "quickterm screen new",
                "quickterm screen new --display 'name:Studio Display' --inherit-cwd-from t1",
            ],
            outputSample: nil),
        ControlCommandSpec(
            group: "screen", "close",
            summary: "Close a screen together with every pane on it (destructive)",
            cls: .destructive, idempotent: false, acceptsTarget: true,
            args: [
                ControlArgSpec("force", .bool, help: "skip QuickTerm's own close-screen prompt"),
            ],
            examples: ["quickterm screen close -t 2 --force"],
            outputSample: nil),
        ControlCommandSpec(
            group: "screen", "move",
            summary: "Move a screen to another display (idempotent: does nothing when it is already there)",
            cls: .mutate, idempotent: true, acceptsTarget: true,
            args: [
                ControlArgSpec("display", .string, help: "display: uuid:<…> / name:<…> / 1-based index", required: true),
            ],
            examples: ["quickterm screen move -t 2 --display 1"],
            outputSample: nil),
        ControlCommandSpec(
            group: "screen", "focus",
            summary: "Bring a screen's window to the front and make it key (idempotent)",
            cls: .mutate, idempotent: true, acceptsTarget: true,
            args: [],
            examples: ["quickterm screen focus -t 2"],
            outputSample: nil),
        ControlCommandSpec(
            group: "screen", "set",
            summary: "Absolute setters: fullscreen / show on all desktops / columns visible per screen",
            cls: .mutate, idempotent: true, acceptsTarget: true,
            args: [
                ControlArgSpec("fullscreen", .enumeration, help: "non-native fullscreen", values: ["on", "off"]),
                ControlArgSpec("join-all-spaces", .enumeration, help: "show on all desktops", values: ["on", "off"]),
                ControlArgSpec("visible-columns", .int, help: "columns visible per screen in scrolling (1–6)"),
            ],
            examples: [
                "quickterm screen set -t 1 --fullscreen off --visible-columns 3",
                "quickterm screen set -t 2 --join-all-spaces on",
            ],
            outputSample: nil),

        ControlCommandSpec(
            group: "app", "get",
            summary: "Read process-level settings (theme / background / gaps / opacity / status bar / visible columns / control plane)",
            cls: .read, idempotent: true, acceptsTarget: true,
            args: [
                ControlArgSpec("key", .string, help: "read a single setting (omit it for all of them)", positional: true),
            ],
            examples: ["quickterm app get", "quickterm app get theme"],
            outputSample: appGetSample),
        ControlCommandSpec(
            group: "app", "set",
            summary: "Process-level settings as absolute setters (the socket-side route around the 6 modal-panel actions)",
            cls: .mutate, idempotent: true, acceptsTarget: true,
            args: [
                ControlArgSpec("key", .enumeration, help: "setting", required: true, positional: true,
                               values: ControlAppSetting.allCases.map(\.rawValue)),
                ControlArgSpec("value", .string, help: "value (see choices in app get)", required: true, positional: true),
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
            summary: "Dump a workspace, a screen or the whole session as \(SpecSchema.workspace) JSON",
            cls: .read, idempotent: true, acceptsTarget: true,
            args: [
                ControlArgSpec("all", .bool, help: "the whole session (\(SpecSchema.session))"),
                ControlArgSpec("relocatable", .bool, help: "write paths under home as ~/… (so the spec works on another machine)"),
                ControlArgSpec("include-ids", .bool,
                               help: "include id / handle / title (for diffs and --reuse; other modes ignore id, and it never joins the fixed-point comparison)"),
            ],
            examples: [
                "quickterm spec dump > dev.json                # the current workspace",
                "quickterm spec dump -t 1:2 > dev.json",
                "quickterm spec dump -t 1 --relocatable > screen.json   # a -t naming only a screen = that whole screen",
                "quickterm spec dump --all > session.json",
            ],
            outputSample: specSample),
        ControlCommandSpec(
            group: "spec", "validate",
            summary: "Validate a spec and nothing else: known keys, value ranges, whether the workspace index can take it (changes nothing)",
            cls: .read, idempotent: true, acceptsTarget: true, readsFile: true,
            args: [
                ControlArgSpec("file", .string, help: "spec file (- or omitted reads stdin)"),
                ControlArgSpec("spec", .string, help: "the spec JSON body inline (instead of -f)"),
            ],
            examples: [
                "quickterm spec validate -f dev.json",
                "quickterm spec dump | quickterm spec validate",
                "quickterm spec validate --spec '{\"columns\":[{},{}]}'",
            ],
            outputSample: nil),
        ControlCommandSpec(
            group: "spec", "apply",
            summary: "Apply a spec to the target; --replace is destructive and confirms first, --dry-run only reports the diff",
            cls: .destructive, idempotent: true, acceptsTarget: true, readsFile: true,
            args: [
                ControlArgSpec("file", .string, help: "spec file (- or omitted reads stdin)"),
                ControlArgSpec("spec", .string, help: "the spec JSON body inline (instead of -f)"),
                ControlArgSpec("into-empty", .bool,
                               help: "the default: fill an empty workspace only; a non-empty one is refused (exit code 4), so nothing can be destroyed"),
                ControlArgSpec("replace", .bool,
                               help: "overwrite: close every existing pane (**destructive**, confirms first; a no-op when the spec already matches exactly)"),
                ControlArgSpec("reuse", .bool,
                               help: "keep every pane that matches right where it is, so a running dev server is not restarted, and close / create the rest"),
                ControlArgSpec("require-cwd", .bool,
                               help: "**fail** when a directory in the spec cannot be used (by default it is applied anyway and the reply carries a cwd_denied warning): "
                                   + "that is what happens for a protected directory with no privacy permission granted"),
            ],
            examples: [
                "quickterm spec apply -f dev.json --dry-run           # look at the diff first, then decide",
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
            summary: "Long poll: return as soon as the events missed since --since are in hand (the shape an agent wants)",
            cls: .read, idempotent: true, acceptsTarget: false,
            args: [
                ControlArgSpec("since", .int,
                               help: "the seq you last received (omit it for the current seq, i.e. wait only for what happens next)"),
                ControlArgSpec("timeout", .string, help: "how long to wait when nothing happens (5s / 500ms / 2m)",
                               defaultValue: "5s"),
                ControlArgSpec("limit", .int,
                               help: "how many events one reply may carry (when it truncates, the seq returned only reaches the last event actually sent "
                                   + "and truncated=true comes with it: poll again with that seq right away and nothing is lost)",
                               defaultValue: String(ControlEventLimits.maxBatch)),
                ControlArgSpec("types", .string,
                               help: "only these types (comma-separated, e.g. pane.opened,focus.changed)"),
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
            summary: "NDJSON stream: the connection stays open and events are pushed one at a time (for humans and shell scripts; Ctrl-C ends it)",
            cls: .read, idempotent: true, acceptsTarget: false,
            args: [
                ControlArgSpec("since", .int, help: "replay what already happened after this seq first (omit it to push only new events)"),
                ControlArgSpec("limit", .int,
                               help: "how many events one batch may carry (a truncated batch loses nothing: the next one carries on)",
                               defaultValue: String(ControlEventLimits.maxBatch)),
                ControlArgSpec("types", .string, help: "only these types (comma-separated)"),
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
            summary: "Send text into a terminal pane as keyboard input — **this is typing into that shell** (off by default)",
            cls: .sensitive, idempotent: false, acceptsTarget: true,
            args: [
                ControlArgSpec("text", .string, help: "the text to send (control characters are always refused)",
                               required: true, positional: true),
                ControlArgSpec("enter", .bool,
                               help: "send a Return after the text — **the only way to make it run** (not sent by default)"),
            ],
            examples: [
                "quickterm input send-text 'git status' -t @self",
                "quickterm input send-text 'git status' -t @self --enter",
                "quickterm input send-text 'npm run dev' -t t7 --enter   # another pane: confirmed every single time",
            ],
            outputSample: sendTextSample),

        // MARK: —— Phase 5：MCP（stdio）——
        // 工具表**从这张命令表生成**（`MCPToolMap`）。手写一份工具描述两个版本之内必然漂移，
        // 而漂移的代价是 agent 拿着过期 schema 得到自己解释不了的错误。

        ControlCommandSpec(
            "mcp",
            summary: "Run an MCP server over stdio (its tool list is generated from this command table; mount it in Claude Code / Codex)",
            cls: .read, idempotent: true, acceptsTarget: false, local: true,
            args: [
                ControlArgSpec("list-tools", .bool, help: "print the tool list as JSON and exit instead of entering the stdio loop"),
            ],
            examples: [
                "quickterm mcp                       # the MCP host launches this; do not type it in a terminal",
                "quickterm mcp --list-tools          # see which tools get exposed and how they are annotated",
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
        ControlArgSpec("target", .string, help: "target screen:workspace.pane (-t)"),
        ControlArgSpec("json", .bool, help: "force JSON output (it is already JSON when stdout is not a TTY)"),
        ControlArgSpec("plain", .bool, help: "force human-readable output"),
        ControlArgSpec("socket", .string, help: "socket path to use (defaults to QUICKTERM_SOCKET)"),
        ControlArgSpec("help", .bool, help: "help (every subcommand's help ends with EXAMPLES)"),
        ControlArgSpec("dry-run", .bool, help: "report what would change and change nothing (mutating commands only)"),
        ControlArgSpec("fail-if-noop", .bool, help: "exit 7 when already in the requested state instead of succeeding silently"),
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
        case .themePicker: "The theme picker is driven by the keyboard. Use app set theme instead, or write theme in ~/.config/quickterm/config.toml."
        case .backgroundMenu: "The background picker is driven by the keyboard. Use app set background instead."
        case .keybindingHelp, .mainMenu: "This is an overlay panel for humans. The machine-readable list is in quickterm describe --json."
        case .openSettings: "It launches an external editor. Edit ~/.config/quickterm/config.toml directly instead."
        case .webExtensions: "It pops up an NSMenu and holds the main thread. Manage extensions inside QuickTerm itself."
        default: "This action needs keyboard interaction and cannot be run over the socket."
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
       "undo":"Control plane: pane resize"}}
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
       "focusPending":true,"undo":"Control plane: pane new"}}
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
       "changes":[{"path":"1:2.panes","from":"2 panes","to":"4 panes (created 3, closed 1, reused 1)"}],
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
       "changes":[{"path":"1:2.t7","from":"(keyboard input)","to":"12 characters + Return"}],
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
       "changes":[{"path":"1:2.b3.tabs","from":"2 tabs","to":"3 tabs"}],
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
        case .theme: "color theme name (app get theme lists every choice)"
        case .background: "wallpaper: a name, a 1-based index, or none"
        case .gaps: "gaps between panes on|off"
        case .opacity: "transparency / blur on|off"
        case .bar: "top status bar on|off (per screen; name it with -t)"
        case .visibleColumns: "columns visible per screen in scrolling 1–6 (per screen; name it with -t)"
        }
    }

    /// 作用在某一块屏幕上（其余是进程级）
    var isPerScreen: Bool { self == .bar || self == .visibleColumns }
}
