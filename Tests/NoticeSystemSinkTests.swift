import AppKit
import UserNotifications
import XCTest
@testable import QuickTerm

/// **The macOS banner, the Dock badge and what a click on a banner does** (design §3.5, contract
/// §10.7 / §10.11).
///
/// The cases drive a centre of their own with `NoticeLocatorStub` (declared in
/// `NoticeCenterTests`), so "the user is looking at this pane" is a value a case sets rather than
/// a window arrangement it has to achieve. The two delegate callbacks are the exception and are
/// called out where they are missing.
@MainActor
final class NoticeSystemSinkTests: XCTestCase {
    private var locator = NoticeLocatorStub()
    private var recorder = RecordingNotificationCenter()
    private var center: NoticeCenter!
    private var sink: SystemNotificationSink!
    private var settings = NoticeSettings()
    private var routed: [UUID] = []

    private var app: AppDelegate {
        get throws { try XCTUnwrap(NSApp.delegate as? AppDelegate) }
    }

    override func setUp() async throws {
        try await super.setUp()
        locator = NoticeLocatorStub()
        recorder = RecordingNotificationCenter()
        settings = NoticeSettings()
        routed = []
        center = NoticeCenter(locator: locator)
        sink = SystemNotificationSink(center: recorder, locator: locator,
                                      route: { [self] in routed.append($0) },
                                      settings: { [self] in settings })
        center.addSink(sink)
    }

    // MARK: Fixtures

    @discardableResult
    private func addPane(active: Bool) throws -> UUID {
        let controller = try XCTUnwrap(app.screens.primary)
        let pane = PaneView(frame: .zero)
        locator.entries[pane.id] = .init(
            pane: pane, controller: controller, workspace: 0,
            activity: PaneActivity(appActive: active, screenKey: active,
                                   workspaceVisible: active, focused: active))
        return pane.id
    }

    private func setActivity(_ pane: UUID, active: Bool) {
        locator.entries[pane]?.activity = PaneActivity(
            appActive: active, screenKey: active, workspaceVisible: active, focused: active)
    }

    /// `evidence` matters from Phase 2 on: only a **hook or report** alarm is quieted by a
    /// keystroke (plan §2.8) — a notification-evidenced one resolves outright, because no later
    /// signal will ever come for it.
    private func request(_ pane: UUID, urgency: NoticeUrgency = .needsUser,
                         source: NoticeSource = .terminal, title: String = "Needs you",
                         body: String? = nil, sensitive: Bool = true,
                         evidence: NoticeEvidence = .notification) -> NoticeRequest {
        NoticeRequest(source: source, pane: pane, urgency: urgency, evidence: evidence,
                      title: title, body: body, bodySensitive: sensitive)
    }

    // MARK: Presenting

    /// Rule 2 of the sink: the banner exists to tell somebody something they cannot see. A pane
    /// the user is looking at gets nothing at all.
    func testPresentsOnlyWhenThePaneIsNotActive() throws {
        let watched = try addPane(active: true)
        center.post(request(watched))
        XCTAssertTrue(recorder.added.isEmpty, "the user is looking straight at that pane")

        let away = try addPane(active: false)
        center.post(request(away))
        XCTAssertEqual(recorder.added.count, 1)
        XCTAssertEqual(recorder.added[0].identifier,
                       SystemNotificationSink.identifier(pane: away),
                       "one identifier per pane is what makes an update replace rather than stack")
        XCTAssertEqual(recorder.added[0].content.title, "Needs you")
        XCTAssertNotNil(recorder.added[0].content.sound, "a raising transition pings")
        XCTAssertEqual(recorder.added[0].content.userInfo["pane"] as? String, away.uuidString)
        XCTAssertEqual(recorder.authorizationRequests, 1,
                       "authorization is asked for lazily, at the first banner")
    }

