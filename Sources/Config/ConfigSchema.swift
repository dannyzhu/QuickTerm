import Foundation

/// **配置项注册表：每个配置项只在这里声明一次。**
///
/// 模板、解析与校验、README 的配置表格、以及将来的设置界面（一个分组 = 一个 tab）
/// 全部从这张表生成。与 `Sources/Control/Wire/ControlCommandTable.swift` 同一条规矩——
/// 手写第二份描述，两个版本之内必然漂移，而漂移的那一份会以"配置写了却不生效"的形式
/// 砸在用户脸上。
///
/// **纯 Foundation**：本文件同时编进 app 与 `quickterm` 工具 target
/// （`quickterm mcp` 要在不启动 app 的情况下读到 `[control] mcp`）。
/// 一旦 import AppKit，CLI 就背上了整个 UI 栈。
///
/// 分组与旧写法：v1.5.9 起配置按功能分组（`[appearance]` / `[workspace]` / `[terminal]` /
/// `[browser]` / `[control]`）。**旧的扁平写法一律永远接受**（见每个键的 `legacy`）：
/// 用户的 ~/.config/quickterm/config.toml 不必改一个字。
enum ConfigSection: String, CaseIterable, Codable {
    case appearance
    case workspace
    case terminal
    case browser
    case control
    case keybinds
    case ghostty

    var titleZH: String {
        switch self {
        case .appearance: "外观"
        case .workspace: "工作区"
        case .terminal: "终端"
        case .browser: "浏览器"
        case .control: "控制面"
        case .keybinds: "快捷键"
        case .ghostty: "引擎透传"
        }
    }

    var titleEN: String {
        switch self {
        case .appearance: "Appearance"
        case .workspace: "Workspaces"
        case .terminal: "Terminal"
        case .browser: "Browser"
        case .control: "Control plane"
        case .keybinds: "Keybinds"
        case .ghostty: "Ghostty passthrough"
        }
    }

    /// 这一段在模板里写在段头下面的说明（可多行）
    var noteZH: String? {
        switch self {
        case .control:
            """
            控制面（quickterm 命令行 / AI agent）。socket：~/Library/Application Support/QuickTerm/control.sock
            """
        case .keybinds:
            """
            动作 = "modifier+key"；"none" 解绑。动作清单见 Cmd+K 速查表。
            """
        case .ghostty:
            """
            原样透传给引擎（最高优先级），任意 ghostty 选项。
            """
        default: nil
        }
    }

    /// 段尾附的固定示例行（`[keybinds]` / `[ghostty]` 是自由段，没有注册表项）
    var extraTemplateLines: [String] {
        switch self {
        case .keybinds:
            ["# new-terminal = \"cmd+return\"",
             "# file-manager = \"cmd+shift+b\"",
             "# new-browser = \"cmd+b\"",
             "# clear-terminal = \"cmd+shift+k\"",
             "# goto-workspace-1 = \"cmd+1\""]
        case .ghostty:
            ["# cursor-style = block"]
        default: []
        }
    }

    /// 有注册表项的分组 = 设置界面的 tab（`[keybinds]` 自有界面，`[ghostty]` 是文本框）
    var hasRegisteredKeys: Bool { !(self == .keybinds || self == .ghostty) }
}

/// 配置文件里的一个写法（段名 + 键名）。段名 `""` = 第一个 `[section]` 之前的顶层键
struct ConfigKeyRef: Hashable {
    var section: String
    var name: String

    init(_ section: String, _ name: String) {
        self.section = section
        self.name = name
    }
}

/// 值的类型 + 合法范围。**范围写在这里，校验只有一份实现**
enum ConfigKind: Equatable {
    case bool
    /// 越界 clamp（与历史行为一致）
    case int(min: Int, max: Int)
    case double(min: Double, max: Double)
    /// `strict` = 不在表里的值一律拒绝（保留默认）；否则非空即收（历史行为）
    case enumeration(values: [String], strict: Bool)
    case string
    /// 文件系统路径（支持 `~`）。校验上等同 string，设置界面里应给一个"选目录"按钮
    case path

    /// 这个键收什么值（写进被拒绝时那条提示里，将来也是设置界面的输入提示）
    var expectationZH: String {
        switch self {
        case .bool: "true / false（也认 1 / 0、yes / no、on / off）"
        case .int(let lo, let hi): "\(lo)–\(hi) 的整数"
        case .double(let lo, let hi): "\(lo)–\(hi) 之间的数"
        case .enumeration(let values, let strict):
            strict ? values.joined(separator: " | ") : "\(values.joined(separator: " | ")) 或自定义值（非空）"
        case .string: "非空字符串"
        case .path: "路径（支持 ~）"
        }
    }

