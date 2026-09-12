import AppKit
import XCTest
@testable import QuickTerm

/// 配置注册表（`Sources/Config/ConfigSchema.swift`）的用例。
///
/// 这个文件的存在本身就是那条项目规矩的**机械执行**：
/// "每个配置项都必须出现在模板、解析器、两份 README 和用例里"——
/// 靠人自觉会漏，靠 `testEveryKeyIsDocumented` 不会。
final class ConfigSchemaTests: XCTestCase {
    /// 仓库根目录（用例跑在构建产物里，README 只能从源码路径找）
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    /// Read one of the READMEs.
    ///
    /// Prefer the copy inside the test bundle (project.yml copies both in as resources) and fall
    /// back to the source tree. The fallback is not the normal path: this test host is ad-hoc
    /// signed and the repo sits under ~/Documents, which macOS gates behind a privacy prompt —
    /// on a machine where nobody answers it, `String(contentsOf:)` blocks and then fails with
    /// EINTR. The bundled copy is rewritten by every build, so it is the same file, just reachable.
    private func readme(_ name: String) throws -> String {
        if let url = Bundle(for: Self.self).url(forResource: name, withExtension: "md") {
            return try String(contentsOf: url, encoding: .utf8)
        }
        return try String(contentsOf: repoRoot.appendingPathComponent("\(name).md"), encoding: .utf8)
    }

    // MARK: 注册表 = 唯一事实来源

    /// 每个配置项都在模板里、在两份 README 里，而且**三处的默认值一模一样**
    func testEveryKeyIsDocumented() throws {
        let template = ConfigStore.template
        let en = try readme("README")
        let zh = try readme("README.zh-CN")
        for spec in ConfigSchema.keys {
            let line = spec.templateAssignment   // "# home = \"https://www.google.com\""
            XCTAssertTrue(template.contains(line), "模板缺少 \(spec.id)：\(line)")
            XCTAssertTrue(en.contains(line), "README.md 缺少 \(spec.id)：\(line)")
            XCTAssertTrue(zh.contains(line), "README.zh-CN.md 缺少 \(spec.id)：\(line)")
        }
        // 补全缺键时照抄的那一块，必须逐行出现在模板里（同一个渲染函数，钉死不漂）
        for (spec, lines) in ConfigSchema.templateKeyBlocks {
            XCTAssertTrue(template.contains(lines.joined(separator: "\n")),
                          "模板与补全块不一致：\(spec.id)")
        }
        for section in ConfigSection.allCases {
            XCTAssertTrue(template.contains("[\(section.rawValue)]"), "模板缺少分组 [\(section.rawValue)]")
        }
        for doc in [en, zh] {
            for section in ConfigSection.allCases where section.hasRegisteredKeys {
                XCTAssertTrue(doc.contains("[\(section.rawValue)]"), "README 缺少分组 [\(section.rawValue)]")
            }
        }
    }

    /// 注册表与"写进 Settings 的哪一个字段"一一对应（多一个少一个都是配置写了不生效）
    func testEveryKeyHasABinding() {
        XCTAssertEqual(Set(ConfigSchema.keys.map(\.id)), Set(ConfigBindings.table.keys))
    }

    /// 模板往返：整份模板全是注释 → 解析出来就是一套默认值；
    /// 把任意一行取消注释 → 拿回的正是注册表声明的那个默认值
    func testTemplateRoundTrips() {
        XCTAssertEqual(ConfigStore.parse(ConfigStore.template), ConfigStore.Settings(),
                       "模板里每一行都是注释，解析出来必须等于纯默认值")
        for spec in ConfigSchema.keys {
            let text = "[\(spec.section.rawValue)]\n\(spec.key) = \(spec.defaultValue.literal)\n"
            XCTAssertEqual(ConfigSchema.resolve(text)[spec.id], spec.defaultValue,
                           "模板里 \(spec.id) 写的默认值解析不回它自己")
        }
    }

    // MARK: 旧写法永远有效

    /// **表驱动跑完整张旧名单**（不是抽查）：每一个旧写法都必须与新写法解析成同一套 Settings
    func testEveryLegacySpellingParsesLikeItsNewName() {
        for spec in ConfigSchema.keys {
            for value in [spec.defaultValue.literal, Self.sample(for: spec)] {
                let modern = ConfigStore.parse("[\(spec.section.rawValue)]\n\(spec.key) = \(value)\n")
                for ref in spec.legacy {
                    let head = ref.section.isEmpty ? "" : "[\(ref.section)]\n"
                    let legacy = ConfigStore.parse("\(head)\(ref.name) = \(value)\n")
                    XCTAssertEqual(legacy, modern,
                                   "旧写法 [\(ref.section)] \(ref.name) = \(value) 与新写法不等价")
                }
            }
        }
    }

