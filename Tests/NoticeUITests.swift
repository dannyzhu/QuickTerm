import AppKit
import SwiftUI
import XCTest
@testable import QuickTerm

/// **The two surfaces that draw a notice, and the click that takes you to one** (design §3.5,
/// contract §10.5 and §10.7): the red dot on a pane's top border, the `●N` on a workspace pill,
/// and the routing from a notice's pane uuid to the screen that holds it.
///
/// The geometry cases are pure functions for the same reason `PaneTitleTests` is: a view cannot
/// measure "does not fit", and "the title runs under the dot" is a bug you can only see with your
/// eyes unless the numbers are pinned down here. The pill case lays the real view out and compares
/// it with the budget, because the budget and the drawing are two separate expressions and the
/// whole row falls over when they disagree by a few points.
@MainActor
final class NoticeUITests: XCTestCase {
    private let metrics = PaneTitleBadge.Metrics.standard

    /// Wide enough that nothing can fail to fit.
    private var roomy: CGFloat { 4000 }

    private var app: AppDelegate {
        get throws { try XCTUnwrap(NSApp.delegate as? AppDelegate) }
    }

    override func setUp() async throws {
        try await super.setUp()
        // The shared centre is the one the pill and the frame read; without the real locator it
        // answers `.unknownPane` to every post.
        AppDelegate.ensureNoticeInterfaceInstalled()
        NoticeCenter.shared.resetForTesting()
    }

    override func tearDown() async throws {
        NoticeCenter.shared.resetForTesting()
        try await super.tearDown()
    }

    /// Turn the runloop so SwiftUI mounting, focus hand-over and the registry's asynchronous
    /// removal actually land.
    private func spin(_ seconds: TimeInterval = 0.3) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    // MARK: The pane mark's geometry

    /// The dot is 6pt, sits 8pt off the right edge, and is centred **on** the border line - the
    /// same relationship the title has with that line, so the two read as one piece of chrome.
    func testMarkSitsOnTheLineAtTheTopRightCorner() throws {
        let rect = try XCTUnwrap(PaneTitleBadge.markRect(topEdgeWidth: 400))
        XCTAssertEqual(rect.width, PaneTitleBadge.markDiameter)
        XCTAssertEqual(rect.height, PaneTitleBadge.markDiameter)
        XCTAssertEqual(rect.maxX, 400 - PaneTitleBadge.markTrailingInset,
                       "the inset is measured from the outer right edge to the dot's trailing edge")
        XCTAssertEqual(rect.midY, PaneTitleBadge.lineWidth / 2, accuracy: 0.001,
                       "the line has to run through the dot, not past it")
    }

    /// The border is broken by `markGap` on each side of the dot, and never past the corner.
    func testMarkGapBracketsTheDot() throws {
        for width in [CGFloat(40), 120, 400, 4000] {
            let rect = try XCTUnwrap(PaneTitleBadge.markRect(topEdgeWidth: width))
            let gap = try XCTUnwrap(PaneTitleBadge.markGapRange(topEdgeWidth: width))
            XCTAssertEqual(gap.start, rect.minX - PaneTitleBadge.markGap, accuracy: 0.001)
            XCTAssertEqual(gap.end, rect.maxX + PaneTitleBadge.markGap, accuracy: 0.001)
            XCTAssertLessThanOrEqual(gap.end, width, "the gap may not run off the top-right corner")
            XCTAssertGreaterThan(gap.start, 0, "a stretch of line always survives to the left of it")
        }
    }

    /// Too narrow for the dot and its gaps: draw nothing at all. Not half a dot over the corner,
    /// and not a notch with nothing in it.
    func testTooNarrowDrawsNoMark() {
        for width in [CGFloat(0), 1, 10, PaneTitleBadge.markReserve - 0.5] {
            XCTAssertNil(PaneTitleBadge.markRect(topEdgeWidth: width), "top edge \(width)")
            XCTAssertNil(PaneTitleBadge.markGapRange(topEdgeWidth: width), "top edge \(width)")
            XCTAssertNil(PaneTitleBadge.markHitRect(topEdgeWidth: width), "top edge \(width)")
        }
        XCTAssertNotNil(PaneTitleBadge.markRect(topEdgeWidth: PaneTitleBadge.markReserve),
                        "exactly the reserve is enough: the dot, its gaps and its inset")
    }