    /// 越界怎么办：数值 clamp，其余（布尔 / 枚举 / 空字符串）拒绝并保留默认
    var outOfRange: ConfigOutOfRange {
        switch self {
        case .int, .double: .clamp
        default: .reject
        }
    }
}

/// 越界行为。**照抄历史行为**，绝不在这次重构里悄悄改掉任何一个键的脾气
enum ConfigOutOfRange: String, Codable {
    /// 夹到区间端点
    case clamp
    /// 整条丢掉，保留默认值
    case reject
}

/// 一条**没生效**的配置行：值不合法，已按该键的脾气保留默认。
/// 启动 / 热重载时打日志；将来的设置界面把它显示在对应 tab 上——
/// "写了却不生效"必须有个地方看得见，否则用户只会以为程序坏了
struct ConfigDiagnostic: Equatable {
    /// 注册表 id（`control.socket`）
    var id: String
    /// 用户实际写的那个写法（可能是旧名）
    var ref: ConfigKeyRef
    var raw: String
    var messageZH: String

    var displayKey: String { ref.section.isEmpty ? ref.name : "[\(ref.section)] \(ref.name)" }
}

enum ConfigValue: Equatable {
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)

    var boolValue: Bool? { if case .bool(let v) = self { v } else { nil } }
    var intValue: Int? { if case .int(let v) = self { v } else { nil } }
    var doubleValue: Double? { if case .double(let v) = self { v } else { nil } }
    var stringValue: String? { if case .string(let v) = self { v } else { nil } }

    /// 写进配置文件的字面量（字符串带引号）
    var literal: String {
        switch self {
        case .bool(let v): String(v)
        case .int(let v): String(v)
        case .double(let v): Self.trim(v)
        case .string(let v): "\"\(v)\""
        }
    }

    private static func trim(_ v: Double) -> String {
        let s = String(format: "%g", v)
        return s
    }
}

/// 新旧写法同时出现时怎么办
enum ConfigLegacyPolicy {
    /// 新名赢（与出现顺序无关）。`pane-gap` 压 `dwindle-gap` 就是这一档
    case canonicalWins
    /// **最严的那个赢**（布尔与逻辑）。`[control] socket` 与旧的 `enabled` 是这一档：
    /// 两个开关都在说"要不要监听"，写了任何一个 false 就必须不监听——
    /// 让新名把旧名的 false 顶掉，等于用户升级一次版本就被悄悄打开了一个他关掉过的口子
    case mostRestrictive
}

/// 一个配置项。
struct ConfigKeySpec {
    var section: ConfigSection
    /// 分组内的键名（`[browser] home`）。**不带分组前缀**——段名已经说了
    var key: String
    var kind: ConfigKind
    /// 默认值（= 模板里注释掉的那个值）
    var defaultValue: ConfigValue
    /// 保存即生效
    var hotReload: Bool
    var labelZH: String
    var labelEN: String
    var helpZH: String
    var helpEN: String
    /// 永远接受的旧写法（升级后不必改配置文件）
    var legacy: [ConfigKeyRef]
    var legacyPolicy: ConfigLegacyPolicy
    /// 空字符串也算一个值（只有 `theme` 是这样：写空 = 显式不选主题）
    var acceptsEmpty: Bool
    /// 枚举值的别名（`mode = "on"` → `ask`）
    var valueAliases: [String: String]

    init(_ section: ConfigSection, _ key: String, _ kind: ConfigKind,
         default defaultValue: ConfigValue,
         hotReload: Bool = true,
         labelZH: String, labelEN: String, helpZH: String, helpEN: String,
         legacy: [ConfigKeyRef] = [], legacyPolicy: ConfigLegacyPolicy = .canonicalWins,
         acceptsEmpty: Bool = false, valueAliases: [String: String] = [:]) {
        self.section = section
        self.key = key
        self.kind = kind
        self.defaultValue = defaultValue
        self.hotReload = hotReload
        self.labelZH = labelZH
        self.labelEN = labelEN
        self.helpZH = helpZH
        self.helpEN = helpEN
        self.legacy = legacy
        self.legacyPolicy = legacyPolicy
        self.acceptsEmpty = acceptsEmpty
        self.valueAliases = valueAliases
    }

    /// 注册表里的唯一标识（`browser.home`）；绑定表、resolve 的结果都按它索引
    var id: String { "\(section.rawValue).\(key)" }
    var canonical: ConfigKeyRef { ConfigKeyRef(section.rawValue, key) }
    var outOfRange: ConfigOutOfRange { kind.outOfRange }
    /// 这个配置项认得的所有写法（新名在前）
    var allRefs: [ConfigKeyRef] { [canonical] + legacy }

