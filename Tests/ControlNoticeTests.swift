import XCTest
@testable import QuickTerm

/// **The control plane's half of the notification centre** (spec §10.9, test list §10.11 (D)).
///
/// What these cases are really guarding is one promise made to agents: *before you interrupt the
/// human, you can find out whether somebody else already has.* That promise is only worth
/// anything if `notices list` sees what the centre sees, if `ack` really silences the pane and
/// says so out loud, and if a caller without this launch's token cannot read the program text a
/// notice body carries.
///
/// Everything runs through `ControlHarness` (the runner directly, no socket) and the **shared**
/// notification centre attached to the test host's real screens — the same wiring the app builds
/// in `AppDelegate`, so a pane handle, a screen index and a workspace number all mean here what
/// they mean in production.
@MainActor
final class ControlNoticeTests: XCTestCase {
    private var harness: ControlHarness!
    private var center: NoticeCenter { NoticeCenter.shared }

    override func setUpWithError() throws {
        try super.setUpWithError()
        harness = try ControlHarness()
        // The app installs these two in `applicationDidFinishLaunching`; the test host may or may
        // not have got there yet (the wiring lands with the system-notification sink), so install
        // exactly what is missing. `addSink` refuses a duplicate id, and `resetForTesting` keeps
        // sinks registered, so this is safe to run for every case.
        center.attach(locator: NoticeLocator(screens: harness.app.screens))
        if center.sink(id: NoticeSinkID.controlPlane) == nil { center.addSink(ControlPlaneSink()) }
        if center.sink(id: NoticeSinkID.activityLog) == nil { center.addSink(ActivityLogSink()) }
        center.settings = NoticeSettings()
        center.resetForTesting()
        ControlActivityLog.shared.clear()
    }

    override func tearDown() {
        center.resetForTesting()
        harness?.cleanup()
        harness = nil
        super.tearDown()
    }

    // MARK: Helpers

    private func handle(_ pane: PaneView) -> String { ControlHandleRegistry.shared.handle(for: pane) }

    @discardableResult
    private func post(_ pane: PaneView, _ urgency: NoticeUrgency = .needsUser,
                      source: NoticeSource = .agent("claude-code"),
                      title: String = "Claude Code · Awaiting approval · Bash",
                      body: String? = "rm -rf build") -> NoticeCenter.PostOutcome {
        center.post(NoticeRequest(source: source, pane: pane.id, urgency: urgency,
                                  evidence: .hook, title: title, body: body))
    }

    private func notices(_ reply: ControlReply) throws -> [[String: JSONValue]] {
        reply.assertOK()
        return try XCTUnwrap(reply.data?["notices"]?.arrayValue).compactMap(\.objectValue)
    }

    /// The pane record `state` reports for this pane.
    private func statePane(_ pane: PaneView, token: String? = nil) throws -> [String: JSONValue] {
        let reply = try harness.run("state", token: token)
        reply.assertOK()
        let panes = try XCTUnwrap(reply.data?["panes"]?.arrayValue).compactMap(\.objectValue)
        return try XCTUnwrap(panes.first { $0["handle"]?.stringValue == handle(pane) },
                             "the pane is not in state at all")
    }

    // MARK: notices list