    /// 一份**全用旧扁平写法**的配置，与同一份内容的新分组写法，解析结果必须一模一样
    func testFlatStyleConfigEqualsGroupedStyle() {
        var flat: [String: [String]] = [:]
        var grouped: [String: [String]] = [:]
        for spec in ConfigSchema.keys {
            let value = Self.sample(for: spec)
            let old = spec.legacy.first ?? spec.canonical
            flat[old.section, default: []].append("\(old.name) = \(value)")
            grouped[spec.canonical.section, default: []].append("\(spec.key) = \(value)")
        }
        func render(_ blocks: [String: [String]]) -> String {
            var out = blocks[""] ?? []
            for section in ConfigSection.allCases {
                guard let lines = blocks[section.rawValue] else { continue }
                out.append("[\(section.rawValue)]")
                out.append(contentsOf: lines)
            }
            return out.joined(separator: "\n") + "\n"
        }
        let a = ConfigStore.parse(render(flat))
        let b = ConfigStore.parse(render(grouped))
        XCTAssertEqual(a, b, "旧扁平写法与新分组写法必须逐字段相等")
        XCTAssertNotEqual(a, ConfigStore.Settings(), "样例值必须真的与默认值不同，否则这个用例什么都没证明")
    }

    /// **重构前那张键表逐条钉死**（这份清单是从改动前的 `ConfigStore.parse` 抄下来的，
    /// 与注册表无关：注册表要是漏掉、改名、改脾气了哪一个键，这条用例就红）。
    /// 用户手上那份全是旧扁平写法的 config.toml 必须一个字都不用改
    func testPreChangeKeyListParsesExactlyLikeBefore() {
        // (写法, 值, 断言)
        let frozen: [(section: String, key: String, value: String,
                      check: (ConfigStore.Settings) -> Bool)] = [
            ("", "theme", "\"nord\"", { $0.themeName == "nord" }),
            ("", "workspaces", "8", { $0.workspaces == 8 }),
            ("", "pane-padding", "20", { $0.panePadding == 20 }),
            ("", "visible-columns", "3", { $0.visibleColumns == 3 }),
            ("", "pane-opacity", "0.8", { abs($0.paneOpacity - 0.8) < 0.001 }),
            ("", "active-opacity", "0.9", { abs($0.activeOpacity - 0.9) < 0.001 }),
            ("", "bar-opacity", "0.5", { abs($0.barOpacity - 0.5) < 0.001 }),
            ("", "divider-opacity", "0.4", { abs($0.dividerOpacity - 0.4) < 0.001 }),
            ("", "pane-gap", "7", { $0.paneGap == 7 }),
            ("", "dwindle-gap", "9", { $0.paneGap == 9 }),
            ("", "inactive-blur", "4.5", { abs($0.inactiveBlur - 4.5) < 0.001 }),
            ("", "file-manager-command", "\"lf\"", { $0.fileManagerCommand == "lf" }),
            ("", "browser-home", "\"https://example.com\"", { $0.browserHome == "https://example.com" }),
            ("", "browser-search", "\"https://duckduckgo.com/?q=%s\"",
             { $0.browserSearch == "https://duckduckgo.com/?q=%s" }),
            ("", "browser-user-agent", "\"webkit\"", { $0.browserUserAgent == "webkit" }),
            ("", "browser-inspectable", "true", { $0.browserInspectable }),
            ("", "browser-tab-bar", "\"auto\"", { $0.browserTabBar == "auto" }),
            ("", "browser-tab-width", "300", { $0.browserTabWidth == 300 }),
            ("", "browser-tab-min-width", "120", { $0.browserTabMinWidth == 120 }),
            ("", "browser-extensions", "false", { !$0.browserExtensions }),
            ("", "browser-download-dir", "\"~/tmp\"", { $0.browserDownloadDir == "~/tmp" }),
            ("", "link-opener", "\"system\"", { $0.linkOpener == "system" }),
            ("control", "enabled", "false", { !$0.controlSocket }),
            ("control", "mode", "\"readonly\"", { $0.controlMode == "readonly" }),
            ("control", "mode", "\"on\"", { $0.controlMode == "ask" }),
            ("control", "expose-browser", "\"never\"", { $0.controlExposeBrowser == "never" }),
            ("control", "send-text", "true", { $0.controlSendText }),
        ]
        for item in frozen {
            let head = item.section.isEmpty ? "" : "[\(item.section)]\n"
            let toml = "\(head)\(item.key) = \(item.value)\n"
            XCTAssertNotNil(ConfigSchema.byRef[ConfigKeyRef(item.section, item.key)],
                            "注册表不再认得旧写法 [\(item.section)] \(item.key)")
            XCTAssertTrue(item.check(ConfigStore.parse(toml)),
                          "旧写法 [\(item.section)] \(item.key) = \(item.value) 解析结果变了")
        }
        // 一整份旧文件一次过（顺序、混排都照旧）
        var whole = frozen.filter { $0.section.isEmpty && $0.key != "dwindle-gap" && $0.key != "pane-gap" }
            .map { "\($0.key) = \($0.value)" }
        whole.append("dwindle-gap = 9")   // 旧名单独在时仍然生效
        whole.append("[control]")
        whole.append(contentsOf: frozen.filter { $0.section == "control" && $0.value != "\"on\"" }
            .map { "\($0.key) = \($0.value)" })
        let all = ConfigStore.parse(whole.joined(separator: "\n") + "\n")
        XCTAssertEqual(all.paneGap, 9, "只有 dwindle-gap 时它说了算")
        XCTAssertEqual(all.workspaces, 8)
        XCTAssertFalse(all.controlSocket, "旧的 [control] enabled = false 仍然关掉监听")
        XCTAssertFalse(ControlCommandRunner.Config(all).isListening)
        // 越界脾气也照旧（clamp / 拒绝）
        XCTAssertEqual(ConfigStore.parse("workspaces = 99").workspaces, 10)
        XCTAssertEqual(ConfigStore.parse("pane-padding = -3").panePadding, 0)
        XCTAssertEqual(ConfigStore.parse("browser-tab-width = 9999").browserTabWidth, 600)
        XCTAssertEqual(ConfigStore.parse("theme = \"\"").themeName, "", "空 theme 仍然是「显式不选」")
        XCTAssertEqual(ConfigStore.parse("browser-home = \"\"").browserHome,
                       ConfigStore.Settings().browserHome, "空值仍然保留默认")
    }