    /// 模板 / README 里那一行左半边（`# home = "https://www.google.com"`）
    var templateAssignment: String { "# \(key) = \(defaultValue.literal)" }

    /// 这个配置项在模板里的**完整**块：赋值行 + 对齐的续行（多行说明）。
    /// 渲染模板与"补全缺失键"共用它——补全时只抄第一行，等于把
    /// `send-text` 那段"**等于在那个 shell 里打字**"的警告丢在新装用户那边，
    /// 升级上来的用户永远看不到
    func templateBlock(width: Int? = nil) -> [String] {
        let assignment = templateAssignment
        let column = max(width ?? assignment.count, assignment.count)
        let pad = String(repeating: " ", count: max(1, column - assignment.count + 2))
        let help = helpZH.split(separator: "\n", omittingEmptySubsequences: false)
        var out = ["\(assignment)\(pad)# \(help[0])"]
        // 续行与第一行的 `#` 对齐：模板本身也要好读
        let indent = String(repeating: " ", count: column + 1)
        for extra in help.dropFirst() { out.append("#\(indent)# \(extra)") }
        return out
    }

    /// 布尔字面量表（大小写不敏感）。TOML 只认 true/false，
    /// 但人手写配置时 1/0、yes/no、on/off 都会写，认下来比装作没看见安全
    static let trueLiterals: Set<String> = ["true", "1", "yes", "on"]
    static let falseLiterals: Set<String> = ["false", "0", "no", "off"]

    static func boolLiteral(_ raw: String) -> Bool? {
        let lowered = raw.lowercased()
        if trueLiterals.contains(lowered) { return true }
        if falseLiterals.contains(lowered) { return false }
        return nil
    }

    /// 把一行原始值收成一个合法值。`nil` = 拒绝（保留默认），并由 `resolve` 记一条 diagnostic
    func coerce(_ raw: String) -> ConfigValue? {
        switch kind {
        case .bool:
            // 布尔只认这张表。**不认得的值一律拒绝**（= 保留默认，并留下一条 diagnostic），
            // 绝不"猜一个"——重构前每个布尔键各写一行 `!= "false"` / `== "true"`，
            // 结果是默认开的键写 off / 0 / no 全都悄悄留在"开"上：
            // 而 `[control] socket` / `mcp` 是两个安全开关，`mode` 的说明就在下一行教人写 off
            guard let value = ConfigKeySpec.boolLiteral(raw) else { return nil }
            return .bool(value)
        case .int(let lo, let hi):
            guard let n = Int(raw) else { return nil }
            return .int(min(max(n, lo), hi))
        case .double(let lo, let hi):
            guard let v = Double(raw) else { return nil }
            return .double(min(max(v, lo), hi))
        case .enumeration(let values, let strict):
            if strict {
                let lowered = raw.lowercased()
                let mapped = valueAliases[lowered] ?? lowered
                guard values.contains(mapped) else { return nil }
                return .string(mapped)
            }
            // 宽松枚举（tab-bar / link-opener）：历史行为是"非空就照收"，
            // 不认得的值由使用方各自兜底。这次重构不改它的脾气
            guard !raw.isEmpty else { return nil }
            return .string(valueAliases[raw] ?? raw)
        case .string, .path:
            guard acceptsEmpty || !raw.isEmpty else { return nil }
            return .string(raw)
        }
    }
}

enum ConfigSchema {
    // MARK: 注册表

