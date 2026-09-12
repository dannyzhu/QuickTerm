import Foundation

/// `quickterm describe --json`：整个控制面一次性吐成机器 schema。
/// 这是"把控制方法通过命令帮助信息提供给大模型"的正解——agent 会话开始时读一次，之后不必再读 `--help`。
/// **全部字段都从 `ControlCommandTable` / `WMAction` 生成**，没有第二份手写描述。
struct ControlDescribeDocument: Codable, Equatable {
    var schema = "quickterm.describe/1"
    var protocolVersion: Int
    var cliVersion: String
    var appVersion: String?
    var appRunning: Bool
    var socket: String?
    var mode: String?
    var phase: Int
    var targetGrammar: TargetGrammar
    var commands: [ControlCommandSpec]
    var globalFlags: [ControlArgSpec]
    var classes: [ClassDoc]
    var exitCodes: [ExitCodeDoc]
    var errorCodes: [ErrorCodeDoc]
    var actions: [ControlCommandTable.ActionDoc]
    /// `app get/set` 认的设置项（枚举即清单）
    var appSettings: [AppSettingDoc]
    /// `quickterm.workspace/1` 的字段表（Phase 3：agent 靠它一次读懂 spec 怎么写）
    var specSchema: SpecSchemaDoc
    /// 事件类型（Phase 4）。`events poll --since <seq>` 是 agent 该用的那一种
    var events: [EventDoc]
    /// MCP 工具表（Phase 5）——**从命令表生成**，每个工具背后是哪几条命令一并写明
    var mcpTools: [MCPTool.Doc]
    /// 名词分组（`pane` / `workspace` / `screen` / `app`）→ 动词
    var groups: [GroupDoc]
    var envVars: [EnvDoc]
    var notes: [String]

    struct TargetGrammar: Codable, Equatable {
        var syntax = "screen:workspace.pane"
        var lines: [String]
        var screen: [String]
        var workspace: [String]
        var pane: [String]
        var predicates: [String]
    }

    struct ClassDoc: Codable, Equatable {
        var name: String
        var policy: String
    }

    struct ExitCodeDoc: Codable, Equatable {
        var code: Int32
        var name: String
        var summary: String
    }

    struct ErrorCodeDoc: Codable, Equatable {
        var code: String
        var exit: Int32
        var summary: String
    }

    struct AppSettingDoc: Codable, Equatable {
        var key: String
        var scope: String
        var help: String
    }

    /// 公开 schema 的字段表。**刻意不是内部存档 v5 的形状**：两者由
    /// `Sources/Control/Spec/SpecCodec.swift` 的投影对连起来，各自独立演进
    struct SpecSchemaDoc: Codable, Equatable {
        var workspace: String
        var screen: String
        var session: String
        var fields: [FieldDoc]
        /// 两种布局形态各一份完整样例（都是合法 JSON，`ControlSpecTests` 会重新解析它们）
        var examples: [String]
        var minimal: String
        var notes: [String]

        struct FieldDoc: Codable, Equatable {
            var path: String
            var type: String
            var defaultValue: String?
            var help: String
        }
    }

    struct EventDoc: Codable, Equatable {
        var type: String
        var summary: String
    }

    struct GroupDoc: Codable, Equatable {
        var name: String
        var verbs: [String]
    }

    struct EnvDoc: Codable, Equatable {
        var name: String
        var summary: String
    }

    /// 破坏性命令的现行策略。**跟着实际 mode 走**：写死一句"会确认"的话，
    /// 在 readonly / off 下就成了假话，而 agent 是拿 describe 当合同读的
    static func destructivePolicy(mode: String?) -> String {
        switch mode {
        case "off": "The control plane is off ([control] mode = \"off\"): nothing is executed."
        case "readonly": "Read-only mode ([control] mode = \"readonly\"): always refused, never prompts."
        default: "Confirmed once inside QuickTerm per (calling process pid, command class); the prompt "
            + "names the exact pane it will act on; a timeout → exit code 4."
        }
    }

