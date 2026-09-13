import AppKit
import XCTest
@testable import QuickTerm

// MARK: - Fixtures

/// A locator that answers from a dictionary.
///
/// This is what makes the whole notification centre testable without arranging windows: every
/// rule in `NoticeCenter` — coalescing, the counts split across screens and workspaces, all six
/// resolutions, the activity pass — is expressed in terms of "where is this pane" and "is the
/// user looking at it", and both questions come through this one protocol.
///
/// `NoticeLocator.Located` does carry a real `PaneView` and a real `MainWindowController`, so the
/// entries are built from the test host's own screen; only `workspace` and `activity` are made up.
@MainActor
final class NoticeLocatorStub: NoticeLocating {
    struct Entry {
        var pane: PaneView
        var controller: MainWindowController
        var workspace: Int
        var activity: PaneActivity
    }

    /// Removing an entry is how a test says "this pane is gone".
    var entries: [UUID: Entry] = [:]

    func locate(_ pane: UUID) -> NoticeLocator.Located? {
        entries[pane].map {
            NoticeLocator.Located(pane: $0.pane, controller: $0.controller, workspace: $0.workspace)
        }
    }

    /// nil exactly when `locate` is nil — the contract, and what rule 4 keys off.
    func activity(_ pane: UUID) -> PaneActivity? { entries[pane]?.activity }

    func handle(_ pane: UUID) -> String? {
        entries[pane] == nil ? nil : "t\(pane.uuidString.prefix(2))"
    }
}

/// A sink that writes down what it is told. `inspect` runs inside `apply`, which is how the
/// "callbacks see a consistent world" case reads `live` / `counts` at the exact moment a sink does.
@MainActor
final class NoticeRecordingSink: NoticeSink {
    let sinkID: String
    var isEnabled = true
    private(set) var changes: [NoticeChange] = []
    private(set) var clearAllCount = 0
    var inspect: ((NoticeChange) -> Void)?

    init(sinkID: String) { self.sinkID = sinkID }

    func apply(_ change: NoticeChange) {
        changes.append(change)
        inspect?(change)
    }

    func clearAll() { clearAllCount += 1 }

    func reset() { changes.removeAll() }

    var posted: [Notice] {
        changes.compactMap { if case .posted(let notice, _, _) = $0 { notice } else { nil } }
    }

    var resolved: [Notice] {
        changes.compactMap { if case .resolved(let notice, _, _) = $0 { notice } else { nil } }
    }

    var supersededOld: [Notice] {
        changes.compactMap { if case .superseded(let old, _, _, _) = $0 { old } else { nil } }
    }

    var transitions: [PaneTransition] {
        changes.compactMap {
            switch $0 {
            case .posted(_, let t, _), .resolved(_, let t, _), .superseded(_, _, let t, _): t
            default: nil
            }
        }
    }

    var countsChanges: [NoticeCounts] {
        changes.compactMap { if case .countsChanged(let counts) = $0 { counts } else { nil } }
    }

    var activityChanges: [(UUID, PaneActivity)] {
        changes.compactMap {
            if case .activityChanged(let pane, let activity) = $0 { (pane, activity) } else { nil }
        }
    }
}

// MARK: - The centre

/// The notification centre (spec §3.5, contract §10.3 and the test list in §10.11).
@MainActor
final class NoticeCenterTests: XCTestCase {
    private var app: AppDelegate {
        get throws { try XCTUnwrap(NSApp.delegate as? AppDelegate) }
    }

    private var locator = NoticeLocatorStub()
    private var center: NoticeCenter!
    private var sink: NoticeRecordingSink!
    /// A clock a case can wind forward, so "the duplicate did not touch postedAt" is a real
    /// assertion and not two reads of the same instant.
    private var now = Date(timeIntervalSince1970: 1_000_000)

    override func setUp() async throws {
        try await super.setUp()
        locator = NoticeLocatorStub()
        center = NoticeCenter(locator: locator, clock: { [self] in now })
        sink = NoticeRecordingSink(sinkID: NoticeSinkID.dockBadge)
        center.addSink(sink)
    }

    /// A pane the stub knows about. Not in any window: nothing in the centre touches the view.
    @discardableResult
    private func addPane(workspace: Int = 0, active: Bool = false,
                         controller: MainWindowController? = nil) throws -> UUID {
        let host = try controller ?? XCTUnwrap(app.screens.primary)
        let pane = PaneView(frame: .zero)
        locator.entries[pane.id] = .init(pane: pane, controller: host, workspace: workspace,
                                         activity: Self.activity(active))
        return pane.id
    }

