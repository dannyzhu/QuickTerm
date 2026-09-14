import AppKit

/// **The red number on the Dock icon**: how many panes, across every screen, are waiting for the
/// user and have not been picked up yet (design §3.5, "Dock badge"; contract §10.5).
///
/// Panes, never notices. Two approval prompts stacked up in one pane are one pane the user has to
/// go to, and a badge that read `2` for a single pane would send them looking for a second one.
/// `NoticeCounts` already counts that way, which is why this sink is four lines long.
///
/// **`interrupting`, not `total`** (plan §2.8, owner decisions Q1(b) and Q6). The badge is one of
/// the two *interrupting* sinks: it is there to pull somebody out of another app. The moment they
/// focus the pane and type into it, that job is done — the alarm is quieted, this number drops it,
/// and the banner goes away with it — while the pane mark and the workspace pill keep reading
/// `needsUser` and stay up until the agent or its process confirms. A badge that kept counting a
/// pane the user is sitting in front of is a red number you learn to ignore.
///
/// Only `.countsChanged` is acted on. Every post, every resolution **and every quieting** that
/// moves the number is followed by exactly one of those (the centre recomputes `counts` and only
/// dispatches when they really moved), so reacting to `.posted` or `.quieted` as well would set
/// the same label twice per notice.
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
        self.setBadge = setBadge ?? { label in
            NSApp.dockTile.badgeLabel = label
            // Logged because the badge is the one surface that cannot be asserted from inside the
            // app: `badgeLabel` is a property the Dock reads, and whether the Dock then draws
            // anything is the Dock's business — it is not, as far as Apple documents, tied to the
            // notification authorization that the banners need, but the report that prompted this
            // line had a denied app showing no badge either, and there was no way to tell "we
            // never set it" from "we set it and the Dock ignored us". Now there is: one `log
            // stream --predicate 'subsystem == "dev.danny.quickterm"'` answers it.
            AppDelegate.logger.info("dock badge set to \(label ?? "<none>", privacy: .public)")
        }
    }

    func apply(_ change: NoticeChange) {
        guard case .countsChanged(let counts) = change else { return }
        // `nil`, not "0": an empty string still draws the red pill, and `0` draws a zero in it.
        setBadge(counts.interrupting == 0 ? nil : String(counts.interrupting))
    }

    func clearAll() {
        setBadge(nil)
    }
}