    /// The duplicate rule, seen from the sink: `PermissionRequest` and the OSC notification that
    /// describes the *same* prompt must not present the banner with sound twice.
    func testADuplicatePostPresentsNothing() throws {
        let pane = try addPane(active: false)
        center.post(request(pane))
        center.post(request(pane))
        XCTAssertEqual(recorder.added.count, 1)
        XCTAssertEqual(recorder.authorizationRequests, 1, "and it is asked for exactly once")
    }

    /// A pane that already had an `info` live and gets a second, different `info` under another
    /// source is not louder than it was - no new banner. It goes up only on a raising transition.
    func testAnInfoThatDoesNotRaiseThePanePresentsNothing() throws {
        let pane = try addPane(active: false)
        center.post(request(pane, urgency: .info, source: .terminal, title: "One"))
        XCTAssertEqual(recorder.added.count, 1)
        center.post(request(pane, urgency: .info, source: .bell, title: "Two"))
        XCTAssertEqual(recorder.added.count, 1, "info -> info is not a raise")

        center.post(request(pane, urgency: .needsUser, title: "Now really"))
        XCTAssertEqual(recorder.added.count, 2, "info -> needsUser is")
    }

    /// A different tool is asking now: the banner is replaced (same identifier), and the sound
    /// only fires when the pane actually got louder.
    func testASupersededNeedsUserReplacesTheBannerSilently() throws {
        let pane = try addPane(active: false)
        center.post(request(pane, title: "Approve Bash"))
        XCTAssertNotNil(recorder.added.last?.content.sound)
        center.post(request(pane, title: "Approve Edit"))
        XCTAssertEqual(recorder.added.count, 2)
        XCTAssertEqual(recorder.added.last?.content.title, "Approve Edit")
        XCTAssertEqual(recorder.added.last?.identifier,
                       SystemNotificationSink.identifier(pane: pane))
        XCTAssertNil(recorder.added.last?.content.sound,
                     "the pane was already at needsUser: replace the text, do not ping again")
    }

    // MARK: Withdrawing

    func testWithdrawsWhenTheLastNoticeResolvesAndNotBefore() throws {
        let pane = try addPane(active: false)
        center.post(request(pane, source: .terminal, title: "First"))
        center.post(request(pane, source: .command, title: "Second"))
        let first = try XCTUnwrap(center.live(pane: pane).first)

        center.resolve(first.id, .acknowledged)
        XCTAssertTrue(recorder.removedDelivered.isEmpty,
                      "the second notice is still live; its banner has to stay")

        let second = try XCTUnwrap(center.live(pane: pane).first)
        center.resolve(second.id, .acknowledged)
        XCTAssertEqual(recorder.removedDelivered, [SystemNotificationSink.identifier(pane: pane)])
        XCTAssertEqual(recorder.removedPending, recorder.removedDelivered,
                       "pending as well: a banner not shown yet is just as stale")
    }

    /// The user walked over to the pane. Whatever is on the lock screen about it is stale, even
    /// though a `needsUser` notice stays live until they actually act.
    func testWithdrawsWhenThePaneBecomesActive() throws {
        let pane = try addPane(active: false)
        center.post(request(pane))
        setActivity(pane, active: true)
        center.flushActivityPass()
        XCTAssertEqual(recorder.removedDelivered, [SystemNotificationSink.identifier(pane: pane)])
        XCTAssertEqual(center.urgency(pane: pane), .needsUser,
                       "looking at an approval prompt is not answering it")
    }

    func testClearAllTakesEveryBannerDown() throws {
        let a = try addPane(active: false)
        let b = try addPane(active: false)
        center.post(request(a))
        center.post(request(b))
        settings.system = "never"
        center.settings = settings
        XCTAssertEqual(Set(recorder.removedDelivered),
                       [SystemNotificationSink.identifier(pane: a),
                        SystemNotificationSink.identifier(pane: b)],
                       "switching the sink off has to take its banners with it")
    }

