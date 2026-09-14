import Foundation

/// **The whitelist an agent hook's JSON is reduced to** (plan §2.2).
///
/// A hook hands its agent's own payload to `quickterm agent-event` on stdin, and that payload is
/// whatever the agent felt like writing: Claude Code's `PreToolUse` carries the full `tool_input`
/// of a `Write` (the entire file), a `transcript_path` pointing at the conversation, the `cwd`.
/// None of that may cross into QuickTerm, and none of it may be reconstructed later — so the
/// reduction is a **whitelist of eight fields**, applied twice: once by the CLI before the
/// request is sent, and once again by the server on whatever it receives, so a hand-built
/// `--event` cannot smuggle more than a real hook could.
///
/// This file lives in `Sources/Control/Wire`, compiled into both the app and the `quickterm`
/// tool target: the CLI reduces, the app re-reduces, and there is one implementation of the rule.
///
/// The `CodingKeys` are the agents' own snake_case spellings, so a rule file's field path
/// (`$.tool_input.command`) reads the same words the agent's documentation does.
struct AgentEventPayload: Codable, Equatable {
    /// The hook that fired (`PreToolUse`, `SessionStart`, `BeforeTool`, …). The only required
    /// field: an event that does not say which event it is cannot be mapped by any rule file.
    var hookEventName: String
    /// Claude Code's / Gemini's `Notification` sub-kind (`permission_prompt`, `ToolPermission`).
    var notificationType: String?
    /// The agent's own session id, when it sends one — half of `NoticeOrigin`.
    var sessionID: String?
    /// A tool **name** (`Bash`, `Write`): payload-free, so it may go in a notice title.
    var toolName: String?
    var errorType: String?
    /// The agent's own sentence. Sensitive: it goes in a notice **body**, never in a title.
    var message: String?
    /// The string-valued top level of the agent's `tool_input`, clamped (see `reduce`).
    var toolInput: [String: String]?
    /// The same treatment for Gemini's `details`.
    var details: [String: String]?

    enum CodingKeys: String, CodingKey {
        case hookEventName = "hook_event_name"
        case notificationType = "notification_type"
        case sessionID = "session_id"
        case toolName = "tool_name"
        case errorType = "error_type"
        case message
        case toolInput = "tool_input"
        case details
    }

    /// How much of stdin the CLI reads, and the largest `event` argument the server accepts.
    /// The hook script never blocks an agent, so a payload larger than this is **cut**, not
    /// waited for; if the cut leaves invalid JSON the event is simply dropped.
    static let maxStdinBytes = 8192
    /// Every string field is clamped to this — the same ceiling a pane title has.
    static let maxFieldLength = TitleRules.maxLength
    /// At most this many keys survive inside `tool_input` / `details`.
    static let maxObjectKeys = 8

    init(hookEventName: String, notificationType: String? = nil, sessionID: String? = nil,
         toolName: String? = nil, errorType: String? = nil, message: String? = nil,
         toolInput: [String: String]? = nil, details: [String: String]? = nil) {
        self.hookEventName = hookEventName
        self.notificationType = notificationType
        self.sessionID = sessionID
        self.toolName = toolName
        self.errorType = errorType
        self.message = message
        self.toolInput = toolInput
        self.details = details
    }

    // MARK: Reduction

    /// One agent's raw hook JSON -> the whitelist, or nil when there is nothing usable in it.
    ///
    /// nil means **drop the event**: the bytes are not an object, or they name no hook event.
    /// Everything else is kept only if it is on the list above and only in the shape stated
    /// there — no `transcript_path`, no `cwd`, no nested bodies, no file contents.
    static func reduce(_ data: Data) -> AgentEventPayload? {
        let clipped = data.count > maxStdinBytes ? data.prefix(maxStdinBytes) : data[...]
        guard let any = try? JSONSerialization.jsonObject(with: Data(clipped)),
              let object = any as? [String: Any] else { return nil }
        guard let event = clamp(object["hook_event_name"]), !event.isEmpty else { return nil }
        return AgentEventPayload(
            hookEventName: event,
            notificationType: clampOptional(object["notification_type"]),
            sessionID: clampOptional(object["session_id"]),
            toolName: clampOptional(object["tool_name"]),
            errorType: clampOptional(object["error_type"]),
            message: clampOptional(object["message"]),
            toolInput: reduceObject(object["tool_input"]),
            details: reduceObject(object["details"]))
    }

