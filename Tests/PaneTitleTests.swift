import AppKit
import Combine
import XCTest
@testable import QuickTerm

/// The title drawn on a pane's top border: the truncation algorithm (a pure function), the config
/// switch, and the rule that only an explicitly set title ever shows up.
final class PaneTitleTests: XCTestCase {
    private let metrics = PaneTitleBadge.Metrics.standard

    /// Wide enough that nothing can fail to fit, so the 20-character cap is the only rule in play.
    private var roomy: CGFloat { 4000 }

    /// The top-edge width that exactly fits `text` (solving `availableTextWidth` backwards).
    private func width(fitting text: String, slack: CGFloat = 0) -> CGFloat {
        metrics.width(of: text) + metrics.leadingInset + metrics.sidePadding
            + CGFloat(metrics.reservedCharacters) * metrics.characterWidth + slack
    }

    // MARK: Truncation

    func testShortTitlePassesThrough() {
        XCTAssertEqual(PaneTitleBadge.fit(title: "build", topEdgeWidth: roomy, metrics: metrics), "build")
    }

    func testEmptyOrBlankTitleDrawsNothing() {
        XCTAssertNil(PaneTitleBadge.fit(title: "", topEdgeWidth: roomy, metrics: metrics))
        XCTAssertNil(PaneTitleBadge.fit(title: "   \n ", topEdgeWidth: roomy, metrics: metrics))
    }

    /// Exactly 20 characters: nothing is cut, no ellipsis is added.
    func testExactlyTwentyCharactersIsNotTruncated() {
        let title = String(repeating: "a", count: 20)
        let fitted = PaneTitleBadge.fit(title: title, topEdgeWidth: roomy, metrics: metrics)
        XCTAssertEqual(fitted, title)
        XCTAssertEqual(fitted?.count, 20)
    }

    /// From 21 characters on it has to be cut, and the ellipsis **counts toward the 20**: 19 real
    /// characters plus `…`.
    func testOverTwentyKeepsNineteenPlusEllipsis() {
        for length in [21, 30, 200] {
            let title = String(repeating: "a", count: length)
            let fitted = try? XCTUnwrap(PaneTitleBadge.fit(title: title, topEdgeWidth: roomy, metrics: metrics))
            XCTAssertEqual(fitted, String(repeating: "a", count: 19) + "…", "\(length) characters")
            XCTAssertEqual(fitted?.count, 20, "20 characters including the ellipsis")
        }
    }

    /// CJK counts as one grapheme per character (not display width, and certainly not bytes): 22 Han
    /// characters -> 19 plus `…`.
    func testCJKCountsAsOneCharacterEach() {
        let title = String(repeating: "编", count: 22)
        let fitted = PaneTitleBadge.fit(title: title, topEdgeWidth: roomy, metrics: metrics)
        XCTAssertEqual(fitted, String(repeating: "编", count: 19) + "…")
        XCTAssertEqual(fitted?.count, 20)
        // Han characters are far wider than Latin letters, though: the same 20 characters need a very
        // different amount of border.
        XCTAssertGreaterThan(metrics.width(of: title), metrics.width(of: String(repeating: "a", count: 22)))
    }

    /// An emoji is a single grapheme cluster too, ZWJ family emoji and skin-tone variants included.
    func testEmojiCountsAsOneCharacterEach() {
        let family = "👩‍👩‍👧‍👦"
        XCTAssertEqual(family.count, 1, "precondition: Swift sees this string as one grapheme cluster")
        let title = String(repeating: family, count: 25)
        let fitted = PaneTitleBadge.fit(title: title, topEdgeWidth: roomy, metrics: metrics)
        XCTAssertEqual(fitted?.count, 20)
        XCTAssertTrue(fitted?.hasSuffix("…") ?? false)
        XCTAssertEqual(PaneTitleBadge.fit(title: "🧪 test", topEdgeWidth: roomy, metrics: metrics), "🧪 test")
    }

