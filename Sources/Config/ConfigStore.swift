import AppKit

/// `~/.config/quickterm/config.toml`（spec §4.7）：极简 TOML 子集
/// （顶层 key = value + `[keybinds]` + `[ghostty]` 原样透传段）。
enum ConfigStore {
    static let configURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/quickterm/config.toml")

    static let template = """
    # QuickTerm 配置（spec §4.7）。保存即热重载。
    # theme = "tokyo-night"     # 或 "ghostty"：不覆盖配色，完全跟随 ghostty 配置
    # workspaces = 5            # 1–10
    # pane-padding = 14         # pane 内终端四边留白（pt，0–32；Omarchy 官方值 14）

    [keybinds]
    # 动作 = "modifier+key"；"none" 解绑。动作清单见 Cmd+K 速查表。
    # new-terminal = "cmd+return"
    # goto-workspace-1 = "cmd+1"

    [ghostty]
    # 原样透传给引擎（最高优先级），任意 ghostty 选项。
    # cursor-style = block
    """

    struct Settings: Equatable {
        var themeName: String?
        var workspaces: Int = 5
        /// pane 内终端四边留白（pt，注入引擎 window-padding-x/y；spec v6 默认 14（= Omarchy 官方终端 padding））
        var panePadding: Int = 14
        /// 每屏可见列数（scrolling；nil = 未设置，走菜单选择/UserDefaults，默认 2）
        var visibleColumns: Int?
        /// 非激活 pane 整体透明度（0.3–1.0，默认 0.85；透出壁纸）
        var inactiveOpacity: Double = 0.85
        var overrides: [WMAction: KeyCombo] = [:]
        var unbound: Set<WMAction> = []
        var ghosttyPassthrough: String = ""
    }

    static func load() -> Settings {
        guard let toml = try? String(contentsOf: configURL, encoding: .utf8) else {
            return Settings()
        }
        return parse(toml)
    }

    static func parse(_ toml: String) -> Settings {
        var settings = Settings()
        var section = ""
        var passthrough: [String] = []
        for rawLine in toml.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("["), line.hasSuffix("]") {
                section = String(line.dropFirst().dropLast())
                continue
            }
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            if section == "ghostty" {
                passthrough.append(line)  // 原样透传（含 ghostty 自己的 key = value 语法）
                continue
            }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\"") {
                let inner = value.dropFirst()
                if let end = inner.firstIndex(of: "\"") { value = String(inner[..<end]) }
            } else if let hash = value.firstIndex(of: "#") {
                value = String(value[..<hash]).trimmingCharacters(in: .whitespaces)
            }
            switch section {
            case "":
                if key == "theme" { settings.themeName = value }
                if key == "workspaces", let n = Int(value) {
                    settings.workspaces = min(max(n, 1), 10)
                }
                if key == "pane-padding", let n = Int(value) {
                    settings.panePadding = min(max(n, 0), 32)
                }
                if key == "visible-columns", let n = Int(value) {
                    settings.visibleColumns = min(max(n, 1), 6)
                }
                if key == "inactive-opacity", let v = Double(value) {
                    settings.inactiveOpacity = min(max(v, 0.3), 1.0)
                }
            case "keybinds":
                guard let action = WMAction(rawValue: key) else { continue }
                if value.lowercased() == "none" {
                    settings.unbound.insert(action)
                } else if let combo = KeyCombo.parse(value) {
                    settings.overrides[action] = combo
                }
            default:
                break
            }
        }
        settings.ghosttyPassthrough = passthrough.joined(separator: "\n")
        return settings
    }
}

extension KeyCombo {
    /// 解析 "cmd+shift+left" 形式（spec §4.7 [keybinds] 值格式）
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

/// 目录级文件监听（编辑器原子替换也能捕获）→ 热重载
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
