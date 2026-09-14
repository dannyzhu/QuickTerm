import XCTest
@testable import QuickTerm

/// **`agents list`, and the agent record wherever else it shows up** (plan §2.9, §4.4).
///
/// `notices list` answers "is anybody being asked something right now". This surface answers the
/// question one step earlier — *is that pane busy at all, with what, and since when* — which is
/// what a second agent actually needs before it types into somebody else's workspace. So the
/// claims here are about scope (the answer has to match the target you wrote), about redaction
/// (the agent's own words follow the browser-URL rule through every door they can leave by), and
/// about absence (a session with no agents encodes exactly the bytes it always did).
///
/// Everything runs through `ControlHarness` against the **shared** registry and notification
/// centre wired to the test host's real screens, so a handle, a screen index and a workspace
/// number mean here what they mean in production.
@MainActor
final class ControlAgentsTests: XCTestCase {
    private var harness: ControlHarness!
    private var registry: AgentRegistry { AgentRegistry.shared }
    private var center: NoticeCenter { NoticeCenter.shared }
    private var savedRules: [AgentRules] = []
    private var savedSettings = AgentSettings()

    /// A rule file with one of everything the record can carry: a session id, a tool name, a
    /// summary that becomes the message, and the three states that matter to this surface.
    private static let ruleText = """
    id = "demo"
    name = "Demo Agent"
    process = ["demo"]

    [fields]
    session = "$.session_id"
    message = "$.message"
    tool    = "$.tool_name"
    error   = "$.error_type"
    summary = ["$.tool_input.command", "$.message"]

    [hooks]
    SessionStart      = "idle"
    PreToolUse        = "working:tool"
    PermissionRequest = "blocked:approval"
    Stop              = "done"
    SessionEnd        = "released"
    """

    override func setUpWithError() throws {
        try super.setUpWithError()
        harness = try ControlHarness()
        let locator = NoticeLocator(screens: harness.app.screens)
        center.attach(locator: locator)
        center.settings = NoticeSettings()
        center.resetForTesting()
        // `userRuleDirectory: nil` on purpose: a test that resolved `~` would read whatever rule
        // files this machine's owner happens to have written.
        registry.attach(locator: locator, userRuleDirectory: nil)
        savedRules = Array(registry.rules.values)
        savedSettings = registry.settings
        registry.reloadRulesForTesting([try AgentRules.parse(Self.ruleText)])
        registry.settings = AgentSettings()
        registry.settings.enabled = ["demo"]
        // The ask would reach for the real `~/.claude/settings.json`; nothing in this file is
        // about installing anything.
        registry.settings.autoInstallHooks = "never"
        registry.resetForTesting()
    }

    override func tearDown() {
        registry.resetForTesting()
        registry.reloadRulesForTesting(savedRules)
        registry.settings = savedSettings
        center.resetForTesting()
        harness?.cleanup()
        harness = nil
        super.tearDown()
    }

    // MARK: Helpers

    private func handle(_ pane: PaneView) -> String { ControlHandleRegistry.shared.handle(for: pane) }

    private func hook(_ event: String, tool: String? = nil, command: String? = nil,
                      session: String? = nil) -> PaneSignal {
        .hook(agent: "demo", payload: AgentEventPayload(
            hookEventName: event, sessionID: session, toolName: tool,
            toolInput: command.map { ["command": $0] }))
    }

    /// Put an agent into a pane and return the status the registry settled on.
    @discardableResult
    private func drive(_ pane: PaneView, _ signal: PaneSignal) -> AgentStatus? {
        registry.apply(signal, pane: pane.id).status
    }

    private func rows(_ reply: ControlReply) throws -> [[String: JSONValue]] {
        reply.assertOK()
        XCTAssertEqual(reply.data?["schema"]?.stringValue, "quickterm.agents/1")
        return try XCTUnwrap(reply.data?["agents"]?.arrayValue).compactMap(\.objectValue)
    }

    private func statePane(_ pane: PaneView, token: String? = nil) throws -> [String: JSONValue] {
        let reply = try harness.run("state", token: token)
        reply.assertOK()
        let panes = try XCTUnwrap(reply.data?["panes"]?.arrayValue).compactMap(\.objectValue)
        return try XCTUnwrap(panes.first { $0["handle"]?.stringValue == handle(pane) },
                             "the pane is not in state at all")
    }