    /// Too narrow for even one character: draw nothing. Not a lone ellipsis, and not half a character.
    func testTooNarrowDrawsNoTitleAtAll() {
        for topEdge in [CGFloat(0), 10, 20, metrics.leadingInset + metrics.sidePadding
                        + 2 * metrics.characterWidth] {
            XCTAssertNil(PaneTitleBadge.fit(title: "build", topEdgeWidth: topEdge, metrics: metrics),
                         "a top edge of \(topEdge) fits no characters, so nothing may be drawn")
        }
        // Drawing starts as soon as "one character + ellipsis" fits, and what is drawn always contains a
        // real character.
        let minimal = width(fitting: "b…", slack: 0.5)
        let fitted = PaneTitleBadge.fit(title: "build", topEdgeWidth: minimal, metrics: metrics)
        XCTAssertEqual(fitted, "b…")
        XCTAssertNotEqual(fitted, "…", "never draw a bare ellipsis")
    }

    /// The 2-character reserve is what does the cutting: the width fits the whole string, but not once the
    /// reserve is taken out of it.
    func testTwoCharacterReserveIsWhatCuts() {
        let title = "deploy"
        // Just barely fits, reserve included.
        let justEnough = width(fitting: title, slack: 0.5)
        XCTAssertEqual(PaneTitleBadge.fit(title: title, topEdgeWidth: justEnough, metrics: metrics), title)
        // At the same width the text alone would still have room to spare if the reserve were dropped, but
        // the reserve is untouchable, so the text gets cut instead.
        let shaved = justEnough - 2 * metrics.characterWidth
        let fitted = try? XCTUnwrap(PaneTitleBadge.fit(title: title, topEdgeWidth: shaved, metrics: metrics))
        XCTAssertNotEqual(fitted, title, "the two-character reserve has to actually eat into the text")
        XCTAssertTrue(fitted?.hasSuffix("…") ?? false)
        XCTAssertGreaterThan(metrics.width(of: title), 0)
    }

    /// What gets drawn **never** reaches the top-right corner, and at least two characters' worth of line
    /// is left on the right.
    func testDrawnTitleNeverReachesTheTopRightCorner() {
        let titles = ["build", "编译 · web 服务", String(repeating: "x", count: 60), "🧪 test"]
        for topEdge in stride(from: CGFloat(0), through: 600, by: 7) {
            for title in titles {
                guard let fitted = PaneTitleBadge.fit(title: title, topEdgeWidth: topEdge,
                                                      metrics: metrics) else { continue }
                let gap = PaneTitleBadge.gapRange(for: fitted, metrics: metrics)
                XCTAssertLessThanOrEqual(
                    gap.end + CGFloat(metrics.reservedCharacters) * metrics.characterWidth,
                    topEdge + 0.001,
                    "`\(fitted)` on a top edge of \(topEdge) ate into the line on the right")
                XCTAssertLessThanOrEqual(fitted.count, PaneTitleBadge.maxCharacters)
            }
        }
    }

    // MARK: Vertical placement (the title has to actually sit on the line)

    /// The default `pane-gap = 5`: it draws, and the center of the line really does land inside the glyphs.
    func testDefaultPaneGapDrawsTheTitleOnTheLine() throws {
        let badge = try XCTUnwrap(PaneTitleBadge.place(title: "build", topEdgeWidth: roomy,
                                                       overhang: 5, metrics: metrics))
        XCTAssertEqual(badge.text, "build")
        XCTAssertGreaterThanOrEqual(badge.offsetY, -5, "the text pushed past the pane-gap it may borrow")
        XCTAssertLessThanOrEqual(badge.offsetY + metrics.capTopInset, PaneTitleBadge.lineWidth / 2,
                                 "the center of the line has to sit inside the glyphs, not float above them")
    }

    /// Regression: with gaps off (Cmd+Shift+Backspace / `app set --gaps off`) or `pane-gap = 0` there is
    /// nothing to borrow above the border. This used to push the text entirely below the line, on top of
    /// the terminal's first row, while the border still bit an empty notch out for it.
    /// Now neither the text nor the notch is drawn.
    func testNoRoomAboveTheLineDrawsNeitherTitleNorGap() {
        for overhang in [CGFloat(0), 0.5, 1, 2] {
            XCTAssertNil(PaneTitleBadge.verticalOffset(overhang: overhang, metrics: metrics),
                         "with only \(overhang)pt above the line, nothing may be drawn")
            XCTAssertNil(PaneTitleBadge.place(title: "build", topEdgeWidth: roomy,
                                              overhang: overhang, metrics: metrics),
                         "only \(overhang)pt above the line: no notch either")
        }
    }

