import AppKit
import OSLog

/// `~/.config/quickterm/config.toml` (spec §4.7): a minimal TOML subset (`[section]` groups
/// plus the `[keybinds]` and `[ghostty]` sections, the latter passed through verbatim).
///
/// **The settings themselves are declared in the `ConfigSchema` registry** (group, type, range,
/// default value, the English and Chinese help text, the legacy spellings). Three jobs are left
/// here: writing the registry's values into `Settings` (`ConfigBindings`), laying down the
/// template and filling in missing keys, and rewriting one key in place.
enum ConfigStore {
    static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "dev.danny.quickterm",
                               category: "Config")

    static var configURL: URL { ConfigPaths.defaultConfigURL }

    /// **For test injection only**: the control plane's `workspace count` rewrites the config
    /// file, and a test host must never touch the user's real
    /// ~/.config/quickterm/config.toml.
    nonisolated(unsafe) static var configURLOverride: URL?

    /// The file we actually read and write.
    static var activeConfigURL: URL { configURLOverride ?? configURL }

    enum RewriteError: Error, CustomStringConvertible {
        case unreadable(String)
        case unwritable(String)
        case unknownKey(String)

        var description: String {
            switch self {
            // English on purpose, like every other CLI-facing string: this description is
            // handed back over the control socket (`quickterm workspace count` reports it),
            // and the CLI speaks English in both UI languages.
            case .unreadable(let path): "cannot read \(path)"
            case .unwritable(let path): "cannot write \(path)"
            case .unknownKey(let key): "\(key) is not a key in the config registry"
            }
        }
    }

    /// The template is rendered from the registry; there is no second, hand-written copy.
    static var template: String { ConfigSchema.template }

    /// Each setting's block in the template (the assignment line plus the continuation lines of
    /// a multi-line help text); reused when filling in missing keys.
    static var templateKeyBlocks: [(spec: ConfigKeySpec, lines: [String])] { ConfigSchema.templateKeyBlocks }

    // MARK: Rewriting in place

    /// Rewrite **one key from the registry** in place (`workspaces = 8`), leaving everything else,
    /// comments included, exactly as it was.
    ///
    /// Four rules:
    /// - Recognize **every spelling** of the key: the current one (`[workspace] workspaces`) and
    ///   the old flat one both count, and whichever the user wrote is the one we edit, so an
    ///   upgrade never reshuffles someone's file;
    /// - a commented-out key is replaced by a live line (every key in the template is commented
    ///   out);
    /// - not found anywhere in the file -> append it at the end of the group it belongs to,
    ///   creating that group if the file does not have it;
    /// - one write to disk. The existing `AppSession.installConfigWatcher` picks it up and hot
    ///   reloads; the caller **must not** also apply the value itself (two paths into effect =
    ///   two keymap rebuilds and one race).
    static func rewrite(key: String, value: String) throws {
        guard let spec = ConfigSchema.spec(named: key) else { throw RewriteError.unknownKey(key) }
        let url = activeConfigURL
        var text = (try? String(contentsOf: url, encoding: .utf8))
        if text == nil {
            // The file does not exist yet (a fresh install): lay down the template first, then
            // edit it.
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            try? template.write(to: url, atomically: true, encoding: .utf8)
            text = try? String(contentsOf: url, encoding: .utf8)
        }
        guard let content = text else { throw RewriteError.unreadable(url.path) }

        var lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var canonicalHit: Int?
        var legacyHit: (index: Int, name: String)?
        for (index, ref) in assignments(in: lines) {
            guard ref.spec.id == spec.id else { continue }
            if ref.ref == spec.canonical {
                if canonicalHit == nil { canonicalHit = index }
            } else if legacyHit == nil {
                legacyHit = (index, ref.ref.name)
            }
        }
        if let index = canonicalHit {
            lines[index] = "\(spec.key) = \(value)"
        } else if let hit = legacyHit {
            lines[hit.index] = "\(hit.name) = \(value)"
        } else {
            lines = insert(blocks: [spec.section.rawValue: ["\(spec.key) = \(value)"]], into: lines)
        }
        do {
            try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        } catch {
            throw RewriteError.unwritable(url.path)
        }
    }

    // MARK: Filling in the template

    /// Guarantee that the config file exists and lists every setting ("every setting must be
    /// written down in the config file"):
    /// - file missing -> write the whole template, creating the directory too;
    /// - file present -> fill in the missing keys (commented out, at their default value, at the
    ///   end of the group they belong to, creating that group if needed), leaving existing
    ///   settings untouched. **A legacy spelling also counts as "already there"**: an old config
    ///   file written flat does not get a duplicate entry added.
    /// Idempotent; returns whether anything was written. Called at startup and when the settings
    /// are opened.
    @discardableResult
    static func ensureTemplateKeys(at url: URL = activeConfigURL) -> Bool {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                try template.write(to: url, atomically: true, encoding: .utf8)
                return true
            } catch { return false }
        }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let mentioned = Set(assignments(in: lines).map(\.1.spec.id))
        let missing = ConfigSchema.keys.filter { !mentioned.contains($0.id) }
        guard !missing.isEmpty else { return false }

        // Copy the template block verbatim, continuation lines of multi-line help included, so
        // what gets filled in is word for word what a fresh install would have written.
        let templateBlock = Dictionary(uniqueKeysWithValues:
            ConfigSchema.templateKeyBlocks.map { ($0.spec.id, $0.lines) })
        var blocks: [String: [String]] = [:]
        for spec in missing {
            blocks[spec.section.rawValue, default: []]
                .append(contentsOf: templateBlock[spec.id] ?? spec.templateBlock())
        }
        let out = insert(blocks: blocks, into: lines)
        do {
            try out.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
            return true
        } catch { return false }
    }

    /// The banner above the auto-filled block, in the active UI language — the same rule the
    /// template comments follow.
    static var autofillBanner: String {
        ConfigSchema.templateLanguage == .zh
            ? "# —— QuickTerm 新增配置项（自动补全，注释 = 默认值）——"
            : "# —— New QuickTerm settings (filled in automatically; commented out = the default) ——"
    }

    /// Insert lines into a config file, grouped by section: the section exists -> append at the
    /// end of it; the section is missing -> create it, ahead of the two free-form sections
    /// `[keybinds]` and `[ghostty]`. Everything after those is passed through verbatim, so a
    /// setting parked below `[ghostty]` would read as if it were meant for the engine.
    private static func insert(blocks: [String: [String]], into lines: [String]) -> [String] {
        var pending = blocks
        var out: [String] = []
        var section = ""

        func flush(_ name: String) {
            guard let block = pending.removeValue(forKey: name) else { return }
            var trailing: [String] = []
            while out.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { trailing.append(out.removeLast()) }
            out.append(contentsOf: [autofillBanner] + block)
            out.append(contentsOf: trailing.isEmpty ? [""] : trailing)
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("["), let close = trimmed.firstIndex(of: "]") {
                flush(section)   // the previous section just ended
                section = String(trimmed[trimmed.index(after: trimmed.startIndex)..<close])
            }
            out.append(line)
        }
        flush(section)

        guard !pending.isEmpty else { return out }
        // Whatever is left belongs to sections the file does not have at all: create them in
        // registry order.
        var fresh: [String] = []
        for sectionCase in ConfigSection.allCases {
            guard let block = pending.removeValue(forKey: sectionCase.rawValue) else { continue }
            // Header plus section note: a freshly created group has to look like the template a
            // fresh install writes, not a bare [control] on its own — that note is where the
            // socket's path is written down.
            fresh.append(contentsOf: ConfigSchema.sectionHeaderLines(sectionCase))
            fresh.append(contentsOf: block)
            fresh.append("")
        }
        let freeform = ["keybinds", "ghostty"].map { "[\($0)]" }
        if let index = out.firstIndex(where: { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return freeform.contains { trimmed.hasPrefix($0) }
        }) {
            out.insert(contentsOf: fresh, at: index)
        } else {
            if out.last?.isEmpty == true { out.removeLast() }
            out.append(contentsOf: [""] + fresh)
        }
        return out
    }

    /// Every assignment to a registry key on **any line** of a config file, commented-out lines
    /// included. Both the template fill-in and the in-place rewrite go through this: "is this key
    /// already written in the file" gets to have exactly one answer.
    private static func assignments(in lines: [String]) -> [(Int, (ref: ConfigKeyRef, spec: ConfigKeySpec))] {
        var out: [(Int, (ref: ConfigKeyRef, spec: ConfigKeySpec))] = []
        var section = ""
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("["), let close = trimmed.firstIndex(of: "]") {
                section = String(trimmed[trimmed.index(after: trimmed.startIndex)..<close])
                continue
            }
            var body = Substring(trimmed)
            if body.hasPrefix("#") { body = body.dropFirst().drop(while: { $0 == " " }) }
            guard let eq = body.firstIndex(of: "=") else { continue }
            let name = body[..<eq].trimmingCharacters(in: .whitespaces)
            let ref = ConfigKeyRef(section, name)
            guard let spec = ConfigSchema.byRef[ref] else { continue }
            out.append((index, (ref, spec)))
        }
        return out
    }

    // MARK: Settings

    struct Settings: Equatable {
        /// UI language (`[general] language`): auto (follow the system) | en | zh.
        /// **UI only**: the program logs and the quickterm CLI are always English.
        var language: String = "auto"
        var themeName: String?
        var workspaces: Int = 5
        /// Terminal padding inside a pane, in pt, injected as the engine's window-padding-x/y.
        /// The spec v6 default is 14, which is Omarchy's own terminal padding.
        var panePadding: Int = 14
        /// Columns visible per screen in the scrolling layout. nil = unset, in which case the
        /// menu selection / UserDefaults decides, defaulting to 2.
        var visibleColumns: Int?
        /// Pane background opacity (0.5–1.0, default 0.92 = the inactive baseline); text is
        /// never affected.
        var paneOpacity: Double = 0.92
        /// Effective background opacity of the focused pane (0.5–1.0, default 0.98).
        var activeOpacity: Double = 0.98
        /// Top status bar background opacity (0.0–1.0, default 0.75); governed by the
        /// Cmd+Backspace master switch.
        var barOpacity: Double = 0.75
        /// Opacity of the thin dwindle divider (0.0–1.0, default 0.2; 0 hides it).
        var dividerOpacity: Double = 0.2
        /// Padding on every side of every pane (pt, 0–20, default 5 = the original scrolling
        /// value, which puts 10 between neighbours). Identical for scrolling, dwindle and
        /// floating panes.
        var paneGap: Int = 5
        /// Gaussian blur radius for inactive panes (0–10pt, default 2.5) — the frosted look.
        var inactiveBlur: Double = 2.5
        /// Draw the title on a pane's top border (on by default). Only titles that were set
        /// explicitly are drawn, truncated to 20 characters.
        var paneTitle: Bool = true
        /// Show the name in the workspace pill (on by default). Only workspaces that were given
        /// a name show one, truncated to 12 characters.
        var workspaceTitle: Bool = true
        /// The file manager program the `file-manager` action runs in a new pane. A bare name is
        /// looked up in PATH and in the usual install directories; an absolute path also works.
        var fileManagerCommand: String = FileManagerLaunch.defaultProgram
        /// Browser panes: home page, search template, user agent ("safari" to masquerade,
        /// "webkit" not to, or a custom string) and the Web Inspector.
        var browserHome: String = "https://www.google.com"
        var browserSearch: String = "https://www.google.com/search?q=%s"
        var browserUserAgent: String = "safari"
        var browserInspectable: Bool = false
        var browserTabBar: String = "always"
        var browserTabWidth: Int = 200
        var browserTabMinWidth: Int = 80
        /// Whether browser panes load WebExtensions. Turning it off unloads all of them, and new
        /// tabs get no controller attached either.
        var browserExtensions: Bool = true
        /// Download directory for browser panes (`~` is expanded; falls back to ~/Downloads when
        /// it is not a real directory).
        var browserDownloadDir: String = "~/Downloads"
        var linkOpener: String = "browser-pane"
        /// `[control] socket` (formerly `enabled`): false means we do not listen at all.
        /// **On** by default.
        var controlSocket: Bool = true
        /// `[control] mcp`: false makes `quickterm mcp` refuse to serve. **On** by default.
        /// Kept separate from `socket` because the two have different attack surfaces: a user may
        /// well want the CLI for themselves while wanting no MCP host — and every web page or CI
        /// log that host reads — to be able to connect.
        var controlMCP: Bool = true
        var controlMode: String = "ask"
        var controlExposeBrowser: String = "token"
        var controlSendText: Bool = false
        var controlCaptureText: Bool = false
        var overrides: [WMAction: KeyCombo] = [:]
        var unbound: Set<WMAction> = []
        var ghosttyPassthrough: String = ""
    }

    static func load() -> Settings {
        guard let toml = try? String(contentsOf: activeConfigURL, encoding: .utf8) else {
            return Settings()
        }
        let result = parseDetailed(toml)
        // A line whose value is not valid is dropped and the default kept. **Say so out loud**:
        // a spelling like `[control] socket = off` used to be silently read as "on", leaving the
        // user believing they had turned it off.
        for note in result.diagnostics {
            logger.warning("Config line had no effect: \(note.messageEN, privacy: .public)")
        }
        return result.settings
    }

    static func parse(_ toml: String) -> Settings { parseDetailed(toml).settings }

    /// Parse, plus the lines that **had no effect** (a future settings window will show each of
    /// them on the tab it belongs to).
    static func parseDetailed(_ toml: String) -> (settings: Settings, diagnostics: [ConfigDiagnostic]) {
        var settings = Settings()
        let scan = ConfigTOML.scan(toml)
        let resolved = ConfigSchema.resolveDetailed(scan)
        for (id, value) in resolved.values {
            ConfigBindings.table[id]?(value, &settings)
        }
        // [keybinds] is not part of the registry: its key names are the action list, see
        // WMAction.
        for entry in scan.entries where entry.section == "keybinds" {
            guard let action = WMAction(rawValue: entry.key) else { continue }
            if entry.value.lowercased() == "none" {
                settings.unbound.insert(action)
            } else if let combo = KeyCombo.parse(entry.value) {
                settings.overrides[action] = combo
            }
        }
        settings.ghosttyPassthrough = scan.ghostty.joined(separator: "\n")
        return (settings, resolved.diagnostics)
    }
}

