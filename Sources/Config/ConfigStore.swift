import AppKit
import OSLog

/// `~/.config/quickterm/config.toml`（spec §4.7）：极简 TOML 子集
/// （`[section]` 分组 + `[keybinds]` + `[ghostty]` 原样透传段）。
///
/// **配置项本身在 `ConfigSchema` 那张注册表里声明**（分组、类型、范围、默认值、
/// 中英文说明、旧写法）。这里只剩三件事：把注册表的值写进 `Settings`（`ConfigBindings`）、
/// 落模板 / 补全缺键、以及就地改写一个键。
enum ConfigStore {
    static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "dev.danny.quickterm",
                               category: "Config")

    static var configURL: URL { ConfigPaths.defaultConfigURL }

    /// **只给用例注入**：控制面的 `workspace count` 会改写配置文件，
    /// 测试宿主绝不能去动用户真正的 ~/.config/quickterm/config.toml
    nonisolated(unsafe) static var configURLOverride: URL?

    /// 实际读写的那一份
    static var activeConfigURL: URL { configURLOverride ?? configURL }

    enum RewriteError: Error, CustomStringConvertible {
        case unreadable(String)
        case unwritable(String)
        case unknownKey(String)

        var description: String {
            switch self {
            case .unreadable(let path): "读不到 \(path)"
            case .unwritable(let path): "写不进 \(path)"
            case .unknownKey(let key): "配置注册表里没有 \(key) 这个键"
            }
        }
    }

    /// 模板 = 注册表渲染出来的那一份（没有第二份手写模板）
    static var template: String { ConfigSchema.template }

    /// 模板里每个配置项的那一块（赋值行 + 多行说明的续行；补全缺失键时复用）
    static var templateKeyBlocks: [(spec: ConfigKeySpec, lines: [String])] { ConfigSchema.templateKeyBlocks }

    // MARK: 就地改写

    /// 就地改写**一个注册表里的键**（`workspaces = 8`），保留其余内容与注释。
    ///
    /// 四条规矩：
    /// - 认这个键的**每一种写法**：新写法（`[workspace] workspaces`）与旧的扁平写法都算，
    ///   用户写的是哪一种就改哪一种（升级不会把人家的文件重排一遍）；
    /// - 键被注释掉了就把那一行换成生效的写法（模板里所有键都是注释形式）；
    /// - 一份文件里都找不到 → 插到它所属的分组末尾（分组不存在就现建一个）；
    /// - 一次写盘。写完由已有的 `AppSession.installConfigWatcher` 去热重载，
    ///   调用方**不得**自己再落一次值（两条生效路径 = 两次键位表重建 + 一次竞态）
    static func rewrite(key: String, value: String) throws {
        guard let spec = ConfigSchema.spec(named: key) else { throw RewriteError.unknownKey(key) }
        let url = activeConfigURL
        var text = (try? String(contentsOf: url, encoding: .utf8))
        if text == nil {
            // 文件还不存在（全新安装）：先落模板，再改
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

    // MARK: 模板补全

    /// 保证配置文件存在且列全所有配置项（"所有配置项都要写在配置文件里"）：
    /// - 文件不存在 → 写完整模板（含目录）；
    /// - 已存在 → 补全缺失键（注释 + 默认值，插在它所属分组的末尾；分组不存在就现建），
    ///   已有设置原样保留。**旧写法也算"已经有了"**：用扁平写法的老配置文件不会被补一份重复的。
    /// 幂等；返回是否有写入。启动与打开设置时调用。
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

        // 整块照抄模板（含多行说明的续行）：补上来的段落与全新安装写下的逐字一致
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

    static let autofillBanner = "# —— QuickTerm 新增配置项（自动补全，注释 = 默认值）——"

    /// 把若干行按分组插进一份配置文件：分组在 → 插在那一段末尾；分组不在 → 现建一段，
    /// 摆在 `[keybinds]` / `[ghostty]` 这两个自由段之前（它们后面的内容是原样透传的，
    /// 把配置项塞到 `[ghostty]` 后面只会让人以为那是给引擎的）
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
                flush(section)   // 上一段结束了
                section = String(trimmed[trimmed.index(after: trimmed.startIndex)..<close])
            }
            out.append(line)
        }
        flush(section)

        guard !pending.isEmpty else { return out }
        // 还没落的都是文件里根本没有的分组：按注册表顺序现建
        var fresh: [String] = []
        for sectionCase in ConfigSection.allCases {
            guard let block = pending.removeValue(forKey: sectionCase.rawValue) else { continue }
            // 段头 + 段说明：现建的分组要和全新安装的模板长得一样，
            // 不能只有一个光秃秃的 [control]（那段说明里写着 socket 的落点）
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

    /// 一份配置文件里**每一行**（含被注释掉的）对注册表键的赋值。
    /// 模板补全与就地改写都靠它 —— "这个键是不是已经写在文件里了"只能有一种判断
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

    // MARK: 设置

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
        /// 在 pane 上边框上画标题（默认开；只画显式设过的标题，最长 20 字）
        var paneTitle: Bool = true
        /// 文件管理器程序（`file-manager` 动作在新 pane 里运行；名字按 PATH + 常见安装目录查找，或绝对路径）
        var fileManagerCommand: String = FileManagerLaunch.defaultProgram
        /// 浏览器 pane：首页 / 搜索模板 / UA（"safari" 伪装、"webkit" 不伪装、或自定义）/ Web Inspector
        var browserHome: String = "https://www.google.com"
        var browserSearch: String = "https://www.google.com/search?q=%s"
        var browserUserAgent: String = "safari"
        var browserInspectable: Bool = false
        var browserTabBar: String = "always"
        var browserTabWidth: Int = 200
        var browserTabMinWidth: Int = 80
        /// 浏览器 pane 是否加载 WebExtensions（关掉 = 全部 unload，新标签也不挂 controller）
        var browserExtensions: Bool = true
        /// 浏览器 pane 的下载目录（支持 `~`；不是个真目录时回退 ~/Downloads）
        var browserDownloadDir: String = "~/Downloads"
        var linkOpener: String = "browser-pane"
        /// `[control] socket`（旧名 `enabled`）：false = 彻底不监听。默认**开**
        var controlSocket: Bool = true
        /// `[control] mcp`：false = `quickterm mcp` 拒绝服务。默认**开**。
        /// 与 socket 分开，是因为两者的攻击面不同：用户完全可能自己用命令行，
        /// 却不想任何 MCP 宿主（以及它读到的每一段网页 / CI 日志）连进来
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
        // 值不合法的行会被丢掉、保留默认。**必须说一声**：
        // `[control] socket = off` 这种写法以前会被悄悄读成"开"，用户以为自己关掉了
        for note in result.diagnostics {
            logger.warning("配置未生效：\(note.messageZH, privacy: .public)")
        }
        return result.settings
    }

    static func parse(_ toml: String) -> Settings { parseDetailed(toml).settings }

    /// 解析 + 那些**没生效**的行（设置界面将来要把它们显示在对应 tab 上）
    static func parseDetailed(_ toml: String) -> (settings: Settings, diagnostics: [ConfigDiagnostic]) {
        var settings = Settings()
        let scan = ConfigTOML.scan(toml)
        let resolved = ConfigSchema.resolveDetailed(scan)
        for (id, value) in resolved.values {
            ConfigBindings.table[id]?(value, &settings)
        }
        // [keybinds] 不是注册表项（键名 = 动作清单，见 WMAction）
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

/// 注册表项 → `Settings` 的哪一个字段。**只有赋值，没有校验**：
/// 类型、范围、越界脾气全在 `ConfigSchema` 里声明并统一执行，
/// 这张表要是自己再判一次，两边就又能各走各的了。
/// `ConfigSchemaTests.testEveryKeyHasABinding` 钉死两张表一一对应
enum ConfigBindings {
    typealias Write = (ConfigValue, inout ConfigStore.Settings) -> Void

    static let table: [String: Write] = [
        "appearance.theme": { v, s in s.themeName = v.stringValue },
        "appearance.pane-opacity": { v, s in v.doubleValue.map { s.paneOpacity = $0 } },
        "appearance.active-opacity": { v, s in v.doubleValue.map { s.activeOpacity = $0 } },
        "appearance.bar-opacity": { v, s in v.doubleValue.map { s.barOpacity = $0 } },
        "appearance.divider-opacity": { v, s in v.doubleValue.map { s.dividerOpacity = $0 } },
        "appearance.inactive-blur": { v, s in v.doubleValue.map { s.inactiveBlur = $0 } },
        "appearance.pane-padding": { v, s in v.intValue.map { s.panePadding = $0 } },
        "appearance.pane-gap": { v, s in v.intValue.map { s.paneGap = $0 } },
        "appearance.pane-title": { v, s in v.boolValue.map { s.paneTitle = $0 } },
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
