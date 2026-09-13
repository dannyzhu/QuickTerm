import Foundation

/// The MCP tool table (Phase 5) — **the whole table is generated from `ControlCommandTable`**; not
/// one line of tool description is hand-written.
///
/// Why generated: a second, hand-written description drifts within two releases, and the whole cost
/// of that drift lands on the agent (it sends requests against a stale schema and gets back errors
/// it cannot explain). `MCPToolMapTests` pins this down: every `command` of every tool must resolve
/// in the command table, and the annotations must agree with that command's safety class.
///
/// Why 11 coarse tools instead of 40-odd: the tool table is a **context tax** — all of it enters
/// the model's context at the start of every session. A one-tool-per-action table is both expensive
/// and hard to choose from. What actually pays is not the number of tools but MCP's
/// **annotations**: `readOnlyHint` / `destructiveHint` / `idempotentHint` let the host (Claude Code
/// / Codex) auto-approve reads and prompt on destructive calls at its own layer — an **independent
/// second gate**, outside QuickTerm's own confirmation gate.
///
/// **Pure Foundation**: this directory is compiled into both the app and the `quickterm` tool
/// target.
struct MCPTool {
    /// The tool name (the one the host shows). The `quickterm_` prefix is there so it stays
    /// recognizable in a host with a dozen servers attached.
    let name: String
    /// The short, human-facing name.
    let title: String
    /// One sentence saying what this tool does (in English: MCP hosts and their prompts are an
    /// English-language environment).
    let summary: String
    /// The command-table entries behind it (wire names, e.g. `pane.new`). **This order is the order
    /// of the `command` enum.**
    let commandNames: [String]

    var commands: [ControlCommandSpec] { commandNames.compactMap(ControlCommandTable.command) }

    // MARK: Annotations (**mechanically** mapped from the safety class, never hand-written)

    /// Every command behind it is `read` -> the host may auto-approve.
    var readOnlyHint: Bool { commands.allSatisfy { $0.cls == .read } }
    /// Any one of them is `destructive` / `sensitive` -> the host should confirm every time.
    var destructiveHint: Bool { commands.contains { $0.cls == .destructive || $0.cls == .sensitive } }
    /// Every command behind it is an absolute setter (running it twice leaves the same state).
    var idempotentHint: Bool { commands.allSatisfy(\.idempotent) }
    /// A closed world: it drives the one QuickTerm on this machine and fetches nothing from the
    /// internet.
    var openWorldHint: Bool { false }