    // MARK: The listing

    /// One row per pane that has an agent, carrying everything a caller branches on. A pane with
    /// no agent is **not listed**: "no agent here" is the absence of a row, never a row of nulls.
    func testListReportsOneRowPerPaneWithAnAgent() throws {
        let busy = try harness.newTerminal()
        let plain = try harness.newTerminal()
        drive(busy, hook("PreToolUse", tool: "Bash", command: "npm test", session: "s-1"))

        let listed = try rows(harness.run("agents.list", token: ControlEnvironment.token))
        XCTAssertEqual(listed.count, 1, "the pane with no agent contributes no row at all")
        let row = try XCTUnwrap(listed.first)
        XCTAssertEqual(row["pane"]?.stringValue, handle(busy))
        XCTAssertEqual(row["paneID"]?.stringValue, busy.id.uuidString)
        XCTAssertEqual(row["screen"]?.intValue, try harness.controller.screenIndex + 1)
        XCTAssertEqual(row["workspace"]?.intValue, try harness.controller.model.activeIndex + 1)
        XCTAssertNotEqual(row["pane"]?.stringValue, handle(plain))

        let agent = try XCTUnwrap(row["agent"]?.objectValue)
        XCTAssertEqual(agent["id"]?.stringValue, "demo")
        XCTAssertEqual(agent["name"]?.stringValue, "Demo Agent")
        XCTAssertEqual(agent["state"]?.stringValue, "working")
        XCTAssertEqual(agent["detail"]?.stringValue, "tool")
        XCTAssertEqual(agent["tool"]?.stringValue, "Bash")
        XCTAssertEqual(agent["evidence"]?.stringValue, "hook")
        XCTAssertEqual(agent["sessionID"]?.stringValue, "s-1")
        XCTAssertNotNil(agent["since"]?.stringValue)
        XCTAssertNil(agent["needsUser"], "a working agent is not somebody waiting; the field stays absent")

        // `needsUser` is the one boolean the whole surface exists for, and it appears only when
        // it is true.
        drive(busy, hook("PermissionRequest", tool: "Bash", command: "rm -rf build"))
        let blocked = try XCTUnwrap(try rows(harness.run("agents.list",
                                                         token: ControlEnvironment.token)).first)
        let waiting = try XCTUnwrap(blocked["agent"]?.objectValue)
        XCTAssertEqual(waiting["state"]?.stringValue, "blocked")
        XCTAssertEqual(waiting["detail"]?.stringValue, "approval")
        XCTAssertEqual(waiting["needsUser"]?.boolValue, true)
    }

    /// `-t` scopes at the precision it is written — a pane, a workspace, a screen — and no `-t`
    /// at all means the **whole session**, which is the reading "is any agent blocked anywhere"
    /// needs. Exactly the rule `notices list` follows.
    func testListScopesByTargetLikeNoticesList() throws {
        let controller = try harness.controller
        let home = controller.model.activeIndex
        let other = home == 0 ? 1 : 0

        let here = try harness.newTerminal(in: home)
        let there = try harness.newTerminal(in: other)
        controller.switchWorkspace(home)
        harness.spin(0.2)
        drive(here, hook("PreToolUse", tool: "Bash"))
        drive(there, hook("PermissionRequest", tool: "Edit"))

        let all = try rows(harness.run("agents.list"))
        XCTAssertEqual(Set(all.compactMap { $0["pane"]?.stringValue }),
                       [handle(here), handle(there)],
                       "no -t means the whole session, including workspaces nobody is looking at")

        let onePane = try rows(harness.run("agents.list", target: handle(there)))
        XCTAssertEqual(onePane.map { $0["pane"]?.stringValue }, [handle(there)])

        let screen = controller.screenIndex + 1
        let oneWorkspace = try rows(harness.run("agents.list", target: "\(screen):\(other + 1)"))
        XCTAssertEqual(oneWorkspace.map { $0["pane"]?.stringValue }, [handle(there)],
                       "-t 1:2 is a workspace, and the agent in the active workspace is not in it")

        let wholeScreen = try rows(harness.run("agents.list", target: "\(screen)"))
        XCTAssertEqual(Set(wholeScreen.compactMap { $0["pane"]?.stringValue }),
                       [handle(here), handle(there)],
                       "-t 1 is the screen; it must not silently narrow to that screen's active workspace")

        let empty = try rows(harness.run("agents.list", target: "\(screen):3"))
        XCTAssertEqual(empty.count, 0)
    }

