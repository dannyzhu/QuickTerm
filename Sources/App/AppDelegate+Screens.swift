import AppKit

/// Creating, placing, closing and moving "screens", plus the landing points for the Window menu's
/// actions (spec v9 §1.1-§1.3).
/// A "screen" is one window plus its own set of workspaces, and it is driven only from the menu bar
/// - there are no shortcuts, since Cmd+N is already taken.
/// (The whole extension is `@MainActor`: windows and `SessionStore` are both main-thread only.)
@MainActor
extension AppDelegate {
    /// Create a new screen. Its first terminal inherits the cwd of the source window's focused pane
    /// (the same rule a new terminal follows).
    /// With `restoring = true` no starter terminal is opened - the caller (`restoreSession`) pours
    /// the saved state in right afterwards.
    @discardableResult
    func newScreen(on screen: NSScreen? = nil, inheritingFrom pane: PaneView? = nil,
                   restoring: Bool = false, id: UUID = UUID(),
                   restoredFrame: CGRect? = nil) -> MainWindowController {
        let index = screens.nextIndex()
        let controller = MainWindowController(
            ghostty: ghostty, session: session,
            screen: screen, index: index, restoring: restoring,
            id: id, restoredFrame: restoredFrame,
            inheritedDirectory: pane?.workingDirectory)
        screens.add(controller)
        session.sessionStore.scheduleSave()
        return controller
    }

    /// One-shot restore (from the user, 2026-09-08): brings back every "screen", its panes and
    /// layout, each terminal pane's directory and the pages each browser pane had open, along with
    /// the display, the frame, fullscreen state and "show on all desktops".
    /// No saved state, a corrupt one, or an entirely empty one keeps the 1.5.x behavior: one new
    /// screen with one terminal.
    func restoreSession() {
        guard !Self.isRunningTests, let state = session.sessionStore.load() else {
            newScreen()
            return
        }
        restoreSession(from: state)
    }

    /// Pure orchestration - reading from disk and the test-host check stay in the layer above, so a
    /// test can feed in a `PersistedState` directly: per window resolve the display, create the
    /// screen, pour the state in, then order the windows front by the saved stacking order with the
    /// key screen last. Returns the controllers it created.
    @discardableResult
    func restoreSession(from state: PersistedState) -> [MainWindowController] {
        // The model is only half-built while the state is being poured in: one debounced save
        // landing mid-way would truncate the user's session.
        session?.sessionStore.beginRestore()
        defer { session?.sessionStore.endRestore() }
        var restored: [MainWindowController] = []
        for windowState in state.windows {
            // A missing display must not lose the window: fall back to the main screen and pull the
            // frame back into its visible area.
            let screen = SessionStore.resolveScreen(for: windowState.display)
            let controller = newScreen(on: screen, restoring: true, id: windowState.id,
                                       restoredFrame: windowState.frame)
            if !controller.restore(from: windowState) { controller.ensureStarterPane() }
            restored.append(controller)
        }
        guard let first = restored.first else { return [newScreen()] }
        // Stacking order: the ones further back in the saved order get orderFront first and the key
        // screen goes last - that is what restores who covers whom when three or more screens are
        // crowded onto the same display. A saved state without this order is an old one, and falls
        // back to the saved sequence, which matches the previous behavior.
        let key = restored.first { $0.windowID == state.keyWindowID } ?? first
        let rank = (state.stackingOrder ?? []).enumerated()
            .reduce(into: [UUID: Int]()) { $0[$1.element] = $1.offset }
        let others = restored.filter { $0 !== key }
            .sorted { (rank[$0.windowID] ?? Int.max) > (rank[$1.windowID] ?? Int.max) }
        for controller in others { controller.window?.orderFront(nil) }
        key.window?.makeKeyAndOrderFront(nil)
        return restored
    }

    /// Close a screen (confirming first when it still has live panes). Returns whether it actually
    /// closed.
    /// Closing the last screen quits the app, through
    /// applicationShouldTerminateAfterLastWindowClosed.
    /// - Parameter confirmed: the caller has already asked the user (the control plane's
    ///   confirmation gate is exactly one such ask).
    ///   **This escape hatch is required**: the `NSAlert.runModal()` inside `confirmCloseScreen()`
    ///   runs a nested run loop on the caller's stack, and a control command runs on the main
    ///   thread - so it would wedge itself, and the whole control service with it, while the user
    ///   stares at two identical confirmation dialogs.
    @discardableResult
    func closeScreen(_ controller: MainWindowController, confirmed: Bool = false) -> Bool {
        guard let window = controller.window else { return false }
        guard confirmed || controller.confirmCloseScreen() else { return false }
        // Closing the last screen means quitting: save first, because windowWillClose's teardown
        // empties the model, and by the time applicationWillTerminate runs there is no layout left
        // to save.
        if screens.controllers.count == 1 { session.sessionStore.saveNow() }
        // → windowWillClose: tears down monitors and observers, then drops the registry entry on
        // the next runloop turn.
        window.close()
        session.sessionStore.scheduleSave()
        return true
    }

