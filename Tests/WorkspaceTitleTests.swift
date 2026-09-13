import AppKit
import SwiftUI
import XCTest
@testable import QuickTerm

/// Workspace names: the truncation rule (a pure function), the status bar's "if it does not fit, the whole
/// row falls back to numbers", and the slot semantics on the model side.
///
/// This group deliberately stays off a live screen: `WorkspacePill` and `TitleRules` are pure
/// functions, and "it does not fit" is precisely the thing a view cannot measure for you, so it has to be
/// testable at this level.
final class WorkspaceTitleTests: XCTestCase {
    // MARK: Truncation (the same counting rule as pane titles, capped at 12)

    func testShortNamePassesThrough() {
        XCTAssertEqual(TitleRules.clamp("dev", to: WorkspacePill.maxCharacters), "dev")
        XCTAssertEqual(WorkspacePill.clamped("  dev  "), "dev", "leading and trailing whitespace is not part of the name")
    }

    func testBlankNameIsNoName() {
        XCTAssertNil(WorkspacePill.clamped(nil))
        XCTAssertNil(WorkspacePill.clamped(""))
        XCTAssertNil(WorkspacePill.clamped("   \n "))
    }

    /// Exactly 12 characters: nothing is cut, no ellipsis added.
    func testExactlyTwelveIsNotTruncated() {
        let name = String(repeating: "a", count: 12)
        XCTAssertEqual(WorkspacePill.clamped(name), name)
        XCTAssertEqual(WorkspacePill.clamped(name)?.count, 12)
    }

    /// From 13 characters on it is cut, and the ellipsis **counts toward the 12**: 11 real characters plus `…`.
    func testOverTwelveKeepsElevenPlusEllipsis() {
        for length in [13, 30, 200] {
            let clamped = WorkspacePill.clamped(String(repeating: "a", count: length))
            XCTAssertEqual(clamped, String(repeating: "a", count: 11) + "…", "\(length) characters")
            XCTAssertEqual(clamped?.count, 12, "12 characters including the ellipsis")
        }
    }

    /// CJK and emoji each count as one grapheme cluster, point for point with pane titles.
    func testCJKAndEmojiCountAsOneEach() {
        XCTAssertEqual(WorkspacePill.clamped(String(repeating: "编", count: 14)),
                       String(repeating: "编", count: 11) + "…")
        let family = "👩‍👩‍👧‍👦"
        XCTAssertEqual(family.count, 1, "precondition: Swift sees this string as one grapheme cluster")
        XCTAssertEqual(WorkspacePill.clamped(String(repeating: family, count: 20))?.count, 12)
        XCTAssertEqual(WorkspacePill.clamped("🧪 dev"), "🧪 dev")
    }

    /// Both caps share a single rule and differ only in the number: the 20 on the pane side must not drift
    /// because of this change.
    func testPaneTitleKeepsItsOwnLimitOnTheSharedRule() {
        let long = String(repeating: "a", count: 40)
        XCTAssertEqual(TitleRules.clamp(long, to: PaneTitleBadge.maxCharacters)?.count, 20)
        XCTAssertEqual(TitleRules.clamp(long, to: WorkspacePill.maxCharacters)?.count, 12)
        XCTAssertEqual(PaneTitleBadge.fit(title: long, topEdgeWidth: 4000),
                       String(repeating: "a", count: 19) + "…", "the 20-character rule on the border is unchanged")
    }

    // MARK: What gets drawn on a pill

    func testPillWithoutANameLooksExactlyLikeToday() {
        XCTAssertEqual(WorkspacePill.label(title: nil, index: 1, active: false, showingTitles: true), "2")
        XCTAssertEqual(WorkspacePill.label(title: nil, index: 1, active: true, showingTitles: true), "■")
        XCTAssertEqual(WorkspacePill.pillWidth(title: nil, index: 1, active: false, showingTitles: true),
                       WorkspacePill.plainWidth)
    }

