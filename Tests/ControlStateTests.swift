import XCTest
@testable import QuickTerm

/// Live controllers -> `quickterm.state/1`, plus target resolution landing on real panes.
@MainActor
final class ControlStateTests: XCTestCase {
    private var controller: MainWindowController {
        get throws { try XCTUnwrap((NSApp.delegate as? AppDelegate)?.controller) }
    }

    private var screens: ScreenRegistry {
        get throws { try XCTUnwrap((NSApp.delegate as? AppDelegate)?.screens) }
    }

    private func spin(_ seconds: TimeInterval = 0.15) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private func encoder(trusted: Bool = true, expose: String = "token") throws -> ControlStateEncoder {
        ControlStateEncoder(screens: try screens, trusted: trusted, exposeBrowser: expose, mode: "ask")
    }

    // MARK: Encoding

    func testStateIsOneBasedEverywhere() throws {
        let controller = try controller
        controller.model.switchTo(0)
        controller.ensureStarterPane()
        spin()
        let payload = try encoder().payload()
        let screen = try XCTUnwrap(payload.screens.first)
        XCTAssertEqual(screen.index, 1, "screen indices are 1-based (matching the window title)")
        XCTAssertEqual(screen.title, "QuickTerm", "the first screen's title has to be exactly QuickTerm")
        XCTAssertEqual(screen.activeWorkspace, 1, "the active workspace is 1-based (the 0-based internal index never leaks)")
        XCTAssertEqual(screen.workspaces.first?.index, 1)
        XCTAssertEqual(screen.workspaces.count, controller.model.layouts.count)
        for pane in payload.panes {
            XCTAssertGreaterThanOrEqual(pane.workspace, 1)
            XCTAssertGreaterThanOrEqual(pane.screen, 1)
        }
    }

    func testPanesGetStableTypePrefixedHandles() throws {
        let controller = try controller
        controller.model.switchTo(0)
        controller.perform(.newTerminal)
        spin()
        let pane = try XCTUnwrap(controller.focusedSurface)
        defer {
            controller.closePane(pane, confirmIfNeeded: false, animated: false)
            spin(0.05)
        }
        let handle = ControlHandleRegistry.shared.handle(for: pane)
        XCTAssertTrue(handle.hasPrefix("t"), "a terminal pane's handle starts with t: \(handle)")
        XCTAssertEqual(ControlHandleRegistry.shared.handle(for: pane), handle, "handles are stable for the life of the process")
        XCTAssertEqual(ControlHandleRegistry.shared.paneID(forHandle: handle), pane.id)

        let payload = try encoder().payload()
        let info = try XCTUnwrap(payload.panes.first { $0.handle == handle })
        XCTAssertEqual(info.kind, "terminal")
        XCTAssertEqual(info.role, "shell")
        XCTAssertEqual(info.id, pane.id.uuidString)
        // The workspace skeleton references handles only and does not repeat the whole pane
        // record (otherwise the JSON of a six-screen session eats the entire context)
        let workspace = try XCTUnwrap(payload.screens.first?.workspaces.first { $0.active })
        XCTAssertTrue(workspace.panes.contains(handle))
    }

    func testClosingPanesAreNotAddressable() throws {
        let controller = try controller
        controller.model.switchTo(0)
        controller.closeAnimationEnabled = true
        controller.perform(.newTerminal)
        spin()
        let pane = try XCTUnwrap(controller.focusedSurface)
        let handle = ControlHandleRegistry.shared.handle(for: pane)
        controller.closePane(pane, confirmIfNeeded: false, animated: true)
        // Fading out: still in model.layouts, but the control plane must not be able to address
        // it any more
        XCTAssertTrue(controller.model.closingPanes.contains(pane.id), "precondition: the fade-out is running")
        let payload = try encoder().payload()
        XCTAssertFalse(payload.panes.contains { $0.handle == handle }, "a pane that is fading out is not addressable")
        let addressable = ControlResolver.addressablePanes(in: try screens)
        XCTAssertFalse(addressable.contains { $0.pane === pane })
        controller.flushPendingCloses()
        spin(0.05)
    }