    // MARK: Quieting — the interrupting half of Q1(b)
    //
    // Every case here leaves the pane **inactive** in the locator stub, so the only road that can
    // take a banner down is `.quieted`. If any of them started passing because the pane went
    // active, `testWithdrawsWhenThePaneBecomesActive` would be the case asserting it.

    /// The user focused the pane and typed into it. The banner exists to fetch somebody out of
    /// another app, and that job is now done — but the prompt has not been answered, so the notice
    /// is still live and the pane mark still draws (owner decision Q1(b)).
    func testTypingInThePaneWithdrawsTheBannerAndLeavesTheNoticeLive() throws {
        let pane = try addPane(active: false)
        center.post(request(pane, title: "Approve Bash", evidence: .hook))
        XCTAssertEqual(recorder.added.count, 1)

        center.userDidType(in: pane)

        XCTAssertEqual(recorder.removedDelivered, [SystemNotificationSink.identifier(pane: pane)])
        XCTAssertEqual(recorder.removedPending, recorder.removedDelivered,
                       "pending as well: a banner not shown yet is just as stale")
        XCTAssertEqual(center.urgency(pane: pane), .needsUser, "the pane mark stays up")
        XCTAssertEqual(center.live(pane: pane).count, 1)
        XCTAssertNotNil(center.live(pane: pane).first?.quietedAt)
    }

    /// Quieted is not resolved, and the one thing that puts the banner back is the agent asking
    /// about something else. It returns **silently**: the pane was already loud, so a second ping
    /// would be the same alarm ringing twice.
    func testASupersedingAlarmPutsTheBannerBackAfterAQuieting() throws {
        let pane = try addPane(active: false)
        center.post(request(pane, title: "Approve Bash", evidence: .hook))
        center.userDidType(in: pane)
        recorder.reset()

        center.post(request(pane, title: "Approve Edit", evidence: .hook))

        XCTAssertEqual(recorder.added.count, 1)
        XCTAssertEqual(recorder.lastContent?.title, "Approve Edit")
        XCTAssertNil(recorder.added.last?.content.sound)
        XCTAssertNil(try XCTUnwrap(center.live(pane: pane).first).quietedAt,
                     "a fresh prompt is a fresh alarm")
    }

    /// Nothing *else* brings it back. An `info` arriving while the quieted alarm is still live is
    /// not a raise, so the banner stays down.
    func testAQuietedAlarmIsNotRePresentedByAnInfoNotice() throws {
        let pane = try addPane(active: false)
        center.post(request(pane, title: "Approve Bash", evidence: .hook))
        center.userDidType(in: pane)
        recorder.reset()

        center.post(request(pane, urgency: .info, source: .command, title: "Command finished"))

        XCTAssertTrue(recorder.added.isEmpty)
    }

    /// The sink withdraws; it never resolves. `notices ack` still answers a quieted alarm, and
    /// that is what finally clears the pane mark. (A click on a banner is the same shape —
    /// `didReceive` reveals and withdraws, leaving a quieted notice live — and is exercised in the
    /// live smoke for the reason the "NOT TESTED HERE" note below gives.)
    func testAckStillResolvesAQuietedAlarm() throws {
        let pane = try addPane(active: false)
        center.post(request(pane, title: "Approve Bash", evidence: .hook))
        center.userDidType(in: pane)

        center.resolveAll(pane: pane, .acknowledged)

        XCTAssertTrue(center.live(pane: pane).isEmpty)
        XCTAssertNil(center.urgency(pane: pane))
    }

    // MARK: The body rule

