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