    func testBrowserRedactionRule() throws {
        // One rule: a caller without an origin token cannot read a browser pane's URL or title.
        // `quickterm state` is an exfiltration surface in its own right — a browser pane holds the
        // user's logged-in sessions
        XCTAssertTrue(try encoder(trusted: true, expose: "token").exposesBrowser)
        XCTAssertFalse(try encoder(trusted: false, expose: "token").exposesBrowser)
        XCTAssertTrue(try encoder(trusted: false, expose: "always").exposesBrowser)
        XCTAssertFalse(try encoder(trusted: true, expose: "never").exposesBrowser)
    }

    // MARK: Resolution

    func testResolvesFocusedAndHandle() throws {
        let controller = try controller
        controller.model.switchTo(0)
        controller.perform(.newTerminal)
        spin()
        let pane = try XCTUnwrap(controller.focusedSurface)
        defer {
            controller.closePane(pane, confirmIfNeeded: false, animated: false)
            spin(0.05)
        }
        let handle = ControlHandleRegistry.shared.handle(for: pane)
        let resolver = ControlResolver(screens: try screens, origin: nil)

        let byHandle = try resolver.resolve(ControlTarget.parse(handle))
        XCTAssertTrue(byHandle.pane === pane)
        XCTAssertEqual(byHandle.echo.screen, 1)
        XCTAssertEqual(byHandle.echo.pane, handle)

        let byPrefix = try resolver.resolve(ControlTarget.parse("#" + pane.id.uuidString.prefix(8)))
        XCTAssertTrue(byPrefix.pane === pane)

        let focused = try resolver.resolve(ControlTarget.parse("@focused"))
        XCTAssertTrue(focused.pane === pane)
    }

    func testResolvesSelfFromOriginEnvironment() throws {
        let controller = try controller
        controller.model.switchTo(0)
        controller.perform(.newTerminal)
        spin()
        let pane = try XCTUnwrap(controller.focusedSurface)
        defer {
            controller.closePane(pane, confirmIfNeeded: false, animated: false)
            spin(0.05)
        }
        let resolver = ControlResolver(screens: try screens,
                                       origin: ControlRequestOrigin(pane: pane.id.uuidString,
                                                                    screen: 1, workspace: 1, pid: 1))
        XCTAssertTrue(try resolver.resolve(ControlTarget.parse("@self")).pane === pane)

        let stale = ControlResolver(screens: try screens,
                                    origin: ControlRequestOrigin(pane: UUID().uuidString,
                                                                 screen: 1, workspace: 1, pid: 1))
        XCTAssertThrowsError(try stale.resolve(ControlTarget.parse("@self")),
                             "when QUICKTERM_PANE points at a pane that no longer exists it has "
                             + "to error out, not fall back to the focused pane")
    }

    func testAmbiguousPredicateListsCandidatesInsteadOfGuessing() throws {
        let controller = try controller
        controller.model.switchTo(0)
        controller.perform(.newTerminal)
        spin()
        let first = try XCTUnwrap(controller.focusedSurface)
        controller.perform(.newTerminal)
        spin()
        let second = try XCTUnwrap(controller.focusedSurface)
        defer {
            for pane in [first, second] {
                controller.closePane(pane, confirmIfNeeded: false, animated: false)
            }
            spin(0.1)
        }
        XCTAssertFalse(first === second)

        let resolver = ControlResolver(screens: try screens, origin: nil)
        do {
            _ = try resolver.resolve(ControlTarget.parse("kind:terminal"))
            XCTFail("with more than one terminal pane, kind:terminal has to report an ambiguity")
        } catch let error as ControlErrorBody {
            XCTAssertEqual(error.code, ControlErrorCode.ambiguousTarget.rawValue)
            XCTAssertEqual(error.exit, ControlExit.badTarget.rawValue)
            let candidates = try XCTUnwrap(error.candidates)
            XCTAssertGreaterThanOrEqual(candidates.count, 2,
                                        "the error has to list every candidate and never just take the first")
            XCTAssertTrue(candidates.contains(ControlHandleRegistry.shared.handle(for: first)))
            XCTAssertTrue(candidates.contains(ControlHandleRegistry.shared.handle(for: second)))
        }
    }