    /// 敏感命令（`input send-text`）的现行策略。同样**跟着实际 mode 与开关走**
    static func sensitivePolicy(mode: String?) -> String {
        switch mode {
        case "off": "The control plane is off ([control] mode = \"off\"): nothing is executed."
        case "readonly": "Read-only mode ([control] mode = \"readonly\"): always refused."
        default: "**One switch per command, both off by default** (exit code 5, code=denied): "
            + "input send-text needs `[control] send-text = true`, pane capture-text needs "
            + "`[control] capture-text = true`. "
            + "Turning one on never turns on the other, and the confirmation cache is per command too."
            + "\n· send-text: once it is on, only writing to the caller's own pane skips the prompt — that tty "
            + "was already its own. What decides that is whether the per-pane, verifiable QUICKTERM_PANE_TOKEN "
            + "matches the pane -t actually resolved to; the self-reported QUICKTERM_PANE plays no part (it "
            + "cannot be verified). Writing to **any** other pane prompts every single time, the prompt shows "
            + "the exact text to be typed and whether a newline follows, and that approval is never cached. "
            + "Control characters are always refused; a newline needs an explicit --enter."
            + "\n· capture-text: there is no \"read your own pane\" exemption (a process cannot read its own "
            + "tty's scrollback anyway). The caller must also carry this launch's QUICKTERM_TOKEN (the same one "
            + "that un-redacts browser URLs), and then the user confirms once per calling process. It changes "
            + "nothing, so it **takes no --dry-run / --fail-if-noop** — elsewhere those flags also mean \"no "
            + "prompt\", which here would be a back door around the gate to the whole content. The captured "
            + "text appears once, in that one response: never in the activity log, the event stream or the "
            + "unified log."
        }
    }

    /// `quickterm.workspace/1` 的字段表（`spec --help` 与 describe 同一出处）
    static var specSchema: SpecSchemaDoc {
        typealias Field = SpecSchemaDoc.FieldDoc
        return SpecSchemaDoc(
            workspace: SpecSchema.workspace,
            screen: SpecSchema.screen,
            session: SpecSchema.session,
            fields: [
                Field(path: "layout", type: "scrolling | dwindle", defaultValue: "scrolling",
                      help: "Taken as dwindle when `tree` is present and `layout` is not"),
                Field(path: "title", type: "string ≤200", defaultValue: "unchanged",
                      help: "The workspace's name (the name travels with the slot); an empty string clears it, "
                          + "omitting the key leaves it alone"),
                Field(path: "visibleColumns", type: "int \(SpecLimits.visibleColumns.lowerBound)–\(SpecLimits.visibleColumns.upperBound)",
                      defaultValue: "unchanged",
                      help: "scrolling: columns visible per screen (**applies to the whole screen**)"),
                Field(path: "columns[]", type: "array", defaultValue: "[]",
                      help: "scrolling: the columns, each a top-to-bottom stack of panes"),
                Field(path: "columns[].width", type: "double \(SpecLimits.widthRange.lowerBound)–\(SpecLimits.widthRange.upperBound)",
                      defaultValue: "derived from the visible column count",
                      help: "Column width factor; out of range is an error, never silently clamped"),
                Field(path: "columns[].panes[]", type: "pane[]", defaultValue: "[{}]", help: "The panes in this column"),
                Field(path: "tree", type: "{pane} | {split,ratio,a,b}", defaultValue: "—",
                      help: "dwindle: the split tree. split=horizontal (a left, b right) / vertical (a top, b bottom)"),
                Field(path: "tree.ratio", type: "double \(SpecLimits.ratioRange.lowerBound)–\(SpecLimits.ratioRange.upperBound)",
                      defaultValue: "0.5", help: "Split ratio"),
                Field(path: "pane.kind", type: "terminal | browser | file-manager", defaultValue: "terminal",
                      help: "What kind of pane it is"),
                Field(path: "pane.cwd", type: "string (~ expanded)", defaultValue: "inherited from the anchor pane",
                      help: "Starting directory; apply checks that it really exists first"),
                Field(path: "pane.cmd", type: "string", defaultValue: "—",
                      help: "The command to run. **Write-only**: dump never gives it back"),
                Field(path: "pane.hold", type: "bool", defaultValue: "false", help: "Keep the pane open after the command exits"),
                Field(path: "pane.env", type: "{KEY: VALUE}", defaultValue: "{}", help: "Extra environment variables (write-only)"),
                Field(path: "pane.url", type: "string", defaultValue: "browser home page",
                      help: "kind=browser: the active tab's URL"),
                Field(path: "pane.tabs[]", type: "string[]", defaultValue: "—",
                      help: "kind=browser: every tab, in tab order"),
                Field(path: "zoom", type: "{column,row} | {path} | {floating}", defaultValue: "null",
                      help: "Which slot fills the content area"),
                Field(path: "focus", type: "{column,row} | {path} | {floating}", defaultValue: "first pane",
                      help: "Which slot takes focus"),
                Field(path: "floating[]", type: "[{rect,pane}]", defaultValue: "[]",
                      help: "The floating layer; rect = fractions of the content area [x,y,w,h], "
                          + "omitted means centered at the default size"),
            ],
            examples: [ControlCommandTable.specSample, ControlCommandTable.specTreeSample],
            minimal: "{\"columns\":[{\"panes\":[{}]},{\"panes\":[{},{}]}]}",
            notes: [
                "Every field may be omitted; what is left out falls back to the default above — "
                    + "a legal spec fits in two lines.",
                "An unrecognized key is always an error (a misspelled `colums` is never silently ignored); "
                    + "a number out of range is an error that names the range, never silently clamped.",
                "spec apply has three modes: --into-empty (the default: a non-empty target exits 4, "
                    + "so it can destroy nothing), --replace (destructive, confirmed first), "
                    + "--reuse (panes that match are kept).",
                "cmd / env / hold are write-only: applying again never re-runs a command that is already "
                    + "running (--replace with an identical spec is a no-op).",
                "quickterm.screen/1 = {display, frame, fullscreen, joinAllSpaces, visibleColumns, "
                    + "activeWorkspace, workspaces[]}; quickterm.session/1 = {screens[], keyScreen}; "
                    + "both reuse the workspace vocabulary verbatim. apply never moves windows "
                    + "(display / frame are echoed back by dump only).",
            ])
    }

