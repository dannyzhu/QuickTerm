import Foundation

/// Why a rule file was rejected. A rule file is **all or nothing** (see `AgentRulesTOML`), and
/// every message names the line or the key, because the only person who ever reads one is
/// somebody editing that file.
enum AgentRulesError: Error, Equatable, CustomStringConvertible {
    case syntax(line: Int, text: String)
    /// A value that parses but cannot mean anything (`state = "idle:approval"`).
    case invalid(key: String, reason: String)
    case missing(key: String)
    /// A table or key the schema does not know. **Not ignored**: a typo must not silently switch
    /// one event off.
    case unknown(key: String)

    var description: String {
        switch self {
        case .syntax(let line, let text): "line \(line): \(text)"
        case .invalid(let key, let reason): "\(key): \(reason)"
        case .missing(let key): "\(key) is required"
        case .unknown(let key): "\(key) is not part of the rule-file schema"
        }
    }
}

/// **A field path**: `$` plus one or two `.segment`s, evaluated against the reduced payload.
///
/// Paths only — no expressions, no defaults, no regex. What a rule file may say about a payload
/// is "the value is over there", and everything that decides anything stays in Swift, where it
/// is read in review and covered by tests.
struct AgentFieldPath: Equatable {
    var head: String
    var sub: String?

    /// `$.tool_input.command` -> `(tool_input, command)`. Throws for a path that names a field
    /// the whitelist does not have: a rule file pointing at `$.transcript_path` has to fail at
    /// load, not read empty for ever.
    static func parse(_ raw: String, key: String) throws -> AgentFieldPath {
        guard raw.hasPrefix("$.") else {
            throw AgentRulesError.invalid(key: key, reason: "a field path starts with $. (got \(raw))")
        }
        let segments = raw.dropFirst(2).split(separator: ".", omittingEmptySubsequences: false)
            .map(String.init)
        guard (1...2).contains(segments.count),
              segments.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") } })
        else {
            throw AgentRulesError.invalid(key: key, reason: "a field path is $.a or $.a.b (got \(raw))")
        }
        if segments.count == 1 {
            guard AgentEventPayload.scalarPaths.contains(segments[0]) else {
                throw AgentRulesError.invalid(
                    key: key,
                    reason: "\(raw) is not a payload field (one of \(AgentEventPayload.scalarPaths.joined(separator: ", ")))")
            }
            return AgentFieldPath(head: segments[0], sub: nil)
        }
        guard AgentEventPayload.objectPaths.contains(segments[0]) else {
            throw AgentRulesError.invalid(
                key: key,
                reason: "only \(AgentEventPayload.objectPaths.joined(separator: " / ")) have sub-keys (got \(raw))")
        }
        return AgentFieldPath(head: segments[0], sub: segments[1])
    }

    func value(in payload: AgentEventPayload) -> String? {
        guard let value = payload.value(head, sub), !value.isEmpty else { return nil }
        return value
    }
}

/// A state a rule file may map an event to. `released` is not a state: it means "this agent's
/// status is removed from the pane".
enum AgentStateTag: Equatable {
    case released
    case state(AgentState, AgentDetail?)

    /// The ten spellings, and no others. A detail belongs to exactly one state
    /// (`AgentDetail.coarse`), and `working` / `blocked` are meaningless without one — writing
    /// them bare would be a rule file saying "busy somehow", which no surface can draw.
    static func parse(_ raw: String, key: String) throws -> AgentStateTag {
        if raw == "released" { return .released }
        let parts = raw.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard (1...2).contains(parts.count), let state = AgentState(rawValue: parts[0]) else {
            throw AgentRulesError.invalid(key: key, reason: "\(raw) is not a state tag")
        }
        guard parts.count == 2 else {
            guard state != .working, state != .blocked else {
                throw AgentRulesError.invalid(
                    key: key, reason: "\(raw) needs a detail (\(state.rawValue):thinking and the like)")
            }
            return .state(state, nil)
        }
        guard let detail = AgentDetail(rawValue: parts[1]) else {
            throw AgentRulesError.invalid(key: key, reason: "\(parts[1]) is not a detail")
        }
        guard detail.coarse == state else {
            throw AgentRulesError.invalid(
                key: key,
                reason: "\(parts[1]) belongs to \(detail.coarse.rawValue), not to \(state.rawValue)")
        }
        return .state(state, detail)
    }

    var displayState: AgentState? {
        if case .state(let state, _) = self { return state }
        return nil
    }
}

/// **One agent's rule file** (plan §2.3): what is agent-specific and nothing else.
///
/// Everything cross-agent — precedence, the hook-recency window, the presence rule, when a notice
/// is posted and when it is resolved — lives once, in `AgentStateReducer` and `AgentRegistry`. A
/// rule file says only which processes carry this agent's name, which event means which state,
/// where in a payload each piece of text is, and what its installer writes.
struct AgentRules: Equatable {
    /// How a hook event maps to a state: either flatly, or keyed on one payload field.
    enum HookRule: Equatable {
        case plain(AgentStateTag)
        case keyed(field: AgentFieldPath, values: [String: AgentStateTag])
    }

