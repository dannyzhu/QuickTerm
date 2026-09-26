import XCTest
@testable import QuickTerm

/// **Precedence** (plan §2.4), against a fixed clock.
///
/// Every case here is a claim about which source is allowed to contradict which: a hook beats
/// everything, an OSC text may only speak when no hook has been heard recently, and the process
/// scan is presence and never a state. Get one of these backwards and the failure mode is not a
/// crash — it is an approval prompt quietly overwritten by a "task complete" banner.
final class AgentStateReducerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private static let text = """
    id = "demo"
    name = "Demo"
    process = ["demo"]

    [fields]
    session = "$.session_id"
    message = "$.message"
    tool    = "$.tool_name"
    summary = ["$.tool_input.command", "$.message"]

    [hooks]
    SessionStart      = "idle"
    UserPromptSubmit  = "working:thinking"
    PreToolUse        = "working:tool"
    PermissionRequest = "blocked:approval"
    Stop              = "done"
    SessionEnd        = "released"

    [hooks.Notification]
    field = "$.notification_type"

    [hooks.Notification.values]
    permission_prompt = "blocked:approval"

    [notifications]
    "Demo needs your permission" = "blocked:approval"
    "Demo finished"              = "done"
    """

    private var rules: AgentRules!

    override func setUpWithError() throws {
        try super.setUpWithError()
        rules = try AgentRules.parse(Self.text)
    }

    private func hook(_ event: String, tool: String? = nil, command: String? = nil,
                      session: String? = nil, notification: String? = nil) -> PaneSignal {
        .hook(agent: "demo", payload: AgentEventPayload(
            hookEventName: event, notificationType: notification, sessionID: session,
            toolName: tool, toolInput: command.map { ["command": $0] }))
    }

    private func reduce(_ signal: PaneSignal, current: AgentStatus? = nil,
                        at offset: TimeInterval = 0) -> AgentReduction {
        AgentStateReducer.reduce(signal, rules: rules, current: current,
                                 now: now.addingTimeInterval(offset))
    }

    // MARK: 1. Hooks

    func testHookSetsTheStateAndTakesItsTextFromTheRuleFile() {
        let result = reduce(hook("PreToolUse", tool: "Bash", command: "npm test", session: "s1"))
        XCTAssertEqual(result.kind, .changed)
        let status = result.status
        XCTAssertEqual(status?.state, .working)
        XCTAssertEqual(status?.detail, .tool)
        XCTAssertEqual(status?.tool, "Bash")
        XCTAssertEqual(status?.message, "npm test", "summary wins over message")
        XCTAssertEqual(status?.sessionID, "s1")
        XCTAssertEqual(status?.evidence, .hook)
        XCTAssertEqual(status?.lastHookAt, now)
        XCTAssertEqual(status?.since, now)
    }

    func testKeyedEventReadsItsFieldAndAnUnmappedValueChangesNothing() {
        let mapped = reduce(hook("Notification", notification: "permission_prompt"))
        XCTAssertEqual(mapped.status?.detail, .approval)
        let unmapped = reduce(hook("Notification", notification: "something_new"),
                              current: mapped.status)
        XCTAssertEqual(unmapped.kind, .none)
        XCTAssertEqual(unmapped.status?.detail, .approval, "the state it had is left alone")
    }

    /// An event no rule maps is still news that the agent is alive: `lastHookAt` moves, which is
    /// what keeps the OSC fallback quiet for an agent whose hooks are installed.
    func testAnUnmappedHookStillBumpsLastHookAt() {
        let first = reduce(hook("PreToolUse", tool: "Bash"))
        let later = reduce(hook("PostToolUse"), current: first.status, at: 3)
        XCTAssertEqual(later.kind, .none)
        XCTAssertEqual(later.status?.lastHookAt, now.addingTimeInterval(3))
        XCTAssertEqual(later.status?.state, .working)
    }

    /// `since` is "how long has it been like this", so a repeated hook for the same state must
    /// not reset it — the strip's elapsed time is read off it.
    func testSinceOnlyMovesWhenTheStateDoes() {
        let first = reduce(hook("PreToolUse", tool: "Bash"))
        let same = reduce(hook("PreToolUse", tool: "Bash"), current: first.status, at: 30)
        XCTAssertEqual(same.kind, .none)
        XCTAssertEqual(same.status?.since, now)
        let other = reduce(hook("PreToolUse", tool: "Write"), current: first.status, at: 40)
        XCTAssertEqual(other.kind, .changed, "a different tool is a change worth reporting")
        XCTAssertEqual(other.status?.since, now, "…but the state did not move, so since does not")
    }

    func testReleasedTagRemovesTheAgent() {
        let live = reduce(hook("SessionStart")).status
        let gone = reduce(hook("SessionEnd"), current: live)
        XCTAssertEqual(gone.kind, .released)
        XCTAssertNil(gone.status)
    }

    // MARK: 2. The OSC fallback

    func testNotificationIsIgnoredInsideTheRecencyWindow() {
        let hooked = reduce(hook("PermissionRequest", tool: "Bash")).status
        let osc = reduce(.notification(title: "Demo finished", body: ""), current: hooked, at: 2)
        XCTAssertEqual(osc.kind, .none)
        XCTAssertEqual(osc.status?.state, .blocked,
                       "a fresh hook may not be contradicted by an OSC text")
    }

    func testNotificationSpeaksOutsideTheRecencyWindow() {
        let hooked = reduce(hook("PermissionRequest", tool: "Bash")).status
        let osc = reduce(.notification(title: "Demo finished", body: "all done"),
                         current: hooked, at: AgentStateReducer.hookRecency + 1)
        XCTAssertEqual(osc.kind, .changed)
        XCTAssertEqual(osc.status?.state, .done)
        XCTAssertEqual(osc.status?.evidence, .notification)
        XCTAssertEqual(osc.status?.message, "all done")
        XCTAssertNil(osc.status?.tool, "an OSC text names no tool")
    }

    func testAnUnmatchedNotificationChangesNothing() {
        let result = reduce(.notification(title: "Some other program", body: "hi"))
        XCTAssertEqual(result.kind, .none)
        XCTAssertNil(result.status)
    }

    /// The OSC text arriving **before** the hook that describes the same prompt: the second
    /// signal is an evidence upgrade, not a second alarm.
    func testOSCBeforeHookIsAnEvidenceUpgrade() {
        let osc = reduce(.notification(title: "Demo needs your permission", body: "run npm test"))
        XCTAssertEqual(osc.kind, .changed)
        XCTAssertEqual(osc.status?.evidence, .notification)

        let hooked = reduce(hook("PermissionRequest"), current: osc.status, at: 0.2)
        XCTAssertEqual(hooked.kind, .evidenceUpgrade)
        XCTAssertEqual(hooked.status?.evidence, .hook)
        XCTAssertEqual(hooked.status?.since, osc.status?.since, "the same prompt, still waiting")
    }

    // MARK: 3. Presence

    func testPresenceCreatesUnknownOnlyWhenNothingIsKnown() {
        let fresh = reduce(.processes([42]))
        XCTAssertEqual(fresh.kind, .changed)
        XCTAssertEqual(fresh.status?.state, .unknown)
        XCTAssertEqual(fresh.status?.evidence, .process)
        XCTAssertEqual(fresh.status?.seenByScan, true)

        let hooked = reduce(hook("PermissionRequest"), current: fresh.status).status
        let again = reduce(.processes([42]), current: hooked)
        XCTAssertEqual(again.kind, .none)
        XCTAssertEqual(again.status?.state, .blocked, "presence never overwrites a state")
    }

    func testPresenceLossReleasesOnlyWhatTheScanHadSeen() {
        let seen = reduce(.processes([42])).status
        XCTAssertEqual(reduce(.processes([]), current: seen).kind, .released)

        // An agent the scan never saw (the interpreter case) is released by its own SessionEnd,
        // never by an empty scan result.
        let hookOnly = reduce(hook("SessionStart")).status
        let empty = reduce(.processes([]), current: hookOnly)
        XCTAssertEqual(empty.kind, .none)
        XCTAssertEqual(empty.status?.state, .idle)
    }

    /// Presence is read **per rule**: a pass that found somebody else's process found nothing of
    /// ours, and a pane that already belongs to another rule is not this one's to claim.
    func testPresenceIsReadPerRuleAndNeverClaimsAnotherRulesPane() {
        XCTAssertEqual(reduce(.processes(["somebody-else": [42]])).kind, .none,
                       "another rule's process is not our presence")
        XCTAssertEqual(reduce(.processes(["demo": [42]])).kind, .changed)

        let foreign = AgentStatus(agent: "somebody-else", name: "Else", state: .blocked,
                                  detail: .approval, since: now, evidence: .hook)
        let claimed = reduce(.processes(["demo": [42]]), current: foreign)
        XCTAssertEqual(claimed.kind, .none, "presence may only create a status where none exists")
        XCTAssertEqual(claimed.status?.agent, "somebody-else")
    }

    func testChildExitedReleases() {
        let live = reduce(hook("PermissionRequest")).status
        XCTAssertEqual(reduce(.childExited, current: live).kind, .released)
        XCTAssertEqual(reduce(.childExited, current: nil).kind, .none)
    }

    // MARK: Reports

    func testAReportIsAsAuthoritativeAsAHook() {
        let hooked = reduce(hook("PermissionRequest", tool: "Bash")).status
        let report = reduce(.report(source: "herdr", agent: "demo", state: .idle, message: "done"),
                            current: hooked, at: 1)
        XCTAssertEqual(report.kind, .changed)
        XCTAssertEqual(report.status?.state, .idle)
        XCTAssertEqual(report.status?.evidence, .report)
        XCTAssertNil(report.status?.detail, "an approval detail may not survive into idle")
    }

    /// A status belonging to another agent is not this signal's history.
    func testASignalFromAnotherAgentStartsFresh() {
        var other = reduce(hook("PermissionRequest", tool: "Bash")).status
        other?.evidence = .hook
        let foreign = AgentStatus(agent: "somebody-else", name: "Else", state: .blocked,
                                  detail: .approval, since: now, evidence: .hook)
        let result = reduce(hook("SessionStart"), current: foreign)
        XCTAssertEqual(result.kind, .changed)
        XCTAssertEqual(result.status?.agent, "demo")
    }

    // MARK: 5. A session that ended stays ended

    /// The trace of 2026-09-26: Claude Code's `Stop` reached the socket 50 ms after its
    /// `SessionEnd`, and built the status back with nothing left to take it down. A release
    /// leaves a tombstone, and the reducer says which later signals are that session's stragglers.
    func testAReleaseLeavesATombstoneAndNamesItsStragglers() throws {
        let live = reduce(hook("Stop", session: "s1")).status
        let end = reduce(hook("SessionEnd", session: "s1"), current: live)
        XCTAssertEqual(end.kind, .released)
        let tomb = try XCTUnwrap(end.released)
        XCTAssertEqual(tomb, AgentStateReducer.ReleasedSession(agent: "demo", session: "s1", at: now))

        func straggler(_ signal: PaneSignal, after offset: TimeInterval,
                       rules: AgentRules? = nil) -> Bool {
            AgentStateReducer.isStraggler(signal, rules: rules ?? self.rules, released: tomb,
                                          now: now.addingTimeInterval(offset))
        }
        XCTAssertTrue(straggler(hook("Stop", session: "s1"), after: 0.05), "the Stop that lost the race")
        XCTAssertTrue(straggler(hook("Stop", session: "s1"),
                                after: AgentStateReducer.releasedSessionGrace - 0.001),
                      "the last instant inside the grace")
        XCTAssertTrue(straggler(.notification(title: "Demo finished", body: ""), after: 1),
                      "the text printed on the way out races the exit the same way")
        XCTAssertFalse(straggler(.notification(title: "Tests passed", body: ""), after: 1),
                       "a text this agent's rules do not map belongs to whatever printed it")
        XCTAssertFalse(straggler(.notification(title: "Demo needs your permission", body: ""), after: 1),
                       "an agent asking for the user is alive, by text as by hook")
        XCTAssertFalse(straggler(hook("SessionEnd", session: "s1"), after: 1),
                       "another end of the same session passes and re-anchors the tombstone")
        XCTAssertFalse(straggler(hook("SessionStart", session: "s2"), after: 0.05), "a new session")
        XCTAssertFalse(straggler(hook("PermissionRequest", tool: "Bash", session: "s1"), after: 0.05),
                       "an agent asking for the user is alive: a resumed session's prompt is never dropped")
        XCTAssertFalse(straggler(hook("Stop", session: "s1"),
                                 after: AgentStateReducer.releasedSessionGrace), "the grace has passed")
        XCTAssertFalse(straggler(.childExited, after: 0.05), "a child exiting is about the present")
        let other = try AgentRules.parse(Self.text.replacingOccurrences(of: "id = \"demo\"",
                                                                        with: "id = \"other\""))
        XCTAssertFalse(straggler(hook("Stop", session: "s1"), after: 0.05, rules: other),
                       "another agent's hook")

        // A SessionEnd nobody had a status for still leaves a tombstone; so does the child exiting.
        XCTAssertEqual(reduce(hook("SessionEnd", session: "s3")).released?.session, "s3")
        // Another session's end is not this status's end (`/clear`: SessionEnd(old) and
        // SessionStart(new) arrive in either order): the old session gets its tombstone, the new
        // session keeps its status.
        let fresh = reduce(hook("SessionStart", session: "s2")).status
        let stale = reduce(hook("SessionEnd", session: "s1"), current: fresh)
        XCTAssertEqual(stale.kind, .none)
        XCTAssertEqual(stale.status, fresh)
        XCTAssertEqual(stale.released?.session, "s1")
        XCTAssertEqual(reduce(.childExited, current: live).released?.session, "s1")
        // A tombstone that knows no session id has nothing to compare a hook against: it shadows
        // the agent's text, not its hooks — a SessionStart of a new session must get through.
        let blind = AgentStateReducer.ReleasedSession(agent: "demo", session: nil, at: now)
        XCTAssertFalse(AgentStateReducer.isStraggler(hook("SessionStart", session: "s9"), rules: rules,
                                                     released: blind, now: now))
        XCTAssertTrue(AgentStateReducer.isStraggler(.notification(title: "Demo finished", body: ""),
                                                    rules: rules, released: blind, now: now))
    }
}
