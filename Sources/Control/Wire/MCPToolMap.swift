import Foundation

/// MCP 工具表（Phase 5）——**整张表从 `ControlCommandTable` 生成**，没有一行手写的工具描述。
///
/// 为什么是生成的：手写的第二份描述两个版本之内必然漂移，而漂移的代价全部由 agent 承担
/// （它拿着过期的 schema 发请求，收到自己解释不了的错误）。`MCPToolMapTests` 把这一条钉死：
/// 每个工具的每条 `command` 都必须在命令表里查得到，注解必须与那条命令的安全分级一致。
///
/// 为什么是 11 个粗粒度工具而不是 40 多个：工具表是**上下文税**——它在每次会话开始时
/// 整份进模型的上下文。一个动作一个工具的表既贵又难选。真正值钱的不是工具个数，
/// 而是 MCP 的**注解**：`readOnlyHint` / `destructiveHint` / `idempotentHint` 让宿主
/// （Claude Code / Codex）在它那一层就能自动放行读、对破坏性调用弹确认——
/// 这是在 QuickTerm 自己的确认闸门之外，**独立的第二道闸**。
///
/// **纯 Foundation**：本目录同时编进 app 与 `quickterm` 工具 target。
struct MCPTool {
    /// 工具名（宿主看到的那个）。`quickterm_` 前缀是为了在挂了十几个 server 的宿主里仍然认得出
    let name: String
    /// 给人看的短名
    let title: String
    /// 一句话说清这个工具是干什么的（英文：MCP 宿主与它们的提示词都是英文场）
    let summary: String
    /// 背后的命令表条目（线名，如 `pane.new`）。**顺序即 `command` 枚举的顺序**
    let commandNames: [String]

    var commands: [ControlCommandSpec] { commandNames.compactMap(ControlCommandTable.command) }

    // MARK: 注解（**机械地**从安全分级映射，不是手写的）

    /// 全部背后命令都是 `read` → 宿主可以自动放行
    var readOnlyHint: Bool { commands.allSatisfy { $0.cls == .read } }
    /// 任何一条是 `destructive` / `sensitive` → 宿主应当每次确认
    var destructiveHint: Bool { commands.contains { $0.cls == .destructive || $0.cls == .sensitive } }
    /// 全部背后命令都是绝对设值（跑两次结果一致）
    var idempotentHint: Bool { commands.allSatisfy(\.idempotent) }
    /// 封闭世界：它只驱动本机上这一个 QuickTerm，不去互联网上取任何东西
    var openWorldHint: Bool { false }

    /// 工具描述：一句英文 + **由命令表生成**的命令清单与例子。
    /// 中文摘要原样取自命令表——两份描述各写各的就是漂移的开始
    var description: String {
        var out = [summary]
        let list = commands
        if list.count > 1 {
            out.append("")
            out.append("`command` selects which QuickTerm command runs:")
            for spec in list {
                out.append("  \(spec.cli) — \(spec.summary)")
            }
        } else if let spec = list.first {
            out.append("")
            out.append("Runs `quickterm \(spec.cli)` — \(spec.summary)")
        }
        if list.contains(where: \.acceptsTarget) {
            out.append("")
            out.append("`target` is the addressing grammar `screen:workspace.pane` "
                + "(handles t7/b3, @focused, @self, @left/@right/@up/@down, title:~regex, cwd:prefix). "
                + "Ambiguous targets are an error listing every candidate — never a silent first match.")
        }
        out.append("")
        out.append("Examples (CLI form; the arguments are the same here):")
        for spec in list {
            for example in spec.examples.prefix(2) { out.append("  \(example)") }
        }
        out.append("")
        out.append("Safety: " + safetyLine)
        return out.joined(separator: "\n")
    }

