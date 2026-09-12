import XCTest
import AppKit
@testable import QuickTerm

final class KeybindingMapTests: XCTestCase {
    let map = KeybindingMap()

    func testSpec51TableFullyBound() {
        // spec §5.1, row by row (key name, modifiers, expected action).
        let table: [(String, NSEvent.ModifierFlags, WMAction)] = [
            ("return", .command, .newTerminal),
            ("b", [.command, .shift], .fileManager),
            ("b", .command, .newBrowser),
            ("k", .command, .keybindingHelp), ("k", [.command, .shift], .clearTerminal),
            ("r", .command, .webReload), ("l", [.command, .shift], .webFocusAddress),
            ("n", .command, .webNewTab), ("tab", .control, .webNextTab), ("tab", [.control, .shift], .webPrevTab),
            ("e", [.command, .shift], .webExtensions),
            ("w", .command, .closePane),
            ("left", .command, .focusLeft), ("right", .command, .focusRight),
            ("up", .command, .focusUp), ("down", .command, .focusDown),
            ("left", [.command, .shift], .swapLeft), ("right", [.command, .shift], .swapRight),
            ("up", [.command, .shift], .swapUp), ("down", [.command, .shift], .swapDown),
            ("j", .command, .toggleSplitDirection),
            ("f", .command, .toggleZoom),
            ("=", [.command, .control], .equalize),
            ("left", [.command, .control], .resizeLeft), ("right", [.command, .control], .resizeRight),
            ("up", [.command, .control], .resizeUp), ("down", [.command, .control], .resizeDown),
            ("tab", .option, .cyclePaneNext), ("tab", [.option, .shift], .cyclePanePrev),
            ("]", .command, .cyclePaneNext), ("[", .command, .cyclePanePrev),
        ]
        for (key, mods, expected) in table {
            let hit = map.action(key: key, modifiers: mods)
            XCTAssertEqual(hit?.action, expected, "\(key)+\(mods.rawValue) should be bound to \(expected)")
        }
    }

    /// Browser-only actions are consumed only while a browser pane has focus; with a terminal focused,
    /// Cmd+R / Cmd+= pass straight through.
    @MainActor
    func testBrowserOnlyActionsConsumedOnlyForBrowserPane() {
        XCTAssertTrue(WMAction.webReload.browserOnly)
        XCTAssertTrue(WMAction.webExtensions.browserOnly, "⌘⇧E is consumed only in a browser pane")
        XCTAssertFalse(WMAction.newBrowser.browserOnly)
        let browser = BrowserPaneView(url: nil)
        XCTAssertTrue(MainWindowController.consumes(.webReload, focusedPane: browser))
        XCTAssertFalse(MainWindowController.consumes(.webReload, focusedPane: nil))
        XCTAssertTrue(MainWindowController.consumes(.newBrowser, focusedPane: nil))
        XCTAssertTrue(MainWindowController.consumes(.closePane, focusedPane: browser))
        // Terminal-only actions: pass through when a browser pane, or no pane at all, has focus
        // (Cmd+Shift+K then belongs to the page).
        XCTAssertTrue(WMAction.clearTerminal.terminalOnly)
        XCTAssertFalse(MainWindowController.consumes(.clearTerminal, focusedPane: browser))
        XCTAssertFalse(MainWindowController.consumes(.clearTerminal, focusedPane: nil))
    }

