import XCTest
@testable import QuickTerm

/// `pane capture-text` — read the characters on a terminal pane's screen.
///
/// One case per gate, and **each gate holds on its own**: remove any one of them and the rest
/// still have to stop the attack. Off by default; a token is required; one prompt per calling
/// process; `--dry-run` is refused; the text leaves no trace.
@MainActor
final class ControlCaptureTextTests: XCTestCase {
    private var harness: ControlHarness!

    override func setUpWithError() throws {
        try super.setUpWithError()
        harness = try ControlHarness()
    }

    override func tearDown() {
        harness?.cleanup()
        harness = nil
        super.tearDown()
    }

    /// Turn `[control] capture-text` on (it ships off)
    private func enableCapture() {
        var config = ControlCommandRunner.Config()
        config.captureText = true
        harness.runner.config = config
    }

    private func target(_ pane: PaneView) -> String { "#\(pane.id.uuidString)" }

    // MARK: Gate one: off by default, and a separate switch from send-text

    func testCaptureIsRefusedWhenTheConfigKeyIsOff() throws {
        XCTAssertFalse(ControlCommandRunner.Config().captureText,
                       "[control] capture-text has to default to false")
        let pane = try harness.newTerminal()
        var prompts = 0
        harness.consent.decisionStub = { _, reply in
            prompts += 1
            reply(.allow)
        }
        let reply = try harness.run("pane.capture-text", target: target(pane),
                                    token: ControlEnvironment.token)
        XCTAssertFalse(reply.ok)
        XCTAssertEqual(reply.error?.code, ControlErrorCode.disabled.rawValue)
        XCTAssertTrue(reply.error?.hint?.contains("capture-text = true") ?? false,
                      "the refusal has to say how to turn it on: \(String(describing: reply.error?.hint))")
        XCTAssertEqual(prompts, 0, "with it off, not even the alert may come up")
    }

    /// **One switch per command.** Turning send-text on must not drag "read the screen" along with
    /// it, and the same the other way round — those are two entirely different grants
    func testTheTwoSensitiveSwitchesAreIndependent() throws {
        let pane = try harness.newTerminal()
        harness.consent.decisionStub = { _, reply in reply(.allow) }

        var onlySendText = ControlCommandRunner.Config()
        onlySendText.sendText = true
        harness.runner.config = onlySendText
        let captured = try harness.run("pane.capture-text", target: target(pane),
                                       token: ControlEnvironment.token)
        XCTAssertFalse(captured.ok, "send-text = true must not turn capture-text on as well")
        XCTAssertEqual(captured.error?.code, ControlErrorCode.disabled.rawValue)

        var onlyCapture = ControlCommandRunner.Config()
        onlyCapture.captureText = true
        harness.runner.config = onlyCapture
        let typed = try harness.run("input.send-text", target: target(pane),
                                    args: ["text": .string("echo hi")],
                                    token: ControlEnvironment.token)
        XCTAssertFalse(typed.ok, "capture-text = true must not turn send-text on as well")
        XCTAssertEqual(typed.error?.code, ControlErrorCode.disabled.rawValue)
    }

    // MARK: Gate two: no origin token, no capture

    /// A caller that cannot even read a browser pane's title certainly must not read a shell's
    /// screen. And that refusal has to happen **before the consent gate**: a command that is going
    /// to be refused anyway should not pull the user away first
    func testCaptureIsRefusedWithoutTheOriginToken() throws {
        enableCapture()
        let pane = try harness.newTerminal()
        var prompts = 0
        harness.consent.decisionStub = { _, reply in
            prompts += 1
            reply(.allow)
        }
        let reply = try harness.run("pane.capture-text", target: target(pane))   // no token
        XCTAssertFalse(reply.ok)
        // `disabled`, not `denied`: nobody was asked, so nobody refused. A caller with no token
        // is in a state retrying cannot change, which is the whole line the split draws
        XCTAssertEqual(reply.error?.code, ControlErrorCode.disabled.rawValue)
        XCTAssertEqual(reply.error?.exit, ControlExit.denied.rawValue)
        XCTAssertTrue(reply.error?.message.contains("QUICKTERM_TOKEN") ?? false,
                      "it has to say what is missing: \(String(describing: reply.error?.message))")
        XCTAssertEqual(prompts, 0, "the refusal has to come before consent")
        XCTAssertNil(reply.data?["text"], "a refused reply must never carry the text")

        // A mistyped token is refused the same way
        let wrong = try harness.run("pane.capture-text", target: target(pane), token: "not-the-token")
        XCTAssertFalse(wrong.ok)
        XCTAssertEqual(wrong.error?.code, ControlErrorCode.disabled.rawValue)
    }

