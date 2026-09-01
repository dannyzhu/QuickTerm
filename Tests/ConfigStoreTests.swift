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
        XCTAssertEqual(decoded.version, 3)
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
    func testPaneOpacityAndBlurParsing() {
        XCTAssertEqual(ConfigStore.parse("").paneOpacity, 0.85, accuracy: 0.001, "默认 0.85")
        XCTAssertEqual(ConfigStore.parse("").inactiveBlur, 2.5, accuracy: 0.001, "默认磨砂开")
        XCTAssertEqual(ConfigStore.parse("inactive-blur = 99").inactiveBlur, 10, accuracy: 0.001, "clamp")
        XCTAssertEqual(ConfigStore.parse("pane-opacity = 0.7").paneOpacity, 0.7, accuracy: 0.001)
        XCTAssertEqual(ConfigStore.parse("").activeOpacity, 0.98, accuracy: 0.001, "激活默认 0.98")
        XCTAssertEqual(ConfigStore.parse("active-opacity = 0.9").activeOpacity, 0.9, accuracy: 0.001)
        XCTAssertEqual(ConfigStore.parse("pane-opacity = 0.1").paneOpacity, 0.5, accuracy: 0.001, "clamp 下限")
    }

    @MainActor
    func testFrostedRespectsToggleAndOverlayCarriesPaneOpacity() {
        let manager = ThemeManager()
        manager.updateFromConfig(passthrough: "", followEngine: false,
                                 paneOpacity: 0.8, inactiveBlur: 3)
        manager.opacityEnabled = true
        XCTAssertTrue(manager.frostedInactive)
        // 合成校验：paneOpacity 0.8 + 垫层 → activeOpacity 0.96
        let a = manager.activeUnderlayAlpha
        XCTAssertEqual(1 - (1 - 0.8) * (1 - a), 0.98, accuracy: 0.001, "垫层合成到 active-opacity")
        XCTAssertTrue(manager.overlayExtra().contains("background-opacity = 0.8"))
        manager.opacityEnabled = false
        XCTAssertFalse(manager.frostedInactive, "总开关关闭 = 无磨砂")
        XCTAssertTrue(manager.overlayExtra().contains("background-opacity = 1.0"))
    }
}
