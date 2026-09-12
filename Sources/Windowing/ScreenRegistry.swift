import AppKit

/// Registry of the multiple "screens" (spec v9 §1): the **only strong reference** to every
/// `MainWindowController` in the process.
/// One "screen" = one window + its own set of workspaces + its own Scratchpad / floating layer /
/// panels; anything that exists exactly once per process (the engine, ThemeManager, the config, the
/// extension manager) does not live here.
///
/// Routing rule: menu actions and App-level callbacks always go through `current` (the key window's
/// controller, falling back to the first one). Only paths that genuinely mean "the main window"
/// (the CLI `--open-browser`, archiving on quit) use `primary`.
final class ScreenRegistry {
    private(set) var controllers: [MainWindowController] = []
    /// Whether the first screen has already been created in this process (restoring the archive
    /// is `SessionStore`'s job; this only records the fact)
    private(set) var didCreateFirstScreen = false

    /// The first screen (its title is always exactly `QuickTerm`; where the archive and the CLI
    /// land)
    var primary: MainWindowController? { controllers.first }

    /// The controller of the key window **itself** (nil when the key window is a sheet or a panel,
    /// or when there is no key window at all).
    /// Destructive menu items such as "close screen" / "move to display" validate against this:
    /// with a sheet up we would rather have them disabled.
    var key: MainWindowController? {
        NSApp.keyWindow?.windowController as? MainWindowController
    }

    /// Where an action lands by default: the key window's controller, falling back to the first.
    /// When the key window is a sheet (a JS dialog, a file picker) or a popover (the downloads
    /// popover) it has no windowController of its own, so walk up sheetParent / parent to find the
    /// host window - otherwise the menu action silently lands on the first screen.
    var current: MainWindowController? {
        guard let keyWindow = NSApp.keyWindow else { return primary }
        var window: NSWindow? = keyWindow
        while let cur = window {
            if let controller = cur.windowController as? MainWindowController { return controller }
            window = cur.sheetParent ?? cur.parent
        }
        // While a sheet is up, the main window is still the host window.
        if let controller = NSApp.mainWindow?.windowController as? MainWindowController { return controller }
        return primary
    }

    /// Identity of the window that most recently became key (recorded in `windowDidBecomeKey`).
    /// For the control plane (IPC) only: when an agent drives us from Terminal.app or a background
    /// job, `NSApp.keyWindow` is nil and `current` silently falls back to the first screen - every
    /// command hits screen 1, and **this never reproduces in local testing**, because while testing
    /// locally QuickTerm is always the frontmost app. Only with this recorded can we answer
    /// honestly what "the current screen" is while the app is not in the foreground.
    private(set) var lastKeyWindowID: UUID?

    func recordKeyWindow(_ controller: MainWindowController) {
        lastKeyWindowID = controller.windowID
    }

    func controller(id: UUID) -> MainWindowController? {
        controllers.first { $0.windowID == id }
    }

    /// One-based screen number (= the number in the window title)
    func controller(screenNumber: Int) -> MainWindowController? {
        controllers.first { $0.screenIndex + 1 == screenNumber }
    }

    /// The control plane's "current screen" (deliberately different from `current`, which is what
    /// menu actions use): the key window only counts when the app really is in the foreground,
    /// otherwise use the screen that was key most recently, and only then fall back to primary.
    /// The full order is in the docs: an explicit -t -> the caller's own pane -> this property ->
    /// primary.
    var controlCurrent: MainWindowController? {
        if NSApp.isActive, let key = current { return key }
        if let id = lastKeyWindowID, let controller = controller(id: id) { return controller }
        return primary
    }

    /// Iteration order with the current screen first (used when the extension host aggregates
    /// across screens)
    var orderedByKeyFirst: [MainWindowController] {
        guard let current else { return controllers }
        return [current] + controllers.filter { $0 !== current }
    }

    /// Every pane on every screen (used to resolve a drop by UUID and to count panes for the quit
    /// confirmation)
    var allPanes: [PaneView] { controllers.flatMap(\.allPanes) }

    /// Reuse the lowest free index: 0 -> the title `QuickTerm`, then `QuickTerm 2` and so on.
    /// (Close screen 2, create a new one, and it is called `QuickTerm 2` again, so the numbers in
    /// the Window menu do not creep upward forever.)
    func nextIndex() -> Int {
        let used = Set(controllers.map(\.screenIndex))
        var i = 0
        while used.contains(i) { i += 1 }
        return i
    }

    func add(_ controller: MainWindowController) {
        guard !controllers.contains(where: { $0 === controller }) else { return }
        controllers.append(controller)
        didCreateFirstScreen = true
        ControlEventBus.noteChange()   // screen.opened
    }

    func remove(_ controller: MainWindowController) {
        controllers.removeAll { $0 === controller }
        ControlEventBus.noteChange()   // screen.closed
    }

    /// Screen title: the first one must be exactly `QuickTerm` (EngineSmokeTests finds the window
    /// by title)
    static func title(forIndex index: Int) -> String {
        index == 0 ? "QuickTerm" : "QuickTerm \(index + 1)"
    }
}

/// App-level host for browser extensions: aggregates the browser panes of every screen into the
/// "set of windows" an extension sees.
/// Back when this was a single weak pointer, only the most recently created window was visible to
/// extensions (BrowserExtensionManager.host is weak, so AppDelegate has to hold this object
/// strongly). The protocol signatures are unchanged, so the stubs in the tests are unaffected.
final class AppBrowserExtensionHost: BrowserExtensionHost {
    private let registry: ScreenRegistry

    init(registry: ScreenRegistry) {
        self.registry = registry
    }

    var browserPanes: [BrowserPaneView] {
        registry.orderedByKeyFirst.flatMap(\.browserPanes)
    }

    /// Take it from the key window (spec v9 §1.4): its first responder first, then the pane that
    /// window activated most recently.
    /// A non-key window's first responder is just leftover focus (it receives no keyboard events)
    /// and must not be treated as "the focused window" - otherwise, while the key screen has focus
    /// on a terminal, an extension would open its options page or a new tab on another display.
    /// Only when the key screen has no browser pane at all do we fall back to the globally most
    /// recently activated one.
    var focusedBrowserPane: BrowserPaneView? {
        if let pane = registry.current?.focusedBrowserPane { return pane }
        return registry.controllers.compactMap { $0.mostRecentBrowserPaneAnywhere() }
            .max { $0.lastActivatedAt < $1.lastActivatedAt }
    }

    /// An extension's windows.create: opens on the key window (falling back to the first screen)
    @discardableResult
    func openBrowserWindow(url: URL?) -> BrowserPaneView? {
        registry.current?.openBrowserWindow(url: url)
    }
}
