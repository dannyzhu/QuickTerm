import AppKit
import SwiftUI

/// The single owner of theme state (spec §4.5): switching a theme means rewriting the
/// engine-overlay (layer 3 of the config chain), which hot-reloads the engine and refreshes the
/// SwiftUI palette.
final class ThemeManager: ObservableObject {
    @Published private(set) var themes: [Theme] = []
    @Published private(set) var current: Theme
    @Published private(set) var backgroundIndex: Int = 0
    @Published var opacityEnabled = true   // Cmd+Backspace
    @Published var gapsEnabled = true      // Cmd+Shift+Backspace

    /// config `theme = "ghostty"`: leave the colors alone and follow ~/.config/ghostty/config
    /// entirely.
    private(set) var followEngineColors = false
    /// The config's [ghostty] section (layer 4 of the chain; appended at the very end of the
    /// overlay, so it is the final override).
    private(set) var ghosttyPassthrough = ""
    /// Terminal padding inside a pane (config `pane-padding`; spec v6 default is 14).
    private(set) var panePadding = 14
    /// Pane background opacity (config `pane-opacity`, default 0.92 = the inactive baseline);
    /// injected into the engine as background-opacity.
    @Published private(set) var paneOpacity = 0.92
    /// Effective background opacity of the focused pane (config `active-opacity`, default 0.98).
    /// The engine still runs at paneOpacity; the active side composites a background-colored
    /// underlay to reach this value, which costs zero engine reloads.
    @Published private(set) var activeOpacity = 0.98
    /// Frosted background for inactive panes (on when config `inactive-blur` > 0). What gets
    /// blurred is the wallpaper behind the pane; the text stays sharp.
    @Published private(set) var inactiveBlur = 2.5
    /// Top status bar background opacity (config `bar-opacity`, default 0.75; pure UI layer).
    @Published private(set) var barOpacity = 0.75
    /// Opacity of the thin dwindle divider (config `divider-opacity`, default 0.2; pure UI layer).
    @Published private(set) var dividerOpacity = 0.2
    /// Padding on every side of every pane (config `pane-gap`, default 5pt). Identical for
    /// scrolling, dwindle and floating panes; adjacent panes add up to 2×gap, and the outer ring
    /// gets the same value.
    @Published private(set) var paneGap: CGFloat = 5
    /// Draw the title on a pane's top border (config `pane-title`, on by default; pure UI layer,
    /// read by PaneChrome).
    @Published private(set) var paneTitleEnabled = true
    /// Show the name in the workspace pill (config `workspace-title`, on by default; pure UI
    /// layer, read by StatusBarView).
    @Published private(set) var workspaceTitleEnabled = true

    var frostedInactive: Bool { opacityEnabled && inactiveBlur > 0 }

    /// Background opacity for the top status bar and the rest of the chrome (the bar-opacity
    /// value), governed by the Cmd+Backspace master switch; switched off = fully opaque.
    var effectiveChromeOpacity: Double { opacityEnabled ? barOpacity : 1.0 }

    /// Effective opacity of the thin dwindle divider (master switch off = a solid opaque line).
    var effectiveDividerOpacity: Double { opacityEnabled ? dividerOpacity : 1.0 }

    /// Alpha of the focused pane's underlay: chosen so that compositing it under paneOpacity
    /// lands exactly on activeOpacity.
    var activeUnderlayAlpha: Double {
        guard opacityEnabled, paneOpacity < 1, activeOpacity > paneOpacity else { return 0 }
        return min((activeOpacity - paneOpacity) / (1 - paneOpacity), 1)
    }

    func updateFromConfig(passthrough: String, followEngine: Bool, panePadding: Int = 14,
                          paneOpacity: Double = 0.92, inactiveBlur: Double = 2.5,
                          activeOpacity: Double = 0.98, barOpacity: Double = 0.75,
                          dividerOpacity: Double = 0.2, paneGap: Int = 5,
                          paneTitle: Bool = true, workspaceTitle: Bool = true) {
        self.paneGap = CGFloat(paneGap)  // pure UI layer
        paneTitleEnabled = paneTitle  // pure UI layer
        workspaceTitleEnabled = workspaceTitle  // pure UI layer
        self.activeOpacity = activeOpacity  // pure UI layer
        self.inactiveBlur = inactiveBlur  // pure UI layer
        self.barOpacity = barOpacity  // pure UI layer
        self.dividerOpacity = dividerOpacity  // pure UI layer
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

    /// Engine reload hooks. With multiple screens, AppDelegate registers the app-level reload and
    /// every MainWindowController registers its own per-surface reload plus window appearance.
    /// Back when this was a single closure, only the most recently created window reacted to a
    /// live theme switch.
    private var overlayListeners: [(token: ObjectIdentifier, action: () -> Void)] = []

    /// Register an overlay-change listener. `token` is the owner: registering the same token
    /// again replaces the previous listener.
    func addOverlayListener(token: AnyObject, _ action: @escaping () -> Void) {
        let id = ObjectIdentifier(token)
        overlayListeners.removeAll { $0.token == id }
        overlayListeners.append((id, action))
    }

    /// Unregister a listener. A window must call this when it closes: a closure left in the array
    /// keeps its controller alive.
    func removeOverlayListener(token: AnyObject) {
        let id = ObjectIdentifier(token)
        overlayListeners.removeAll { $0.token == id }
    }

    /// Tests only: how many listeners are registered right now.
    var overlayListenerCount: Int { overlayListeners.count }

    private static let defaultsThemeKey = "quickterm.theme"
    private static let defaultsBgKey = "quickterm.backgroundIndex"

    // MARK: Palette (the UI layer's only source of color)

    /// Directory of user-supplied wallpapers, shared by every theme:
    /// ~/.config/quickterm/backgrounds/
    static var userBackgroundsDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/quickterm/backgrounds", isDirectory: true)
    }
    @Published private(set) var userBackgrounds: [URL] = []