    /// The tooltip target is bigger than the dot (6pt is not pointable) and centred on it.
    func testMarkHitTargetIsCentredOnTheDot() throws {
        let rect = try XCTUnwrap(PaneTitleBadge.markRect(topEdgeWidth: 300))
        let hit = try XCTUnwrap(PaneTitleBadge.markHitRect(topEdgeWidth: 300))
        XCTAssertEqual(hit.midX, rect.midX, accuracy: 0.001)
        XCTAssertEqual(hit.midY, rect.midY, accuracy: 0.001)
        XCTAssertEqual(hit.width, PaneTitleBadge.markHitSize)
        XCTAssertEqual(hit.height, PaneTitleBadge.markHitSize)
        XCTAssertGreaterThan(hit.width, rect.width)
    }

    /// **The reserve grows by the dot.** Without a mark the title only has to leave two characters
    /// of line on the right; with one it has to leave those two characters *and* the dot's
    /// `markReserve`, or a title that "just fits" is drawn straight under the dot.
    func testTheDotCostsTheTitleExactlyItsReserve() {
        for width in [CGFloat(100), 240, 4000] {
            XCTAssertEqual(
                PaneTitleBadge.availableTextWidth(topEdgeWidth: width, mark: true, metrics: metrics),
                PaneTitleBadge.availableTextWidth(topEdgeWidth: width, mark: false, metrics: metrics)
                    - PaneTitleBadge.markReserve,
                accuracy: 0.001, "top edge \(width)")
        }
        XCTAssertEqual(PaneTitleBadge.markReserve,
                       PaneTitleBadge.markDiameter + 2 * PaneTitleBadge.markGap
                           + PaneTitleBadge.markTrailingInset)
    }

    /// The same pane, the same title, one with an alarm on it: the marked frame draws no more
    /// characters than the unmarked one, and at the width where the reserve bites it draws fewer.
    func testAMarkedFrameNeverDrawsMoreTitleThanAnUnmarkedOne() {
        let title = "build the world"
        // The exact top edge where this title fills the unmarked budget to the last point.
        let exact = metrics.width(of: title) + metrics.leadingInset + metrics.sidePadding
            + CGFloat(metrics.reservedCharacters) * metrics.characterWidth
        XCTAssertEqual(PaneTitleBadge.fit(title: title, topEdgeWidth: exact, metrics: metrics), title,
                       "precondition: without the dot the whole title fits exactly")
        let marked = PaneTitleBadge.fit(title: title, topEdgeWidth: exact, mark: true, metrics: metrics)
        XCTAssertNotEqual(marked, title, "with the dot there is `markReserve` less room")
        XCTAssertTrue(marked?.hasSuffix(TitleRules.ellipsis) ?? false,
                      "what still fits is drawn truncated, not dropped")
        for width in stride(from: CGFloat(30), through: 600, by: 7) {
            let bare = PaneTitleBadge.fit(title: title, topEdgeWidth: width, metrics: metrics)?.count ?? 0
            let dotted = PaneTitleBadge.fit(title: title, topEdgeWidth: width, mark: true,
                                            metrics: metrics)?.count ?? 0
            XCTAssertLessThanOrEqual(dotted, bare, "top edge \(width)")
        }
    }

    /// **The two gaps never touch.** The title's notch is on the left, the dot's on the right, and
    /// whatever the width, whatever the title, a stretch of unbroken line survives between them.
    func testTitleGapNeverReachesTheMarkGap() {
        let titles = ["b", "build", "开发环境很长很长很长", String(repeating: "a", count: 40)]
        for width in stride(from: CGFloat(20), through: 900, by: 11) {
            guard let markGap = PaneTitleBadge.markGapRange(topEdgeWidth: width) else { continue }
            for title in titles {
                guard let badge = PaneTitleBadge.place(title: title, topEdgeWidth: width,
                                                       overhang: 5, mark: true, metrics: metrics)
                else { continue }
                XCTAssertLessThan(badge.gapEnd, markGap.start,
                                  "top edge \(width), `\(title)`: the title's notch ran into the dot's")
            }
        }
    }