    /// `system-body` x `bodySensitive`, all six answers. The default is `composed`: only text
    /// QuickTerm wrote itself, because Notification Center keeps a body in its database, shows it
    /// on the lock screen and outlives the app.
    func testBodyFollowsSystemBodyAndSensitivity() throws {
        for (mode, sensitive, expected) in [
            ("never", true, ""), ("never", false, ""),
            ("composed", true, ""), ("composed", false, "Command took 12 s."),
            ("always", true, "rm -rf build"), ("always", false, "Command took 12 s."),
        ] as [(String, Bool, String)] {
            recorder.reset()
            center.resetForTesting()
            settings.systemBody = mode
            let pane = try addPane(active: false)
            let text = sensitive ? "rm -rf build" : "Command took 12 s."
            center.post(request(pane, body: text, sensitive: sensitive))
            XCTAssertEqual(recorder.lastContent?.body, expected,
                           "system-body = \(mode), sensitive = \(sensitive)")
        }
    }

    /// The subtitle names the pane the way the user addresses it, and never carries the
    /// terminal's own title.
    func testSubtitleNamesThePaneByItsHandle() throws {
        let pane = try addPane(active: false)
        center.post(request(pane))
        let handle = try XCTUnwrap(locator.handle(pane))
        XCTAssertEqual(recorder.lastContent?.subtitle, L("notice.system.subtitle", handle))
    }

    // MARK: Wiring

    /// The delegate is what makes a click on a banner route at all, and it is installed by the
    /// launch wiring (contract §10.10) on whichever centre the sink was built with.
    func testInstallAsDelegateTakesTheNotificationCentre() throws {
        XCTAssertNil(recorder.delegate)
        sink.installAsDelegate()
        XCTAssertTrue(recorder.delegate === sink)
    }

    /// The app really does register the system sink at launch - the case that would have caught
    /// "the engine's path was removed and nothing replaced it".
    func testTheAppRegistersTheSystemSinkAtLaunch() throws {
        AppDelegate.ensureNoticeInterfaceInstalled()
        let installed = try XCTUnwrap(NoticeCenter.shared.systemSink,
                                      "no system-notification sink: nothing would reach macOS")
        XCTAssertTrue(NoticeCenter.shared.sink(id: NoticeSinkID.system) === installed)
        XCTAssertNotNil(NoticeCenter.shared.sink(id: NoticeSinkID.dockBadge))
        XCTAssertNotNil(NoticeCenter.shared.sink(id: NoticeSinkID.controlPlane))
        XCTAssertNotNil(NoticeCenter.shared.sink(id: NoticeSinkID.activityLog))
    }

    // NOT TESTED HERE, on purpose: `willPresent` and `didReceive`. Both take a `UNNotification` /
    // `UNNotificationResponse`, and neither type has a public initialiser - a case for them would
    // be testing a hand-forged object, not the system's. What they do is exercised in the live
    // smoke test (a banner while the pane is hidden, a click that routes to it).

    // MARK: The Dock badge

    /// Panes, never notices, and `nil` rather than "0" - an empty string still draws the red pill.
    func testDockBadgeCountsPanesAndClearsAtZero() throws {
        var labels: [String?] = []
        let badge = DockBadgeSink(setBadge: { labels.append($0) })
        center.addSink(badge)

        let pane = try addPane(active: false)
        center.post(request(pane))
        XCTAssertEqual(labels.last, "1")

        // A second alarm on the same pane is still one pane to walk to.
        center.post(request(pane, source: .command, title: "Also this"))
        XCTAssertEqual(labels.last, "1")

        var panes: [UUID] = []
        for _ in 0..<6 { panes.append(try addPane(active: false)) }
        for other in panes { center.post(request(other)) }
        XCTAssertEqual(labels.last, "7")

        center.resolveAll(pane: pane, .acknowledged)
        for other in panes { center.resolveAll(pane: other, .acknowledged) }
        XCTAssertEqual(labels.last, .some(nil), "cleared at zero, not set to \"0\"")

        badge.clearAll()
        XCTAssertEqual(labels.last, .some(nil))
    }