    func testNamedPillShowsTheNameInPlaceOfTheGlyph() {
        XCTAssertEqual(WorkspacePill.label(title: "dev", index: 1, active: false, showingTitles: true), "dev")
        XCTAssertEqual(WorkspacePill.label(title: "dev", index: 1, active: true, showingTitles: true), "dev",
                       "a named active workspace shows its name too; active is the accent color, not that square")
        XCTAssertGreaterThan(
            WorkspacePill.pillWidth(title: "dev", index: 1, active: false, showingTitles: true),
            WorkspacePill.plainWidth, "a named pill is wider than a numbered one")
    }

    /// When the whole row falls back to numbers, not one name shows.
    func testFallbackDrawsNumbersEvenForNamedWorkspaces() {
        XCTAssertEqual(WorkspacePill.label(title: "dev", index: 1, active: false, showingTitles: false), "2")
        XCTAssertEqual(WorkspacePill.pillWidth(title: "dev", index: 1, active: false, showingTitles: false),
                       WorkspacePill.plainWidth)
    }

    // MARK: If it does not fit, the whole row falls back to numbers

    private let clock = "Wednesday 14:32"

    func testRoomyBarShowsTheNames() {
        XCTAssertTrue(WorkspacePill.showsTitles(contentWidth: 1600,
                                                titles: ["dev", nil, "web", nil, nil],
                                                activeIndex: 0,
                                                clockWidth: WorkspacePill.width(of: clock), flash: nil))
    }

    /// A narrow window plus five long names: the left section would run into the centered clock, so the
    /// **whole row** falls back to numbers.
    func testNarrowBarFallsBackForTheWholeRow() {
        let titles = Array(repeating: String(repeating: "长", count: 12), count: 5) as [String?]
        XCTAssertFalse(WorkspacePill.showsTitles(contentWidth: 900, titles: titles, activeIndex: 0,
                                                 clockWidth: WorkspacePill.width(of: clock), flash: nil))
    }

    /// All or nothing: the row of short names fits, and once three long names join it the **whole row**, the
    /// two short ones included, goes back to numbers. This is structural: `showsTitles` has exactly one
    /// answer, and pills have no switch of their own.
    func testOneOverlongNameTurnsTheWholeRowOff() {
        let clockWidth = WorkspacePill.width(of: clock)
        let short: [String?] = ["dev", "web", nil, nil, nil]
        var crowded = short
        for index in 2..<5 { crowded[index] = String(repeating: "字", count: 12) }
        let width = 2 * (WorkspacePill.leftSectionWidth(titles: crowded, activeIndex: 0,
                                                        showingTitles: true, flash: nil)
                         + clockWidth / 2 + WorkspacePill.clearance) - 1
        XCTAssertTrue(WorkspacePill.showsTitles(contentWidth: width, titles: short, activeIndex: 0,
                                                clockWidth: clockWidth, flash: nil))
        XCTAssertFalse(WorkspacePill.showsTitles(contentWidth: width, titles: crowded, activeIndex: 0,
                                                 clockWidth: clockWidth, flash: nil))
    }

    /// The threshold is not a guess: it flips at the exact moment the left section's right edge meets the
    /// **clock's left edge**.
    func testTheThresholdIsExactlyTheClockLeftEdge() {
        let titles: [String?] = ["开发环境", "网页", "日志", nil, nil]
        let clockWidth = WorkspacePill.width(of: clock)
        let left = WorkspacePill.leftSectionWidth(titles: titles, activeIndex: 0,
                                                  showingTitles: true, flash: nil)
        let exact = 2 * (left + clockWidth / 2 + WorkspacePill.clearance)
        XCTAssertTrue(WorkspacePill.showsTitles(contentWidth: exact + 1, titles: titles, activeIndex: 0,
                                                clockWidth: clockWidth, flash: nil))
        XCTAssertFalse(WorkspacePill.showsTitles(contentWidth: exact - 1, titles: titles, activeIndex: 0,
                                                 clockWidth: clockWidth, flash: nil))
        // Switch the clock to the wider format and the same row of names needs a wider window: the threshold
        // really does follow the clock.
        let wideClock = WorkspacePill.width(of: "31 September W36 2026")
        XCTAssertGreaterThan(2 * (left + wideClock / 2 + WorkspacePill.clearance), exact)
    }