    static let keys: [ConfigKeySpec] = [
        // MARK: [appearance]
        ConfigKeySpec(.appearance, "theme", .string, default: .string("tokyo-night"),
                      labelZH: "主题", labelEN: "Theme",
                      helpZH: "或 \"ghostty\"：不覆盖配色，完全跟随 ghostty 配置",
                      helpEN: "or \"ghostty\": don't touch colours, follow ~/.config/ghostty/config entirely",
                      legacy: [ConfigKeyRef("", "theme")], acceptsEmpty: true),
        ConfigKeySpec(.appearance, "pane-opacity", .double(min: 0.5, max: 1.0), default: .double(0.92),
                      labelZH: "pane 背景透明度", labelEN: "Pane opacity",
                      helpZH: "pane 背景透明度（0.5–1.0；非激活基准，文字不受影响）",
                      helpEN: "0.5–1.0, inactive baseline; text is never affected",
                      legacy: [ConfigKeyRef("", "pane-opacity")]),
        ConfigKeySpec(.appearance, "active-opacity", .double(min: 0.5, max: 1.0), default: .double(0.98),
                      labelZH: "激活 pane 透明度", labelEN: "Active pane opacity",
                      helpZH: "激活 pane 背景等效透明度（0.5–1.0）",
                      helpEN: "0.5–1.0, effective opacity of the focused pane",
                      legacy: [ConfigKeyRef("", "active-opacity")]),
        ConfigKeySpec(.appearance, "bar-opacity", .double(min: 0.0, max: 1.0), default: .double(0.75),
                      labelZH: "状态条透明度", labelEN: "Status bar opacity",
                      helpZH: "顶部状态条背景透明度（0–1）",
                      helpEN: "0–1, top status bar background",
                      legacy: [ConfigKeyRef("", "bar-opacity")]),
        ConfigKeySpec(.appearance, "divider-opacity", .double(min: 0.0, max: 1.0), default: .double(0.2),
                      labelZH: "分隔线不透明度", labelEN: "Divider opacity",
                      helpZH: "dwindle 分隔细线不透明度（0–1；0 隐藏，1 实线）",
                      helpEN: "0–1, dwindle split divider line (0 hides it)",
                      legacy: [ConfigKeyRef("", "divider-opacity")]),
        ConfigKeySpec(.appearance, "inactive-blur", .double(min: 0, max: 10), default: .double(2.5),
                      labelZH: "非激活磨砂", labelEN: "Inactive blur",
                      helpZH: "非激活 pane 磨砂背景（> 0 开启；0 关闭）",
                      helpEN: "> 0 enables frosted inactive panes; 0 turns it off",
                      legacy: [ConfigKeyRef("", "inactive-blur")]),
        ConfigKeySpec(.appearance, "pane-padding", .int(min: 0, max: 32), default: .int(14),
                      labelZH: "终端内边距", labelEN: "Terminal padding",
                      helpZH: "pane 内终端四边留白（pt，0–32；Omarchy 官方值 14）",
                      helpEN: "terminal padding in pt, 0–32 (Omarchy's value is 14)",
                      legacy: [ConfigKeyRef("", "pane-padding")]),
        ConfigKeySpec(.appearance, "pane-gap", .int(min: 0, max: 20), default: .int(5),
                      labelZH: "pane 间距", labelEN: "Pane gap",
                      helpZH: "每 pane 每边留白 pt（0–20；相邻间距 = 2×gap；scrolling / dwindle 一致）",
                      helpEN: "0–20 pt around each pane (neighbours end up 2×gap apart)",
                      legacy: [ConfigKeyRef("", "pane-gap"), ConfigKeyRef("", "dwindle-gap"),
                               ConfigKeyRef("appearance", "dwindle-gap")]),
        ConfigKeySpec(.appearance, "pane-title", .bool, default: .bool(true),
                      labelZH: "pane 标题", labelEN: "Pane title",
                      helpZH: "把标题画在 pane 上边框上（只显示手动设过的标题，最长 20 字）",
                      helpEN: "draw the title into the pane's top border (only titles you set; 20 chars max)"),
        ConfigKeySpec(.appearance, "workspace-title", .bool, default: .bool(true),
                      labelZH: "工作区名字", labelEN: "Workspace title",
                      helpZH: "起过名的工作区胶囊显示名字而不是序号（最长 12 字；放不下就整排回到序号）",
                      helpEN: "named workspaces show the name instead of the number (12 chars max)"),

        // MARK: [workspace]
        ConfigKeySpec(.workspace, "workspaces", .int(min: 1, max: 10), default: .int(5),
                      labelZH: "工作区数量", labelEN: "Workspaces",
                      helpZH: "1–10",
                      helpEN: "1–10",
                      legacy: [ConfigKeyRef("", "workspaces")]),
        ConfigKeySpec(.workspace, "visible-columns", .int(min: 1, max: 6), default: .int(2),
                      labelZH: "每屏可见列数", labelEN: "Visible columns",
                      helpZH: "scrolling 每屏可见列数（1–6；未设置走主菜单选择）",
                      helpEN: "scrolling columns per screen, 1–6 (unset: follows the main menu)",
                      legacy: [ConfigKeyRef("", "visible-columns")]),

        // MARK: [terminal]
        ConfigKeySpec(.terminal, "file-manager-command", .string, default: .string("yazi"),
                      labelZH: "文件管理器", labelEN: "File manager",
                      helpZH: "文件管理器程序（Cmd+Shift+B 在新 pane 里运行；名字或绝对路径，lf/ranger 亦可）",
                      helpEN: "program for the file-manager action (Cmd+Shift+B); name or absolute path",
                      legacy: [ConfigKeyRef("", "file-manager-command")]),

        // MARK: [browser]
        ConfigKeySpec(.browser, "home", .string, default: .string("https://www.google.com"),
                      labelZH: "首页", labelEN: "Home page",
                      helpZH: "浏览器 pane（Cmd+B）打开的首页",
                      helpEN: "page a new browser pane (Cmd+B) opens",
                      legacy: [ConfigKeyRef("", "browser-home")]),
        ConfigKeySpec(.browser, "search", .string, default: .string("https://www.google.com/search?q=%s"),
                      labelZH: "搜索模板", labelEN: "Search template",
                      helpZH: "地址栏输入非网址时的搜索模板（%s = 关键词）",
                      helpEN: "used when the address bar text is not a URL (%s = the query)",
                      legacy: [ConfigKeyRef("", "browser-search")]),
        ConfigKeySpec(.browser, "user-agent", .string, default: .string("safari"),
                      labelZH: "User-Agent", labelEN: "User agent",
                      helpZH: "伪装成 Safari（Google 登录页拒绝嵌入式浏览器）；\"webkit\" = 不伪装；或填自定义 UA",
                      helpEN: "safari | webkit | a custom UA string (Google's login page refuses embedded browsers)",
                      legacy: [ConfigKeyRef("", "browser-user-agent")]),
        ConfigKeySpec(.browser, "inspectable", .bool, default: .bool(false),
                      labelZH: "Web Inspector", labelEN: "Web Inspector",
                      helpZH: "浏览器 pane 的 Web Inspector（右键\"检查元素\"）",
                      helpEN: "right-click \"Inspect Element\" in browser panes",
                      legacy: [ConfigKeyRef("", "browser-inspectable")]),
        ConfigKeySpec(.browser, "tab-bar", .enumeration(values: ["always", "auto"], strict: false),
                      default: .string("always"),
                      labelZH: "标签条", labelEN: "Tab bar",
                      helpZH: "标签条：always = 始终显示（默认）；auto = 只有一个标签时隐藏",
                      helpEN: "always (default) | auto — auto hides the strip when there is one tab",
                      legacy: [ConfigKeyRef("", "browser-tab-bar")]),
        ConfigKeySpec(.browser, "tab-width", .int(min: 40, max: 600), default: .int(200),
                      labelZH: "标签最大宽度", labelEN: "Max tab width",
                      helpZH: "标签最大宽度 pt（40–600）",
                      helpEN: "max tab width in pt, 40–600",
                      legacy: [ConfigKeyRef("", "browser-tab-width")]),
        ConfigKeySpec(.browser, "tab-min-width", .int(min: 40, max: 600), default: .int(80),
                      labelZH: "标签最小宽度", labelEN: "Min tab width",
                      helpZH: "标签最小宽度 pt（40–600）；放不下时标签条横向滚动",
                      helpEN: "min tab width in pt, 40–600; the strip scrolls when they no longer fit",
                      legacy: [ConfigKeyRef("", "browser-tab-min-width")]),
        ConfigKeySpec(.browser, "extensions", .bool, default: .bool(true),
                      labelZH: "WebExtensions", labelEN: "WebExtensions",
                      helpZH: "浏览器 pane 加载 WebExtensions（Chrome Web Store 安装 / 从 Chrome 导入；macOS 15.4+）",
                      helpEN: "load WebExtensions in browser panes (macOS 15.4+)",
                      legacy: [ConfigKeyRef("", "browser-extensions")]),
        ConfigKeySpec(.browser, "download-dir", .path, default: .string("~/Downloads"),
                      labelZH: "下载目录", labelEN: "Download directory",
                      helpZH: "浏览器 pane 下载落盘目录（支持 ~；目录不存在时回退 ~/Downloads）",
                      helpEN: "where browser panes save downloads (~ expands; falls back to ~/Downloads)",
                      legacy: [ConfigKeyRef("", "browser-download-dir")]),
        ConfigKeySpec(.browser, "link-opener",
                      .enumeration(values: ["browser-pane", "system"], strict: false),
                      default: .string("browser-pane"),
                      labelZH: "终端链接打开方式", labelEN: "Link opener",
                      helpZH: "终端 ⌘+点击链接：browser-pane = 在浏览器 pane 打开（有则用最近激活的，无则新开）；system = 系统浏览器",
                      helpEN: "browser-pane | system — where ⌘-clicked terminal links open",
                      legacy: [ConfigKeyRef("", "link-opener")]),

        // MARK: [control]
        ConfigKeySpec(.control, "socket", .bool, default: .bool(true),
                      labelZH: "控制 socket", labelEN: "Control socket",
                      helpZH: "false 彻底不监听（quickterm 命令行与 MCP 都连不上）",
                      helpEN: "false: do not listen at all (neither the CLI nor MCP can connect)",
                      legacy: [ConfigKeyRef("control", "enabled")],
                      legacyPolicy: .mostRestrictive),
        ConfigKeySpec(.control, "mcp", .bool, default: .bool(true),
                      labelZH: "MCP 服务", labelEN: "MCP server",
                      helpZH: "false 时 `quickterm mcp` 直接拒绝服务（socket 仍可给你自己的命令行用）",
                      helpEN: "false makes `quickterm mcp` refuse to serve (the CLI socket stays available)"),
        ConfigKeySpec(.control, "mode",
                      .enumeration(values: ["off", "readonly", "ask"], strict: true),
                      default: .string("ask"),
                      labelZH: "模式", labelEN: "Mode",
                      helpZH: """
                      off = 不监听 | readonly = 只读 | ask = 默认（"on" 是 ask 的别名）
                      ask = 读免确认；改静默执行；破坏性按调用方确认一次
                      没有"免确认"档：确认闸门只能靠 off / readonly 绕开
                      """,
                      helpEN: "off | readonly | ask (\"on\" is an alias for ask). There is no \"never ask\" mode.",
                      valueAliases: ["on": "ask"]),
        ConfigKeySpec(.control, "expose-browser",
                      .enumeration(values: ["token", "always", "never"], strict: true),
                      default: .string("token"),
                      labelZH: "浏览器信息可见性", labelEN: "Expose browser",
                      helpZH: "token | always | never：谁能读到浏览器 pane 的网址与标题",
                      helpEN: "token | always | never — who may read browser pane URLs and titles"),
        ConfigKeySpec(.control, "send-text", .bool, default: .bool(false),
                      labelZH: "允许 send-text", labelEN: "Allow send-text",
                      helpZH: """
                      quickterm input send-text：把文本当键盘输入送进一个终端 pane。
                      **等于在那个 shell 里打字**（可能是 root，也可能是一条 ssh 会话），
                      所以默认关闭。打开之后：写调用方自己那个 pane 免确认，
                      写别的 pane 每次都要确认；控制字符一律拒绝，换行只能靠 --enter
                      """,
                      helpEN: "typing into a terminal pane on behalf of a caller; off by default"),
        ConfigKeySpec(.control, "capture-text", .bool, default: .bool(false),
                      labelZH: "允许 capture-text", labelEN: "Allow capture-text",
                      helpZH: """
                      quickterm pane capture-text：把一个终端 pane **屏幕上的文字**读回给调用方。
                      那里可能有 token、刚敲进去还没回车的密码、私有代码，所以默认关闭。
                      打开之后仍然要：调用方带着本次启动的 QUICKTERM_TOKEN（与浏览器网址同一枚），
                      而且每个调用进程要用户在 QuickTerm 里确认一次；正文不进任何日志
                      """,
                      helpEN: "reading a terminal pane's visible text on behalf of a caller; off by default"),
    ]