    private static func activity(_ active: Bool) -> PaneActivity {
        PaneActivity(appActive: active, screenKey: active, workspaceVisible: active, focused: active)
    }

    private func request(_ pane: UUID, _ urgency: NoticeUrgency = .needsUser,
                         source: NoticeSource = .terminal, title: String = "Waiting for you",
                         body: String? = nil, origin: NoticeOrigin? = nil) -> NoticeRequest {
        NoticeRequest(source: source, pane: pane, urgency: urgency, evidence: .notification,
                      title: title, body: body, origin: origin)
    }

    // MARK: Coalescing

    /// An identical repost is a **no-op**: no sink hears about it, and `postedAt` does not move.
    /// This is what stops one approval prompt described by both a hook and an OSC notification
    /// from re-presenting the banner with sound twice.
    func testIdenticalRepostChangesNothing() throws {
        let pane = try addPane()
        guard case .posted(let id) = center.post(request(pane, title: "Awaiting approval")) else {
            return XCTFail("the first post has to land")
        }
        let postedAt = try XCTUnwrap(center.notice(id: id)).postedAt
        let seen = sink.changes.count
        now += 60

        XCTAssertEqual(center.post(request(pane, title: "Awaiting approval")), .duplicate(id))
        XCTAssertEqual(sink.changes.count, seen, "a duplicate must not reach a single sink")
        XCTAssertEqual(center.notice(id: id)?.postedAt, postedAt, "postedAt must not be refreshed")
        XCTAssertEqual(center.live.count, 1)
    }

    /// Same key, different words: the old one resolves as `.superseded` and the new one takes
    /// its place. A different tool is now asking, and that is a real change.
    func testDifferentContentSupersedes() throws {
        let pane = try addPane()
        guard case .posted(let first) = center.post(request(pane, title: "Awaiting approval: Bash")) else {
            return XCTFail("the first post has to land")
        }
        now += 5
        let outcome = center.post(request(pane, title: "Awaiting approval: Write"))
        guard case .superseded(let old, let new) = outcome else {
            return XCTFail("a different title under the same key has to supersede, got \(outcome)")
        }
        XCTAssertEqual(old, first)
        XCTAssertEqual(center.live.map(\.id), [new])
        XCTAssertEqual(sink.supersededOld.map(\.id), [first])
        let archived = try XCTUnwrap(center.notice(id: first))
        XCTAssertEqual(archived.resolution, .superseded)
        XCTAssertFalse(archived.isLive)
        XCTAssertEqual(center.history.map(\.id), [first])
    }

    /// **A post never lowers a pane.** An `info` while a `needsUser` is live lands under its own
    /// key, leaves the alarm alone, and moves no count.
    func testInfoDoesNotDisplaceANeedsUser() throws {
        let pane = try addPane()
        center.post(request(pane, .needsUser, source: .agent("claude-code"), title: "Awaiting approval"))
        sink.reset()

        center.post(request(pane, .info, source: .command, title: "Command finished"))

        XCTAssertEqual(center.live(pane: pane).count, 2)
        XCTAssertEqual(center.urgency(pane: pane), .needsUser)
        XCTAssertEqual(center.counts.total, 1)
        XCTAssertTrue(sink.countsChanges.isEmpty, "an info post moves no count")
        XCTAssertEqual(sink.transitions.map(\.raised), [false],
                       "the pane was already at needsUser: nothing was raised")
    }

    /// The other direction does raise, and that is what an alerting sink reacts to.
    func testNeedsUserAfterInfoRaisesThePane() throws {
        let pane = try addPane()
        center.post(request(pane, .info, source: .command, title: "Command finished"))
        sink.reset()

        center.post(request(pane, .needsUser, source: .agent("codex"), title: "Awaiting approval"))

        let transition = try XCTUnwrap(sink.transitions.first)
        XCTAssertEqual(transition.before, .info)
        XCTAssertEqual(transition.after, .needsUser)
        XCTAssertTrue(transition.raised)
        XCTAssertFalse(transition.cleared)
        XCTAssertEqual(sink.countsChanges.last?.total, 1)
    }

