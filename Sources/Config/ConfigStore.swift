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
    # visible-columns = 2       # scrolling 每屏可见列数（1–6；未设置走主菜单选择）
    # pane-opacity = 0.92       # pane 背景透明度（0.5–1.0；非激活基准，文字不受影响）
    # active-opacity = 0.98     # 激活 pane 背景等效透明度（0.5–1.0）
    # bar-opacity = 0.75        # 顶部状态条背景透明度（0–1）
    # divider-opacity = 0.2     # dwindle 分隔细线不透明度（0–1；0 隐藏，1 实线）
    # pane-gap = 5              # 每 pane 每边留白 pt（0–20；相邻间距 = 2×gap；scrolling / dwindle 一致）
    # inactive-blur = 2.5       # 非激活 pane 磨砂背景（> 0 开启；0 关闭）
    # file-manager-command = "yazi"   # 文件管理器程序（Cmd+Shift+B 在新 pane 里运行；名字或绝对路径，lf/ranger 亦可）
    # browser-home = "https://www.google.com"   # 浏览器 pane（Cmd+B）打开的首页
    # browser-search = "https://www.google.com/search?q=%s"   # 地址栏输入非网址时的搜索模板（%s = 关键词）
    # browser-user-agent = "safari"   # 伪装成 Safari（Google 登录页拒绝嵌入式浏览器）；"webkit" = 不伪装；或填自定义 UA
    # browser-inspectable = false     # 浏览器 pane 的 Web Inspector（右键"检查元素"）

    [keybinds]
    # 动作 = "modifier+key"；"none" 解绑。动作清单见 Cmd+K 速查表。
    # new-terminal = "cmd+return"
    # file-manager = "cmd+shift+b"
    # new-browser = "cmd+b"
    # goto-workspace-1 = "cmd+1"

    [ghostty]
    # 原样透传给引擎（最高优先级），任意 ghostty 选项。
    # cursor-style = block
    """

    /// 模板顶层键的标准行（"# key = 默认  # 说明"），按模板顺序；补全缺失键时复用
    static var templateKeyLines: [(key: String, line: String)] {
        // 只扫第一个 [section] 之前的顶层键：[keybinds]/[ghostty] 里的示例行不是顶层配置项
        template.split(separator: "\n", omittingEmptySubsequences: false)
            .prefix { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("[") }
            .compactMap { raw in
            let line = String(raw)
            guard line.hasPrefix("# ") else { return nil }
            let body = line.dropFirst(2)
            guard let eq = body.firstIndex(of: "=") else { return nil }
            let key = body[..<eq].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, key.allSatisfy({ $0.isLetter || $0 == "-" }) else { return nil }
            return (key, line)
        }
    }

    /// 保证配置文件存在且列全所有顶层键（"所有配置项都要写在配置文件里"）：
    /// - 文件不存在 → 写完整模板（含目录）；
    /// - 已存在 → 补全缺失键（注释 + 默认值，插在第一个 [section] 之前），已有设置原样保留。
    /// 幂等；返回是否有写入。启动与打开设置时调用。
    @discardableResult
    static func ensureTemplateKeys(at url: URL = configURL) -> Bool {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                try template.write(to: url, atomically: true, encoding: .utf8)
                return true
            } catch { return false }
        }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        func mentions(_ key: String) -> Bool {
            lines.contains { line in
                var s = Substring(line.trimmingCharacters(in: .whitespaces))
                if s.hasPrefix("#") { s = s.dropFirst().drop(while: { $0 == " " }) }
                guard s.hasPrefix(key) else { return false }
                let rest = s.dropFirst(key.count).drop(while: { $0 == " " })
                return rest.hasPrefix("=")
            }
        }
        let missing = templateKeyLines.filter { !mentions($0.key) }
        guard !missing.isEmpty else { return false }
        var out = lines
        let block = ["# —— QuickTerm 新增配置项（自动补全，注释 = 默认值）——"] + missing.map(\.line) + [""]
        if let sectionIdx = out.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("[") }) {
            out.insert(contentsOf: block, at: sectionIdx)
        } else {
            if out.last == "" { out.removeLast() }
            out.append(contentsOf: [""] + block)
        }
        do {
            try out.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
            return true
        } catch { return false }
    }

    struct Settings: Equatable {
        var themeName: String?
        var workspaces: Int = 5
        /// pane 内终端四边留白（pt，注入引擎 window-padding-x/y；spec v6 默认 14（= Omarchy 官方终端 padding））
        var panePadding: Int = 14
        /// 每屏可见列数（scrolling；nil = 未设置，走菜单选择/UserDefaults，默认 2）
        var visibleColumns: Int?
        /// pane 背景透明度（0.5–1.0，默认 0.92 = 非激活基准；文字不受影响）
        var paneOpacity: Double = 0.92
        /// 激活 pane 背景等效透明度（0.5–1.0，默认 0.98）
        var activeOpacity: Double = 0.98
        /// 顶部状态条背景透明度（0.0–1.0，默认 0.75；受 Cmd+Backspace 总开关控制）
        var barOpacity: Double = 0.75
        /// dwindle 分隔细线不透明度（0.0–1.0，默认 0.2；0 = 隐藏）
        var dividerOpacity: Double = 0.2
        /// 每 pane 每边留白（pt，0–20，默认 5 = 原 scrolling 值：相邻间距 10；scrolling / dwindle / 浮动一致）
        var paneGap: Int = 5
        /// 非激活 pane 高斯模糊半径（0–10pt，默认 2.5；磨砂感）
        var inactiveBlur: Double = 2.5
        /// 文件管理器程序（`file-manager` 动作在新 pane 里运行；名字按 PATH + 常见安装目录查找，或绝对路径）
        var fileManagerCommand: String = FileManagerLaunch.defaultProgram
        /// 浏览器 pane：首页 / 搜索模板 / UA（"safari" 伪装、"webkit" 不伪装、或自定义）/ Web Inspector
        var browserHome: String = "https://www.google.com"
        var browserSearch: String = "https://www.google.com/search?q=%s"
        var browserUserAgent: String = "safari"
        var browserInspectable: Bool = false
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
        var sawPaneGap = false   // pane-gap 优先于旧键 dwindle-gap（与出现顺序无关）
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
                if key == "pane-opacity", let v = Double(value) {
                    settings.paneOpacity = min(max(v, 0.5), 1.0)
                }
                if key == "active-opacity", let v = Double(value) {
                    settings.activeOpacity = min(max(v, 0.5), 1.0)
                }
                if key == "bar-opacity", let v = Double(value) {
                    settings.barOpacity = min(max(v, 0.0), 1.0)
                }
                if key == "divider-opacity", let v = Double(value) {
                    settings.dividerOpacity = min(max(v, 0.0), 1.0)
                }
                if key == "pane-gap", let v = Int(value) {
                    settings.paneGap = min(max(v, 0), 20)
                    sawPaneGap = true
                }
                if key == "dwindle-gap", let v = Int(value), !sawPaneGap {
                    // 旧键（曾只作用于 dwindle）：pane-gap 未出现时沿用其值，两种布局一致
                    settings.paneGap = min(max(v, 0), 20)
                }
                if key == "inactive-blur", let v = Double(value) {
                    settings.inactiveBlur = min(max(v, 0), 10)
                }
                if key == "file-manager-command", !value.isEmpty {
                    settings.fileManagerCommand = value
                }
                if key == "browser-home", !value.isEmpty { settings.browserHome = value }
                if key == "browser-search", !value.isEmpty { settings.browserSearch = value }
                if key == "browser-user-agent", !value.isEmpty { settings.browserUserAgent = value }
                if key == "browser-inspectable" { settings.browserInspectable = (value.lowercased() == "true") }
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
