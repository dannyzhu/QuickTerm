import Foundation

/// The `[agents]` group as the registry reads it (plan §2.10) — the same shape `NoticeSettings`
/// has, and for the same reason: one value type to hand the registry, one object a settings
/// window would bind to, and nothing anywhere else reading the config file itself.
struct AgentSettings: Equatable {
    /// Recognise agents at all. `false` stops the whole feature: no hook is accepted, no OSC is
    /// consumed, no scan runs.
    var detect = true
    /// The rule ids to use. A loaded rule whose id is not in here is inert.
    var enabled: [String] = ["claude-code", "codex", "gemini"]
    /// `lifecycle` | `tools` — which events the installer writes.
    var hookDetail = "lifecycle"
    /// `ask` | `always` | `never`.
    var autoInstallHooks = "ask"
    /// Draw the info strip in the pane's top padding.
    var infoStrip = true

    init() {}

    init(_ settings: ConfigStore.Settings) {
        detect = settings.agentsDetect
        enabled = settings.agentsEnabled
        hookDetail = settings.agentsHookDetail
        autoInstallHooks = settings.agentsAutoInstallHooks
        infoStrip = settings.agentsInfoStrip
    }

    /// The enabled ids, trimmed, empties dropped — what the registry filters its loaded rules by.
    var enabledIDs: [String] {
        enabled.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    func isEnabled(_ id: String) -> Bool { detect && enabledIDs.contains(id) }
}