    /// Scoping and `--needs-user`. The default is the **whole session** on purpose: "is anyone
    /// waiting for the user, anywhere" is the question, and a default that silently narrowed to
    /// the focused workspace would answer "no" while another screen held a prompt.
    func testListScopesByTargetAndFiltersNeedsUser() throws {
        let waiting = try harness.newTerminal()
        let chatty = try harness.newTerminal()
        post(waiting)
        post(chatty, .info, source: .command, title: "Command finished", body: "took 42s, exit 0")

        let all = try notices(harness.run("notices.list"))
        XCTAssertEqual(Set(all.compactMap { $0["pane"]?.stringValue }),
                       [handle(waiting), handle(chatty)])

        let reply = try harness.run("notices.list", args: ["needs-user": .bool(true)])
        let urgent = try notices(reply)
        XCTAssertEqual(urgent.count, 1, "--needs-user keeps only the panes a human has to go to")
        XCTAssertEqual(urgent.first?["pane"]?.stringValue, handle(waiting))
        XCTAssertEqual(urgent.first?["urgency"]?.stringValue, "needs-user")
        XCTAssertEqual(urgent.first?["source"]?.stringValue, "agent:claude-code")
        XCTAssertEqual(urgent.first?["evidence"]?.stringValue, "hook")
        // **Panes, not notices**, and it is not derived from the rows: the filter above threw the
        // info row away, and this number still answers "how many panes are waiting".
        XCTAssertEqual(reply.data?["panesNeedingUser"]?.intValue, 1)
        XCTAssertEqual(reply.data?["schema"]?.stringValue, "quickterm.notices/1")

        // One pane
        let scoped = try notices(harness.run("notices.list", target: handle(chatty)))
        XCTAssertEqual(scoped.map { $0["pane"]?.stringValue }, [handle(chatty)])

        // A workspace that holds neither of them
        let controller = try harness.controller
        let elsewhere = controller.model.activeIndex == 0 ? 2 : 1
        let empty = try harness.run("notices.list",
                                    target: "\(controller.screenIndex + 1):\(elsewhere)")
        XCTAssertEqual(try notices(empty).count, 0)
        XCTAssertEqual(empty.data?["panesNeedingUser"]?.intValue, 0)
    }

    /// `--history` brings the resolved ring back, and it never joins `--needs-user`: a prompt that
    /// was answered ten minutes ago is not somebody waiting.
    func testHistoryReturnsResolvedNoticesAndNeverAnswersNeedsUser() throws {
        let pane = try harness.newTerminal()
        post(pane)
        try harness.run("notices.ack", target: handle(pane)).assertOK()

        XCTAssertEqual(try notices(harness.run("notices.list")).count, 0)
        let history = try notices(harness.run("notices.list", args: ["history": .bool(true)]))
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history.first?["resolution"]?.stringValue, "acknowledged")
        XCTAssertNotNil(history.first?["resolvedAt"]?.stringValue)