    /// Whenever it draws at all, the line runs through the glyphs and the text stays inside the gap it is
    /// allowed to borrow.
    func testDrawnTitleAlwaysStraddlesTheBorderLine() {
        let lineCentre = PaneTitleBadge.lineWidth / 2
        for overhang in stride(from: CGFloat(0), through: 20, by: 0.25) {
            guard let offset = PaneTitleBadge.verticalOffset(overhang: overhang, metrics: metrics)
            else { continue }
            XCTAssertGreaterThanOrEqual(offset, -overhang - 0.001,
                                        "pane-gap \(overhang): the text left the gap and the slot would clip it")
            XCTAssertLessThanOrEqual(offset + metrics.capTopInset, lineCentre,
                                     "pane-gap \(overhang): the line's center is above the caps, so the text dropped below the line")
            XCTAssertGreaterThanOrEqual(offset + metrics.baselineInset, lineCentre,
                                        "pane-gap \(overhang): the line's center is below the baseline, so the text floated above the line")
        }
    }

    /// Given enough gap it centers properly: the box's center lands on the line's center.
    func testRoomyGapCentresTheTitleOnTheLine() throws {
        let offset = try XCTUnwrap(PaneTitleBadge.verticalOffset(overhang: 20, metrics: metrics))
        XCTAssertEqual(offset, PaneTitleBadge.lineWidth / 2 - metrics.lineHeight / 2, accuracy: 0.001)
    }

    /// `place` is the only entry point: no title, too narrow to fit, or no room above. In all three cases
    /// the border has to be drawn unbroken.
    func testPlacementIsNilWheneverTheFrameMustStayUnbroken() {
        XCTAssertNil(PaneTitleBadge.place(title: nil, topEdgeWidth: roomy, overhang: 5,
                                          metrics: metrics))
        XCTAssertNil(PaneTitleBadge.place(title: "build", topEdgeWidth: 20, overhang: 5,
                                          metrics: metrics))
        XCTAssertNil(PaneTitleBadge.place(title: "build", topEdgeWidth: roomy, overhang: 0,
                                          metrics: metrics))
    }

    /// The notch has to bracket the string that is actually drawn, not the original title, and still leave
    /// two characters' worth of line on the right.
    func testPlacementGapMatchesTheDrawnText() throws {
        let badge = try XCTUnwrap(PaneTitleBadge.place(title: String(repeating: "编", count: 40),
                                                       topEdgeWidth: 400, overhang: 5,
                                                       metrics: metrics))
        let gap = PaneTitleBadge.gapRange(for: badge.text, metrics: metrics)
        XCTAssertEqual(badge.gapStart, gap.start)
        XCTAssertEqual(badge.gapEnd, gap.end)
        XCTAssertLessThanOrEqual(badge.gapEnd + 2 * metrics.characterWidth, 400.001)
    }

    // MARK: What a person types into the rename sheet

    /// "Change Terminal Title" runs the typed string through `TitleRules.fromTypedInput` before it
    /// ever reaches the pane — the same rulebook `pane set --title` enforces, only filtering where
    /// the command line refuses.
    ///
    /// Regression: this sheet shipped passing the `NSTextField` string straight through, with no
    /// filter and no cap, while the workspace rename sheet right next to it was fixed to do exactly
    /// this. An `NSTextField` accepts a pasted escape sequence, a pasted newline and a pasted log
    /// file without a word of complaint, and all three went onto the pane and into every `state`
    /// response.
    func testTypedPaneTitleIsFilteredBeforeItReachesThePane() {
        let cleaned = TitleRules.fromTypedInput("build\u{1B}[31m\nweb\u{7F}")
        XCTAssertTrue(TitleRules.isPrintable(cleaned), "no control character may survive into a pane title")
        XCTAssertFalse(cleaned.contains("\n"))
        XCTAssertEqual(TitleRules.fromTypedInput("  build  "), "build", "trimmed, exactly as --title is")
        XCTAssertEqual(TitleRules.fromTypedInput("   "), "",
                       "a blank rename means the same as --title \"\": hand the title back to the shell")
        XCTAssertEqual(TitleRules.fromTypedInput(String(repeating: "字", count: 400)).count,
                       TitleRules.maxLength, "a person gets a truncation, not an error sheet")
        // And the border still has the last word on what it can draw: 20 characters.
        let long = TitleRules.fromTypedInput(String(repeating: "字", count: 400))
        XCTAssertEqual(PaneTitleBadge.fit(title: long, topEdgeWidth: roomy, metrics: metrics)?.count,
                       PaneTitleBadge.maxCharacters)
    }

