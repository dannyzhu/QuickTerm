import AppKit
import Combine
import XCTest
@testable import QuickTerm

/// **The transitions** (plan §2.5), plus the two redraw bounds of §1.5.
///
/// The registry is the one place that turns a reduced state into things the user and an agent can
/// see: the pane's own status, one `agent.state.changed`, and — only when a pane starts or stops
/// needing a human — a notice. Everything here is a claim about *when* those fire, because the
/// cost of firing them too often is not wrong output, it is a redraw of every mounted frame on
/// every tool call.
@MainActor
final class AgentRegistryTests: XCTestCase {
    private var app: AppDelegate {
        get throws { try XCTUnwrap(NSApp.delegate as? AppDelegate) }
    }

    private var locator = NoticeLocatorStub()
    private var center: NoticeCenter!
    private var sink: NoticeRecordingSink!
    private var registry: AgentRegistry!
    private var now = Date(timeIntervalSince1970: 1_700_000_000)
    private var bag: Set<AnyCancellable> = []

    private static let text = """
    id = "demo"
    name = "Demo"
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
    PostToolUse       = "working:thinking"
    PermissionRequest = "blocked:approval"
    StopFailure       = "error"
    Stop              = "done"
    SessionEnd        = "released"

    [notifications]
    "Demo needs your permission" = "blocked:approval"
    """

    /// A second agent, for the pane that runs two. Same shape, different id and process name —
    /// what matters here is only that the scan can tell one from the other.
    private static let otherText = """
    id = "other"
    name = "Other"
    process = ["other"]

    [hooks]
    SessionStart = "idle"
    SessionEnd   = "released"
    """

    override func setUp() async throws {
        try await super.setUp()
        locator = NoticeLocatorStub()
        center = NoticeCenter(locator: locator, clock: { [self] in now })
        sink = NoticeRecordingSink(sinkID: NoticeSinkID.dockBadge)
        center.addSink(sink)
        registry = AgentRegistry(rules: [try AgentRules.parse(Self.text)], center: center,
                                 locator: locator, clock: { [self] in now })
        registry.settings.enabled = ["demo"]
        bag.removeAll()
    }

    @discardableResult
    private func addPane() throws -> (id: UUID, view: PaneView) {
        let host = try XCTUnwrap(app.screens.primary)
        let pane = PaneView(frame: .zero)
        locator.entries[pane.id] = .init(pane: pane, controller: host, workspace: 0,
                                         activity: PaneActivity(appActive: false, screenKey: false,
                                                                workspaceVisible: false, focused: false))
        return (pane.id, pane)
    }

    private func hook(_ event: String, tool: String? = nil, command: String? = nil,
                      session: String? = nil, error: String? = nil) -> PaneSignal {
        .hook(agent: "demo", payload: AgentEventPayload(
            hookEventName: event, sessionID: session, toolName: tool, errorType: error,
            toolInput: command.map { ["command": $0] }))
    }

    /// Both rules loaded and enabled, in that order: `demo` is the pane's agent, `other` is the
    /// one that turns up in the same pane and must keep its hands off.
    private func loadTwoRules() throws {
        registry.reloadRulesForTesting([try AgentRules.parse(Self.text),
                                        try AgentRules.parse(Self.otherText)])
        registry.settings.enabled = ["demo", "other"]
    }

    /// The `agent.state.changed` events emitted since `mark`.
    private func agentEvents(since mark: Int) -> [ControlEvent] {
        ControlEventBus.shared.flush()
        return ControlEventBus.shared
            .batch(since: mark, limit: ControlEventLimits.maxBatch, types: nil, exposesBrowser: true)
            .events.filter { $0.type == ControlEventType.agentStateChanged.rawValue }
    }

    // MARK: Notices

    /// Entering `blocked` posts exactly one alarm, with the lineage that reported it, and the
    /// title carries the tool **name** and no payload.
    func testEnteringBlockedPostsOneAlarmWithItsOrigin() throws {
        let pane = try addPane()
        let origin = NoticeOrigin(lineageRoot: 4242, sessionID: "s1")
        let outcome = registry.apply(hook("PermissionRequest", tool: "Bash", command: "rm -rf /tmp/x",
                                          session: "s1"),
                                     pane: pane.id, origin: origin)

        XCTAssertTrue(outcome.changed)
        let id = try XCTUnwrap(outcome.noticePosted)
        let notice = try XCTUnwrap(center.notice(id: id))
        XCTAssertEqual(notice.urgency, .needsUser)
        XCTAssertEqual(notice.source.id, "agent:demo")
        XCTAssertEqual(notice.evidence, .hook)
        XCTAssertEqual(notice.origin, origin)
        XCTAssertTrue(notice.title.contains("Bash"))
        XCTAssertFalse(notice.title.contains("rm -rf"), "a command line may never be in a title")
        XCTAssertEqual(notice.body, "rm -rf /tmp/x")
        XCTAssertTrue(notice.bodySensitive)
        XCTAssertEqual(center.counts.total, 1)
    }

