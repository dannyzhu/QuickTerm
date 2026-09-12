import Foundation

/// **The settings registry: every setting is declared here exactly once.**
///
/// The template, parsing and validation, the config tables in the READMEs and the future
/// settings window (one group = one tab) are all generated from this table. Same rule as
/// `Sources/Control/Wire/ControlCommandTable.swift`: write a second description by hand and it
/// will have drifted within two releases, and the drifted half lands on the user in the shape of
/// "I set it in the config and nothing happened".
///
/// **Pure Foundation**: this file is compiled into both the app and the `quickterm` tool target
/// (`quickterm mcp` has to read `[control] mcp` without launching the app). One `import AppKit`
/// here and the CLI carries the entire UI stack.
///
/// Groups and legacy spellings: since v1.5.9 the settings are grouped by function
/// (`[appearance]` / `[workspace]` / `[terminal]` / `[browser]` / `[control]`). **The old flat
/// spellings are accepted forever** (see each key's `legacy`): nobody's
/// ~/.config/quickterm/config.toml needs a single edit.
enum ConfigSection: String, CaseIterable, Codable {
    case general
    case appearance
    case workspace
    case terminal
    case browser
    case control
    case keybinds
    case ghostty

    var titleZH: String {
        switch self {
        case .general: "通用"
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
        case .general: "General"
        case .appearance: "Appearance"
        case .workspace: "Workspaces"
        case .terminal: "Terminal"
        case .browser: "Browser"
        case .control: "Control plane"
        case .keybinds: "Keybinds"
        case .ghostty: "Ghostty passthrough"
        }
    }

    /// Section header and note, rendered in the **active** language: the template comments
    /// follow the UI language. Both wordings stay — a future settings window reads the same
    /// registry, just in the language it is drawn in.
    var title: String { ConfigSchema.templateLanguage == .zh ? titleZH : titleEN }
    var note: String? { ConfigSchema.templateLanguage == .zh ? noteZH : noteEN }

    /// The note the template writes under this section's header; may span several lines.
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

    /// English counterpart of `noteZH` (the template writes whichever the UI language is)
    var noteEN: String? {
        switch self {
        case .control:
            """
            Control plane (the quickterm CLI / AI agents). Socket: ~/Library/Application Support/QuickTerm/control.sock
            """
        case .keybinds:
            """
            action = "modifiers+key"; "none" unbinds. The action list is the Cmd+K cheat sheet.
            """
        case .ghostty:
            """
            Passed through to the engine verbatim (highest priority); any ghostty option.
            """
        default: nil
        }
    }

    /// Fixed example lines appended at the end of a section (`[keybinds]` and `[ghostty]` are
    /// free-form: they have no registry entries).
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

    /// A group with registry entries is a tab in the settings window (`[keybinds]` gets its own
    /// UI, `[ghostty]` is a text box).
    var hasRegisteredKeys: Bool { !(self == .keybinds || self == .ghostty) }
}

/// The UI language QuickTerm draws itself in.
///
/// Pure Foundation and declared here on purpose: this file is compiled into the `quickterm`
/// CLI as well as the app, and the config-file template renders its comments in the active
/// language. `Localization` (app side) resolves and owns the live value; this type is only the
/// vocabulary plus the `auto` resolution rule, so both sides cannot drift.
///
/// English is the base language, and it is also what `auto` falls back to when the system asks
/// for a language QuickTerm does not ship.
enum AppLanguage: String, CaseIterable, Codable {
    case en
    case zh

    /// The `.lproj` directory this language lives in (`zh` ships as Simplified Chinese).
    var lprojName: String { self == .zh ? "zh-Hans" : "en" }

