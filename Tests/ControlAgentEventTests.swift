import Darwin
import XCTest
@testable import QuickTerm

/// **`agent-event`: the hook's road in** (plan §2.2, §2.1), driven through the real runner.
///
/// Three separate promises are under test here, and they pull in different directions:
///
/// - **A report is never refused for a mutation's reasons.** The hook exits 0 by design and never
///   retries, so an approval prompt that arrives while a dialog is up, or while the control plane
///   is read-only, is lost for good if the gates in front of mutations apply to it.
/// - **A report proves its pane before it is believed.** `QUICKTERM_PANE` is self-reported;
///   `QUICKTERM_PANE_TOKEN` and the peer's process lineage are not, and both are checked before a
///   byte of payload is parsed.
/// - **A forger may add a notice; it may never remove one.** Every resolution carries the lineage
///   and session that posted the alarm, and a mismatch is `origin_mismatch`, logged, with the
///   alarm left standing.
///
/// The lineage cases spawn **real child processes** of the test host: `ControlLineage.root(of:)`
/// walks `pbi_ppid`, so the only honest way to have two different lineages is to have two
/// different children. Nothing here ever reaches the developer's own QuickTerm — the runner is
/// driven directly, with no socket at all.
@MainActor
final class ControlAgentEventTests: XCTestCase {
    private var harness: ControlHarness!
    private var pane: PaneView!
    private var center: NoticeCenter { NoticeCenter.shared }
    private var registry: AgentRegistry { AgentRegistry.shared }
    private var children: [Process] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        harness = try ControlHarness()
        center.attach(locator: NoticeLocator(screens: harness.app.screens))
        if center.sink(id: NoticeSinkID.controlPlane) == nil { center.addSink(ControlPlaneSink()) }
        if center.sink(id: NoticeSinkID.activityLog) == nil { center.addSink(ActivityLogSink()) }
        center.settings = NoticeSettings()
        center.resetForTesting()
        // The registry is the shared one the runner reaches for. Attach it to the test host's real
        // screens with **no user rule directory**: a test must never read the developer's own
        // ~/.config/quickterm/agents, and the three bundled rule files are what the fixtures are
        // written against.
        registry.attach(locator: NoticeLocator(screens: harness.app.screens), userRuleDirectory: nil)
        if registry.rules["claude-code"] == nil {
            registry.reloadRulesForTesting(AgentRulesLoader.load(userDirectory: nil).rules)
        }
        registry.settings = AgentSettings()
        registry.resetForTesting()
        harness.runner.rateLimiter.reset()
        ControlActivityLog.shared.clear()
        pane = try harness.newTerminal()
    }

    override func tearDown() {
        for child in children where child.isRunning { child.terminate() }
        children.removeAll()
        center.resetForTesting()
        registry.resetForTesting()
        harness?.cleanup()
        harness = nil
        super.tearDown()
    }

    // MARK: Helpers

    private var handle: String { ControlHandleRegistry.shared.handle(for: pane) }

    /// A request origin that really does prove the pane (the HMAC the app injects into it).
    private func origin(_ id: UUID? = nil, token: String? = nil) -> ControlRequestOrigin {
        let paneID = id ?? pane.id
        return ControlRequestOrigin(pane: paneID.uuidString, screen: 1, workspace: 1, pid: getpid(),
                                    paneToken: token ?? ControlEnvironment.paneToken(for: paneID))
    }

    /// One `agent-event`, through the whole runner, from a peer of our choosing.
    ///
    /// `ControlHarness.run` always speaks as the test host's own pid, and half of what this file
    /// proves is about *whose* process tree the caller sits in — so the request is built here.
    @discardableResult
    private func event(_ json: String, agent: String = "claude-code",
                       origin: ControlRequestOrigin? = nil, pid: pid_t = getpid(),
                       file: StaticString = #filePath, line: UInt = #line) throws -> ControlReply {
        let request = ControlRequest(id: UUID().uuidString, cmd: "agent-event", target: nil,
                                     args: ["agent": .string(agent), "event": .string(json)],
                                     token: ControlEnvironment.token,
                                     origin: origin ?? self.origin())
        let peer = ControlSocket.Peer(fd: -1, uid: getuid(), pid: pid, processName: "xctest")
        var response: ControlResponse?
        harness.runner.handle(request, peer: peer) { response = $0 }
        let got = try XCTUnwrap(response, "agent-event did not answer synchronously", file: file, line: line)
        return try ControlJSON.decoder.decode(ControlReply.self, from: try ControlJSON.line(got))
    }

    /// A fixture as the **CLI would send it**: the recorded hook payload, put through the first of
    /// the two reductions. `--event` is defined as the *reduced* object (that is what the CLI
    /// builds from stdin), so a test that shovelled the raw recording at the server would be
    /// testing a request no hook can produce — and would miss that the server re-reduces.
    private func payload(_ event: String, agent: String = "claude-code",
                         file: StaticString = #filePath, line: UInt = #line) throws -> String {
        let raw = try AgentPayloadFixtures.data(agent, event)
        let reduced = try XCTUnwrap(AgentEventPayload.reduce(raw), "\(agent)/\(event) reduces to nothing",
                                    file: file, line: line)
        return String(decoding: try ControlJSON.encoder.encode(reduced), as: UTF8.self)
    }

    /// A hand-built payload (the cases that are about the server's own reduction).
    private func json(_ fields: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]),
               as: UTF8.self)
    }

    /// A real child of this process, so `ControlLineage.root(of:)` has something true to find.
    /// `sleep` is a platform binary, which is fine here: the lineage walk reads `pbi_ppid`, never
    /// an argument buffer or an environment.
    private func spawnChild() throws -> pid_t {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 30"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        children.append(process)
        return process.processIdentifier
    }

    // MARK: The report class passes the gates that protect the user's layout

    /// `[control] mode = "readonly"` and a modal up: both refuse mutations, both let a report
    /// through. A `PermissionRequest` landing at exactly that moment is the case the whole class
    /// exists for — it is never retried.
    func testAReportPassesTheReadonlyAndModalGatesThatRefuseMutations() throws {
        harness.runner.config.mode = "readonly"
        harness.runner.modalBusyProbe = { true }

        try event(try payload("PermissionRequest")).assertOK()
        XCTAssertEqual(registry.status(pane: pane.id)?.state, .blocked)

        let refused = try harness.run("pane.new")
        XCTAssertFalse(refused.ok, "a mutation must still be refused in readonly mode")
        XCTAssertEqual(refused.error?.code, ControlErrorCode.disabled.rawValue)
    }

    /// Reports have **their own** ledger: a burst of hooks must not spend the budget the agent's
    /// own `quickterm pane new` calls draw on, and vice versa.
    func testReportsNeverSpendTheMutationBucket() throws {
        for _ in 0..<40 { try event(try payload("PreToolUse")).assertOK() }
        let reply = try harness.run("pane.set", target: handle, args: ["title": .string("still mine")])
        reply.assertOK()
        XCTAssertNotEqual(reply.error?.code, ControlErrorCode.rateLimited.rawValue)
    }

    /// The report bucket is sized for `hook-detail = "tools"` (a dozen parallel tool hooks inside
    /// one second is normal), stops there, and refills at 20/s.
    ///
    /// The burst is counted rather than indexed: the bucket refills **while the loop runs**, so
    /// "the 61st is refused" is a claim about a clock nobody controls here. What the runner leg
    /// proves is that the ceiling exists and that at least a full burst gets through it; the exact
    /// arithmetic is proved below on an injected clock, which is the only honest way to state it.
    func testTheReportBucketRefusesTheBurstAndRefillsAfterwards() throws {
        let raw = try payload("PreToolUse")
        var admitted = 0
        var refusal: ControlReply?
        for _ in 0..<400 {
            let reply = try event(raw)
            guard reply.ok else { refusal = reply; break }
            admitted += 1
        }
        let over = try XCTUnwrap(refusal, "the report bucket has no ceiling at all")
        XCTAssertGreaterThanOrEqual(Double(admitted), ControlRateLimiter.reportLimit.capacity,
                                    "a full burst of hooks must never be refused")
        XCTAssertEqual(over.error?.code, ControlErrorCode.rateLimited.rawValue)
        XCTAssertEqual(over.error?.exit, ControlExit.busy.rawValue)
        XCTAssertNotNil(over.error?.retryAfterMs, "a human reading this needs to know how long")

        // The refill, on an injected clock: capacity, then empty, then a second later.
        var limiter = ControlRateLimiter(now: Date(timeIntervalSince1970: 1_700_000_000))
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        for _ in 0..<Int(ControlRateLimiter.reportLimit.capacity) {
            XCTAssertEqual(limiter.admitReport(pane: pane.id, now: start), .allowed)
        }
        guard case .limited(_, let scope) = limiter.admitReport(pane: pane.id, now: start) else {
            return XCTFail("the bucket should be empty by now")
        }
        XCTAssertEqual(scope, "pane", "one runaway pane must not spend another pane's budget")
        XCTAssertEqual(limiter.admitReport(pane: pane.id, now: start.addingTimeInterval(1)), .allowed,
                       "20 tokens a second means the next second admits again")
    }

    // MARK: Proving the pane

    func testWithoutAPaneTokenTheReportIsABadRequest() throws {
        let reply = try event(try payload("Stop"),
                              origin: ControlRequestOrigin(pane: pane.id.uuidString, pid: getpid()))
        XCTAssertFalse(reply.ok)
        XCTAssertEqual(reply.error?.code, ControlErrorCode.badRequest.rawValue)
        XCTAssertTrue(try XCTUnwrap(reply.error?.message).contains("QUICKTERM_PANE_TOKEN"))
        XCTAssertNil(registry.status(pane: pane.id), "nothing was believed")
    }

    /// A wrong token is not merely refused: it is the one shape a forgery takes, so it lands in
    /// the activity log naming the peer the kernel reported.
    func testAWrongPaneTokenIsRefusedAndLogged() throws {
        let reply = try event(try payload("Stop"),
                              origin: origin(token: String(repeating: "0", count: 64)))
        XCTAssertFalse(reply.ok)
        XCTAssertEqual(reply.error?.code, ControlErrorCode.badRequest.rawValue)
        let entry = try XCTUnwrap(ControlActivityLog.shared.recent(10)
            .first { $0.command == "agent-event" })
        XCTAssertEqual(entry.outcome, ControlActivityLog.Entry.Outcome.refused("bad_request"))
        XCTAssertTrue(entry.peer.hasPrefix("xctest("), "the log names the peer, not what it claimed")
        XCTAssertNil(registry.status(pane: pane.id))
    }

    /// A report about a pane that is not this one is not expressible: there is no `-t`, and the
    /// token is recomputed from the pane the caller names.
    func testAnotherPanesTokenCannotBeBorrowed() throws {
        let other = try harness.newTerminal()
        let reply = try event(try payload("PermissionRequest"),
                              origin: origin(pane.id, token: ControlEnvironment.paneToken(for: other.id)))
        XCTAssertFalse(reply.ok)
        XCTAssertEqual(reply.error?.code, ControlErrorCode.badRequest.rawValue)
        XCTAssertNil(registry.status(pane: pane.id))
        XCTAssertNil(registry.status(pane: other.id))
    }

    // MARK: The payload

    func testAnUnknownAgentIsABadRequestThatNamesTheLoadedRules() throws {
        let reply = try event(try payload("Stop"), agent: "claude")
        XCTAssertFalse(reply.ok)
        XCTAssertEqual(reply.error?.code, ControlErrorCode.badRequest.rawValue)
        XCTAssertEqual(reply.error?.candidates?.sorted(), registry.rules.keys.sorted())
    }

    func testAnEventArgumentOverTheCapIsABadRequest() throws {
        let over = try json(["hook_event_name": "PreToolUse",
                             "tool_input": ["command": String(repeating: "x", count: 9000)]])
        XCTAssertGreaterThan(over.utf8.count, AgentEventPayload.maxStdinBytes)
        let reply = try event(over)
        XCTAssertFalse(reply.ok)
        XCTAssertEqual(reply.error?.code, ControlErrorCode.badRequest.rawValue)
        XCTAssertTrue(try XCTUnwrap(reply.error?.message).contains("too large"))
    }

    /// The server reduces **again**, so a hand-built `--event` is worth no more than a real hook:
    /// a five-kilobyte command comes out at 200 characters, and the fields the whitelist has no
    /// home for are not fields at all — they decode into nothing and reach nothing.
    func testTheServerReReducesAHandBuiltEvent() throws {
        let reply = try event(try json([
            "hook_event_name": "PreToolUse",
            "tool_name": "Bash",
            "transcript_path": "/Users/danny/.claude/projects/x/conversation.jsonl",
            "cwd": "/Users/danny/secret-project",
            "tool_input": ["command": String(repeating: "c", count: 5000),
                           "description": "a tidy little command"],
        ]))
        reply.assertOK()
        let status = try XCTUnwrap(registry.status(pane: pane.id))
        XCTAssertEqual(status.message?.count, AgentEventPayload.maxFieldLength)
        XCTAssertEqual(status.tool, "Bash")
        let seen = [status.message, status.tool, status.sessionID].compactMap { $0 }.joined(separator: " ")
        XCTAssertFalse(seen.contains("conversation.jsonl"))
        XCTAssertFalse(seen.contains("secret-project"))
    }

    /// `--event` is the **reduced** shape, and the decoder says so: a `tool_input` still carrying a
    /// number (what a raw hook payload looks like before the CLI has been through it) is refused
    /// outright rather than half-read. Nothing a hook can produce ever takes this road — the CLI
    /// reduces first — and a hand-built one that skips the reduction is told so plainly.
    func testARawUnreducedPayloadIsRefused() throws {
        let reply = try event(try json(["hook_event_name": "PreToolUse", "tool_name": "Bash",
                                        "tool_input": ["command": "ls", "timeout": 120_000]]))
        XCTAssertFalse(reply.ok)
        XCTAssertEqual(reply.error?.code, ControlErrorCode.badRequest.rawValue)
        XCTAssertNil(registry.status(pane: pane.id), "a payload that did not decode changes nothing")
    }

    // MARK: The rule files, replayed

    /// Every recorded payload, through the whole command, lands on the state its rule file says.
    /// This is the table that fails when a rule file and a fixture drift apart — which is exactly
    /// what happens the day one of these is replaced by a real recording.
    func testEveryFixtureLandsOnTheStateItsRuleFileSays() throws {
        // agent, event, state, detail, tool, needsUser
        let table: [(String, String, String, AgentDetail?, String?, Bool)] = [
            ("claude-code", "SessionStart", "idle", nil, nil, false),
            ("claude-code", "UserPromptSubmit", "working", .thinking, nil, false),
            ("claude-code", "PreToolUse", "working", .tool, "Bash", false),
            ("claude-code", "PostToolUse", "working", .thinking, "Bash", false),
            ("claude-code", "PermissionRequest", "blocked", .approval, "Bash", true),
            ("claude-code", "Notification", "blocked", .approval, "Bash", true),
            ("claude-code", "Stop", "done", nil, nil, false),
            ("claude-code", "StopFailure", "error", nil, nil, true),
            ("claude-code", "SessionEnd", "released", nil, nil, false),
            ("codex", "SessionStart", "idle", nil, nil, false),
            ("codex", "UserPromptSubmit", "working", .thinking, nil, false),
            ("codex", "PreToolUse", "working", .tool, "shell", false),
            ("codex", "PostToolUse", "working", .thinking, "shell", false),
            ("codex", "PermissionRequest", "blocked", .approval, "shell", true),
            ("codex", "Stop", "done", nil, nil, false),
            ("codex", "Interrupt", "idle", nil, nil, false),
            ("codex", "SessionEnd", "released", nil, nil, false),
            ("gemini", "SessionStart", "idle", nil, nil, false),
            ("gemini", "BeforeAgent", "working", .thinking, nil, false),
            ("gemini", "AfterAgent", "done", nil, nil, false),
            ("gemini", "BeforeTool", "working", .tool, "run_shell_command", false),
            ("gemini", "AfterTool", "working", .thinking, "run_shell_command", false),
            ("gemini", "Notification", "blocked", .approval, "run_shell_command", true),
            ("gemini", "SessionEnd", "released", nil, nil, false),
        ]
        for (agent, name, state, detail, tool, needsUser) in table {
            // Each fixture is judged on its own: a state left over from the previous row would
            // make `since` and the transitions meaningless.
            registry.resetForTesting()
            center.resetForTesting()
            let where_ = "\(agent)/\(name)"
            // A release has to have something to release: `SessionEnd` arriving at a pane nobody
            // ever reported on is not a transition, and the reply says `unknown` rather than
            // inventing one. So the session is started first, exactly as it is in life.
            if state == "released" { try event(try payload("SessionStart", agent: agent), agent: agent).assertOK() }
            let reply = try event(try payload(name, agent: agent), agent: agent)
            reply.assertOK()
            let data = try XCTUnwrap(reply.data?.objectValue, where_)
            XCTAssertEqual(data["state"]?.stringValue, state, where_)
            XCTAssertEqual(data["detail"]?.stringValue, detail?.rawValue, where_)
            XCTAssertEqual(data["pane"]?.stringValue, handle, where_)
            XCTAssertEqual(data["agent"]?.stringValue, agent, where_)
            XCTAssertEqual(data["schema"]?.stringValue, "quickterm.agent-event/1", where_)

            let status = registry.status(pane: pane.id)
            if state == "released" {
                XCTAssertNil(status, where_)
            } else {
                XCTAssertEqual(status?.state.rawValue, state, where_)
                XCTAssertEqual(status?.detail, detail, where_)
                XCTAssertEqual(status?.tool, tool, where_)
                XCTAssertEqual(status?.needsUser, needsUser, where_)
                XCTAssertEqual(status?.evidence, .hook, where_)
            }
            XCTAssertEqual(center.urgency(pane: pane.id) == .needsUser, needsUser, where_)
        }
    }

    // MARK: The alarm, and who may take it down

    /// One prompt, one alarm, carrying the lineage of the process that reported it and the agent's
    /// own session id. Both halves are what `permits` compares later.
    func testPermissionRequestPostsOneAlarmWithItsLineageAndSession() throws {
        let child = try spawnChild()
        let reply = try event(try payload("PermissionRequest"), pid: child)
        reply.assertOK()

        let id = try XCTUnwrap(reply.data?["noticeID"]?.stringValue)
        XCTAssertEqual(center.live.count, 1)
        let notice = try XCTUnwrap(center.notice(id: try XCTUnwrap(UUID(uuidString: id))))
        XCTAssertEqual(notice.urgency, .needsUser)
        XCTAssertEqual(notice.evidence, .hook)
        XCTAssertEqual(notice.origin?.lineageRoot, ControlLineage.root(of: child))
        XCTAssertEqual(notice.origin?.lineageRoot, child, "a direct child of the test host is its own root")
        XCTAssertEqual(notice.origin?.sessionID, "c3a1f0d2-51b8-4b6a-9a2e-6d0c1f3e8a47")
        XCTAssertTrue(notice.title.contains("Bash"))
        XCTAssertFalse(notice.title.contains("rm -rf"), "a command line may never be in a title")
        XCTAssertEqual(notice.body, "rm -rf build")
    }

    /// The same agent, the same pane, a **different process lineage**: refused, logged, and the
    /// alarm is still there. A forger may add a notice; it may never remove one.
    func testAForeignLineageCannotResolveTheAlarm() throws {
        let poster = try spawnChild()
        try event(try payload("PermissionRequest"), pid: poster).assertOK()
        XCTAssertEqual(center.live(pane: pane.id).count, 1)
        ControlActivityLog.shared.clear()

        let stranger = try spawnChild()
        let reply = try event(try payload("Stop"), pid: stranger)
        XCTAssertFalse(reply.ok)
        XCTAssertEqual(reply.error?.code, ControlErrorCode.originMismatch.rawValue)
        XCTAssertEqual(reply.error?.exit, ControlExit.denied.rawValue)
        XCTAssertTrue(try XCTUnwrap(reply.error?.message).contains(handle))

        let entry = try XCTUnwrap(ControlActivityLog.shared.recent(10).first { $0.command == "agent-event" })
        XCTAssertEqual(entry.outcome, ControlActivityLog.Entry.Outcome.refused("origin_mismatch"))
        XCTAssertEqual(center.live(pane: pane.id).filter { $0.urgency == .needsUser }.count, 1,
                       "the alarm stays up")
    }

    /// The other half of `permits`: the same process, a different session id. A second agent
    /// started inside the first one's pane cannot answer its prompt.
    func testAForeignSessionCannotResolveTheAlarm() throws {
        let agentPID = try spawnChild()
        try event(try payload("PermissionRequest"), pid: agentPID).assertOK()

        let other = try json(["hook_event_name": "Stop", "session_id": "a-different-session"])
        let reply = try event(other, pid: agentPID)
        XCTAssertFalse(reply.ok)
        XCTAssertEqual(reply.error?.code, ControlErrorCode.originMismatch.rawValue)
        XCTAssertEqual(center.live(pane: pane.id).filter { $0.urgency == .needsUser }.count, 1)
    }

    /// The lineage that posted it takes it down, and says how many it took.
    func testThePostingLineageResolvesItsOwnAlarm() throws {
        let agentPID = try spawnChild()
        try event(try payload("PermissionRequest"), pid: agentPID).assertOK()

        let reply = try event(try payload("Stop"), pid: agentPID)
        reply.assertOK()
        XCTAssertEqual(reply.data?["resolved"]?.intValue, 1)
        XCTAssertEqual(center.live(pane: pane.id).filter { $0.urgency == .needsUser }.count, 0)
        XCTAssertTrue(center.history.contains { $0.resolution == .stateChanged },
                      "the alarm is resolved as state-changed, which is what the wire tells an agent")
    }

    // MARK: seq

    /// `seq` is the ruler an agent takes straight into `events poll --since`, so a report moves it
    /// **only** when something really changed: a repeated `PreToolUse` for the same tool is the
    /// common case under `hook-detail = "tools"`, and it must cost nothing.
    func testSeqMovesOncePerStateChangeAndNotAtAllForARepeatedTool() throws {
        let mark0 = harness.seq
        let first = try event(try payload("PreToolUse"))
        first.assertOK()
        XCTAssertEqual(first.data?["changed"]?.boolValue, true)
        XCTAssertEqual(agentEvents(since: mark0).count, 1)

        // `harness.events` flushed the bus, so this mark is the seq with every other producer
        // already accounted for — and a report that changes nothing never flushes again.
        let mark1 = harness.seq
        let repeated = try event(try payload("PreToolUse"))
        repeated.assertOK()
        XCTAssertEqual(repeated.data?["changed"]?.boolValue, false)
        XCTAssertEqual(repeated.seq, mark1, "the same tool twice is not news, so seq stands still")
        XCTAssertEqual(agentEvents(since: mark1).count, 0)

        let mark2 = harness.seq
        let moved = try event(try payload("PermissionRequest"))
        moved.assertOK()
        XCTAssertEqual(moved.data?["changed"]?.boolValue, true)
        XCTAssertGreaterThan(try XCTUnwrap(moved.seq), mark2)
        let emitted = agentEvents(since: mark2)
        XCTAssertEqual(emitted.count, 1, "one state change, one event")
        XCTAssertEqual(emitted.first?.state, "blocked")
        XCTAssertEqual(emitted.first?.detail, "approval")
        XCTAssertEqual(emitted.first?.tool, "Bash")
    }

    /// The `agent.state.changed` events since `mark`.
    private func agentEvents(since mark: Int) -> [ControlEvent] {
        harness.events(since: mark).filter { $0.type == ControlEventType.agentStateChanged.rawValue }
    }

    /// An event no rule file maps is not an error and not news: it is heard (the OSC fallback
    /// stays quiet) and nothing else happens.
    func testAnUnmappedEventIsAcceptedAndChangesNothing() throws {
        try event(try payload("PreToolUse")).assertOK()
        _ = harness.events(since: 0)           // flush, so `before` is a settled number
        let before = harness.seq
        let reply = try event(try json(["hook_event_name": "SomethingNobodyMapped"]))
        reply.assertOK()
        XCTAssertEqual(reply.data?["changed"]?.boolValue, false)
        XCTAssertEqual(reply.seq, before)
        XCTAssertEqual(registry.status(pane: pane.id)?.detail, .tool, "the state is untouched")
    }
}