    /// The OSC text arrives first, the hook a moment later: the strip learns the tool name and
    /// the better evidence, and **the alarm already on screen is left exactly as it is**.
    func testEvidenceUpgradeDoesNotRepost() throws {
        let pane = try addPane()
        registry.apply(.notification(title: "Demo needs your permission", body: "may I?"),
                       pane: pane.id)
        XCTAssertEqual(sink.posted.count, 1)
        let first = try XCTUnwrap(sink.posted.first)

        now += 0.2
        let outcome = registry.apply(hook("PermissionRequest"), pane: pane.id,
                                     origin: NoticeOrigin(lineageRoot: 9))
        XCTAssertFalse(outcome.changed, "an evidence upgrade is not a state change")
        XCTAssertNil(outcome.noticePosted)
        XCTAssertEqual(sink.posted.count, 1, "the same prompt must not become two alarms")
        XCTAssertEqual(center.live.first?.id, first.id)
        XCTAssertEqual(registry.status(pane: pane.id)?.evidence, .hook)
    }

    /// Leaving `blocked` resolves the alarm — but only for the lineage that posted it.
    func testLeavingBlockedResolvesForItsOwnLineageOnly() throws {
        let pane = try addPane()
        let origin = NoticeOrigin(lineageRoot: 4242, sessionID: "s1")
        registry.apply(hook("PermissionRequest", tool: "Bash", session: "s1"), pane: pane.id,
                       origin: origin)

        now += 1
        let foreign = registry.apply(hook("PostToolUse", session: "s1"), pane: pane.id,
                                     origin: NoticeOrigin(lineageRoot: 77, sessionID: "s1"))
        XCTAssertEqual(foreign.resolved, 0)
        XCTAssertEqual(foreign.refused.count, 1, "a foreign lineage is refused, and says so")
        XCTAssertEqual(center.live.count, 1, "the alarm stays: a forger may never remove a notice")

        now += 1
        registry.apply(hook("PermissionRequest", tool: "Bash", session: "s1"), pane: pane.id,
                       origin: origin)
        let owner = registry.apply(hook("PostToolUse", session: "s1"), pane: pane.id, origin: origin)
        XCTAssertEqual(owner.resolved, 1)
        XCTAssertTrue(owner.refused.isEmpty)
        XCTAssertEqual(center.history.last?.resolution, .stateChanged)
    }

    /// **A refusal is total.** The forged `Stop` is answered `origin_mismatch` *and* leaves the
    /// pane exactly as it found it — because if it moved the status to `done`, the agent's own
    /// next `Stop` would be the same state from the same rule, would reduce to nothing, and would
    /// never reach the resolution path: the alarm we promise to keep live would be one nobody
    /// could ever take down.
    func testARefusedResolveLeavesTheStatusAloneSoTheOwnerCanStillResolve() throws {
        let pane = try addPane()
        let origin = NoticeOrigin(lineageRoot: 4242, sessionID: "s1")
        registry.apply(hook("PermissionRequest", tool: "Bash", session: "s1"), pane: pane.id,
                       origin: origin)
        let posted = try XCTUnwrap(registry.status(pane: pane.id))

        now += 1
        let foreign = registry.apply(hook("Stop", session: "s1"), pane: pane.id,
                                     origin: NoticeOrigin(lineageRoot: 77, sessionID: "s1"))
        XCTAssertEqual(foreign.resolved, 0)
        XCTAssertEqual(foreign.refused.count, 1)
        XCTAssertFalse(foreign.changed, "a refused report is not a state change")
        XCTAssertEqual(center.live.count, 1, "the alarm stays: a forger may never remove a notice")
        XCTAssertEqual(registry.status(pane: pane.id), posted,
                       "nor may it move the status out from under the agent that posted it")
        XCTAssertEqual(sink.posted.count, 1, "and nothing was reposted")

        now += 1
        let owner = registry.apply(hook("Stop", session: "s1"), pane: pane.id, origin: origin)
        XCTAssertEqual(owner.resolved, 1, "the lineage that posted it can still take it down")
        XCTAssertTrue(owner.refused.isEmpty)
        XCTAssertEqual(registry.status(pane: pane.id)?.state, .done)
        XCTAssertEqual(center.history.last?.resolution, .stateChanged)
    }