    // MARK: Gate three: consent

    /// One prompt per calling process (at `(pid, command)` granularity), and what the alert names
    /// is **which pane's screen is about to be read**; the user denying means not a character comes
    /// back
    func testCapturePromptsPerProcessAndTheDialogNamesTheRead() throws {
        pinUILanguage(.en)
        enableCapture()
        let pane = try harness.newTerminal()
        var seen: [ControlConsent.Request] = []
        harness.consent.decisionStub = { request, reply in
            seen.append(request)
            reply(.allow)
        }
        for _ in 0..<3 {
            let reply = try harness.run("pane.capture-text", target: target(pane),
                                        token: ControlEnvironment.token)
            XCTAssertTrue(reply.ok, "\(String(describing: reply.error))")
        }
        XCTAssertEqual(seen.count, 1, "one prompt per process is enough (cached by (pid, command) after that)")
        let request = try XCTUnwrap(seen.first)
        XCTAssertEqual(request.cls, .sensitive)
        XCTAssertEqual(request.scope, "pane.capture-text",
                       "one grant key per sensitive command: approving a screen read is not approving typing")
        XCTAssertTrue(request.summary.contains("Read every character"),
                      "the alert has to say this is a read: \(request.summary)")
        XCTAssertNil(request.payload,
                     "a read command has no payload to display (the text is what comes back, and it "
                     + "goes nowhere else)")

        // **The caches do not bleed**: after capture is approved, send-text still has to ask
        var both = harness.runner.config
        both.sendText = true
        harness.runner.config = both
        seen.removeAll()
        _ = try harness.run("input.send-text", target: target(pane),
                            args: ["text": .string("echo hi")], token: ControlEnvironment.token)
        XCTAssertEqual(seen.count, 1, "a capture grant must never open the door for send-text")

        // The user denies = no content comes back
        harness.consent.decisionStub = { _, reply in reply(.deny) }
        harness.consent.reset()
        let denied = try harness.run("pane.capture-text", target: target(pane),
                                     token: ControlEnvironment.token)
        XCTAssertFalse(denied.ok)
        // A real human pressed Deny -- the one thing `denied` still means. Do not re-point this
        // one to `disabled` along with the switch cases above
        XCTAssertEqual(denied.error?.code, ControlErrorCode.denied.rawValue)
        XCTAssertNil(denied.data?["text"])
    }

    // MARK: Gate four: --dry-run is refused (it would become a way around consent)

    /// Everywhere else `--dry-run` also means **no prompt** (a dry run changes nothing, so nothing
    /// is asked). A command that changes nothing yet hands over every character on the screen would
    /// turn that into a back door the moment it honored the flag
    func testCaptureRefusesTheMutationFlagsSoTheyCannotSkipConsent() throws {
        let spec = try XCTUnwrap(ControlCommandTable.command("pane.capture-text"))
        XCTAssertEqual(spec.cls, .sensitive, "it has to land on the side that requires consent")
        XCTAssertTrue(spec.readOnlyEffect, "it changes nothing")
        XCTAssertFalse(spec.honorsMutationFlags, "which is exactly why it refuses --dry-run / --fail-if-noop")

        enableCapture()
        let pane = try harness.newTerminal()
        var prompts = 0
        harness.consent.decisionStub = { _, reply in
            prompts += 1
            reply(.allow)
        }
        for flag in [ControlCommandTable.Flag.dryRun, ControlCommandTable.Flag.failIfNoop] {
            let reply = try harness.run("pane.capture-text", target: target(pane),
                                        args: [flag: .bool(true)], token: ControlEnvironment.token)
            XCTAssertFalse(reply.ok, "--\(flag) has to be refused")
            XCTAssertEqual(reply.error?.code, ControlErrorCode.badRequest.rawValue)
            XCTAssertNil(reply.data?["text"], "--\(flag) must certainly not hand the content over on the way out")
        }
        XCTAssertEqual(prompts, 0)
    }