    // MARK: Config

    func testPaneTitleConfigKey() {
        XCTAssertTrue(ConfigStore.parse("").paneTitle, "on by default")
        XCTAssertFalse(ConfigStore.parse("[appearance]\npane-title = false").paneTitle)
        XCTAssertFalse(ConfigStore.parse("[appearance]\npane-title = off").paneTitle, "off is accepted too")
        XCTAssertTrue(ConfigStore.parse("[appearance]\npane-title = 1").paneTitle)
        XCTAssertTrue(ConfigStore.parse("[appearance]\npane-title = 乱写").paneTitle, "an unparseable value falls back to the default")
    }

    /// A config hot-reload has to be able to switch it off at once (it rides the same path as pane-gap).
    @MainActor
    func testThemeManagerFollowsConfig() {
        let manager = ThemeManager()
        XCTAssertTrue(manager.paneTitleEnabled)
        manager.updateFromConfig(passthrough: "", followEngine: false, paneTitle: false)
        XCTAssertFalse(manager.paneTitleEnabled)
        manager.updateFromConfig(passthrough: "", followEngine: false, paneTitle: true)
        XCTAssertTrue(manager.paneTitleEnabled, "switching it back on takes effect just as fast")
    }

    // MARK: Only an explicitly set title ever shows

    @MainActor
    func testOnlyAnExplicitlySetTitleShowsOnTheFrame() throws {
        let appDelegate = try XCTUnwrap(NSApp.delegate as? AppDelegate)
        let surface = Ghostty.SurfaceView(try XCTUnwrap(appDelegate.ghostty.app), baseConfig: nil)
        surface.setControlTitle("shell-reported")   // Get into the "taken over" state first, then clear it
        _ = surface.setControlTitle(nil)
        XCTAssertNil(surface.customTitle, "a title reported by the shell never reaches the border")

        XCTAssertTrue(surface.setControlTitle("build · web"))
        XCTAssertEqual(surface.customTitle, "build · web")

        _ = surface.setControlTitle("")             // An empty string hands it back to the shell
        XCTAssertNil(surface.customTitle, "once handed back, nothing is left on the border")

        // A browser pane's title belongs to the page; nobody ever "set" it.
        XCTAssertNil(BrowserPaneView(url: URL(string: "about:blank")).customTitle)
    }

    /// Trap regression: pin the title to the exact value the shell is reporting right now. The visible title
    /// does not change by a single character, so the @Published `title` never fires, yet the border has to
    /// show a title immediately.
    /// That is why the "is it pinned" bit has to publish a change of its own.
    @MainActor
    func testPinningToTheAlreadyVisibleTitleStillNotifiesSwiftUI() throws {
        let appDelegate = try XCTUnwrap(NSApp.delegate as? AppDelegate)
        let surface = Ghostty.SurfaceView(try XCTUnwrap(appDelegate.ghostty.app), baseConfig: nil)
        surface.setTitle("same-title")
        let deadline = Date().addingTimeInterval(1)
        while surface.paneTitle != "same-title", Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertEqual(surface.paneTitle, "same-title", "precondition: the title is still the shell's")
        XCTAssertNil(surface.customTitle)

        var notifications = 0
        let token = surface.objectWillChange.sink { _ in notifications += 1 }
        defer { token.cancel() }

        XCTAssertFalse(surface.setControlTitle("same-title"), "the visible title really did not change one character")
        XCTAssertEqual(surface.customTitle, "same-title", "but it is pinned now, so the border must show it")
        XCTAssertGreaterThan(notifications, 0, "SwiftUI has to be woken even when the title is identical")

        notifications = 0
        _ = surface.setControlTitle("")
        XCTAssertNil(surface.customTitle, "clearing back to the shell title takes it off the border")
        XCTAssertGreaterThan(notifications, 0, "the reverse direction has to wake it too")
    }
}