    func testWorkspaceOutOfRangeNamesTheCurrentCount() throws {
        let controller = try controller
        let resolver = ControlResolver(screens: try screens, origin: nil)
        let count = controller.model.layouts.count
        do {
            _ = try resolver.resolve(ControlTarget.parse(":\(count + 1)"))
            XCTFail("an out-of-range workspace has to error out")
        } catch let error as ControlErrorBody {
            XCTAssertEqual(error.code, ControlErrorCode.notFound.rawValue)
            XCTAssertTrue(error.message.contains("\(count)"),
                          "the error has to say how many workspaces there are: \(error.message)")
        }
    }

    func testUnknownScreenListsAvailableOnes() throws {
        let resolver = ControlResolver(screens: try screens, origin: nil)
        do {
            _ = try resolver.resolve(ControlTarget.parse("99"))
            XCTFail("a screen that does not exist has to error out")
        } catch let error as ControlErrorBody {
            XCTAssertEqual(error.code, ControlErrorCode.notFound.rawValue)
            XCTAssertFalse(error.candidates?.isEmpty ?? true)
        }
    }

    // MARK: Environment injection

    func testSpawnedPaneCarriesControlEnvironment() throws {
        let injected = ControlEnvironment.inject(into: ["PATH": "/usr/bin"],
                                                 paneID: UUID(uuidString: "9C1B4E2F-0000-0000-0000-000000000000")!,
                                                 screen: 2, workspace: 3)
        XCTAssertEqual(injected["PATH"], "/usr/bin", "an existing variable must not be overwritten")
        XCTAssertEqual(injected[ControlProtocol.Env.pane], "9C1B4E2F-0000-0000-0000-000000000000")
        XCTAssertEqual(injected[ControlProtocol.Env.screen], "2")
        XCTAssertEqual(injected[ControlProtocol.Env.workspace], "3")
        // With nothing listening, neither socket nor token is injected (otherwise the pane gets a
        // path nothing answers on)
        let socketPath = ControlEnvironment.socketPath
        ControlEnvironment.socketPath = nil
        XCTAssertNil(ControlEnvironment.inject(into: [:], paneID: UUID(), screen: nil,
                                               workspace: nil)[ControlProtocol.Env.socket])
        ControlEnvironment.socketPath = "/tmp/x.sock"
        let mine = UUID()
        let live = ControlEnvironment.inject(into: [:], paneID: mine, screen: nil, workspace: nil)
        XCTAssertEqual(live[ControlProtocol.Env.socket], "/tmp/x.sock")
        XCTAssertEqual(live[ControlProtocol.Env.token], ControlEnvironment.token)
        XCTAssertEqual(ControlEnvironment.token.count, 64, "32 random bytes -> 64 hex digits")

        // The per-pane marker: **different for every pane**, and knowing the paneID alone is not
        // enough to derive it (the key never leaves the process). It is the only thing the
        // send-text self-write exemption rests on, which makes this case structural
        let paneToken = try XCTUnwrap(live[ControlProtocol.Env.paneToken])
        XCTAssertEqual(paneToken, ControlEnvironment.paneToken(for: mine))
        XCTAssertEqual(paneToken.count, 64, "HMAC-SHA256 -> 64 hex digits")
        let other = ControlEnvironment.inject(into: [:], paneID: UUID(), screen: nil, workspace: nil)
        XCTAssertNotEqual(other[ControlProtocol.Env.paneToken], paneToken,
                          "two panes must get different origin markers, otherwise the marker proves nothing about which one")
        XCTAssertNotEqual(paneToken, ControlEnvironment.token,
                          "do not let the global token and the per-pane marker collapse into the same value")
        ControlEnvironment.socketPath = socketPath
    }