    /// 布尔：认得的写法一律认，**不认得的一律拒绝并留一条 diagnostic**。
    /// 以前默认开的键写 off / 0 / no 会被悄悄读成"开"
    func testBoolSpellingsAndRejectionsAreReported() {
        for word in ["off", "0", "no", "OFF"] {
            XCTAssertFalse(ConfigStore.parse("[control]\nsocket = \(word)\n").controlSocket,
                           "socket = \(word) 必须真的关掉")
            XCTAssertFalse(ConfigStore.parse("[control]\nmcp = \(word)\n").controlMCP)
            XCTAssertFalse(ControlConfigGate(text: "[control]\nsocket = \(word)\n").isListening)
        }
        for word in ["on", "1", "yes", "TRUE"] {
            XCTAssertTrue(ConfigStore.parse("[control]\nsocket = \(word)\n").controlSocket)
            XCTAssertTrue(ConfigStore.parse("[browser]\ninspectable = \(word)\n").browserInspectable,
                          "默认关的键写 \(word) 就是开")
        }
        let bad = ConfigStore.parseDetailed("[control]\nsocket = maybe\n")
        XCTAssertTrue(bad.settings.controlSocket, "认不出来 → 保留默认（默认是开）")
        let note = bad.diagnostics.first { $0.id == "control.socket" }
        XCTAssertNotNil(note, "认不出来的值必须留下一条「这行没生效」")
        XCTAssertTrue(note?.messageZH.contains("socket") ?? false, note?.messageZH ?? "")
        XCTAssertTrue(note?.messageZH.contains("maybe") ?? false, note?.messageZH ?? "")
        XCTAssertEqual(note?.ref, ConfigKeyRef("control", "socket"))
        // 合法的值一条 diagnostic 都不该有（模板自己更不该有）
        XCTAssertTrue(ConfigStore.parseDetailed(ConfigStore.template).diagnostics.isEmpty)
        XCTAssertTrue(ConfigStore.parseDetailed("[control]\nsocket = off\n").diagnostics.isEmpty)
        // 旧写法同样能真的关掉
        XCTAssertFalse(ConfigStore.parse("[control]\nenabled = off\n").controlSocket)
    }

    /// 新旧同时出现：一般情况新名赢（与行序无关）
    func testCanonicalWinsOverLegacy() {
        XCTAssertEqual(ConfigStore.parse("dwindle-gap = 4\n[appearance]\npane-gap = 7\n").paneGap, 7)
        XCTAssertEqual(ConfigStore.parse("[appearance]\npane-gap = 7\ndwindle-gap = 4\n").paneGap, 7)
        XCTAssertEqual(ConfigStore.parse("dwindle-gap = 4\n").paneGap, 4, "只有旧名时旧名生效")
        XCTAssertEqual(ConfigStore.parse("browser-home = \"https://old\"\n[browser]\nhome = \"https://new\"\n")
            .browserHome, "https://new")
    }

    // MARK: 越界行为（照抄历史，不许静悄悄改）