    /// `id` → 配置项
    static let byID: [String: ConfigKeySpec] = Dictionary(uniqueKeysWithValues: keys.map { ($0.id, $0) })

    /// 文件里的写法 → 配置项（新名与每一个旧名都在里面）
    static let byRef: [ConfigKeyRef: ConfigKeySpec] = {
        var out: [ConfigKeyRef: ConfigKeySpec] = [:]
        for spec in keys {
            for ref in spec.allRefs {
                precondition(out[ref] == nil, "配置写法冲突：[\(ref.section)] \(ref.name)")
                out[ref] = spec
            }
        }
        return out
    }()

    static func specs(in section: ConfigSection) -> [ConfigKeySpec] {
        keys.filter { $0.section == section }
    }

    /// 按新名查（跨分组唯一：注册表里不允许两个分组用同一个新名之外的重名，见 `byRef` 的 precondition）
    static func spec(named key: String) -> ConfigKeySpec? {
        keys.first { $0.key == key }
    }

    // MARK: 解析

    /// 一份配置文本 → 每个配置项一个**已校验**的值（缺席的项不出现，由调用方保留默认）。
    ///
    /// 归并规则（与出现顺序无关，因此"把同一个键写两遍"不会因为行序不同而结果不同）：
    /// - 同一个写法出现多次：最后一次赢（历史行为：逐行赋值）
    /// - 新名与旧名同时出现：`canonicalWins` 新名赢；`mostRestrictive` 取最严的那个
    /// - 多个旧名同时出现：`legacy` 数组里靠前的那个赢（声明顺序 = 优先级）
    static func resolve(_ scan: ConfigTOML.Scan) -> [String: ConfigValue] {
        resolveDetailed(scan).values
    }