    /// The tool description: one English sentence plus the command list and examples,
    /// **generated from the command table**.
    /// Each command's summary is taken from that table verbatim — two descriptions written
    /// separately is where drift begins.
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
            // "Dry-run it first" only holds for tools that **actually take the argument**. The
            // pane.capture-text behind `quickterm_read_terminal` is readOnlyEffect (it changes
            // nothing), so `honorsMutationFlags` is false: there is no dry_run property in its
            // schema at all, and the server rejects it as an unknown argument (bad_request).
            // Telling the model in prose to do something guaranteed to fail is exactly the drift
            // that "generate every annotation mechanically" exists to prevent.
            let advice = commands.contains(where: \.honorsMutationFlags)
                ? " Run with dry-run first."
                : " Changes nothing itself, and takes no dry-run / fail-if-noop."
            return "class \(classes) — QuickTerm asks the user to confirm in its own UI "
                + "(exit code 4 / error confirmation_required if nobody answers)." + advice
        }
        // **This sentence has to track `idempotentHint`.** The host and the model read this line to
        // answer one concrete question: "the call timed out, can I just resend it?" For `pane new`
        // / `screen new` / `action` the answer is no (a resend produces an extra pane, or flips a
        // toggle back again), and the tool's own annotation does say idempotentHint=false. With the
        // annotation saying false and the prose saying "running it twice leaves the same state",
        // the two contradict each other inside the same tool object — and the model believes the
        // prose.
        if idempotentHint {
            return "class \(classes) — applied silently but visibly (status-bar flash, in-app activity log, "
                + "undo entry). Absolute setters: running the same call twice leaves the same state."
        }
        return "class \(classes) — applied silently but visibly (status-bar flash, in-app activity log, "
            + "undo entry). NOT idempotent: a second call repeats the effect (another pane, a re-toggled "
            + "state). Never retry blindly after a timeout — read state or quickterm_poll_events first."
    }

    // MARK: Input schema (generated from the command table's arguments)

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
        // A spec body can only be passed inline: **the MCP server never reads the caller's file
        // system** (`-f` is the CLI's business).
        // It is marked required only when **every** command behind this tool needs a body:
        // `quickterm_dump_spec` carries spec.dump (no file) and spec.validate (file), and marking
        // it required at the tool level would make a schema-enforcing host force `spec` onto every
        // call, while `MCPServer.buildRequest` validates arguments against the command it actually
        // resolved — so `spec dump` would be rejected by its own server every time.
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

    // MARK: Output schema (the response envelope plus the `data` shape this tool actually returns)

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

    /// The copy that goes into `describe --json` (hosts never see this one; it is for an agent
    /// reading describe).
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

    /// The copy that goes on `tools/list`.
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

    /// The coarse-grained tool table. **One tool per action was explicitly rejected in the design**
    /// (see the file header).
    /// There is exactly one grouping rule: **the commands inside one tool must be able to share one
    /// set of annotations** — slip a destructive command into a read-only tool and the host-layer
    /// gate is dead on the spot.
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
                summary: "Geometry plus the process-level settings: zoom, float, column width, split ratio, "
                    + "moving and swapping panes, workspace layout and equalize, workspace name, workspace "
                    + "count, screen display / fullscreen / visible columns, theme and background. Most of "
                    + "these are absolute setters, where the same call twice leaves the same state — but "
                    + "`pane resize` steps a divider relative to where it is now (a second call moves it "
                    + "again, except at the boundary) and `pane move` / `pane swap` are positional, so none "
                    + "of those three is safe to replay. This tool's idempotentHint is false for that reason.",
                commandNames: ["pane.set", "pane.move", "pane.swap", "pane.resize",
                               "workspace.set", "workspace.set-layout", "workspace.equalize",
                               "workspace.count",
                               "screen.move", "screen.set", "app.set"]),
        MCPTool(name: "quickterm_close", title: "Close panes, tabs, workspaces or screens",
                summary: "Close a pane, one browser tab (closing the last tab closes the pane, exactly like "
                    + "Cmd-W), clear a workspace, or close a screen with everything in it. This ends "
                    + "the processes running there. Destructive: QuickTerm asks the user to confirm.",
                commandNames: ["pane.close", "browser.close", "workspace.clear", "screen.close"]),
        MCPTool(name: "quickterm_browser", title: "Drive a browser pane's tabs",
                summary: "Open a new tab at a URL, navigate a tab, or reload one, in a browser pane. "
                    + "`target` picks the pane (b3); `tab` picks the tab inside it — 1-based index, "
                    + "`#<id prefix>` from the pane's `tabList`, `@active` (default) or `@last`. "
                    + "Read `tabList` from quickterm_state first: it is what `tab` addresses. "
                    + "Tab titles and URLs are redacted for callers without QUICKTERM_TOKEN, exactly like "
                    + "the pane-level ones. To close a tab use quickterm_close.",
                commandNames: ["browser.open", "browser.goto", "browser.reload"]),
        MCPTool(name: "quickterm_read_terminal", title: "Read a terminal pane's screen",
                summary: "Return the text currently visible in a terminal pane (optionally plus N lines of "
                    + "scrollback) — how a command you started actually ended. Treated as sensitive, not as a "
                    + "read: a shell screen can hold tokens, a password typed at a prompt, private source. "
                    + "Off unless `[control] capture-text = true`; the caller must carry QUICKTERM_TOKEN; and "
                    + "the user confirms once per calling process in QuickTerm's own UI. The captured text is "
                    + "returned once and never logged.",
                commandNames: ["pane.capture-text"]),
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

    /// The commands deliberately kept **off** MCP, and why. `MCPToolMapTests` requires every entry
    /// in the command table to be either covered by some tool or listed here with a reason — "we
    /// forgot to add it" cannot slip through.
    static let excluded: [String: String] = [
        "install-cli": "Symlinking into PATH is an installation step, not something an agent should do "
            + "on the user's behalf (a human runs `quickterm install-cli` once)",
        "events.follow": "A never-ending NDJSON stream does not fit into one tool call; "
            + "MCP callers use quickterm_poll_events instead",
        "mcp": "This server itself",
    ]

    static func tool(named name: String) -> MCPTool? { tools.first { $0.name == name } }

    /// Which tool a given command belongs to (both `describe` and the tests rely on this).
    static func tool(forCommand name: String) -> MCPTool? {
        tools.first { $0.commandNames.contains(name) }
    }

    // MARK: Argument merging (for a tool that carries several commands)

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

    /// `--file` stays off MCP: reading a file is always the caller's side of the line, and a server
    /// that will open a path on someone's behalf is an abusable primitive.
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
            // When the value sets differ, **write no enum at all**: an enum that only holds for one
            // of the commands is worse than none — the host will use it to block legitimate calls
            let valueSets = entries.map { $0.1.values }
            let values: [String]? = valueSets.allSatisfy { $0 == valueSets.first } ? valueSets.first ?? nil : nil

            var help = entries[0].1.help
            if let def = entries[0].1.defaultValue { help += " (default \(def))" }
            if values == nil, entries.contains(where: { $0.1.values != nil }) {
                let perCommand = entries.compactMap { entry -> String? in
                    entry.1.values.map { "\(entry.0.cli): \($0.joined(separator: " | "))" }
                }
                help += " (" + perCommand.joined(separator: "; ") + ")"
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

    // MARK: Output schema (derived from **samples of the real payload types**, not a hand-copied
    // field list)

    /// The `data` shape of each command. Encoding the sample once produces the schema: add a field
    /// to a payload type and the schema follows automatically; leave an optional field out of a
    /// sample and `MCPToolMapTests` catches it the moment it diffs a real response against the
    /// schema.
    static func dataSchema(for spec: ControlCommandSpec) -> JSONValue {
        switch spec.name {
        case "describe":
            // A full schema for the describe document would be bigger than the document itself, and
            // it is a read-once blob by design
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
        case "pane.capture-text":
            return schema(fromSample: MCPSamples.capture,
                          description: "`text` is what the pane shows right now (plus `scrollback` lines of "
                              + "history when asked). It is returned here once and written nowhere else.")
        default:
            // The mutating commands in the noun-verb layer all share one envelope
            // (`ControlMutationPayload`)
            return schema(fromSample: MCPSamples.mutation,
                          description: "The mutation envelope: `changed` = there was something to do, "
                              + "`applied` = it was really done (always false for a dry run), `changes` = the diff.")
        }
    }

    /// How deep the nesting still gets expanded into fields. **The tool table is a context tax paid
    /// once per session**: the fully nested schema for a six-screen session is longer than the
    /// response it describes, while what an agent actually needs is "which keys `data` has, and
    /// what a record in a record array looks like". Anything deeper is in `quickterm describe
    /// --json`.
    static let schemaDepth = 2

    /// One encoded sample -> one JSON Schema.
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
            // An array does not count as a level: a list of records is semantically just the
            // "record" level
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

    /// Merges two object schemas into one (for a tool whose commands return different `data`).
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

/// Payload samples. **They exist purely to generate `outputSchema`**: every optional field is
/// filled in, because a field left out of a sample never appears in the schema (the tests diff a
/// real response against the schema and report the omission on the spot).
enum MCPSamples {
    static let resolved = ResolvedTarget(screen: 1, screenID: "3F2A9C", workspace: 2,
                                         pane: "t7", paneID: "C40D")
    static let error = ControlErrorBody(.ambiguousTarget, "3 panes match title:~dev",
                                        hint: "Re-address it by handle: -t <handle>",
                                        candidates: ["t2", "t7", "b1"],
                                        retryAfterMs: 800)

    static let paneInfo = ControlStatePayload.PaneInfo(
        handle: "t7", id: "C40D-…", kind: "terminal", role: "shell", screen: 1, workspace: 2,
        at: ControlStatePayload.PaneInfo.Position(column: 2, row: 0, path: "b.a"),
        size: ControlStatePayload.PaneInfo.PaneSize(
            rect: [0.97, 0, 0.485, 1], points: [776, 900], cols: 96, rows: 48,
            split: "vertical", ratio: 0.62, width: 0.485, share: 1),
        title: "npm run dev", cwd: "/Users/you/proj", url: "http://localhost:3000", tabs: 2,
        tabList: [ControlStatePayload.PaneInfo.TabInfo(
            index: 1, id: "8A1F-…", active: true, title: "QuickTerm",
            url: "http://localhost:3000", loading: false)],
        focused: false, busy: true, float: false, zoom: false, redacted: false)

    static let workspaceInfo = ControlStatePayload.WorkspaceInfo(
        index: 2, title: "dev", layout: "scrolling", empty: false, active: true,
        panes: ["t7", "b3"], zoom: "t7",
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
        focusPending: true, confirmPending: false, undo: "Control plane: pane set",
        note: "Lands through the config.toml watcher, in effect about 0.2s later",
        spec: ControlSpecApplyReport(mode: "reuse", scope: "workspace", created: ["t9"],
                                     reused: ["t3"], closed: ["t4"], partial: false,
                                     skipped: ["screen 3"]),
        warnings: [ControlWarning.cwdDenied("/Users/you/Downloads", used: nil)])

    static let capture = ControlCaptureTextPayload(
        command: "pane.capture-text", pane: paneInfo, cols: 96, rows: 24,
        lines: 2, scrollback: 0, truncated: false, text: "~/proj $ npm test\n  12 passing")

    static let specDump = ControlSpecDumpPayload(scope: "workspace", schema: SpecSchema.workspace,
                                                 panes: 3, spec: .object([:]))

    static let specValidate = ControlSpecValidatePayload(valid: true, scope: "workspace",
                                                         schema: SpecSchema.workspace, panes: 3,
                                                         notes: ["dump never gives cmd back"])

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