    /// A BCP-47-ish tag (`zh-Hans`, `zh_CN`, `en-US`) narrowed to a language QuickTerm ships.
    /// `nil` = not one of ours. Traditional Chinese resolves to Simplified: it is much closer
    /// to what that reader wants than English is.
    static func normalize(_ raw: String) -> AppLanguage? {
        let lower = raw.trimmingCharacters(in: .whitespaces).lowercased()
        for language in allCases {
            let tag = language.rawValue
            if lower == tag || lower.hasPrefix("\(tag)-") || lower.hasPrefix("\(tag)_") { return language }
        }
        return nil
    }

    /// What the system's preferred languages ask for, English when none of them is ours.
    static func system(_ preferred: [String] = Locale.preferredLanguages) -> AppLanguage {
        for tag in preferred {
            if let language = normalize(tag) { return language }
        }
        return .en
    }

    /// `[general] language` → the language to draw in. `auto` (and anything unrecognized,
    /// which the schema rejects long before it gets here) follows the system.
    static func resolve(configValue: String,
                        preferred: [String] = Locale.preferredLanguages) -> AppLanguage {
        let value = configValue.trimmingCharacters(in: .whitespaces).lowercased()
        guard !value.isEmpty, value != "auto" else { return system(preferred) }
        return normalize(value) ?? system(preferred)
    }
}

/// One spelling of a key in a config file (section name + key name). A section of `""` means a
/// top-level key, written before the first `[section]`.
struct ConfigKeyRef: Hashable {
    var section: String
    var name: String

    init(_ section: String, _ name: String) {
        self.section = section
        self.name = name
    }
}

/// A value's type and its legal range. **The range is declared here, and validation has exactly
/// one implementation.**
enum ConfigKind: Equatable {
    case bool
    /// Out-of-range values are clamped, which is what the code has always done.
    case int(min: Int, max: Int)
    case double(min: Double, max: Double)
    /// `strict` rejects any value not in the list, keeping the default; otherwise anything
    /// non-empty is accepted, which is the historical behavior.
    case enumeration(values: [String], strict: Bool)
    case string
    /// A filesystem path (`~` is expanded). Validated exactly like a string; the settings window
    /// should give it a "choose directory" button.
    case path

    /// What this key accepts. Goes into the message a rejected line produces, and will be the
    /// input hint in the settings window.
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

    /// English counterpart of `expectationZH`, read through `expectation`.
    var expectationEN: String {
        switch self {
        case .bool: "true / false (1 / 0, yes / no and on / off are accepted too)"
        case .int(let lo, let hi): "a whole number from \(lo) to \(hi)"
        case .double(let lo, let hi): "a number between \(lo) and \(hi)"
        case .enumeration(let values, let strict):
            strict ? values.joined(separator: " | ")
                   : "\(values.joined(separator: " | ")), or any other non-empty value"
        case .string: "a non-empty string"
        case .path: "a path (~ is expanded)"
        }
    }

    /// What this key accepts, in the **active** language — the same rule the template
    /// comments and `ConfigKeySpec.help` follow.
    var expectation: String { ConfigSchema.templateLanguage == .zh ? expectationZH : expectationEN }

    /// What to do with an out-of-range value: numbers are clamped, everything else (bools,
    /// enumerations, the empty string) is rejected and the default kept.
    var outOfRange: ConfigOutOfRange {
        switch self {
        case .int, .double: .clamp
        default: .reject
        }
    }
}

/// Out-of-range behavior. **Copied from the historical behavior**: this refactor does not
/// quietly change the temperament of a single key.
enum ConfigOutOfRange: String, Codable {
    /// Clamp to the nearest end of the range.
    case clamp
    /// Drop the whole line and keep the default value.
    case reject
}

/// One config line that **had no effect**: the value was not valid, so the key's own
/// out-of-range rule kept the default. Logged at startup and on a hot reload; the future settings
/// window will show it on the tab it belongs to. "I wrote it and it does nothing" has to be
/// visible somewhere, or the user simply concludes the program is broken.
struct ConfigDiagnostic: Equatable {
    /// The registry id (`control.socket`).
    var id: String
    /// The spelling the user actually wrote, which may be a legacy name.
    var ref: ConfigKeyRef
    var raw: String
    var messageZH: String
    /// English counterpart of `messageZH`. Both wordings are built up front, like every other
    /// pair in this registry: the settings window will draw `message` (the active UI language)
    /// while the program log stays English whatever the window is drawn in.
    var messageEN: String

