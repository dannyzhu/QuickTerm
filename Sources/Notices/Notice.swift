import Foundation

/// **The value types of the notification centre** (spec §3.5 and the Phase 1 API contract §10.2).
///
/// `import Foundation` only, deliberately: these types are the vocabulary four separate
/// implementers speak — the centre, the drawing sinks, the system-notification sink and the
/// control plane. Pulling AppKit in here would make them unavailable to anything that is not the
/// app, and the wire records the control plane builds are shaped from exactly these fields.
///
/// One notice is **(source, urgency, pane)**. That triple is the coalescing key, it is computed
/// here and never supplied by the poster — see `Notice.key(source:urgency:pane:)`.

/// How loudly a notice asks. `nil` (no live notice at all) sorts below both; `info < needsUser`.
///
/// `<` is written out by hand because Swift does not synthesise `Comparable` for an enum with raw
/// values — and the declaration order of the cases is not, on its own, a promise anybody may rely
/// on. Write the comparison and the order can never drift apart.
enum NoticeUrgency: String, Codable, Comparable {
    case info
    case needsUser = "needs-user"

    /// Rank with a hole at the bottom for "no live notice": that is what makes
    /// `PaneTransition.raised` answer correctly for none -> info as well as info -> needsUser.
    static func rank(_ urgency: NoticeUrgency?) -> Int {
        switch urgency {
        case .none: 0
        case .info: 1
        case .needsUser: 2
        }
    }

    static func < (lhs: NoticeUrgency, rhs: NoticeUrgency) -> Bool {
        rank(lhs) < rank(rhs)
    }
}

/// Who is speaking. `download` and `control` are reserved: they are part of the wire vocabulary
/// from the first release so that an agent branching on `source` never has to handle a spelling
/// that appeared later, but nothing in Phase 1 posts them.
enum NoticeSource: Hashable, Codable {
    /// An agent adapter id (Phase 2: `"claude-code"`).
    case agent(String)
    /// OSC 9 / 99 / 777 from whatever runs in the pane.
    case terminal
    /// `commandFinished` (OSC 133).
    case command
    /// BEL, and only with `[notifications] bell = "info"`.
    case bell
    /// Reserved: not wired in Phase 1.
    case download
    /// Reserved: not wired in Phase 1.
    case control
    case custom(String)

    /// The wire and coalescing spelling. **Stable**: agents branch on it, and it is half of
    /// every coalescing key, so changing a word here would silently split one pane's alarm into
    /// two.
    var id: String {
        switch self {
        case .agent(let name): "agent:\(name)"
        case .terminal: "terminal"
        case .command: "command"
        case .bell: "bell"
        case .download: "download"
        case .control: "control"
        case .custom(let name): "custom:\(name)"
        }
    }
}

/// Where the text came from. `.composed` means **QuickTerm wrote the sentence itself**; every
/// other case means the words are some program's own, which is what `bodySensitive` keys off.
enum NoticeEvidence: String, Codable {
    case hook
    case report
    case notification
    case process
    case composed
}

/// Why a notice stopped being live. The spelling is on the wire (`notice.resolved` events, the
/// activity log's outcome column), so these raw values are API.
enum NoticeResolution: String, Codable {
    /// Rule 1: the poster itself said the state changed. Only the lineage that posted may say so.
    case stateChanged = "state-changed"
    /// Rule 2: the user focused the pane and typed into it.
    case userActed = "user-acted"
    /// Rule 3: `quickterm notices ack`.
    case acknowledged
    /// A newer notice took the same key.
    case superseded
    /// The user is looking at the pane. **`info` notices only** — an approval prompt is not
    /// answered by looking at it.
    case paneFocused = "pane-focused"
    /// Rule 4: the pane is gone.
    case paneClosed = "pane-closed"
    /// The agent's **process** went away while its prompt was still live — the registry lost
    /// presence, or the pane's child exited (plan §1.4, §2.7).
    ///
    /// Appended, never reordered: this is a wire value. It is deliberately **not** origin-gated
    /// the way `stateChanged` is: the registry is in-process and the program really is gone. On
    /// the wire it tells an agent "the prompt went away because the program did", which
    /// `state-changed` would misstate.
    case agentGone = "agent-gone"
}

/// Who may resolve a notice as `.stateChanged` (spec §3.3).
///
/// Phase 1 never fills this in — nothing posts with an origin yet, so `permits` answers "yes" for
/// every Phase 1 notice. Phase 2's `agent-event` records the poster's process lineage and session
/// id here, and that is what stops an agent in pane A from **silencing** pane B's real alarm: a
/// forger can add a notice, it can never remove one.
struct NoticeOrigin: Equatable, Codable {
    /// The direct child of QuickTerm the poster descends from.
    var lineageRoot: pid_t?
    /// The agent's own session id, when a hook told us one.
    var sessionID: String?

    init(lineageRoot: pid_t? = nil, sessionID: String? = nil) {
        self.lineageRoot = lineageRoot
        self.sessionID = sessionID
    }