    /// The badge is an **interrupting** sink: it counts the panes nobody has gone to yet. The pane
    /// mark and the workspace pill are not, and keep counting every live alarm (owner decision Q6)
    /// — which is why `counts.needsUser` stays at two throughout.
    func testDockBadgeShowsOnlyWhatIsStillInterrupting() throws {
        var labels: [String?] = []
        center.addSink(DockBadgeSink(setBadge: { labels.append($0) }))

        let a = try addPane(active: false)
        let b = try addPane(active: false)
        center.post(request(a, title: "Approve Bash", evidence: .hook))
        center.post(request(b, title: "Approve Edit", evidence: .hook))
        XCTAssertEqual(labels.last, "2")

        center.userDidType(in: a)
        XCTAssertEqual(labels.last, "1", "one pane has been picked up; the other has not")
        XCTAssertEqual(center.urgency(pane: a), .needsUser, "the quieted pane still draws its mark")
        XCTAssertEqual(center.counts.needsUser.count, 2, "and the pill still counts both")

        center.userDidType(in: b)
        XCTAssertEqual(labels.last, .some(nil), "nothing is interrupting: no red pill at all")
        XCTAssertEqual(center.counts.needsUser.count, 2,
                       "two prompts are still pending, and two marks are still drawn")
    }

    /// A notification-evidenced alarm has no hook behind it: nothing will ever come to say it is
    /// over, so a keystroke resolves it outright rather than quieting it — badge and mark together.
    func testANotificationEvidencedAlarmResolvesOnAKeystrokeInsteadOfQuieting() throws {
        var labels: [String?] = []
        center.addSink(DockBadgeSink(setBadge: { labels.append($0) }))

        let pane = try addPane(active: false)
        center.post(request(pane, evidence: .notification))
        XCTAssertEqual(labels.last, "1")

        center.userDidType(in: pane)

        XCTAssertEqual(labels.last, .some(nil))
        XCTAssertTrue(center.live(pane: pane).isEmpty)
        XCTAssertNil(center.urgency(pane: pane), "the mark goes with it")
    }

    // MARK: Click routing

    /// What a click on a banner does: the pane is focused, and the focus **stays** there for the
    /// hold even though the cursor is parked where the banner was, over some other pane.
    func testRevealFocusesThePaneAndHoldsItAgainstHoverFocus() throws {
        let controller = try XCTUnwrap(app.screens.primary)
        guard let window = controller.window, window.canBecomeKey else {
            throw XCTSkip("no window server focus in this environment")
        }
        window.makeKeyAndOrderFront(nil)
        let before = Set(controller.model.allPanes.map(\.id))
        controller.perform(.newTerminal)
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        guard let fresh = controller.model.allPanes.first(where: { !before.contains($0.id) }),
              let other = controller.model.allPanes.first(where: { $0 !== fresh })
        else { throw XCTSkip("the split did not happen in this environment") }
        defer {
            controller.releaseFocusHold()
            controller.closePane(fresh, confirmIfNeeded: false, animated: false)
            controller.removeFromAnyWorkspace(fresh)
            controller.flushPendingCloses()
        }

        controller.requestFocus(to: other)
        RunLoop.current.run(until: Date().addingTimeInterval(0.9))

        let real = NoticeLocator(screens: try app.screens)
        XCTAssertTrue(NoticeRouting.reveal(pane: fresh.id, locator: real))
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        XCTAssertTrue(controller.focusedPane === fresh, "the click takes the user to the pane")
        XCTAssertFalse(controller.paneMayReclaimFocus(other),
                       "the cursor is sitting where the banner was: hover must not steal it back")

        // The first real keystroke ends the hold - the user is where they meant to be.
        controller.releaseFocusHold()
        XCTAssertTrue(controller.paneMayReclaimFocus(other))
    }

    // A pane that closed while its banner was on screen routes nowhere: covered by
    // `NoticeUITests.testRoutingAnUnknownPaneDoesNothing`, which drives the same road through its
    // app-side name.
}