    /// A pane that cannot be located is not addressable: nothing is stored and no sink is called.
    func testUnknownPaneStoresNothing() {
        XCTAssertEqual(center.post(request(UUID())), .unknownPane)
        XCTAssertTrue(center.live.isEmpty)
        XCTAssertTrue(sink.changes.isEmpty)
    }

    // MARK: Counts

    /// Counts are **panes**, not notices, and they split by screen and by workspace.
    func testCountsArePanesAndSplitByWorkspace() throws {
        let controller = try XCTUnwrap(app.screens.primary)
        let a = try addPane(workspace: 0)
        let b = try addPane(workspace: 1)

        center.post(request(a, source: .agent("claude-code"), title: "Awaiting approval"))
        center.post(request(a, source: .terminal, title: "Also waiting"))
        center.post(request(b, source: .terminal, title: "Waiting too"))

        XCTAssertEqual(center.counts.total, 2, "two needsUser on one pane is one pane")
        XCTAssertEqual(center.counts.count(screen: controller.windowID), 2)
        XCTAssertEqual(center.counts.count(screen: controller.windowID, workspace: 0), 1)
        XCTAssertEqual(center.counts.count(screen: controller.windowID, workspace: 1), 1)
        XCTAssertEqual(center.needsUserCount(), 2)
        XCTAssertEqual(center.needsUserCount(screen: controller.windowID, workspace: 1), 1)
        XCTAssertEqual(center.needsUserCount(screen: UUID()), 0)
    }

    /// The same, across two real screens — the number the Dock badge shows is the total, and each
    /// window's pill only ever sees its own.
    func testCountsSplitAcrossTwoScreens() throws {
        let app = try self.app
        let primary = try XCTUnwrap(app.screens.primary)
        let second = app.newScreen(on: NSScreen.main)
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        defer {
            if app.controllers.contains(where: { $0 === second }) { _ = app.closeScreen(second, confirmed: true) }
            primary.window?.makeKeyAndOrderFront(nil)
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }

        let here = try addPane(workspace: 0, controller: primary)
        let there = try addPane(workspace: 2, controller: second)
        center.post(request(here))
        center.post(request(there))

        XCTAssertEqual(center.counts.total, 2)
        XCTAssertEqual(center.counts.count(screen: primary.windowID), 1)
        XCTAssertEqual(center.counts.count(screen: second.windowID), 1)
        XCTAssertEqual(center.counts.count(screen: second.windowID, workspace: 2), 1)
        XCTAssertEqual(center.counts.count(screen: second.windowID, workspace: 0), 0)
    }

    /// The number a Dock badge would draw at 0, 1 and 12 panes. `total` is the count of panes, so
    /// the badge never has to deduplicate anything itself.
    func testTotalAtZeroOneAndTwelve() throws {
        XCTAssertEqual(center.counts.total, 0)
        let first = try addPane()
        center.post(request(first))
        XCTAssertEqual(center.counts.total, 1)
        for _ in 0..<11 { center.post(request(try addPane())) }
        XCTAssertEqual(center.counts.total, 12)
    }

    // MARK: Resolution

    /// Rule 1's guard: only the lineage that posted a notice may resolve it as `.stateChanged`.
    /// A forger can add a notice; it can never remove one.
    func testStateChangedNeedsTheOriginThatPosted() throws {
        let pane = try addPane()
        let origin = NoticeOrigin(lineageRoot: 4242, sessionID: "abc")
        guard case .posted(let id) = center.post(request(pane, origin: origin)) else {
            return XCTFail("the post has to land")
        }
        XCTAssertEqual(center.resolve(id, .stateChanged, origin: nil), .originMismatch)
        XCTAssertEqual(center.resolve(id, .stateChanged,
                                      origin: NoticeOrigin(lineageRoot: 9, sessionID: "abc")),
                       .originMismatch)
        XCTAssertEqual(center.resolve(id, .stateChanged,
                                      origin: NoticeOrigin(lineageRoot: 4242, sessionID: "other")),
                       .originMismatch)
        XCTAssertEqual(center.live.count, 1, "a refused resolution changes nothing")
        XCTAssertEqual(center.resolve(id, .stateChanged, origin: origin), .resolved)
        XCTAssertEqual(center.notice(id: id)?.resolution, .stateChanged)

        // No stored origin (every Phase 1 notice): anyone may resolve it.
        guard case .posted(let open) = center.post(request(pane, title: "No origin")) else {
            return XCTFail("the post has to land")
        }
        XCTAssertEqual(center.resolve(open, .stateChanged, origin: nil), .resolved)
    }