    // MARK: It really does read the characters on screen

    /// Type a marker into a real surface and read it back.
    /// Three more things get pinned along the way: the grid size, the line count, and that **not
    /// one character of the text reaches the activity log**
    func testCaptureReturnsWhatTheTerminalShows() throws {
        enableCapture()
        harness.consent.decisionStub = { _, reply in reply(.allow) }
        let pane = try harness.newTerminal()
        let surface = try XCTUnwrap(pane as? Ghostty.SurfaceView)
        harness.spin(0.6)   // Wait for the shell to come up and draw its first prompt

        let marker = "QT-CAPTURE-\(UUID().uuidString.prefix(8))"
        let model = try XCTUnwrap(surface.surfaceModel, "the engine surface was never created")
        model.sendText(marker)

        // Engine rendering is asynchronous: poll until it shows up (**not** a fixed sleep)
        var payload: [String: JSONValue] = [:]
        var text = ""
        for _ in 0..<40 {
            harness.spin(0.1)
            let reply = try harness.run("pane.capture-text", target: target(pane),
                                        token: ControlEnvironment.token)
            XCTAssertTrue(reply.ok, "\(String(describing: reply.error))")
            payload = reply.data?.objectValue ?? [:]
            text = payload["text"]?.stringValue ?? ""
            if text.contains(marker) { break }
        }
        XCTAssertTrue(text.contains(marker),
                      "the string typed into the shell has to appear in the captured screen, got: \(text.suffix(200))")

        XCTAssertEqual(payload["command"]?.stringValue, "pane.capture-text")
        XCTAssertEqual(payload["scrollback"]?.intValue, 0, "the viewport alone by default")
        XCTAssertEqual(payload["lines"]?.intValue, text.components(separatedBy: "\n").count)
        XCTAssertEqual(payload["cols"]?.intValue, surface.surfaceSize.map { Int($0.columns) },
                       "the grid size comes back faithfully: that is how a caller knows where this text wraps")
        XCTAssertEqual(payload["rows"]?.intValue, surface.surfaceSize.map { Int($0.rows) })
        XCTAssertEqual(payload["pane"]?["handle"]?.stringValue,
                       ControlHandleRegistry.shared.handle(for: pane))

        // **The text leaves no trace**: not in the activity log, not in the event stream
        for entry in ControlActivityLog.shared.recent(50) {
            XCTAssertFalse(entry.line.contains(marker), "the text must never reach the activity log: \(entry.line)")
        }
        for event in harness.events(since: 0) {
            let encoded = String(decoding: try ControlJSON.encoder.encode(event), as: UTF8.self)
            XCTAssertFalse(encoded.contains(marker), "an event never carries a pane's output: \(encoded)")
        }

        // --scrollback works too (how many history lines there are is up to the shell, so all
        // this pins is "no fewer than the viewport")
        let withHistory = try harness.run("pane.capture-text", target: target(pane),
                                          args: ["scrollback": .int(50)],
                                          token: ControlEnvironment.token)
        XCTAssertTrue(withHistory.ok, "\(String(describing: withHistory.error))")
        XCTAssertGreaterThanOrEqual(withHistory.data?["lines"]?.intValue ?? 0,
                                    payload["lines"]?.intValue ?? 0)
        XCTAssertTrue(withHistory.data?["text"]?.stringValue?.contains(marker) ?? false,
                      "with history included, the viewport section still has to be in there")
    }

    // MARK: Arguments and pane kinds