    var safetyLine: String {
        let classes = Set(commands.map(\.cls.rawValue)).sorted().joined(separator: " / ")
        if readOnlyHint {
            return "class \(classes) — read-only, never prompts, never changes anything. "
                + "Browser pane URLs and titles are redacted unless the caller inherited QUICKTERM_TOKEN."
        }
        if destructiveHint {
            return "class \(classes) — QuickTerm asks the user to confirm in its own UI "
                + "(exit code 4 / error confirmation_required if nobody answers). Run with dry-run first."
        }
        // **这一句必须跟着 `idempotentHint` 走。** 宿主与模型读这一行是为了回答一个具体问题：
        // "调用超时了，能不能直接重发？" 对 `pane new` / `screen new` / `action` 来说答案是不能
        // （重发多出一个 pane，或者把一个 toggle 又翻回去），而工具自己的注解也确实写着
        // idempotentHint=false。注解说 false、正文说"跑两次结果一致"，两句话在同一个工具对象里打架，
        // 模型信的是正文
        if idempotentHint {
            return "class \(classes) — applied silently but visibly (status-bar flash, in-app activity log, "
                + "undo entry). Absolute setters: running the same call twice leaves the same state."
        }
        return "class \(classes) — applied silently but visibly (status-bar flash, in-app activity log, "
            + "undo entry). NOT idempotent: a second call repeats the effect (another pane, a re-toggled "
            + "state). Never retry blindly after a timeout — read state or quickterm_poll_events first."
    }

    // MARK: 输入 schema（由命令表的参数生成）

    var inputSchema: JSONValue {
        var properties: [String: JSONValue] = [:]
        var required: [JSONValue] = []
        let list = commands

        if list.count > 1 {
            properties["command"] = .object([
                "type": .string("string"),
                "enum": .array(list.map { .string($0.cli) }),
                "description": .string("Which QuickTerm command to run."),
            ])
            required.append(.string("command"))
        }
        if list.contains(where: \.acceptsTarget) {
            properties["target"] = .object([
                "type": .string("string"),
                "description": .string("Target `screen:workspace.pane`; each part may be omitted "
                    + "(defaults rightwards from context). Defaults to the focused pane."),
            ])
        }
        for arg in MCPToolMap.mergedArgs(of: list) {
            properties[arg.name] = arg.schema
            if arg.requiredEverywhere { required.append(.string(arg.name)) }
        }
        // spec 正文只能内联给：**MCP 服务端不去读调用方的文件系统**（`-f` 是 CLI 的事）。
        // 只有这个工具背的**每一条**命令都要读正文时才标成必填：`quickterm_dump_spec`
        // 背着 spec.dump（不读文件）与 spec.validate（读），标成工具级必填的话，
        // 守 schema 的宿主会逼模型每次都带上 spec，而 `MCPServer.buildRequest` 按解析出的那条命令
        // 校验参数，于是 `spec dump` 一律被自己的服务端拒掉
        if !list.isEmpty, list.allSatisfy(\.readsFile) {
            required.append(.string("spec"))
        }
        if list.contains(where: \.honorsMutationFlags) {
            properties[ControlCommandTable.Flag.dryRun] = .object([
                "type": .string("boolean"),
                "description": .string("Report what would change (`changes` is the diff) and change nothing."),
            ])
            properties[ControlCommandTable.Flag.failIfNoop] = .object([
                "type": .string("boolean"),
                "description": .string("Fail (exit 7 / error noop) instead of succeeding silently "
                    + "when the target is already in the requested state."),
            ])
        }
        var schema: [String: JSONValue] = [
            "type": .string("object"),
            "properties": .object(properties),
        ]
        if !required.isEmpty { schema["required"] = .array(required) }
        return .object(schema)
    }

    // MARK: 输出 schema（响应信封 + 这个工具真的会回的 data 形状）