    /// Whether `other` is allowed to resolve a notice that recorded **this** origin.
    ///
    /// A notice with **no** stored origin is resolvable by anyone — that check lives at the call
    /// site (`notice.origin?.permits(supplied) ?? true`), because "there is nothing to match" is
    /// not a property of an origin that exists. Here the rule is: `other` must exist, and every
    /// field this origin actually recorded must be equal. A field we never learned (nil) does not
    /// constrain anything; a field we did learn constrains exactly.
    func permits(_ other: NoticeOrigin?) -> Bool {
        guard let other else { return false }
        if let lineageRoot, lineageRoot != other.lineageRoot { return false }
        if let sessionID, sessionID != other.sessionID { return false }
        return true
    }
}

/// One live or resolved notice.
///
/// `title` and `body` are **two fields with two rules** (spec §3.5): the title is payload-free by
/// construction — the agent, the state and a tool *name*, or a sentence QuickTerm composed — and
/// goes on screen anywhere. The body carries the program's own words and is sensitive by default:
/// redacted for token-less control-plane callers, kept out of the OSLog mirror, and out of the
/// system banner unless `[notifications] system-body = "always"`.
struct Notice: Identifiable, Equatable, Codable {
    let id: UUID
    /// `Notice.key(source:urgency:pane:)` — the coalescing key, computed by the centre.
    let key: String
    let source: NoticeSource
    let pane: UUID
    /// `MainWindowController.windowID` **at post time**.
    let screen: UUID
    /// Zero-based, **at post time**.
    let workspace: Int
    let urgency: NoticeUrgency
    let evidence: NoticeEvidence
    /// Payload-free, printable, at most `TitleRules.maxLength`. Sanitised by `NoticeCenter.post`,
    /// so every sink may draw it without filtering again.
    let title: String
    /// At most `Notice.maxBodyLength`, printable, newlines collapsed, nil when empty.
    let body: String?
    /// `false` only for text QuickTerm composed itself.
    let bodySensitive: Bool
    let origin: NoticeOrigin?
    let postedAt: Date
    /// The user focused this pane and typed into it while this alarm was still live, and the
    /// policy in force was `clearInterruptingSinks` (plan §2.8, owner decision Q1(b)): the
    /// **interrupting** sinks — the system banner and the Dock badge — let go, while the pane
    /// mark, the workspace pill count and this notice all stay until a hook or the process
    /// confirms. A quieted notice is still **live**; `notices ack` still resolves it and
    /// `notices list --needs-user` still lists it (the human started, the prompt may well still
    /// be pending).
    var quietedAt: Date?
    var resolvedAt: Date?
    var resolution: NoticeResolution?

    var isLive: Bool { resolvedAt == nil }
    /// Live and not quieted — the state the banner and the badge react to.
    var isInterrupting: Bool { isLive && quietedAt == nil }

    /// Where the notice was posted. **`NoticeCenter.location(of:)` is the current one**: a pane
    /// that has since moved to another workspace is counted where it is now, and this pair is
    /// what a history entry outliving its pane falls back to (plan §1.1).
    var location: NoticeLocation { NoticeLocation(screen: screen, workspace: workspace) }

    /// A body longer than this is cut. One kilobyte is far more than any banner or `notices list`
    /// row shows; the cap is here so a program that pipes a log file into an OSC 777 body cannot
    /// park a megabyte in the history ring.
    static let maxBodyLength = 1024

    /// **The coalescing key: (source, urgency, pane) and nothing else.**
    ///
    /// The urgency is part of it on purpose (spec §3.5 rule 3): an `info` post while a
    /// `needsUser` is live must land under its own key and leave the alarm alone. Fold the
    /// urgency out of this string and a "task complete" banner silently replaces "waiting for
    /// your approval".
    static func key(source: NoticeSource, urgency: NoticeUrgency, pane: UUID) -> String {
        "\(source.id)|\(urgency.rawValue)|\(pane.uuidString)"
    }

    // MARK: Sanitising

    /// A title as it may be stored: printable characters only, trimmed, cut to
    /// `TitleRules.maxLength`. **May come back empty** — the centre substitutes the localized
    /// fallback, which it can do and this file cannot (`Notice.swift` is Foundation-only so that
    /// the control plane's wire types can be built from it).
    static func sanitizedTitle(_ raw: String) -> String {
        TitleRules.fromTypedInput(raw)
    }

    /// A body as it may be stored: newlines collapsed to a single space **first** (so a
    /// two-line message keeps its word boundary instead of losing it to the printable filter),
    /// then the same printable rule as a title, trimmed, cut to `maxBodyLength`, and nil when
    /// nothing is left.
    static func sanitizedBody(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let flattened = raw.replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
        let printable = String(String.UnicodeScalarView(
            flattened.unicodeScalars.filter(TitleRules.isPrintable)))
        guard let trimmed = TitleRules.normalized(printable) else { return nil }
        return TitleRules.normalized(String(trimmed.prefix(maxBodyLength)))
    }
}

