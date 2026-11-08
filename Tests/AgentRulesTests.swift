import XCTest
@testable import QuickTerm

/// The rule-file grammar and schema (plan §2.3).
///
/// Two things are being pinned here and they matter for different reasons. The **grammar** is
/// narrow on purpose — a rule file is data, and a parser that accepted expressions would be a
/// place for behaviour to hide outside Swift. The **schema** rejects rather than ignores: a
/// mistyped event name that loaded quietly would disable exactly the hook whose line was
/// mistyped, and nobody would find out until an approval prompt went unreported.
final class AgentRulesTests: XCTestCase {
    /// A complete, valid file. Individual cases mutate one line of it, so every red case differs
    /// from a green one by exactly the thing it is testing.
    private static let sample = """
    # a comment
    id = "demo"
    name = "Demo Agent"
    process = ["demo", "demo-cli"]
    process-path = ["/.local/share/demo/versions/"]

    [fields]
    session = "$.session_id"
    message = "$.message"
    tool    = "$.tool_name"
    error   = "$.error_type"
    summary = ["$.tool_input.command", "$.message"]

    [hooks]
    SessionStart = "idle"
    PreToolUse   = "working:tool"
    Stop         = "done"
    SessionEnd   = "released"

    [hooks.Notification]
    field = "$.notification_type"

    [hooks.Notification.values]
    permission_prompt = "blocked:approval"

    [notifications]
    "Demo needs your permission" = "blocked:approval"
    "Demo finished"              = "done"

    [install]
    shape     = "claude"
    config    = "~/.demo/settings.json"
    lifecycle = ["SessionStart", "SessionEnd", "Stop", "Notification"]
    tools     = ["PreToolUse"]
    """

    private func rules(_ text: String = sample, file: StaticString = #filePath,
                       line: UInt = #line) throws -> AgentRules {
        try XCTUnwrap(try? AgentRules.parse(text), "the file should have parsed", file: file, line: line)
    }

    /// Every accepted form of the grammar, in one file, read back field by field.
    func testEveryAcceptedFormParses() throws {
        let rules = try self.rules()
        XCTAssertEqual(rules.id, "demo")
        XCTAssertEqual(rules.name, "Demo Agent")
        XCTAssertEqual(rules.process, ["demo", "demo-cli"])
        XCTAssertEqual(rules.processPath, ["/.local/share/demo/versions/"])
        XCTAssertEqual(rules.fields.summary,
                       [AgentFieldPath(head: "tool_input", sub: "command"),
                        AgentFieldPath(head: "message", sub: nil)])
        XCTAssertEqual(rules.hooks["SessionStart"], .plain(.state(.idle, nil)))
        XCTAssertEqual(rules.hooks["SessionEnd"], .plain(.released))
        guard case .keyed(let field, let values) = rules.hooks["Notification"] else {
            return XCTFail("a keyed event has to parse as one")
        }
        XCTAssertEqual(field, AgentFieldPath(head: "notification_type", sub: nil))
        XCTAssertEqual(values["permission_prompt"], .state(.blocked, .approval))
        // File order is data: `[notifications]` matches by prefix and the first match wins.
        XCTAssertEqual(rules.notifications.map(\.prefix),
                       ["Demo needs your permission", "Demo finished"])
        XCTAssertEqual(rules.install?.shape, .claude)
        XCTAssertEqual(rules.install?.events(detail: "lifecycle"),
                       ["SessionStart", "SessionEnd", "Stop", "Notification"])
        XCTAssertEqual(rules.install?.events(detail: "tools").last, "PreToolUse")
    }

    /// Escapes, a `#` inside a string, and an empty list — the corners of the scanner.
    func testScannerCorners() throws {
        let document = try AgentRulesTOML.parse("""
        id = "x"
        name = "A \\"quoted\\" name"   # a trailing comment
        process = []

        [notifications]
        "Build #1 finished" = "done"
        """)
        XCTAssertEqual(document.root("name")?.stringValue, "A \"quoted\" name")
        XCTAssertEqual(document.root("process")?.listValue, [])
        XCTAssertEqual(document.table("notifications")?.entries.first?.key, "Build #1 finished")
    }