    /// 数值 clamp，枚举 / 空串拒绝并保留默认——每一类各一条
    func testOutOfRangeBehaviourPerKind() {
        for spec in ConfigSchema.keys {
            switch spec.kind {
            case .int(let lo, let hi):
                XCTAssertEqual(spec.coerce("999999"), .int(hi), "\(spec.id) 上界应 clamp")
                XCTAssertEqual(spec.coerce("-999999"), .int(lo), "\(spec.id) 下界应 clamp")
                XCTAssertNil(spec.coerce("abc"), "\(spec.id) 非数字应拒绝")
                XCTAssertEqual(spec.outOfRange, .clamp)
            case .double(let lo, let hi):
                XCTAssertEqual(spec.coerce("99"), .double(hi), "\(spec.id) 上界应 clamp")
                XCTAssertEqual(spec.coerce("-99"), .double(lo), "\(spec.id) 下界应 clamp")
                XCTAssertNil(spec.coerce("abc"), "\(spec.id) 非数字应拒绝")
                XCTAssertEqual(spec.outOfRange, .clamp)
            case .enumeration(_, let strict):
                if strict {
                    XCTAssertNil(spec.coerce("yolo"), "\(spec.id) 是严格枚举，不认得的值必须拒绝")
                    XCTAssertEqual(spec.outOfRange, .reject)
                } else {
                    XCTAssertEqual(spec.coerce("yolo"), .string("yolo"),
                                   "\(spec.id) 历史上是「非空即收」，这次重构不改它的脾气")
                    XCTAssertNil(spec.coerce(""))
                }
            case .string, .path:
                if spec.acceptsEmpty {
                    XCTAssertEqual(spec.coerce(""), .string(""))
                } else {
                    XCTAssertNil(spec.coerce(""), "\(spec.id) 空值不该覆盖默认")
                }
            case .bool:
                // 布尔只认那张字面量表；表外的值一律拒绝（= 保留默认，并留一条 diagnostic）
                for truthy in ["true", "TRUE", "1", "yes", "on"] {
                    XCTAssertEqual(spec.coerce(truthy), .bool(true), "\(spec.id) 认不出真值 \(truthy)")
                }
                for falsey in ["false", "False", "0", "no", "off"] {
                    XCTAssertEqual(spec.coerce(falsey), .bool(false), "\(spec.id) 认不出假值 \(falsey)")
                }
                XCTAssertNil(spec.coerce("maybe"), "\(spec.id) 怪值必须拒绝，绝不猜一个")
                XCTAssertEqual(spec.outOfRange, .reject)
            }
        }
        // 几条钉死的历史行为（回归）
        XCTAssertEqual(ConfigStore.parse("workspaces = 99").workspaces, 10)
        XCTAssertEqual(ConfigStore.parse("workspaces = 0").workspaces, 1)
        XCTAssertEqual(ConfigStore.parse("pane-opacity = 0.1").paneOpacity, 0.5, accuracy: 0.001)
        XCTAssertEqual(ConfigStore.parse("[control]\nmode = \"yolo\"\n").controlMode, "ask")
        XCTAssertEqual(ConfigStore.parse("[control]\nexpose-browser = \"yolo\"\n").controlExposeBrowser, "token")
        XCTAssertEqual(ConfigStore.parse("browser-download-dir = \"\"").browserDownloadDir, "~/Downloads")
    }

    // MARK: 样例值

    /// 给一个键造一个"肯定不是默认值"的合法值
    static func sample(for spec: ConfigKeySpec) -> String {
        switch spec.kind {
        case .bool:
            return String(!(spec.defaultValue.boolValue ?? true))
        case .int(let lo, let hi):
            let current = spec.defaultValue.intValue ?? lo
            return String(current + 1 <= hi ? current + 1 : current - 1)
        case .double(let lo, let hi):
            let current = spec.defaultValue.doubleValue ?? lo
            return String(format: "%g", current + 0.01 <= hi ? current + 0.01 : current - 0.01)
        case .enumeration(let values, _):
            return "\"\(values.first { $0 != spec.defaultValue.stringValue } ?? values[0])\""
        case .string, .path:
            return "\"qt-\(spec.key)\""
        }
    }
}

// MARK: - [control] 的两个开关

final class ControlSwitchConfigTests: XCTestCase {
    func testDefaultsAreOn() {
        let defaults = ConfigStore.parse("")
        XCTAssertTrue(defaults.controlSocket, "[control] socket 默认开")
        XCTAssertTrue(defaults.controlMCP, "[control] mcp 默认开")
        XCTAssertTrue(ControlCommandRunner.Config(defaults).isListening)
        XCTAssertTrue(ControlConfigGate(text: "").socket)
        XCTAssertTrue(ControlConfigGate(text: "").mcp)
    }