    func testConfigParsesControlSection() {
        let settings = ConfigStore.parse("""
        [control]
        enabled = true
        mode = "readonly"
        expose-browser = "never"
        send-text = true
        """)
        XCTAssertTrue(settings.controlSocket, "the old name enabled still maps onto the socket switch")
        XCTAssertEqual(settings.controlMode, "readonly")
        XCTAssertEqual(settings.controlExposeBrowser, "never")
        XCTAssertTrue(settings.controlSendText)

        let defaults = ConfigStore.parse("")
        XCTAssertTrue(defaults.controlSocket, "on by default")
        XCTAssertTrue(defaults.controlMCP, "MCP is on by default")
        XCTAssertEqual(defaults.controlMode, "ask", "ask by default")
        XCTAssertEqual(defaults.controlExposeBrowser, "token")
        XCTAssertFalse(defaults.controlSendText, "send-text is off by default")

        let off = ConfigStore.parse("[control]\nenabled = false\n")
        XCTAssertFalse(off.controlSocket)
        XCTAssertFalse(ControlCommandRunner.Config(off).isListening)
        XCTAssertFalse(ControlCommandRunner.Config(ConfigStore.parse("[control]\nmode = \"off\"\n")).isListening)
        XCTAssertFalse(ControlCommandRunner.Config(ConfigStore.parse("[control]\nmode = \"readonly\"\n")).allowsMutation)

        // The template has to show this section ("every setting belongs in the config file")
        XCTAssertTrue(ConfigStore.template.contains("[control]"))
        XCTAssertTrue(ConfigStore.template.contains("expose-browser"))
        XCTAssertTrue(ConfigStore.template.contains("# socket = true"))
        XCTAssertTrue(ConfigStore.template.contains("# mcp = true"))
    }

    func testTestHostNeverBindsTheRealSocket() throws {
        let session = try XCTUnwrap((NSApp.delegate as? AppDelegate)?.session)
        XCTAssertFalse(session.controlServer.isListening,
                       "the test host must never take over the control socket of the user's QuickTerm")
        XCTAssertFalse(FileManager.default.fileExists(atPath: ControlPaths.preferredSocketPath)
                       && session.controlServer.socketPath == ControlPaths.preferredSocketPath)
    }
}

/// Regression cases added after the adversarial review: each one pins down a hole that **really
/// was there** at the time.
@MainActor
final class ControlSecurityTests: XCTestCase {
    private var controller: MainWindowController {
        get throws { try XCTUnwrap((NSApp.delegate as? AppDelegate)?.controller) }
    }

    private var screens: ScreenRegistry {
        get throws { try XCTUnwrap((NSApp.delegate as? AppDelegate)?.screens) }
    }

    private func spin(_ seconds: TimeInterval = 0.15) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    // MARK: mode = "on" used to be a switch that silently turned the consent gate off

    func testModeOnIsJustAskAndNeverDisablesTheConsentGate() {
        // The template listed the values of mode as `off | readonly | ask | on`, and "on" was
        // never defined anywhere. A user will read it as the opposite of off ("just turn it on"),
        // and writing it down turned the whole destructive-consent gate off
        XCTAssertEqual(ConfigStore.parse("[control]\nmode = \"on\"\n").controlMode, "ask",
                       "\"on\" can only ever be an alias for ask")

        // The consent gate may only be bypassed by an explicit off / readonly, never by some
        // other spelling
        for mode in ["off", "readonly", "ask", "on", "yolo", "ASK", ""] {
            var config = ControlCommandRunner.Config()
            config.mode = mode
            XCTAssertEqual(config.promptsForDestructive, config.allowsMutation,
                           "mode = \"\(mode)\": as long as mutations can still run, a "
                           + "destructive command has to be confirmed")
            if config.allowsMutation {
                XCTAssertTrue(config.promptsForDestructive, "mode = \"\(mode)\" must not become a no-prompt setting")
            }
        }

        // The template must not park an undefined setting next to off ever again
        let modeLine = ConfigStore.template.split(separator: "\n").first { $0.contains("mode = ") }
        XCTAssertNotNil(modeLine)
        XCTAssertFalse(modeLine?.contains("| on") ?? false, "the template must not advertise a fourth setting beyond ask")

        // The policy sentence in describe must not keep saying "you get a prompt" under readonly
        // either
        XCTAssertTrue(ControlDescribeDocument.destructivePolicy(mode: "ask").contains("Confirmed once"))
        XCTAssertTrue(ControlDescribeDocument.destructivePolicy(mode: "readonly").contains("always refused"))
        XCTAssertFalse(ControlDescribeDocument.destructivePolicy(mode: "readonly").contains("Confirmed once"))
    }

