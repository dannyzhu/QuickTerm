import AppKit

/// The main menu, built in code: the conventional macOS items plus a visible registry of the WM
/// actions and their shortcuts.
/// Actual key presses are consumed first by MainWindowController's local monitor; clicking a menu
/// item goes through the actions here.
enum MainMenu {
    /// Rebuild the whole main menu when the language changes. An NSMenuItem title is a
    /// **value**, not a binding: once installed, a menu keeps showing the old language until
    /// something rebuilds it. The observer lives here rather than in AppDelegate — whoever
    /// builds the menu owns keeping it in the current language.
    private static var languageObserver: Any?
    /// The delegate of the last install, reused to rebuild on a language change.
    private static weak var installedDelegate: AppDelegate?

    static func install(delegate: AppDelegate) {
        installedDelegate = delegate
        if languageObserver == nil {
            languageObserver = NotificationCenter.default.addObserver(
                forName: Localization.didChangeNotification, object: nil, queue: .main
            ) { _ in
                guard let delegate = installedDelegate else { return }
                install(delegate: delegate)
            }
        }
        // The two display submenu delegates are re-registered on every rebuild; the old ones
        // must not pile up.
        displayDelegates.removeAll()

        let main = NSMenu()

        // App menu
        let appItem = main.addItem(withTitle: "QuickTerm", action: nil, keyEquivalent: "")
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: L("menu.app.about"),
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        // The trick VS Code's `code` uses: symlink the bundled quickterm into PATH. It never asks
        // for an admin password.
        let installItem = appMenu.addItem(withTitle: L("menu.app.install-cli"),
                                          action: #selector(AppDelegate.installCLIAction(_:)),
                                          keyEquivalent: "")
        installItem.target = delegate
        // The control plane runs **silently** (reads need no confirmation, mutations put up no
        // dialog), and the precondition for that silence is being auditable afterwards.
        // The flash in the status bar covers "what just happened"; this covers "what has happened
        // at all".
        let logItem = appMenu.addItem(withTitle: L("menu.app.control-activity"),
                                      action: #selector(AppDelegate.controlActivityAction(_:)),
                                      keyEquivalent: "")
        logItem.target = delegate
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L("menu.app.hide"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: L("menu.app.quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.setSubmenu(appMenu, for: appItem)

        // Edit menu: Cmd+C/V/X/A/Z for AppKit controls (browser panes, the address bar, file
        // pickers) is routed through menu key equivalents; a terminal pane handles its bound keys
        // itself in performKeyEquivalent and is unaffected.
        let editItem = main.addItem(withTitle: L("menu.edit"), action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: L("menu.edit"))
        editMenu.addItem(withTitle: L("menu.edit.undo"), action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: L("menu.edit.redo"), action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: L("menu.edit.cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: L("menu.edit.copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: L("menu.edit.paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: L("menu.edit.select-all"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.delegate = EditMenuDelegate.shared
        main.setSubmenu(editMenu, for: editItem)

        // Shell menu
        let shellItem = main.addItem(withTitle: L("menu.shell"), action: nil, keyEquivalent: "")
        let shellMenu = NSMenu(title: L("menu.shell"))
        shellMenu.addItem(wm(.newTerminal, title: L("menu.shell.new-terminal"), key: "\r", delegate: delegate))
        shellMenu.addItem(wm(.fileManager, title: L("menu.shell.file-manager"), key: "b", modifiers: [.command, .shift], delegate: delegate))
        shellMenu.addItem(wm(.newBrowser, title: L("menu.shell.new-browser"), key: "b", delegate: delegate))
        shellMenu.addItem(wm(.clearTerminal, title: L("menu.shell.clear-terminal"), key: "k", modifiers: [.command, .shift], delegate: delegate))
        shellMenu.addItem(wm(.closePane, title: L("menu.shell.close-pane"), key: "w", delegate: delegate))
        main.setSubmenu(shellMenu, for: shellItem)

        // Pane menu
        let paneItem = main.addItem(withTitle: L("menu.pane"), action: nil, keyEquivalent: "")
        let paneMenu = NSMenu(title: L("menu.pane"))
        paneMenu.addItem(wm(.focusLeft, title: L("menu.pane.focus-left"), key: String(UnicodeScalar(NSLeftArrowFunctionKey)!), delegate: delegate))
        paneMenu.addItem(wm(.focusRight, title: L("menu.pane.focus-right"), key: String(UnicodeScalar(NSRightArrowFunctionKey)!), delegate: delegate))
        paneMenu.addItem(wm(.focusUp, title: L("menu.pane.focus-up"), key: String(UnicodeScalar(NSUpArrowFunctionKey)!), delegate: delegate))
        paneMenu.addItem(wm(.focusDown, title: L("menu.pane.focus-down"), key: String(UnicodeScalar(NSDownArrowFunctionKey)!), delegate: delegate))
        paneMenu.addItem(.separator())
        paneMenu.addItem(wm(.toggleSplitDirection, title: L("menu.pane.toggle-split-direction"), key: "j", delegate: delegate))
        paneMenu.addItem(wm(.toggleZoom, title: L("menu.pane.toggle-zoom"), key: "f", delegate: delegate))
        paneMenu.addItem(wm(.equalize, title: L("menu.pane.equalize"), key: "=", modifiers: [.command, .control], delegate: delegate))
        main.setSubmenu(paneMenu, for: paneItem)

        // Window menu (the system-standard one; AppKit appends the window list at the end itself).
        // Multiple "screens" are driven only from here, and none of it gets a shortcut: Cmd+N is
        // already taken by the system and by habit, and the user explicitly asked for no bindings.
        let windowItem = main.addItem(withTitle: L("menu.window"), action: nil, keyEquivalent: "")
        let windowMenu = NSMenu(title: L("menu.window"))
        windowMenu.addItem(withTitle: L("menu.window.new-screen"),
                           action: #selector(AppDelegate.newScreenAction(_:)), keyEquivalent: "")
            .target = delegate
        let newOnItem = windowMenu.addItem(withTitle: L("menu.window.new-screen-on-display"), action: nil, keyEquivalent: "")
        let newOnMenu = NSMenu(title: L("menu.window.new-screen-on-display"))
        newOnMenu.delegate = newScreenDisplayDelegate(for: delegate)
        windowMenu.setSubmenu(newOnMenu, for: newOnItem)
        let moveItem = windowMenu.addItem(withTitle: L("menu.window.move-screen-to-display"), action: nil, keyEquivalent: "")
        let moveMenu = NSMenu(title: L("menu.window.move-screen-to-display"))
        moveMenu.delegate = moveScreenDisplayDelegate(for: delegate)
        windowMenu.setSubmenu(moveMenu, for: moveItem)
        windowMenu.addItem(withTitle: L("menu.window.join-all-spaces"),
                           action: #selector(AppDelegate.toggleJoinAllSpaces(_:)), keyEquivalent: "")
            .target = delegate
        windowMenu.addItem(withTitle: L("menu.window.close-screen"),
                           action: #selector(AppDelegate.closeScreenAction(_:)), keyEquivalent: "")
            .target = delegate
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: L("menu.window.minimize"), action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: L("menu.window.zoom"), action: #selector(NSWindow.zoom(_:)), keyEquivalent: "")
        windowMenu.addItem(withTitle: L("menu.window.bring-all-to-front"),
                           action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        main.setSubmenu(windowMenu, for: windowItem)
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = main
    }

    /// The delegates for the two display submenus: the lists change as monitors come and go and are
    /// rebuilt on every open. They have to be held strongly, since NSMenu.delegate is weak.
    private static var displayDelegates: [DisplayMenuDelegate] = []

    private static func newScreenDisplayDelegate(for delegate: AppDelegate) -> DisplayMenuDelegate {
        let d = DisplayMenuDelegate(mode: .newScreen, target: delegate)
        displayDelegates.append(d)
        return d
    }

    private static func moveScreenDisplayDelegate(for delegate: AppDelegate) -> DisplayMenuDelegate {
        let d = DisplayMenuDelegate(mode: .moveScreen, target: delegate)
        displayDelegates.append(d)
        return d
    }

    private static func wm(_ action: WMAction, title: String, key: String,
                           modifiers: NSEvent.ModifierFlags = .command,
                           delegate: AppDelegate) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(AppDelegate.performWMAction(_:)), keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = delegate
        item.representedObject = action.rawValue
        return item
    }
}

extension AppDelegate {
    @objc func performWMAction(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let action = WMAction(rawValue: raw), let controller else { return }
        // When triggered by a key equivalent (currentEvent is a keyDown), [keybinds] is the
        // authority: if the binding was removed or remapped, or the focused pane does not consume
        // this action (clear-screen while focus sits in a browser), do not run it and hand the key
        // back to the focused terminal. Clicking the item with the mouse always runs it - the
        // shortcut shown in the menu is only a hint.
        let event = NSApp.currentEvent
        guard MainWindowController.menuShortcutAllowed(action, event: event, keybindings: controller.keybindings,
                                                       focusedPane: controller.focusedPane) else {
            if let event, let surface = event.window?.firstResponder as? Ghostty.SurfaceView {
                surface.keyDown(with: event)
            }
            return
        }
        controller.perform(action)
    }
}

/// The Edit menu's key equivalents are claimed only when focus is on an AppKit text or web control,
/// never when it is on a terminal pane - otherwise keys the engine has no binding for, like
/// Cmd+X / Cmd+Z / Cmd+A, get swallowed by the (disabled) menu item with a beep and never reach the
/// terminal (apps speaking the kitty keyboard protocol, neovim among them, do receive super+x).
final class EditMenuDelegate: NSObject, NSMenuDelegate {
    static let shared = EditMenuDelegate()

    func menuHasKeyEquivalent(_ menu: NSMenu, for event: NSEvent,
                              target: AutoreleasingUnsafeMutablePointer<AnyObject?>?,
                              action: UnsafeMutablePointer<Selector?>?) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let key = (event.charactersIgnoringModifiers ?? "").lowercased()
        guard let item = menu.items.first(where: { Self.matches($0, key: key, flags: flags) }) else { return false }
        // Returning false does not stop AppKit from continuing to enumerate menu items (verified
        // with a probe: a disabled item still consumes the key and beeps).
        // So when focus is on a terminal, hand back an explicit target/action that forwards this
        // key press verbatim to the terminal's keyDown.
        if let surface = (event.window ?? NSApp.keyWindow)?.firstResponder as? Ghostty.SurfaceView {
            target?.pointee = surface
            action?.pointee = #selector(Ghostty.SurfaceView.quicktermForwardMenuKey(_:))
            return true
        }
        target?.pointee = item.target
        action?.pointee = item.action
        return true
    }

    /// Matching a menu item's key equivalent: an uppercase keyEquivalent implies Shift (an AppKit
    /// convention).
    static func matches(_ item: NSMenuItem, key: String, flags: NSEvent.ModifierFlags) -> Bool {
        guard !item.keyEquivalent.isEmpty else { return false }
        var required = item.keyEquivalentModifierMask
        if item.keyEquivalent != item.keyEquivalent.lowercased() { required.insert(.shift) }
        return item.keyEquivalent.lowercased() == key && required == flags
    }
}

extension Ghostty.SurfaceView {
    /// Where an Edit menu key equivalent lands while a terminal is focused: hand the current key
    /// event back to the terminal (apps speaking the kitty keyboard protocol then receive
    /// super+x/z).
    @objc func quicktermForwardMenuKey(_ sender: Any?) {
        guard let event = NSApp.currentEvent, event.type == .keyDown else { return }
        keyDown(with: event)
    }
}
