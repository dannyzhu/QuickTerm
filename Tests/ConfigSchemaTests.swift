import AppKit
import XCTest
@testable import QuickTerm

/// Cases for the config registry (`Sources/Config/ConfigSchema.swift`).
///
/// This file exists to **mechanically enforce** one project rule: "every config key has to appear in the
/// template, in the parser, in both READMEs and in a test". Left to human diligence that slips;
/// `testEveryKeyIsDocumented` does not.
final class ConfigSchemaTests: XCTestCase {
    /// The repo root (tests run out of the build products, so a README is only reachable by source path).
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

    // MARK: The registry is the single source of truth

    /// Every config key appears in the template and in both READMEs, and **the default is identical in all three**.
    func testEveryKeyIsDocumented() throws {
        let template = ConfigStore.template
        let en = try readme("README")
        let zh = try readme("README.zh-CN")
        for spec in ConfigSchema.keys {
            let line = spec.templateAssignment   // "# home = \"https://www.google.com\""
            XCTAssertTrue(template.contains(line), "the template is missing \(spec.id): \(line)")
            XCTAssertTrue(en.contains(line), "README.md is missing \(spec.id): \(line)")
            XCTAssertTrue(zh.contains(line), "README.zh-CN.md is missing \(spec.id): \(line)")
        }
        // The block copied in when a key is missing has to appear line for line in the template: one renderer,
        // pinned so the two cannot drift apart.
        for (spec, lines) in ConfigSchema.templateKeyBlocks {
            XCTAssertTrue(template.contains(lines.joined(separator: "\n")),
                          "the template and the fill-in block disagree: \(spec.id)")
        }
        for section in ConfigSection.allCases {
            XCTAssertTrue(template.contains("[\(section.rawValue)]"), "the template is missing the [\(section.rawValue)] section")
        }
        for doc in [en, zh] {
            for section in ConfigSection.allCases where section.hasRegisteredKeys {
                XCTAssertTrue(doc.contains("[\(section.rawValue)]"), "the README is missing the [\(section.rawValue)] section")
            }
        }
    }

    /// The registry maps one-to-one onto the Settings field each key writes: one extra or one missing means
    /// a config line that silently does nothing.
    func testEveryKeyHasABinding() {
        XCTAssertEqual(Set(ConfigSchema.keys.map(\.id)), Set(ConfigBindings.table.keys))
    }

    /// Template round trip: the template is all comments, so parsing it yields exactly the defaults;
    /// uncomment any single line and you get back precisely the default the registry declares.
    func testTemplateRoundTrips() {
        XCTAssertEqual(ConfigStore.parse(ConfigStore.template), ConfigStore.Settings(),
                       "every line in the template is a comment, so parsing it has to equal the bare defaults")
        for spec in ConfigSchema.keys {
            let text = "[\(spec.section.rawValue)]\n\(spec.key) = \(spec.defaultValue.literal)\n"
            XCTAssertEqual(ConfigSchema.resolve(text)[spec.id], spec.defaultValue,
                           "the default the template shows for \(spec.id) does not parse back to itself")
        }
    }

    // MARK: Old spellings keep working forever

    /// **Table-driven across the whole list of old names**, not a spot check: every legacy spelling has to
    /// parse into the same Settings as its new name.
    func testEveryLegacySpellingParsesLikeItsNewName() {
        for spec in ConfigSchema.keys {
            for value in [spec.defaultValue.literal, Self.sample(for: spec)] {
                let modern = ConfigStore.parse("[\(spec.section.rawValue)]\n\(spec.key) = \(value)\n")
                for ref in spec.legacy {
                    let head = ref.section.isEmpty ? "" : "[\(ref.section)]\n"
                    let legacy = ConfigStore.parse("\(head)\(ref.name) = \(value)\n")
                    XCTAssertEqual(legacy, modern,
                                   "the old spelling [\(ref.section)] \(ref.name) = \(value) is not equivalent to the new one")
                }
            }
        }
    }