    /// socket / 旧名 enabled / mode 三个开关的优先级表：**取最严的那个**
    func testListenerPrecedenceTable() {
        let cases: [(toml: String, listening: Bool, why: String)] = [
            ("", true, "什么都不写 = 开"),
            ("[control]\nsocket = true\n", true, "新名 true"),
            ("[control]\nsocket = false\n", false, "新名 false"),
            ("[control]\nenabled = false\n", false, "旧名 false 仍然有效"),
            ("[control]\nenabled = true\n", true, "旧名 true"),
            ("[control]\nsocket = true\nenabled = false\n", false, "两个都在 → 取最严"),
            ("[control]\nsocket = false\nenabled = true\n", false, "两个都在 → 取最严（与行序无关）"),
            ("[control]\nenabled = true\nsocket = false\n", false, "两个都在 → 取最严（换个行序）"),
            ("[control]\nmode = \"off\"\n", false, "mode = off 也等于不监听"),
            ("[control]\nsocket = true\nmode = \"off\"\n", false, "socket 开也救不回 mode = off"),
            ("[control]\nsocket = false\nmode = \"ask\"\n", false, "mode 正常也救不回 socket = false"),
            ("[control]\nmode = \"readonly\"\n", true, "只读仍然监听"),
        ]
        for item in cases {
            let settings = ConfigStore.parse(item.toml)
            XCTAssertEqual(ControlCommandRunner.Config(settings).isListening, item.listening, item.why)
            // CLI 侧那份（不带 AppKit）必须给出同一个答案，否则两边会各说各话
            XCTAssertEqual(ControlConfigGate(text: item.toml).isListening, item.listening,
                           "CLI 闸门与 app 解析不一致：\(item.why)")
        }
    }

    /// 闸门与 app 的解析同源：三个 [control] 值逐一对齐
    func testGateMatchesAppParse() {
        for toml in ["", "[control]\nsocket = false\n", "[control]\nmcp = false\n",
                     "[control]\nenabled = false\nmcp = false\n", "[control]\nmode = \"readonly\"\n",
                     "[control]\nmode = \"on\"\n"] {
            let settings = ConfigStore.parse(toml)
            let gate = ControlConfigGate(text: toml)
            XCTAssertEqual(gate.socket, settings.controlSocket, toml)
            XCTAssertEqual(gate.mcp, settings.controlMCP, toml)
            XCTAssertEqual(gate.mode, settings.controlMode, toml)
        }
    }

    /// 用例宿主里 `.load()` 不许去读开发者真正的 ~/.config/quickterm/config.toml：
    /// `serve(gate: .load())` 这类默认参数是在调用点求值的，
    /// 谁家配置里写了 `[control] mcp = false`，哪台机器上的用例就红
    func testGateLoadIgnoresTheDeveloperConfigInTests() throws {
        let testHost = ["XCTestConfigurationFilePath": "/somewhere/Test.xctestconfiguration"]
        XCTAssertEqual(ControlConfigGate.load(environment: testHost), ControlConfigGate(),
                       "用例宿主里没指定配置文件 → 一律默认全开")
        // 真跑在用例里（本进程）也一样
        XCTAssertEqual(ControlConfigGate.load(), ControlConfigGate())
        // 显式指定了文件就照读（闸门用例走的就是这条路）
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("qt-gate-\(UUID().uuidString.prefix(8)).toml")
        defer { try? FileManager.default.removeItem(at: url) }
        try "[control]\nmcp = false\n".write(to: url, atomically: true, encoding: .utf8)
        var env = testHost
        env[ConfigPaths.environmentKey] = url.path
        XCTAssertFalse(ControlConfigGate.load(environment: env).mcp, "指定了文件就必须读它")
    }

    /// `mcp = false` 只关 MCP，不关 socket；`socket = false` 也不改写 mcp
    func testTwoSwitchesAreIndependent() {
        let noMCP = ConfigStore.parse("[control]\nmcp = false\n")
        XCTAssertTrue(noMCP.controlSocket, "关 MCP 不该顺手把命令行也关掉")
        XCTAssertFalse(noMCP.controlMCP)
        let noSocket = ConfigStore.parse("[control]\nsocket = false\n")
        XCTAssertTrue(noSocket.controlMCP, "两个开关各管各的（socket 关了 MCP 自然也连不上，但那是另一回事）")
    }

    // MARK: MCP 入口

