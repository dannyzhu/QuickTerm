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
        XCTAssertEqual(ConfigStore.parse("").paneOpacity, 0.92, accuracy: 0.001, "默认 0.92")
        XCTAssertEqual(ConfigStore.parse("").inactiveBlur, 2.5, accuracy: 0.001, "默认磨砂开")
        XCTAssertEqual(ConfigStore.parse("inactive-blur = 99").inactiveBlur, 10, accuracy: 0.001, "clamp")
        XCTAssertEqual(ConfigStore.parse("pane-opacity = 0.7").paneOpacity, 0.7, accuracy: 0.001)
        XCTAssertEqual(ConfigStore.parse("").activeOpacity, 0.98, accuracy: 0.001, "激活默认 0.98")
        XCTAssertEqual(ConfigStore.parse("active-opacity = 0.9").activeOpacity, 0.9, accuracy: 0.001)
        XCTAssertEqual(ConfigStore.parse("pane-opacity = 0.1").paneOpacity, 0.5, accuracy: 0.001, "clamp 下限")
        XCTAssertEqual(ConfigStore.parse("").barOpacity, 0.75, accuracy: 0.001, "顶栏默认 0.75")
        XCTAssertEqual(ConfigStore.parse("bar-opacity = 0.3").barOpacity, 0.3, accuracy: 0.001)
        XCTAssertEqual(ConfigStore.parse("bar-opacity = 1.5").barOpacity, 1.0, accuracy: 0.001, "clamp 上限")
        XCTAssertEqual(ConfigStore.parse("").dividerOpacity, 0.2, accuracy: 0.001, "dwindle 分隔细线默认 0.2")
        XCTAssertEqual(ConfigStore.parse("divider-opacity = 0.4").dividerOpacity, 0.4, accuracy: 0.001)
        XCTAssertEqual(ConfigStore.parse("divider-opacity = -1").dividerOpacity, 0.0, accuracy: 0.001, "clamp 下限")
    }

    /// 已有配置文件补全缺失键：注释+默认值插在第一个 section 前；幂等；完整文件不动；活跃设置不被覆盖
    func testEnsureTemplateKeysAppendsMissingOnce() throws {
        let fm = FileManager.default
        let url = fm.temporaryDirectory.appendingPathComponent("qt-config-\(UUID().uuidString).toml")
        defer { try? fm.removeItem(at: url) }
        try "theme = \"nord\"\nworkspaces = 8\n\n[keybinds]\nnew-terminal = \"cmd+t\"\n".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertTrue(ConfigStore.ensureTemplateKeys(at: url), "缺键 → 写入")
        // 文件不存在 → 写完整模板（含目录）
        let fresh = fm.temporaryDirectory.appendingPathComponent("qt-cfgdir-\(UUID().uuidString)/config.toml")
        defer { try? fm.removeItem(at: fresh.deletingLastPathComponent()) }
        XCTAssertTrue(ConfigStore.ensureTemplateKeys(at: fresh), "不存在 → 创建")
        XCTAssertEqual(try String(contentsOf: fresh, encoding: .utf8), ConfigStore.template)
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("# divider-opacity = 0.2"), "补全 divider-opacity 默认")
        XCTAssertTrue(text.contains("# pane-opacity = 0.92"))
        XCTAssertFalse(text.contains("# theme = "), "已有的 theme 不重复补")
        XCTAssertFalse(text.contains("# workspaces = "), "已有的 workspaces 不重复补")
        let keybindsIdx = try XCTUnwrap(text.range(of: "[keybinds]")).lowerBound
        let dividerIdx = try XCTUnwrap(text.range(of: "# divider-opacity")).lowerBound
        XCTAssertLessThan(dividerIdx, keybindsIdx, "补全块插在第一个 section 之前")
        let parsed = ConfigStore.parse(text)
        XCTAssertEqual(parsed.themeName, "nord"); XCTAssertEqual(parsed.workspaces, 8)
        XCTAssertEqual(parsed.overrides[.newTerminal], KeyCombo(key: "t", .command), "活跃设置原样保留")
        XCTAssertFalse(ConfigStore.ensureTemplateKeys(at: url), "第二次无缺键 → 不写")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), text, "幂等")
        // 完整模板本身不需要补全；模板键覆盖所有可解析键
        try ConfigStore.template.write(to: url, atomically: true, encoding: .utf8)
        XCTAssertFalse(ConfigStore.ensureTemplateKeys(at: url))
        let keys = Set(ConfigStore.templateKeyLines.map(\.key))
        for k in ["theme", "workspaces", "pane-padding", "visible-columns", "pane-opacity",
                  "active-opacity", "bar-opacity", "divider-opacity", "inactive-blur"] {
            XCTAssertTrue(keys.contains(k), "模板缺少 \(k)")
        }
    }

    @MainActor
    func testDividerOpacityFollowsMasterToggle() {
        let manager = ThemeManager()
        manager.updateFromConfig(passthrough: "", followEngine: false, dividerOpacity: 0.6)
        manager.opacityEnabled = true
        XCTAssertEqual(manager.effectiveDividerOpacity, 0.6, accuracy: 0.001)
        manager.opacityEnabled = false
        XCTAssertEqual(manager.effectiveDividerOpacity, 1.0, accuracy: 0.001, "总开关关闭 = 不透明实线")
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

    /// 引擎兜底配置：仅当四个候选路径都不存在时才启用；XDG_CONFIG_HOME 覆盖生效
    func testGhosttyFallbackOnlyWhenNoUserConfig() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("qt-home-\(UUID().uuidString)")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }
        let env: [String: String] = [:]
        func touch(_ url: URL, empty: Bool = false) throws {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            fm.createFile(atPath: url.path, contents: empty ? Data() : Data("font-size = 12\n".utf8))
        }
        XCTAssertFalse(GhosttyDefaultConfig.userConfigExists(home: home, environment: env), "空 home：启用兜底")

        let legacy = home.appendingPathComponent(".config/ghostty/config")
        try touch(legacy)
        XCTAssertTrue(GhosttyDefaultConfig.userConfigExists(home: home, environment: env), "旧名 config 存在 → 让位")
        try fm.removeItem(at: legacy)

        try touch(home.appendingPathComponent(".config/ghostty/config.ghostty"))
        XCTAssertTrue(GhosttyDefaultConfig.userConfigExists(home: home, environment: env), "新名 config.ghostty 存在 → 让位")
        try fm.removeItem(at: home.appendingPathComponent(".config/ghostty/config.ghostty"))

        let xdg = home.appendingPathComponent("xdg")
        try touch(xdg.appendingPathComponent("ghostty/config"))
        XCTAssertFalse(GhosttyDefaultConfig.userConfigExists(home: home, environment: env), "未设 XDG_CONFIG_HOME 不看该目录")
        XCTAssertTrue(GhosttyDefaultConfig.userConfigExists(home: home, environment: ["XDG_CONFIG_HOME": xdg.path]),
                      "XDG_CONFIG_HOME 覆盖生效")

        try touch(home.appendingPathComponent("Library/Application Support/com.mitchellh.ghostty/config"))
        XCTAssertTrue(GhosttyDefaultConfig.userConfigExists(home: home, environment: env), "Application Support 路径也算")
        try fm.removeItem(at: home.appendingPathComponent("Library/Application Support/com.mitchellh.ghostty/config"))

        // libghostty 1.3.1 自动写出的 0 字节模板：引擎按 FileIsEmpty 不加载 → 不算用户配置
        try touch(home.appendingPathComponent("Library/Application Support/com.mitchellh.ghostty/config.ghostty"),
                  empty: true)
        XCTAssertFalse(GhosttyDefaultConfig.userConfigExists(home: home, environment: env), "0 字节文件不算")
        try fm.createDirectory(at: home.appendingPathComponent(".config/ghostty/config"),
                               withIntermediateDirectories: true)
        XCTAssertFalse(GhosttyDefaultConfig.userConfigExists(home: home, environment: env), "同名目录不算")

        // 加载顺序同 libghostty：XDG 旧名 → XDG 新名 → App Support
        try fm.removeItem(at: home.appendingPathComponent(".config/ghostty/config"))
        try touch(home.appendingPathComponent(".config/ghostty/config.ghostty"))
        try touch(home.appendingPathComponent(".config/ghostty/config"))
        let order = GhosttyDefaultConfig.userConfigFiles(home: home, environment: env).map(\.lastPathComponent)
        XCTAssertEqual(order, ["config", "config.ghostty"], "旧名先于新名（后者覆盖前者）")
    }

    /// 兜底文件已打入 bundle 且内容为用户指定的缺省值
    func testGhosttyFallbackResourceBundled() throws {
        let path = try XCTUnwrap(GhosttyDefaultConfig.bundledPath, "bundle 应包含 ghostty-default.conf")
        let text = try String(contentsOfFile: path, encoding: .utf8)
        for key in ["font-family = Monaco", "font-size = 15", "theme = Builtin Pastel Dark",
                    "copy-on-select = clipboard", "scrollback-limit = 100000000"] {
            XCTAssertTrue(text.contains(key), "缺少 \(key)")
        }
        // QuickTerm 语义所需的删减（只看生效行，文件头注释里会提到这些键）：
        // shell 集成保持 detect；无 tab 键位
        let active = text.split(separator: "\n").filter { !$0.hasPrefix("#") }.joined(separator: "\n")
        XCTAssertFalse(active.contains("shell-integration = none"), "会断掉 cwd 继承与免确认关闭")
        XCTAssertFalse(active.contains("previous_tab"), "QuickTerm 无 tab，且会覆盖引擎行首/行尾")
    }
}