    /// The control-plane flash lives in that left section too: at the same window width, names have to give
    /// way the moment it appears.
    func testControlFlashCountsAgainstTheBudget() {
        let titles: [String?] = ["开发环境", "网页", "日志", nil, nil]
        let clockWidth = WorkspacePill.width(of: clock)
        let flash = "控制面：workspace set"
        let bare = WorkspacePill.leftSectionWidth(titles: titles, activeIndex: 0,
                                                  showingTitles: true, flash: nil)
        let crowded = WorkspacePill.leftSectionWidth(titles: titles, activeIndex: 0,
                                                     showingTitles: true, flash: flash)
        XCTAssertGreaterThan(crowded, bare + 1, "the flash really does take up width")
        let width = 2 * (crowded + clockWidth / 2 + WorkspacePill.clearance) - 1
        XCTAssertTrue(WorkspacePill.showsTitles(contentWidth: width, titles: titles, activeIndex: 0,
                                                clockWidth: clockWidth, flash: nil))
        XCTAssertFalse(WorkspacePill.showsTitles(contentWidth: width, titles: titles, activeIndex: 0,
                                                 clockWidth: clockWidth, flash: flash))
    }

    /// Nothing named at all: the row is numbers anyway, so there is nothing to measure.
    func testNothingNamedMeansNothingToMeasure() {
        XCTAssertFalse(WorkspacePill.showsTitles(contentWidth: 4000, titles: [nil, nil, nil],
                                                 activeIndex: 0, clockWidth: 100, flash: nil))
    }

    /// The width has not been measured yet (the first frame): better to show names a frame late than to draw
    /// one bad frame.
    func testUnmeasuredBarDrawsNumbers() {
        XCTAssertFalse(WorkspacePill.showsTitles(contentWidth: 0, titles: ["dev", nil],
                                                 activeIndex: 0, clockWidth: 100, flash: nil))
    }

    // MARK: Right-click renames, left-click still switches workspace

