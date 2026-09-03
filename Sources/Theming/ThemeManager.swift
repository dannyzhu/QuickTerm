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

    /// config: theme = "ghostty" → 不覆盖配色，完全跟随 ~/.config/ghostty/config
    private(set) var followEngineColors = false
    /// config [ghostty] 段（配置链第 4 层，追加在 overlay 最末 = 最终覆盖）
    private(set) var ghosttyPassthrough = ""
    /// pane 内终端四边留白（config `pane-padding`，spec v6 默认 14）
    private(set) var panePadding = 14
    /// pane 背景透明度（config `pane-opacity`，默认 0.92 = 非激活基准，注入引擎 background-opacity）
    @Published private(set) var paneOpacity = 0.92
    /// 激活 pane 背景等效透明度（config `active-opacity`，默认 0.98；
    /// 引擎仍用 paneOpacity，激活侧以底色垫层合成到该值——零引擎 reload）
    @Published private(set) var activeOpacity = 0.98
    /// 非激活 pane 磨砂背景开关（config `inactive-blur` > 0；模糊的是身后壁纸，文字锐利）
    @Published private(set) var inactiveBlur = 2.5
    /// 顶部状态条背景透明度（config `bar-opacity`，默认 0.75；纯 UI 层）
    @Published private(set) var barOpacity = 0.75

    var frostedInactive: Bool { opacityEnabled && inactiveBlur > 0 }

    /// 顶部状态条等 chrome 的背景透明度（bar-opacity 数值，
    /// 受 Cmd+Backspace 总开关控制；关闭 = 不透明）
    var effectiveChromeOpacity: Double { opacityEnabled ? barOpacity : 1.0 }

    /// 激活 pane 垫层 alpha：使 paneOpacity 与垫层合成后 = activeOpacity
    var activeUnderlayAlpha: Double {
        guard opacityEnabled, paneOpacity < 1, activeOpacity > paneOpacity else { return 0 }
        return min((activeOpacity - paneOpacity) / (1 - paneOpacity), 1)
    }

    func updateFromConfig(passthrough: String, followEngine: Bool, panePadding: Int = 14,
                          paneOpacity: Double = 0.92, inactiveBlur: Double = 2.5,
                          activeOpacity: Double = 0.98, barOpacity: Double = 0.75) {
        self.activeOpacity = activeOpacity  // 纯 UI 层
        self.inactiveBlur = inactiveBlur  // 纯 UI 层
        self.barOpacity = barOpacity  // 纯 UI 层
        guard passthrough != ghosttyPassthrough
                || followEngine != followEngineColors
                || panePadding != self.panePadding
                || paneOpacity != self.paneOpacity else { return }
        self.paneOpacity = paneOpacity
        ghosttyPassthrough = passthrough
        followEngineColors = followEngine
        self.panePadding = panePadding
        writeOverlay()
    }

    /// 引擎重载钩子（MainWindowController 注入：app + 全部 surface reload）
    var onOverlayChanged: (() -> Void)?

    private static let defaultsThemeKey = "quickterm.theme"
    private static let defaultsBgKey = "quickterm.backgroundIndex"

    // MARK: 调色板（UI 层唯一取色入口）

    /// 用户自选背景目录（全主题共用）：~/.config/quickterm/backgrounds/
    static var userBackgroundsDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/quickterm/backgrounds", isDirectory: true)
    }
    @Published private(set) var userBackgrounds: [URL] = []

    /// 目录内图片（按文件名排序；跳过非图片）
    static func discoverBackgrounds(in dir: URL) -> [URL] {
        let exts: Set<String> = ["png", "jpg", "jpeg", "webp", "heic", "gif", "tiff"]
        return ((try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { exts.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// 可选背景 = 当前主题自带 + 用户自选（面板网格与 Cmd+Ctrl+Space 循环共用此列表）
    var backgroundChoices: [URL] { current.backgroundURLs + userBackgrounds }

    /// 导入用户背景：拷入用户目录（重名加时间戳）并立即选中
    func addUserBackground(from source: URL) {
        let dir = Self.userBackgroundsDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var dest = dir.appendingPathComponent(source.lastPathComponent)
        if FileManager.default.fileExists(atPath: dest.path) {
            let stem = dest.deletingPathExtension().lastPathComponent
            dest = dir.appendingPathComponent(
                "\(stem)-\(Int(Date().timeIntervalSince1970)).\(dest.pathExtension)")
        }
        guard (try? FileManager.default.copyItem(at: source, to: dest)) != nil else { return }
        userBackgrounds = Self.discoverBackgrounds(in: dir)
        if let idx = backgroundChoices.firstIndex(of: dest) {
            selectBackground(idx)
        }
    }

    var background: Color { current.color("background") ?? Palette.background }
    var foreground: Color { current.color("foreground") ?? Palette.foreground }
    var accent: Color { current.color("accent") ?? Palette.accent }
    var alert: Color { current.color("red") ?? Palette.alert }
    var currentBackgroundURL: URL? {
        backgroundChoices.indices.contains(backgroundIndex)
            ? backgroundChoices[backgroundIndex] : nil
    }

    init() {
        let loaded = Self.discoverThemes()
        themes = loaded
        let savedName = UserDefaults.standard.string(forKey: Self.defaultsThemeKey)
        current = loaded.first { $0.name == savedName }
            ?? loaded.first { $0.name == "tokyo-night" }
            ?? loaded.first
            ?? Theme(name: "fallback", isLight: false, colors: [:], backgroundURLs: [])
        userBackgrounds = Self.discoverBackgrounds(in: Self.userBackgroundsDir)
        let savedBg = UserDefaults.standard.integer(forKey: Self.defaultsBgKey)
        backgroundIndex = backgroundChoices.indices.contains(savedBg) ? savedBg : 0
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
        guard backgroundChoices.count > 1 else { return }
        selectBackground((backgroundIndex + 1) % backgroundChoices.count)
    }

    func selectBackground(_ index: Int) {
        guard backgroundChoices.indices.contains(index) else { return }
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
        var lines: [String] = ["window-padding-x = \(panePadding)",
                               "window-padding-y = \(panePadding)"]
        if followEngineColors {
            // theme = "ghostty"：配色与透明度完全跟随 ~/.config/ghostty/config
            // （pane-padding 仍是 QuickTerm 自身特性，照常注入；[ghostty] 段可最终覆盖）
            var out: [String] = lines
            if !opacityEnabled {
                out.append("background-opacity = 1.0")
                out.append("unfocused-split-opacity = 1.0")
            }
            if !ghosttyPassthrough.isEmpty { out.append(ghosttyPassthrough) }
            return out.joined(separator: "\n")
        }
        // pane 背景透明度（清玻璃/磨砂玻璃的基础；文字不受影响）
        lines.append(opacityEnabled
            ? "background-opacity = \(paneOpacity)" : "background-opacity = 1.0")
        lines.append(opacityEnabled ? "unfocused-split-opacity = 0.96" : "unfocused-split-opacity = 1.0")
        func emit(_ configKey: String, _ tomlKey: String, fallback: String? = nil) {
            if let v = current.hex(tomlKey) ?? fallback.flatMap({ current.hex($0) }) {
                lines.append("\(configKey) = \(v)")
            }
        }
        emit("background", "background")
        emit("foreground", "foreground")
        emit("cursor-color", "bright_foreground", fallback: "foreground")
        // 主题文件（如兜底的 Builtin Pastel Dark）可能自带 cursor-text = #ffffff，overlay 不写
        // 就会穿透：暗色主题块光标下的字变白底白字。重放在主题之后，此行必胜（1.2+ 支持该值）。
        lines.append("cursor-text = cell-background")
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
        if !ghosttyPassthrough.isEmpty {
            lines.append(ghosttyPassthrough)  // 配置链第 4 层：最终覆盖
        }
        return lines.joined(separator: "\n")
    }

    private func writeOverlay(notify: Bool = true) {
        EngineOverlay.install(extra: overlayExtra())
        if notify { onOverlayChanged?() }
    }
}