    /// A config written **entirely in the old flat style** has to parse identically to the same content in
    /// the new grouped style.
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
        XCTAssertEqual(a, b, "the old flat style and the new grouped style have to match field for field")
        XCTAssertNotEqual(a, ConfigStore.Settings(),
                          "the sample values have to really differ from the defaults, or this case proves nothing")
    }

    /// **The pre-refactor key table, pinned row by row.** This list was copied out of `ConfigStore.parse` as
    /// it stood before the change and owes the registry nothing: if the registry drops a key, renames one, or
    /// changes its temperament, this case goes red.
    /// The old, entirely flat config.toml a user already has must not need a single edit.
    func testPreChangeKeyListParsesExactlyLikeBefore() {
        // (spelling, value, assertion)
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
                            "the registry no longer knows the old spelling [\(item.section)] \(item.key)")
            XCTAssertTrue(item.check(ConfigStore.parse(toml)),
                          "the old spelling [\(item.section)] \(item.key) = \(item.value) now parses differently")
        }
        // A whole old file in one pass, original ordering and mixing included.
        var whole = frozen.filter { $0.section.isEmpty && $0.key != "dwindle-gap" && $0.key != "pane-gap" }
            .map { "\($0.key) = \($0.value)" }
        whole.append("dwindle-gap = 9")   // The old name on its own still takes effect
        whole.append("[control]")
        whole.append(contentsOf: frozen.filter { $0.section == "control" && $0.value != "\"on\"" }
            .map { "\($0.key) = \($0.value)" })
        let all = ConfigStore.parse(whole.joined(separator: "\n") + "\n")
        XCTAssertEqual(all.paneGap, 9, "with only dwindle-gap present, it decides")
        XCTAssertEqual(all.workspaces, 8)
        XCTAssertFalse(all.controlSocket, "the old [control] enabled = false still turns the listener off")
        XCTAssertFalse(ControlCommandRunner.Config(all).isListening)
        // Out-of-range temperament is unchanged too: clamp or reject.
        XCTAssertEqual(ConfigStore.parse("workspaces = 99").workspaces, 10)
        XCTAssertEqual(ConfigStore.parse("pane-padding = -3").panePadding, 0)
        XCTAssertEqual(ConfigStore.parse("browser-tab-width = 9999").browserTabWidth, 600)
        XCTAssertEqual(ConfigStore.parse("theme = \"\"").themeName, "", "an empty theme still means \"explicitly none\"")
        XCTAssertEqual(ConfigStore.parse("browser-home = \"\"").browserHome,
                       ConfigStore.Settings().browserHome, "an empty value still keeps the default")
    }

    /// Booleans: every spelling it knows is accepted, and **anything else is rejected with a diagnostic left
    /// behind**. A key that defaults to on used to read off / 0 / no silently as "on".
    func testBoolSpellingsAndRejectionsAreReported() {
        for word in ["off", "0", "no", "OFF"] {
            XCTAssertFalse(ConfigStore.parse("[control]\nsocket = \(word)\n").controlSocket,
                           "socket = \(word) really has to turn it off")
            XCTAssertFalse(ConfigStore.parse("[control]\nmcp = \(word)\n").controlMCP)
            XCTAssertFalse(ControlConfigGate(text: "[control]\nsocket = \(word)\n").isListening)
        }
        for word in ["on", "1", "yes", "TRUE"] {
            XCTAssertTrue(ConfigStore.parse("[control]\nsocket = \(word)\n").controlSocket)
            XCTAssertTrue(ConfigStore.parse("[browser]\ninspectable = \(word)\n").browserInspectable,
                          "a key that defaults to off is on when written \(word)")
        }
        let bad = ConfigStore.parseDetailed("[control]\nsocket = maybe\n")
        XCTAssertTrue(bad.settings.controlSocket, "unrecognized -> keep the default, which here is on")
        let note = bad.diagnostics.first { $0.id == "control.socket" }
        XCTAssertNotNil(note, "an unrecognized value has to leave a \"this line did nothing\" note")
        XCTAssertTrue(note?.messageZH.contains("socket") ?? false, note?.messageZH ?? "")
        XCTAssertTrue(note?.messageZH.contains("maybe") ?? false, note?.messageZH ?? "")
        XCTAssertEqual(note?.ref, ConfigKeyRef("control", "socket"))
        // A valid value leaves no diagnostic at all, and the template least of all.
        XCTAssertTrue(ConfigStore.parseDetailed(ConfigStore.template).diagnostics.isEmpty)
        XCTAssertTrue(ConfigStore.parseDetailed("[control]\nsocket = off\n").diagnostics.isEmpty)
        // The old spelling really turns it off too.
        XCTAssertFalse(ConfigStore.parse("[control]\nenabled = off\n").controlSocket)
    }

    /// When both spellings appear the new name normally wins, regardless of line order.
    func testCanonicalWinsOverLegacy() {
        XCTAssertEqual(ConfigStore.parse("dwindle-gap = 4\n[appearance]\npane-gap = 7\n").paneGap, 7)
        XCTAssertEqual(ConfigStore.parse("[appearance]\npane-gap = 7\ndwindle-gap = 4\n").paneGap, 7)
        XCTAssertEqual(ConfigStore.parse("dwindle-gap = 4\n").paneGap, 4, "with only the old name present, the old name applies")
        XCTAssertEqual(ConfigStore.parse("browser-home = \"https://old\"\n[browser]\nhome = \"https://new\"\n")
            .browserHome, "https://new")
    }

    // MARK: Out-of-range behavior (copied from history; no quiet changes)

    /// Numbers clamp; enums and empty strings are rejected and keep the default. One case per kind.
    func testOutOfRangeBehaviourPerKind() {
        for spec in ConfigSchema.keys {
            switch spec.kind {
            case .int(let lo, let hi):
                XCTAssertEqual(spec.coerce("999999"), .int(hi), "\(spec.id) has to clamp at the upper bound")
                XCTAssertEqual(spec.coerce("-999999"), .int(lo), "\(spec.id) has to clamp at the lower bound")
                XCTAssertNil(spec.coerce("abc"), "\(spec.id) has to reject a non-number")
                XCTAssertEqual(spec.outOfRange, .clamp)
            case .double(let lo, let hi):
                XCTAssertEqual(spec.coerce("99"), .double(hi), "\(spec.id) has to clamp at the upper bound")
                XCTAssertEqual(spec.coerce("-99"), .double(lo), "\(spec.id) has to clamp at the lower bound")
                XCTAssertNil(spec.coerce("abc"), "\(spec.id) has to reject a non-number")
                XCTAssertEqual(spec.outOfRange, .clamp)
            case .enumeration(_, let strict):
                if strict {
                    XCTAssertNil(spec.coerce("yolo"), "\(spec.id) is a strict enum: an unknown value has to be rejected")
                    XCTAssertEqual(spec.outOfRange, .reject)
                } else {
                    XCTAssertEqual(spec.coerce("yolo"), .string("yolo"),
                                   "\(spec.id) has always taken anything non-empty, and this refactor leaves that temperament alone")
                    XCTAssertNil(spec.coerce(""))
                }
            case .string, .path:
                if spec.acceptsEmpty {
                    XCTAssertEqual(spec.coerce(""), .string(""))
                } else {
                    XCTAssertNil(spec.coerce(""), "an empty value for \(spec.id) must not override the default")
                }
            case .bool:
                // Booleans know only that table of literals; anything outside it is rejected, which means
                // keeping the default and leaving a diagnostic.
                for truthy in ["true", "TRUE", "1", "yes", "on"] {
                    XCTAssertEqual(spec.coerce(truthy), .bool(true), "\(spec.id) does not recognize the true spelling \(truthy)")
                }
                for falsey in ["false", "False", "0", "no", "off"] {
                    XCTAssertEqual(spec.coerce(falsey), .bool(false), "\(spec.id) does not recognize the false spelling \(falsey)")
                }
                XCTAssertNil(spec.coerce("maybe"), "\(spec.id) has to reject an odd value and never guess one")
                XCTAssertEqual(spec.outOfRange, .reject)
            }
        }
        // A few historical behaviors pinned as regressions.
        XCTAssertEqual(ConfigStore.parse("workspaces = 99").workspaces, 10)
        XCTAssertEqual(ConfigStore.parse("workspaces = 0").workspaces, 1)
        XCTAssertEqual(ConfigStore.parse("pane-opacity = 0.1").paneOpacity, 0.5, accuracy: 0.001)
        XCTAssertEqual(ConfigStore.parse("[control]\nmode = \"yolo\"\n").controlMode, "ask")
        XCTAssertEqual(ConfigStore.parse("[control]\nexpose-browser = \"yolo\"\n").controlExposeBrowser, "token")
        XCTAssertEqual(ConfigStore.parse("browser-download-dir = \"\"").browserDownloadDir, "~/Downloads")
    }

    // MARK: Sample values

    /// Build a legal value for a key that is guaranteed not to be its default.
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