    /// Each rejected form, with the line it is on. A file is rejected **whole**.
    func testRejectedFormsNameTheirLine() {
        let cases: [(String, Int)] = [
            ("id = \"x\"\nname = \"unterminated", 2),
            ("id = \"x\"\nname = bare", 2),
            ("id = \"x\"\n[a.b.c.d]\nk = \"v\"", 2),
            ("id = \"x\"\n[bad space]\nk = \"v\"", 2),
            ("id = \"x\"\nname = \"a\" trailing", 2),
            ("id = \"x\"\nname = [\"a\", bare]", 2),
            ("id = \"x\"\nname = \"a\"\nname = \"b\"", 3),
            ("id = \"x\"\nname = \"a\\q\"", 2),
        ]
        for (text, line) in cases {
            do {
                _ = try AgentRulesTOML.parse(text)
                XCTFail("this should not have parsed: \(text.replacingOccurrences(of: "\n", with: " ⏎ "))")
            } catch let error as AgentRulesError {
                guard case .syntax(let reported, _) = error else {
                    return XCTFail("expected a syntax error for \(text), got \(error)")
                }
                XCTAssertEqual(reported, line, "wrong line reported for \(text)")
            } catch {
                XCTFail("unexpected error \(error)")
            }
        }
    }

    /// Every load-time rule in the schema has a red case. All of them are **rejections**: a rule
    /// file that silently ignored what it did not understand would disable hooks invisibly.
    func testSchemaRejections() {
        func reject(_ replace: (String, String), _ why: String,
                    file: StaticString = #filePath, line: UInt = #line) {
            let text = Self.sample.replacingOccurrences(of: replace.0, with: replace.1)
            XCTAssertThrowsError(try AgentRules.parse(text), why, file: file, line: line)
        }
        reject(("summary = [\"$.tool_input.command\", \"$.message\"]",
                "summary = [\"$.transcript_path\"]"),
               "a path outside the whitelist has to fail at load, not read empty for ever")
        reject(("session = \"$.session_id\"", "session = \"$.message.text\""),
               "only tool_input / details have sub-keys")
        reject(("session = \"$.session_id\"", "session = \"session_id\""),
               "a field path starts with $.")
        reject(("SessionStart = \"idle\"", "SessionStart = \"idle:approval\""),
               "a state that may not carry a detail")
        reject(("PreToolUse   = \"working:tool\"", "PreToolUse   = \"working\""),
               "working without a detail is not a state anything can draw")
        reject(("PreToolUse   = \"working:tool\"", "PreToolUse   = \"working:approval\""),
               "a detail that belongs to another state")
        reject(("name = \"Demo Agent\"", "nickname = \"Demo Agent\""),
               "an unknown top-level key is a typo, not an extension point")
        reject(("[fields]", "[field]"), "an unknown table")
        reject(("session = \"$.session_id\"", "sesion = \"$.session_id\""),
               "an unknown key inside [fields]")
        reject(("lifecycle = [\"SessionStart\", \"SessionEnd\", \"Stop\", \"Notification\"]",
                "lifecycle = [\"SessionStart\", \"Ghost\"]"),
               "an event the installer writes but no rule maps")
        reject(("shape     = \"claude\"", "shape     = \"vscode\""), "an unknown shape")
        reject(("id = \"demo\"", "id = \"Demo\""), "an id is lowercase")
    }

    /// A `[hooks.<Event>]` with no `values` table, and a `values` table with no event.
    func testKeyedEventHalvesMustBothBeThere() {
        let noValues = Self.sample.replacingOccurrences(
            of: "[hooks.Notification.values]\npermission_prompt = \"blocked:approval\"", with: "")
        XCTAssertThrowsError(try AgentRules.parse(noValues))
        let noEvent = Self.sample.replacingOccurrences(
            of: "[hooks.Notification]\nfield = \"$.notification_type\"", with: "")
        XCTAssertThrowsError(try AgentRules.parse(noEvent))
    }

    // MARK: [resume]

    /// The optional `[resume]` table: two argument arrays, one with the `{session}` slot.
    private static let resumeTable = """

    [resume]
    session = ["demo", "--resume", "{session}"]
    latest  = ["demo", "--continue"]
    """