    /// Re-reduce a payload that arrived **already decoded** — the server's second pass over an
    /// `--event` somebody may have hand-built. Same rules, applied to the same fields.
    static func reduce(_ payload: AgentEventPayload) -> AgentEventPayload? {
        let event = TitleRules.fromTypedInput(payload.hookEventName)
        guard !event.isEmpty else { return nil }
        return AgentEventPayload(
            hookEventName: event,
            notificationType: clampText(payload.notificationType),
            sessionID: clampText(payload.sessionID),
            toolName: clampText(payload.toolName),
            errorType: clampText(payload.errorType),
            message: clampText(payload.message),
            toolInput: payload.toolInput.flatMap { reduceObject($0) },
            details: payload.details.flatMap { reduceObject($0) })
    }

    /// `tool_input` / `details`: an object keeps only its **string-valued** top-level keys, each
    /// clamped, at most `maxObjectKeys` of them; a bare string becomes `["text": …]`; anything
    /// else (a number, an array, a nested object, null) is dropped whole.
    ///
    /// The keys kept are the first `maxObjectKeys` **by sorted name**, not by the order they
    /// appeared: `JSONSerialization` hands back an unordered dictionary, so file order is not
    /// available here, and sorted is at least the same answer on every run.
    private static func reduceObject(_ raw: Any?) -> [String: String]? {
        if let text = raw as? String {
            let clamped = TitleRules.fromTypedInput(text)
            return clamped.isEmpty ? nil : ["text": clamped]
        }
        guard let object = raw as? [String: Any] else { return nil }
        var out: [String: String] = [:]
        for key in object.keys.sorted() {
            guard out.count < maxObjectKeys else { break }
            guard let value = object[key] as? String else { continue }
            let clamped = TitleRules.fromTypedInput(value)
            guard !clamped.isEmpty else { continue }
            out[TitleRules.fromTypedInput(key)] = clamped
        }
        return out.isEmpty ? nil : out
    }

    private static func clamp(_ raw: Any?) -> String? {
        guard let text = raw as? String else { return nil }
        return TitleRules.fromTypedInput(text)
    }

    private static func clampOptional(_ raw: Any?) -> String? {
        guard let clamped = clamp(raw), !clamped.isEmpty else { return nil }
        return clamped
    }

    private static func clampText(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let clamped = TitleRules.fromTypedInput(raw)
        return clamped.isEmpty ? nil : clamped
    }

    // MARK: Field paths (the rule files' vocabulary)

    /// The one-segment field paths a rule file may name (`$.tool_name`). Declared here, beside
    /// the fields themselves, so a field added to the whitelist and a field a rule file can read
    /// cannot drift apart.
    static let scalarPaths = ["hook_event_name", "notification_type", "session_id",
                              "tool_name", "error_type", "message"]
    /// The two-segment roots (`$.tool_input.command`).
    static let objectPaths = ["tool_input", "details"]

    /// Evaluate a validated field path. `head` is one of `scalarPaths` (with `sub == nil`) or one
    /// of `objectPaths` (with a sub-key); anything else answers nil, which reads as "empty" and
    /// lets the next path in a rule file's array have its turn.
    func value(_ head: String, _ sub: String? = nil) -> String? {
        if let sub {
            switch head {
            case "tool_input": return toolInput?[sub]
            case "details": return details?[sub]
            default: return nil
            }
        }
        switch head {
        case "hook_event_name": return hookEventName
        case "notification_type": return notificationType
        case "session_id": return sessionID
        case "tool_name": return toolName
        case "error_type": return errorType
        case "message": return message
        default: return nil
        }
    }
}