    // MARK: title:~ used to freeze the whole app with 7 bytes

    func testTitlePredicateAbortsCatastrophicBacktrackingInsteadOfFreezingTheApp() throws {
        // The caller's regex runs on the main thread, and ICU is a backtracking engine with no
        // time limit by default: the patterns below are exponential against a title the length of
        // an ordinary prompt (measured at several hours). And title: goes through a read-class
        // command — no token, no consent, not even rate limiting
        let title = String(repeating: "a", count: 60) + "!"
        for pattern in ["(a|aa)+$", "(.|.)+z", "(a+)+$"] {
            let regex = try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
            let started = Date()
            let result = ControlResolver.titleMatches(
                title, regex: regex,
                deadline: started.addingTimeInterval(ControlResolver.titleMatchBudget))
            XCTAssertNil(result, "\(pattern) has to be cut off inside the budget rather than running until the end of time")
            XCTAssertLessThan(Date().timeIntervalSince(started), 2.0,
                              "\(pattern) blew far past the budget: the guard rail did not fire")
        }

        // Ordinary patterns still run (the guard rail must not take the useful predicate down
        // with it)
        let ok = try NSRegularExpression(pattern: "nvim", options: [.caseInsensitive])
        XCTAssertEqual(ControlResolver.titleMatches("nvim foo.txt", regex: ok,
                                                    deadline: Date().addingTimeInterval(5)), true)
        XCTAssertEqual(ControlResolver.titleMatches("zsh", regex: ok,
                                                    deadline: Date().addingTimeInterval(5)), false)

        // A timeout fails **the whole command**: computing an ambiguity or a not_found from a pool
        // that was only half walked is a silently wrong answer
        let resolver = ControlResolver(screens: try screens, origin: nil)
        let huge = String(repeating: "x", count: ControlResolver.maxTitlePatternLength + 1)
        do {
            _ = try resolver.resolve(ControlTarget.parse("title:~\(huge)"))
            XCTFail("an oversized regex has to error out")
        } catch let error as ControlErrorBody {
            XCTAssertEqual(error.code, ControlErrorCode.badTarget.rawValue)
        }
    }

    // MARK: title:~ used to be a probe around the browser redaction

