import AppKit
import GhosttyKit
import XCTest
@testable import QuickTerm

/// **The app side of OSC 7501** (spec decisions 1–3, 15, 20): the engine's C report becomes a
/// `ProgramStatusReport`, its text is made safe to draw, and the three engine actions (report,
/// prompt start, reset) plus the user's own Reset reach the pane's store, unless
/// `[agents] program-status = false`.
///
/// The decoding cases build the real C struct from Swift strings, so `from(_:)` is tested on the
/// type the engine hands over. The routing cases drive `Ghostty.App.action` with a real surface
/// (no window), because the part worth pinning is that the target surface resolves to its pane.
@MainActor
final class ProgramStatusReportTests: XCTestCase {
    // MARK: Helpers

    /// Build a `ghostty_action_program_status_s` the way the engine does: NUL-terminated strings,
    /// "" for an absent field, -1 for an absent progress. The strings live only inside `body`.
    private func withCReport<T>(
        state: String = "working", kind: String = "", progress: Int32 = -1, id: String = "",
        app: String = "", title: String = "", msg: String = "",
        _ body: (ghostty_action_program_status_s) throws -> T
    ) rethrows -> T {
        let owned = [state, kind, id, app, title, msg].map { strdup($0)! }
        defer { owned.forEach { free($0) } }
        let c = ghostty_action_program_status_s(
            state: UnsafePointer(owned[0]), kind: UnsafePointer(owned[1]), progress: progress,
            id: UnsafePointer(owned[2]), app: UnsafePointer(owned[3]),
            title: UnsafePointer(owned[4]), msg: UnsafePointer(owned[5]))
        return try body(c)
    }

    /// Record every call the store receives for `pane` until the test ends. Other panes in the
    /// test host (real surfaces from other cases) can reach the shared store too, so the log is
    /// filtered to this pane.
    private func recordStore(for pane: UUID) -> () -> [String] {
        var log: [String] = []
        let previousEnabled = ProgramStatusRouter.isEnabled
        ProgramStatusStore.shared.recordForTesting = { entry in
            if entry.contains(pane.uuidString) { log.append(entry) }
        }
        addTeardownBlock { @MainActor in
            ProgramStatusStore.shared.recordForTesting = nil
            ProgramStatusRouter.isEnabled = previousEnabled
        }
        return { log.map { $0.replacingOccurrences(of: pane.uuidString, with: "PANE") } }
    }

    private func makeSurfaceView() throws -> Ghostty.SurfaceView {
        let appDelegate = try XCTUnwrap(NSApp.delegate as? AppDelegate)
        return Ghostty.SurfaceView(try XCTUnwrap(appDelegate.ghostty.app), baseConfig: nil)
    }

    /// Send one engine action to a surface through the same entry point libghostty calls.
    private func send(_ tag: ghostty_action_tag_e, to view: Ghostty.SurfaceView,
                      payload: ghostty_action_program_status_s? = nil) throws {
        let appDelegate = try XCTUnwrap(NSApp.delegate as? AppDelegate)
        let app = try XCTUnwrap(appDelegate.ghostty.app)
        var target = ghostty_target_s()
        target.tag = GHOSTTY_TARGET_SURFACE
        target.target.surface = try XCTUnwrap(view.surface)
        var action = ghostty_action_s()
        action.tag = tag
        if let payload { action.action.program_status = payload }
        XCTAssertTrue(Ghostty.App.action(app, target: target, action: action))
    }

    // MARK: Decoding

    func testDecodesEveryField() throws {
        let report = try XCTUnwrap(withCReport(
            state: "blocked", kind: "permission", progress: 42, id: "build/test",
            app: "cargo", title: "Build", msg: "waiting for 你 ✅") { ProgramStatusReport.from($0) })
        XCTAssertEqual(report, ProgramStatusReport(
            state: .blocked, kind: .permission, progress: 42, id: ["build", "test"],
            app: "cargo", title: "Build", message: "waiting for 你 ✅"))
    }

    func testEmptyStringsAreAbsent() throws {
        let report = try XCTUnwrap(withCReport(state: "idle") { ProgramStatusReport.from($0) })
        XCTAssertEqual(report, ProgramStatusReport(
            state: .idle, kind: nil, progress: nil, id: [], app: nil, title: nil, message: nil))
    }