        let needsUser = try harness.run("notices.list", args: ["needs-user": .bool(true),
                                                              "history": .bool(true)])
        XCTAssertEqual(try notices(needsUser).count, 0)
        XCTAssertEqual(needsUser.data?["panesNeedingUser"]?.intValue, 0)
    }

    /// **Whether the user could have been told at all.**
    ///
    /// `panesNeedingUser: 0` used to be the only answer an agent could read, and it meant two
    /// completely different things: nobody is waiting, or macOS has QuickTerm's notifications
    /// switched off and every banner this launch posted was thrown away. This field separates
    /// them, and the pane-less hint beside it is what the *human* reads.
    func testListReportsWhetherMacOSWillShowBannersAtAll() throws {
        AppDelegate.ensureNoticeInterfaceInstalled()
        let sink = try XCTUnwrap(center.systemSink)
        let before = sink.authorizationStatus
        defer { sink.noteAuthorization(before) }

        // The test host's notification centre is inert, so nobody has been able to ask macOS
        // anything — `unavailable`, which is deliberately not `denied`.
        let quiet = try harness.run("notices.list")
        quiet.assertOK()
        XCTAssertEqual(quiet.data?["systemNotifications"]?.stringValue, "unavailable")
        XCTAssertNil(quiet.data?["appNotices"],
                     "nothing to say about the app: the field is absent, not an empty array")

        sink.noteAuthorization(.denied)

        let reply = try harness.run("notices.list")
        reply.assertOK()
        XCTAssertEqual(reply.data?["systemNotifications"]?.stringValue, "denied")
        let app = try XCTUnwrap(reply.data?["appNotices"]?.arrayValue).compactMap(\.objectValue)
        XCTAssertEqual(app.count, 1, "one hint per launch")
        XCTAssertEqual(app.first?["source"]?.stringValue, "custom:system")
        XCTAssertEqual(app.first?["urgency"]?.stringValue, "info")
        XCTAssertEqual(app.first?["title"]?.stringValue, L("notice.system.denied"))
        XCTAssertNil(app.first?["pane"], "it belongs to no pane, and says so by not naming one")
        // The status is a property of the app, so narrowing the call must not narrow it away.
        let scoped = try harness.run("notices.list", args: ["needs-user": .bool(true)])
        XCTAssertEqual(scoped.data?["systemNotifications"]?.stringValue, "denied")
        // And the record carries it too — the panel the user can open, plus the OSLog mirror.
        XCTAssertTrue(
            ControlActivityLog.shared.recent().contains {
                $0.command == SystemNotificationSink.deniedCommand
            },
            "a silent failure the user is never told about is the whole bug")
    }

    // MARK: Redaction

    /// **The body is a program's own words; the title is not.**
    ///
    /// A notice body carries what the agent was asked to run (`rm -rf build`) or whatever text an
    /// OSC 777 handed over, so it follows the browser-URL rule everywhere it appears — `notices
    /// list`, the pane record in `state`, and the event stream. The title beside it is composed by
    /// QuickTerm out of an agent id, a state and a tool *name*, and stays readable: it is the one
    /// sentence that lets a token-less caller decide whether to interrupt the user at all.
    func testTheBodyIsRedactedWithoutTheTokenEverywhereItAppears() throws {
        let pane = try harness.newTerminal()
        let mark = harness.seq
        post(pane)

        for token in [nil, ControlEnvironment.token] {
            let trusted = token != nil
            let row = try XCTUnwrap(notices(harness.run("notices.list", token: token)).first)
            XCTAssertEqual(row["title"]?.stringValue, "Claude Code · Awaiting approval · Bash",
                           "the title is payload-free by construction and is never redacted")
            XCTAssertEqual(row["body"]?.stringValue,
                           trusted ? "rm -rf build" : ControlStateEncoder.redacted)
            XCTAssertEqual(row["redacted"]?.boolValue, trusted ? nil : true,
                           "say so when something was withheld, or the caller believes the body "
                               + "really reads <redacted>")

            let statePaneRecord = try statePane(pane, token: token)
            let stateRow = try XCTUnwrap(statePaneRecord["notices"]?.arrayValue?.first?.objectValue)
            XCTAssertEqual(stateRow["body"]?.stringValue,
                           trusted ? "rm -rf build" : ControlStateEncoder.redacted,
                           "state must not be a way around the rule notices list applies")
        }

        // The event stream is the third door into the same text.
        let exposed = ControlEventBus.shared.batch(since: mark, limit: ControlEventLimits.maxBatch,
                                                   types: nil, exposesBrowser: true).events
        let hidden = ControlEventBus.shared.batch(since: mark, limit: ControlEventLimits.maxBatch,
                                                  types: nil, exposesBrowser: false).events
        XCTAssertEqual(exposed.first { $0.type == "notice.posted" }?.body, "rm -rf build")
        let redacted = try XCTUnwrap(hidden.first { $0.type == "notice.posted" })
        XCTAssertEqual(redacted.body, ControlEvent.redactedPlaceholder)
        XCTAssertEqual(redacted.title, "Claude Code · Awaiting approval · Bash",
                       "redaction covers the body; a notice title carries no payload")
        XCTAssertEqual(redacted.redacted, true)
    }

    // MARK: notices ack

    /// `ack` resolves as `acknowledged`, flashes the status bar, writes the activity log, and the
    /// second call has nothing left to do — the ordinary shape of every absolute setter in the
    /// noun-verb layer, which is what makes it safe for an agent to retry.
    func testAckResolvesFlashesLogsAndIsANoopTheSecondTime() throws {
        let pane = try harness.newTerminal()
        post(pane)
        try harness.controller.model.controlFlash = nil

        let first = try harness.mutation(harness.run("notices.ack", target: handle(pane)))
        XCTAssertEqual(first["applied"]?.boolValue, true)
        XCTAssertEqual(first["changed"]?.boolValue, true)
        XCTAssertEqual(first["changes"]?.arrayValue?.first?["path"]?.stringValue,
                       "notices.\(handle(pane))")
        XCTAssertEqual(first["changes"]?.arrayValue?.first?["to"]?.stringValue, "0")
        XCTAssertNil(first["undo"], "a notice is not layout: Cmd+Z must not put an alarm back")
        XCTAssertTrue(center.live(pane: pane.id).isEmpty)
        XCTAssertEqual(center.history.last?.resolution, .acknowledged)
        // `mutate` commands run silently, and **visibility is the condition on which they may**.
        XCTAssertNotNil(try harness.controller.model.controlFlash,
                        "acknowledging somebody else's alarm has to be visible on screen")

        let second = try harness.mutation(harness.run("notices.ack", target: handle(pane)))
        XCTAssertEqual(second["changed"]?.boolValue, false)
        XCTAssertEqual(second["applied"]?.boolValue, false)

        let failing = try harness.run("notices.ack", target: handle(pane),
                                      args: [ControlCommandTable.Flag.failIfNoop: .bool(true)])
        XCTAssertEqual(failing.error?.code, ControlErrorCode.noop.rawValue)
        XCTAssertEqual(failing.error?.exit, ControlExit.noop.rawValue)
    }

    /// **`ack` never defaults to the focused pane.** Everywhere else an omitted pane means "the
    /// focused one"; here that default would throw away the alarm of whichever pane an agent's
    /// last command happened to leave focused.
    func testAckRefusesATargetThatDoesNotNameAPane() throws {
        let pane = try harness.newTerminal()
        post(pane)

        for target in [nil, String("\(try harness.controller.screenIndex + 1)")] {
            let reply = try harness.run("notices.ack", target: target)
            XCTAssertEqual(reply.error?.code, ControlErrorCode.badRequest.rawValue,
                           "ack without a pane has to be refused, not applied to whatever has focus")
            XCTAssertNotNil(reply.error?.hint)
        }
        XCTAssertEqual(center.live(pane: pane.id).count, 1, "nothing may have been resolved")
    }

    // MARK: Events

    /// `notice.posted` / `notice.resolved` carry the fields an agent branches on, and `seq` moves
    /// with them — otherwise a poller that saw the seq before the post would never come back.
    func testNoticeEventsCarryTheFieldsAndAdvanceSeq() throws {
        let pane = try harness.newTerminal()
        let controller = try harness.controller
        let mark = harness.seq
        post(pane)
        XCTAssertGreaterThan(harness.seq, mark, "a notice is a state change; seq has to move")

        let posted = try XCTUnwrap(harness.events(since: mark).first { $0.type == "notice.posted" })
        XCTAssertEqual(posted.pane, handle(pane))
        XCTAssertEqual(posted.paneID, pane.id.uuidString)
        XCTAssertEqual(posted.screen, controller.screenIndex + 1)
        XCTAssertEqual(posted.screenID, controller.windowID.uuidString)
        XCTAssertEqual(posted.workspace, controller.model.activeIndex + 1)
        XCTAssertEqual(posted.source, "agent:claude-code")
        XCTAssertEqual(posted.urgency, "needs-user")
        XCTAssertEqual(posted.title, "Claude Code · Awaiting approval · Bash")
        XCTAssertNotNil(posted.noticeID)
        XCTAssertNil(posted.resolution)

        let afterPost = harness.seq
        try harness.run("notices.ack", target: handle(pane)).assertOK()
        let resolved = try XCTUnwrap(harness.events(since: afterPost)
            .first { $0.type == "notice.resolved" })
        XCTAssertEqual(resolved.noticeID, posted.noticeID, "the pair has to be matchable by id")
        XCTAssertEqual(resolved.resolution, "acknowledged")
        XCTAssertEqual(resolved.pane, handle(pane))
    }

    /// A supersession is **two** events in one order: the prompt that is no longer being asked
    /// resolves, then the new one is posted. A subscriber that only heard the second would keep a
    /// dead id for ever.
    func testSupersessionResolvesTheOldNoticeBeforePostingTheNew() throws {
        let pane = try harness.newTerminal()
        post(pane, title: "Awaiting approval · Bash")
        let mark = harness.seq
        post(pane, title: "Awaiting approval · Write")

        let events = harness.events(since: mark).filter { ControlEventType.isNotice($0.type) }
        XCTAssertEqual(events.map(\.type), ["notice.resolved", "notice.posted"])
        XCTAssertEqual(events.first?.resolution, "superseded")
        XCTAssertEqual(events.last?.title, "Awaiting approval · Write")
    }

    // MARK: state

    /// `state` answers the same question twice, at the two altitudes a caller reads it from: the
    /// pane record says "this one is waiting", the workspace says how many of its panes are.
    func testStateCarriesTheNoticeFieldsOnPanesAndWorkspaces() throws {
        let pane = try harness.newTerminal()
        let controller = try harness.controller
        let workspace = controller.model.activeIndex

        let before = try statePane(pane)
        XCTAssertNil(before["notices"], "a pane with nothing pending returns the bytes it always did")
        XCTAssertNil(before["needsUser"])
        XCTAssertNil(before["urgency"])

        post(pane)
        let after = try statePane(pane, token: ControlEnvironment.token)
        XCTAssertEqual(after["needsUser"]?.boolValue, true)
        XCTAssertEqual(after["urgency"]?.stringValue, "needs-user")
        XCTAssertEqual(after["notices"]?.arrayValue?.count, 1)

        // Two notices on one pane are still **one** pane waiting.
        post(pane, .info, source: .terminal, title: "Build finished", body: nil)
        let reply = try harness.run("state", token: ControlEnvironment.token)
        let screens = try XCTUnwrap(reply.data?["screens"]?.arrayValue)
        let row = try XCTUnwrap(screens.compactMap(\.objectValue)
            .first { $0["id"]?.stringValue == controller.windowID.uuidString })
        let ws = try XCTUnwrap(row["workspaces"]?.arrayValue?.compactMap(\.objectValue)
            .first { $0["index"]?.intValue == workspace + 1 })
        XCTAssertEqual(ws["needsUser"]?.intValue, 1,
                       "the pill counts panes waiting for the user, not notices")

        try harness.run("notices.ack", target: handle(pane)).assertOK()
        let cleared = try statePane(pane)
        XCTAssertNil(cleared["notices"])
        XCTAssertNil(cleared["needsUser"])
    }

    // MARK: The activity log

    /// Silent commands are only defensible if they stay visible afterwards. A `needs-user` notice
    /// and every resolution of one go into the log — and **the body never reaches the OSLog
    /// mirror**, which lands in /var/db/diagnostics, is readable by any admin and outlives the app.
    func testTheActivityLogRecordsNoticesAndNeverWritesABody() throws {
        let pane = try harness.newTerminal()
        post(pane)
        try harness.run("notices.ack", target: handle(pane)).assertOK()

        let entries = ControlActivityLog.shared.entries
        let posted = try XCTUnwrap(entries.first { $0.command == ActivityLogSink.postCommand })
        XCTAssertEqual(posted.target, handle(pane))
        XCTAssertTrue(posted.line.contains("Claude Code"), "the panel shows the user the title")
        let resolved = try XCTUnwrap(entries.first { $0.command == ActivityLogSink.resolveCommand })
        XCTAssertEqual(resolved.outcome, NoticeResolution.acknowledged.rawValue)
        XCTAssertTrue(entries.contains { $0.command == "notices.ack" },
                      "the command itself is logged by commit(), the way every mutation is")

        for entry in entries {
            XCTAssertFalse(entry.logLine.contains("rm -rf build"),
                           "a notice body must never reach the OSLog mirror: \(entry.logLine)")
        }
    }

    /// An `info` notice is **not** logged: the ring holds 200 entries and exists to answer "who
    /// changed something behind my back". Every finished command and every OSC notification would
    /// push the real mutations out of it within a minute; the event stream carries those.
    func testInfoNoticesStayOutOfTheActivityLog() throws {
        let pane = try harness.newTerminal()
        post(pane, .info, source: .command, title: "Command finished", body: nil)
        XCTAssertFalse(ControlActivityLog.shared.entries
            .contains { $0.command == ActivityLogSink.postCommand })
    }

    // MARK: The generated surfaces

    /// The commands exist in the one table everything else is generated from, and the MCP tool
    /// covers both of them — an agent that only speaks MCP has to be able to ask the question too.
    func testTheCommandTableAndTheMCPToolCoverBothVerbs() throws {
        let list = try XCTUnwrap(ControlCommandTable.command("notices.list"))
        XCTAssertEqual(list.cls, .read)
        XCTAssertTrue(list.acceptsTarget)
        XCTAssertFalse(list.honorsMutationFlags, "a read has no diff to rehearse")
        let ack = try XCTUnwrap(ControlCommandTable.command("notices.ack"))
        XCTAssertEqual(ack.cls, .mutate)
        XCTAssertTrue(ack.idempotent)
        XCTAssertTrue(ack.honorsMutationFlags, "--fail-if-noop is how an agent learns nothing was live")

        let tool = try XCTUnwrap(MCPToolMap.tool(named: "quickterm_notices"))
        XCTAssertEqual(Set(tool.commandNames), ["notices.list", "notices.ack"])
        XCTAssertFalse(tool.readOnlyHint, "one of the two changes something")
        XCTAssertFalse(tool.destructiveHint)
        XCTAssertTrue(tool.idempotentHint)
        XCTAssertEqual(MCPToolMap.tool(forCommand: "notices.list")?.name, "quickterm_notices")

        // describe is generated from the same tables, so the two event types have to be in it.
        let document = ControlDescribeDocument.make(cliVersion: "x", appVersion: "x",
                                                    socket: nil, mode: "ask")
        let types = Set(document.events.map(\.type))
        XCTAssertTrue(types.isSuperset(of: ["notice.posted", "notice.resolved"]))
        XCTAssertTrue(document.commands.contains { $0.name == "notices.list" })
    }

    /// The two payload fields the plain renderer keys off have to be **absent** when there is
    /// nothing to mark: that is what keeps `quickterm list panes` looking exactly as it always did
    /// for a session nobody is waiting on (`CLI/Render.swift` adds its `!` column only when some
    /// row carries `needsUser`).
    ///
    /// The renderer itself lives in the `quickterm` tool target, which the test bundle does not
    /// link — so what is pinned here is the contract between the two: the encoder's silence.
    func testTheEncoderStaysSilentWhenNothingIsWaiting() throws {
        let pane = try harness.newTerminal()
        let quiet = try statePane(pane)
        XCTAssertNil(quiet["needsUser"])
        XCTAssertNil(quiet["urgency"])
        XCTAssertNil(quiet["notices"])

        post(pane, .info, source: .command, title: "Command finished", body: nil)
        let info = try statePane(pane)
        XCTAssertNil(info["needsUser"], "an info notice is not somebody waiting for the user")
        XCTAssertEqual(info["urgency"]?.stringValue, "info")
        XCTAssertEqual(info["notices"]?.arrayValue?.count, 1)
    }
}