    var outputSchema: JSONValue {
        let data = commands
            .map { MCPToolMap.dataSchema(for: $0) }
            .reduce(JSONValue.object([:])) { MCPToolMap.merge($0, $1) }
        return .object([
            "type": .string("object"),
            "description": .string("The control-plane response envelope, exactly as `quickterm --json` prints it."),
            "properties": .object([
                "ok": .object(["type": .string("boolean"),
                               "description": .string("false means `error` is filled in and nothing was applied.")]),
                "seq": .object(["type": .string("integer"),
                                "description": .string("Monotonic state counter; feed it to quickterm_poll_events.")]),
                "resolved": MCPToolMap.schema(fromSample: MCPSamples.resolved,
                                              description: "Where the command actually landed."),
                "data": data,
                "error": MCPToolMap.schema(fromSample: MCPSamples.error,
                                           description: "Stable `code` — branch on it, never on the message."),
            ]),
            "required": .array([.string("ok")]),
        ])
    }

    /// `describe --json` 里的那一份（宿主看不到，是给读 describe 的 agent 看的）
    struct Doc: Codable, Equatable {
        var name: String
        var title: String
        var commands: [String]
        var readOnlyHint: Bool
        var destructiveHint: Bool
        var idempotentHint: Bool
    }

    var doc: Doc {
        Doc(name: name, title: title, commands: commands.map(\.cli),
            readOnlyHint: readOnlyHint, destructiveHint: destructiveHint,
            idempotentHint: idempotentHint)
    }

    /// `tools/list` 上的那一份
    var listEntry: JSONValue {
        .object([
            "name": .string(name),
            "title": .string(title),
            "description": .string(description),
            "inputSchema": inputSchema,
            "outputSchema": outputSchema,
            "annotations": .object([
                "title": .string(title),
                "readOnlyHint": .bool(readOnlyHint),
                "destructiveHint": .bool(destructiveHint),
                "idempotentHint": .bool(idempotentHint),
                "openWorldHint": .bool(openWorldHint),
            ]),
        ])
    }
}

enum MCPToolMap {
    static let serverName = "quickterm"