    /// Right-click only. Claim one more event type and the pill's left-click, which switches to that
    /// workspace, is swallowed on the spot by this transparent overlay.
    func testOnlyRightClicksAreClaimed() {
        XCTAssertTrue(RightClickCatcher.claims(.rightMouseDown))
        XCTAssertTrue(RightClickCatcher.claims(.rightMouseUp))
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp, .leftMouseDragged,
                     .mouseMoved, .scrollWheel, .keyDown] {
            XCTAssertFalse(RightClickCatcher.claims(type), "\(type) has to pass straight through to the button")
        }
        XCTAssertFalse(RightClickCatcher.claims(nil), "outside event dispatch, a layout query say, nothing is claimed either")
    }

    // MARK: The model: a name belongs to the **slot**

    func testSetTitleNormalisesAndIsIdempotent() {
        let model = WorkspaceModel()
        XCTAssertTrue(model.setTitle("  dev  ", at: 1))
        XCTAssertEqual(model.title(at: 1), "dev")
        XCTAssertFalse(model.setTitle("dev", at: 1), "the same value a second time is not a change (exit 7 rests on this)")
        XCTAssertTrue(model.setTitle("", at: 1), "an empty string clears it")
        XCTAssertNil(model.title(at: 1))
        XCTAssertFalse(model.setTitle("   ", at: 1), "there is no name left, so clearing again is not a change")
    }

    func testOutOfRangeSlotIsIgnored() {
        let model = WorkspaceModel()
        XCTAssertFalse(model.setTitle("dev", at: 99))
        XCTAssertNil(model.title(at: 99))
        XCTAssertNil(model.title(at: -1))
    }

    /// When the workspace count changes, which is how a config hot-reload lands, names must not shift and
    /// must not crash.
    func testNamesSurviveWorkspaceCountChanges() {
        let model = WorkspaceModel()
        model.setTitle("one", at: 0)
        model.setTitle("five", at: 4)

        model.setWorkspaceCount(10)
        XCTAssertEqual(model.titles.count, 10)
        XCTAssertEqual(model.title(at: 0), "one")
        XCTAssertEqual(model.title(at: 4), "five", "growing the count must not slide names along")
        XCTAssertNil(model.title(at: 9))

        model.setTitle("ten", at: 9)
        model.setWorkspaceCount(3)
        XCTAssertEqual(model.title(at: 0), "one", "after shrinking, the remaining slots keep their names")
        XCTAssertNil(model.title(at: 9), "a trimmed slot reads back no name")

        model.setWorkspaceCount(10)
        XCTAssertEqual(model.title(at: 4), "five", "set it back and the name is still there: names belong to slots")
        XCTAssertEqual(model.title(at: 9), "ten")
    }

    /// The name names the slot, not the panes inside it: replacing the whole layout leaves it alone.
    func testReplacingTheLayoutLeavesTheNameAlone() {
        let model = WorkspaceModel()
        model.setTitle("dev", at: 0)
        model.layouts[0] = .empty
        model.setLayout("dwindle", at: 0)
        XCTAssertEqual(model.title(at: 0), "dev")
    }

    // MARK: Archive round trip

    func testArchiveRoundTripKeepsTheNames() throws {
        let saved = WindowState(layouts: [.empty, .empty, .empty],
                                floatings: [[], [], []], activeIndex: 1,
                                workspaceTitles: ["dev", nil, "日志"])
        let data = try JSONEncoder().encode(saved)
        let back = try JSONDecoder().decode(WindowState.self, from: data)
        XCTAssertEqual(back.workspaceTitles?.count, 3)
        XCTAssertEqual(back.workspaceTitles?[0], "dev")
        XCTAssertNil(back.workspaceTitles?[1] ?? nil)
        XCTAssertEqual(back.workspaceTitles?[2], "日志")
    }

    /// An older archive, from before v5 carried this field, still decodes: adding an optional field must not
    /// throw away a user's session.
    func testOlderArchiveWithoutTheFieldStillDecodes() throws {
        let saved = WindowState(layouts: [.empty, .empty], activeIndex: 0,
                                workspaceTitles: ["dev", nil])
        var raw = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: try JSONEncoder().encode(saved)) as? [String: Any])
        raw.removeValue(forKey: "workspaceTitles")
        let back = try JSONDecoder().decode(
            WindowState.self, from: try JSONSerialization.data(withJSONObject: raw))
        XCTAssertNil(back.workspaceTitles, "a missing field means nothing was ever named")
        XCTAssertEqual(back.layouts.count, 2)
    }

    /// More names in the archive than there are workspaces (saved with 10, config later set to 3): no crash,
    /// and nothing shifts.
    func testMoreNamesThanWorkspacesIsHarmless() throws {
        let saved = WindowState(layouts: [.empty, .empty], activeIndex: 0,
                                workspaceTitles: ["dev", "web", "log", "x", "y"])
        let back = try JSONDecoder().decode(WindowState.self, from: try JSONEncoder().encode(saved))
        let model = WorkspaceModel()
        model.layouts = [.empty, .empty]
        model.titles = try XCTUnwrap(back.workspaceTitles)
        model.setWorkspaceCount(2)
        XCTAssertEqual(model.title(at: 0), "dev")
        XCTAssertEqual(model.title(at: 1), "web")
    }

    // MARK: The budget versus the pill that is actually laid out

    /// A pill's budgeted width has to equal the width SwiftUI actually lays out.
    ///
    /// **The only way to check this is to lay one out for real**: whether `padding` wraps outside or inside
    /// `frame(minWidth:)`, the formula looks "about right" either way, and the difference is exactly 8pt per
    /// pill. The whole row has only 8pt of slack, so five one-character names are enough to shove the last
    /// cell into the clock.
    @MainActor
    func testPillWidthMatchesTheLaidOutPill() {
        for name in ["a", "ab", "编", "dev", "开发环境", "🧪 dev", String(repeating: "a", count: 12)] {
            let laidOut = NSHostingView(
                rootView: WorkspacePill.pill(title: name, index: 0, active: false,
                                             showingTitles: true)).fittingSize.width
            let budget = WorkspacePill.pillWidth(title: name, index: 0, active: false,
                                                 showingTitles: true)
            XCTAssertEqual(budget, laidOut, accuracy: 1,
                           "`\(name)`: budget \(budget), laid out \(laidOut)")
        }
    }

    /// An unnamed pill is still those 18pt: this change must not move it by a single point.
    @MainActor
    func testPlainPillIsStillEighteenPoints() {
        for (active, showing) in [(false, false), (true, false), (false, true), (true, true)] {
            let laidOut = NSHostingView(
                rootView: WorkspacePill.pill(title: nil, index: 3, active: active,
                                             showingTitles: showing)).fittingSize.width
            XCTAssertEqual(laidOut, WorkspacePill.plainWidth, accuracy: 1)
        }
    }

    /// A newline inside a name must not push the status bar taller: the 26pt bar height is hard-coded, and a
    /// second line would be laid out right outside the background.
    /// (Whether such a name can get in at all is another layer's problem: the CLI errors, the dialog filters.
    /// This covers the case where one is already in, from a hand-edited archive for instance.)
    @MainActor
    func testAMultiLineNameCannotGrowTheBar() {
        let tall = NSHostingView(
            rootView: WorkspacePill.pill(title: "a\nb\nc", index: 0, active: false,
                                         showingTitles: true)).fittingSize.height
        XCTAssertLessThanOrEqual(tall, StatusBarView.height, "one line of text, and no height may exceed the status bar")
    }

    /// Newlines, tabs and DEL pasted into the dialog are filtered out (the CLI errors on them; for a human,
    /// filtering is the only option).
    func testTypedNameLosesControlCharacters() {
        XCTAssertEqual(TitleRules.fromTypedInput("dev\n日志"), "dev日志")
        XCTAssertEqual(TitleRules.fromTypedInput("a\tb\u{7}c\u{7F}"), "abc")
        XCTAssertEqual(TitleRules.fromTypedInput("开发"), "开发", "ordinary characters are left alone")
        XCTAssertEqual(
            TitleRules.fromTypedInput(String(repeating: "a", count: 500)).count,
            TitleRules.maxLength, "over the limit it truncates rather than erroring")
        // Filter first, hand it to the model after, and the status bar is left with a single line.
        let model = WorkspaceModel()
        model.setTitle(TitleRules.fromTypedInput("a\nb"), at: 0)
        XCTAssertEqual(model.title(at: 0), "ab")
    }

    // MARK: One rulebook (`TitleRules`)

    /// Both rename sheets hand a typed string to the same function, and what comes out is already
    /// in the form the command line would have insisted on: trimmed, printable, within the cap.
    /// **A value that filters down to nothing is a real answer** — it means "hand it back", exactly
    /// what `--title ""` means, which is what lets the sheet and the command agree.
    func testTypedInputIsTrimmedAndBlankMeansNoTitle() {
        XCTAssertEqual(TitleRules.fromTypedInput("  dev  "), "dev")
        XCTAssertEqual(TitleRules.fromTypedInput("   "), "", "all whitespace is no title at all")
        XCTAssertEqual(TitleRules.fromTypedInput("\n\t"), "", "and so is a paste of nothing but control characters")
        XCTAssertEqual(TitleRules.fromTypedInput(""), "")
        // The cut lands exactly on a space here (199 a's, then a space, then more): what comes out
        // must not end in whitespace, or the next idempotency check reads it as a difference.
        let cutOnASpace = TitleRules.fromTypedInput(String(repeating: "a", count: 199) + " more")
        XCTAssertEqual(cutOnASpace, String(repeating: "a", count: 199))
    }

    /// The printable rule is one predicate, not three copies of an inequality: C0 (newline and tab
    /// included), DEL and C1 are all out, everything else is in.
    func testPrintableRuleCoversC0DelAndC1() {
        XCTAssertTrue(TitleRules.isPrintable("dev 开发 🧪"))
        for bad in ["a\nb", "a\tb", "a\u{7}b", "a\u{1B}[31m", "a\u{7F}b", "a\u{85}b", "a\u{9B}b"] {
            XCTAssertFalse(TitleRules.isPrintable(bad), "\(bad.debugDescription) must not be allowed in a title")
        }
        XCTAssertTrue(TitleRules.isPrintable(""), "an empty string has nothing unprintable in it; emptiness is normalized, not refused")
    }

    /// Trimming is the shared idea behind "a blank value is no value": both `--title` commands and
    /// both rename sheets go through this one function.
    func testNormalizedTrimsAndTreatsBlankAsNothing() {
        XCTAssertEqual(TitleRules.normalized("  dev  "), "dev")
        XCTAssertNil(TitleRules.normalized("   "))
        XCTAssertNil(TitleRules.normalized("\n"))
        XCTAssertNil(TitleRules.normalized(""))
        XCTAssertNil(TitleRules.normalized(nil))
    }

    /// The two display caps are **two surfaces, correctly different**, and the rulebook holds no
    /// default that either could drift onto.
    func testTheTwoDisplayCapsStayDifferent() {
        XCTAssertEqual(PaneTitleBadge.maxCharacters, 20)
        XCTAssertEqual(WorkspacePill.maxCharacters, 12)
        XCTAssertEqual(TitleRules.maxLength, 200, "what may be stored is a different question from what is drawn")
    }

    /// Once the workspace count shrinks, what gets measured is still **the row that is drawn**.
    /// `titles` is not trimmed on shrink, because names belong to slots, so measuring it as-is pays for pills
    /// that are never drawn.
    func testShrunkRowMeasuresOnlyThePillsItDraws() {
        let model = WorkspaceModel()
        model.setWorkspaceCount(10)
        for index in 0..<10 { model.setTitle("名字\(index)", at: index) }
        model.setWorkspaceCount(5)
        XCTAssertEqual(model.titles.count, 10, "precondition: shrinking does not trim the names")
        XCTAssertEqual(model.visibleTitles.count, 5, "only 5 pills are drawn")
        XCTAssertEqual(model.visibleTitles.last ?? nil, "名字4")

        let clockWidth = WorkspacePill.width(of: clock)
        let drawn = WorkspacePill.leftSectionWidth(titles: model.visibleTitles, activeIndex: 0,
                                                   showingTitles: true, flash: nil)
        let width = 2 * (drawn + clockWidth / 2 + WorkspacePill.clearance) + 1
        XCTAssertTrue(WorkspacePill.showsTitles(contentWidth: width, titles: model.visibleTitles,
                                                activeIndex: 0, clockWidth: clockWidth, flash: nil),
                      "this row fits")
        XCTAssertFalse(WorkspacePill.showsTitles(contentWidth: width, titles: model.titles,
                                                 activeIndex: 0, clockWidth: clockWidth, flash: nil),
                       "same bar: measured against the untrimmed titles it claims not to fit, which is exactly why it must not be measured that way")
    }

    // MARK: That one sentence in the help

    /// The help for `--title` is **generated** for agents (`--help`, `describe --json` and the MCP tool table
    /// all share one copy), so it must not contradict what `SpecApplier` really does: a spec that carries
    /// `title` does rename.
    func testHelpTellsTheTruthAboutSpecApply() throws {
        let command = try XCTUnwrap(ControlCommandTable.commands.first { $0.name == "workspace.set" })
        let help = try XCTUnwrap(command.args.first { $0.name == "title" }).help
        XCTAssertTrue(help.contains("spec"), "the help has to say whether spec apply touches the name")
        XCTAssertTrue(help.contains("carries a title"),
                      "the help has to spell out that a spec carrying a title renames, the same thing the two assertions below check: \(help)")
        XCTAssertNil(SpecApplier.wantedTitle(WorkspaceSpec()), "no title means the name is untouched")
        XCTAssertEqual(SpecApplier.wantedTitle(WorkspaceSpec(title: "dev")) ?? nil, "dev",
                       "a spec carrying title renames, and that is what the help must be saying")
    }
}