    /// 解析结果 + 被拒绝的行（后者给日志与将来的设置界面）
    struct Resolution: Equatable {
        var values: [String: ConfigValue] = [:]
        var diagnostics: [ConfigDiagnostic] = []
    }

    static func resolveDetailed(_ scan: ConfigTOML.Scan) -> Resolution {
        var raws: [ConfigKeyRef: [String]] = [:]
        for line in scan.entries {
            let ref = ConfigKeyRef(line.section, line.key)
            guard byRef[ref] != nil else { continue }
            raws[ref, default: []].append(line.value)
        }
        var out: [String: ConfigValue] = [:]
        var notes: [ConfigDiagnostic] = []
        /// 生效的那一次取值；拒绝时记一条（数值是 clamp，不会走到这里）
        func take(_ spec: ConfigKeySpec, _ ref: ConfigKeyRef) -> ConfigValue? {
            guard let raw = raws[ref]?.last else { return nil }
            if let value = spec.coerce(raw) { return value }
            notes.append(ConfigDiagnostic(
                id: spec.id, ref: ref, raw: raw,
                messageZH: "\(ref.section.isEmpty ? ref.name : "[\(ref.section)] \(ref.name)") = \(raw) "
                    + "不是合法的值（要 \(spec.kind.expectationZH)），这一行没生效，"
                    + "仍按默认值 \(spec.defaultValue.literal)"))
            return nil
        }
        for spec in keys {
            let canonical = take(spec, spec.canonical)
            let legacy = spec.legacy.compactMap { take(spec, $0) }
            switch spec.legacyPolicy {
            case .canonicalWins:
                // 旧名之间按**声明顺序**定优先级（`pane-gap` 压 `dwindle-gap`），
                // 与它们在文件里出现的先后无关
                if let value = canonical ?? legacy.first { out[spec.id] = value }
            case .mostRestrictive:
                let all = ([canonical].compactMap { $0 }) + legacy
                guard !all.isEmpty else { continue }
                // 目前只有布尔开关用这一档（最严 = 与逻辑）
                if all.allSatisfy({ $0.boolValue != nil }) {
                    out[spec.id] = .bool(all.allSatisfy { $0.boolValue == true })
                } else {
                    out[spec.id] = canonical ?? all.last
                }
            }
        }
        return Resolution(values: out, diagnostics: notes)
    }

