import XCTest
import AppKit
@testable import QuickTerm

final class KeybindingMapTests: XCTestCase {
    let map = KeybindingMap()

    func testSpec51TableFullyBound() {
        // spec §5.1 逐条（键名, 修饰键, 期望动作）
        let table: [(String, NSEvent.ModifierFlags, WMAction)] = [
            ("return", .command, .newTerminal),
            ("b", [.command, .shift], .fileManager),
            ("b", .command, .newBrowser),
            ("k", .command, .keybindingHelp), ("k", [.command, .shift], .clearTerminal),
            ("r", .command, .webReload), ("l", [.command, .shift], .webFocusAddress),
            ("n", .command, .webNewTab), ("tab", .control, .webNextTab), ("tab", [.control, .shift], .webPrevTab),
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
            XCTAssertEqual(hit?.action, expected, "\(key)+\(mods.rawValue) 应绑定 \(expected)")
        }
    }

    /// 浏览器专属动作只在焦点是浏览器 pane 时消费；终端聚焦时 Cmd+R / Cmd+= 放行
    @MainActor
    func testBrowserOnlyActionsConsumedOnlyForBrowserPane() {
        XCTAssertTrue(WMAction.webReload.browserOnly)
        XCTAssertFalse(WMAction.newBrowser.browserOnly)
        let browser = BrowserPaneView(url: nil)
        XCTAssertTrue(MainWindowController.consumes(.webReload, focusedPane: browser))
        XCTAssertFalse(MainWindowController.consumes(.webReload, focusedPane: nil))
        XCTAssertTrue(MainWindowController.consumes(.newBrowser, focusedPane: nil))
        XCTAssertTrue(MainWindowController.consumes(.closePane, focusedPane: browser))
        // 终端专属：焦点在浏览器 / 无焦点 pane 时放行（Cmd+Shift+K 交给页面）
        XCTAssertTrue(WMAction.clearTerminal.terminalOnly)
        XCTAssertFalse(MainWindowController.consumes(.clearTerminal, focusedPane: browser))
        XCTAssertFalse(MainWindowController.consumes(.clearTerminal, focusedPane: nil))
    }

    /// 菜单固定快捷键：解绑 / 改键后不执行；焦点 pane 不消费的动作不执行；鼠标点菜单项始终执行
    @MainActor
    func testMenuShortcutRespectsKeymapAndConsumption() throws {
        let cmdShiftK = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.command, .shift], timestamp: 0, windowNumber: 0,
            context: nil, characters: "k", charactersIgnoringModifiers: "K", isARepeat: false, keyCode: 40))
        let bound = KeybindingMap()
        XCTAssertTrue(MainWindowController.menuShortcutAllowed(.clearTerminal, event: nil, keybindings: bound,
                                                                focusedPane: nil), "鼠标点菜单项")
        XCTAssertFalse(MainWindowController.menuShortcutAllowed(.clearTerminal, event: cmdShiftK, keybindings: bound,
                                                                 focusedPane: BrowserPaneView(url: nil)),
                       "焦点在浏览器：清屏不执行")
        let unbound = KeybindingMap(unbound: [.clearTerminal])
        XCTAssertFalse(MainWindowController.menuShortcutAllowed(.clearTerminal, event: cmdShiftK, keybindings: unbound,
                                                                 focusedPane: nil), "none 解绑后菜单快捷键失效")
        let rebound = KeybindingMap(overrides: [.clearTerminal: KeyCombo(key: "l", [.command, .shift])])
        XCTAssertFalse(MainWindowController.menuShortcutAllowed(.clearTerminal, event: cmdShiftK, keybindings: rebound,
                                                                 focusedPane: nil), "改键后原组合不再触发")
    }

    func testResizeWithShiftIsPrecise() {
        let hit = map.action(key: "left", modifiers: [.command, .control, .shift])
        XCTAssertEqual(hit?.action, .resizeLeft)
        XCTAssertEqual(hit?.precise, true, "Cmd+Ctrl+Shift+方向 = 10px 微调")
    }

    func testTerminalKeysPassThrough() {
        // 绝不拦截终端级键（spec §5.4）
        XCTAssertNil(map.action(key: "c", modifiers: .command), "Cmd+C 必须放行")
        XCTAssertNil(map.action(key: "v", modifiers: .command), "Cmd+V 必须放行")
        // Cmd+- / Cmd+= / Cmd+0 现在是浏览器专属动作：表里有绑定，但焦点在终端时监视器不消费（放行给引擎调字号）
        let minus = map.action(key: "-", modifiers: .command)
        XCTAssertEqual(minus?.action, .webZoomOut)
        XCTAssertFalse(MainWindowController.consumes(.webZoomOut, focusedPane: nil), "Cmd+- 字号必须放行给终端")
        XCTAssertEqual(map.action(key: "escape", modifiers: .command)?.action, .exitFullscreen,
                       "Cmd+Esc = 退出全屏（裸 Esc 不受影响）")
        XCTAssertNil(map.action(key: "escape", modifiers: []), "裸 Esc 必须放行给终端")
        XCTAssertEqual(map.action(key: ",", modifiers: .command)?.action, .openSettings,
                       "Cmd+, = 打开配置（WM 层拦截，不再穿透给 ghostty open_config）")
        XCTAssertEqual(map.action(key: "k", modifiers: .command)?.action, .keybindingHelp,
                       "Cmd+K = 速查表（忠实 Omarchy，偏移说明 2）")
        XCTAssertNil(map.action(key: "q", modifiers: .command), "Cmd+Q 系统行为")
        XCTAssertNil(map.action(key: "w", modifiers: [.command, .shift]), "未定义组合放行")
    }

    /// 真实按键（CGEvent 背书）：Cmd+Shift+[ 的 charactersIgnoringModifiers 是 "{"，
    /// 归一化必须给出基础键 "["；既有的 Cmd+Shift+1 同理（原先是死键）
    func testShiftedSymbolKeysNormalizeToBaseKey() throws {
        func real(_ keyCode: CGKeyCode, _ flags: CGEventFlags) throws -> NSEvent {
            let cg = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true))
            cg.flags = flags
            return try XCTUnwrap(NSEvent(cgEvent: cg))
        }
        let bracket = try real(33, [.maskCommand, .maskShift])   // US 布局 "["
        XCTAssertEqual(KeybindingMap.normalizedKey(for: bracket), "[")
        XCTAssertEqual(map.action(for: bracket)?.action, .webBack)
        let one = try real(18, [.maskCommand, .maskShift])       // "1"
        XCTAssertEqual(KeybindingMap.normalizedKey(for: one), "1")
        XCTAssertEqual(map.action(for: one)?.action, .moveToWorkspace1)
        let letter = try real(11, [.maskCommand, .maskShift])    // "b"
        XCTAssertEqual(map.action(for: letter)?.action, .fileManager)
    }

    /// Edit 菜单键等价匹配：大写 keyEquivalent 隐含 Shift
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