    /// The sentence to show the user, in the **active** language.
    var message: String { ConfigSchema.templateLanguage == .zh ? messageZH : messageEN }

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

    /// The literal written into the config file; strings keep their quotes.
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

/// What to do when the current and a legacy spelling both appear.
enum ConfigLegacyPolicy {
    /// The current name wins, no matter which came first in the file. `pane-gap` beating
    /// `dwindle-gap` is this case.
    case canonicalWins
    /// **The most restrictive one wins** (boolean AND). `[control] socket` and the old `enabled`
    /// are this case: both switches answer the same question, "should we listen", so a `false` in
    /// either one has to mean we do not listen. Letting the current name override the legacy
    /// name's `false` would mean a user who upgrades once gets a port they had closed quietly
    /// reopened.
    case mostRestrictive
}

/// One setting.
struct ConfigKeySpec {
    var section: ConfigSection
    /// The key name within its group (`[browser] home`). **No group prefix**: the section header
    /// has already said it.
    var key: String
    var kind: ConfigKind
    /// The default value, which is also the value the template writes commented out.
    var defaultValue: ConfigValue
    /// Takes effect the moment the file is saved.
    var hotReload: Bool
    var labelZH: String
    var labelEN: String
    var helpZH: String
    var helpEN: String
    /// Legacy spellings, accepted forever, so an upgrade never forces a config file edit.
    var legacy: [ConfigKeyRef]
    var legacyPolicy: ConfigLegacyPolicy
    /// The empty string counts as a value. Only `theme` works this way: writing it empty is an
    /// explicit "no theme".
    var acceptsEmpty: Bool
    /// Aliases for enumeration values (`mode = "on"` -> `ask`).
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

    /// The unique id in the registry (`browser.home`); the binding table and `resolve`'s result
    /// are both indexed by it.
    var id: String { "\(section.rawValue).\(key)" }
    var canonical: ConfigKeyRef { ConfigKeyRef(section.rawValue, key) }
    var outOfRange: ConfigOutOfRange { kind.outOfRange }
    /// Every spelling this setting answers to, the current name first.
    var allRefs: [ConfigKeyRef] { [canonical] + legacy }

    /// Label and help in the **active** language (`ConfigSchema.templateLanguage`). Both
    /// wordings stay: the template comments, the future settings window and the two READMEs
    /// all read this one registry, only in different languages.
    var label: String { ConfigSchema.templateLanguage == .zh ? labelZH : labelEN }
    var help: String { ConfigSchema.templateLanguage == .zh ? helpZH : helpEN }

    /// The left half of the line in the template and the READMEs
    /// (`# home = "https://www.google.com"`).
    var templateAssignment: String { "# \(key) = \(defaultValue.literal)" }

    /// This setting's **complete** block in the template: the assignment line plus the aligned
    /// continuation lines of a multi-line help text. Rendering the template and filling in missing
    /// keys share it. Copying only the first line when filling in would leave the `send-text`
    /// warning — **this is the same as typing into that shell** — to fresh installs only, and a
    /// user who upgraded would never see it.
    func templateBlock(width: Int? = nil) -> [String] {
        let assignment = templateAssignment
        let column = max(width ?? assignment.count, assignment.count)
        let pad = String(repeating: " ", count: max(1, column - assignment.count + 2))
        let help = self.help.split(separator: "\n", omittingEmptySubsequences: false)
        var out = ["\(assignment)\(pad)# \(help[0])"]
        // Line the continuation up with the first line's `#`: the template has to read well too.
        let indent = String(repeating: " ", count: column + 1)
        for extra in help.dropFirst() { out.append("#\(indent)# \(extra)") }
        return out
    }

