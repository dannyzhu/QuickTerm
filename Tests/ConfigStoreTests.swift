import XCTest
import AppKit
@testable import QuickTerm

final class ConfigStoreTests: XCTestCase {
    func testParseFullConfig() {
        let toml = """
        theme = "nord"    # 注释
        workspaces = 8

        [keybinds]
        new-terminal = "cmd+t"
        close-pane = "none"
        goto-workspace-1 = "ctrl+alt+1"

        [ghostty]
        cursor-style = block
        font-family = Monaco
        """
        let s = ConfigStore.parse(toml)
        XCTAssertEqual(s.themeName, "nord")
        XCTAssertEqual(s.workspaces, 8)
        XCTAssertEqual(s.overrides[.newTerminal], KeyCombo(key: "t", .command))
        XCTAssertTrue(s.unbound.contains(.closePane))
        XCTAssertEqual(s.overrides[.gotoWorkspace1], KeyCombo(key: "1", [.control, .option]))
        XCTAssertTrue(s.ghosttyPassthrough.contains("cursor-style = block"))
        XCTAssertTrue(s.ghosttyPassthrough.contains("font-family = Monaco"))
    }

    func testWorkspacesClamped() {
        XCTAssertEqual(ConfigStore.parse("workspaces = 99").workspaces, 10)
        XCTAssertEqual(ConfigStore.parse("workspaces = 0").workspaces, 1)
    }

    func testKeyComboParse() {
        XCTAssertEqual(KeyCombo.parse("cmd+shift+left"), KeyCombo(key: "left", [.command, .shift]))
        XCTAssertEqual(KeyCombo.parse("super+return"), KeyCombo(key: "return", .command))
        XCTAssertNil(KeyCombo.parse("cmd+shift+"))
    }

    func testKeybindingMapWithOverridesAndExtraWorkspaces() {
        let map = KeybindingMap(
            workspaceCount: 10,
            overrides: [.newTerminal: KeyCombo(key: "t", .command)],
            unbound: [.closePane])
        XCTAssertEqual(map.action(key: "t", modifiers: .command)?.action, .newTerminal)
        XCTAssertNil(map.action(key: "return", modifiers: .command), "旧组合应被替换")
        XCTAssertNil(map.action(key: "w", modifiers: .command), "close-pane 已解绑")
        XCTAssertEqual(map.action(key: "6", modifiers: .command)?.action, .gotoWorkspace6)
        XCTAssertEqual(map.action(key: "0", modifiers: [.command, .shift])?.action, .moveToWorkspace10)
    }

    @MainActor
    func testPersistedStateRoundTrip() throws {
        let c = try XCTUnwrap((NSApp.delegate as? AppDelegate)?.controller)
        let state = MainWindowController.PersistedState(
            layouts: c.model.layouts, activeIndex: c.model.activeIndex)
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(MainWindowController.PersistedState.self, from: data)
        XCTAssertEqual(decoded.version, 2)
        XCTAssertEqual(decoded.layouts.count, c.model.layouts.count)
        XCTAssertEqual(decoded.activeIndex, c.model.activeIndex)
        XCTAssertEqual(decoded.layouts[c.model.activeIndex].paneList.count,
                       c.paneList.count, "布局（含 pane 数）应完整往返")
    }
}

extension ConfigStoreTests {
    func testPanePaddingParsing() {
        XCTAssertEqual(ConfigStore.parse("").panePadding, 14, "默认 14（Omarchy 官方终端 padding）")
        XCTAssertEqual(ConfigStore.parse("pane-padding = 8").panePadding, 8)
        XCTAssertEqual(ConfigStore.parse("pane-padding = 99").panePadding, 32, "clamp 上限")
        XCTAssertEqual(ConfigStore.parse("pane-padding = -1").panePadding, 0, "clamp 下限")
    }

    @MainActor
    func testPanePaddingReachesOverlay() {
        let manager = ThemeManager()
        XCTAssertTrue(manager.overlayExtra().contains("window-padding-x = 14"), "默认 14")
        manager.updateFromConfig(passthrough: "", followEngine: false, panePadding: 6)
        XCTAssertTrue(manager.overlayExtra().contains("window-padding-x = 6"))
        XCTAssertTrue(manager.overlayExtra().contains("window-padding-y = 6"))
        manager.updateFromConfig(passthrough: "", followEngine: true, panePadding: 6)
        XCTAssertTrue(manager.overlayExtra().contains("window-padding-x = 6"),
                      "theme=ghostty 模式仍注入（QuickTerm 自身特性）")
    }
}

extension ConfigStoreTests {
    func testVisibleColumnsParsing() {
        XCTAssertNil(ConfigStore.parse("").visibleColumns, "未设置 = nil（走菜单/UserDefaults）")
        XCTAssertEqual(ConfigStore.parse("visible-columns = 3").visibleColumns, 3)
        XCTAssertEqual(ConfigStore.parse("visible-columns = 99").visibleColumns, 6, "clamp")
    }
}

extension ConfigStoreTests {
    func testInactiveOpacityParsing() {
        XCTAssertEqual(ConfigStore.parse("").inactiveOpacity, 0.85, accuracy: 0.001, "默认 0.85")
        XCTAssertEqual(ConfigStore.parse("inactive-opacity = 0.7").inactiveOpacity, 0.7, accuracy: 0.001)
        XCTAssertEqual(ConfigStore.parse("inactive-opacity = 0.1").inactiveOpacity, 0.3, accuracy: 0.001, "clamp 下限")
    }

    @MainActor
    func testEffectiveInactiveOpacityRespectsToggle() {
        let manager = ThemeManager()
        manager.updateFromConfig(passthrough: "", followEngine: false, inactiveOpacity: 0.8)
        manager.opacityEnabled = true
        XCTAssertEqual(manager.effectiveInactiveOpacity, 0.8, accuracy: 0.001)
        manager.opacityEnabled = false
        XCTAssertEqual(manager.effectiveInactiveOpacity, 1.0, accuracy: 0.001, "总开关关闭 = 不透明")
    }
}