    // MARK: The workspace pill's count

    /// The budget has to equal what SwiftUI lays out, counts included - the row has 8pt of slack
    /// in total, and a `●2` that is drawn but not budgeted is 20 of them.
    func testPillWidthWithACountMatchesTheLaidOutPill() {
        for (name, count) in [("dev", 1), ("dev", 2), (nil, 1), (nil, 12), ("开发", 3),
                              (String(repeating: "a", count: 12), 9)] as [(String?, Int)] {
            for showingTitles in [true, false] {
                let laidOut = NSHostingView(
                    rootView: WorkspacePill.pill(title: name, index: 2, active: false,
                                                 showingTitles: showingTitles,
                                                 count: count)).fittingSize.width
                let budget = WorkspacePill.pillWidth(title: name, index: 2, active: false,
                                                     showingTitles: showingTitles, count: count)
                XCTAssertEqual(budget, laidOut, accuracy: 1,
                               "`\(name ?? "-")` ●\(count), names \(showingTitles): "
                                   + "budget \(budget), laid out \(laidOut)")
            }
        }
    }

    /// No count, nothing changes: a numbered pill is still exactly those 18pt, and a named one is
    /// exactly what it was before this feature existed.
    func testNoCountLeavesEveryPillExactlyAsItWas() {
        XCTAssertEqual(WorkspacePill.countSuffix(0), "")
        XCTAssertEqual(WorkspacePill.label(title: "dev", index: 0, active: false,
                                           showingTitles: true, count: 0), "dev")
        XCTAssertEqual(WorkspacePill.pillWidth(title: nil, index: 3, active: false,
                                               showingTitles: true, count: 0),
                       WorkspacePill.plainWidth)
        XCTAssertEqual(WorkspacePill.pillWidth(title: "dev", index: 0, active: false,
                                               showingTitles: true, count: 0),
                       WorkspacePill.pillWidth(title: "dev", index: 0, active: false,
                                               showingTitles: true))
    }

    /// A count is drawn whether the row shows names or numbers, so it is in the budget in both
    /// cases - including on an unnamed pill, which stops being 18pt wide the moment it carries one.
    func testACountWidensTheLeftSection() {
        let titles: [String?] = ["dev", "web", nil, nil, nil]
        let bare = WorkspacePill.leftSectionWidth(titles: titles, activeIndex: 0,
                                                 showingTitles: true, flash: nil)
        let counted = WorkspacePill.leftSectionWidth(titles: titles, activeIndex: 0,
                                                    showingTitles: true, flash: nil,
                                                    counts: [2, 0, 1, 0, 0])
        XCTAssertGreaterThan(counted, bare)
        XCTAssertGreaterThan(
            WorkspacePill.pillWidth(title: nil, index: 2, active: false, showingTitles: false,
                                    count: 1),
            WorkspacePill.plainWidth,
            "`3 ●1` does not fit in the 18pt a plain number gets")
    }

    /// **The all-or-nothing fallback still holds with counts in it.** At a width where the names
    /// fit bare, the same row with a count on it goes back to numbers - all of them together.
    func testACountCanBeWhatPushesTheRowBackToNumbers() {
        let titles: [String?] = ["develop", "website", "logs", "notes", "scratch"]
        let counts = [3, 2, 1, 1, 1]
        let clock: CGFloat = 120
        let bare = WorkspacePill.leftSectionWidth(titles: titles, activeIndex: 0,
                                                 showingTitles: true, flash: nil)
        // Exactly wide enough for the names without counts, and not one point more.
        let width = 2 * (bare + WorkspacePill.clearance + clock / 2)
        XCTAssertTrue(WorkspacePill.showsTitles(contentWidth: width, titles: titles, activeIndex: 0,
                                                clockWidth: clock, flash: nil))
        XCTAssertFalse(WorkspacePill.showsTitles(contentWidth: width, titles: titles, activeIndex: 0,
                                                 clockWidth: clock, flash: nil, counts: counts),
                       "the counts are drawn either way, so they have to be paid for either way")
    }

