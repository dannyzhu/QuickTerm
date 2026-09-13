import AppKit
import XCTest
@testable import QuickTerm

// MARK: - The engine's own notice sources

/// **The three Phase 1 sources that are not an agent** (spec §3.5 "Sources beyond agents in
/// Phase 1", contract §10.6): a desktop notification (OSC 9 / 99 / 777), a finished command
/// (OSC 133) and the bell.
///
/// These cases drive the Swift half of the engine callbacks through `GhosttyNoticeProducer`,
/// whose three closures are replaced here by recorders. That seam is the reason the whole file
/// needs no window, no pane, no libghostty surface and no live `UNUserNotificationCenter`: what
/// is being asserted is a policy — *what* each source posts and *whether* the settings let it —
/// and every one of those decisions is made before a notice ever reaches the centre.
///
/// The centre's own behaviour (coalescing, counts, resolution) is `NoticeCenterTests`; the
/// banner is `NoticeSystemSinkTests`. Nothing here asserts either.
@MainActor
final class NoticeSourcesTests: XCTestCase {
    /// Every request the producers handed over, in order.
    private var posted: [NoticeRequest] = []
    /// The `[notifications]` values the producers see. A case sets the two keys it is about.
    private var settings = NoticeSettings()
    /// What `ControlHandleRegistry` would answer, without touching the process-wide registry.
    private var handles: [UUID: String] = [:]

    private let pane = UUID()

    override func setUp() async throws {
        try await super.setUp()
        posted = []
        settings = NoticeSettings()
        handles = [:]
        GhosttyNoticeProducer.post = { [self] in posted.append($0) }
        GhosttyNoticeProducer.settings = { [self] in settings }
        GhosttyNoticeProducer.handle = { [self] in handles[$0] }
    }

    override func tearDown() async throws {
        // Put the singleton back: these are process-wide closures, and a recorder left behind
        // would capture this test case for the rest of the run.
        GhosttyNoticeProducer.resetForTesting()
        try await super.tearDown()
    }

    /// The formatting the command producer uses, repeated here so a body can be asserted as a
    /// whole sentence instead of by substring.
    private func formatted(_ duration: Duration) -> String {
        duration.formatted(
            .units(
                allowed: [.hours, .minutes, .seconds, .milliseconds],
                width: .abbreviated,
                fractionalPart: .hide
            )
        )
    }

    private func onlyRequest(file: StaticString = #filePath, line: UInt = #line) throws -> NoticeRequest {
        XCTAssertEqual(posted.count, 1, "expected exactly one notice", file: file, line: line)
        return try XCTUnwrap(posted.first, file: file, line: line)
    }

    // MARK: OSC 9 / 99 / 777

    func testDesktopNotificationBecomesAnInfoTerminalNotice() throws {
        GhosttyNoticeProducer.desktopNotification(
            pane: pane, title: "Build finished", body: "npm test exited 0")

        let request = try onlyRequest()
        XCTAssertEqual(request.source.id, "terminal")
        XCTAssertEqual(request.pane, pane)
        XCTAssertEqual(request.urgency, .info)
        XCTAssertEqual(request.evidence, .notification)
        XCTAssertEqual(request.title, "Build finished")
        XCTAssertEqual(request.body, "npm test exited 0")
        // The body is the program's own words, so it is sensitive by construction — that is what
        // keeps it out of Notification Center's database under the default `system-body`.
        XCTAssertTrue(request.bodySensitive)
        XCTAssertNil(request.origin)
    }

    func testDesktopNotificationWithoutATitleIsNamedByThePaneHandle() throws {
        handles[pane] = "t7"
        GhosttyNoticeProducer.desktopNotification(pane: pane, title: "", body: "ready")

        XCTAssertEqual(try onlyRequest().title, L("notice.terminal.title", "t7"))
    }

    /// A title that is nothing but control characters is as empty as `""`: the centre would
    /// sanitise it away and fall back to "Notice from terminal", which says less than the handle.
    func testDesktopNotificationTitleOfControlCharactersIsTreatedAsEmpty() throws {
        handles[pane] = "t9"
        GhosttyNoticeProducer.desktopNotification(pane: pane, title: "\u{1b}\u{7}", body: "ready")

        XCTAssertEqual(try onlyRequest().title, L("notice.terminal.title", "t9"))
    }

    /// No handle has been allocated (nobody has addressed this pane through the control plane):
    /// hand the centre an empty title and let its own fallback name the source. Inventing a
    /// handle here would allocate one as a side effect of a program ringing for attention.
    func testDesktopNotificationWithoutATitleOrAHandleLeavesTheTitleToTheCentre() throws {
        GhosttyNoticeProducer.desktopNotification(pane: pane, title: "", body: "ready")

        XCTAssertEqual(try onlyRequest().title, "")
    }

    // MARK: OSC 133

    func testCommandFinishedNeverPostsNothing() {
        settings.commandFinished = "never"
        GhosttyNoticeProducer.commandFinished(pane: pane, exitCode: 0, duration: .seconds(600))

        XCTAssertTrue(posted.isEmpty)
    }

