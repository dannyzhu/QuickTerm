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

    // MARK: Re-arm — the banner an active pane never got, delivered when the user looks away

    /// The screenshot bug. An alarm raised while the user is looking straight at the pane gets no
    /// banner then (rule 2). When they switch away with it still pending, the banner is presented at
    /// last — with sound, because it has never been on screen.
    func testLeavingAWatchedPanePresentsTheBannerItNeverGot() throws {
        let pane = try addPane(active: true)
        center.post(request(pane, title: "Approve Bash", evidence: .hook))
        XCTAssertTrue(recorder.added.isEmpty, "watched: no banner while the user is looking")

        setActivity(pane, active: false)
        center.flushActivityPass()

        XCTAssertEqual(recorder.added.count, 1, "looked away: the banner appears at last")
        XCTAssertEqual(recorder.added[0].identifier, SystemNotificationSink.identifier(pane: pane))
        XCTAssertNotNil(recorder.added.last?.content.sound, "first time on screen, so it pings")
    }

    /// The re-armed banner does not ping a second time: the user tabs away (first ping), tabs back
    /// (banner withdrawn), and away again. The second presentation is silent **not** because a banner
    /// is still up — it was withdrawn on focus, so `present` genuinely re-adds — but because the pane
    /// is already in `pingedPanes` and stays there across the withdrawal.
    func testReArmedBannerDoesNotPingWhileAlreadyAnnounced() throws {
        let pane = try addPane(active: true)
        center.post(request(pane, title: "Approve Bash", evidence: .hook))
        setActivity(pane, active: false)
        center.flushActivityPass()
        XCTAssertEqual(recorder.added.count, 1)
        XCTAssertNotNil(recorder.added.last?.content.sound, "first delivery pings")
        recorder.reset()

        // Back to the pane (banner withdrawn on active), then away again with the prompt still up.
        setActivity(pane, active: true)
        center.flushActivityPass()
        setActivity(pane, active: false)
        center.flushActivityPass()

        XCTAssertEqual(recorder.added.count, 1, "presented again once")
        XCTAssertNil(recorder.added.last?.content.sound, "the pane was already announced — silent")
    }

    /// Spec §3.5 rule 5: one audible alert per pane, however many sources describe the prompt. A
    /// second source's `needsUser` is coalesced away (no banner of its own), but it is the newest
    /// notice and so becomes the re-arm representative — the sound must still be keyed on the pane
    /// having been announced, not on that notice's own id.
    func testReArmDoesNotDoublePingAPaneAlreadyAnnouncedByAnotherSource() throws {
        let pane = try addPane(active: false)
        center.post(request(pane, source: .agent("claude-code"), title: "Approve Bash", evidence: .hook))
        XCTAssertEqual(recorder.added.count, 1)
        XCTAssertNotNil(recorder.added.last?.content.sound, "the first source announces the pane")
        // A second source describes the same pane while it is already loud: coalesced, no banner.
        center.post(request(pane, source: .terminal, title: "Something else"))
        XCTAssertEqual(recorder.added.count, 1, "one banner per pane")
        recorder.reset()

        // The user glances at the pane (banner withdrawn) and leaves again without answering.
        setActivity(pane, active: true)
        center.flushActivityPass()
        setActivity(pane, active: false)
        center.flushActivityPass()

        XCTAssertEqual(recorder.added.count, 1, "re-presented once")
        XCTAssertNil(recorder.added.last?.content.sound,
                     "the pane was already announced by the first source — no second ping")
    }

    /// A genuinely fresh alarm, after the pane's approval fully resolved, pings again: `pingedPanes`
    /// is cleared when the pane stops needing the user.
    func testAFreshAlarmAfterResolutionPingsAgain() throws {
        let pane = try addPane(active: false)
        center.post(request(pane, source: .agent("claude-code"), title: "Approve Bash", evidence: .hook))
        XCTAssertNotNil(recorder.added.last?.content.sound)
        XCTAssertEqual(center.resolveAll(pane: pane, .acknowledged), 1)   // the pane no longer needs you
        recorder.reset()

        // A new prompt arrives while the user is watching the pane (no banner then)…
        setActivity(pane, active: true)
        center.flushActivityPass()
        center.post(request(pane, source: .agent("claude-code"), title: "Approve Edit", evidence: .hook))
        XCTAssertTrue(recorder.added.isEmpty, "watched: no banner yet")
        // …then they leave.
        setActivity(pane, active: false)
        center.flushActivityPass()
        XCTAssertEqual(recorder.added.count, 1)
        XCTAssertNotNil(recorder.added.last?.content.sound, "a fresh alarm after resolution pings again")
    }

    /// The pre-existing stale-banner bug (confirmed in review): focusing a pane whose `info`
    /// resolves in the same pass must still withdraw the pane's approval banner. The info's own
    /// resolution cannot (the pane still needs the user), so the `.activityChanged` on focus has to.
    func testFocusingAPaneWhoseInfoResolvesInTheSamePassStillWithdrawsTheBanner() throws {
        let pane = try addPane(active: false)
        center.post(request(pane, source: .agent("claude-code"), title: "Approve Bash", evidence: .hook))
        center.post(request(pane, urgency: .info, source: .command, title: "Command finished"))
        XCTAssertEqual(recorder.added.count, 1, "one banner per pane")
        recorder.reset()

        setActivity(pane, active: true)
        center.flushActivityPass()

        XCTAssertEqual(recorder.removedDelivered, [SystemNotificationSink.identifier(pane: pane)],
                       "opening the pane withdraws its banner, even though an info resolved in the same pass")
        XCTAssertEqual(center.urgency(pane: pane), .needsUser, "the approval prompt is still live")
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

    /// The badge is a **passive** indicator like the pane mark and the pill: it counts every pane
    /// that needs the user, and a keystroke — which quiets the *banner* — must not drop it. Answering
    /// an approval means pressing Tab/arrows to pick an option, and a badge that vanished on that
    /// first keystroke was gone before the user had decided (owner decision, superseding Q6).
    func testDockBadgeCountsEveryPaneThatNeedsYouEvenAfterAKeystroke() throws {
        var labels: [String?] = []
        center.addSink(DockBadgeSink(setBadge: { labels.append($0) }))

        let a = try addPane(active: false)
        let b = try addPane(active: false)
        center.post(request(a, title: "Approve Bash", evidence: .hook))
        center.post(request(b, title: "Approve Edit", evidence: .hook))
        XCTAssertEqual(labels.last, "2")

        center.userDidType(in: a)
        XCTAssertEqual(labels.last, "2", "a keystroke quiets the banner, not the badge — both still need you")
        XCTAssertEqual(center.urgency(pane: a), .needsUser, "the quieted pane still draws its mark")
        XCTAssertEqual(center.counts.interrupting, 1, "the banner let go of the pane the user is in")

        // Only answering (or ack, or the agent moving on) clears the badge.
        center.resolveAll(pane: a, .acknowledged)
        XCTAssertEqual(labels.last, "1", "one pane answered; the other still needs you")
        center.resolveAll(pane: b, .acknowledged)
        XCTAssertEqual(labels.last, .some(nil), "both answered: no red pill")
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

    // MARK: Authorization — "macOS is not going to show this, and nobody told you"
    //
    // The bug these guard: a denial stored by an earlier launch made every banner fail silently.
    // The app logged one `error` line and carried on; the pane mark, the pill and the info strip
    // all drew, so from inside QuickTerm everything looked fine while the user sat in another app
    // waiting for a banner that was never coming.

    /// The probe at launch: macOS says denied, the user is told **once**, and the status is
    /// readable afterwards. Asking again changes nothing — no second hint, and no prompt loop.
    func testADeniedProbePostsExactlyOneHintPerLaunch() throws {
        let centre = AuthorizingNotificationCenter()
        centre.status = .denied
        var announced = 0
        let sink = SystemNotificationSink(center: centre, locator: locator, route: { _ in },
                                          settings: { [self] in settings },
                                          announceDenied: { announced += 1 })

        sink.refreshAuthorizationStatus()
        sink.refreshAuthorizationStatus()
        sink.refreshAuthorizationStatus()

        XCTAssertEqual(announced, 1, "once per launch, however many times we ask macOS")
        XCTAssertEqual(sink.authorizationStatus, .denied)
    }

    /// Every other answer is recorded and says nothing. `notDetermined` in particular is left
    /// alone: the lazy `requestAuthorization` at the first banner is what asks, and telling the
    /// user "notifications are off" before anybody has been asked would be false.
    func testOnlyADenialIsAnnounced() throws {
        for status in [SystemNotificationStatus.authorized, .notDetermined, .unavailable] {
            let centre = AuthorizingNotificationCenter()
            centre.status = status
            var announced = 0
            let sink = SystemNotificationSink(center: centre, locator: locator, route: { _ in },
                                              settings: { [self] in settings },
                                              announceDenied: { announced += 1 })
            sink.refreshAuthorizationStatus()
            XCTAssertEqual(sink.authorizationStatus, status)
            XCTAssertEqual(announced, 0, "\(status.rawValue) is not a denial")
        }
    }

    /// A sink that has asked nothing reports `unavailable`, which is **not** `denied`: an agent
    /// that read "denied" here would tell the user their settings are wrong when in fact nobody
    /// looked. (This is also the test host's own state — its centre is inert.)
    func testAnUnaskedSinkReportsUnavailableRatherThanDenied() throws {
        XCTAssertEqual(sink.authorizationStatus, .unavailable)
    }

    /// The second road in: permission revoked while the app runs. The probe ran at launch and said
    /// `authorized`; the banner is refused anyway, and that refusal is now reported instead of
    /// disappearing into the error log.
    func testABannerRefusedAsNotAllowedReportsDeniedOnce() throws {
        let centre = AuthorizingNotificationCenter()
        centre.status = .authorized
        centre.addError = NSError(domain: UNErrorDomain,
                                  code: UNError.Code.notificationsNotAllowed.rawValue)
        var announced = 0
        let sink = SystemNotificationSink(center: centre, locator: locator, route: { _ in },
                                          settings: { [self] in settings },
                                          announceDenied: { announced += 1 })
        // The fixture's sink holds `NoticeSinkID.system`, and `addSink` refuses a second sink
        // under an id it already has — so this one has to take its place, not queue behind it.
        center.removeSink(id: NoticeSinkID.system)
        center.addSink(sink)
        sink.refreshAuthorizationStatus()
        XCTAssertEqual(sink.authorizationStatus, .authorized)

        center.post(request(try addPane(active: false)))
        center.post(request(try addPane(active: false)))

        XCTAssertEqual(sink.authorizationStatus, .denied)
        XCTAssertEqual(announced, 1, "two refused banners are still one thing to tell the user")
    }

    /// Any other `add` failure is a malformed request, not a permission state, and must not be
    /// reported as one — a user sent to System Settings over a bad payload finds a switch that is
    /// already on and stops believing the app.
    func testAnUnrelatedAddFailureIsNotReportedAsADenial() throws {
        let centre = AuthorizingNotificationCenter()
        centre.addError = NSError(domain: "SomeOtherDomain", code: 42)
        var announced = 0
        let sink = SystemNotificationSink(center: centre, locator: locator, route: { _ in },
                                          settings: { [self] in settings },
                                          announceDenied: { announced += 1 })
        center.removeSink(id: NoticeSinkID.system)
        center.addSink(sink)

        center.post(request(try addPane(active: false)))
        XCTAssertEqual(centre.recorder.added.count, 1, "the banner really was attempted")

        XCTAssertEqual(sink.authorizationStatus, .unavailable)
        XCTAssertEqual(announced, 0)
    }

    /// What the default announcement actually does: a pane-less `info` notice the user can read,
    /// and a line in the activity log (which carries the OSLog mirror with it). Called twice on
    /// purpose — the centre's own deduplication is the second lock under the sink's latch.
    func testTheDefaultAnnouncementPostsOneAppNoticeAndOneLogLine() throws {
        // The shared centre, because that is where `reportDenialToTheUser` posts — swept clean on
        // both sides so this case neither reads nor leaves anybody else's notices.
        let shared = NoticeCenter.shared
        shared.resetForTesting()
        ControlActivityLog.shared.clear()
        defer {
            shared.resetForTesting()
            ControlActivityLog.shared.clear()
        }

        SystemNotificationSink.reportDenialToTheUser()
        SystemNotificationSink.reportDenialToTheUser()

        XCTAssertEqual(shared.appNotices.count, 1, "the same sentence twice is one thing to say")
        let posted = try XCTUnwrap(shared.appNotices.first)
        XCTAssertEqual(posted.title, L("notice.system.denied"))
        XCTAssertEqual(posted.source.id, "custom:system")
        XCTAssertEqual(posted.urgency, .info)
        XCTAssertTrue(shared.live.isEmpty,
                      "it belongs to no pane, so it joins no pane's notices and raises no mark")
        XCTAssertEqual(shared.counts, NoticeCounts(), "and it is not a number on the Dock icon")
        XCTAssertEqual(
            ControlActivityLog.shared.recent().filter { $0.command == SystemNotificationSink.deniedCommand }.count,
            2,
            "the log is a record of what happened, so both discoveries are in it")
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

/// A recorder that can also answer "where does macOS stand" and fail an `add`.
///
/// `RecordingNotificationCenter` cannot: it lives in `NoticeTestSupport` and `add` there always
/// succeeds, and its `getNotificationSettings` is an empty body because `UNNotificationSettings`
/// has **no public initialiser** — which is precisely why the denied path had no test until now.
/// Composition rather than subclassing, because the recorder is `final`.
private final class AuthorizingNotificationCenter: UserNotificationCentering {
    let recorder = RecordingNotificationCenter()

    /// What `authorizationStatus` answers — synchronously and on the caller's thread, which is
    /// what makes "exactly one hint was posted" assertable without a run-loop spin.
    var status: SystemNotificationStatus = .unavailable
    /// What `add` calls back with. nil = accepted.
    var addError: (any Error)?

    var delegate: UNUserNotificationCenterDelegate? {
        get { recorder.delegate }
        set { recorder.delegate = newValue }
    }

    func requestAuthorization(options: UNAuthorizationOptions,
                              completionHandler: @escaping @Sendable (Bool, (any Error)?) -> Void) {
        recorder.requestAuthorization(options: options, completionHandler: completionHandler)
    }

    func getNotificationSettings(completionHandler: @escaping @Sendable (UNNotificationSettings) -> Void) {}

    func authorizationStatus(_ completion: @escaping @Sendable (SystemNotificationStatus) -> Void) {
        completion(status)
    }

    func add(_ request: UNNotificationRequest,
             withCompletionHandler: (@Sendable ((any Error)?) -> Void)?) {
        recorder.add(request, withCompletionHandler: nil)
        withCompletionHandler?(addError)
    }

    func removeDeliveredNotifications(withIdentifiers identifiers: [String]) {
        recorder.removeDeliveredNotifications(withIdentifiers: identifiers)
    }

    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {
        recorder.removePendingNotificationRequests(withIdentifiers: identifiers)
    }
}