    /// Boolean literals, case-insensitive. TOML only knows true/false, but people hand-writing a
    /// config write 1/0, yes/no and on/off as well, and accepting those is safer than pretending
    /// not to have seen them.
    static let trueLiterals: Set<String> = ["true", "1", "yes", "on"]
    static let falseLiterals: Set<String> = ["false", "0", "no", "off"]

    static func boolLiteral(_ raw: String) -> Bool? {
        let lowered = raw.lowercased()
        if trueLiterals.contains(lowered) { return true }
        if falseLiterals.contains(lowered) { return false }
        return nil
    }

    /// Coerce one raw line value into a valid value. `nil` = rejected (the default is kept), and
    /// `resolve` records a diagnostic for it.
    func coerce(_ raw: String) -> ConfigValue? {
        switch kind {
        case .bool:
            // A bool is only what this table says it is. **Anything unrecognized is rejected**
            // (the default is kept and a diagnostic is left behind); we never guess one. Before
            // this refactor every boolean key carried its own `!= "false"` / `== "true"` line,
            // and the result was that keys defaulting to on stayed quietly on when written as
            // off / 0 / no — while `[control] socket` and `mcp` are two security switches, and
            // `mode`'s own help text, one line further down, tells people to write off.
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
            // A loose enumeration (tab-bar, link-opener): historically anything non-empty was
            // taken as-is, and each consumer fell back on its own for a value it did not know.
            // This refactor does not change that temperament.
            guard !raw.isEmpty else { return nil }
            return .string(valueAliases[raw] ?? raw)
        case .string, .path:
            guard acceptsEmpty || !raw.isEmpty else { return nil }
            return .string(raw)
        }
    }
}

enum ConfigSchema {
    // MARK: The registry

    /// The language the template comments are written in. On the app side `Localization`
    /// keeps it in sync (a config hot reload moves it); the `quickterm` CLI never renders the
    /// template, so following the system is enough there.
    /// **Deliberately not inside `Localization`**: this file is compiled into the CLI too, and
    /// that target has neither AppKit nor the `.lproj` directories.
    nonisolated(unsafe) static var templateLanguage: AppLanguage = AppLanguage.system()