    /// 粗粒度工具表。**一个动作一个工具是设计上明确否掉的**（见文件头）。
    /// 分组的规则只有一条：**同一个工具里的命令必须能共用同一套注解**——
    /// 把一条破坏性命令混进只读工具里，宿主那一层的闸门就当场失效了。
    static let tools: [MCPTool] = [
        MCPTool(name: "quickterm_describe", title: "Describe QuickTerm's control plane",
                summary: "Read the whole control surface as machine schema — every command, its arguments, "
                    + "the addressing grammar, exit codes, event types and all "
                    + "\(WMAction.allCases.count) window-manager actions. Call this once per session.",
                commandNames: ["describe", "version"]),
        MCPTool(name: "quickterm_state", title: "Read QuickTerm state",
                summary: "Read the session: a flat pane array plus a screen/workspace skeleton that only "
                    + "references pane handles. Use `fields` to keep large sessions out of your context.",
                commandNames: ["state", "list", "get", "app.get"]),
        MCPTool(name: "quickterm_action", title: "Run a window-manager action",
                summary: "Run one of the \(WMAction.allCases.count) keybinding actions verbatim. This is the "
                    + "parity escape hatch and it keeps keybinding semantics — every action is a toggle acting "
                    + "on the focused pane. Prefer quickterm_arrange: absolute setters replay safely, toggles do not.",
                commandNames: ["action"]),
        MCPTool(name: "quickterm_new_pane", title: "Create a pane or a screen",
                summary: "Open a terminal / browser / file-manager pane (optionally running a command in a "
                    + "directory), or a new screen (window). To lay out a whole workspace at once use "
                    + "quickterm_apply_spec instead of a loop of these.",
                commandNames: ["pane.new", "screen.new"]),
        MCPTool(name: "quickterm_focus", title: "Move focus",
                summary: "Give keyboard focus to a pane, switch a screen to a workspace, or bring a screen "
                    + "forward. Idempotent: asking for the state it is already in changes nothing.",
                commandNames: ["pane.focus", "workspace.goto", "screen.focus"]),
        MCPTool(name: "quickterm_arrange", title: "Arrange panes, workspaces and screens",
                summary: "Absolute setters for everything geometric plus the process-level settings: zoom, "
                    + "float, column width, split ratio, moving and swapping panes, workspace layout and "
                    + "equalize, workspace count, screen display / fullscreen / visible columns, theme and "
                    + "background. Running the same call twice leaves the same state.",
                commandNames: ["pane.set", "pane.move", "pane.swap", "pane.resize",
                               "workspace.set-layout", "workspace.equalize", "workspace.count",
                               "screen.move", "screen.set", "app.set"]),
        MCPTool(name: "quickterm_close", title: "Close panes, workspaces or screens",
                summary: "Close a pane, clear a workspace, or close a screen with everything in it. This ends "
                    + "the processes running there. Destructive: QuickTerm asks the user to confirm.",
                commandNames: ["pane.close", "workspace.clear", "screen.close"]),
        MCPTool(name: "quickterm_dump_spec", title: "Dump or validate a workspace spec",
                summary: "Serialise a workspace / screen / whole session as \(SpecSchema.workspace) JSON, or "
                    + "validate a spec without touching anything. dump -> edit -> apply is the safe way to "
                    + "reshape a layout.",
                commandNames: ["spec.dump", "spec.validate"]),
        MCPTool(name: "quickterm_apply_spec", title: "Apply a workspace spec",
                summary: "Lay out an entire workspace in one call: one relayout, one animation, one failure "
                    + "point. `into-empty` (the default) refuses a non-empty workspace and can destroy nothing; "
                    + "`reuse` keeps matching panes alive; `replace` closes what is there. Always dry-run first.",
                commandNames: ["spec.apply"]),
        MCPTool(name: "quickterm_poll_events", title: "Poll for state changes",
                summary: "Long-poll for what happened since a `seq`: panes opened/closed, focus, workspace, "
                    + "layout, screens, titles and cwds. Events never carry pane output — titles and cwd only.",
                commandNames: ["events.poll"]),
        MCPTool(name: "quickterm_send_text", title: "Type text into a terminal pane",
                summary: "Type text into a terminal pane as if it came from the keyboard. This is arbitrary "
                    + "code execution in whatever shell is there — possibly root, possibly a live ssh session. "
                    + "Off unless `[control] send-text = true`. Only the caller's own pane is exempt, and only "
                    + "when it proves that with the per-pane QUICKTERM_PANE_TOKEN it inherited — every other pane "
                    + "prompts the user every single time, showing the exact text. Control characters are refused "
                    + "and a newline needs `enter: true`.",
                commandNames: ["input.send-text"]),
    ]

    /// 刻意**不**上 MCP 的命令，以及为什么。`MCPToolMapTests` 要求命令表里的每一条
    /// 要么被某个工具覆盖，要么在这张表里写明理由——"忘了加"不可能悄悄溜过去
    static let excluded: [String: String] = [
        "install-cli": "在 PATH 里造软链是安装动作，不该由 agent 代劳（人跑一次 quickterm install-cli 即可）",
        "events.follow": "一条永不结束的 NDJSON 流塞不进一次工具调用；MCP 这边用 quickterm_poll_events",
        "mcp": "就是这个服务本身",
    ]

    static func tool(named name: String) -> MCPTool? { tools.first { $0.name == name } }

    /// 某条命令属于哪个工具（`describe` 与用例都靠它）
    static func tool(forCommand name: String) -> MCPTool? {
        tools.first { $0.commandNames.contains(name) }
    }

    // MARK: 参数合并（一个工具背几条命令时）

    struct MergedArg {
        var name: String
        var jsonTypes: [String]
        var values: [String]?
        var help: String
        var requiredEverywhere: Bool

        var schema: JSONValue {
            var out: [String: JSONValue] = [
                "type": jsonTypes.count == 1 ? .string(jsonTypes[0])
                    : .array(jsonTypes.map { .string($0) }),
                "description": .string(help),
            ]
            if let values { out["enum"] = .array(values.map { .string($0) }) }
            if jsonTypes == ["array"] { out["items"] = .object(["type": .string("string")]) }
            return .object(out)
        }
    }

