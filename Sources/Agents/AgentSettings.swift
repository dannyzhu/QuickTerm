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
    /// Reserve a dedicated status strip at the top of every terminal pane.
    var infoStrip = true
    /// The strip's reserved height in pt (0 = reserve nothing, falling back to the old
    /// draw-in-the-padding behaviour). The band is reserved whenever it is > 0, whether or not
    /// there is anything to draw in it, so the terminal never moves when an agent comes or goes.
    var stripHeight = defaultStripHeight
    /// The strip's text size in pt.
    var stripFontSize = defaultStripFontSize
    /// The status bar's background for the four quiet states (idle / working / done / unknown),
    /// as `#rrggbb`. The schema has already validated and normalised it — nothing downstream
    /// re-checks, it only parses.
    var stripBackground = defaultStripBackground
    /// The background for the two states that mean "go and look": blocked and error.
    var stripAttention = defaultStripAttention
    /// The colour of the text on the bar, whichever background is under it.
    var stripText = defaultStripText

    /// The defaults, spelled once. They live here rather than only in `ConfigSchema` because two
    /// other places need the same literals — `ConfigStore.Settings`, and the view's fallback for
    /// the (impossible, but not worth crashing over) case of an unparsable colour reaching it —
    /// and three copies of `#414868` is exactly how a default drifts.
    ///
    /// Chosen off the default Tokyo Night palette: `muted` for the base so the bar reads as part
    /// of the chrome rather than as a second terminal, `red` for attention because that is the
    /// same colour the pane mark and the workspace pill already use for "a human is needed
    /// here", and `bright_foreground` for the text, which clears WCAG AA on both.
    static let defaultStripBackground = "#414868"
    static let defaultStripAttention = "#f7768e"
    static let defaultStripText = "#c0caf5"
    /// 16pt matches the tallest band the old in-padding bar was ever given; 11pt is its text size.
    static let defaultStripHeight = 16
    static let defaultStripFontSize = 11

    init() {}

    init(_ settings: ConfigStore.Settings) {
        detect = settings.agentsDetect
        enabled = settings.agentsEnabled
        hookDetail = settings.agentsHookDetail
        autoInstallHooks = settings.agentsAutoInstallHooks
        infoStrip = settings.agentsInfoStrip
        stripHeight = settings.agentsStripHeight
        stripFontSize = settings.agentsStripFontSize
        stripBackground = settings.agentsStripBackground
        stripAttention = settings.agentsStripAttention
        stripText = settings.agentsStripText
    }

    /// The enabled ids, trimmed, empties dropped — what the registry filters its loaded rules by.
    var enabledIDs: [String] {
        enabled.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    func isEnabled(_ id: String) -> Bool { detect && enabledIDs.contains(id) }
}