// MARK: - The two [control] switches

final class ControlSwitchConfigTests: XCTestCase {
    func testDefaultsAreOn() {
        let defaults = ConfigStore.parse("")
        XCTAssertTrue(defaults.controlSocket, "[control] socket is on by default")
        XCTAssertTrue(defaults.controlMCP, "[control] mcp is on by default")
        XCTAssertTrue(ControlCommandRunner.Config(defaults).isListening)
        XCTAssertTrue(ControlConfigGate(text: "").socket)
        XCTAssertTrue(ControlConfigGate(text: "").mcp)
    }

    /// The precedence table for socket, the old name enabled, and mode: **the strictest one wins**.
    func testListenerPrecedenceTable() {
        let cases: [(toml: String, listening: Bool, why: String)] = [
            ("", true, "nothing written at all means on"),
            ("[control]\nsocket = true\n", true, "the new name, true"),
            ("[control]\nsocket = false\n", false, "the new name, false"),
            ("[control]\nenabled = false\n", false, "the old name, false, still counts"),
            ("[control]\nenabled = true\n", true, "the old name, true"),
            ("[control]\nsocket = true\nenabled = false\n", false, "both present -> take the strictest"),
            ("[control]\nsocket = false\nenabled = true\n", false, "both present -> the strictest, whatever the line order"),
            ("[control]\nenabled = true\nsocket = false\n", false, "both present -> the strictest, lines swapped"),
            ("[control]\nmode = \"off\"\n", false, "mode = off also means no listener"),
            ("[control]\nsocket = true\nmode = \"off\"\n", false, "socket on cannot rescue mode = off"),
            ("[control]\nsocket = false\nmode = \"ask\"\n", false, "a normal mode cannot rescue socket = false"),
            ("[control]\nmode = \"readonly\"\n", true, "readonly still listens"),
        ]
        for item in cases {
            let settings = ConfigStore.parse(item.toml)
            XCTAssertEqual(ControlCommandRunner.Config(settings).isListening, item.listening, item.why)
            // The CLI-side copy, which has no AppKit, has to give the same answer, or the two talk past each other.
            XCTAssertEqual(ControlConfigGate(text: item.toml).isListening, item.listening,
                           "the CLI gate and the app's parse disagree: \(item.why)")
        }
    }