    func testRuleFileResumeTableParses() throws {
        let rules = try self.rules(Self.sample + Self.resumeTable)
        XCTAssertEqual(rules.resume?.session, ["demo", "--resume", "{session}"])
        XCTAssertEqual(rules.resume?.latest, ["demo", "--continue"])
        XCTAssertNil(try self.rules().resume, "a file without [resume] offers no resume")
        let latestOnly = try self.rules(Self.sample + "\n[resume]\nlatest = [\"demo\", \"--continue\"]")
        XCTAssertNil(latestOnly.resume?.session)
        XCTAssertEqual(latestOnly.resume?.latest, ["demo", "--continue"])

        // The bundled files carry spec decision 14's arrays; Gemini has none.
        let byID = Dictionary(uniqueKeysWithValues: AgentRulesLoader.load(userDirectory: nil).rules.map { ($0.id, $0) })
        XCTAssertEqual(byID["claude-code"]?.resume?.session, ["claude", "--resume", "{session}"])
        XCTAssertEqual(byID["claude-code"]?.resume?.latest, ["claude", "--continue"])
        XCTAssertEqual(byID["codex"]?.resume?.session, ["codex", "resume", "{session}"])
        XCTAssertEqual(byID["codex"]?.resume?.latest, ["codex", "resume", "--last"])
        XCTAssertNotNil(byID["gemini"])
        XCTAssertNil(byID["gemini"]?.resume)
        XCTAssertEqual(byID["kiro-cli"]?.resume?.session, ["kiro-cli", "chat", "--resume-id", "{session}"])
        XCTAssertEqual(byID["kiro-cli"]?.resume?.latest, ["kiro-cli", "chat", "--resume"])
    }