    /// Fixed menu shortcuts: they must not fire after the action is unbound or rebound, must not fire for
    /// an action the focused pane does not consume, and must always fire when the item is clicked.
    @MainActor
    func testMenuShortcutRespectsKeymapAndConsumption() throws {
        let cmdShiftK = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.command, .shift], timestamp: 0, windowNumber: 0,
            context: nil, characters: "k", charactersIgnoringModifiers: "K", isARepeat: false, keyCode: 40))
        let bound = KeybindingMap()
        XCTAssertTrue(MainWindowController.menuShortcutAllowed(.clearTerminal, event: nil, keybindings: bound,
                                                                focusedPane: nil), "clicked with the mouse")
        XCTAssertFalse(MainWindowController.menuShortcutAllowed(.clearTerminal, event: cmdShiftK, keybindings: bound,
                                                                 focusedPane: BrowserPaneView(url: nil)),
                       "browser focused: clear-terminal must not run")
        let unbound = KeybindingMap(unbound: [.clearTerminal])
        XCTAssertFalse(MainWindowController.menuShortcutAllowed(.clearTerminal, event: cmdShiftK, keybindings: unbound,
                                                                 focusedPane: nil), "unbinding with none kills the menu shortcut")
        let rebound = KeybindingMap(overrides: [.clearTerminal: KeyCombo(key: "l", [.command, .shift])])
        XCTAssertFalse(MainWindowController.menuShortcutAllowed(.clearTerminal, event: cmdShiftK, keybindings: rebound,
                                                                 focusedPane: nil), "after a rebind the old combo no longer fires")
    }

    func testResizeWithShiftIsPrecise() {
        let hit = map.action(key: "left", modifiers: [.command, .control, .shift])
        XCTAssertEqual(hit?.action, .resizeLeft)
        XCTAssertEqual(hit?.precise, true, "Cmd+Ctrl+Shift+arrow = 10px fine adjustment")
    }

    func testTerminalKeysPassThrough() {
        // Never intercept terminal-level keys (spec §5.4).
        XCTAssertNil(map.action(key: "c", modifiers: .command), "Cmd+C must pass through")
        XCTAssertNil(map.action(key: "v", modifiers: .command), "Cmd+V must pass through")
        // Cmd+- / Cmd+= / Cmd+0 are browser-only actions now: the table still binds them, but with a
        // terminal focused the monitor does not consume them, so they reach the engine's font sizing.
        let minus = map.action(key: "-", modifiers: .command)
        XCTAssertEqual(minus?.action, .webZoomOut)
        XCTAssertFalse(MainWindowController.consumes(.webZoomOut, focusedPane: nil), "Cmd+- font size must reach the terminal")
        XCTAssertEqual(map.action(key: "escape", modifiers: .command)?.action, .exitFullscreen,
                       "Cmd+Esc = exit fullscreen (bare Esc is untouched)")
        XCTAssertNil(map.action(key: "escape", modifiers: []), "bare Esc must pass through to the terminal")
        XCTAssertEqual(map.action(key: ",", modifiers: .command)?.action, .openSettings,
                       "Cmd+, = open the config (intercepted in the WM layer, no longer passed down to ghostty's open_config)")
        XCTAssertEqual(map.action(key: "k", modifiers: .command)?.action, .keybindingHelp,
                       "Cmd+K = the cheat sheet (faithful to Omarchy, deviation note 2)")
        XCTAssertNil(map.action(key: "q", modifiers: .command), "Cmd+Q keeps its system behavior")
        XCTAssertNil(map.action(key: "w", modifiers: [.command, .shift]), "an undefined combo passes through")
    }

    /// Real key events (CGEvent-backed): Cmd+Shift+[ reports charactersIgnoringModifiers as "{", so
    /// normalization has to hand back the base key "[". Cmd+Shift+1 is the same story; it used to be a dead key.
    func testShiftedSymbolKeysNormalizeToBaseKey() throws {
        func real(_ keyCode: CGKeyCode, _ flags: CGEventFlags) throws -> NSEvent {
            let cg = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true))
            cg.flags = flags
            return try XCTUnwrap(NSEvent(cgEvent: cg))
        }
        let bracket = try real(33, [.maskCommand, .maskShift])   // "[" on a US layout
        XCTAssertEqual(KeybindingMap.normalizedKey(for: bracket), "[")
        XCTAssertEqual(map.action(for: bracket)?.action, .webBack)
        let one = try real(18, [.maskCommand, .maskShift])       // "1"
        XCTAssertEqual(KeybindingMap.normalizedKey(for: one), "1")
        XCTAssertEqual(map.action(for: one)?.action, .moveToWorkspace1)
        let letter = try real(11, [.maskCommand, .maskShift])    // "b"
        XCTAssertEqual(map.action(for: letter)?.action, .fileManager)
    }

    /// Edit-menu key-equivalent matching: an uppercase keyEquivalent implies Shift. The titles below are
    /// the macOS Edit menu's own, kept in Chinese as data ("重做" = Redo, "拷贝" = Copy).
    func testEditMenuKeyEquivalentMatching() {
        let redo = NSMenuItem(title: "重做", action: nil, keyEquivalent: "Z")
        let copy = NSMenuItem(title: "拷贝", action: nil, keyEquivalent: "c")
        XCTAssertTrue(EditMenuDelegate.matches(redo, key: "z", flags: [.command, .shift]))
        XCTAssertFalse(EditMenuDelegate.matches(redo, key: "z", flags: [.command]))
        XCTAssertTrue(EditMenuDelegate.matches(copy, key: "c", flags: [.command]))
        XCTAssertFalse(EditMenuDelegate.matches(copy, key: "c", flags: [.command, .shift]))
    }

    func testNSEventNormalization() throws {
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.command],
            timestamp: 0, windowNumber: 0, context: nil,
            characters: "w", charactersIgnoringModifiers: "w",
            isARepeat: false, keyCode: 13))
        XCTAssertEqual(KeybindingMap.normalizedKey(for: event), "w")
        let arrow = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.command],
            timestamp: 0, windowNumber: 0, context: nil,
            characters: "\u{F702}", charactersIgnoringModifiers: "\u{F702}",
            isARepeat: false, keyCode: 123))
        XCTAssertEqual(KeybindingMap.normalizedKey(for: arrow), "left")
    }
}