    /// `resolve` tells "never heard of it" and "already in the history" apart — an agent that
    /// acknowledges twice should not be told it made a mistake.
    func testResolveReportsNotFoundAndNotLive() throws {
        let pane = try addPane()
        guard case .posted(let id) = center.post(request(pane)) else { return XCTFail("post") }
        XCTAssertEqual(center.resolve(UUID(), .acknowledged), .notFound)
        XCTAssertEqual(center.resolve(id, .acknowledged), .resolved)
        XCTAssertEqual(center.resolve(id, .acknowledged), .notLive)
    }

    /// Rule 2, the body of it: typing resolves **every** urgency of that pane, and only that pane.
    func testUserDidTypeResolvesEveryUrgency() throws {
        let pane = try addPane()
        let other = try addPane()
        center.post(request(pane, .needsUser, source: .agent("claude-code"), title: "Awaiting approval"))
        center.post(request(pane, .info, source: .command, title: "Command finished"))
        center.post(request(other, .needsUser, title: "Still waiting"))

        center.userDidType(in: pane)

        XCTAssertTrue(center.live(pane: pane).isEmpty)
        XCTAssertEqual(center.live(pane: other).count, 1, "another pane's alarm is untouched")
        XCTAssertEqual(Set(center.history.compactMap(\.resolution)), [.userActed])
        XCTAssertEqual(center.counts.total, 1)
    }

    /// Rule 1 in one call, as Phase 2 will use it: only `needsUser`, only from the right lineage.
    func testAgentStateLeftNeedsUserResolvesOnlyTheAlarms() throws {
        let pane = try addPane()
        let origin = NoticeOrigin(lineageRoot: 7)
        center.post(request(pane, .needsUser, source: .agent("gemini"), title: "Awaiting approval",
                            origin: origin))
        center.post(request(pane, .info, source: .command, title: "Command finished"))

        XCTAssertEqual(center.agentStateLeftNeedsUser(pane: pane, origin: NoticeOrigin(lineageRoot: 8)), 0)
        XCTAssertEqual(center.agentStateLeftNeedsUser(pane: pane, origin: origin), 1)
        XCTAssertEqual(center.urgency(pane: pane), .info, "the info notice is not an alarm and stays")
    }

    // MARK: The activity pass

    /// `info` resolves when the user is looking at the pane; a `needsUser` does not — an approval
    /// prompt is not answered by looking at it.
    func testActivityPassResolvesInfoOnFocusOnly() throws {
        let pane = try addPane(active: false)
        center.post(request(pane, .info, source: .command, title: "Command finished"))
        center.post(request(pane, .needsUser, source: .agent("claude-code"), title: "Awaiting approval"))

        locator.entries[pane]?.activity = Self.activity(true)
        center.flushActivityPass()

        XCTAssertEqual(center.live(pane: pane).map(\.urgency), [.needsUser])
        XCTAssertEqual(center.history.last?.resolution, .paneFocused)
    }

    /// Rule 4: the pane is gone, everything it held goes with it.
    func testActivityPassResolvesEverythingWhenThePaneIsGone() throws {
        let pane = try addPane()
        center.post(request(pane, .needsUser, title: "Awaiting approval"))
        center.post(request(pane, .info, source: .command, title: "Command finished"))
        XCTAssertEqual(center.counts.total, 1)

        locator.entries[pane] = nil
        center.flushActivityPass()

        XCTAssertTrue(center.live.isEmpty)
        XCTAssertEqual(Set(center.history.compactMap(\.resolution)), [.paneClosed])
        XCTAssertEqual(center.counts.total, 0)
        XCTAssertEqual(sink.countsChanges.last?.total, 0)
    }

    /// `.activityChanged` is sent **once per real change**: the centre remembers the last
    /// activity per pane so a sink is never woken for a pass that found nothing new.
    func testActivityChangedIsReportedOncePerRealChange() throws {
        let pane = try addPane(active: false)
        center.post(request(pane, .needsUser, title: "Awaiting approval"))
        sink.reset()

        center.flushActivityPass()
        XCTAssertTrue(sink.activityChanges.isEmpty, "nothing changed since the post recorded it")

        locator.entries[pane]?.activity = PaneActivity(appActive: true, screenKey: true,
                                                       workspaceVisible: true, focused: false)
        center.flushActivityPass()
        XCTAssertEqual(sink.activityChanges.count, 1)
        XCTAssertEqual(sink.activityChanges.first?.0, pane)
        XCTAssertFalse(try XCTUnwrap(sink.activityChanges.first?.1).isActive)

        center.flushActivityPass()
        XCTAssertEqual(sink.activityChanges.count, 1, "a second identical pass says nothing")
    }