    static let keys: [ConfigKeySpec] = [
        // MARK: [general]
        ConfigKeySpec(.general, "language",
                      .enumeration(values: ["auto", "en", "zh"], strict: true),
                      default: .string("auto"),
                      labelZH: "界面语言", labelEN: "Language",
                      helpZH: """
                      auto = 跟随系统 | en = English | zh = 简体中文
                      只管**界面**：程序日志与 quickterm 命令行始终是英文
                      """,
                      helpEN: """
                      auto (follow the system) | en | zh
                      UI only: the logs and the quickterm CLI are English in both languages
                      """,
                      valueAliases: ["zh-hans": "zh", "zh-cn": "zh", "zh_cn": "zh",
                                     "zh-hant": "zh", "zh-tw": "zh",
                                     "en-us": "en", "en_us": "en", "en-gb": "en",
                                     "system": "auto"]),

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

    /// `id` -> the setting.
    static let byID: [String: ConfigKeySpec] = Dictionary(uniqueKeysWithValues: keys.map { ($0.id, $0) })

    /// A spelling in the file -> the setting. Holds the current name and every legacy name.
    static let byRef: [ConfigKeyRef: ConfigKeySpec] = {
        var out: [ConfigKeyRef: ConfigKeySpec] = [:]
        for spec in keys {
            for ref in spec.allRefs {
                precondition(out[ref] == nil,
                             "Conflicting config spelling: [\(ref.section)] \(ref.name)")
                out[ref] = spec
            }
        }
        return out
    }()

    static func specs(in section: ConfigSection) -> [ConfigKeySpec] {
        keys.filter { $0.section == section }
    }

    /// Look a setting up by its current name, which is unique across groups: the registry does
    /// not allow two groups to share a name, see the precondition in `byRef`.
    static func spec(named key: String) -> ConfigKeySpec? {
        keys.first { $0.key == key }
    }

    // MARK: Parsing

    /// A config text -> one **validated** value per setting. A setting that is absent does not
    /// appear at all, and the caller keeps its default.
    ///
    /// The merge rules do not depend on the order lines appear in, so writing the same key twice
    /// cannot produce different results just because the lines were swapped:
    /// - the same spelling more than once: the last one wins (the historical line-by-line
    ///   assignment);
    /// - the current name and a legacy name together: `canonicalWins` gives it to the current
    ///   name, `mostRestrictive` takes whichever is stricter;
    /// - several legacy names together: the one earlier in the `legacy` array wins, so
    ///   declaration order is priority order.
    static func resolve(_ scan: ConfigTOML.Scan) -> [String: ConfigValue] {
        resolveDetailed(scan).values
    }

    /// The parse result plus the rejected lines; the latter feed the log and the future settings
    /// window.
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
        /// The reading that takes effect; a rejection records a diagnostic. Numbers are clamped
        /// and never reach that path.
        func take(_ spec: ConfigKeySpec, _ ref: ConfigKeyRef) -> ConfigValue? {
            guard let raw = raws[ref]?.last else { return nil }
            if let value = spec.coerce(raw) { return value }
            let display = ref.section.isEmpty ? ref.name : "[\(ref.section)] \(ref.name)"
            notes.append(ConfigDiagnostic(
                id: spec.id, ref: ref, raw: raw,
                messageZH: "\(display) = \(raw) "
                    + "不是合法的值（要 \(spec.kind.expectationZH)），这一行没生效，"
                    + "仍按默认值 \(spec.defaultValue.literal)",
                messageEN: "\(display) = \(raw) is not a valid value "
                    + "(expected \(spec.kind.expectationEN)); that line had no effect, "
                    + "the default \(spec.defaultValue.literal) is still in use"))
            return nil
        }
        for spec in keys {
            let canonical = take(spec, spec.canonical)
            let legacy = spec.legacy.compactMap { take(spec, $0) }
            switch spec.legacyPolicy {
            case .canonicalWins:
                // Among legacy names, priority is **declaration order** (`pane-gap` beats
                // `dwindle-gap`), regardless of which comes first in the file.
                if let value = canonical ?? legacy.first { out[spec.id] = value }
            case .mostRestrictive:
                let all = ([canonical].compactMap { $0 }) + legacy
                guard !all.isEmpty else { continue }
                // Only boolean switches use this policy so far, where "most restrictive" is a
                // logical AND.
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

    // MARK: The template

    /// The template is the commented config file rendered from the registry. **There is no
    /// second, hand-written template.**
    static var template: String {
        var out = templateHeaderLines + [""]
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

    /// Each setting's block in the template (assignment line plus continuation lines). Filling in
    /// a missing key copies it verbatim, which makes what gets filled in **word for word** what a
    /// fresh install writes (`testAutofilledSectionMatchesFreshInstall` pins this down).
    static var templateKeyBlocks: [(spec: ConfigKeySpec, lines: [String])] {
        var out: [(ConfigKeySpec, [String])] = []
        for section in ConfigSection.allCases {
            let specs = specs(in: section)
            let width = specs.map(\.templateAssignment.count).max() ?? 0
            for spec in specs { out.append((spec, spec.templateBlock(width: width))) }
        }
        return out
    }

    /// The first few lines of the template, in the active UI language.
    static var templateHeaderLines: [String] {
        templateLanguage == .zh
            ? ["# QuickTerm 配置（spec §4.7）。保存即热重载。",
               "# 配置项按功能分组，一个分组 = 设置界面的一个 tab；下面每一行都是默认值。",
               "# 兼容：旧的扁平写法（theme = … / browser-home = … / [control] enabled = …）永远有效，",
               "# 已有配置文件一个字都不用改。"]
            : ["# QuickTerm configuration (spec §4.7). Saving hot-reloads it.",
               "# Keys are grouped by function — one group = one tab in the settings window;",
               "# every line below is the default value.",
               "# The old flat spellings (theme = … / browser-home = … / [control] enabled = …) are",
               "# accepted forever: an existing config file needs no edit."]
    }

    /// The header lines to write when creating a group, section note included — identical to the
    /// lines the template produces.
    static func sectionHeaderLines(_ section: ConfigSection) -> [String] {
        var out = ["[\(section.rawValue)]  # \(section.title)"]
        if let note = section.note {
            out.append(contentsOf: note.split(separator: "\n").map { "# \($0)" })
        }
        return out
    }
}

/// The scanner for our minimal TOML subset (spec §4.7: top-level `key = value` plus
/// `[section]`). **The only implementation**: the app's parsing, the CLI's `[control]` gate and
/// the template fill-in all go through it.
enum ConfigTOML {
    struct Entry: Equatable {
        /// A top-level key, written before the first `[section]`, has section `""`.
        var section: String
        var key: String
        var value: String
    }

    struct Scan {
        var entries: [Entry] = []
        /// Lines in the `[ghostty]` section, passed through verbatim.
        var ghostty: [String] = []
        /// Section names seen on live lines (not comments, not blank) that we do not recognize;
        /// left to the caller, which is how `[keybinds]` handles itself.
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
                out.ghostty.append(line)   // verbatim, ghostty's own key = value syntax included
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

/// Where the config file lives. The app side also has `ConfigStore.configURLOverride` for test
/// injection, while a CLI process only honors the `QUICKTERM_CONFIG_FILE` environment variable;
/// the two are the same seam.
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

    /// Was a config file named explicitly, through the environment variable?
    static func isOverridden(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        !(environment[environmentKey] ?? "").isEmpty
    }

    /// Are we running inside an XCTest host? **A test host never reads the developer's real
    /// ~/.config/quickterm/config.toml**: one `[control] mcp = false` line in that file must not
    /// turn the tests red. Same rule as the guard around `ensureTemplateKeys` in `AppSession`.
    static func isTestHost(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        environment["XCTestConfigurationFilePath"] != nil || environment["XCTestBundlePath"] != nil
    }
}

/// The three `[control]` switches, **without AppKit**: `quickterm mcp` has to read them outside
/// the app as well.
///
/// Whether we listen is the strictest of the three: `socket = false`, the legacy
/// `enabled = false` and `mode = "off"` each mean "do not listen" on their own. The app side's
/// `ControlCommandRunner.Config` reads the same registry, and `testGateMatchesAppParse` pins the
/// two against drifting apart.
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

    /// Read the config file; a missing file means all defaults, which means everything on.
    static func load(environment: [String: String] = ProcessInfo.processInfo.environment) -> ControlConfigGate {
        // Inside a test host, never touch the user's own file: with no QUICKTERM_CONFIG_FILE
        // set, fall back to all-default, all-on. A default argument like `serve(gate: .load())`
        // is evaluated at the **call site**, so one test that forgot to pass a gate would go red
        // because of the developer's personal config.
        guard !ConfigPaths.isTestHost(environment) || ConfigPaths.isOverridden(environment) else {
            return ControlConfigGate()
        }
        let url = ConfigPaths.configURL(environment: environment)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return ControlConfigGate() }
        return ControlConfigGate(text: text)
    }

    var isListening: Bool { socket && mode != "off" }

    /// What the user is shown when the config refuses `quickterm mcp`. **It must name the key
    /// and the file**, or all the user gets is an MCP host saying the server would not start.
    static func mcpDisabledMessage(path: String = ConfigPaths.configURL().path) -> String {
        "The MCP server is turned off in the config: [control] mcp = false in \(path)"
    }

    static let mcpDisabledHint =
        "Set [control] mcp = true (or delete that line) to use MCP; socket = false and mode = \"off\" "
        + "also keep it from connecting"
}
