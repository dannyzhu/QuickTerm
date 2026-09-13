import AppKit

/// **Taking the user to the pane a notice is about** (design §3.5 "System notification", contract
/// §10.7).
///
/// A click on a banner is navigation, never acknowledgement: this brings the pane in front of the
/// user and nothing more - the notice stays live until the user actually acts on it, because with
/// two panes blocked, clicking A and being pulled away must leave A marked.
extension MainWindowController {
    /// Put `pane` in front of the user: this screen's window key, this workspace visible, this
    /// pane focused, the app frontmost.
    ///
    /// The four steps are exactly the four clauses of `PaneActivity`, in the order that makes each
    /// one stick:
    /// 1. `flushPendingCloses()` first - a pane that is fading out is still in the layout, and
    ///    switching or focusing around it lands on a slot that is about to disappear;
    /// 2. the workspace, before anything about focus: `requestFocus` on a pane in a workspace that
    ///    is not on screen hands first responder to a view that is not mounted;
    /// 3. the zoom, because a zoomed pane covers every other tile in its workspace - "visible"
    ///    means visible, not "its workspace is active";
    /// 4. key window, then activation, then focus. Focus last: `switchWorkspace` re-focuses
    ///    whatever was focused before, so asking earlier gets overwritten.
    ///
    /// **No second focus path.** `requestFocus(to:)` is the one road to a focused pane in this
    /// app - it records the intent, waits for the mount and verifies after the layout animation -
    /// and a notice click is not special enough to deserve its own.
    func reveal(_ pane: PaneView, in workspace: Int) {
        guard model.layouts.indices.contains(workspace) else { return }
        flushPendingCloses()
        if model.activeIndex != workspace { switchWorkspace(workspace) }
        if zoomHides(pane, in: workspace) { clearZoom() }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        requestFocus(to: pane)
    }

    /// Whether something else being zoomed in that workspace is covering this pane.
    ///
    /// The floating clause is the one that is easy to miss: the floating layer draws **above** the
    /// zoomed tile, so a floating pane is already visible and un-zooming would rearrange the
    /// user's screen for nothing. Same reading as `NoticeLocator.activity`'s `workspaceVisible`,
    /// deliberately - "can the user see it" has to mean one thing in this app.
    private func zoomHides(_ pane: PaneView, in workspace: Int) -> Bool {
        guard let zoomed = ControlStateEncoder.zoomedPaneID(in: model.layouts[workspace]),
              zoomed != pane.id else { return false }
        guard model.floatings.indices.contains(workspace) else { return true }
        return !model.floatings[workspace].contains { $0.pane.id == pane.id }
    }
}