    /// A pane with nothing live is not walked at all: the pass is about notices, not panes.
    func testActivityPassIgnoresPanesWithoutNotices() throws {
        let pane = try addPane(active: true)
        center.flushActivityPass()
        XCTAssertTrue(sink.changes.isEmpty)
        XCTAssertNotNil(locator.entries[pane])
    }

    /// The coalescing: any number of `noteActivityChange`-style calls in one run-loop turn
    /// produce one pass.
    func testActivityPassIsCoalescedIntoOneTurn() throws {
        let pane = try addPane(active: false)
        center.post(request(pane, .needsUser, title: "Awaiting approval"))
        sink.reset()
        locator.entries[pane]?.activity = Self.activity(true)

        for _ in 0..<5 { center.scheduleActivityPass() }
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))

        // isActive, so the needsUser stays and exactly one activity change is reported.
        XCTAssertEqual(sink.activityChanges.count, 1)
    }

    // MARK: Sanitising, history, sinks

    /// Every sink may draw `title` and `body` without filtering again.
    func testTitleAndBodyAreSanitisedOnce() throws {
        let pane = try addPane()
        let request = NoticeRequest(source: .terminal, pane: pane, urgency: .info,
                                    evidence: .notification,
                                    title: "  build\u{1B}[31m done\n ",
                                    body: "line one\nline two\u{7F}")
        guard case .posted(let id) = center.post(request) else { return XCTFail("post") }
        let notice = try XCTUnwrap(center.notice(id: id))
        XCTAssertEqual(notice.title, "build[31m done")
        XCTAssertEqual(notice.body, "line one line two")
        XCTAssertTrue(notice.bodySensitive, "a program's own words are sensitive by default")

        let blank = NoticeRequest(source: .command, pane: pane, urgency: .info, evidence: .composed,
                                  title: "\u{1B}\u{7F}", body: "   ")
        guard case .posted(let fallback) = center.post(blank) else { return XCTFail("post") }
        let composed = try XCTUnwrap(center.notice(id: fallback))
        XCTAssertFalse(composed.title.isEmpty, "an unprintable title falls back to the source's name")
        XCTAssertTrue(composed.title.contains("command"))
        XCTAssertNil(composed.body, "a body that sanitises to nothing is nil, not an empty string")
    }

    /// A body longer than the cap is cut rather than stored whole.
    func testBodyIsCappedAtMaxBodyLength() throws {
        let pane = try addPane()
        let long = String(repeating: "x", count: Notice.maxBodyLength + 500)
        guard case .posted(let id) = center.post(request(pane, .info, body: long)) else {
            return XCTFail("post")
        }
        XCTAssertEqual(center.notice(id: id)?.body?.count, Notice.maxBodyLength)
    }

    /// The history ring is capped, and it keeps the newest.
    func testHistoryIsCappedAtTwoHundred() throws {
        let pane = try addPane()
        let total = NoticeCenter.historyCapacity + 50
        for i in 0..<total {
            center.post(request(pane, .info, source: .custom("s\(i)"), title: "Notice \(i)"))
        }
        XCTAssertEqual(center.resolveAll(pane: pane, .acknowledged), total)
        XCTAssertEqual(center.history.count, NoticeCenter.historyCapacity)
        XCTAssertEqual(center.history.last?.title, "Notice \(total - 1)", "the newest survives")
    }

    /// Inside a sink callback the world is already consistent: `.posted` arrives after the notice
    /// is in `live`, `.resolved` after it has left, and `counts` already reflects both.
    func testSinkCallbacksSeeAConsistentWorld() throws {
        let pane = try addPane()
        var checked = 0
        sink.inspect = { [center] change in
            guard let center else { return }
            switch change {
            case .posted(let notice, _, _):
                XCTAssertTrue(center.live.contains { $0.id == notice.id })
                XCTAssertEqual(center.urgency(pane: notice.pane), .needsUser)
                XCTAssertEqual(center.counts.total, 1)
                checked += 1
            case .resolved(let notice, _, _):
                XCTAssertFalse(center.live.contains { $0.id == notice.id })
                XCTAssertNil(center.urgency(pane: notice.pane))
                XCTAssertEqual(center.counts.total, 0)
                checked += 1
            default:
                break
            }
        }
        guard case .posted(let id) = center.post(request(pane)) else { return XCTFail("post") }
        center.resolve(id, .acknowledged)
        XCTAssertEqual(checked, 2, "both callbacks have to have run")
    }

    /// A sink switched off receives nothing and is told to clear itself exactly once.
    func testDisabledSinkIsSilencedAndClearedOnce() throws {
        let pane = try addPane()
        center.post(request(pane))
        XCTAssertFalse(sink.changes.isEmpty)
        sink.reset()

        center.settings.dockBadge = false
        XCTAssertFalse(sink.isEnabled)
        XCTAssertEqual(sink.clearAllCount, 1)

        center.post(request(pane, source: .agent("codex"), title: "Another"))
        center.resolveAll(pane: pane, .acknowledged)
        XCTAssertTrue(sink.changes.isEmpty, "a disabled sink hears nothing at all")

        center.settings.dockBadge = false
        XCTAssertEqual(sink.clearAllCount, 1, "writing the same value again clears nothing twice")

        center.settings.dockBadge = true
        XCTAssertTrue(sink.isEnabled)
        XCTAssertEqual(sink.clearAllCount, 1)
    }

    /// The registry side of the sinks, including the "the config decides, never the sink" rule.
    func testSinkRegistrationAndSettings() {
        XCTAssertTrue(center.sink(id: NoticeSinkID.dockBadge) === sink)
        let duplicate = NoticeRecordingSink(sinkID: NoticeSinkID.dockBadge)
        center.addSink(duplicate)
        XCTAssertTrue(center.sink(id: NoticeSinkID.dockBadge) === sink, "one id, one sink")

        center.settings.system = "never"
        let system = NoticeRecordingSink(sinkID: NoticeSinkID.system)
        center.addSink(system)
        XCTAssertFalse(system.isEnabled, "a sink added while its switch is off starts off")

        let log = NoticeRecordingSink(sinkID: NoticeSinkID.activityLog)
        center.addSink(log)
        XCTAssertTrue(log.isEnabled, "the record of what happened has no switch")

        center.removeSink(id: NoticeSinkID.dockBadge)
        XCTAssertNil(center.sink(id: NoticeSinkID.dockBadge))
    }

    // MARK: Value types

    /// `nil` sorts below both, and `info < needsUser`. Written by hand, so pinned by hand.
    func testUrgencyOrdering() {
        XCTAssertTrue(NoticeUrgency.info < NoticeUrgency.needsUser)
        XCTAssertEqual(NoticeUrgency.rank(nil), 0)
        XCTAssertTrue(NoticeUrgency.rank(nil) < NoticeUrgency.rank(.info))
        XCTAssertTrue(PaneTransition(pane: UUID(), before: nil, after: .info).raised)
        XCTAssertTrue(PaneTransition(pane: UUID(), before: .info, after: .needsUser).raised)
        XCTAssertFalse(PaneTransition(pane: UUID(), before: .needsUser, after: .info).raised)
        XCTAssertTrue(PaneTransition(pane: UUID(), before: .needsUser, after: nil).cleared)
        XCTAssertFalse(PaneTransition(pane: UUID(), before: nil, after: nil).cleared)
    }

    /// The wire spelling of a source is half of every coalescing key, so it is API.
    func testSourceWireSpelling() {
        XCTAssertEqual(NoticeSource.agent("claude-code").id, "agent:claude-code")
        XCTAssertEqual(NoticeSource.terminal.id, "terminal")
        XCTAssertEqual(NoticeSource.command.id, "command")
        XCTAssertEqual(NoticeSource.bell.id, "bell")
        XCTAssertEqual(NoticeSource.download.id, "download")
        XCTAssertEqual(NoticeSource.control.id, "control")
        XCTAssertEqual(NoticeSource.custom("x").id, "custom:x")
        let pane = UUID()
        XCTAssertEqual(Notice.key(source: .terminal, urgency: .needsUser, pane: pane),
                       "terminal|needs-user|\(pane.uuidString)")
        XCTAssertNotEqual(Notice.key(source: .terminal, urgency: .info, pane: pane),
                          Notice.key(source: .terminal, urgency: .needsUser, pane: pane),
                          "the urgency is part of the key: an info post must not replace an alarm")
    }

    /// `PaneActivity` needs all four clauses. The app being frontmost is one of them: a key
    /// window in a background app has nobody's attention.
    func testPaneActivityNeedsAllFourClauses() {
        XCTAssertTrue(PaneActivity(appActive: true, screenKey: true, workspaceVisible: true,
                                   focused: true).isActive)
        for index in 0..<4 {
            var flags = [true, true, true, true]
            flags[index] = false
            XCTAssertFalse(PaneActivity(appActive: flags[0], screenKey: flags[1],
                                        workspaceVisible: flags[2], focused: flags[3]).isActive,
                           "clause \(index) has to be necessary")
        }
    }

    /// `[notifications] command-finished` and the ten-second rule.
    func testSettingsGates() {
        var settings = NoticeSettings()
        XCTAssertTrue(settings.allowsCommandFinished(.seconds(11)))
        XCTAssertFalse(settings.allowsCommandFinished(.milliseconds(9_999)))
        settings.commandFinished = "always"
        XCTAssertTrue(settings.allowsCommandFinished(.milliseconds(1)))
        settings.commandFinished = "never"
        XCTAssertFalse(settings.allowsCommandFinished(.seconds(600)))
        XCTAssertFalse(NoticeSettings().allowsBell)
        var bell = NoticeSettings()
        bell.bell = "info"
        XCTAssertTrue(bell.allowsBell)
    }

    /// The config really reaches the centre's switches.
    func testSettingsComeFromTheConfigRegistry() {
        let parsed = ConfigStore.parse("""
        [notifications]
        system = "never"
        system-body = "always"
        dock-badge = false
        pane-mark = false
        workspace-count = false
        bell = "info"
        command-finished = "never"
        """)
        let settings = NoticeSettings(parsed)
        XCTAssertEqual(settings.system, "never")
        XCTAssertEqual(settings.systemBody, "always")
        XCTAssertFalse(settings.dockBadge)
        XCTAssertFalse(settings.paneMark)
        XCTAssertFalse(settings.workspaceCount)
        XCTAssertTrue(settings.allowsBell)
        XCTAssertFalse(settings.allowsCommandFinished(.seconds(3600)))
        for id in [NoticeSinkID.system, NoticeSinkID.dockBadge, NoticeSinkID.paneMark,
                   NoticeSinkID.workspaceCount] {
            XCTAssertFalse(settings.isEnabled(sinkID: id), "\(id) has to be off")
        }
        XCTAssertTrue(settings.isEnabled(sinkID: NoticeSinkID.controlPlane))
        XCTAssertTrue(settings.isEnabled(sinkID: NoticeSinkID.activityLog))
        XCTAssertEqual(NoticeSettings(ConfigStore.Settings()), NoticeSettings(),
                       "the registry defaults and the type's own defaults have to agree")
    }
}