    /// Every way a `[resume]` table can be wrong is a rejection of the whole file.
    func testResumeSessionFormNeedsThePlaceholder() {
        func reject(_ table: String, _ why: String, file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertThrowsError(try AgentRules.parse(Self.sample + "\n[resume]\n" + table), why,
                                 file: file, line: line)
        }
        reject(#"session = ["demo", "--resume"]"#, "the session form without its slot")
        reject(#"session = ["demo", "{session}", "{session}"]"#, "the slot twice")
        reject(#"session = ["demo", "--id={session}"]"#, "the slot is a whole argument, never part of one")
        reject(#"session = ["{session}"]"#, "the session id is never the command")
        reject(#"latest = ["demo", "{session}"]"#, "latest has no session to put anywhere")
        reject(#"latest = []"#, "an empty command")
        reject(#"latest = "demo --continue""#, "a string would be one word: the form is an array")
        reject(#"resume = ["demo"]"#, "an unknown key inside [resume]")
        // The scanner turns `\n` into a newline; the [resume] check is what rejects it.
        XCTAssertThrowsError(try AgentRules.parse(
            Self.sample + "\n[resume]\nsession = [\"claude\", \"--resume\\n\", \"{session}\"]"),
                             "a newline would submit the typed line early") { error in
            guard case .invalid(let key, _) = error as? AgentRulesError else {
                return XCTFail("expected the [resume] check to reject it, got \(error)")
            }
            XCTAssertEqual(key, "[resume] session")
        }
        reject("latest = [\"demo\", \"--a\u{1B}\"]", "ESC is an editing key in a shell")
        reject("latest = [\"demo\", \"x\u{7F}\"]", "DEL too")
        XCTAssertThrowsError(try AgentRules.parse(Self.sample + "\n[resume.extra]\nk = \"v\""),
                             "[resume] has no sub-tables")
    }

    // MARK: The bundled files

    /// **All four bundled rule files load**, and everything their installers name is mapped.
    /// A rule file that is not in the Xcode project is not in the bundle at all, which this is
    /// also the guard against.
    func testBundledRuleFilesLoad() throws {
        let result = AgentRulesLoader.load(userDirectory: nil)
        XCTAssertEqual(result.failures.count, 0,
                       "a bundled rule file failed to load: \(result.failures)")
        XCTAssertEqual(result.rules.map(\.id), ["claude-code", "codex", "gemini", "kiro-cli"])
        for rules in result.rules {
            XCTAssertFalse(rules.name.isEmpty)
            XCTAssertFalse(rules.process.isEmpty, "\(rules.id) names no process")
            let install = try XCTUnwrap(rules.install, "\(rules.id) has no installer")
            for event in install.lifecycle + install.tools {
                XCTAssertNotNil(rules.hooks[event], "\(rules.id) installs \(event) without mapping it")
            }
        }
        // Q5: the OSC fallback ships for Claude Code only; the other two stay empty until their
        // wording is recorded from a real session.
        let byID = Dictionary(uniqueKeysWithValues: result.rules.map { ($0.id, $0) })
        XCTAssertFalse(byID["claude-code"]?.notifications.isEmpty ?? true)
        XCTAssertTrue(byID["codex"]?.notifications.isEmpty ?? false)
        XCTAssertTrue(byID["gemini"]?.notifications.isEmpty ?? false)
        XCTAssertTrue(byID["kiro-cli"]?.notifications.isEmpty ?? false)
        // The native install is a symlink whose target's file name is a version number: without
        // this fragment the scan never sees Claude Code at all (2026-09-26).
        XCTAssertEqual(byID["claude-code"]?.processPath, ["/.local/share/claude/versions/"])
    }

    /// kiro-cli (spec decisions 14, 22): its V3 triggers, a standalone hook file, the chat
    /// process for presence, and both resume forms. No prompt text is read (`message` unset).
    func testKiroRuleFileLoads() throws {
        let result = AgentRulesLoader.load(userDirectory: nil)
        let kiro = try XCTUnwrap(result.rules.first { $0.id == "kiro-cli" }, "\(result.failures)")
        XCTAssertEqual(kiro.name, "Kiro CLI")
        XCTAssertEqual(kiro.process, ["kiro-cli"])
        XCTAssertEqual(kiro.processPath, ["/Library/Application Support/kiro-cli/"])
        XCTAssertEqual(kiro.fields.session, [AgentFieldPath(head: "session_id", sub: nil)])
        XCTAssertEqual(kiro.fields.tool, [AgentFieldPath(head: "tool_name", sub: nil)])
        XCTAssertEqual(kiro.fields.summary, [AgentFieldPath(head: "tool_input", sub: "command")])
        XCTAssertTrue(kiro.fields.message.isEmpty, "kiro sends no message; a prompt is the user's text")
        XCTAssertTrue(kiro.fields.error.isEmpty)
        XCTAssertEqual(kiro.hooks, [
            "SessionStart": .plain(.state(.idle, nil)),
            "UserPromptSubmit": .plain(.state(.working, .thinking)),
            "PreToolUse": .plain(.state(.working, .tool)),
            "PostToolUse": .plain(.state(.working, .thinking)),
            "Stop": .plain(.state(.done, nil)),
            "SessionEnd": .plain(.released),
        ])
        let install = try XCTUnwrap(kiro.install)
        XCTAssertEqual(install.shape, .kiro)
        XCTAssertEqual(install.config, "~/.kiro/hooks/quickterm-agent-state.json")
        XCTAssertEqual(install.lifecycle, ["SessionStart", "SessionEnd", "UserPromptSubmit", "Stop"])
        XCTAssertEqual(install.tools, ["PreToolUse", "PostToolUse"])
        XCTAssertEqual(kiro.resume?.session, ["kiro-cli", "chat", "--resume-id", "{session}"])
        XCTAssertEqual(kiro.resume?.latest, ["kiro-cli", "chat", "--resume"])
    }

    /// A user file replaces a bundled one **whole** when the id matches, and adds an agent when
    /// it does not. A bad file is skipped, and takes nothing else down with it.
    func testUserFilesOverrideByIDAndAddByID() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("qt-agents-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        try """
        id = "claude-code"
        name = "My Claude"
        process = ["claude"]

        [hooks]
        SessionStart = "idle"
        """.write(to: directory.appendingPathComponent("claude-code.toml"),
                  atomically: true, encoding: .utf8)
        try """
        id = "mine"
        name = "Mine"
        process = ["mine"]

        [hooks]
        SessionStart = "idle"
        """.write(to: directory.appendingPathComponent("mine.toml"), atomically: true, encoding: .utf8)
        try "id = \"broken\"\nname = ".write(to: directory.appendingPathComponent("broken.toml"),
                                             atomically: true, encoding: .utf8)

        let result = AgentRulesLoader.load(userDirectory: directory)
        let byID = Dictionary(uniqueKeysWithValues: result.rules.map { ($0.id, $0) })
        XCTAssertEqual(byID["claude-code"]?.name, "My Claude")
        XCTAssertNil(byID["claude-code"]?.install,
                     "a user override replaces the bundled file whole, installer included")
        XCTAssertEqual(byID["mine"]?.name, "Mine")
        XCTAssertNotNil(byID["codex"], "one bad file must not take the others down")
        XCTAssertEqual(result.failures.count, 1)
    }

    /// The file name is part of the identity: `mine.toml` declaring `id = "yours"` is a mistake
    /// somebody would otherwise chase for an hour.
    func testFileNameAndIDHaveToAgree() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("qt-agents-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try """
        id = "yours"
        name = "Yours"

        [hooks]
        SessionStart = "idle"
        """.write(to: directory.appendingPathComponent("mine.toml"), atomically: true, encoding: .utf8)

        let result = AgentRulesLoader.load(userDirectory: directory)
        XCTAssertNil(result.rules.first { $0.id == "yours" })
        XCTAssertEqual(result.failures.count, 1)
    }
}