    /// `--file` 不上 MCP：读文件的永远是调用方那一侧，服务端替谁 open 一个路径都是可被滥用的原语
    static let argsNotExposed: Set<String> = ["file"]

    static func mergedArgs(of commands: [ControlCommandSpec]) -> [MergedArg] {
        var order: [String] = []
        var byName: [String: [(ControlCommandSpec, ControlArgSpec)]] = [:]
        for spec in commands {
            for arg in spec.args where !argsNotExposed.contains(arg.name) {
                if byName[arg.name] == nil { order.append(arg.name) }
                byName[arg.name, default: []].append((spec, arg))
            }
        }
        return order.map { name in
            let entries = byName[name] ?? []
            var types: [String] = []
            for (_, arg) in entries where !types.contains(jsonType(of: arg)) { types.append(jsonType(of: arg)) }
            // 取值集合各不相同时**不写 enum**：写一个只对其中一条命令成立的 enum，
            // 比不写更糟——宿主会照着它挡掉合法调用
            let valueSets = entries.map { $0.1.values }
            let values: [String]? = valueSets.allSatisfy { $0 == valueSets.first } ? valueSets.first ?? nil : nil

            var help = entries[0].1.help
            if let def = entries[0].1.defaultValue { help += "（默认 \(def)）" }
            if values == nil, entries.contains(where: { $0.1.values != nil }) {
                let perCommand = entries.compactMap { entry -> String? in
                    entry.1.values.map { "\(entry.0.cli): \($0.joined(separator: " | "))" }
                }
                help += "（" + perCommand.joined(separator: "；") + "）"
            }
            if commands.count > 1, entries.count < commands.count {
                help = "[" + entries.map { $0.0.cli }.joined(separator: ", ") + "] " + help
            }
            let requiredEverywhere = entries.count == commands.count && entries.allSatisfy { $0.1.required }
            return MergedArg(name: name, jsonTypes: types, values: values, help: help,
                             requiredEverywhere: requiredEverywhere)
        }
    }

    static func jsonType(of arg: ControlArgSpec) -> String {
        if arg.repeatable { return "array" }
        switch arg.kind {
        case .string, .enumeration: return "string"
        case .int: return "integer"
        case .double: return "number"
        case .bool: return "boolean"
        }
    }

    // MARK: 输出 schema（从**真实负载类型的样例**推出来，不是手抄的字段清单）

    /// 每条命令的 `data` 形状。样例编码一遍就是 schema：给负载类型加一个字段，
    /// schema 自动跟上；样例漏填一个可选字段，`MCPToolMapTests` 拿真实响应一比就当场报出来
    static func dataSchema(for spec: ControlCommandSpec) -> JSONValue {
        switch spec.name {
        case "describe":
            // 整份 describe 文档做成 schema 会比文档本身还大，而它本来就是"读一次的大对象"
            return .object([
                "type": .string("object"),
                "description": .string("A quickterm.describe/1 document: commands, target grammar, exit codes, "
                    + "error codes, event types, app settings, the workspace spec schema and every WM action."),
            ])
        case "version":
            return schema(fromSample: MCPSamples.version, description: "Versions and socket path.")
        case "state":
            return schema(fromSample: MCPSamples.state, description: "quickterm.state/1")
        case "list":
            return schema(fromSample: MCPSamples.list, description: "Whichever of the three lists was asked for.")
        case "get":
            return schema(fromSample: MCPSamples.pane, description: "One pane record.")
        case "action":
            return merge(schema(fromSample: MCPSamples.action, description: "What the action did."),
                         schema(fromSample: MCPSamples.actionList, description: nil))
        case "app.get":
            return schema(fromSample: MCPSamples.appSettings, description: "Process-level settings and their choices.")
        case "spec.dump":
            return schema(fromSample: MCPSamples.specDump, description: "`spec` is the document itself.")
        case "spec.validate":
            return schema(fromSample: MCPSamples.specValidate, description: "Validation report; nothing was changed.")
        case "events.poll":
            return schema(fromSample: MCPSamples.events, description: "quickterm.events/1 — never carries pane output.")
        default:
            // 名词-动词层的变更命令共用一个信封（`ControlMutationPayload`）
            return schema(fromSample: MCPSamples.mutation,
                          description: "The mutation envelope: `changed` = there was something to do, "
                              + "`applied` = it was really done (always false for a dry run), `changes` = the diff.")
        }
    }