// MARK: - Rule 2 through a real surface

/// The one rule that cannot be tested with a stub: **a keystroke is a real `NSEvent` delivered to
/// `SurfaceView.keyDown(with:)`**, and text pushed through `input send-text` is not.
///
/// That asymmetry is a security property, not a detail. `QUICKTERM_PANE_TOKEN` is readable by any
/// same-uid non-platform process (spec §2.3), so a process in pane A can drive `send-text` at
/// pane B; if that counted as "the user acted", it could silence B's alarm. It cannot, because
/// `Ghostty.Surface.sendText` never walks through `keyDown`.
///
/// These cases drive the **process-wide** `NoticeCenter.shared`, because that is what the call
/// site in `SurfaceView.keyDown` reaches. They attach it to the real screens themselves: the
/// launch-time wiring (contract §10.10) belongs to the AppDelegate change that lands with the
/// system-notification sink.
@MainActor
final class NoticeKeyDownTests: XCTestCase {
    private var created: [PaneView] = []

    private var app: AppDelegate {
        get throws { try XCTUnwrap(NSApp.delegate as? AppDelegate) }
    }

    override func setUp() async throws {
        try await super.setUp()
        let app = try self.app
        NoticeCenter.shared.attach(locator: NoticeLocator(screens: app.screens))
        NoticeCenter.shared.resetForTesting()
    }