    static func resolve(_ text: String) -> [String: ConfigValue] { resolve(ConfigTOML.scan(text)) }
    static func resolveDetailed(_ text: String) -> Resolution { resolveDetailed(ConfigTOML.scan(text)) }

    // MARK: 模板

    /// 模板 = 注册表渲染出来的那份带注释的配置文件。**没有第二份手写模板**
    static var template: String {
        var out = [
            "# QuickTerm 配置（spec §4.7）。保存即热重载。",
            "# 配置项按功能分组，一个分组 = 设置界面的一个 tab；下面每一行都是默认值。",
            "# 兼容：旧的扁平写法（theme = … / browser-home = … / [control] enabled = …）永远有效，",
            "# 已有配置文件一个字都不用改。",
            "",
        ]
        for section in ConfigSection.allCases {
            out.append(contentsOf: sectionHeaderLines(section))
            let specs = specs(in: section)
            let width = specs.map(\.templateAssignment.count).max() ?? 0
            for spec in specs { out.append(contentsOf: spec.templateBlock(width: width)) }
            out.append(contentsOf: section.extraTemplateLines)
            out.append("")
        }
        if out.last == "" { out.removeLast() }
        return out.joined(separator: "\n") + "\n"
    }

    /// 模板里每个配置项的那一块（赋值行 + 续行）。补全缺失键时照抄，
    /// 补出来的段落因此与全新安装写下的**逐字一致**（`testAutofilledSectionMatchesFreshInstall` 钉死）
    static var templateKeyBlocks: [(spec: ConfigKeySpec, lines: [String])] {
        var out: [(ConfigKeySpec, [String])] = []
        for section in ConfigSection.allCases {
            let specs = specs(in: section)
            let width = specs.map(\.templateAssignment.count).max() ?? 0
            for spec in specs { out.append((spec, spec.templateBlock(width: width))) }
        }
        return out
    }

    /// 新建一个分组时要写的段头（含段说明），与模板里那几行一模一样
    static func sectionHeaderLines(_ section: ConfigSection) -> [String] {
        var out = ["[\(section.rawValue)]  # \(section.titleZH) / \(section.titleEN)"]
        if let note = section.noteZH {
            out.append(contentsOf: note.split(separator: "\n").map { "# \($0)" })
        }
        return out
    }
}