    /// A row names where the pane **is**, not where its agent started: `pane move` is routine for
    /// the very agent arranging the work, and a row pointing at the old workspace sends the human
    /// to the wrong screen.
    func testRowsFollowAPaneThatMoved() throws {
        let controller = try harness.controller
        let home = controller.model.activeIndex
        let other = home == 0 ? 1 : 0
        let pane = try harness.newTerminal(in: home)
        controller.switchWorkspace(home)
        harness.spin(0.2)
        drive(pane, hook("PermissionRequest", tool: "Bash"))

        try harness.run("pane.move", target: handle(pane),
                        args: ["to": .string(":\(other + 1)")]).assertOK()
        harness.spin(0.3)

        let row = try XCTUnwrap(try rows(harness.run("agents.list")).first)
        XCTAssertEqual(row["workspace"]?.intValue, other + 1,
                       "the listing reports where the pane is now")
        let scoped = try rows(harness.run("agents.list",
                                          target: "\(controller.screenIndex + 1):\(other + 1)"))
        XCTAssertEqual(scoped.count, 1, "and -t finds it there")
    }

    // MARK: Redaction

    /// **The state is free, the message is not.** The agent id, the state, the detail and the
    /// tool *name* are composed vocabulary and stay readable for everyone — deciding whether to
    /// interrupt the user is precisely what a token-less caller needs them for. The message is
    /// the agent's own words (here, the command it wants to run) and follows the browser-URL rule
    /// through all three doors it can leave by.
    func testTheMessageIsRedactedWithoutTheTokenEverywhereItAppears() throws {
        let pane = try harness.newTerminal()
        let mark = harness.seq
        drive(pane, hook("PermissionRequest", tool: "Bash", command: "rm -rf build"))

        for token in [nil, ControlEnvironment.token] {
            let trusted = token != nil
            let row = try XCTUnwrap(try rows(harness.run("agents.list", token: token)).first)
            let agent = try XCTUnwrap(row["agent"]?.objectValue)
            XCTAssertEqual(agent["message"]?.stringValue,
                           trusted ? "rm -rf build" : ControlStateEncoder.redacted)
            XCTAssertEqual(agent["redacted"]?.boolValue, trusted ? nil : true,
                           "say so when something was withheld, or the caller believes the "
                               + "message really reads <redacted>")
            XCTAssertEqual(agent["tool"]?.stringValue, "Bash",
                           "a tool name is payload-free and is never redacted")
            XCTAssertEqual(agent["state"]?.stringValue, "blocked")

            let statePaneRecord = try statePane(pane, token: token)
            let stateAgent = try XCTUnwrap(statePaneRecord["agent"]?.objectValue)
            XCTAssertEqual(stateAgent["message"]?.stringValue,
                           trusted ? "rm -rf build" : ControlStateEncoder.redacted,
                           "state must not be a way around the rule agents list applies")
            XCTAssertEqual(stateAgent["needsUser"]?.boolValue, true)
        }

        // The event stream is the third door into the same text.
        let exposed = ControlEventBus.shared.batch(since: mark, limit: ControlEventLimits.maxBatch,
                                                   types: nil, exposesBrowser: true).events
        let hidden = ControlEventBus.shared.batch(since: mark, limit: ControlEventLimits.maxBatch,
                                                  types: nil, exposesBrowser: false).events
        let open = try XCTUnwrap(exposed.last { $0.type == ControlEventType.agentStateChanged.rawValue })
        XCTAssertEqual(open.message, "rm -rf build")
        XCTAssertEqual(open.agent, "demo")
        XCTAssertEqual(open.state, "blocked")
        XCTAssertEqual(open.detail, "approval")
        XCTAssertEqual(open.tool, "Bash")
        let shut = try XCTUnwrap(hidden.last { $0.type == ControlEventType.agentStateChanged.rawValue })
        XCTAssertEqual(shut.message, ControlEvent.redactedPlaceholder)
        XCTAssertEqual(shut.state, "blocked", "redaction covers the message and nothing else")
        XCTAssertEqual(shut.tool, "Bash")
    }