    /// One `[notifications]` line. A struct rather than a tuple because the order of these is
    /// data (first match wins) and an array of tuples is not `Equatable`.
    struct NotificationRule: Equatable {
        var prefix: String
        var tag: AgentStateTag
    }

    /// Where each piece of text lives in this agent's payloads. Each is a list of paths: the
    /// first non-empty one wins, which is how one key covers `tool_input.command` for a shell and
    /// `tool_input.file_path` for a write.
    struct Fields: Equatable {
        var session: [AgentFieldPath] = []
        var message: [AgentFieldPath] = []
        var tool: [AgentFieldPath] = []
        var error: [AgentFieldPath] = []
        /// The sensitive one-liner for a notice body and the strip.
        var summary: [AgentFieldPath] = []

        func first(_ paths: [AgentFieldPath], in payload: AgentEventPayload) -> String? {
            for path in paths {
                if let value = path.value(in: payload) { return value }
            }
            return nil
        }
    }

    /// Which JSON shape this agent's config file takes (plan §2.6). The three differ in one
    /// entry key and one timeout unit, which is exactly why this is a value and not three
    /// installers.
    enum Shape: String, Equatable {
        case claude, codex, gemini
    }

    /// What the installer writes, and where. Absent for a rule file describing an agent with no
    /// hooks at all: identity then comes from the process scan alone, and `hooks status` says
    /// "no installer".
    struct Install: Equatable {
        var shape: Shape
        /// The user-level config file, `~` **not** expanded (it is expanded at use, so a test can
        /// point the installer somewhere else without the path having been resolved already).
        var config: String
        /// The events written at `hook-detail = "lifecycle"`.
        var lifecycle: [String]
        /// The events added at `hook-detail = "tools"`.
        var tools: [String]

        /// Every event of a tier, lifecycle first.
        func events(detail: String) -> [String] {
            detail == "tools" ? lifecycle + tools : lifecycle
        }
    }

    var id: String
    var name: String
    /// Executable basenames the process scan matches (`proc_pidpath`).
    var process: [String]
    var fields: Fields
    var hooks: [String: HookRule]
    /// Matched by `hasPrefix`, **in file order**, first match wins.
    var notifications: [NotificationRule]
    var install: Install?

    // MARK: Loading

    private static let tableNames: Set<String> = ["fields", "hooks", "notifications", "install"]
    private static let rootKeys: Set<String> = ["id", "name", "process"]
    private static let fieldKeys: Set<String> = ["session", "message", "tool", "error", "summary"]
    private static let installKeys: Set<String> = ["shape", "config", "lifecycle", "tools"]

    /// Parse and validate one rule file. Throws on the first thing that cannot mean what it says.
    static func parse(_ text: String) throws -> AgentRules {
        let document = try AgentRulesTOML.parse(text)
        try rejectUnknownTables(document)

        guard let id = document.root("id")?.stringValue else { throw AgentRulesError.missing(key: "id") }
        guard !id.isEmpty, id.allSatisfy({ $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "-") }) else {
            throw AgentRulesError.invalid(key: "id", reason: "a rule id is lowercase letters, digits and -")
        }
        guard let name = document.root("name")?.stringValue, !name.isEmpty else {
            throw AgentRulesError.missing(key: "name")
        }
        for entry in document.table("")?.entries ?? [] where !rootKeys.contains(entry.key) {
            throw AgentRulesError.unknown(key: entry.key)
        }
        let process = document.root("process")?.listValue ?? []

        var fields = Fields()
        for entry in document.table("fields")?.entries ?? [] {
            guard fieldKeys.contains(entry.key) else {
                throw AgentRulesError.unknown(key: "[fields] \(entry.key)")
            }
            let paths = try entry.value.listValue.map {
                try AgentFieldPath.parse($0, key: "[fields] \(entry.key)")
            }
            switch entry.key {
            case "session": fields.session = paths
            case "message": fields.message = paths
            case "tool": fields.tool = paths
            case "error": fields.error = paths
            default: fields.summary = paths
            }
        }

        let hooks = try parseHooks(document)
        var notifications: [NotificationRule] = []
        for entry in document.table("notifications")?.entries ?? [] {
            guard let raw = entry.value.stringValue else {
                throw AgentRulesError.invalid(key: "[notifications] \(entry.key)",
                                              reason: "a notification maps to one state tag")
            }
            notifications.append(NotificationRule(
                prefix: entry.key,
                tag: try AgentStateTag.parse(raw, key: "[notifications] \(entry.key)")))
        }

