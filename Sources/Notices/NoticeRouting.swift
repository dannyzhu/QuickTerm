import AppKit

/// **What a click on a banner does** (design §3.5, contract §10.7): take the user to the pane the
/// notice is about, and nothing else.
///
/// Navigation, never acknowledgement - the notice stays live. With two panes blocked, clicking A's
/// banner and then being pulled into a meeting must leave A still marked, or the second alarm
/// silently becomes the only one anybody ever sees.
@MainActor
enum NoticeRouting {
    /// How long the routed pane keeps focus against focus-follows-mouse.
    ///
    /// The banner is drawn at the top right of the screen; after the click the cursor is parked
    /// there, which is over *some other pane* of the window that is about to come forward. With
    /// `focus-follows-mouse` on, the first twitch of the mouse would hand focus straight back to
    /// whatever sits under the pointer - i.e. the click would take the user to the pane and then
    /// take it away again. Three seconds is long enough to move the mouse deliberately and short
    /// enough that nobody notices the hold.
    static let hoverFocusHold: TimeInterval = 3

    /// Activate the app, make the pane's screen key, switch to its workspace, focus it.
    /// `false` = no screen has that pane any more (it closed while the banner was on screen); the
    /// caller's job is then to do nothing at all, never to fall back to some other pane.
    @discardableResult
    static func reveal(pane: UUID, locator: NoticeLocating) -> Bool {
        guard let located = locator.locate(pane) else { return false }
        located.controller.reveal(located.pane, in: located.workspace)
        located.controller.holdFocus(on: located.pane, for: hoverFocusHold)
        return true
    }
}