    func testProgressMinusOneIsAbsent() throws {
        XCTAssertNil(withCReport(progress: -1) { ProgramStatusReport.from($0) }?.progress)
        XCTAssertEqual(withCReport(progress: 0) { ProgramStatusReport.from($0) }?.progress, 0)
        XCTAssertEqual(withCReport(progress: 100) { ProgramStatusReport.from($0) }?.progress, 100)
        // Defence in depth: the engine never sends these, and a number outside 0–100 is not a
        // percentage anybody should draw.
        XCTAssertNil(withCReport(progress: 101) { ProgramStatusReport.from($0) }?.progress)
    }

    func testIdSplitsIntoSegments() {
        XCTAssertEqual(withCReport(id: "") { ProgramStatusReport.from($0) }?.id, [])
        XCTAssertEqual(withCReport(id: "job") { ProgramStatusReport.from($0) }?.id, ["job"])
        XCTAssertEqual(withCReport(id: "a/b.c/d-1") { ProgramStatusReport.from($0) }?.id,
                       ["a", "b.c", "d-1"])
    }

    func testUnknownStateOrKindIsRejectedOrAbsent() {
        // An unknown state drops the whole report (the engine already does; this is the backstop).
        XCTAssertNil(withCReport(state: "sleeping") { ProgramStatusReport.from($0) })
        XCTAssertNil(withCReport(state: "") { ProgramStatusReport.from($0) })
        for state in ["idle", "working", "done", "blocked", "error", "clear"] {
            XCTAssertEqual(withCReport(state: state) { ProgramStatusReport.from($0) }?.state.rawValue,
                           state)
        }
        // An unknown kind is only absent.
        let report = withCReport(state: "blocked", kind: "coffee") { ProgramStatusReport.from($0) }
        XCTAssertEqual(report?.state, .blocked)
        XCTAssertNil(report?.kind)
        XCTAssertEqual(withCReport(state: "blocked", kind: "auth") { ProgramStatusReport.from($0) }?.kind,
                       .auth)
    }

    // MARK: Display text

    func testDisplayTextStripsBidiAndZeroWidth() {
        // RLO, ZWSP, LRI, PDI, LRE…PDF, BOM, word joiner and soft hyphen are all format
        // characters (General_Category Cf) and are removed.
        XCTAssertEqual(ProgramStatusReport.displayText("ab\u{202E}cd\u{200B}ef\u{2066}gh\u{2069}"),
                       "abcdefgh")
        XCTAssertEqual(ProgramStatusReport.displayText("\u{202A}x\u{202C}\u{FEFF}y\u{2060}z\u{00AD}"),
                       "xyz")
        // Chinese, emoji and ordinary punctuation are kept as they are.
        XCTAssertEqual(ProgramStatusReport.displayText("构建完成：3 个测试通过 ✅ 🎉 (ok)."),
                       "构建完成：3 个测试通过 ✅ 🎉 (ok).")
    }

    func testDisplayTextKeepsZeroWidthJoinerOnlyInsideEmoji() {
        let family = "👨\u{200D}👩\u{200D}👧"
        let rainbowFlag = "🏳\u{FE0F}\u{200D}🌈"
        let womanTechnologist = "👩🏽\u{200D}💻"   // skin-tone modifier before the joiner
        XCTAssertEqual(ProgramStatusReport.displayText("team \(family)"), "team \(family)")
        XCTAssertEqual(ProgramStatusReport.displayText(rainbowFlag), rainbowFlag)
        XCTAssertEqual(ProgramStatusReport.displayText(womanTechnologist), womanTechnologist)
        // Between letters, digits, or at either end, the joiner is just another invisible character.
        XCTAssertEqual(ProgramStatusReport.displayText("a\u{200D}b 1\u{200D}2"), "ab 12")
        XCTAssertEqual(ProgramStatusReport.displayText("\u{200D}👍\u{200D}"), "👍")
    }

    func testDisplayTextClampsLikeTheBand() {
        // The band's rulebook: control characters out, whitespace trimmed, at most
        // `TitleRules.maxLength` grapheme clusters (a ZWJ family counts as one).
        XCTAssertEqual(ProgramStatusReport.displayText("  line\none\t "), "lineone")
        let long = String(repeating: "长", count: TitleRules.maxLength + 50)
        XCTAssertEqual(ProgramStatusReport.displayText(long).count, TitleRules.maxLength)
        XCTAssertEqual(ProgramStatusReport.displayText(long), TitleRules.fromTypedInput(long))
        // A line or paragraph separator would wrap the one-line band.
        XCTAssertEqual(ProgramStatusReport.displayText("a\u{2028}b\u{2029}c"), "a b c")
        XCTAssertEqual(ProgramStatusReport.displayText("\u{202E}\u{200B}"), "")
    }

