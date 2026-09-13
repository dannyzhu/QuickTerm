import AppKit

/// **The red number on the Dock icon**: how many panes, across every screen, are waiting for the
/// user (design §3.5, "Dock badge"; contract §10.5).
///
/// Panes, never notices. Two approval prompts stacked up in one pane are one pane the user has to
/// go to, and a badge that read `2` for a single pane would send them looking for a second one.
/// `NoticeCounts.total` already counts that way, which is why this sink is four lines long.
///
/// Only `.countsChanged` is acted on. Every post and every resolution that moves the number is
/// followed by exactly one of those (the centre recomputes `counts` and only dispatches when they
/// really moved), so reacting to `.posted` as well would set the same label twice per notice.
@MainActor
final class DockBadgeSink: NoticeSink {
    let sinkID = NoticeSinkID.dockBadge
    var isEnabled = true

    private let setBadge: (String?) -> Void

    /// The closure exists so the test host can assert the badge string without writing on the
    /// real Dock tile - a test that set `NSApp.dockTile.badgeLabel` would leave a red number on
    /// the icon of whatever ran the tests.
    ///
    /// Spelled `nil` rather than a default closure because a default argument expression is
    /// evaluated in a **nonisolated** context however isolated the initialiser is, and
    /// `NSApp.dockTile` is main-actor isolated. (`ControlPlaneSink` carries the same note.)
    init(setBadge: ((String?) -> Void)? = nil) {
        self.setBadge = setBadge ?? { NSApp.dockTile.badgeLabel = $0 }
    }

    func apply(_ change: NoticeChange) {
        guard case .countsChanged(let counts) = change else { return }
        // `nil`, not "0": an empty string still draws the red pill, and `0` draws a zero in it.
        setBadge(counts.total == 0 ? nil : String(counts.total))
    }

    func clearAll() {
        setBadge(nil)
    }
}