/// Registry entry -> the `Settings` field it writes. **Assignment only, no validation**: the
/// type, the range and the out-of-range behavior are all declared in `ConfigSchema` and enforced
/// in one place. If this table checked anything a second time, the two could once again drift
/// apart. `ConfigSchemaTests.testEveryKeyHasABinding` pins the two tables to each other.
enum ConfigBindings {
    typealias Write = (ConfigValue, inout ConfigStore.Settings) -> Void

    static let table: [String: Write] = [
        "general.language": { v, s in v.stringValue.map { s.language = $0 } },
        "appearance.theme": { v, s in s.themeName = v.stringValue },
        "appearance.pane-opacity": { v, s in v.doubleValue.map { s.paneOpacity = $0 } },
        "appearance.active-opacity": { v, s in v.doubleValue.map { s.activeOpacity = $0 } },
        "appearance.bar-opacity": { v, s in v.doubleValue.map { s.barOpacity = $0 } },
        "appearance.divider-opacity": { v, s in v.doubleValue.map { s.dividerOpacity = $0 } },
        "appearance.inactive-blur": { v, s in v.doubleValue.map { s.inactiveBlur = $0 } },
        "appearance.pane-padding": { v, s in v.intValue.map { s.panePadding = $0 } },
        "appearance.pane-gap": { v, s in v.intValue.map { s.paneGap = $0 } },
        "appearance.pane-title": { v, s in v.boolValue.map { s.paneTitle = $0 } },
        "appearance.workspace-title": { v, s in v.boolValue.map { s.workspaceTitle = $0 } },
        "workspace.workspaces": { v, s in v.intValue.map { s.workspaces = $0 } },
        "workspace.visible-columns": { v, s in s.visibleColumns = v.intValue },
        "terminal.file-manager-command": { v, s in v.stringValue.map { s.fileManagerCommand = $0 } },
        "browser.home": { v, s in v.stringValue.map { s.browserHome = $0 } },
        "browser.search": { v, s in v.stringValue.map { s.browserSearch = $0 } },
        "browser.user-agent": { v, s in v.stringValue.map { s.browserUserAgent = $0 } },
        "browser.inspectable": { v, s in v.boolValue.map { s.browserInspectable = $0 } },
        "browser.tab-bar": { v, s in v.stringValue.map { s.browserTabBar = $0 } },
        "browser.tab-width": { v, s in v.intValue.map { s.browserTabWidth = $0 } },
        "browser.tab-min-width": { v, s in v.intValue.map { s.browserTabMinWidth = $0 } },
        "browser.extensions": { v, s in v.boolValue.map { s.browserExtensions = $0 } },
        "browser.download-dir": { v, s in v.stringValue.map { s.browserDownloadDir = $0 } },
        "browser.link-opener": { v, s in v.stringValue.map { s.linkOpener = $0 } },
        "control.socket": { v, s in v.boolValue.map { s.controlSocket = $0 } },
        "control.mcp": { v, s in v.boolValue.map { s.controlMCP = $0 } },
        "control.mode": { v, s in v.stringValue.map { s.controlMode = $0 } },
        "control.expose-browser": { v, s in v.stringValue.map { s.controlExposeBrowser = $0 } },
        "control.send-text": { v, s in v.boolValue.map { s.controlSendText = $0 } },
        "control.capture-text": { v, s in v.boolValue.map { s.controlCaptureText = $0 } },
    ]
}

extension KeyCombo {
    /// Parse the "cmd+shift+left" form (the [keybinds] value format from spec §4.7).
    static func parse(_ text: String) -> KeyCombo? {
        var flags: NSEvent.ModifierFlags = []
        var key: String?
        for part in text.lowercased().split(separator: "+").map(String.init) {
            switch part {
            case "cmd", "command", "super": flags.insert(.command)
            case "shift": flags.insert(.shift)
            case "alt", "option", "opt": flags.insert(.option)
            case "ctrl", "control": flags.insert(.control)
            default: key = part
            }
        }
        guard let key, !key.isEmpty else { return nil }
        return KeyCombo(key: key, flags)
    }
}

/// Directory-level file watching, which also catches the atomic replace an editor does on save,
/// and hot reloads from it.
final class ConfigWatcher {
    private var source: DispatchSourceFileSystemObject?
    private let fd: Int32

    init?(directory: URL, onChange: @escaping () -> Void) {
        fd = open(directory.path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write], queue: .main)
        source.setEventHandler(handler: onChange)
        source.setCancelHandler { [fd] in close(fd) }
        source.resume()
        self.source = source
    }

    deinit { source?.cancel() }
}