    /// The images in a directory, sorted by file name; anything that is not an image is skipped.
    static func discoverBackgrounds(in dir: URL) -> [URL] {
        let exts: Set<String> = ["png", "jpg", "jpeg", "webp", "heic", "gif", "tiff"]
        return ((try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { exts.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// The choosable wallpapers: the ones the current theme ships plus the user's own. The
    /// picker grid and the Cmd+Ctrl+Space cycle share this one list.
    var backgroundChoices: [URL] { current.backgroundURLs + userBackgrounds }

    /// Import a wallpaper: copy it into the user directory (a name clash gets a timestamp
    /// appended) and select it straight away.
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
        // At startup the engine does not exist yet, so only write the file for the first load.
        writeOverlay(notify: false)
    }

    /// The bundled Themes/ directory union the user's own; on a name collision the user's theme
    /// wins (spec §4.5).
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

    // MARK: Switching

    func apply(_ theme: Theme) {
        current = theme
        backgroundIndex = 0
        UserDefaults.standard.set(theme.name, forKey: Self.defaultsThemeKey)
        UserDefaults.standard.set(0, forKey: Self.defaultsBgKey)
        writeOverlay()
    }

    /// Next wallpaper, wrapping around (spec §4.3).
    func nextBackground() {
        guard backgroundChoices.count > 1 else { return }
        selectBackground((backgroundIndex + 1) % backgroundChoices.count)
    }

    func selectBackground(_ index: Int) {
        guard backgroundChoices.indices.contains(index) else { return }
        backgroundIndex = index
        UserDefaults.standard.set(index, forKey: Self.defaultsBgKey)
        // The wallpaper lives in QuickTerm's own drawing layer, never in the engine config, so
        // there is nothing to reload.
    }

    func toggleOpacity() {
        opacityEnabled.toggle()
        writeOverlay()
    }

    func toggleGaps() {
        gapsEnabled.toggle()  // gaps are a pure UI layer, read by RootView/PaneChrome
    }

    // MARK: Engine overlay (layer 3 of the config chain; the mapping follows omarchy's
    // ghostty.conf.tpl)

    func overlayExtra() -> String {
        var lines: [String] = ["window-padding-x = \(panePadding)",
                               "window-padding-y = \(panePadding)"]
        if followEngineColors {
            // theme = "ghostty": colors and opacity follow ~/.config/ghostty/config entirely.
            // pane-padding is still a QuickTerm feature and is injected as usual; the [ghostty]
            // section can override everything at the end.
            var out: [String] = lines
            if !opacityEnabled {
                out.append("background-opacity = 1.0")
                out.append("unfocused-split-opacity = 1.0")
            }
            if !ghosttyPassthrough.isEmpty { out.append(ghosttyPassthrough) }
            return out.joined(separator: "\n")
        }
        // Pane background opacity: the basis for both clear and frosted glass. Text is never
        // affected.
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
        // A theme file (the fallback Builtin Pastel Dark, for one) may carry its own
        // cursor-text = #ffffff, which leaks through whenever the overlay does not write the key:
        // under a block cursor in a dark theme that turns into white text on a white background.
        // The overlay is replayed after the theme, so this line always wins (1.2+ supports the
        // `cell-background` value).
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
            // Override EngineOverlay's base section (for the same key, the later line wins).
            lines.append("background-opacity = 1.0")
            lines.append("unfocused-split-opacity = 1.0")
        }
        if !ghosttyPassthrough.isEmpty {
            lines.append(ghosttyPassthrough)  // layer 4 of the config chain: the final override
        }
        return lines.joined(separator: "\n")
    }

    private func writeOverlay(notify: Bool = true) {
        EngineOverlay.install(extra: overlayExtra())
        if notify { for listener in overlayListeners { listener.action() } }
    }
}