    /// The agent's process went away while its prompt was live: the alarm resolves as
    /// `agent-gone`, which on the wire says why the prompt disappeared.
    func testPresenceLossResolvesAsAgentGone() throws {
        let pane = try addPane()
        registry.apply(.processes([42]), pane: pane.id)
        registry.apply(hook("PermissionRequest", tool: "Bash"), pane: pane.id,
                       origin: NoticeOrigin(lineageRoot: 1))
        XCTAssertEqual(center.counts.total, 1)

        now += 5
        let outcome = registry.apply(.processes([]), pane: pane.id)
        XCTAssertEqual(outcome.resolved, 1)
        XCTAssertEqual(center.history.last?.resolution, .agentGone)
        XCTAssertNil(registry.status(pane: pane.id))
        XCTAssertEqual(center.counts.total, 0)
    }

    /// **The defect, exactly as the integrator hit it.** A `demo` hook posts an approval alarm;
    /// the next scan pass finds `other`'s process in that same pane — a nested agent, or simply a
    /// second rule whose process is running there. The pane belongs to the agent that is speaking:
    /// the status stays `demo`'s and the alarm stays up.
    ///
    /// Before a scan was routed per rule, `other` was tried as a candidate, found the pane's
    /// status to be somebody else's, and created a fresh `unknown`/`process` of its own — which
    /// left `demo`'s `blocked` behind and resolved its alarm as `agent-gone`.
    func testAnotherRulesProcessNeverTakesAPaneFromALiveAlarm() throws {
        try loadTwoRules()
        let pane = try addPane()
        let posted = registry.apply(hook("PermissionRequest", tool: "Bash"), pane: pane.id,
                                    origin: NoticeOrigin(lineageRoot: 1))
        let alarm = try XCTUnwrap(posted.noticePosted)

        now += 1
        let scan = registry.apply(.processes(["other": [4242]]), pane: pane.id)
        XCTAssertFalse(scan.changed)
        XCTAssertEqual(scan.resolved, 0)
        let status = try XCTUnwrap(registry.status(pane: pane.id))
        XCTAssertEqual(status.agent, "demo")
        XCTAssertEqual(status.state, .blocked)
        XCTAssertEqual(status.evidence, .hook)
        XCTAssertFalse(status.seenByScan, "the pass found somebody else's process, not demo's")
        XCTAssertEqual(center.live.map(\.id), [alarm], "the alarm is untouched")
        XCTAssertEqual(center.counts.total, 1)
    }

    /// A pass that does not find the pane's own agent says **nothing** about a status the scan had
    /// never confirmed: a hook-evidenced pane whose agent runs as an interpreter (`node …`) is
    /// invisible to the scan, and silence must not be read as "it left".
    func testPresenceLossLeavesAHookEvidencedPaneAlone() throws {
        try loadTwoRules()
        let pane = try addPane()
        registry.apply(hook("PermissionRequest", tool: "Bash"), pane: pane.id,
                       origin: NoticeOrigin(lineageRoot: 1))
        XCTAssertEqual(center.counts.total, 1)

        now += 1
        let outcome = registry.apply(.processes([]), pane: pane.id)
        XCTAssertFalse(outcome.changed)
        XCTAssertEqual(outcome.resolved, 0)
        XCTAssertEqual(registry.status(pane: pane.id)?.state, .blocked)
        XCTAssertEqual(center.counts.total, 1, "the alarm is the scan's to resolve only if it saw it")
    }

    /// One pane, two agents — a `claude` started from inside a `codex` session. The two presences
    /// stay apart, so one leaving is not the other leaving.
    func testTwoRulesInOnePaneKeepSeparatePresences() throws {
        try loadTwoRules()
        let pane = try addPane()
        let both: AgentPresence = ["demo": [10], "other": [20]]
        XCTAssertEqual(both.pids(for: "demo"), [10])
        XCTAssertEqual(both.pids(for: "other"), [20])

        // Nothing is known about the pane, so the first enabled rule the pass found there says so.
        registry.apply(.processes(both), pane: pane.id)
        XCTAssertEqual(registry.status(pane: pane.id)?.agent, "demo")
        XCTAssertEqual(registry.status(pane: pane.id)?.state, .unknown)

        // `other` leaving is not `demo` leaving.
        now += 1
        registry.apply(.processes(["demo": [10]]), pane: pane.id)
        XCTAssertEqual(registry.status(pane: pane.id)?.agent, "demo")
        XCTAssertEqual(registry.status(pane: pane.id)?.state, .unknown)

        // `demo` leaving is, even though `other` is still running: the pane's own agent is gone,
        // and `other` becomes the pane's agent on the next pass rather than in this transition.
        now += 1
        registry.apply(.processes(["other": [20]]), pane: pane.id)
        XCTAssertNil(registry.status(pane: pane.id))
        now += 1
        registry.apply(.processes(["other": [20]]), pane: pane.id)
        XCTAssertEqual(registry.status(pane: pane.id)?.agent, "other")
    }