    func testRedactedBrowserPanesLeaveTheTitlePredicatePool() throws {
        let controller = try controller
        controller.model.switchTo(0)
        let previous = BrowserPaneView.settings
        BrowserPaneView.settings.home = "about:blank"        // stays off the network
        controller.perform(.newTerminal)
        spin(0.3)
        let terminal = try XCTUnwrap(controller.focusedPane)
        controller.perform(.newBrowser)
        spin(0.5)
        let browser = try XCTUnwrap(controller.paneList.compactMap { $0 as? BrowserPaneView }.last)
        defer {
            for pane in [browser as PaneView, terminal] {
                controller.closePane(pane, confirmIfNeeded: false, animated: false)
            }
            BrowserPaneView.settings = previous
            spin(0.3)
        }
        XCTAssertFalse(browser.paneTitle.isEmpty, "precondition: the browser pane has a title to match against")
        let browserHandle = ControlHandleRegistry.shared.handle(for: browser)
        let terminalHandle = ControlHandleRegistry.shared.handle(for: terminal)

        // `title:~.` matches every non-empty title: whoever lands in the candidate pool is
        // whoever the predicate can see
        func visibleHandles(exposesBrowser: Bool) throws -> [String] {
            let resolver = ControlResolver(screens: try screens, origin: nil,
                                           exposesBrowser: exposesBrowser)
            do {
                let resolution = try resolver.resolve(ControlTarget.parse("title:~."))
                return resolution.pane.map { [ControlHandleRegistry.shared.handle(for: $0)] } ?? []
            } catch let error as ControlErrorBody {
                XCTAssertNotEqual(error.code, ControlErrorCode.badTarget.rawValue, error.message)
                return error.candidates ?? []
            }
        }

        XCTAssertTrue(try visibleHandles(exposesBrowser: true).contains(browserHandle),
                      "precondition: with redaction off, the browser pane is in the candidate pool to begin with")
        let redacted = try visibleHandles(exposesBrowser: false)
        XCTAssertFalse(redacted.contains(browserHandle),
                       "with redaction on, a browser pane must not enter the title:~ candidate "
                           + "pool -- the match count alone is an oracle for reading a redacted "
                           + "title one character at a time")
        XCTAssertTrue(redacted.contains(terminalHandle),
                      "only the browser pane is taken out, the predicate itself is not gutted")
    }

    // MARK: With the app in the background, no screen used to be the key one

    func testExactlyOneScreenIsKeyEvenWithNoKeyWindow() throws {
        // When an agent drives from Terminal.app or a background job, NSApp.keyWindow is nil, and
        // a payload computed from it has key:false on every screen while every screen still reports
        // a pane with focused:true — which leaves the disambiguation rule described in describe
        // ("the globally unique one lives on the screen with key:true") with no answer at all
        if NSApp.keyWindow == nil {
            XCTAssertNil(try screens.key, "precondition: this case is running down the no-key-window branch")
        }
        let payload = try ControlStateEncoder(screens: try screens, trusted: true,
                                              exposeBrowser: "token", mode: "ask").payload()
        let keys = payload.screens.filter(\.key)
        XCTAssertEqual(keys.count, 1, "there is always exactly one key screen")
        XCTAssertEqual(keys.first?.id, try screens.controlCurrent?.windowID.uuidString,
                       "key has to come off the same ladder target resolution uses "
                       + "(controlCurrent), otherwise the echo and the state contradict each other")
    }
}

extension ControlSecurityTests {
    /// The timeout and the sheet callback rear-end each other: `endSheet` fires the
    /// `beginSheetModal` completion **synchronously**, so the `.deny` queued behind the timeout
    /// runs first and the agent is told "the user denied this command" (exit code 5) — while the
    /// user never said a word, and it contradicts the "timeout -> exit code 4" written into
    /// describe and the docs. Whichever decision lands first has to win, and it may only be
    /// delivered once
    func testALateAnswerCannotOverwriteTheFirstDecision() {
        let consent = ControlConsent(screens: nil)
        var decisions: [ControlConsent.Decision] = []
        consent.decisionStub = { _, reply in
            reply(.timeout)
            reply(.deny)      // The second, trailing callback has to be swallowed whole
        }
        consent.evaluate(.init(peerName: "node", peerPID: 4821, cls: .destructive,
                               summary: "close t7", originPane: nil, tokenPresent: false)) {
            decisions.append($0)
        }
        XCTAssertEqual(decisions, [.timeout], "the second callback may neither change the verdict nor deliver a second reply")
        XCTAssertFalse(consent.isPrompting, "the prompting state has to be cleared once an answer lands")
        XCTAssertFalse(consent.hasGrant(pid: 4821, cls: .destructive), "a timeout must never leave a grant behind")
        XCTAssertEqual(ControlErrorCode.confirmationRequired.exit, .confirmationRequired,
                       "a timeout maps to exit code 4, not to denied's 5")
    }
}