    /// The gate and the app parse from one source: all three [control] values line up.
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

    /// Inside a test host, `.load()` must not read the developer's real ~/.config/quickterm/config.toml:
    /// a default argument like `serve(gate: .load())` is evaluated at the call site, so anyone whose own
    /// config says `[control] mcp = false` would watch these cases go red on their machine.
    func testGateLoadIgnoresTheDeveloperConfigInTests() throws {
        let testHost = ["XCTestConfigurationFilePath": "/somewhere/Test.xctestconfiguration"]
        XCTAssertEqual(ControlConfigGate.load(environment: testHost), ControlConfigGate(),
                       "no config file named in a test host -> everything defaults to on")
        // The real thing, running inside this test process, behaves the same.
        XCTAssertEqual(ControlConfigGate.load(), ControlConfigGate())
        // A file named explicitly is read as usual, which is the path the gate cases take.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("qt-gate-\(UUID().uuidString.prefix(8)).toml")
        defer { try? FileManager.default.removeItem(at: url) }
        try "[control]\nmcp = false\n".write(to: url, atomically: true, encoding: .utf8)
        var env = testHost
        env[ConfigPaths.environmentKey] = url.path
        XCTAssertFalse(ControlConfigGate.load(environment: env).mcp, "once a file is named it has to be read")
    }