    /// Move a screen to the given display.
    func moveScreen(_ controller: MainWindowController, to screen: NSScreen) {
        controller.move(to: screen)
        controller.window?.makeKeyAndOrderFront(nil)
        session.sessionStore.scheduleSave()   // new display: the next launch reopens here
    }

    /// The window has closed: drop the registry's strong reference (called by windowWillClose on
    /// the next runloop turn).
    func forgetScreen(_ controller: MainWindowController) {
        screens.remove(controller)
    }

    // MARK: Window menu actions (no shortcuts)

    @objc func newScreenAction(_ sender: Any?) {
        newScreen(inheritingFrom: screens.current?.focusedPane)
    }

    @objc func newScreenOnDisplay(_ sender: NSMenuItem) {
        guard let screen = Self.screen(forRepresentedObject: sender.representedObject) else { return }
        newScreen(on: screen, inheritingFrom: screens.current?.focusedPane)
    }

    @objc func moveScreenToDisplay(_ sender: NSMenuItem) {
        guard let controller = screens.key ?? screens.primary,
              let screen = Self.screen(forRepresentedObject: sender.representedObject) else { return }
        moveScreen(controller, to: screen)
    }

    /// A Space (virtual desktop) cannot be chosen through any public API, so the only thing that
    /// can honestly be offered is "show on all desktops".
    @objc func toggleJoinAllSpaces(_ sender: NSMenuItem) {
        guard let controller = screens.key ?? screens.primary else { return }
        controller.joinsAllSpaces.toggle()
        session.sessionStore.scheduleSave()
    }

    @objc func closeScreenAction(_ sender: Any?) {
        guard let controller = screens.key ?? screens.primary else { return }
        closeScreen(controller)
    }

    /// The display identifier carried on a menu item (a displayUUID string - NSScreen instances are
    /// replaced whenever the display configuration changes, so an instance cannot be stored).
    static func screen(forRepresentedObject object: Any?) -> NSScreen? {
        guard let uuid = object as? String else { return nil }
        return NSScreen.screens.first { $0.displayUUID?.uuidString == uuid }
    }
}

extension AppDelegate: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(moveScreenToDisplay(_:)), #selector(closeScreenAction(_:)):
            return screens.key != nil
        case #selector(toggleJoinAllSpaces(_:)):
            let controller = screens.key
            menuItem.state = controller?.joinsAllSpaces == true ? .on : .off
            return controller != nil
        default:
            return true
        }
    }
}

/// The two Window submenus, "New Screen on Display" and "Move This Screen to Display": the list of
/// displays changes as monitors are plugged and unplugged, so it is rebuilt every time the menu
/// opens (representedObject holds a displayUUID string, never an NSScreen instance).
final class DisplayMenuDelegate: NSObject, NSMenuDelegate {
    enum Mode {
        case newScreen
        case moveScreen
    }

    private let mode: Mode
    private weak var target: AppDelegate?

    init(mode: Mode, target: AppDelegate) {
        self.mode = mode
        self.target = target
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let current = target?.screens.current?.window?.screen
        let screens = NSScreen.screens
        guard !screens.isEmpty else {
            let item = menu.addItem(withTitle: L("window.display.none-available"), action: nil,
                                    keyEquivalent: "")
            item.isEnabled = false
            return
        }
        for (i, screen) in screens.enumerated() {
            let isCurrent = screen === current
            var title = screen.localizedName
            if title.isEmpty { title = L("window.display.unnamed", i + 1) }
            // Whole sentence, not a suffix: the marker sits elsewhere in other languages.
            if isCurrent { title = L("window.display.current", title) }
            let action = mode == .newScreen
                ? #selector(AppDelegate.newScreenOnDisplay(_:))
                : #selector(AppDelegate.moveScreenToDisplay(_:))
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = target
            item.representedObject = screen.displayUUID?.uuidString
            if mode == .moveScreen, isCurrent {
                // Already on this display: check it, and make it unclickable.
                item.state = .on
                item.action = nil
            }
            // With no displayUUID (a handful of virtual displays) the item has nowhere to land, so
            // disable it outright.
            if item.representedObject == nil, item.action != nil { item.action = nil }
        }
    }
}