    /// A finished turn is information, and only when `[notifications] done` says so.
    func testDoneInfoPostIsGatedByTheSetting() throws {
        let pane = try addPane()
        registry.apply(hook("PreToolUse", tool: "Bash"), pane: pane.id)
        now += 1
        registry.apply(hook("Stop"), pane: pane.id)
        XCTAssertEqual(sink.posted.filter { $0.urgency == .info }.count, 1)
        XCTAssertEqual(center.counts.total, 0, "an info notice never counts toward the badge")

        var settings = center.settings
        settings.done = false
        center.settings = settings
        now += 1
        registry.apply(hook("PreToolUse", tool: "Bash"), pane: pane.id)
        now += 1
        registry.apply(hook("Stop"), pane: pane.id)
        XCTAssertEqual(sink.posted.filter { $0.urgency == .info }.count, 1, "switched off, so nothing more")
    }

    /// An error is an alarm too, and its title carries the error **type**, never its text.
    func testErrorPostsAnAlarmNamingTheType() throws {
        let pane = try addPane()
        let outcome = registry.apply(hook("StopFailure", error: "api_error"), pane: pane.id,
                                     origin: NoticeOrigin(lineageRoot: 3))
        let id = try XCTUnwrap(outcome.noticePosted)
        XCTAssertTrue(try XCTUnwrap(center.notice(id: id)).title.contains("api_error"))
        XCTAssertEqual(center.counts.total, 1)
    }

    // MARK: Events

    func testOneEventPerChangeAndNoneForAMessageOnlyChange() throws {
        let pane = try addPane()
        let mark = ControlEventBus.shared.seq
        registry.apply(hook("PreToolUse", tool: "Bash", command: "npm test"), pane: pane.id)
        var events = agentEvents(since: mark)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.agent, "demo")
        XCTAssertEqual(events.first?.state, "working")
        XCTAssertEqual(events.first?.detail, "tool")
        XCTAssertEqual(events.first?.tool, "Bash")
        XCTAssertEqual(events.first?.evidence, "hook")
        XCTAssertEqual(events.first?.message, "npm test")
        XCTAssertEqual(events.first?.paneID, pane.id.uuidString)

        // The same state and tool, a different command line: nothing to wake anybody for.
        now += 1
        registry.apply(hook("PreToolUse", tool: "Bash", command: "npm run build"), pane: pane.id)
        events = agentEvents(since: mark)
        XCTAssertEqual(events.count, 1, "a message-only change emits nothing")

