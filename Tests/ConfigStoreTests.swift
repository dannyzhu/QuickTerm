import XCTest
import AppKit
@testable import QuickTerm

final class ConfigStoreTests: XCTestCase {
    func testParseFullConfig() {
        let toml = """
        theme = "nord"    # comment
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
        XCTAssertNil(map.action(key: "return", modifiers: .command), "the old combo has been replaced")
        XCTAssertNil(map.action(key: "w", modifiers: .command), "close-pane is unbound")
        XCTAssertEqual(map.action(key: "6", modifiers: .command)?.action, .gotoWorkspace6)
        XCTAssertEqual(map.action(key: "0", modifiers: [.command, .shift])?.action, .moveToWorkspace10)
    }

    @MainActor
    func testPersistedStateRoundTrip() throws {
        let c = try XCTUnwrap((NSApp.delegate as? AppDelegate)?.controller)
        let state = PersistedState(windows: [
            WindowState(layouts: c.model.layouts, activeIndex: c.model.activeIndex)
        ])
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(PersistedState.self, from: data)
        XCTAssertEqual(decoded.version, 5)
        if !c.model.allPanes.isEmpty {
            XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("\"kind\":\"terminal\""), "a v4 leaf carries kind")
        }
        let window = try XCTUnwrap(decoded.windows.first)
        XCTAssertEqual(window.layouts.count, c.model.layouts.count)
        XCTAssertEqual(window.activeIndex, c.model.activeIndex)
        XCTAssertEqual(window.layouts[c.model.activeIndex].paneList.count,
                       c.paneList.count, "the layout, pane count included, round-trips intact")
    }
}

extension ConfigStoreTests {
    func testPanePaddingParsing() {
        XCTAssertEqual(ConfigStore.parse("").panePadding, 14, "14 by default (Omarchy's own terminal padding)")
        XCTAssertEqual(ConfigStore.parse("pane-padding = 8").panePadding, 8)
        XCTAssertEqual(ConfigStore.parse("pane-padding = 99").panePadding, 32, "clamped to the upper bound")
        XCTAssertEqual(ConfigStore.parse("pane-padding = -1").panePadding, 0, "clamped to the lower bound")
    }

    @MainActor
    func testPanePaddingReachesOverlay() {
        let manager = ThemeManager()
        XCTAssertTrue(manager.overlayExtra().contains("window-padding-x = 14"), "14 by default")
        manager.updateFromConfig(passthrough: "", followEngine: false, panePadding: 6)
        XCTAssertTrue(manager.overlayExtra().contains("window-padding-x = 6"))
        XCTAssertTrue(manager.overlayExtra().contains("window-padding-y = 6"))
        manager.updateFromConfig(passthrough: "", followEngine: true, panePadding: 6)
        XCTAssertTrue(manager.overlayExtra().contains("window-padding-x = 6"),
                      "theme=ghostty mode still injects it: this is QuickTerm's own feature")
    }
}

extension ConfigStoreTests {
    func testVisibleColumnsParsing() {
        XCTAssertNil(ConfigStore.parse("").visibleColumns, "unset means nil, so the menu / UserDefaults decides")
        XCTAssertEqual(ConfigStore.parse("visible-columns = 3").visibleColumns, 3)
        XCTAssertEqual(ConfigStore.parse("visible-columns = 99").visibleColumns, 6, "clamp")
    }
}

extension ConfigStoreTests {
    func testPaneOpacityAndBlurParsing() {
        XCTAssertEqual(ConfigStore.parse("").paneOpacity, 0.92, accuracy: 0.001, "0.92 by default")
        XCTAssertEqual(ConfigStore.parse("").inactiveBlur, 2.5, accuracy: 0.001, "frosting is on by default")
        XCTAssertEqual(ConfigStore.parse("inactive-blur = 99").inactiveBlur, 10, accuracy: 0.001, "clamp")
        XCTAssertEqual(ConfigStore.parse("pane-opacity = 0.7").paneOpacity, 0.7, accuracy: 0.001)
        XCTAssertEqual(ConfigStore.parse("").activeOpacity, 0.98, accuracy: 0.001, "0.98 for the active pane by default")
        XCTAssertEqual(ConfigStore.parse("active-opacity = 0.9").activeOpacity, 0.9, accuracy: 0.001)
        XCTAssertEqual(ConfigStore.parse("pane-opacity = 0.1").paneOpacity, 0.5, accuracy: 0.001, "clamped to the lower bound")
        XCTAssertEqual(ConfigStore.parse("").barOpacity, 0.75, accuracy: 0.001, "the top bar defaults to 0.75")
        XCTAssertEqual(ConfigStore.parse("bar-opacity = 0.3").barOpacity, 0.3, accuracy: 0.001)
        XCTAssertEqual(ConfigStore.parse("bar-opacity = 1.5").barOpacity, 1.0, accuracy: 0.001, "clamped to the upper bound")
        XCTAssertEqual(ConfigStore.parse("").dividerOpacity, 0.2, accuracy: 0.001, "the thin dwindle divider defaults to 0.2")
        XCTAssertEqual(ConfigStore.parse("divider-opacity = 0.4").dividerOpacity, 0.4, accuracy: 0.001)
        XCTAssertEqual(ConfigStore.parse("divider-opacity = -1").dividerOpacity, 0.0, accuracy: 0.001, "clamped to the lower bound")
        XCTAssertEqual(ConfigStore.parse("").paneGap, 5, "pane gap defaults to 5 (the old scrolling value, 10pt between neighbours)")
        XCTAssertEqual(ConfigStore.parse("pane-gap = 3").paneGap, 3)
        XCTAssertEqual(ConfigStore.parse("pane-gap = 99").paneGap, 20, "clamped to the upper bound")
        XCTAssertEqual(ConfigStore.parse("pane-gap = -4").paneGap, 0, "clamped to the lower bound")
        XCTAssertEqual(ConfigStore.parse("dwindle-gap = 4").paneGap, 4, "the old dwindle-gap key still works as an alias")
        XCTAssertEqual(ConfigStore.parse("dwindle-gap = 4\npane-gap = 7").paneGap, 7, "the new key wins")
        XCTAssertEqual(ConfigStore.parse("pane-gap = 7\ndwindle-gap = 4").paneGap, 7, "the new key wins, order does not matter")
        XCTAssertEqual(ConfigStore.parse("").fileManagerCommand, "yazi", "the file manager defaults to yazi")
        XCTAssertEqual(ConfigStore.parse("file-manager-command = \"lf\"").fileManagerCommand, "lf")
        XCTAssertEqual(ConfigStore.parse("file-manager-command = /opt/homebrew/bin/yazi").fileManagerCommand, "/opt/homebrew/bin/yazi")
        XCTAssertEqual(ConfigStore.parse("file-manager-command = \"\"").fileManagerCommand, "yazi",
                       "an empty value does not override the default")
        let b = ConfigStore.parse("browser-home = \"https://x.y\"\nbrowser-search = \"https://s/?q=%s\"\nbrowser-user-agent = webkit\nbrowser-inspectable = true")
        XCTAssertEqual(b.browserHome, "https://x.y")
        XCTAssertEqual(b.browserSearch, "https://s/?q=%s")
        XCTAssertEqual(b.browserUserAgent, "webkit")
        XCTAssertTrue(b.browserInspectable)
        XCTAssertEqual(ConfigStore.parse("").browserUserAgent, "safari", "it poses as Safari by default")
        XCTAssertFalse(ConfigStore.parse("").browserInspectable)
        XCTAssertEqual(ConfigStore.parse("").browserTabBar, "always", "the tab bar is always shown by default")
        XCTAssertEqual(ConfigStore.parse("browser-tab-bar = auto").browserTabBar, "auto")
        XCTAssertEqual(ConfigStore.parse("").browserTabWidth, 200)
        XCTAssertEqual(ConfigStore.parse("").browserTabMinWidth, 80)
        let w = ConfigStore.parse("browser-tab-width = 160\nbrowser-tab-min-width = 5")
        XCTAssertEqual(w.browserTabWidth, 160)
        XCTAssertEqual(w.browserTabMinWidth, 40, "lower bound 40")
        XCTAssertEqual(ConfigStore.parse("browser-tab-width = 9999").browserTabWidth, 600, "upper bound 600")
        XCTAssertTrue(ConfigStore.parse("").browserExtensions, "extensions are on by default")
        XCTAssertFalse(ConfigStore.parse("browser-extensions = false").browserExtensions)
        XCTAssertTrue(ConfigStore.parse("browser-extensions = true").browserExtensions)
        XCTAssertEqual(ConfigStore.parse("").browserDownloadDir, "~/Downloads", "downloads default to ~/Downloads")
        XCTAssertEqual(ConfigStore.parse("browser-download-dir = \"/tmp/dl\"").browserDownloadDir, "/tmp/dl")
        XCTAssertEqual(ConfigStore.parse("browser-download-dir = \"\"").browserDownloadDir, "~/Downloads",
                       "an empty value does not override the default")
        XCTAssertEqual(ConfigStore.parse("").linkOpener, "browser-pane", "a link from the terminal opens in a browser pane by default")
        XCTAssertEqual(ConfigStore.parse("link-opener = system").linkOpener, "system")
    }

    /// Filling missing keys into an existing config file: the comment plus default goes in before the first
    /// section, the whole thing is idempotent, a complete file is left alone, and live settings survive.
    func testEnsureTemplateKeysAppendsMissingOnce() throws {
        let fm = FileManager.default
        let url = fm.temporaryDirectory.appendingPathComponent("qt-config-\(UUID().uuidString).toml")
        defer { try? fm.removeItem(at: url) }
        try "theme = \"nord\"\nworkspaces = 8\n\n[keybinds]\nnew-terminal = \"cmd+t\"\n".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertTrue(ConfigStore.ensureTemplateKeys(at: url), "keys missing -> write")
        // No file at all: write the full template, creating the directory on the way.
        let fresh = fm.temporaryDirectory.appendingPathComponent("qt-cfgdir-\(UUID().uuidString)/config.toml")
        defer { try? fm.removeItem(at: fresh.deletingLastPathComponent()) }
        XCTAssertTrue(ConfigStore.ensureTemplateKeys(at: fresh), "missing -> created")
        XCTAssertEqual(try String(contentsOf: fresh, encoding: .utf8), ConfigStore.template)
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("# divider-opacity = 0.2"), "divider-opacity's default was filled in")
        XCTAssertTrue(text.contains("# pane-opacity = 0.92"))
        XCTAssertFalse(text.contains("# theme = "), "an existing theme key is not filled in again")
        XCTAssertFalse(text.contains("# workspaces = "), "an existing workspaces key is not filled in again")
        let keybindsIdx = try XCTUnwrap(text.range(of: "[keybinds]")).lowerBound
        let dividerIdx = try XCTUnwrap(text.range(of: "# divider-opacity")).lowerBound
        XCTAssertLessThan(dividerIdx, keybindsIdx, "the filled-in block goes before the first section")
        let parsed = ConfigStore.parse(text)
        XCTAssertEqual(parsed.themeName, "nord"); XCTAssertEqual(parsed.workspaces, 8)
        XCTAssertEqual(parsed.overrides[.newTerminal], KeyCombo(key: "t", .command), "live settings are kept verbatim")
        XCTAssertFalse(ConfigStore.ensureTemplateKeys(at: url), "nothing missing the second time -> no write")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), text, "idempotent")
        // The full template needs no filling in, and its keys cover every parsable key.
        try ConfigStore.template.write(to: url, atomically: true, encoding: .utf8)
        XCTAssertFalse(ConfigStore.ensureTemplateKeys(at: url))
        // Template keys carry the registry's new names: after the grouping, `[browser] home` is no longer browser-home.
        let keys = Set(ConfigStore.templateKeyBlocks.map(\.spec.key))
        XCTAssertEqual(keys, Set(ConfigSchema.keys.map(\.key)), "the template has to list every key in the registry")
        for k in ["theme", "workspaces", "pane-padding", "visible-columns", "pane-opacity",
                  "active-opacity", "bar-opacity", "divider-opacity", "pane-gap", "inactive-blur",
                  "file-manager-command", "home", "search", "user-agent", "inspectable",
                  "tab-bar", "tab-width", "tab-min-width", "extensions", "download-dir",
                  "link-opener", "socket", "mcp", "mode", "expose-browser", "send-text"] {
            XCTAssertTrue(keys.contains(k), "the template is missing \(k)")
        }
        for k in ["new-terminal", "cursor-style", "动作"] {
            XCTAssertFalse(keys.contains(k), "an example row in the [keybinds] / [ghostty] sections is not a top-level key: \(k)")
        }
    }

    @MainActor
    func testDividerOpacityFollowsMasterToggle() {
        let manager = ThemeManager()
        manager.updateFromConfig(passthrough: "", followEngine: false, dividerOpacity: 0.6)
        manager.opacityEnabled = true
        XCTAssertEqual(manager.effectiveDividerOpacity, 0.6, accuracy: 0.001)
        manager.opacityEnabled = false
        XCTAssertEqual(manager.effectiveDividerOpacity, 1.0, accuracy: 0.001, "master switch off means an opaque solid line")
    }

    @MainActor
    func testFrostedRespectsToggleAndOverlayCarriesPaneOpacity() {
        let manager = ThemeManager()
        manager.updateFromConfig(passthrough: "", followEngine: false,
                                 paneOpacity: 0.8, inactiveBlur: 3)
        manager.opacityEnabled = true
        XCTAssertTrue(manager.frostedInactive)
        // Compositing check: paneOpacity 0.8 plus the underlay -> activeOpacity 0.96.
        let a = manager.activeUnderlayAlpha
        XCTAssertEqual(1 - (1 - 0.8) * (1 - a), 0.98, accuracy: 0.001, "the underlay composites up to active-opacity")
        XCTAssertTrue(manager.overlayExtra().contains("background-opacity = 0.8"))
        manager.opacityEnabled = false
        XCTAssertFalse(manager.frostedInactive, "master switch off means no frosting")
        XCTAssertTrue(manager.overlayExtra().contains("background-opacity = 1.0"))
    }

    /// The engine's fallback config: used only when none of the four candidate paths exist, and
    /// XDG_CONFIG_HOME really does move the location.
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
        XCTAssertFalse(GhosttyDefaultConfig.userConfigExists(home: home, environment: env), "empty home: the fallback is used")

        let legacy = home.appendingPathComponent(".config/ghostty/config")
        try touch(legacy)
        XCTAssertTrue(GhosttyDefaultConfig.userConfigExists(home: home, environment: env), "the old name config exists -> stand aside")
        try fm.removeItem(at: legacy)

        try touch(home.appendingPathComponent(".config/ghostty/config.ghostty"))
        XCTAssertTrue(GhosttyDefaultConfig.userConfigExists(home: home, environment: env),
                      "the new name config.ghostty exists -> stand aside")
        try fm.removeItem(at: home.appendingPathComponent(".config/ghostty/config.ghostty"))

        let xdg = home.appendingPathComponent("xdg")
        try touch(xdg.appendingPathComponent("ghostty/config"))
        XCTAssertFalse(GhosttyDefaultConfig.userConfigExists(home: home, environment: env),
                       "without XDG_CONFIG_HOME that directory is not consulted")
        XCTAssertTrue(GhosttyDefaultConfig.userConfigExists(home: home, environment: ["XDG_CONFIG_HOME": xdg.path]),
                      "XDG_CONFIG_HOME really does move it")

        try touch(home.appendingPathComponent("Library/Application Support/com.mitchellh.ghostty/config"))
        XCTAssertTrue(GhosttyDefaultConfig.userConfigExists(home: home, environment: env), "the Application Support path counts too")
        try fm.removeItem(at: home.appendingPathComponent("Library/Application Support/com.mitchellh.ghostty/config"))

        // The 0-byte template libghostty 1.3.1 writes out on its own: the engine skips it as FileIsEmpty, so
        // it does not count as a user config.
        try touch(home.appendingPathComponent("Library/Application Support/com.mitchellh.ghostty/config.ghostty"),
                  empty: true)
        XCTAssertFalse(GhosttyDefaultConfig.userConfigExists(home: home, environment: env), "a 0-byte file does not count")
        try fm.createDirectory(at: home.appendingPathComponent(".config/ghostty/config"),
                               withIntermediateDirectories: true)
        XCTAssertFalse(GhosttyDefaultConfig.userConfigExists(home: home, environment: env), "a directory with the same name does not count")

        // Load order follows libghostty: XDG old name -> XDG new name -> App Support.
        try fm.removeItem(at: home.appendingPathComponent(".config/ghostty/config"))
        try touch(home.appendingPathComponent(".config/ghostty/config.ghostty"))
        try touch(home.appendingPathComponent(".config/ghostty/config"))
        let order = GhosttyDefaultConfig.userConfigFiles(home: home, environment: env).map(\.lastPathComponent)
        XCTAssertEqual(order, ["config", "config.ghostty"], "the old name comes first, and the new one overrides it")
    }

    /// The fallback file is bundled, and its contents are the defaults the user asked for.
    func testGhosttyFallbackResourceBundled() throws {
        let path = try XCTUnwrap(GhosttyDefaultConfig.bundledPath, "the bundle has to contain ghostty-default.conf")
        let text = try String(contentsOfFile: path, encoding: .utf8)
        for key in ["font-family = Monaco", "font-size = 15", "theme = Builtin Pastel Dark",
                    "copy-on-select = clipboard", "scrollback-limit = 100000000"] {
            XCTAssertTrue(text.contains(key), "missing \(key)")
        }
        // Removals QuickTerm's semantics require (only active lines are checked; the header comment does
        // mention these keys):
        // shell integration stays on detect, and there are no tab keybindings.
        let active = text.split(separator: "\n").filter { !$0.hasPrefix("#") }.joined(separator: "\n")
        XCTAssertFalse(active.contains("shell-integration = none"), "that would break cwd inheritance and confirmation-free closing")
        XCTAssertFalse(active.contains("previous_tab"),
                       "QuickTerm has no tabs, and this would override the engine's start/end-of-line keys")
    }
}
