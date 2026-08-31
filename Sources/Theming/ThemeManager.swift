import AppKit
import SwiftUI

/// 主题状态的唯一拥有者（spec §4.5）：
/// 切换 = 重写 engine-overlay（配置链第 3 层）→ 引擎热重载 + SwiftUI 调色板刷新。
final class ThemeManager: ObservableObject {
    @Published private(set) var themes: [Theme] = []
    @Published private(set) var current: Theme
    @Published private(set) var backgroundIndex: Int = 0
    @Published var opacityEnabled = true   // Cmd+Backspace
    @Published var gapsEnabled = true      // Cmd+Shift+Backspace

    /// 引擎重载钩子（MainWindowController 注入：app + 全部 surface reload）
    var onOverlayChanged: (() -> Void)?

    private static let defaultsThemeKey = "quickterm.theme"
    private static let defaultsBgKey = "quickterm.backgroundIndex"

    // MARK: 调色板（UI 层唯一取色入口）

    var background: Color { current.color("background") ?? Palette.background }
    var foreground: Color { current.color("foreground") ?? Palette.foreground }
    var accent: Color { current.color("accent") ?? Palette.accent }
    var alert: Color { current.color("red") ?? Palette.alert }
    var currentBackgroundURL: URL? {
        current.backgroundURLs.indices.contains(backgroundIndex)
            ? current.backgroundURLs[backgroundIndex] : nil
    }

    init() {
        let loaded = Self.discoverThemes()
        themes = loaded
        let savedName = UserDefaults.standard.string(forKey: Self.defaultsThemeKey)
        current = loaded.first { $0.name == savedName }
            ?? loaded.first { $0.name == "tokyo-night" }
            ?? loaded.first
            ?? Theme(name: "fallback", isLight: false, colors: [:], backgroundURLs: [])
        let savedBg = UserDefaults.standard.integer(forKey: Self.defaultsBgKey)
        backgroundIndex = current.backgroundURLs.indices.contains(savedBg) ? savedBg : 0
        writeOverlay(notify: false)  // 启动时引擎尚未创建，仅落盘供首次加载
    }

    /// 内置 Themes/（app bundle）∪ 用户目录（同名用户优先，spec §4.5）
    static func discoverThemes() -> [Theme] {
        var byName: [String: Theme] = [:]
        if let bundleDir = Bundle.main.resourceURL?.appendingPathComponent("Themes") {
            for theme in themes(in: bundleDir) { byName[theme.name] = theme }
        }
        let userDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/quickterm/themes", isDirectory: true)
        for theme in themes(in: userDir) { byName[theme.name] = theme }
        return byName.values.sorted { $0.name < $1.name }
    }

    private static func themes(in dir: URL) -> [Theme] {
        ((try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
            .compactMap { Theme.load(from: $0) }
    }

    // MARK: 切换

    func apply(_ theme: Theme) {
        current = theme
        backgroundIndex = 0
        UserDefaults.standard.set(theme.name, forKey: Self.defaultsThemeKey)
        UserDefaults.standard.set(0, forKey: Self.defaultsBgKey)
        writeOverlay()
    }

    /// 下一张背景（回绕，spec §4.3）
    func nextBackground() {
        guard current.backgroundURLs.count > 1 else { return }
        selectBackground((backgroundIndex + 1) % current.backgroundURLs.count)
    }

    func selectBackground(_ index: Int) {
        guard current.backgroundURLs.indices.contains(index) else { return }
        backgroundIndex = index
        UserDefaults.standard.set(index, forKey: Self.defaultsBgKey)
        // 壁纸在 QuickTerm 自绘层，不进引擎配置，无需 reload
    }

    func toggleOpacity() {
        opacityEnabled.toggle()
        writeOverlay()
    }

    func toggleGaps() {
        gapsEnabled.toggle()  // gaps 纯 UI 层（RootView/PaneChrome 读取）
    }

    // MARK: 引擎覆盖层（配置链第 3 层；映射照 omarchy ghostty.conf.tpl）

    func overlayExtra() -> String {
        var lines: [String] = []
        func emit(_ configKey: String, _ tomlKey: String, fallback: String? = nil) {
            if let v = current.hex(tomlKey) ?? fallback.flatMap({ current.hex($0) }) {
                lines.append("\(configKey) = \(v)")
            }
        }
        emit("background", "background")
        emit("foreground", "foreground")
        emit("cursor-color", "bright_foreground", fallback: "foreground")
        emit("selection-background", "selection")
        emit("selection-foreground", "foreground")
        let paletteMap: [(Int, String, String?)] = [
            (0, "background", nil), (1, "red", nil), (2, "green", nil), (3, "yellow", nil),
            (4, "blue", nil), (5, "magenta", nil), (6, "cyan", nil), (7, "foreground", nil),
            (8, "muted", nil), (9, "bright_red", "red"), (10, "bright_green", "green"),
            (11, "bright_yellow", "yellow"), (12, "bright_blue", "blue"),
            (13, "bright_magenta", "magenta"), (14, "bright_cyan", "cyan"),
            (15, "bright_foreground", "foreground"),
        ]
        for (index, key, fallback) in paletteMap {
            if let v = current.hex(key) ?? fallback.flatMap({ current.hex($0) }) {
                lines.append("palette = \(index)=\(v)")
            }
        }
        if !opacityEnabled {
            // 覆盖 EngineOverlay 基础段（同键后写者胜）
            lines.append("background-opacity = 1.0")
            lines.append("unfocused-split-opacity = 1.0")
        }
        return lines.joined(separator: "\n")
    }

    private func writeOverlay(notify: Bool = true) {
        EngineOverlay.install(extra: overlayExtra())
        if notify { onOverlayChanged?() }
    }
}