/// 极简 TOML 子集的扫描器（spec §4.7：顶层 key = value + `[section]`）。
/// **只有这一处实现**：app 的解析、CLI 的 `[control]` 闸门、模板补全全用它
enum ConfigTOML {
    struct Entry: Equatable {
        /// 第一个 `[section]` 之前的顶层键 = `""`
        var section: String
        var key: String
        var value: String
    }

    struct Scan {
        var entries: [Entry] = []
        /// `[ghostty]` 段原样透传的行
        var ghostty: [String] = []
        /// 生效行（非注释、非空）里段名不认识的那些——留给调用方（`[keybinds]` 自己处理）
        var sections: Set<String> = []
    }

    static func scan(_ toml: String) -> Scan {
        var out = Scan()
        var section = ""
        for rawLine in toml.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("["), let close = line.firstIndex(of: "]") {
                section = String(line[line.index(after: line.startIndex)..<close])
                out.sections.insert(section)
                continue
            }
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            if section == "ghostty" {
                out.ghostty.append(line)   // 原样透传（含 ghostty 自己的 key = value 语法）
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
            out.entries.append(Entry(section: section, key: key, value: String(value)))
        }
        return out
    }
}

/// 配置文件落点。app 侧还有 `ConfigStore.configURLOverride`（用例注入），
/// 而 CLI 进程只认环境变量 `QUICKTERM_CONFIG_FILE`——两边是同一个 seam
enum ConfigPaths {
    static let environmentKey = "QUICKTERM_CONFIG_FILE"

    static var defaultConfigURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/quickterm/config.toml")
    }

    static func configURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let path = environment[environmentKey], !path.isEmpty {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        }
        return defaultConfigURL
    }

    /// 明确指定了配置文件（环境变量）吗
    static func isOverridden(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        !(environment[environmentKey] ?? "").isEmpty
    }

    /// 跑在 XCTest 宿主里吗。**用例宿主绝不去读开发者真正的 ~/.config/quickterm/config.toml**：
    /// 那份文件里一句 `[control] mcp = false` 不该把测试弄红。
    /// 与 `AppSession` 里对 `ensureTemplateKeys` 的那道防线是同一条规矩
    static func isTestHost(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        environment["XCTestConfigurationFilePath"] != nil || environment["XCTestBundlePath"] != nil
    }
}

/// `[control]` 的三个开关，**不带 AppKit**：`quickterm mcp` 在 app 之外也要读得到。
///
/// 监听与否是三个开关取最严：`socket = false`、旧的 `enabled = false`、`mode = "off"`
/// 任何一个都等于"不监听"。app 侧 `ControlCommandRunner.Config` 用的是同一张注册表，
/// 用例 `testGateMatchesAppParse` 钉死两边不会漂
struct ControlConfigGate: Equatable {
    var socket: Bool
    var mcp: Bool
    var mode: String

    init(socket: Bool = true, mcp: Bool = true, mode: String = "ask") {
        self.socket = socket
        self.mcp = mcp
        self.mode = mode
    }

    init(text: String) {
        let values = ConfigSchema.resolve(text)
        socket = values["control.socket"]?.boolValue ?? true
        mcp = values["control.mcp"]?.boolValue ?? true
        mode = values["control.mode"]?.stringValue ?? "ask"
    }

    /// 读配置文件（不存在 = 全默认 = 全开）
    static func load(environment: [String: String] = ProcessInfo.processInfo.environment) -> ControlConfigGate {
        // 用例宿主里不碰用户那一份（没设 QUICKTERM_CONFIG_FILE 就一律默认全开）：
        // `serve(gate: .load())` 这种默认参数是在**调用点**求值的，
        // 一条忘了传 gate 的用例会因为开发者自己的配置而红
        guard !ConfigPaths.isTestHost(environment) || ConfigPaths.isOverridden(environment) else {
            return ControlConfigGate()
        }
        let url = ConfigPaths.configURL(environment: environment)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return ControlConfigGate() }
        return ControlConfigGate(text: text)
    }

    var isListening: Bool { socket && mode != "off" }

    /// `quickterm mcp` 被配置拒绝时给用户看的那句话（**必须点名是哪个键、哪个文件**，
    /// 否则用户只会看到一个 MCP 宿主说"服务器起不来"）
    static func mcpDisabledMessage(path: String = ConfigPaths.configURL().path) -> String {
        "MCP 服务被配置关掉了：\(path) 的 [control] mcp = false"
    }

    static let mcpDisabledHint =
        "要用 MCP 的话，把 [control] mcp 改成 true（或删掉这一行）；socket = false / mode = \"off\" 也会让它连不上"
}
