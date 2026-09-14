import SwiftUI
import XCTest
@testable import QuickTerm

/// **The info strip, decided without a window** (plan §2.11, §4.4).
///
/// Everything the strip draws is a pure function of `(status, now)` plus three switches, so the
/// claims worth making are all made here: when it is drawn at all, what it says, what colour it
/// says it in, how long it says the state has lasted, and how much of the pane it is allowed to
/// take a click on. The SwiftUI body is the thin part; if these hold, it is drawing the right
/// thing.
@MainActor
final class PaneAgentStripTests: XCTestCase {
    private let since = Date(timeIntervalSince1970: 1_700_000_000)
    private var language: AppLanguage!

    override func setUpWithError() throws {
        try super.setUpWithError()
        // The strip's words come from the catalog and its elapsed time from the UI language, so
        // pin the language: otherwise the same case reads "Thinking · 5s" on one machine and
        // "思考中 · 5秒" on the next.
        language = Localization.shared.language
        Localization.shared.setLanguage(.en)
    }

    override func tearDown() {
        Localization.shared.setLanguage(language)
        super.tearDown()
    }

    private func status(_ state: AgentState, detail: AgentDetail? = nil, tool: String? = nil,
                        message: String? = nil, evidence: NoticeEvidence = .hook) -> AgentStatus {
        AgentStatus(agent: "claude-code", name: "Claude Code", state: state, detail: detail,
                    tool: tool, message: message, since: since, evidence: evidence)
    }

    private func model(_ status: AgentStatus, after seconds: TimeInterval = 0)
        -> PaneAgentStrip.Model {
        .make(status: status, now: since.addingTimeInterval(seconds), language: .en)
    }

    // MARK: Whether it is drawn at all

    /// The three independent reasons not to draw, each on its own. The padding one is the load
    /// bearing one: the strip lives in space the engine already reserves, and a pane configured
    /// with less padding than the line needs gets **no strip**, not a resized terminal.
    func testDrawnOnlyWithAStatusAPaddedPaneAndTheSwitchOn() {
        let live = status(.working, detail: .thinking)
        XCTAssertTrue(PaneAgentStrip.visible(status: live, infoStrip: true, panePadding: 14))
        XCTAssertTrue(PaneAgentStrip.visible(status: live, infoStrip: true, panePadding: 32))

        XCTAssertFalse(PaneAgentStrip.visible(status: nil, infoStrip: true, panePadding: 14),
                       "a pane with no agent draws nothing")
        XCTAssertFalse(PaneAgentStrip.visible(status: live, infoStrip: false, panePadding: 14),
                       "[agents] info-strip = false switches it off")
        XCTAssertFalse(PaneAgentStrip.visible(status: live, infoStrip: true, panePadding: 13),
                       "below pane-padding 14 there is no room; the terminal is never shrunk to make some")
        XCTAssertFalse(PaneAgentStrip.visible(status: live, infoStrip: true, panePadding: 0))
    }

    /// The strip takes a click, so its rectangle has to be exactly its own line: everything else
    /// on the chrome still belongs to the terminal (selection, Cmd+click on a link).
    func testHitRectIsTheStripsOwnLineOnly() {
        let pane = CGSize(width: 800, height: 600)
        let rect = PaneAgentStrip.rect(in: pane, panePadding: 14)
        XCTAssertEqual(rect.minY, 0)
        XCTAssertEqual(rect.height, 14)
        XCTAssertEqual(rect.minX, PaneAgentStrip.Metrics.inset)
        XCTAssertEqual(rect.maxX, pane.width - PaneAgentStrip.Metrics.inset)
        XCTAssertLessThan(rect.height, pane.height / 10,
                          "the strip must never be able to eat the pane's mouse events")

        // A padding larger than the line gives the extra space back to the terminal.
        XCTAssertEqual(PaneAgentStrip.rect(in: pane, panePadding: 32).height,
                       PaneAgentStrip.Metrics.maxHeight)
        // A pane narrower than the two insets still produces a valid (empty) rect rather than a
        // negative width, which would trap in a SwiftUI frame.
        XCTAssertEqual(PaneAgentStrip.rect(in: CGSize(width: 4, height: 10), panePadding: 14).width, 0)
    }

    // MARK: What it says

    /// The line is `<name> · <state>` plus the two optional halves, and the tool **name** is
    /// shown while the agent's own words follow a colon — the same title/body split the notice
    /// titles keep.
    func testTextIsNameStateToolAndMessage() {
        XCTAssertEqual(model(status(.working, detail: .thinking)).text, "Claude Code · Thinking")
        XCTAssertEqual(model(status(.working, detail: .tool, tool: "Bash")).text,
                       "Claude Code · Running · Bash")
        XCTAssertEqual(model(status(.blocked, detail: .approval, tool: "Bash",
                                    message: "rm -rf build")).text,
                       "Claude Code · Awaiting approval · Bash: rm -rf build")
        XCTAssertEqual(model(status(.idle)).text, "Claude Code · Idle")
        XCTAssertEqual(model(status(.done)).text, "Claude Code · Finished")
        XCTAssertEqual(model(status(.error)).text, "Claude Code · Failed")
        XCTAssertEqual(model(status(.unknown, evidence: .process)).text, "Claude Code · Running")
    }