/// The refusal taxonomy. Exit code 5 used to mean four different things at once, and the JSON
/// `code` said `denied` for all of them — so a script could not tell "the user clicked Deny"
/// (retrying may well work) from "a switch in the config is off" (retrying never will).
extension ControlSecurityTests {
    func testTheDeniedFamilyIsFourCodesBehindOneExit() {
        // Exits are coarse **by design**: one number for the whole family, and the fine
        // distinction lives in the code. Widening the exit set instead would break every script
        // that already branches on 5
        for code in [ControlErrorCode.denied, .disabled, .cwdDenied, .limit] {
            XCTAssertEqual(code.exit, .denied,
                           "\(code.rawValue) has to keep exit 5: scripts branch on the code, not the exit")
            XCTAssertEqual(ControlErrorBody(code, "x").exit, ControlExit.denied.rawValue,
                           "the body carries the same mapping the CLI uses as its process exit code")
        }
        XCTAssertEqual(Set([ControlErrorCode.denied, .disabled, .cwdDenied, .limit].map(\.rawValue)).count, 4,
                       "four distinct strings, or the split bought nothing")

        // **One spelling, two reportings.** `--require-cwd` turns the warning into an error; the
        // condition is identical, so the string an agent branches on has to be identical too
        XCTAssertEqual(ControlErrorCode.cwdDenied.rawValue, ControlWarning.cwdDenied,
                       "the error code and the warning code are the same condition and must stay "
                       + "spelled the same — an agent matches one string either way")

        // `denied` now means exactly one thing, and the generated documentation has to say so:
        // this summary is what `quickterm describe --json` hands the model
        let denied = ControlErrorCode.denied.summary.lowercased()
        XCTAssertTrue(denied.contains("deny") || denied.contains("user"),
                      "denied's summary has to name the human pressing Deny: \(ControlErrorCode.denied.summary)")
        XCTAssertFalse(ControlErrorCode.disabled.summary.isEmpty)
        XCTAssertFalse(ControlErrorCode.limit.summary.isEmpty)
    }

    /// A switch that is off is not a refusal. Driven through the runner rather than the socket:
    /// `ControlServer.apply` takes the listener down for `mode = "off"`, so the socket can never
    /// deliver this particular answer.
    func testSwitchedOffCommandsReportDisabledNotDenied() throws {
        let harness = try ControlHarness()
        defer { harness.cleanup() }

        harness.runner.config.mode = "off"
        let off = try harness.run("state")
        XCTAssertEqual(off.error?.code, ControlErrorCode.disabled.rawValue,
                       "mode = off is a switch, not somebody refusing")
        XCTAssertEqual(off.error?.exit, ControlExit.denied.rawValue)

        harness.runner.config.mode = "readonly"
        let readOnly = try harness.run("action", args: ["name": .string("new-terminal")])
        XCTAssertEqual(readOnly.error?.code, ControlErrorCode.disabled.rawValue)

        // A sensitive command the user never switched on is the same story, and the hint has to
        // point at the switch — that is the only way out of this state
        harness.runner.config.mode = "ask"
        harness.runner.config.sendText = false
        let sensitive = try harness.run("input.send-text", args: ["text": .string("hi")])
        XCTAssertEqual(sensitive.error?.code, ControlErrorCode.disabled.rawValue)
        XCTAssertNotNil(sensitive.error?.hint)
        XCTAssertTrue(sensitive.error?.hint?.contains("send-text") ?? false,
                      "the hint has to name the config key: \(sensitive.error?.hint ?? "nil")")
    }

