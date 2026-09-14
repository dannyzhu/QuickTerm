import XCTest
@testable import QuickTerm

/// **The whitelist** (plan §2.2): what an agent's hook JSON is reduced to before a single byte of
/// it reaches QuickTerm, and what is thrown away and cannot be reconstructed later.
///
/// The reduction runs twice — the CLI applies it to stdin, the server applies it again to whatever
/// arrives — so these cases pin both overloads against the same rules, and against the recorded
/// payload fixtures the rule files are written for.
final class AgentEventPayloadTests: XCTestCase {

    // MARK: The cap

    /// Stdin is **cut** at the cap, never waited for, and a JSON object cut mid-string is not a
    /// JSON object any more — so a runaway `Write` of a megabyte file becomes a dropped event
    /// rather than a megabyte of somebody's source code inside QuickTerm.
    func testReduceStopsAtTheStdinCap() throws {
        let huge = String(repeating: "a", count: 1_000_000)
        let raw = Data(#"{"hook_event_name":"PreToolUse","tool_input":{"content":"\#(huge)"}}"#.utf8)
        XCTAssertGreaterThan(raw.count, AgentEventPayload.maxStdinBytes)
        XCTAssertNil(AgentEventPayload.reduce(raw),
                     "a payload cut at the cap no longer parses, and an event we cannot name is dropped")
    }

    /// The cap is a cut, not a refusal: a payload that *fits* is reduced normally, and a long
    /// field inside it is clamped rather than dropping the whole event.
    func testAPayloadUnderTheCapIsClampedFieldByField() throws {
        let long = String(repeating: "x", count: 5000)
        let raw = Data(#"{"hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"content":"\#(long)"}}"#.utf8)
        XCTAssertLessThanOrEqual(raw.count, AgentEventPayload.maxStdinBytes)
        let payload = try XCTUnwrap(AgentEventPayload.reduce(raw))
        XCTAssertEqual(payload.toolInput?["content"]?.count, AgentEventPayload.maxFieldLength)
    }

    // MARK: What never crosses

    /// The two fields the whole whitelist exists for: a path to the entire conversation, and the
    /// directory the user is working in. Neither is a property of `AgentEventPayload` at all, so
    /// there is nowhere for them to survive — this case is the regression guard for somebody
    /// adding a convenient `[String: String]` passthrough later.
    func testTranscriptPathAndCwdNeverSurvive() throws {
        let raw = Data("""
        {"hook_event_name":"PreToolUse","transcript_path":"/Users/danny/.claude/x.jsonl",
         "cwd":"/Users/danny/secret-project","tool_name":"Bash",
         "tool_input":{"command":"ls"}}
        """.utf8)
        let payload = try XCTUnwrap(AgentEventPayload.reduce(raw))
        let json = String(decoding: try ControlJSON.encoder.encode(payload), as: UTF8.self)
        XCTAssertFalse(json.contains("transcript"))
        XCTAssertFalse(json.contains("secret-project"))
        XCTAssertEqual(payload.toolInput, ["command": "ls"])
    }

    /// Inside `tool_input` / `details` only **string-valued top-level keys** survive: a number, an
    /// array or a nested object is dropped whole, which is what keeps a tool result (or a file
    /// body hiding one level down) out.
    func testOnlyStringSubValuesSurvive() throws {
        let raw = Data("""
        {"hook_event_name":"PostToolUse","tool_input":{"command":"ls","timeout":120000,
         "files":["a","b"],"nested":{"body":"whole file"},"nothing":null,"ok":"yes"}}
        """.utf8)
        let payload = try XCTUnwrap(AgentEventPayload.reduce(raw))
        XCTAssertEqual(payload.toolInput, ["command": "ls", "ok": "yes"])
    }

    /// At most `maxObjectKeys` keys, taken in sorted order (`JSONSerialization` hands back an
    /// unordered dictionary, so sorted is the only answer that is the same on every run).
    func testAtMostEightKeysSurviveInSortedOrder() throws {
        let pairs = (0..<20).map { "\"k\(String(format: "%02d", $0))\":\"v\($0)\"" }.joined(separator: ",")
        let raw = Data(#"{"hook_event_name":"PreToolUse","tool_input":{\#(pairs)}}"#.utf8)
        let payload = try XCTUnwrap(AgentEventPayload.reduce(raw))
        XCTAssertEqual(payload.toolInput?.count, AgentEventPayload.maxObjectKeys)
        XCTAssertEqual(payload.toolInput?.keys.sorted(),
                       (0..<AgentEventPayload.maxObjectKeys).map { "k\(String(format: "%02d", $0))" })
    }

    /// A bare string where an object was expected (some agents send `details: "…"`) becomes one
    /// `text` key rather than being dropped: it is the only thing the event carries.
    func testAStringObjectBecomesOneTextKey() throws {
        let raw = Data(#"{"hook_event_name":"Notification","details":"may I run rm?"}"#.utf8)
        let payload = try XCTUnwrap(AgentEventPayload.reduce(raw))
        XCTAssertEqual(payload.details, ["text": "may I run rm?"])
    }

    // MARK: Dropped outright

    /// Four ways to say nothing, one answer: drop it. The hook script exits 0 either way, so a
    /// dropped event costs nothing and a *guessed* one would cost the user a wrong alarm.
    func testBytesThatAreNotAHookPayloadAreDropped() {
        XCTAssertNil(AgentEventPayload.reduce(Data("not json".utf8)))
        XCTAssertNil(AgentEventPayload.reduce(Data("[1,2,3]".utf8)))
        XCTAssertNil(AgentEventPayload.reduce(Data()))
        XCTAssertNil(AgentEventPayload.reduce(Data(#"{"tool_name":"Bash"}"#.utf8)),
                     "an event that does not say which event it is cannot be mapped by any rule file")
        XCTAssertNil(AgentEventPayload.reduce(Data(#"{"hook_event_name":"   "}"#.utf8)))
    }

    // MARK: The server's second pass

    /// The re-reduction is what makes a hand-built `--event` no more powerful than a real hook:
    /// the same clamps, applied to an already-decoded payload.
    func testTheSecondPassClampsAHandBuiltPayload() throws {
        let payload = AgentEventPayload(
            hookEventName: "PreToolUse",
            toolName: String(repeating: "T", count: 400),
            message: "line one\nline two",
            toolInput: ["command": String(repeating: "c", count: 900)])
        let reduced = try XCTUnwrap(AgentEventPayload.reduce(payload))
        XCTAssertEqual(reduced.toolName?.count, AgentEventPayload.maxFieldLength)
        XCTAssertEqual(reduced.toolInput?["command"]?.count, AgentEventPayload.maxFieldLength)
        XCTAssertFalse(try XCTUnwrap(reduced.message).contains("\n"),
                       "a control character never reaches a notice title or an info strip")
        XCTAssertNil(AgentEventPayload.reduce(AgentEventPayload(hookEventName: " ")))
    }

    // MARK: Field paths (the rule files' vocabulary)

    /// Every path a rule file may name resolves, and nothing else does. The lists live beside the
    /// fields themselves precisely so that a field added to the whitelist and a field a rule file
    /// can read cannot drift apart.
    func testEveryDeclaredPathResolves() throws {
        let payload = AgentEventPayload(
            hookEventName: "Notification", notificationType: "permission_prompt", sessionID: "s1",
            toolName: "Bash", errorType: "api_error", message: "hello",
            toolInput: ["command": "ls"], details: ["command": "npm test"])
        XCTAssertEqual(AgentEventPayload.scalarPaths.compactMap { payload.value($0) },
                       ["Notification", "permission_prompt", "s1", "Bash", "api_error", "hello"])
        XCTAssertEqual(payload.value("tool_input", "command"), "ls")
        XCTAssertEqual(payload.value("details", "command"), "npm test")
        XCTAssertNil(payload.value("transcript_path"))
        XCTAssertNil(payload.value("tool_input", "content"))
        XCTAssertNil(payload.value("message", "text"), "a scalar field has no sub-keys")
    }

    // MARK: The fixtures

    /// Every recorded payload reduces to something a rule file can map, and none of them carries
    /// a field that is not on the whitelist. The fixtures are the input to
    /// `ControlAgentEventTests.testEveryFixtureLandsOnTheStateItsRuleFileSays`; this is the case
    /// that fails first if one of them is edited into something the whitelist would drop.
    func testEveryFixtureReducesToTheWhitelist() throws {
        for (agent, event) in AgentPayloadFixtures.all {
            let raw = try AgentPayloadFixtures.data(agent, event)
            let payload = try XCTUnwrap(AgentEventPayload.reduce(raw), "\(agent)/\(event)")
            XCTAssertEqual(payload.hookEventName, event, "\(agent)/\(event)")
            let object = try XCTUnwrap(
                try JSONSerialization.jsonObject(with: ControlJSON.encoder.encode(payload)) as? [String: Any])
            XCTAssertTrue(Set(object.keys).isSubset(of: AgentPayloadFixtures.wireKeys),
                          "\(agent)/\(event) kept \(Set(object.keys).subtracting(AgentPayloadFixtures.wireKeys))")
            let raws = try XCTUnwrap(try JSONSerialization.jsonObject(with: raw) as? [String: Any])
            for dropped in ["transcript_path", "cwd", "workspace_dir", "prompt", "tool_response",
                            "tool_output", "result", "permission_suggestions"] where raws[dropped] != nil {
                XCTAssertNil(object[dropped], "\(agent)/\(event) let \(dropped) through")
            }
        }
    }
}

/// The recorded hook payloads, and where they live.
///
/// **Hand-written from the agents' documented hook schemas**, not recorded from a real session:
/// replay proves everything that happens after a hook reaches our socket and nothing about the
/// agents themselves (plan §4.6). Replace a file here with a real recording the moment a session
/// is available — the mapping table in `ControlAgentEventTests` is what tells you whether the
/// rule file still agrees with it.
///
/// They are copied into the test bundle as a **folder reference** (`project.yml`), because three
/// agents share the file name `PreToolUse.json` and a flat resource phase would collapse them —
/// and because the test host cannot read the source tree (ad-hoc signed, repo under ~/Documents).
enum AgentPayloadFixtures {
    static let claudeCode = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse",
                             "PermissionRequest", "Notification", "Stop", "StopFailure", "SessionEnd"]
    static let codex = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse",
                        "PermissionRequest", "Stop", "Interrupt", "SessionEnd"]
    static let gemini = ["SessionStart", "BeforeAgent", "AfterAgent", "BeforeTool", "AfterTool",
                         "Notification", "SessionEnd"]

    static var all: [(String, String)] {
        claudeCode.map { ("claude-code", $0) } + codex.map { ("codex", $0) }
            + gemini.map { ("gemini", $0) }
    }

    /// The eight keys `AgentEventPayload` encodes — the whitelist, by its wire spelling.
    static let wireKeys: Set<String> = ["hook_event_name", "notification_type", "session_id",
                                        "tool_name", "error_type", "message", "tool_input", "details"]

    /// The bundled copy first; the source tree only as a fallback for a checkout whose bundle was
    /// built before the fixtures existed.
    static func data(_ agent: String, _ event: String) throws -> Data {
        let bundled = Bundle(for: AgentEventPayloadTests.self).resourceURL?
            .appendingPathComponent("Fixtures/agent-payloads/\(agent)/\(event).json")
        if let bundled, FileManager.default.fileExists(atPath: bundled.path) {
            return try Data(contentsOf: bundled)
        }
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/agent-payloads/\(agent)/\(event).json")
        return try Data(contentsOf: source)
    }
}