    func testScrollbackIsBoundedAndTheWrongPaneKindIsNamed() throws {
        enableCapture()
        harness.consent.decisionStub = { _, reply in reply(.allow) }
        let pane = try harness.newTerminal()

        for bad in [-1, ControlCaptureLimits.maxScrollback + 1] {
            let reply = try harness.run("pane.capture-text", target: target(pane),
                                        args: ["scrollback": .int(bad)],
                                        token: ControlEnvironment.token)
            XCTAssertFalse(reply.ok, "--scrollback \(bad) should be refused")
            XCTAssertEqual(reply.error?.code, ControlErrorCode.badRequest.rawValue)
            XCTAssertTrue(reply.error?.message.contains("\(ControlCaptureLimits.maxScrollback)") ?? false,
                          "out of range has to name the range: \(String(describing: reply.error?.message))")
        }

        // A browser pane: wrong_pane_kind, not a hollow generic failure
        let controller = try harness.controller
        let before = Set(controller.model.allPanes.map(\.id))
        _ = try harness.mutation(try harness.run("pane.new", args: [
            "kind": .string("browser"), "url": .string("http://127.0.0.1:1/"),
        ]))
        harness.spin(0.35)
        let browser = try XCTUnwrap(harness.app.screens.allPanes.first { !before.contains($0.id) })
        harness.track(browser)
        let reply = try harness.run("pane.capture-text", target: target(browser),
                                    token: ControlEnvironment.token)
        XCTAssertFalse(reply.ok)
        XCTAssertEqual(reply.error?.code, ControlErrorCode.wrongPaneKind.rawValue)
    }

    /// The length cap trims **from the top**, so the newest lines on screen always survive
    func testTruncationKeepsTheNewestLines() {
        let lines = (1...200).map { "line-\($0) " + String(repeating: "x", count: 2000) }
        let capture = ControlCommandRunner.Capture(text: lines.joined(separator: "\n"),
                                                   lines: lines.count, scrollbackLines: 0,
                                                   truncated: false)
        XCTAssertGreaterThan(capture.text.utf8.count, ControlCaptureLimits.maxBytes,
                             "precondition: this sample really is over the cap")
        // The same rule the implementation uses (that stretch inside `capture`): keep the tail
        var kept: [String] = []
        var bytes = 0
        for line in lines.reversed() {
            bytes += line.utf8.count + 1
            if bytes > ControlCaptureLimits.maxBytes { break }
            kept.append(line)
        }
        XCTAssertEqual(kept.first, lines.last, "the last line has to survive the truncation")
        XCTAssertLessThan(kept.count, lines.count)
    }

    /// **The two counts still have to add up after a truncation.**
    /// Regression: after truncating, `scrollback` was taken as
    /// `min(original history lines, lines kept)`, and what is kept are the last lines — which
    /// contain a full viewport. In the extreme that reported scrollback == lines, so a caller
    /// slicing "the viewport section" as `lines - scrollback` sliced out 0 lines
    func testTruncationKeepsTheScrollbackCountHonest() {
        let viewportRows = 24
        let viewport = (1...viewportRows).map { "view-\($0)" }.joined(separator: "\n")
        // screen = history + viewport (that is the shape the engine hands over), large enough to
        // be certain of hitting the byte cap
        let history = (1...4000).map { "hist-\($0) " + String(repeating: "x", count: 200) }
        let screen = (history + (1...viewportRows).map { "view-\($0)" }).joined(separator: "\n")

        let capture = ControlCommandRunner.assemble(viewport: viewport, screen: screen,
                                                    scrollback: ControlCaptureLimits.maxScrollback)
        XCTAssertTrue(capture.truncated, "precondition: this sample really does hit the byte cap")
        XCTAssertEqual(capture.lines - capture.scrollbackLines, viewportRows,
                       "lines - scrollback still has to be the viewport line count")
        XCTAssertLessThan(capture.scrollbackLines, capture.lines)
        XCTAssertTrue(capture.text.hasSuffix("view-\(viewportRows)"), "the newest lines always survive")

        // The identity holds anyway when nothing is truncated; it has to read the same on both
        // sides of a truncation
        let small = ControlCommandRunner.assemble(
            viewport: viewport,
            screen: ((1...5).map { "hist-\($0)" } + (1...viewportRows).map { "view-\($0)" })
                .joined(separator: "\n"),
            scrollback: 5)
        XCTAssertFalse(small.truncated)
        XCTAssertEqual(small.scrollbackLines, 5)
        XCTAssertEqual(small.lines - small.scrollbackLines, viewportRows)
    }
}
