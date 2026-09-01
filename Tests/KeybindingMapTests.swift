import XCTest
import AppKit
@testable import QuickTerm

final class KeybindingMapTests: XCTestCase {
    let map = KeybindingMap()

    func testSpec51TableFullyBound() {
        // spec §5.1 逐条（键名, 修饰键, 期望动作）
        let table: [(String, NSEvent.ModifierFlags, WMAction)] = [
            ("return", .command, .newTerminal),
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

    func testResizeWithShiftIsPrecise() {
        let hit = map.action(key: "left", modifiers: [.command, .control, .shift])
        XCTAssertEqual(hit?.action, .resizeLeft)
        XCTAssertEqual(hit?.precise, true, "Cmd+Ctrl+Shift+方向 = 10px 微调")
    }

    func testTerminalKeysPassThrough() {
        // 绝不拦截终端级键（spec §5.4）
        XCTAssertNil(map.action(key: "c", modifiers: .command), "Cmd+C 必须放行")
        XCTAssertNil(map.action(key: "v", modifiers: .command), "Cmd+V 必须放行")
        XCTAssertNil(map.action(key: "-", modifiers: .command), "Cmd+- 字号必须放行")
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