    override func tearDown() async throws {
        let app = try self.app
        for controller in app.screens.controllers {
            for pane in created where controller.model.allPanes.contains(where: { $0 === pane }) {
                controller.closePane(pane, confirmIfNeeded: false, animated: false)
                controller.removeFromAnyWorkspace(pane)
            }
            controller.flushPendingCloses()
        }
        created.removeAll()
        NoticeCenter.shared.resetForTesting()
        spin(0.2)
        try await super.tearDown()
    }

    private func spin(_ seconds: TimeInterval = 0.3) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private func newTerminal() throws -> Ghostty.SurfaceView {
        let controller = try XCTUnwrap(app.screens.primary)
        let before = Set(controller.model.allPanes.map(\.id))
        controller.perform(.newTerminal)
        spin(0.4)
        let pane = try XCTUnwrap(controller.model.allPanes.first { !before.contains($0.id) },
                                 "failed to create the new pane")
        created.append(pane)
        return try XCTUnwrap(pane as? Ghostty.SurfaceView, "a new terminal pane is a SurfaceView")
    }

    private func postAlarm(_ pane: PaneView) throws -> UUID {
        let outcome = NoticeCenter.shared.post(
            NoticeRequest(source: .agent("claude-code"), pane: pane.id, urgency: .needsUser,
                          evidence: .hook, title: "Awaiting approval"))
        guard case .posted(let id) = outcome else {
            throw XCTSkip("the pane is not addressable in this environment: \(outcome)")
        }
        return id
    }