    /// 嵌套多深还展开字段。**工具表是每次会话都要付的上下文税**：
    /// 一个六屏会话的完整嵌套 schema 比它描述的响应还长，而 agent 真正需要的是
    /// "data 里有哪些键、记录数组里的记录长什么样"，再深的形状 `quickterm describe --json` 里有
    static let schemaDepth = 2

    /// 一个编码好的样例 → 一份 JSON Schema
    static func schema(fromSample value: JSONValue, description: String?,
                       depth: Int = schemaDepth) -> JSONValue {
        var out: [String: JSONValue]
        switch value {
        case .object(let object):
            guard depth > 0 else { out = ["type": .string("object")]; break }
            var properties: [String: JSONValue] = [:]
            for (key, child) in object {
                properties[key] = schema(fromSample: child, description: nil, depth: depth - 1)
            }
            out = ["type": .string("object"), "properties": .object(properties)]
        case .array(let array):
            // 数组不算一层：一串记录在语义上就是"记录"这一层
            out = ["type": .string("array"),
                   "items": array.first.map { schema(fromSample: $0, description: nil, depth: depth) }
                       ?? .object([:])]
        case .string: out = ["type": .string("string")]
        case .int: out = ["type": .string("integer")]
        case .double: out = ["type": .string("number")]
        case .bool: out = ["type": .string("boolean")]
        case .null: out = [:]
        }
        if let description { out["description"] = .string(description) }
        return .object(out)
    }

    static func schema(fromSample value: some Encodable, description: String?) -> JSONValue {
        guard let data = try? ControlJSON.encoder.encode(value),
              let json = try? ControlJSON.decoder.decode(JSONValue.self, from: data) else {
            return .object(["type": .string("object")])
        }
        return schema(fromSample: json, description: description)
    }

    /// 两份对象 schema 合并成一份（一个工具背的几条命令回不同的 data 时）
    static func merge(_ a: JSONValue, _ b: JSONValue) -> JSONValue {
        guard var left = a.objectValue else { return b }
        guard let right = b.objectValue else { return a }
        if left.isEmpty { return b }
        if right.isEmpty { return a }
        var properties = left["properties"]?.objectValue ?? [:]
        for (key, value) in right["properties"]?.objectValue ?? [:] where properties[key] == nil {
            properties[key] = value
        }
        if !properties.isEmpty {
            left["properties"] = .object(properties)
            left["type"] = .string("object")
        }
        return .object(left)
    }
}

/// 负载样例。**只为生成 `outputSchema` 存在**：每个可选字段都填上，
/// 否则那个字段就不会出现在 schema 里（用例拿真实响应对着 schema 比，漏了当场报）
enum MCPSamples {
    static let resolved = ResolvedTarget(screen: 1, screenID: "3F2A9C", workspace: 2,
                                         pane: "t7", paneID: "C40D")
    static let error = ControlErrorBody(.ambiguousTarget, "3 个 pane 匹配 title:~dev",
                                        hint: "改用 -t <句柄>", candidates: ["t2", "t7", "b1"],
                                        retryAfterMs: 800)

    static let paneInfo = ControlStatePayload.PaneInfo(
        handle: "t7", id: "C40D-…", kind: "terminal", role: "shell", screen: 1, workspace: 2,
        at: ControlStatePayload.PaneInfo.Position(column: 2, row: 0, path: "b.a"),
        size: ControlStatePayload.PaneInfo.PaneSize(
            rect: [0.97, 0, 0.485, 1], points: [776, 900], cols: 96, rows: 48,
            split: "vertical", ratio: 0.62, width: 0.485, share: 1),
        title: "npm run dev", cwd: "/Users/you/proj", url: "http://localhost:3000", tabs: 2,
        focused: false, busy: true, float: false, zoom: false, redacted: false)