    /// The consent alert is drawn in QuickTerm's own window, so it follows the UI language.
    /// It used to read `WMAction.help`, which is the Chinese wording and nothing else — an
    /// English user was asked to approve a sentence half of which was in Chinese. (The Cmd+K
    /// cheat sheet read the same property; both now go through `localizedHelp`.)
    func testConsentSummaryDrawsActionHelpInTheUILanguage() throws {
        let previous = ConfigSchema.templateLanguage
        defer { _ = Localization.shared.setLanguage(previous) }

        let spec = try XCTUnwrap(ControlCommandTable.command("action"))
        let request = ControlRequest(id: "1", cmd: "action", args: ["name": .string("close-pane")])
        func summary() -> String {
            ControlCommandRunner.consentSummary(request, spec: spec, action: .closePane,
                                                target: nil, subject: nil)
        }
        let cjk = CharacterSet(charactersIn: "\u{4E00}"..."\u{9FFF}")

        _ = Localization.shared.setLanguage(.en)
        XCTAssertTrue(summary().contains(WMAction.closePane.helpEN))
        XCTAssertNil(summary().rangeOfCharacter(from: cjk),
                     "the English alert must not draw Chinese: \(summary())")
        XCTAssertEqual(WMAction.closePane.localizedHelp, WMAction.closePane.helpEN,
                       "the accessor the cheat sheet and the alert share has to follow the language")

        _ = Localization.shared.setLanguage(.zh)
        XCTAssertTrue(summary().contains(WMAction.closePane.help))
        XCTAssertEqual(WMAction.closePane.localizedHelp, WMAction.closePane.help)
    }
}

/// ITEM 4 regression: the consent alert promised "only the current tab is closed" for
/// `quickterm pane close` as well, and that command closes the **whole pane, tabs and all**. The
/// user read the reassuring sentence and lost every tab in the pane.
///
/// The pane is a **real** one built through the harness (so its teardown is the real one), and
/// both tabs point at `127.0.0.1:1`, where the connection is refused at once — no DNS, nothing
/// leaves the machine. `consentSummary` only ever reads the pane's kind and its tab count.
extension ControlSecurityTests {
    func testPaneCloseConsentDoesNotPromiseTheTabOnlyWayOut() throws {
        let harness = try ControlHarness()
        defer { harness.cleanup() }
        let controller = try harness.controller
        controller.model.switchTo(0)
        let before = Set(controller.model.allPanes.map(\.id))
        _ = try harness.mutation(try harness.run("pane.new", args: [
            "kind": .string("browser"), "url": .string("http://127.0.0.1:1/a"),
        ]))
        harness.spin(0.35)
        let made = try XCTUnwrap(harness.app.screens.allPanes.first { !before.contains($0.id) },
                                 "pane new --kind browser did not create a pane")
        harness.track(made)
        let browser = try XCTUnwrap(made as? BrowserPaneView)
        browser.addTab(url: URL(string: "http://127.0.0.1:1/b"), activate: false)
        XCTAssertEqual(browser.tabs.count, 2, "precondition: the split only exists above one tab")

        let subject = ControlCommandRunner.PinnedSubject(
            controller: controller, workspace: controller.model.activeIndex,
            pane: browser, handle: "w1", paneIDs: nil,
            description: "w1 \"probe\"", consentText: "w1 “probe”")
        let tabOnly = L("consent.summary.tab-only")
        let wholePane = Lp("consent.summary.whole-pane", count: 2, 2)

        // The COMMAND: the whole pane goes
        let close = try XCTUnwrap(ControlCommandTable.command("pane.close"))
        let command = ControlCommandRunner.consentSummary(
            ControlRequest(id: "1", cmd: "pane.close"), spec: close, action: nil,
            target: nil, subject: subject)
        XCTAssertFalse(command.contains(tabOnly),
                       "quickterm pane close closes the pane, tabs and all — this sentence is a "
                       + "promise it does not keep: \(command)")
        XCTAssertTrue(command.contains(wholePane),
                      "and it has to say how many tabs go with it: \(command)")

        // The ACTION (the Cmd+W path): Chrome's semantics, one tab, and the sentence is true
        let action = try XCTUnwrap(ControlCommandTable.command("action"))
        let viaAction = ControlCommandRunner.consentSummary(
            ControlRequest(id: "2", cmd: "action", args: ["name": .string("close-pane")]),
            spec: action, action: .closePane, target: nil, subject: subject)
        XCTAssertTrue(viaAction.contains(tabOnly), "close-pane really does close only the tab: \(viaAction)")
        XCTAssertFalse(viaAction.contains(wholePane))
    }
}