    // MARK: Routing a notice to the screen its pane lives on

    /// Run a case with a second screen open, always closing it and handing key back to the first.
    private func withSecondScreen(
        _ body: (AppDelegate, MainWindowController, MainWindowController) throws -> Void
    ) throws {
        let app = try self.app
        let primary = try XCTUnwrap(app.screens.primary)
        let second = app.newScreen(on: NSScreen.main)
        spin()
        defer {
            if app.controllers.contains(where: { $0 === second }) { app.closeScreen(second) }
            primary.window?.makeKeyAndOrderFront(nil)
            spin()
        }
        try body(app, primary, second)
    }

    /// A notice carries a pane uuid and nothing else. The click has to land on **that pane's own
    /// screen**, in its own workspace - not on whichever window happens to hold key.
    func testRoutingRevealsThePaneOnItsOwnScreen() throws {
        try withSecondScreen { _, primary, second in
            second.switchWorkspace(2)
            second.perform(.newTerminal)
            spin(0.5)
            let pane = try XCTUnwrap(second.focusedPane)
            second.switchWorkspace(0)
            primary.window?.makeKeyAndOrderFront(nil)
            spin()
            XCTAssertEqual(second.model.activeIndex, 0, "precondition: the pane is out of sight")

            XCTAssertTrue(AppDelegate.revealNoticePane(pane.id))
            spin(0.5)
            XCTAssertEqual(second.model.activeIndex, 2, "its own workspace came forward")
            XCTAssertEqual(primary.model.activeIndex, 0, "the other screen was left alone")
            XCTAssertTrue(second.focusedPane === pane, "and the pane itself has focus")
            // Key status is the one clause a test cannot force: macOS hands a window key only
            // while its application is active, and the test host is not frontmost when the suite
            // runs under `xcodebuild`. So: its own window took key, or nothing did - and either
            // way key must not have stayed on the screen the pane does not live on, which is the
            // failure this case exists to catch.
            XCTAssertFalse(primary.window?.isKeyWindow == true,
                           "key must not stay on the other screen")
            XCTAssertTrue(second.window?.isKeyWindow == true || !NSApp.isActive,
                          "app active \(NSApp.isActive), key window "
                              + "\(NSApp.keyWindow?.title ?? "none")")

            second.closePane(pane, confirmIfNeeded: false, animated: false)
            spin()
        }
    }

    /// A pane that is gone (the banner outlived it) routes nowhere and says so, rather than
    /// falling back to some other pane.
    func testRoutingAnUnknownPaneDoesNothing() {
        XCTAssertFalse(AppDelegate.revealNoticePane(UUID()))
    }

    /// The pill's counts are per screen **and** per workspace: an alarm on screen 2 must never
    /// turn up on screen 1's status bar.
    func testWorkspaceCountsBelongToOneScreenOnly() throws {
        try withSecondScreen { _, primary, second in
            second.switchWorkspace(3)
            second.perform(.newTerminal)
            spin(0.5)
            let pane = try XCTUnwrap(second.focusedPane)

            let outcome = NoticeCenter.shared.post(
                NoticeRequest(source: .terminal, pane: pane.id, urgency: .needsUser,
                              evidence: .notification, title: "Awaiting approval"))
            guard case .posted = outcome else { return XCTFail("the post has to land: \(outcome)") }

            let onSecond = AppDelegate.workspaceNoticeCounts(for: second.model)
            XCTAssertEqual(onSecond.count, second.model.layouts.count)
            XCTAssertEqual(onSecond[3], 1)
            XCTAssertEqual(onSecond.reduce(0, +), 1, "one pane, in one workspace")
            XCTAssertEqual(AppDelegate.workspaceNoticeCounts(for: primary.model).reduce(0, +), 0,
                           "the other screen's pills know nothing about it")

            // And the pill actually draws it.
            XCTAssertEqual(WorkspacePill.label(title: "dev", index: 3, active: false,
                                               showingTitles: true, count: onSecond[3]), "dev ●1")

            second.closePane(pane, confirmIfNeeded: false, animated: false)
            spin()
        }
    }
}