    // MARK: Config

    func testConfigKeyDefaultsOnAndParsesOff() {
        XCTAssertTrue(ConfigStore.Settings().programStatus)
        XCTAssertFalse(ConfigStore.parse("[agents]\nprogram-status = false\n").programStatus)
        XCTAssertTrue(ConfigStore.parse("[agents]\nprogram-status = true\n").programStatus)
    }

    func testConfigOffRoutesNothing() throws {
        let pane = UUID()
        let log = recordStore(for: pane)
        let report = ProgramStatusReport(state: .working, kind: nil, progress: 5, id: [],
                                         app: nil, title: nil, message: nil)

        ProgramStatusRouter.isEnabled = false
        ProgramStatusRouter.report(report, pane: pane, foregroundGroup: 77)
        ProgramStatusRouter.promptStarted(pane: pane)
        ProgramStatusRouter.reset(pane: pane)
        XCTAssertEqual(log(), [], "[agents] program-status = false routes nothing")

        ProgramStatusRouter.isEnabled = true
        ProgramStatusRouter.report(report, pane: pane, foregroundGroup: 77)
        ProgramStatusRouter.promptStarted(pane: pane)
        ProgramStatusRouter.reset(pane: pane)
        XCTAssertEqual(log(), ["receive PANE working [] fg=77", "promptStarted PANE", "reset PANE"])
    }

    // MARK: Routing from the engine

    func testEngineActionsReachTheSurfacesPane() throws {
        let view = try makeSurfaceView()
        let log = recordStore(for: view.id)
        ProgramStatusRouter.isEnabled = true

        try withCReport(state: "done", id: "build", app: "cargo") {
            try send(GHOSTTY_ACTION_PROGRAM_STATUS, to: view, payload: $0)
        }
        try send(GHOSTTY_ACTION_PROMPT_START, to: view)
        try send(GHOSTTY_ACTION_PROGRAM_STATUS_RESET, to: view)

        let entries = log()
        XCTAssertEqual(entries.count, 3, "\(entries)")
        // The foreground group is read at the moment of the report: a positive pid, or nil
        // while the pty is not up yet.
        XCTAssertTrue(entries.first?.hasPrefix("receive PANE done [\"build\"] fg=") ?? false, "\(entries)")
        XCTAssertEqual(Array(entries.dropFirst()), ["promptStarted PANE", "reset PANE"])
    }

    func testEngineActionsAreDroppedWhenOff() throws {
        let view = try makeSurfaceView()
        let log = recordStore(for: view.id)
        ProgramStatusRouter.isEnabled = false

        try withCReport(state: "blocked") { try send(GHOSTTY_ACTION_PROGRAM_STATUS, to: view, payload: $0) }
        try send(GHOSTTY_ACTION_PROMPT_START, to: view)
        try send(GHOSTTY_ACTION_PROGRAM_STATUS_RESET, to: view)
        XCTAssertEqual(log(), [])
    }

    func testUserResetClearsThePane() throws {
        let view = try makeSurfaceView()
        let log = recordStore(for: view.id)
        ProgramStatusRouter.isEnabled = true

        // The context menu's "Reset" (the surface view's own action).
        view.resetTerminal(self)
        XCTAssertEqual(log(), ["reset PANE"])

        // The app-level binding path.
        let appDelegate = try XCTUnwrap(NSApp.delegate as? AppDelegate)
        appDelegate.ghostty.resetTerminal(surface: try XCTUnwrap(view.surface))
        XCTAssertEqual(log(), ["reset PANE", "reset PANE"])
    }

    func testForegroundProcessGroupIsPositiveOrNil() throws {
        let view = try makeSurfaceView()
        if let group = view.foregroundProcessGroup {
            XCTAssertGreaterThan(group, 0)
        }
        XCTAssertNil(ProgramStatusRouter.processGroup(-1))
        XCTAssertNil(ProgramStatusRouter.processGroup(0))
        XCTAssertEqual(ProgramStatusRouter.processGroup(4242), 4242)
    }
}