    func testMCPGateRefusesAndNamesTheConfigKey() throws {
        XCTAssertNil(MCPServer.configRefusal(gate: ControlConfigGate()), "默认开 = 不拒绝")
        let refusal = try XCTUnwrap(MCPServer.configRefusal(gate: ControlConfigGate(socket: true, mcp: false)),
                                    "mcp = false 必须拒绝")
        XCTAssertEqual(refusal.code, ControlErrorCode.denied.rawValue)
        XCTAssertEqual(refusal.exit, ControlExit.denied.rawValue)
        XCTAssertTrue(refusal.message.contains("[control]") && refusal.message.contains("mcp"),
                      "错误里必须点名是哪个配置键：\(refusal.message)")
        XCTAssertTrue(MCPServer.configRefusal(gate: ControlConfigGate(socket: true, mcp: false),
                                              path: "/tmp/whatever.toml")?
            .message.contains("/tmp/whatever.toml") ?? false,
                      "还要点名是哪一份配置文件（冒烟 / 第二实例用的不是 ~ 那一份）")

        // serve() 是"真的开始说 MCP"的唯一出口：闸门钉在它上面，多一个入口也绕不过去
        let server = MCPServer(cliVersion: "test") { _ in
            XCTFail("被拒绝之后一条请求都不该发出去")
            throw ControlErrorBody(.failed, "unreachable")
        }
        let refused = server.serve(input: .nullDevice, output: .nullDevice,
                                   gate: ControlConfigGate(socket: true, mcp: false))
        XCTAssertEqual(refused?.exit, ControlExit.denied.rawValue)
        XCTAssertNil(server.serve(input: .nullDevice, output: .nullDevice, gate: ControlConfigGate()),
                     "开着的时候 serve 读到 EOF 正常返回")
    }

    /// 端到端：随包的那个 `quickterm` 二进制，配置里 mcp = false 时必须拒绝服务
    func testBundledCLIRefusesMCPWhenDisabled() throws {
        let cli = try XCTUnwrap(Bundle.main.sharedSupportURL?.appendingPathComponent("quickterm"))
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: cli.path),
                          "构建产物里没有随包 CLI")
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("qt-mcp-\(UUID().uuidString.prefix(8)).toml")
        defer { try? FileManager.default.removeItem(at: temporary) }

        func run(_ toml: String, _ args: [String]) throws -> (code: Int32, err: String) {
            try toml.write(to: temporary, atomically: true, encoding: .utf8)
            let process = Process()
            process.executableURL = cli
            process.arguments = args
            process.environment = ["QUICKTERM_CONFIG_FILE": temporary.path]
            process.standardInput = FileHandle.nullDevice
            let err = Pipe()
            process.standardOutput = Pipe()
            process.standardError = err
            try process.run()
            let text = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            return (process.terminationStatus, text)
        }

        let denied = try run("[control]\nmcp = false\n", ["mcp", "--plain"])
        XCTAssertEqual(denied.code, ControlExit.denied.rawValue, "退出码要能被脚本分辨")
        XCTAssertTrue(denied.err.contains("mcp"), "stderr 必须点名配置键：\(denied.err)")

        // 别的入口也别想绕过去：--list-tools 同样被拒
        XCTAssertEqual(try run("[control]\nmcp = false\n", ["mcp", "--list-tools", "--plain"]).code,
                       ControlExit.denied.rawValue)
        // 开着的时候（默认）：标准输入立刻 EOF → 正常收工
        XCTAssertEqual(try run("", ["mcp", "--plain"]).code, 0)
    }
}

// MARK: - socket = false 真的不绑

@MainActor
final class ControlSocketSwitchTests: XCTestCase {
    private var paths: [String] = []

    override func tearDown() {
        for path in paths { unlink(path) }
        paths.removeAll()
        super.tearDown()
    }

    private func tempSocketPath() throws -> String {
        let path = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("qts-\(UUID().uuidString.prefix(8)).sock")
        try XCTSkipUnless(ControlPaths.fits(path), "临时目录太长，装不进 sun_path")
        paths.append(path)
        return path
    }

    private func server(at path: String) throws -> ControlServer {
        let app = try XCTUnwrap(NSApp.delegate as? AppDelegate)
        return ControlServer(screens: app.screens, consent: ControlConsent(screens: app.screens),
                             socketPath: path)
    }

    /// `[control] socket = false`：既没有 socket 文件，服务对象也没被起起来
    func testSocketFalseNeverBinds() throws {
        for toml in ["[control]\nsocket = false\n", "[control]\nenabled = false\n",
                     "[control]\nmode = \"off\"\n"] {
            let path = try tempSocketPath()
            let server = try server(at: path)
            defer { server.stop() }
            server.apply(ControlCommandRunner.Config(ConfigStore.parse(toml)))
            XCTAssertFalse(server.isListening, "不该监听：\(toml)")
            XCTAssertNil(server.socketPath)
            XCTAssertFalse(FileManager.default.fileExists(atPath: path),
                           "socket 文件都不该出现：\(toml)")
        }
    }