    func testCommandFinishedLongSkipsShortCommandsAndPostsAtTenSeconds() {
        settings.commandFinished = "long"

        GhosttyNoticeProducer.commandFinished(pane: pane, exitCode: 0, duration: .seconds(3))
        XCTAssertTrue(posted.isEmpty, "three seconds is not a long command")

        // Exactly ten seconds counts: `long` is "over 10 s" as a threshold, not a strict >.
        GhosttyNoticeProducer.commandFinished(pane: pane, exitCode: 0, duration: .seconds(10))
        XCTAssertEqual(posted.count, 1)

        GhosttyNoticeProducer.commandFinished(pane: pane, exitCode: 0, duration: .seconds(42))
        XCTAssertEqual(posted.count, 2)
    }

    func testCommandFinishedAlwaysPostsEvenAOneSecondCommand() throws {
        settings.commandFinished = "always"
        GhosttyNoticeProducer.commandFinished(pane: pane, exitCode: 0, duration: .seconds(1))

        let request = try onlyRequest()
        XCTAssertEqual(request.source.id, "command")
        XCTAssertEqual(request.urgency, .info)
    }

    /// The sentence QuickTerm composed itself: `.composed` evidence, and the one body a banner
    /// may show under the default `system-body = "composed"` because it carries a duration and an
    /// exit code, never a command line.
    func testCommandFinishedTextIsComposedAndNotSensitive() throws {
        settings.commandFinished = "always"
        GhosttyNoticeProducer.commandFinished(pane: pane, exitCode: 0, duration: .seconds(12))

        let request = try onlyRequest()
        XCTAssertEqual(request.evidence, .composed)
        XCTAssertFalse(request.bodySensitive)
        XCTAssertEqual(request.title, L("notice.command.succeeded"))
        XCTAssertEqual(request.body, L("notice.command.took-exit", formatted(.seconds(12)), 0))
    }

    func testCommandFinishedFailedCarriesTheExitCode() throws {
        settings.commandFinished = "always"
        GhosttyNoticeProducer.commandFinished(pane: pane, exitCode: 7, duration: .seconds(2))

        let request = try onlyRequest()
        XCTAssertEqual(request.title, L("notice.command.failed"))
        XCTAssertEqual(request.body, L("notice.command.took-exit", formatted(.seconds(2)), 7))
    }

    /// A negative code means the shell reported no status at all (a signal, or a prompt mark that
    /// carried none). The body must not invent one — "exited with code -1" is a number no shell
    /// ever gave us.
    func testCommandFinishedWithoutAnExitCodeSaysOnlyHowLongItTook() throws {
        settings.commandFinished = "always"
        GhosttyNoticeProducer.commandFinished(pane: pane, exitCode: -1, duration: .seconds(5))

        let request = try onlyRequest()
        XCTAssertEqual(request.title, L("notice.command.finished"))
        XCTAssertEqual(request.body, L("notice.command.took", formatted(.seconds(5))))
    }

    // MARK: BEL

    func testBellIsIgnoredByDefault() {
        XCTAssertEqual(settings.bell, "ignore")
        GhosttyNoticeProducer.bell(pane: pane)

        XCTAssertTrue(posted.isEmpty)
    }

    func testBellPostsAnInfoNoticeWhenAskedFor() throws {
        settings.bell = "info"
        GhosttyNoticeProducer.bell(pane: pane)

        let request = try onlyRequest()
        XCTAssertEqual(request.source.id, "bell")
        XCTAssertEqual(request.urgency, .info)
        XCTAssertEqual(request.evidence, .notification)
        XCTAssertEqual(request.title, L("notice.bell.title"))
        // A bell says nothing but that it rang, so there is no body to be sensitive about.
        XCTAssertNil(request.body)
    }

    // MARK: The rule that covers all three

    /// **No Phase 1 producer posts `needsUser`** (contract §10.6). Only an agent hook may claim a
    /// human is needed; a program ringing for attention, a command ending and a bell are all
    /// information. If this ever fails, the Dock badge and the pane mark have started counting
    /// things the user cannot act on.
    func testNoEngineSourceEverPostsNeedsUser() {
        settings.commandFinished = "always"
        settings.bell = "info"
        handles[pane] = "t3"

        GhosttyNoticeProducer.desktopNotification(pane: pane, title: "", body: "attention")
        GhosttyNoticeProducer.desktopNotification(pane: pane, title: "Alert", body: "attention")
        GhosttyNoticeProducer.commandFinished(pane: pane, exitCode: 0, duration: .seconds(1))
        GhosttyNoticeProducer.commandFinished(pane: pane, exitCode: 2, duration: .seconds(90))
        GhosttyNoticeProducer.bell(pane: pane)

        XCTAssertEqual(posted.count, 5)
        XCTAssertTrue(posted.allSatisfy { $0.urgency == .info })
        XCTAssertTrue(posted.allSatisfy { $0.pane == self.pane })
        XCTAssertEqual(Set(posted.map(\.source.id)), ["terminal", "command", "bell"])
    }
}