    static let workspaceInfo = ControlStatePayload.WorkspaceInfo(
        index: 2, layout: "scrolling", empty: false, active: true, panes: ["t7", "b3"], zoom: "t7",
        columns: [ControlStatePayload.ColumnInfo(width: 0.485, panes: ["t7"])],
        tree: .split(.init(split: "vertical", ratio: 0.62, a: .leaf("t7"), b: .leaf("b3"))),
        floating: ["t9"])

    static let screenInfo = ControlStatePayload.ScreenInfo(
        index: 1, id: "3F2A9C", title: "QuickTerm", key: true, activeWorkspace: 2,
        visibleColumns: 2, fullscreen: false, joinAllSpaces: false,
        display: ControlStatePayload.DisplayInfo(uuid: "37D8…", name: "Studio Display"),
        frame: [0, 0, 1600, 1000], workspaces: [workspaceInfo])

    static let state = ControlStatePayload(
        app: ControlStatePayload.AppInfo(version: "1.5.8", protocolVersion: ControlProtocol.version,
                                         workspaceCount: 5, mode: "ask", trusted: true),
        screens: [screenInfo], panes: [paneInfo])

    static let list = ControlListPayload(screens: [screenInfo], workspaces: [workspaceInfo],
                                         panes: [(try? ControlJSON.decoder.decode(
                                             JSONValue.self,
                                             from: ControlJSON.encoder.encode(paneInfo))) ?? .null])

    static let pane = ControlPanePayload(pane: paneInfo)

    static let action = ControlActionPayload(action: "new-terminal", cls: .mutate, applied: true,
                                             confirmPending: false, focusPending: true,
                                             panes: [paneInfo])

    static let actionList = ControlActionListPayload(actions: ControlCommandTable.actionDocs)

    static let appSettings = ControlAppPayload(settings: [
        ControlAppPayload.Setting(key: "theme", value: "tokyo-night",
                                  choices: ["tokyo-night", "gruvbox"], scope: "app",
                                  help: ControlAppSetting.theme.help),
    ])

    static let mutation = ControlMutationPayload(
        command: "pane.set", applied: true, changed: true, dryRun: false,
        changes: [ControlChange("1:2.t7.zoom", from: "off", to: "on")],
        pane: paneInfo, panes: [paneInfo], workspace: workspaceInfo, screen: screenInfo,
        focusPending: true, confirmPending: false, undo: "控制面：pane set",
        note: "由 config.toml 监听落地，约 0.2s 后生效",
        spec: ControlSpecApplyReport(mode: "reuse", scope: "workspace", created: ["t9"],
                                     reused: ["t3"], closed: ["t4"], partial: false,
                                     skipped: ["screen 3"]))

    static let specDump = ControlSpecDumpPayload(scope: "workspace", schema: SpecSchema.workspace,
                                                 panes: 3, spec: .object([:]))

    static let specValidate = ControlSpecValidatePayload(valid: true, scope: "workspace",
                                                         schema: SpecSchema.workspace, panes: 3,
                                                         notes: ["dump 不会回吐 cmd"])

    static let events = ControlEventsPayload(
        events: [ControlEvent(seq: 418, ts: ControlEvent.stamp(), type: .paneOpened,
                              screen: 1, screenID: "3F2A9C", workspace: 2, pane: "t9",
                              paneID: "C40D", kind: "terminal", layout: "scrolling",
                              title: "zsh", cwd: "/Users/you/proj", redacted: false)],
        seq: 420, oldest: 301, missed: false, timedOut: false, truncated: false, follow: false)

    static let version = ControlVersionPayload(cli: "1.5.8", app: "1.5.8",
                                               protocolVersion: ControlProtocol.version,
                                               appProtocolVersion: ControlProtocol.version,
                                               socket: "/Users/you/Library/Application Support/QuickTerm/control.sock",
                                               running: true)
}