    /// `mcp = false` turns off MCP only, not the socket, and `socket = false` does not rewrite mcp.
    func testTwoSwitchesAreIndependent() {
        let noMCP = ConfigStore.parse("[control]\nmcp = false\n")
        XCTAssertTrue(noMCP.controlSocket, "turning MCP off must not take the command line down with it")
        XCTAssertFalse(noMCP.controlMCP)
        let noSocket = ConfigStore.parse("[control]\nsocket = false\n")
        XCTAssertTrue(noSocket.controlMCP,
                      "the two switches are independent (with the socket off MCP cannot connect either, but that is a different matter)")
    }

    // MARK: The MCP entry point

    func testMCPGateRefusesAndNamesTheConfigKey() throws {
        XCTAssertNil(MCPServer.configRefusal(gate: ControlConfigGate()), "on by default means no refusal")
        let refusal = try XCTUnwrap(MCPServer.configRefusal(gate: ControlConfigGate(socket: true, mcp: false)),
                                    "mcp = false has to refuse")
        XCTAssertEqual(refusal.code, ControlErrorCode.disabled.rawValue)
        XCTAssertEqual(refusal.exit, ControlExit.denied.rawValue)
        XCTAssertTrue(refusal.message.contains("[control]") && refusal.message.contains("mcp"),
                      "the error has to name the config key: \(refusal.message)")
        XCTAssertTrue(MCPServer.configRefusal(gate: ControlConfigGate(socket: true, mcp: false),
                                              path: "/tmp/whatever.toml")?
            .message.contains("/tmp/whatever.toml") ?? false,
                      "and name which config file it is (smoke runs and a second instance do not use the one under ~)")

        // serve() is the only way to actually start speaking MCP: the gate is nailed to it, so no extra entry point slips past.
        let server = MCPServer(cliVersion: "test") { _ in
            XCTFail("not one request may go out after a refusal")
            throw ControlErrorBody(.failed, "unreachable")
        }
        let refused = server.serve(input: .nullDevice, output: .nullDevice,
                                   gate: ControlConfigGate(socket: true, mcp: false))
        XCTAssertEqual(refused?.exit, ControlExit.denied.rawValue)
        XCTAssertNil(server.serve(input: .nullDevice, output: .nullDevice, gate: ControlConfigGate()),
                     "while enabled, serve returns normally when it reads EOF")
    }

    /// End to end: the bundled `quickterm` binary has to refuse service when the config says mcp = false.
    func testBundledCLIRefusesMCPWhenDisabled() throws {
        let cli = try XCTUnwrap(Bundle.main.sharedSupportURL?.appendingPathComponent("quickterm"))
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: cli.path),
                          "the build products contain no bundled CLI")
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
        XCTAssertEqual(denied.code, ControlExit.denied.rawValue, "the exit code has to be distinguishable from a script")
        XCTAssertTrue(denied.err.contains("mcp"), "stderr has to name the config key: \(denied.err)")

        // No other entry point gets around it either: --list-tools is refused just the same.
        XCTAssertEqual(try run("[control]\nmcp = false\n", ["mcp", "--list-tools", "--plain"]).code,
                       ControlExit.denied.rawValue)
        // While enabled (the default): stdin hits EOF immediately and it finishes normally.
        XCTAssertEqual(try run("", ["mcp", "--plain"]).code, 0)
    }
}