    /// 反过来：默认配置是真的会绑上（否则上一条用例证明不了任何事）
    func testDefaultConfigBinds() throws {
        let path = try tempSocketPath()
        let server = try server(at: path)
        defer { server.stop() }
        server.apply(ControlCommandRunner.Config(ConfigStore.parse("")))
        XCTAssertTrue(server.isListening)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        // 热重载把开关关掉 → 停服并把 socket 文件收走
        server.apply(ControlCommandRunner.Config(ConfigStore.parse("[control]\nsocket = false\n")))
        XCTAssertFalse(server.isListening)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }
}

// MARK: - 热重载

@MainActor
final class ConfigHotReloadTests: XCTestCase {
    /// 每一个声明了 `hotReload` 的键，保存即生效（走的是真正的 `reloadConfigFile()`）
    func testEveryHotReloadableKeyAppliesOnSave() throws {
        let session = try XCTUnwrap((NSApp.delegate as? AppDelegate)?.session)
        let controller = try XCTUnwrap((NSApp.delegate as? AppDelegate)?.controller)
        let before = session.settings
        let columnsBefore = controller.visibleColumns
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("qt-hot-\(UUID().uuidString.prefix(8)).toml")
        defer {
            ConfigStore.configURLOverride = nil
            try? FileManager.default.removeItem(at: temporary)
            session.apply(before)                            // 进程内状态复原
            controller.setVisibleColumns(columnsBefore, persist: false)
        }

        var lines: [String] = []
        for section in ConfigSection.allCases where section.hasRegisteredKeys {
            let specs = ConfigSchema.specs(in: section).filter(\.hotReload)
            guard !specs.isEmpty else { continue }
            lines.append("[\(section.rawValue)]")
            for spec in specs {
                // 主题名故意用一个不存在的：验证到解析这一层就够了，
                // 真去换主题会把测试宿主的配色留给后面每一条用例
                let value = spec.id == "appearance.theme" ? "\"qt-not-a-theme\"" : ConfigSchemaTests.sample(for: spec)
                lines.append("\(spec.key) = \(value)")
            }
        }
        let text = lines.joined(separator: "\n") + "\n"
        try text.write(to: temporary, atomically: true, encoding: .utf8)
        ConfigStore.configURLOverride = temporary
        session.reloadConfigFile()

        let expected = ConfigStore.parse(text)
        XCTAssertEqual(session.settings, expected, "热重载后进程内设置必须与文件一致")
        XCTAssertNotEqual(session.settings, before, "样例值必须真的改变了什么")
        // 抽查几条真的落到了使用方（不是只存进 Settings 里）
        XCTAssertEqual(BrowserPaneView.settings.home, expected.browserHome)
        XCTAssertEqual(session.fileManagerCommand, expected.fileManagerCommand)
        XCTAssertEqual(BrowserExtensionManager.shared.isEnabled, expected.browserExtensions)
        XCTAssertTrue(session.themeManager.overlayExtra()
            .contains("window-padding-x = \(expected.panePadding)"))
        XCTAssertEqual(controller.visibleColumns, expected.visibleColumns ?? columnsBefore)
    }
}

// MARK: - 模板补全（分组之后）

final class ConfigTemplateFillTests: XCTestCase {
    /// The template comments follow the UI language (`[general] language`). This class compares
    /// the template text verbatim, so it pins the language — otherwise every case in here would
    /// go red on a machine whose system language is English.
    private var templateLanguage = ConfigSchema.templateLanguage

    override func setUp() {
        super.setUp()
        templateLanguage = ConfigSchema.templateLanguage
        ConfigSchema.templateLanguage = .zh
    }

    override func tearDown() {
        ConfigSchema.templateLanguage = templateLanguage
        super.tearDown()
    }