        // A released agent is reported as released, not as its last state.
        now += 1
        registry.apply(hook("SessionEnd"), pane: pane.id)
        events = agentEvents(since: mark)
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events.last?.state, "released")
        XCTAssertNil(events.last?.message)
    }

    /// The agent's own words follow the browser-URL rule, exactly like a notice body.
    func testTheMessageIsRedactedForATokenlessCaller() throws {
        let pane = try addPane()
        let mark = ControlEventBus.shared.seq
        registry.apply(hook("PreToolUse", tool: "Bash", command: "npm test"), pane: pane.id)
        ControlEventBus.shared.flush()
        let redacted = ControlEventBus.shared
            .batch(since: mark, limit: ControlEventLimits.maxBatch, types: nil, exposesBrowser: false)
            .events.filter { $0.type == ControlEventType.agentStateChanged.rawValue }
        XCTAssertEqual(redacted.first?.message, ControlEvent.redactedPlaceholder)
        XCTAssertEqual(redacted.first?.tool, "Bash", "a tool name is payload-free and stays readable")
        XCTAssertEqual(redacted.first?.state, "working")
    }

    // MARK: The redraw bounds (plan §1.5)

    /// 200 tool hooks, and the notification centre is never touched. This is the bound that makes
    /// `hook-detail = "tools"` affordable: `live` mutating would re-evaluate every mounted pane's
    /// body, because `PaneChrome` and `StatusBarView` both observe the centre.
    func testToolHooksNeverTouchTheCentre() throws {
        let pane = try addPane()
        var published = 0
        center.objectWillChange.sink { _ in published += 1 }.store(in: &bag)
        let liveBefore = center.live
        let mark = ControlEventBus.shared.seq

        for index in 0..<200 {
            now += 0.1
            registry.apply(hook(index.isMultiple(of: 2) ? "PreToolUse" : "PostToolUse", tool: "Bash"),
                           pane: pane.id)
        }
        XCTAssertEqual(published, 0, "a tool-tier hook must never publish from the centre")
        XCTAssertEqual(center.live, liveBefore)
        XCTAssertTrue(sink.changes.isEmpty)
        // The events are still emitted — the bound is about the centre, not about the wire.
        XCTAssertEqual(agentEvents(since: mark).count, 200)
    }

    /// One pane's agent churning redraws one pane.
    func testStatusRedrawsOnlyItsPane() throws {
        let first = try addPane()
        let second = try addPane()
        var others = 0
        var centreChanges = 0
        second.view.objectWillChange.sink { _ in others += 1 }.store(in: &bag)
        center.objectWillChange.sink { _ in centreChanges += 1 }.store(in: &bag)

        for index in 0..<50 {
            now += 0.1
            registry.apply(hook("PreToolUse", tool: "tool\(index)"), pane: first.id)
        }
        XCTAssertEqual(others, 0, "the neighbouring pane must not redraw")
        XCTAssertEqual(centreChanges, 0)
        XCTAssertEqual(registry.status(pane: first.id)?.tool, "tool49")
        XCTAssertNil(registry.status(pane: second.id))
    }

    /// The pane is where the status lives, so the strip can observe its own pane.
    func testTheStatusIsWrittenOntoThePane() throws {
        let pane = try addPane()
        registry.apply(hook("PreToolUse", tool: "Bash"), pane: pane.id)
        XCTAssertEqual(pane.view.agentStatus?.tool, "Bash")
        now += 1
        registry.apply(hook("SessionEnd"), pane: pane.id)
        XCTAssertNil(pane.view.agentStatus)
    }

    // MARK: Switches and the engine seam

    func testDetectOffIgnoresEverything() throws {
        let pane = try addPane()
        registry.settings.detect = false
        let outcome = registry.apply(hook("PermissionRequest", tool: "Bash"), pane: pane.id)
        XCTAssertFalse(outcome.changed)
        XCTAssertNil(registry.status(pane: pane.id))
        XCTAssertTrue(center.live.isEmpty)
    }

    func testARuleThatIsNotEnabledIsInert() throws {
        let pane = try addPane()
        registry.settings.enabled = ["something-else"]
        XCTAssertFalse(registry.apply(hook("PermissionRequest"), pane: pane.id).changed)
        XCTAssertNil(registry.status(pane: pane.id))
    }

    /// The engine's ear: a notification a rule consumes belongs to the registry, and while a
    /// pane's status rests on a hook the engine posts nothing of its own.
    func testObserveEngineAndMuting() throws {
        let pane = try addPane()
        XCTAssertEqual(registry.observeEngine(pane: pane.id, .notification(title: "Something else",
                                                                          body: "hi")),
                       .ignored)
        XCTAssertFalse(registry.mutesEngineNotices(pane: pane.id))

        XCTAssertEqual(registry.observeEngine(pane: pane.id,
                                              .notification(title: "Demo needs your permission",
                                                            body: "may I?")),
                       .consumed)
        XCTAssertFalse(registry.mutesEngineNotices(pane: pane.id),
                       "a notification-evidenced status does not mute the engine")

        now += 1
        registry.apply(hook("PreToolUse", tool: "Bash"), pane: pane.id)
        XCTAssertTrue(registry.mutesEngineNotices(pane: pane.id))
    }

    /// A hook asks for a scan; `commandFinished` asks for one and nothing else.
    func testScanTriggerSeam() throws {
        let pane = try addPane()
        var scans = 0
        registry.scanTrigger = { scans += 1 }
        registry.apply(hook("PreToolUse", tool: "Bash"), pane: pane.id)
        XCTAssertEqual(scans, 1)
        XCTAssertEqual(registry.observeEngine(pane: pane.id, .commandFinished), .ignored)
        XCTAssertEqual(scans, 2)
    }

    /// A pane that closed takes its status with it — through the centre, as an ordinary sink.
    func testPaneClosedDropsTheStatus() throws {
        let pane = try addPane()
        center.addSink(registry)
        registry.apply(hook("PermissionRequest", tool: "Bash"), pane: pane.id,
                       origin: NoticeOrigin(lineageRoot: 1))
        locator.entries[pane.id] = nil
        center.flushActivityPass()
        XCTAssertNil(registry.status(pane: pane.id))
        XCTAssertEqual(center.history.last?.resolution, .paneClosed)
    }
}