    /// 唯一构造入口。`appVersion == nil` = 应用没在运行，CLI 拿本地命令表兜底
    static func make(cliVersion: String, appVersion: String?, socket: String?, mode: String?) -> ControlDescribeDocument {
        ControlDescribeDocument(
            protocolVersion: ControlProtocol.version,
            cliVersion: cliVersion,
            appVersion: appVersion,
            appRunning: appVersion != nil,
            socket: socket,
            mode: mode,
            phase: 5,
            targetGrammar: TargetGrammar(
                lines: ControlTarget.grammarLines,
                screen: ["<1-based index>", "#<uuid>:", "@current", "@primary"],
                workspace: ["<1-based index>", "@active", "@next", "@prev"],
                pane: ["t<N>", "b<N>", "#<uuid, or a prefix of 4+ chars>", "@focused", "@self",
                       "@left", "@right", "@up", "@down", "@next", "@prev"],
                predicates: ["title:~<regex>", "cwd:<prefix>", "kind:terminal|browser", "role:file-manager"]),
            commands: ControlCommandTable.commands,
            globalFlags: ControlCommandTable.globalFlags,
            classes: [
                ClassDoc(name: ControlCommandClass.read.rawValue,
                         policy: "Allowed silently; a caller without a token cannot read browser "
                             + "URLs or titles (<redacted>)."),
                ClassDoc(name: ControlCommandClass.mutate.rawValue,
                         policy: "Applied silently but visibly: the status bar flashes and it goes into the "
                             + "in-app control-plane activity log; layout changes register with the "
                             + "UndoManager, so Edit ▸ Undo / ⌘Z rolls them back."),
                ClassDoc(name: ControlCommandClass.destructive.rawValue,
                         policy: destructivePolicy(mode: mode)),
                ClassDoc(name: ControlCommandClass.interactive.rawValue,
                         policy: "Always refused: these open a panel or pop-up menu that needs the keyboard."),
                ClassDoc(name: ControlCommandClass.sensitive.rawValue,
                         policy: sensitivePolicy(mode: mode)),
            ],
            exitCodes: ControlExit.allCases.map {
                ExitCodeDoc(code: $0.rawValue, name: String(describing: $0), summary: $0.summary)
            },
            errorCodes: ControlErrorCode.allCases.map {
                ErrorCodeDoc(code: $0.rawValue, exit: $0.exit.rawValue, summary: $0.summary)
            },
            actions: ControlCommandTable.actionDocs,
            appSettings: ControlAppSetting.allCases.map {
                AppSettingDoc(key: $0.rawValue, scope: $0.isPerScreen ? "screen" : "app", help: $0.help)
            },
            specSchema: specSchema,
            events: ControlEventType.allCases.map { EventDoc(type: $0.rawValue, summary: $0.summary) },
            mcpTools: MCPToolMap.tools.map(\.doc),
            groups: ControlCommandTable.groups.map {
                GroupDoc(name: $0, verbs: ControlCommandTable.commands(inGroup: $0).map(\.verb))
            },
            envVars: [
                EnvDoc(name: ControlProtocol.Env.socket,
                       summary: "Path to the control socket (injected into every pane QuickTerm opens)"),
                EnvDoc(name: ControlProtocol.Env.pane,
                       summary: "This pane's UUID — what `-t @self` resolves through"),
                EnvDoc(name: ControlProtocol.Env.screen,
                       summary: "The screen index at creation time (a hint; not updated when the pane moves)"),
                EnvDoc(name: ControlProtocol.Env.workspace,
                       summary: "The workspace index at creation time (a hint; not updated when the pane moves)"),
                EnvDoc(name: ControlProtocol.Env.token,
                       summary: "Proof of origin, **not a permission boundary**: it shows the command came from a "
                           + "pane QuickTerm opened, and it never skips a confirmation"),
                EnvDoc(name: ControlProtocol.Env.paneToken,
                       summary: "A per-pane, verifiable origin token (HMAC). Used in exactly one place: skipping "
                           + "the prompt when input send-text writes to the caller's own pane. "
                           + "Not a permission boundary either"),
            ],
            notes: [
                "When stdout is not a TTY the output is JSON; errors are always JSON on stderr "
                    + "carrying a stable code.",
                "A target that matches more than one thing is an error listing every candidate in "
                    + "`candidates` — never a silent first match.",
                "`action` is the keybinding-parity passthrough (the **only** place that keeps toggle "
                    + "semantics); prefer the noun-verb layer: it is all absolute setters, so running the "
                    + "same command twice leaves the same state.",
                "Every mutating command in the noun-verb layer takes --dry-run (returns `changes` and "
                    + "changes nothing) and --fail-if-noop (exit code 7 when the target is already in the "
                    + "requested state, instead of succeeding silently); the `action` passthrough takes neither.",
                "`workspace set-layout` can act on an **inactive** workspace — which `action toggle-layout` cannot.",
                "`workspace count N` rewrites config.toml and lands through the config watcher: the new "
                    + "count is only readable about 0.2s after the command returns.",
                "Mutating commands are rate-limited per origin (over the limit → exit code 6 with "
                    + "retryAfterMs); while a modal dialog is up in QuickTerm, **every** mutating command "
                    + "is refused (exit code 6).",
                "A pane that is fading out (mid close animation) cannot be addressed; every mutating "
                    + "command flushes those first.",
                "A pane's `focused` is the focus **of its own screen**; the globally unique one is on the "
                    + "screen with `key: true` — exactly one screen is always `key`: the real key window "
                    + "while the app is frontmost, otherwise the screen that was key most recently.",
                "Short handles (t7/b3) are stable only for this run of QuickTerm; the only identity that "
                    + "survives a restart is `id` (the UUID).",
                "To lay out a whole workspace at once use `spec apply`, not N `pane new` calls: "
                    + "N commands = N relayouts, N animations, N failure points; a spec is computed once "
                    + "and applied once.",
                "Run `--dry-run` before `spec apply --replace`: it returns the same envelope with "
                    + "applied=false, and `changes` is that diff.",
                "`spec dump` prints the spec itself (not wrapped in the response envelope), so you can "
                    + "redirect it to a file and apply it back.",
                "Every successful mutation advances `seq` (the one returned in the response); "
                    + "`events poll --since <seq>` returns what happened in between. Both seqs are the same "
                    + "ruler: polling with the seq a mutation returned never misses the events that command produced.",
                "Events **never carry a pane's output** — only structure, titles and cwd, and a browser "
                    + "pane's title / cwd is redacted for callers without a token exactly as in `state`.",
                "`events poll` is the form an agent should use (one request, one reply); `events follow` "
                    + "is an NDJSON stream for people and shell scripts. The buffer is a ring of "
                    + "\(ControlEventLimits.ringCapacity) events: `missed: true` means something was dropped "
                    + "in between, so read `state` again.",
                "`input send-text` is typing on that tty (possibly root, possibly a live ssh session): "
                    + "off by default, class sensitive, confirmed every time, control characters refused, "
                    + "and a newline only through --enter.",
                "`quickterm mcp` is an MCP stdio server generated from this same command table "
                    + "(\(MCPToolMap.tools.count) coarse-grained tools carrying readOnlyHint / destructiveHint / "
                    + "idempotentHint and an outputSchema): **use MCP for interactive, one-off control** "
                    + "(the host can auto-allow reads and prompt on destructive calls in its own layer), "
                    + "**use the CLI for batches and composition** (it costs no context until you call it, "
                    + "whereas a tool table is context tax paid at the start of every session).",
                "The MCP layer has no privilege of its own: every tools/call goes over the same socket, "
                    + "through the same confirmations and the same rate limit. `events follow` (a stream) "
                    + "and `install-cli` (making a symlink) are deliberately not exposed over MCP.",
            ])
    }
}
