import AppKit

/// **The red number on the Dock icon**: how many panes, across every screen, are waiting for the
/// user and have not been picked up yet (design §3.5, "Dock badge"; contract §10.5).
///
/// Panes, never notices. Two approval prompts stacked up in one pane are one pane the user has to
/// go to, and a badge that read `2` for a single pane would send them looking for a second one.
/// `NoticeCounts` already counts that way, which is why this sink is four lines long.
///
/// **`total`, not `interrupting`** (owner decision, superseding the plan §2.8 / Q6 reading). The
/// badge is a *passive* indicator, the same kind as the pane mark and the workspace pill: it counts
/// every pane that needs the user, and it keeps counting one whether or not the user has glanced at
/// it or typed into it. The first sessions with it showed why: an approval prompt is answered by
/// pressing Tab or an arrow to move between the options, and a badge that dropped on that first
/// keystroke vanished before the user had decided anything — so the one signal they were watching
/// for was gone exactly when they still needed it. Quieting is now the *banner's* business alone
/// (the banner is the interrupting sink — it pulls somebody out of another app, and it should stay
/// quiet while they sit in the pane); the badge tracks `needsUser` and clears only when the pane
/// stops needing the user (answered, acknowledged, or the agent moved on).
///
/// Only `.countsChanged` is acted on. Every post, every resolution **and every quieting** that
/// moves either number is followed by exactly one of those (the centre recomputes `counts` and only
/// dispatches when they really moved), so reacting to `.posted` or `.quieted` as well would set
/// the same label twice per notice. A quieting moves `interrupting` but not `total`, so it lands
/// here as a `.countsChanged` that leaves the badge exactly where it was — which is the point.
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
        // `counts.total` — panes that need the user, quieted or not, matching the pane mark and the
        // workspace pill. `nil`, not "0": an empty string still draws the red pill, and `0` draws a
        // zero in it.
        let label = counts.total == 0 ? nil : String(counts.total)
        DiagnosticLog.shared.note("badge", "Dock badge → \(label ?? "<cleared>") (needsUser panes=\(counts.total))")
        setBadge(label)
    }

    func clearAll() {
        setBadge(nil)
    }
}
