import Foundation

/// **The three shapes of "a hook entry"** (plan §2.6).
///
/// All three agents keep hooks in the same overall structure — `hooks.<Event>` is an array of
/// *matcher groups*, each group holding a `hooks` array of entries — and differ only in the
/// details of one entry. Those differences are data, kept here, so that a fourth agent is a rule
/// file plus one case, and a correction to Codex's key set is one value changed rather than a
/// branch hunted through an editor.
///
/// Written **without a matcher**, always: a matcher would mean "only for these tools", and the
/// whole point of a state hook is to hear about all of them.
struct HookConfigShape: Equatable {
    /// Claude Code's `async: true` — the agent does not wait for our process at all. Neither Codex
    /// nor Gemini documents the key, and an unknown key can fail a settings file's validation, so
    /// it is written for Claude Code alone.
    var isAsync: Bool
    /// Gemini's schema documents a `name` on a hook object; the other two do not.
    var entryName: String?
    /// Claude Code and Codex count seconds, Gemini counts milliseconds. Same five seconds.
    var timeout: Int

    static func of(_ shape: AgentRules.Shape) -> HookConfigShape {
        switch shape {
        case .claude: return HookConfigShape(isAsync: true, entryName: nil, timeout: 5)
        case .codex: return HookConfigShape(isAsync: false, entryName: nil, timeout: 5)
        case .gemini: return HookConfigShape(isAsync: false, entryName: "quickterm", timeout: 5000)
        }
    }

    /// One entry: the object that lives inside a group's `hooks` array.
    func entry(command: String) -> [String: Any] {
        var entry: [String: Any] = ["type": "command", "command": command, "timeout": timeout]
        if isAsync { entry["async"] = true }
        if let entryName { entry["name"] = entryName }
        return entry
    }
}
