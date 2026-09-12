import AppKit
import GhosttyKit

// QuickTerm shim (M0): minimal stand-ins for the Ghostty app-side types that the GhosttyEmbed
// porting layer references. In M1 MainWindowController inherits from BaseTerminalController and
// takes over the SplitTree and the WM actions. Notes in docs/porting-notes.md.

class BaseTerminalController: NSWindowController {
    var surfaceTree: SplitTree<PaneView> = .init()
    /// The focused pane. Source of truth: the window's first responder is this pane or one of its
    /// descendants.
    var focusedPane: PaneView? { nil }
    /// Set only when the focused pane is a terminal: the engine side (`goto_split` and friends)
    /// only knows about terminals.
    var focusedSurface: Ghostty.SurfaceView? { focusedPane as? Ghostty.SurfaceView }
    var titleOverride: String?
    var commandPaletteIsShowing: Bool { false }
    /// Focus follows mouse (spec §4.2). M1's MainWindowController overrides this to true.
    var focusFollowsMouse: Bool { false }
    /// Hover occlusion test (spec v7 revision): at this window coordinate, is the pane covered by a
    /// floating layer or an overlay? MainWindowController overrides it with a geometry test against
    /// the model; the default answer is "nothing is occluded".
    func surfaceIsOccluded(_ pane: PaneView,
                           at locationInWindow: NSPoint) -> Bool { false }
    /// A pane (or its hosting view) became first responder. Single-focus invariant: the controller
    /// clears the stale `focused` flag left behind on every other pane.
    func paneDidBecomeFirstResponder(_ pane: PaneView) {}
    /// May a pane that was detached from the window and then re-attached grab focus back? Denied
    /// while the controller already has an explicit pending focus target of its own.
    func paneMayReclaimFocus(_ pane: PaneView) -> Bool { true }
    /// Can this controller still accept pane operations? A controller whose screen is already gone
    /// cannot. This is the fallback used to resolve the controller for a pane that has left its
    /// window; see `PaneView.controller`.
    var acceptsPaneOperations: Bool { true }
    /// Open a browser pane. target=_blank and window.open come through here too.
    @discardableResult
    func openBrowserPane(url: URL, from: PaneView?) -> BrowserPaneView? { nil }
    /// A link Cmd+clicked inside the terminal. true = we opened it in a browser pane; false = we are
    /// not taking it, hand it to the system default app.
    func openLink(_ url: URL, from: PaneView?) -> Bool { false }
    /// The pane asks to close itself, e.g. the page called window.close() on its last tab.
    func requestClosePane(_ pane: PaneView) {}
    func toggleBackgroundOpacity() {}
    func promptTabTitle() {}
    @objc func changeTabTitle(_ sender: Any?) {}
}

class TerminalWindow: NSWindow {}

/// Window state restoration errors (from Ghostty's TerminalRestorable.swift; M0 only needs the
/// type to exist).
enum TerminalRestoreError: Error {
    case identifierUnknown
    case delegateInvalid
    case windowDidNotLoad
    case stateDecodeFailed
    case surfaceHasNoWindows
}