    /// **`input send-text` is not the user acting.** Deterministic: no window focus is involved.
    func testSendTextNeverResolvesANotice() throws {
        let surface = try newTerminal()
        let id = try postAlarm(surface)
        let model = try XCTUnwrap(surface.surfaceModel, "the engine surface has to be up")

        model.sendText("y")
        spin(0.2)

        let notice = try XCTUnwrap(NoticeCenter.shared.notice(id: id))
        XCTAssertTrue(notice.isLive, "text pushed in by a caller must never resolve a notice")
        XCTAssertEqual(NoticeCenter.shared.urgency(pane: surface.id), .needsUser)
    }

    /// The guard, deterministically: a `keyDown` delivered to a pane that is **not** the focused
    /// pane of the key window of the active app resolves nothing.
    ///
    /// This case is the one that always runs, and it is what proves the call site in
    /// `SurfaceView.keyDown(with:)` is reached at all — it goes through exactly the same line as
    /// the case below, which needs window-server focus the suite usually does not have.
    func testKeyDownOutsideTheFocusedPaneResolvesNothing() throws {
        let surface = try newTerminal()
        let id = try postAlarm(surface)
        surface.resignFirstResponder()
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: surface.window?.windowNumber ?? 0, context: nil, characters: "\u{1B}",
            charactersIgnoringModifiers: "\u{1B}", isARepeat: false, keyCode: 53))

        surface.keyDown(with: event)
        spin(0.2)

        XCTAssertTrue(try XCTUnwrap(NoticeCenter.shared.notice(id: id)).isLive,
                      "a keystroke that did not land on the focused pane of the key window of the "
                      + "active app is not the user acting")
    }

    /// A real `keyDown` on the focused pane of the key window of the active app resolves it.
    ///
    /// Skipped rather than failed when the suite runs without window-server focus (the same
    /// tolerance `ScreenRegistryTests.testControllerFollowsKeyWindow` has): all four clauses of
    /// `PaneActivity` are genuinely false then, and the correct behaviour is to resolve nothing.
    func testKeyDownInTheFocusedPaneResolves() throws {
        let surface = try newTerminal()
        let controller = try XCTUnwrap(app.screens.primary)
        NSApp.activate(ignoringOtherApps: true)
        controller.window?.makeKeyAndOrderFront(nil)
        controller.requestFocus(to: surface)
        spin(0.4)

        guard NSApp.isActive, surface.window?.isKeyWindow == true, surface.focused else {
            throw XCTSkip("no window-server focus in this environment; rule 2 cannot fire")
        }
        let id = try postAlarm(surface)
        let window = try XCTUnwrap(surface.window)
        let escape = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "\u{1B}",
            charactersIgnoringModifiers: "\u{1B}", isARepeat: false, keyCode: 53))

        surface.keyDown(with: escape)
        spin(0.2)

        XCTAssertNil(NoticeCenter.shared.urgency(pane: surface.id),
                     "a real keystroke in the focused pane resolves what was asking")
        XCTAssertEqual(NoticeCenter.shared.notice(id: id)?.resolution, .userActed)
    }
}