    /// A message is the one part of the line that came from another program, so it goes through
    /// the same rulebook every title does: no control characters over a terminal, and a ceiling.
    func testTheMessageIsClampedLikeEveryOtherTitle() {
        let nasty = model(status(.blocked, detail: .input, message: "line\u{1B}[2Jone\nline two"))
        XCTAssertFalse(nasty.text.contains("\u{1B}"), "an escape sequence must never be drawn")
        XCTAssertFalse(nasty.text.contains("\n"))
        let long = model(status(.working, detail: .tool, message: String(repeating: "x", count: 500)))
        XCTAssertLessThanOrEqual(long.text.count, TitleRules.maxLength)
    }

    // MARK: Colour and glyph per state

    /// Colour is a decision, not a `Color`: the model says which of the three roles applies and
    /// the view owns the theme. `blocked` and `error` are the two that mean "go and look", and
    /// they are the two that get `theme.alert`.
    func testTonePerState() {
        XCTAssertEqual(model(status(.working, detail: .tool)).tone, .neutral)
        XCTAssertEqual(model(status(.idle)).tone, .neutral)
        XCTAssertEqual(model(status(.unknown)).tone, .neutral)
        XCTAssertEqual(model(status(.blocked, detail: .approval)).tone, .alert)
        XCTAssertEqual(model(status(.error)).tone, .alert,
                       "a failed turn is somewhere to go and look, exactly like a prompt")
    }

    /// `done` flashes green and decays into the ordinary dim text, so a workspace left running
    /// overnight is not a wall of green.
    func testDoneFadesOverThreeSeconds() {
        XCTAssertEqual(model(status(.done)).tone, .finished(fade: 0))
        XCTAssertEqual(model(status(.done), after: 1.5).tone, .finished(fade: 0.5))
        XCTAssertEqual(model(status(.done), after: 3).tone, .finished(fade: 1))
        XCTAssertEqual(model(status(.done), after: 600).tone, .finished(fade: 1),
                       "the fade saturates; it never runs past the end colour")

        // The blend is what turns that number into a colour, and both ends are exact.
        func rgb(_ color: Color) -> [Double] {
            guard let raw = NSColor(color).usingColorSpace(.deviceRGB) else { return [] }
            return [raw.redComponent, raw.greenComponent, raw.blueComponent].map(Double.init)
        }
        let green = Color.green
        let dim = Palette.inactiveTitle
        for (got, want) in [(rgb(PaneAgentStrip.blend(green, dim, 0)), rgb(green)),
                            (rgb(PaneAgentStrip.blend(green, dim, 1)), rgb(dim)),
                            (rgb(PaneAgentStrip.blend(green, dim, 0.5)),
                             zip(rgb(green), rgb(dim)).map { ($0 + $1) / 2 })] {
            XCTAssertEqual(got.count, 3)
            for (a, b) in zip(got, want) { XCTAssertEqual(a, b, accuracy: 0.001) }
        }
    }

    /// The spinner is the only moving thing on the frame: four frames, one revolution a second,
    /// and it moves only while the agent is working.
    func testTheGlyphCyclesOnlyWhileWorking() {
        let working = status(.working, detail: .tool, tool: "Bash")
        let frames = stride(from: 0.0, to: 1.0, by: 0.25).map { model(working, after: $0).glyph }
        XCTAssertEqual(frames, PaneAgentStrip.Model.spinner)
        XCTAssertEqual(model(working, after: 1).glyph, PaneAgentStrip.Model.spinner[0],
                       "four frames at 0.25s is one full turn a second")

        for state in [AgentState.idle, .blocked, .done, .error, .unknown] {
            let fixed = status(state, detail: state == .blocked ? .approval : nil)
            XCTAssertEqual(model(fixed).glyph, model(fixed, after: 7).glyph,
                           "\(state) has a fixed glyph; only working spins")
        }
        XCTAssertEqual(model(status(.blocked, detail: .approval)).glyph, "●",
                       "the pane mark, the workspace pill and the CLI all draw this same dot for "
                           + "\"a human is needed here\"")
    }

    // MARK: The clock

    /// Two units at most, in the UI language: this sits in the corner of a line that is mostly
    /// the agent's own words, and `1h 1m 1s` is three units of clock nobody reads.
    func testElapsedFormats() {
        XCTAssertEqual(model(status(.working, detail: .thinking)).elapsed, "0s")
        XCTAssertEqual(model(status(.working, detail: .thinking), after: 5).elapsed, "5s")
        XCTAssertEqual(model(status(.working, detail: .thinking), after: 125).elapsed, "2m 5s")
        XCTAssertEqual(model(status(.working, detail: .thinking), after: 3661).elapsed, "1h 1m")
        XCTAssertEqual(PaneAgentStrip.Model.elapsedText(-5, language: .en), "0s",
                       "a clock that has gone backwards reads zero, never a negative age")
        XCTAssertEqual(PaneAgentStrip.Model.elapsedText(5, language: .zh), "5秒",
                       "the elapsed time follows the UI language, not the machine's locale")
    }

    /// The whole model is `(status, now)` and nothing else — the property every one of these
    /// cases rests on, and the reason the strip can be driven by a `TimelineView` rather than by
    /// a subscription to the registry.
    func testTheModelIsAPureFunctionOfStatusAndNow() {
        let live = status(.blocked, detail: .approval, tool: "Bash", message: "rm -rf build")
        XCTAssertEqual(model(live, after: 30), model(live, after: 30))
        XCTAssertNotEqual(model(live, after: 30), model(live, after: 90),
                          "only the elapsed time moves, but it does move")
    }
}
