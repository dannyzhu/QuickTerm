import Foundation

/// **The shapes of "a hook entry"** (plan §2.6).
///
/// Claude Code, Codex and Gemini keep hooks in the same overall structure — `hooks.<Event>` is an
/// array of *matcher groups*, each group holding a `hooks` array of entries — and differ only in
/// the details of one entry. kiro-cli (V3 engine) keeps a **flat** list instead: a standalone file
/// in `~/.kiro/hooks/` holding `{"version": "v1", "hooks": [{name, trigger, action, timeout}]}`,
/// one entry per trigger. Those differences are data, kept here, so that another agent is a rule
/// file plus one case, and a correction to Codex's key set is one value changed rather than a
/// branch hunted through an editor.
///
/// Written **without a matcher**, always: a matcher would mean "only for these tools", and the
/// whole point of a state hook is to hear about all of them.
struct HookConfigShape: Equatable {
    enum Layout: Equatable {
        /// `hooks.<Event>` -> `[{matcher?, hooks: [entry]}]` (Claude Code, Codex, Gemini).
        case grouped
        /// `hooks` -> `[{name, trigger: <Event>, action: {type, command}, timeout}]` (kiro-cli).
        case flat
    }

    var layout: Layout = .grouped
    /// The flat file's top-level `version`, written when the file does not name one yet.
    var version: String?
    /// Claude Code's `async: true` — the agent does not wait for our process at all. Neither Codex
    /// nor Gemini documents the key, and an unknown key can fail a settings file's validation, so
    /// it is written for Claude Code alone.
    var isAsync: Bool
    /// Gemini's and kiro-cli's schemas document a `name` on a hook object; Claude Code's and
    /// Codex's do not.
    var entryName: String?
    /// Claude Code, Codex and kiro-cli count seconds, Gemini counts milliseconds. Same five seconds.
    var timeout: Int

    static func of(_ shape: AgentRules.Shape) -> HookConfigShape {
        switch shape {
        case .claude: return HookConfigShape(isAsync: true, entryName: nil, timeout: 5)
        case .codex: return HookConfigShape(isAsync: false, entryName: nil, timeout: 5)
        case .gemini: return HookConfigShape(isAsync: false, entryName: "quickterm", timeout: 5000)
        case .kiro:
            return HookConfigShape(layout: .flat, version: "v1", isAsync: false, entryName: "quickterm",
                                   timeout: 5)
        }
    }

    /// One entry: the object that lives inside a group's `hooks` array.
    func entry(command: String) -> [String: Any] {
        var entry: [String: Any] = ["type": "command", "command": command, "timeout": timeout]
        if isAsync { entry["async"] = true }
        if let entryName { entry["name"] = entryName }
        return entry
    }

    /// One flat entry (kiro-cli): the trigger is part of the entry, and the command sits inside an
    /// `action` object. Our entries are found by `action.command`, with the same marker.
    func flatEntry(command: String, trigger: String) -> [String: Any] {
        var entry: [String: Any] = ["trigger": trigger, "timeout": timeout,
                                    "action": ["type": "command", "command": command] as [String: Any]]
        if let entryName { entry["name"] = entryName }
        return entry
    }
}
