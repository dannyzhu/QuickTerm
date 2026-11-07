import Combine
import SwiftUI
import XCTest
@testable import QuickTerm

/// **The agent status bar, decided without a window** (plan §2.11, §4.4).
///
/// Everything the bar draws is a pure function of `(status, title, now)` plus three switches, so
/// the claims worth making are all made here: when it is drawn at all, what it says, which
/// background it wears, how long it says the state has lasted, and how much of the pane it is
/// allowed to take a click on. The one claim that cannot be made that way is geometry — an 11pt
/// semibold line in a 10pt band looks fine in the formula and spills onto the terminal's first
/// row on screen — so that one hosts the view and measures it.
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

    private func model(_ status: AgentStatus, after seconds: TimeInterval = 0,
                       title: String? = nil) -> PaneAgentStrip.Model {
        .make(status: status, now: since.addingTimeInterval(seconds), title: title, language: .en)
    }

    // MARK: Whether it is reserved, and whether it paints

    /// The band is reserved for a terminal pane whenever the switch is on and `strip-height` is
    /// > 0 — for nothing else — and its height is held whether or not anything is painted in it, so
    /// the terminal never moves as an agent comes or goes. Painting is the second, independent
    /// decision: only a status or a set title fills the reserved band.
    func testTheBandIsReservedForTerminalsAndPaintsOnlyWithSomethingToSay() {
        let live = status(.working, detail: .thinking)
        // Reserved: terminal + switch on + height > 0.
        XCTAssertEqual(PaneAgentStrip.band(infoStrip: true, stripHeight: 16, isTerminal: true), 16)
        XCTAssertEqual(PaneAgentStrip.band(infoStrip: true, stripHeight: 24, isTerminal: true), 24)
        // Not reserved: switched off, height 0, or not a terminal.
        XCTAssertEqual(PaneAgentStrip.band(infoStrip: false, stripHeight: 16, isTerminal: true), 0,
                       "[agents] info-strip = false reserves nothing")
        XCTAssertEqual(PaneAgentStrip.band(infoStrip: true, stripHeight: 0, isTerminal: true), 0,
                       "strip-height 0 is the off switch")
        XCTAssertEqual(PaneAgentStrip.band(infoStrip: true, stripHeight: 16, isTerminal: false), 0,
                       "a browser pane gets no band")

        // Painting is independent of the reserve above.
        XCTAssertTrue(PaneAgentStrip.draws(status: live, title: nil, infoStrip: true,
                                           stripHeight: 16, isTerminal: true),
                      "an agent paints the band")
        XCTAssertTrue(PaneAgentStrip.draws(status: nil, title: "build", infoStrip: true,
                                           stripHeight: 16, isTerminal: true),
                      "a named but idle pane paints its title")
        XCTAssertFalse(PaneAgentStrip.draws(status: nil, title: nil, infoStrip: true,
                                            stripHeight: 16, isTerminal: true),
                       "no agent and no title: the height is held but nothing is painted")
        XCTAssertFalse(PaneAgentStrip.draws(status: nil, title: "  ", infoStrip: true,
                                            stripHeight: 16, isTerminal: true),
                       "a blank title is not a title")
        XCTAssertFalse(PaneAgentStrip.draws(status: live, title: "build", infoStrip: false,
                                            stripHeight: 16, isTerminal: true),
                       "the switch off paints nothing")
        XCTAssertFalse(PaneAgentStrip.draws(status: live, title: "build", infoStrip: true,
                                            stripHeight: 0, isTerminal: true),
                       "no reserved height, nothing to paint into")
    }

    /// A named but agent-less pane: the band is just the title — no glyph, no clock, neutral tone —
    /// and the title still goes through the shared rulebook (no control characters over a terminal).
    func testTitleOnlyIsAPlainNeutralLine() {
        let plain = PaneAgentStrip.Model.titleOnly(title: "build")
        XCTAssertEqual(plain.text, "build")
        XCTAssertEqual(plain.glyph, "", "no agent, no glyph")
        XCTAssertEqual(plain.elapsed, "", "no agent, no clock")
        XCTAssertEqual(plain.tone, .neutral)
        let nasty = PaneAgentStrip.Model.titleOnly(title: "one\u{1B}[2Jtwo\nthree")
        XCTAssertFalse(nasty.text.contains("\u{1B}"), "an escape sequence must never be drawn")
        XCTAssertFalse(nasty.text.contains("\n"))
    }

    /// **The bar fills the reserved band, and takes the mouse nowhere else.**
    ///
    /// It ends exactly at `strip-height` — the band is real reserved space above the terminal, so
    /// filling it never reaches the terminal's text — and it starts one border line in on every
    /// side it touches, because the border is not the bar's to paint over: the red pane mark rides
    /// on that line at the top right and stays visible whatever the bar is doing.
    func testTheBarFillsTheReservedBandAndStartsBelowTheBorder() {
        let pane = CGSize(width: 800, height: 600)
        let border = PaneTitleBadge.lineWidth
        for stripHeight in [12, 16, 20, 32] {
            let rect = PaneAgentStrip.rect(in: pane, stripHeight: stripHeight)
            XCTAssertEqual(rect.minY, PaneAgentStrip.Metrics.topInset,
                           "strip-height \(stripHeight): the bar starts under the border's inner half")
            XCTAssertLessThan(rect.minY, border, "and never at or below the border's inner edge")
            XCTAssertEqual(rect.minX, border)
            XCTAssertEqual(rect.maxX, pane.width - border, "the bar spans the pane's inner width")
            XCTAssertEqual(rect.maxY, CGFloat(stripHeight),
                           "strip-height \(stripHeight): the bar fills the band exactly")
            XCTAssertLessThan(rect.height, pane.height / 10,
                              "the bar must never be able to eat the pane's mouse events")
        }
        // A pane narrower than the two borders still produces a valid (empty) rect rather than a
        // negative width, which would trap in a SwiftUI frame.
        XCTAssertEqual(PaneAgentStrip.rect(in: CGSize(width: 2, height: 10), stripHeight: 16).width, 0)
    }

    /// The same claim, against a bar SwiftUI has actually laid out, at the configured font size.
    ///
    /// **The only way to check this is to lay one out for real.** The bar pins its frame to `rect`,
    /// and a message far too long to fit must be truncated rather than grow the bar past its
    /// reserved height onto the terminal below. If this ever fails, the bar is drawing over the
    /// first row of the terminal.
    func testTheLaidOutBarNeverExceedsTheReservedBand() {
        let long = status(.blocked, detail: .approval, tool: "Bash",
                          message: String(repeating: "rm -rf build ", count: 20))
        for (stripHeight, fontSize) in [(16, 11), (20, 13), (24, 16)] {
            let rect = PaneAgentStrip.rect(in: CGSize(width: 600, height: 400), stripHeight: stripHeight)
            let laidOut = NSHostingView(
                rootView: PaneAgentStrip.Bar(model: model(long), size: rect.size,
                                             fontSize: CGFloat(fontSize),
                                             background: .red, text: .white)).fittingSize
            XCTAssertEqual(laidOut.height, rect.height, accuracy: 0.5,
                           "strip-height \(stripHeight): the text may not grow the bar")
            XCTAssertEqual(laidOut.width, rect.width, accuracy: 0.5,
                           "a message far too long to fit is truncated, never allowed to widen the bar")
        }
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

    /// **The line is `title · name · state`.** The pane's own title leads when it has one (on a
    /// screen of four Claude Code panes it is the one word that tells them apart), the agent's name
    /// always follows so you still see *which* agent, and a blank or absent title falls back to
    /// just the name. A title that is already the agent's name is not repeated. The title goes
    /// through the border badge's own 20-character rule, so it is cut the same way wherever drawn.
    func testThePaneTitleLeadsThenTheAgentNameThenTheState() {
        let live = status(.working, detail: .thinking)
        XCTAssertEqual(model(live, title: "build").text, "build · Claude Code · Thinking")
        XCTAssertEqual(model(live, title: nil).text, "Claude Code · Thinking",
                       "no title: just the agent's name")
        XCTAssertEqual(model(live, title: "   ").text, "Claude Code · Thinking",
                       "a blank title is not a title")
        XCTAssertEqual(model(live, title: "Claude Code").text, "Claude Code · Thinking",
                       "a title that is already the agent's name is not repeated")
        XCTAssertEqual(model(live, title: String(repeating: "a", count: 30)).text,
                       String(repeating: "a", count: 19) + "… · Claude Code · Thinking",
                       "the border badge's 20-character rule still clamps the title")
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
    /// the view owns the config and the theme. `blocked` and `error` are the two that mean "go
    /// and look", and they are the two the bar wears `[agents] strip-attention` for — the whole
    /// point of a filled bar is that this is readable across a screen without reading a word.
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

    // MARK: The configured colours

    /// The bar's three colours come out of `[agents]`, and they go through the **config schema's
    /// own validator** — so a value the settings accept is exactly a value the bar can draw, and
    /// there is no second opinion about what a colour is.
    func testTheConfiguredColoursParseThroughTheSchema() {
        func rgb(_ color: Color) -> [Double] {
            guard let raw = NSColor(color).usingColorSpace(.deviceRGB) else { return [] }
            return [raw.redComponent, raw.greenComponent, raw.blueComponent].map(Double.init)
        }
        let fallback = AgentSettings.defaultStripText
        for (hex, want) in [("#ff0000", [1.0, 0, 0]), ("00ff00", [0.0, 1, 0]),
                            ("#0000FF", [0.0, 0, 1])] {
            let got = rgb(PaneAgentStrip.color(hex: hex, fallback: fallback))
            XCTAssertEqual(got.count, 3, hex)
            for (a, b) in zip(got, want) { XCTAssertEqual(a, b, accuracy: 0.005, hex) }
        }
        // Garbage cannot reach here (the schema rejects it at the door) but must not crash or
        // draw black if it ever does: it falls back to the default, which is a real colour.
        for garbage in ["", "slate", "#12345", "#gggggg"] {
            XCTAssertEqual(rgb(PaneAgentStrip.color(hex: garbage, fallback: fallback)),
                           rgb(PaneAgentStrip.color(hex: fallback, fallback: fallback)),
                           "\(garbage) has to fall back to the default colour")
        }
    }

    /// **State -> background**, the mapping the user actually sees: the four quiet states share
    /// `strip-background`, the two that need a human wear `strip-attention`, and a finished turn
    /// starts green and blends back into the base.
    func testTheStateChoosesTheBackground() {
        var settings = AgentSettings()
        settings.stripBackground = "#101010"
        settings.stripAttention = "#ff0000"
        func background(_ tone: PaneAgentStrip.Model.Tone) -> [Double] {
            let color: Color = switch tone {
            case .neutral: PaneAgentStrip.color(hex: settings.stripBackground,
                                                fallback: AgentSettings.defaultStripBackground)
            case .alert: PaneAgentStrip.color(hex: settings.stripAttention,
                                              fallback: AgentSettings.defaultStripAttention)
            case .finished(let fade):
                PaneAgentStrip.blend(.green,
                                     PaneAgentStrip.color(hex: settings.stripBackground,
                                                          fallback: AgentSettings.defaultStripBackground),
                                     fade)
            }
            guard let raw = NSColor(color).usingColorSpace(.deviceRGB) else { return [] }
            return [raw.redComponent, raw.greenComponent, raw.blueComponent].map(Double.init)
        }
        let base = background(.neutral)
        let attention = background(.alert)
        for state in [AgentState.working, .idle, .unknown] {
            XCTAssertEqual(background(model(status(state, detail: state == .working ? .tool : nil)).tone),
                           base, "\(state) is quiet and wears the base colour")
        }
        for state in [AgentState.blocked, .error] {
            XCTAssertEqual(background(model(status(state, detail: state == .blocked ? .approval : nil)).tone),
                           attention, "\(state) needs a human and wears the attention colour")
        }
        XCTAssertNotEqual(base, attention, "the two have to be distinguishable, or the bar says nothing")
        // And the green fade lands on the configured base rather than on some hard-coded grey.
        XCTAssertEqual(background(model(status(.done), after: 600).tone), base,
                       "once the flash is over, a finished pane is as quiet as an idle one")
        XCTAssertNotEqual(background(model(status(.done)).tone), base, "…but it does flash first")
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

    // MARK: Program status (OSC 7501, spec decisions 14, 15 and 18)

    private func record(_ state: ProgramStatusReport.State, kind: ProgramStatusReport.Kind? = nil,
                        progress: Int? = nil, app: String? = nil, title: String? = nil,
                        message: String? = nil, id: String = "",
                        at offset: TimeInterval = 0) -> ProgramStatusStore.Record {
        ProgramStatusStore.Record(
            report: ProgramStatusReport(state: state, kind: kind, progress: progress,
                                        id: id.split(separator: "/").map(String.init),
                                        app: app, title: title, message: message),
            foregroundGroup: 100, updatedAt: since.addingTimeInterval(offset))
    }

    private func programModel(_ record: ProgramStatusStore.Record, after seconds: TimeInterval = 0,
                              title: String? = nil) -> PaneAgentStrip.Model {
        .program(record: record, now: record.updatedAt.addingTimeInterval(seconds), title: title,
                 language: .en)
    }

    /// Spec 15: `<pane title> · <label> · <state>[ · NN%]`, with the agents' own state words and
    /// the colour and glyph an agent in that state wears.
    func testBandShowsGenericProgram() {
        let cargo = programModel(record(.working, progress: 40, app: "cargo"))
        XCTAssertEqual(cargo.text, "cargo · Running · 40%")
        XCTAssertEqual(cargo.tone, .neutral)
        XCTAssertEqual(cargo.glyph, PaneAgentStrip.Model.spinner[0], "working spins")
        XCTAssertEqual(programModel(record(.working, progress: 40, app: "cargo"), title: "build").text,
                       "build · cargo · Running · 40%", "the pane title leads, as for an agent")
        XCTAssertEqual(programModel(record(.working)).text, "Program · Running",
                       "no title and no app: the generic label")

        let auth = programModel(record(.blocked, kind: .auth, app: "gh"))
        XCTAssertEqual(auth.text, "gh · Waiting for you to sign in")
        XCTAssertEqual(auth.tone, .alert)
        XCTAssertEqual(auth.glyph, "●")
        XCTAssertEqual(programModel(record(.blocked, app: "cargo")).text, "cargo · Waiting for input")
        XCTAssertEqual(programModel(record(.blocked, kind: .permission, app: "cargo")).text,
                       "cargo · Awaiting approval")
        XCTAssertEqual(programModel(record(.error, app: "cargo")).tone, .alert)
        XCTAssertEqual(programModel(record(.done, app: "cargo")).text, "cargo · Finished")
        XCTAssertEqual(programModel(record(.done, app: "cargo")).tone, .finished(fade: 0))
        XCTAssertEqual(programModel(record(.idle, app: "cargo")).text, "cargo · Idle")
        XCTAssertEqual(programModel(record(.working, app: "cargo"), after: 65).elapsed, "1m 5s")
    }

    /// Spec 11: the label is the record's `title`, else its `app`, else "Program". A title that
    /// sanitises to nothing is no title.
    func testBandPrefersTitleOverApp() {
        XCTAssertEqual(programModel(record(.working, app: "cargo", title: "Build crate")).text,
                       "Build crate · Running")
        XCTAssertEqual(programModel(record(.working, app: "cargo", title: "\u{200B}\u{202E}")).text,
                       "cargo · Running", "an invisible title falls back to the app")
        XCTAssertEqual(programModel(record(.working, title: "Build crate")).text, "Build crate · Running")
    }

    /// The program's own words follow a colon, after the progress.
    func testBandShowsMessageAfterColon() {
        XCTAssertEqual(programModel(record(.working, progress: 40, app: "cargo",
                                           message: "compiling serde")).text,
                       "cargo · Running · 40%: compiling serde")
        XCTAssertEqual(programModel(record(.blocked, kind: .question, app: "cargo",
                                           message: "overwrite?")).text,
                       "cargo · Waiting for input: overwrite?")
    }

    /// Spec 15: no bidirectional override or zero-width character from a program reaches the
    /// band, in its title or its message; control characters never arrive (the engine refuses
    /// them) and would be stripped anyway.
    func testTitleIsSanitisedForDisplay() {
        let model = programModel(record(.working, app: "cargo", title: "\u{202E}gnp.exe\u{202C}",
                                        message: "a\u{200B}b\u{2066}c"))
        XCTAssertEqual(model.text, "gnp.exe · Running: abc")
        for scalar in model.text.unicodeScalars {
            XCTAssertNotEqual(scalar.properties.generalCategory, .format, "U+\(String(scalar.value, radix: 16))")
        }
        let long = programModel(record(.working, app: "cargo", message: String(repeating: "x", count: 500)))
        XCTAssertLessThanOrEqual(long.text.count, TitleRules.maxLength)
    }

    /// An agent status that carries a progress from its own reports shows it after the tool.
    func testTheAgentBandShowsProgress() {
        var live = status(.working, detail: .tool, tool: "Bash", message: "npm test")
        live.progress = 40
        XCTAssertEqual(model(live).text, "Claude Code · Running · Bash · 40%: npm test")
    }

    /// Spec 14: the band draws the winner of the pane's agent status and its records. The records
    /// of the agent that holds the status are already folded into it (spec 12: hook first), so
    /// they are not a second candidate; the resume button and a title-only band only show when
    /// nothing wins.
    func testTheBandDrawsTheWinner() throws {
        let rules = ["claude-code": try AgentRules.parse("""
        id = "claude-code"
        name = "Claude Code"
        process = ["claude"]
        """)]
        let working = status(.working, detail: .tool, tool: "Bash")
        let cargo = record(.blocked, app: "cargo", at: 1)
        guard case .program(let won)? = ProgramStatusMapper.winner(agent: working, records: [cargo])
        else { return XCTFail("a blocked cargo outranks a working agent") }
        XCTAssertEqual(won, cargo)

        let own = record(.blocked, app: "claude", id: "x", at: 1)
        let byID = record(.working, app: "claude-code", id: "y", at: 1)
        XCTAssertEqual(ProgramStatusMapper.bandRecords(agent: working, records: [own, cargo, byID],
                                                       rules: rules), [cargo],
                       "the agent's own records are part of its status, not a rival on the band")
        XCTAssertEqual(ProgramStatusMapper.bandRecords(agent: nil, records: [own, cargo], rules: rules),
                       [own, cargo], "with no status to fold them into, they are drawn as they are")
        XCTAssertEqual(ProgramStatusMapper.bandRecords(agent: working, records: [own, cargo], rules: [:]),
                       [own, cargo], "with the rule off, they are generic programs")

        XCTAssertTrue(PaneAgentStrip.draws(status: nil, title: nil, infoStrip: true, stripHeight: 16,
                                           isTerminal: true, program: true),
                      "a program alone paints the band")
        XCTAssertFalse(PaneAgentStrip.draws(status: nil, title: nil, infoStrip: false, stripHeight: 16,
                                            isTerminal: true, program: true))
        XCTAssertNil(PaneAgentStrip.resumeLabel(offer: "Resume", status: nil, isTerminal: true,
                                                program: true),
                     "a program in the pane owns the band; no resume button")
        XCTAssertEqual(PaneAgentStrip.resumeLabel(offer: "Resume", status: nil, isTerminal: true), "Resume")
    }

    /// Spec 18: at most 4 band redraws a second per pane. A 1→100 progress burst in 100 ms draws
    /// the first value at once and the last one 250 ms later, nothing in between, and no timer
    /// is left behind once it is drawn.
    func testBandRedrawsAreCoalesced() throws {
        var clock = since
        var scheduled: [(at: Date, run: @MainActor () -> Void)] = []
        let throttle = BandRedrawThrottle(clock: { clock }, schedule: { delay, run in
            scheduled.append((clock.addingTimeInterval(delay), run))
        })
        func advance(to time: Date) {
            clock = time
            let due = scheduled.filter { $0.at <= time }
            scheduled.removeAll { $0.at <= time }
            for item in due { item.run() }
        }

        // The throttle on its own.
        let pane = UUID()
        var value = 0
        var drawn: [(at: Date, value: Int)] = []
        for step in 1...100 {
            advance(to: since.addingTimeInterval(Double(step - 1) * 0.001))
            value = step
            throttle.request(pane) { drawn.append((clock, value)) }
        }
        XCTAssertEqual(drawn.map(\.value), [1], "the first change draws at once")
        XCTAssertEqual(scheduled.count, 1, "one pending redraw, however many changes")
        advance(to: since.addingTimeInterval(0.26))
        XCTAssertEqual(drawn.map(\.value), [1, 100], "the last value is always drawn")
        XCTAssertTrue(scheduled.isEmpty, "nothing runs while the pane is idle")
        for (a, b) in zip(drawn, drawn.dropFirst()) {
            XCTAssertGreaterThanOrEqual(b.at.timeIntervalSince(a.at), 0.25 - 1e-6)
        }
        // A change after a quiet spell draws at once again.
        advance(to: since.addingTimeInterval(2))
        throttle.request(pane) { drawn.append((clock, 101)) }
        XCTAssertEqual(drawn.last?.value, 101)

        // Wired through the registry: a burst of reports reaches the pane's records at most once
        // per 250 ms, and the band ends on the final record.
        let host = try XCTUnwrap((NSApp.delegate as? AppDelegate)?.screens.primary)
        let locator = NoticeLocatorStub()
        let view = PaneView(frame: .zero)
        locator.entries[view.id] = .init(pane: view, controller: host, workspace: 0,
                                         activity: PaneActivity(appActive: false, screenKey: false,
                                                                workspaceVisible: false, focused: false))
        let store = ProgramStatusStore(clock: { clock })
        let registry = AgentRegistry(center: NoticeCenter(locator: locator, clock: { clock }),
                                     locator: locator, programStatus: store, clock: { clock })
        registry.listenToProgramStatus()
        registry.bandThrottle = throttle
        let start = clock.addingTimeInterval(10)
        var redraws = 0
        let watch = view.objectWillChange.sink { redraws += 1 }
        defer { watch.cancel() }
        for step in 1...100 {
            advance(to: start.addingTimeInterval(Double(step - 1) * 0.001))
            store.receive(ProgramStatusReport(state: .working, kind: nil, progress: step, id: [],
                                              app: "cargo", title: nil, message: nil),
                          pane: view.id, foregroundGroup: 100)
        }
        XCTAssertEqual(redraws, 1)
        XCTAssertEqual(view.programRecords.first?.report.progress, 1)
        advance(to: start.addingTimeInterval(0.26))
        XCTAssertEqual(redraws, 2)
        XCTAssertEqual(view.programRecords.first?.report.progress, 100)
        XCTAssertTrue(scheduled.isEmpty)
    }
}