        let install = try parseInstall(document)
        if let install {
            // An event the installer writes but no rule maps would be a hook process started on
            // every prompt whose report is then thrown away.
            for event in install.lifecycle + install.tools where hooks[event] == nil {
                throw AgentRulesError.invalid(key: "[install]",
                                              reason: "\(event) is installed but not mapped under [hooks]")
            }
        }
        return AgentRules(id: id, name: name, process: process, fields: fields, hooks: hooks,
                          notifications: notifications, install: install)
    }

    private static func rejectUnknownTables(_ document: AgentRulesTOML.Document) throws {
        for table in document.tables {
            guard !table.path.isEmpty else { continue }
            let root = table.path[0]
            guard tableNames.contains(root) else {
                throw AgentRulesError.unknown(key: "[\(table.name)]")
            }
            // Only `[hooks.<Event>]` and `[hooks.<Event>.values]` go deeper than one segment.
            if table.path.count > 1, root != "hooks" {
                throw AgentRulesError.unknown(key: "[\(table.name)]")
            }
            if table.path.count == 3, table.path[2] != "values" {
                throw AgentRulesError.unknown(key: "[\(table.name)]")
            }
        }
    }

    private static func parseHooks(_ document: AgentRulesTOML.Document) throws -> [String: HookRule] {
        var out: [String: HookRule] = [:]
        for entry in document.table("hooks")?.entries ?? [] {
            guard let raw = entry.value.stringValue else {
                throw AgentRulesError.invalid(key: "[hooks] \(entry.key)",
                                              reason: "an event maps to one state tag")
            }
            out[entry.key] = .plain(try AgentStateTag.parse(raw, key: "[hooks] \(entry.key)"))
        }
        // `[hooks.<Event>]`: a `field` plus a `[hooks.<Event>.values]` table.
        for table in document.tables where table.path.count == 2 && table.path[0] == "hooks" {
            let event = table.path[1]
            guard out[event] == nil else {
                throw AgentRulesError.invalid(key: "[hooks.\(event)]",
                                              reason: "\(event) is already mapped under [hooks]")
            }
            for entry in table.entries where entry.key != "field" {
                throw AgentRulesError.unknown(key: "[hooks.\(event)] \(entry.key)")
            }
            guard let raw = table.value("field")?.stringValue else {
                throw AgentRulesError.missing(key: "[hooks.\(event)] field")
            }
            let field = try AgentFieldPath.parse(raw, key: "[hooks.\(event)] field")
            guard let values = document.table("hooks.\(event).values") else {
                throw AgentRulesError.missing(key: "[hooks.\(event).values]")
            }
            var mapped: [String: AgentStateTag] = [:]
            for entry in values.entries {
                guard let tag = entry.value.stringValue else {
                    throw AgentRulesError.invalid(key: "[hooks.\(event).values] \(entry.key)",
                                                  reason: "a value maps to one state tag")
                }
                mapped[entry.key] = try AgentStateTag.parse(
                    tag, key: "[hooks.\(event).values] \(entry.key)")
            }
            guard !mapped.isEmpty else { throw AgentRulesError.missing(key: "[hooks.\(event).values]") }
            out[event] = .keyed(field: field, values: mapped)
        }
        // A `[hooks.<Event>.values]` whose `[hooks.<Event>]` never appeared.
        for table in document.tables where table.path.count == 3 && table.path[0] == "hooks" {
            guard case .keyed = out[table.path[1]] else {
                throw AgentRulesError.unknown(key: "[\(table.name)]")
            }
        }
        return out
    }

    private static func parseInstall(_ document: AgentRulesTOML.Document) throws -> Install? {
        guard let table = document.table("install") else { return nil }
        for entry in table.entries where !installKeys.contains(entry.key) {
            throw AgentRulesError.unknown(key: "[install] \(entry.key)")
        }
        guard let rawShape = table.value("shape")?.stringValue else {
            throw AgentRulesError.missing(key: "[install] shape")
        }
        guard let shape = Shape(rawValue: rawShape) else {
            throw AgentRulesError.invalid(key: "[install] shape",
                                          reason: "\(rawShape) is not claude / codex / gemini")
        }
        guard let config = table.value("config")?.stringValue, !config.isEmpty else {
            throw AgentRulesError.missing(key: "[install] config")
        }
        let lifecycle = table.value("lifecycle")?.listValue ?? []
        let tools = table.value("tools")?.listValue ?? []
        guard !lifecycle.isEmpty else { throw AgentRulesError.missing(key: "[install] lifecycle") }
        return Install(shape: shape, config: config, lifecycle: lifecycle, tools: tools)
    }

    // MARK: Reading a payload

    /// The state a hook payload maps to, or nil when this rule file says nothing about it.
    /// An unmapped event is **not** an error: agents add hooks, and hearing one we do not map is
    /// news about the agent being alive, which the reducer records without changing the state.
    func tag(for payload: AgentEventPayload) -> AgentStateTag? {
        switch hooks[payload.hookEventName] {
        case .plain(let tag): return tag
        case .keyed(let field, let values):
            guard let key = field.value(in: payload) else { return nil }
            return values[key]
        case nil: return nil
        }
    }

    /// The OSC fallback: the first prefix that matches the title, or the body when the title is
    /// empty (some emitters put everything in one field).
    func tag(title: String, body: String) -> AgentStateTag? {
        let subject = title.isEmpty ? body : title
        return notifications.first { subject.hasPrefix($0.prefix) }?.tag
    }
}