// MARK: - socket = false really does not bind

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
        try XCTSkipUnless(ControlPaths.fits(path), "the temp directory is too long to fit in sun_path")
        paths.append(path)
        return path
    }

    private func server(at path: String) throws -> ControlServer {
        let app = try XCTUnwrap(NSApp.delegate as? AppDelegate)
        return ControlServer(screens: app.screens, consent: ControlConsent(screens: app.screens),
                             socketPath: path)
    }

    /// `[control] socket = false`: no socket file appears, and the server object is never started either.
    func testSocketFalseNeverBinds() throws {
        for toml in ["[control]\nsocket = false\n", "[control]\nenabled = false\n",
                     "[control]\nmode = \"off\"\n"] {
            let path = try tempSocketPath()
            let server = try server(at: path)
            defer { server.stop() }
            server.apply(ControlCommandRunner.Config(ConfigStore.parse(toml)))
            XCTAssertFalse(server.isListening, "must not listen: \(toml)")
            XCTAssertNil(server.socketPath)
            XCTAssertFalse(FileManager.default.fileExists(atPath: path),
                           "not even the socket file may appear: \(toml)")
        }
    }

    /// The other direction: the default config really does bind, or the case above would prove nothing.
    func testDefaultConfigBinds() throws {
        let path = try tempSocketPath()
        let server = try server(at: path)
        defer { server.stop() }
        server.apply(ControlCommandRunner.Config(ConfigStore.parse("")))
        XCTAssertTrue(server.isListening)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        // A hot reload that flips the switch off stops the server and takes the socket file away.
        server.apply(ControlCommandRunner.Config(ConfigStore.parse("[control]\nsocket = false\n")))
        XCTAssertFalse(server.isListening)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }
}

// MARK: - Hot reload

@MainActor
final class ConfigHotReloadTests: XCTestCase {
    /// Every key that declares `hotReload` takes effect on save, through the real `reloadConfigFile()`.
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
            session.apply(before)                            // Restore the in-process state
            controller.setVisibleColumns(columnsBefore, persist: false)
        }

        var lines: [String] = []
        for section in ConfigSection.allCases where section.hasRegisteredKeys {
            let specs = ConfigSchema.specs(in: section).filter(\.hotReload)
            guard !specs.isEmpty else { continue }
            lines.append("[\(section.rawValue)]")
            for spec in specs {
                // The theme name is deliberately one that does not exist: checking as far as parsing is enough,
                // and really switching themes would leave the test host recolored for every case after this one.
                let value = spec.id == "appearance.theme" ? "\"qt-not-a-theme\"" : ConfigSchemaTests.sample(for: spec)
                lines.append("\(spec.key) = \(value)")
            }
        }
        let text = lines.joined(separator: "\n") + "\n"
        try text.write(to: temporary, atomically: true, encoding: .utf8)
        ConfigStore.configURLOverride = temporary
        session.reloadConfigFile()

        let expected = ConfigStore.parse(text)
        XCTAssertEqual(session.settings, expected, "after a hot reload the in-process settings have to match the file")
        XCTAssertNotEqual(session.settings, before, "the sample values really have to change something")
        // Spot-check a few that really reached their consumers, rather than only landing in Settings.
        XCTAssertEqual(BrowserPaneView.settings.home, expected.browserHome)
        XCTAssertEqual(session.fileManagerCommand, expected.fileManagerCommand)
        XCTAssertEqual(BrowserExtensionManager.shared.isEnabled, expected.browserExtensions)
        XCTAssertTrue(session.themeManager.overlayExtra()
            .contains("window-padding-x = \(expected.panePadding)"))
        XCTAssertEqual(controller.visibleColumns, expected.visibleColumns ?? columnsBefore)
    }
}