    // MARK: Absence

    /// A pane with no agent carries no `agent` field at all, so every fixture, diff and jq
    /// pipeline written before Phase 2 sees exactly the bytes it saw before.
    func testStateCarriesAnAgentOnlyWhenThereIsOne() throws {
        let pane = try harness.newTerminal()
        let before = try harness.run("state", token: ControlEnvironment.token)
        before.assertOK()
        XCTAssertNil(try statePane(pane, token: ControlEnvironment.token)["agent"])
        let bytes = String(decoding: try ControlJSON.encoder.encode(XCTUnwrap(before.data)), as: UTF8.self)
        XCTAssertFalse(bytes.contains("\"agent\""),
                       "a session with no agents must encode byte for byte what it always did")

        drive(pane, hook("SessionStart", session: "s-9"))
        let after = try XCTUnwrap(try statePane(pane, token: ControlEnvironment.token)["agent"]?.objectValue)
        XCTAssertEqual(after["state"]?.stringValue, "idle")
        XCTAssertEqual(after["id"]?.stringValue, "demo")
        XCTAssertNil(after["tool"], "an absent value is absent, never an empty string")
        XCTAssertNil(after["detail"])

        // And it goes away again when the agent does.
        drive(pane, hook("SessionEnd"))
        XCTAssertNil(try statePane(pane, token: ControlEnvironment.token)["agent"])
        XCTAssertEqual(try rows(harness.run("agents.list")).count, 0)
    }

    // MARK: The generated surface

    /// Every command in the table is either exposed through a tool or explicitly excluded, and
    /// every one with a sample has a sample that parses — both are pinned globally, so what is
    /// asserted here is the part specific to this group: `describe` really does hand an agent the
    /// new class, error code, event type and tool, which is the only way it learns they exist.
    func testDescribeCarriesTheNewClassCodeEventAndTool() throws {
        let reply = try harness.run("describe")
        reply.assertOK()
        let document = try XCTUnwrap(reply.data?.objectValue)

        let classes = (document["classes"]?.arrayValue ?? []).compactMap { $0["name"]?.stringValue }
        XCTAssertTrue(classes.contains(ControlCommandClass.report.rawValue),
                      "an agent that does not know `report` exists cannot tell why agent-event is "
                          + "never refused for a reason that applies to a mutation")

        let codes = (document["errorCodes"]?.arrayValue ?? []).compactMap { $0["code"]?.stringValue }
        XCTAssertTrue(codes.contains(ControlErrorCode.originMismatch.rawValue))

        let events = (document["events"]?.arrayValue ?? []).compactMap { $0["type"]?.stringValue }
        XCTAssertTrue(events.contains(ControlEventType.agentStateChanged.rawValue))

        let tools = (document["mcpTools"]?.arrayValue ?? []).compactMap(\.objectValue)
        let agents = try XCTUnwrap(tools.first { $0["name"]?.stringValue == "quickterm_agents" },
                                   "the MCP tool table is generated from the command table")
        XCTAssertEqual(agents["readOnlyHint"]?.boolValue, true,
                       "both commands behind it are reads; a host must be free to auto-allow it")
        XCTAssertEqual(agents["destructiveHint"]?.boolValue, false)
        XCTAssertEqual(Set((agents["commands"]?.arrayValue ?? []).compactMap(\.stringValue)),
                       ["agents list", "hooks status"])

        // The two new read commands both ship an output sample, because a sample is how an agent
        // learns the shape without making a call.
        for name in ["agents.list", "hooks.status"] {
            let spec = try XCTUnwrap(ControlCommandTable.command(name))
            let sample = try XCTUnwrap(spec.outputSample, "\(name) has no output sample")
            XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(sample.utf8)))
        }
        XCTAssertEqual(ControlCommandTable.command("agents.list")?.cls, .read)
        XCTAssertEqual(ControlCommandTable.command("agents.list")?.acceptsTarget, true)
    }
}