/// What a poster hands in. The centre computes `key`, `screen`, `workspace` and `postedAt`
/// itself: a poster that could choose its own coalescing key could split one pane's alarm in two.
struct NoticeRequest {
    var source: NoticeSource
    var pane: UUID
    var urgency: NoticeUrgency
    var evidence: NoticeEvidence
    var title: String
    var body: String?
    /// Sensitive by default. Pass `false` **only** for text QuickTerm composed itself.
    var bodySensitive: Bool
    var origin: NoticeOrigin?

    init(source: NoticeSource, pane: UUID, urgency: NoticeUrgency, evidence: NoticeEvidence,
         title: String, body: String? = nil, bodySensitive: Bool = true,
         origin: NoticeOrigin? = nil) {
        self.source = source
        self.pane = pane
        self.urgency = urgency
        self.evidence = evidence
        self.title = title
        self.body = body
        self.bodySensitive = bodySensitive
        self.origin = origin
    }
}

/// Where a pane is: which screen's window, and which zero-based workspace inside it.
struct NoticeLocation: Equatable {
    var screen: UUID
    var workspace: Int

    init(screen: UUID, workspace: Int) {
        self.screen = screen
        self.workspace = workspace
    }
}

/// **Panes with at least one live `needsUser`, and where each of them is.**
///
/// Panes, not notices (spec §3.5 rule 4, and the owner's decision in §9): two approval prompts in
/// one pane are one thing for the user to go and handle, so the Dock badge says 1. Keying the
/// dictionary by pane id is what makes that true by construction rather than by a careful
/// `Set(...)` somewhere downstream.
struct NoticeCounts: Equatable {
    var needsUser: [UUID: NoticeLocation]
    /// Panes holding at least one live `needs-user` notice that has **not** been quieted — the
    /// number the interrupting sinks (the Dock badge) show. `needsUser` above counts every live
    /// alarm whatever its quieted state, and that is what the pane mark and the workspace pill
    /// keep reading (owner decision Q6).
    var interrupting: Int

    init(needsUser: [UUID: NoticeLocation] = [:], interrupting: Int = 0) {
        self.needsUser = needsUser
        self.interrupting = interrupting
    }

    /// Across every screen — panes that need the user at all.
    var total: Int { needsUser.count }

    func count(screen: UUID) -> Int {
        needsUser.values.reduce(0) { $0 + ($1.screen == screen ? 1 : 0) }
    }

    func count(screen: UUID, workspace: Int) -> Int {
        needsUser.values.reduce(0) {
            $0 + ($1.screen == screen && $1.workspace == workspace ? 1 : 0)
        }
    }
}

/// The pane's **displayed** urgency before and after one change — the maximum over its live
/// notices, not the urgency of the notice that moved.
///
/// Alerting sinks react to this and never to a notice on its own: one banner per prompt however
/// many sources describe the same prompt (spec §3.5 rule 5).
struct PaneTransition: Equatable {
    let pane: UUID
    let before: NoticeUrgency?
    let after: NoticeUrgency?

    /// The pane got louder — none -> info, none -> needsUser, info -> needsUser.
    var raised: Bool { NoticeUrgency.rank(after) > NoticeUrgency.rank(before) }
    /// The pane went quiet: it had something live and now has nothing.
    var cleared: Bool { before != nil && after == nil }
}

/// **Whether the user is looking at this pane right now.** All four have to hold.
///
/// Note how this differs from `ScreenRegistry.controlCurrent`, which answers "where would a
/// command land": there the key window counts even while the app is in the background, because
/// something has to be the current screen. A notice asks a different question — is a human's
/// attention here — and a key window in a background app has nobody's attention. That is exactly
/// what `appActive && screenKey` says.
struct PaneActivity: Equatable {
    /// `NSApp.isActive`.
    var appActive: Bool
    /// The pane's window is the key window.
    var screenKey: Bool
    /// Its workspace is the screen's active one, and no *other* pane is zoomed over it.
    var workspaceVisible: Bool
    /// `controller.focusedPane === pane`.
    var focused: Bool

    init(appActive: Bool, screenKey: Bool, workspaceVisible: Bool, focused: Bool) {
        self.appActive = appActive
        self.screenKey = screenKey
        self.workspaceVisible = workspaceVisible
        self.focused = focused
    }

    var isActive: Bool { appActive && screenKey && workspaceVisible && focused }
}

/// What a sink is told. Every case carries the pane transition, so a sink never has to recompute
/// "was this pane already loud"; `PaneActivity?` is nil only when the pane could not be located
/// at that instant.
enum NoticeChange {
    case posted(Notice, PaneTransition, PaneActivity?)
    /// The user acted in the pane and this alarm stopped interrupting, without being resolved
    /// (plan §2.8). Only the interrupting sinks react: the banner is withdrawn, the badge drops
    /// this pane. The notice is still live.
    case quieted(Notice, PaneActivity?)
    case superseded(old: Notice, new: Notice, PaneTransition, PaneActivity?)
    case resolved(Notice, PaneTransition, PaneActivity?)
    /// Only for panes holding a live notice, and only when the activity really changed — the
    /// centre remembers the last one per pane so a sink never hears about a change that did not
    /// happen.
    case activityChanged(pane: UUID, PaneActivity)
    case countsChanged(NoticeCounts)
}