    private func temporaryFile(_ contents: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("qt-tpl-\(UUID().uuidString.prefix(8)).toml")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// 一份**全旧扁平写法**的配置文件（就是用户手上那一份的形状）：
    /// 只补真正新增的键，绝不因为"新名没出现"就把每个键重补一遍
    func testOldStyleFileOnlyGainsGenuinelyNewKeys() throws {
        var old = ["# QuickTerm 配置", ""]
        for spec in ConfigSchema.keys where spec.section != .control {
            let ref = spec.legacy.first ?? spec.canonical
            guard ref.section.isEmpty else { continue }
            old.append("# \(ref.name) = \(spec.defaultValue.literal)")
        }
        old.append(contentsOf: ["", "pane-gap = 4", "divider-opacity = 0", "", "[keybinds]", "", "[ghostty]"])
        let url = try temporaryFile(old.joined(separator: "\n") + "\n")
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertTrue(ConfigStore.ensureTemplateKeys(at: url), "缺 [control] → 要补")
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("# socket = true"), "新增的 socket 要补上")
        XCTAssertTrue(text.contains("# mcp = true"), "新增的 mcp 要补上")
        XCTAssertFalse(text.contains("# home = "), "旧写法 browser-home 已经在，不该再补一份新名")
        XCTAssertFalse(text.contains("# workspaces = 5\n# workspaces"), "不该补重复行")
        let controlIdx = try XCTUnwrap(text.range(of: "[control]")).lowerBound
        let keybindsIdx = try XCTUnwrap(text.range(of: "[keybinds]")).lowerBound
        XCTAssertLessThan(controlIdx, keybindsIdx, "新建的分组要摆在自由段之前")

        let parsed = ConfigStore.parse(text)
        XCTAssertEqual(parsed.paneGap, 4, "用户设过的值原样保留")
        XCTAssertEqual(parsed.dividerOpacity, 0, accuracy: 0.001)
        XCTAssertTrue(parsed.controlSocket)
        XCTAssertTrue(parsed.controlMCP)
        XCTAssertFalse(ConfigStore.ensureTemplateKeys(at: url), "第二次没得补 → 不写")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), text, "幂等")

        // 补出来的 [control] 必须与全新安装写下的那一段**逐行一致**：
        // 段说明、mode 的续行、send-text 那段"等于在那个 shell 里打字"的警告，一行都不能少
        XCTAssertEqual(Self.section("control", of: text),
                       Self.section("control", of: ConfigStore.template),
                       "补全出来的 [control] 与模板不一致（多行说明又被砍成一行了）")
        XCTAssertTrue(text.contains("**等于在那个 shell 里打字**"), "send-text 的警告不能丢")
        XCTAssertTrue(text.contains("没有\"免确认\"档"), "mode 的续行不能丢")
        XCTAssertTrue(text.contains("control.sock"), "段说明（socket 落点）不能丢")
    }

    /// 一份配置文件里某一段的内容（段头到下一个段头之前，去掉尾部空行）
    static func section(_ name: String, of text: String) -> [String] {
        var out: [String] = []
        var inside = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") {
                if inside { break }
                inside = trimmed.hasPrefix("[\(name)]")
                if inside { out.append(line) }
                continue
            }
            // 自动补全的横幅不是模板的一部分，比较时忽略
            guard inside, trimmed != ConfigStore.autofillBanner else { continue }
            out.append(line)
        }
        while out.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { out.removeLast() }
        return out
    }

    /// 文件不存在 → 落整份模板；模板自己不需要补全
    func testFreshInstallWritesTemplate() throws {
        let fm = FileManager.default
        let fresh = fm.temporaryDirectory
            .appendingPathComponent("qt-cfgdir-\(UUID().uuidString.prefix(8))/config.toml")
        defer { try? fm.removeItem(at: fresh.deletingLastPathComponent()) }
        XCTAssertTrue(ConfigStore.ensureTemplateKeys(at: fresh))
        XCTAssertEqual(try String(contentsOf: fresh, encoding: .utf8), ConfigStore.template)
        XCTAssertFalse(ConfigStore.ensureTemplateKeys(at: fresh), "模板本身不缺键")
    }

    /// 就地改写：新写法改新写法那一行，旧写法的文件就改旧写法那一行（不重排用户的文件）
    func testRewriteFollowsWhicheverSpellingTheUserUses() throws {
        let flat = try temporaryFile("# QuickTerm\n# workspaces = 5\n\n[keybinds]\n")
        let grouped = try temporaryFile("[workspace]\n# workspaces = 5\n")
        defer {
            ConfigStore.configURLOverride = nil
            for url in [flat, grouped] { try? FileManager.default.removeItem(at: url) }
        }
        for url in [flat, grouped] {
            ConfigStore.configURLOverride = url
            try ConfigStore.rewrite(key: "workspaces", value: "7")
            let text = try String(contentsOf: url, encoding: .utf8)
            XCTAssertTrue(text.contains("workspaces = 7"), text)
            XCTAssertFalse(text.contains("# workspaces = 5"), "原来那行注释应被换掉：\(text)")
            XCTAssertEqual(ConfigStore.parse(text).workspaces, 7, "改写出来的还得能解析回来")
        }
        // 文件里压根没有这个键 → 插进它所属的分组
        let bare = try temporaryFile("theme = \"nord\"\n")
        defer { try? FileManager.default.removeItem(at: bare) }
        ConfigStore.configURLOverride = bare
        try ConfigStore.rewrite(key: "workspaces", value: "3")
        let text = try String(contentsOf: bare, encoding: .utf8)
        XCTAssertEqual(ConfigStore.parse(text).workspaces, 3)
        XCTAssertEqual(ConfigStore.parse(text).themeName, "nord", "别的内容不许动")
        XCTAssertThrowsError(try ConfigStore.rewrite(key: "not-a-key", value: "1"))
    }
}