// MARK: - Template fill-in (after the grouping)

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

    /// A config file written **entirely in the old flat style**, the shape of the one a user already has:
    /// only genuinely new keys are filled in, and no key is filled in again just because "the new name is missing".
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

        XCTAssertTrue(ConfigStore.ensureTemplateKeys(at: url), "[control] is missing -> fill it in")
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("# socket = true"), "the newly added socket key gets filled in")
        XCTAssertTrue(text.contains("# mcp = true"), "the newly added mcp key gets filled in")
        XCTAssertFalse(text.contains("# home = "), "the old spelling browser-home is already there; the new name must not be added on top")
        XCTAssertFalse(text.contains("# workspaces = 5\n# workspaces"), "no duplicate lines")
        let controlIdx = try XCTUnwrap(text.range(of: "[control]")).lowerBound
        let keybindsIdx = try XCTUnwrap(text.range(of: "[keybinds]")).lowerBound
        XCTAssertLessThan(controlIdx, keybindsIdx, "a newly created section goes in before the free-form ones")

        let parsed = ConfigStore.parse(text)
        XCTAssertEqual(parsed.paneGap, 4, "a value the user set is kept verbatim")
        XCTAssertEqual(parsed.dividerOpacity, 0, accuracy: 0.001)
        XCTAssertTrue(parsed.controlSocket)
        XCTAssertTrue(parsed.controlMCP)
        XCTAssertFalse(ConfigStore.ensureTemplateKeys(at: url), "nothing to fill in the second time -> no write")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), text, "idempotent")

        // The [control] block that gets filled in has to match the one a fresh install writes **line for line**:
        // the section note, mode's continuation lines, and the send-text warning that this is the same as typing
        // into that shell. Not one line may go missing.
        XCTAssertEqual(Self.section("control", of: text),
                       Self.section("control", of: ConfigStore.template),
                       "the filled-in [control] does not match the template (the multi-line note was flattened to one line again)")
        XCTAssertTrue(text.contains("**等于在那个 shell 里打字**"), "the send-text warning must not be lost")
        XCTAssertTrue(text.contains("没有\"免确认\"档"), "mode's continuation line must not be lost")
        XCTAssertTrue(text.contains("control.sock"), "the section note, which says where the socket lands, must not be lost")
    }

    /// The contents of one section of a config file: the header down to just before the next one, with
    /// trailing blank lines dropped.
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
            // The autofill banner is not part of the template, so ignore it when comparing.
            guard inside, trimmed != ConfigStore.autofillBanner else { continue }
            out.append(line)
        }
        while out.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { out.removeLast() }
        return out
    }

    /// No file at all -> write the whole template; the template itself needs no filling in.
    func testFreshInstallWritesTemplate() throws {
        let fm = FileManager.default
        let fresh = fm.temporaryDirectory
            .appendingPathComponent("qt-cfgdir-\(UUID().uuidString.prefix(8))/config.toml")
        defer { try? fm.removeItem(at: fresh.deletingLastPathComponent()) }
        XCTAssertTrue(ConfigStore.ensureTemplateKeys(at: fresh))
        XCTAssertEqual(try String(contentsOf: fresh, encoding: .utf8), ConfigStore.template)
        XCTAssertFalse(ConfigStore.ensureTemplateKeys(at: fresh), "the template itself is missing no key")
    }

    /// Rewriting in place: a file in the new style has its new-style line changed, a file in the old style has
    /// its old-style line changed, and the user's file is never reordered.
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
            XCTAssertFalse(text.contains("# workspaces = 5"), "the original commented line has to be replaced: \(text)")
            XCTAssertEqual(ConfigStore.parse(text).workspaces, 7, "what comes out of a rewrite still has to parse back")
        }
        // The key is nowhere in the file -> insert it into the section it belongs to.
        let bare = try temporaryFile("theme = \"nord\"\n")
        defer { try? FileManager.default.removeItem(at: bare) }
        ConfigStore.configURLOverride = bare
        try ConfigStore.rewrite(key: "workspaces", value: "3")
        let text = try String(contentsOf: bare, encoding: .utf8)
        XCTAssertEqual(ConfigStore.parse(text).workspaces, 3)
        XCTAssertEqual(ConfigStore.parse(text).themeName, "nord", "nothing else may be touched")
        XCTAssertThrowsError(try ConfigStore.rewrite(key: "not-a-key", value: "1"))
    }
}
