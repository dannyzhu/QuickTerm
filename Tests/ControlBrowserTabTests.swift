import XCTest
@testable import QuickTerm

/// `browser open|goto|reload|close` — the tab layer inside a browser pane.
///
/// These use a **real** `BrowserPaneView` (a real WKWebView) and every URL points at
/// `127.0.0.1:1`: the connection is refused immediately (no DNS, no traffic leaving the machine),
/// while "which URL this tab is asking for" stays perfectly determined (`effectiveURL` falls back
/// to `lastRequestedURL` while an error page is showing).
@MainActor
final class ControlBrowserTabTests: XCTestCase {
    private var harness: ControlHarness!
    private var previousSettings: BrowserPaneView.Settings!

    override func setUpWithError() throws {
        try super.setUpWithError()
        harness = try ControlHarness()
        try harness.controller.model.switchTo(0)
        previousSettings = BrowserPaneView.settings
        BrowserPaneView.settings.home = "about:blank"
    }

    override func tearDown() {
        BrowserPaneView.settings = previousSettings
        harness?.cleanup()
        harness = nil
        super.tearDown()
    }

    // MARK: Fixtures

    @discardableResult
    private func newBrowser(url: String = "http://127.0.0.1:1/a") throws -> BrowserPaneView {
        let controller = try harness.controller
        let before = Set(controller.model.allPanes.map(\.id))
        _ = try harness.mutation(try harness.run("pane.new", args: [
            "kind": .string("browser"), "url": .string(url),
        ]))
        harness.spin(0.35)
        let made = try XCTUnwrap(harness.app.screens.allPanes.first { !before.contains($0.id) },
                                 "pane new --kind browser did not create a pane")
        harness.track(made)
        return try XCTUnwrap(made as? BrowserPaneView)
    }

    private func handle(_ pane: PaneView) -> String { ControlHandleRegistry.shared.handle(for: pane) }

    /// Send with the origin token (a browser's title / URL is redacted for a tokenless caller by
    /// default, and those are exactly the fields these cases read)
    @discardableResult
    private func run(_ cmd: String, target: String, args: [String: JSONValue] = [:]) throws -> ControlReply {
        try harness.run(cmd, target: target, args: args, token: ControlEnvironment.token)
    }

    private func tabs(of pane: BrowserPaneView) throws -> [JSONValue] {
        let reply = try run("get", target: handle(pane))
        return try XCTUnwrap(reply.data?["pane"]?["tabList"]?.arrayValue, "get did not return a tabList")
    }

    // MARK: The happy path: open -> navigate -> reload -> close

    /// Run all four commands back to back, verifying each step through the `tabList` on the
    /// `state` side rather than the implementation's own `pane.tabs` — **what an agent can see is
    /// what counts**
    func testOpenNavigateReloadAndCloseATab() throws {
        let browser = try newBrowser()
        XCTAssertEqual(browser.tabs.count, 1)

        // 1. open: one more tab, and it becomes the active tab right away
        let opened = try harness.mutation(try run("browser.open", target: handle(browser),
                                                  args: ["url": .string("http://127.0.0.1:1/b")]))
        XCTAssertEqual(opened["applied"]?.boolValue, true)
        XCTAssertEqual(browser.tabs.count, 2)
        XCTAssertEqual(browser.activeTabIndex, 1, "--activate defaults to on")
        XCTAssertEqual(opened["pane"]?["tabs"]?.intValue, 2)
        XCTAssertEqual(try tabs(of: browser).count, 2)

        // --activate off: opened, but not switched to
        _ = try harness.mutation(try run("browser.open", target: handle(browser),
                                         args: ["url": .string("http://127.0.0.1:1/c"),
                                                "activate": .string("off")]))
        XCTAssertEqual(browser.tabs.count, 3)
        XCTAssertEqual(browser.activeTabIndex, 1, "--activate off must not touch the active tab")

        // 2. goto: change the URL of the active tab
        let moved = try harness.mutation(try run("browser.goto", target: handle(browser),
                                                 args: ["url": .string("http://127.0.0.1:1/d")]))
        XCTAssertEqual(moved["changed"]?.boolValue, true)
        XCTAssertEqual(browser.tabs[1].effectiveURL?.absoluteString, "http://127.0.0.1:1/d")

        // 3. goto is an **absolute set**: the same URL again does nothing, and --fail-if-noop
        // exits 7
        let again = try harness.mutation(try run("browser.goto", target: handle(browser),
                                                 args: ["url": .string("http://127.0.0.1:1/d")]))
        XCTAssertEqual(again["changed"]?.boolValue, false)
        XCTAssertEqual(again["applied"]?.boolValue, false)
        let noop = try run("browser.goto", target: handle(browser),
                           args: ["url": .string("http://127.0.0.1:1/d"),
                                  ControlCommandTable.Flag.failIfNoop: .bool(true)])
        XCTAssertFalse(noop.ok)
        XCTAssertEqual(noop.error?.code, ControlErrorCode.noop.rawValue)
        XCTAssertEqual(noop.error?.exit, ControlExit.noop.rawValue)

        // 4. reload always has work to do ("reload" is its entire point), --hard included
        for hard in [false, true] {
            let reloaded = try harness.mutation(try run("browser.reload", target: handle(browser),
                                                        args: ["hard": .bool(hard)]))
            XCTAssertEqual(reloaded["changed"]?.boolValue, true, "hard=\(hard)")
            XCTAssertEqual(reloaded["applied"]?.boolValue, true, "hard=\(hard)")
        }

        // 5. close: one tab goes away, the pane stays
        let closed = try harness.mutation(try run("browser.close", target: handle(browser),
                                                  args: ["tab": .string("2")]))
        XCTAssertEqual(closed["applied"]?.boolValue, true)
        XCTAssertEqual(browser.tabs.count, 2)
        XCTAssertTrue(try harness.controller.model.allPanes.contains { $0 === browser },
                      "with other tabs still open, close must never take the pane down with it")
    }

    /// `--dry-run` reports a diff but **does not touch a single tab**
    func testDryRunTouchesNothing() throws {
        let browser = try newBrowser()
        let cases: [(String, [String: JSONValue])] = [
            ("browser.open", ["url": .string("http://127.0.0.1:1/x")]),
            ("browser.close", [:]),
            ("browser.goto", ["url": .string("http://127.0.0.1:1/y")]),
        ]
        for (cmd, args) in cases {
            var withFlag = args
            withFlag[ControlCommandTable.Flag.dryRun] = .bool(true)
            let payload = try harness.mutation(try run(cmd, target: handle(browser), args: withFlag))
            XCTAssertEqual(payload["dryRun"]?.boolValue, true, cmd)
            XCTAssertEqual(payload["applied"]?.boolValue, false, cmd)
            XCTAssertFalse((payload["changes"]?.arrayValue ?? []).isEmpty, "\(cmd) has to spell out what it would change")
        }
        XCTAssertEqual(browser.tabs.count, 1, "the tab count must not move by one after a dry run")
        XCTAssertEqual(browser.tabs[0].effectiveURL?.absoluteString, "http://127.0.0.1:1/a")
    }

    // MARK: Addressing

    /// Index / id / `@active` / `@last` all land on the same tab, while out-of-range and
    /// unrecognized spellings **produce an explicit error** rather than picking the nearest tab
    func testTabAddressingResolvesEveryFormAndRefusesTheRest() throws {
        let browser = try newBrowser()
        _ = try run("browser.open", target: handle(browser),
                    args: ["url": .string("http://127.0.0.1:1/b")])
        _ = try run("browser.open", target: handle(browser),
                    args: ["url": .string("http://127.0.0.1:1/c")])
        XCTAssertEqual(browser.tabs.count, 3)
        XCTAssertEqual(browser.activeTabIndex, 2)

        let second = browser.tabs[1]
        let prefix = String(second.id.uuidString.replacingOccurrences(of: "-", with: "").prefix(8))

        // The index (1-based) and the id prefix name the same tab
        for (ref, path) in [("2", "by-index"), ("#\(prefix)", "by-id")] {
            _ = try harness.mutation(try run("browser.goto", target: handle(browser),
                                             args: ["tab": .string(ref),
                                                    "url": .string("http://127.0.0.1:1/\(path)")]))
            XCTAssertEqual(second.effectiveURL?.absoluteString, "http://127.0.0.1:1/\(path)",
                           "--tab \(ref) did not land on tab 2")
        }
        // @active / @last
        _ = try harness.mutation(try run("browser.goto", target: handle(browser),
                                         args: ["tab": .string("@active"),
                                                "url": .string("http://127.0.0.1:1/active")]))
        XCTAssertEqual(browser.tabs[2].effectiveURL?.absoluteString, "http://127.0.0.1:1/active")
        _ = try harness.mutation(try run("browser.goto", target: handle(browser),
                                         args: ["tab": .string("@last"),
                                                "url": .string("http://127.0.0.1:1/last")]))
        XCTAssertEqual(browser.tabs[2].effectiveURL?.absoluteString, "http://127.0.0.1:1/last")

        // Out of range: say how many there actually are, and point at how to look
        let outOfRange = try run("browser.reload", target: handle(browser), args: ["tab": .string("9")])
        XCTAssertFalse(outOfRange.ok)
        XCTAssertEqual(outOfRange.error?.code, ControlErrorCode.notFound.rawValue)
        XCTAssertTrue(outOfRange.error?.message.contains("3") ?? false,
                      "out of range has to report the real tab count: \(String(describing: outOfRange.error?.message))")
        XCTAssertTrue(outOfRange.error?.hint?.contains("tabList") ?? false)

        // Unrecognized spellings and too-short id prefixes: bad_request (never quietly treated
        // as @active)
        for bad in ["banana", "0", "#ab"] {
            let reply = try run("browser.reload", target: handle(browser), args: ["tab": .string(bad)])
            XCTAssertFalse(reply.ok, "--tab \(bad) must not be accepted")
            XCTAssertEqual(reply.error?.code, ControlErrorCode.badRequest.rawValue, bad)
        }
        // An id that matches no tab
        let missing = try run("browser.reload", target: handle(browser), args: ["tab": .string("#deadbeef")])
        XCTAssertFalse(missing.ok)
        XCTAssertEqual(missing.error?.code, ControlErrorCode.notFound.rawValue)

        // A browser-group command aimed at a terminal pane: wrong_pane_kind, not a bland
        // "nothing happened"
        let terminal = try harness.newTerminal()
        let wrongKind = try run("browser.reload", target: handle(terminal))
        XCTAssertFalse(wrongKind.ok)
        XCTAssertEqual(wrongKind.error?.code, ControlErrorCode.wrongPaneKind.rawValue)
    }

    /// The `index` / `id` in `tabList` and the spellings `--tab` accepts are **the same
    /// vocabulary**: whatever an agent reads it can address with, no translation step in between
    func testTabListIsWhatTabAddresses() throws {
        let browser = try newBrowser()
        _ = try run("browser.open", target: handle(browser),
                    args: ["url": .string("http://127.0.0.1:1/b")])
        let list = try tabs(of: browser)
        XCTAssertEqual(list.count, 2)
        XCTAssertEqual(list[0]["index"]?.intValue, 1)
        XCTAssertEqual(list[1]["index"]?.intValue, 2)
        XCTAssertEqual(list[0]["active"]?.boolValue, false)
        XCTAssertEqual(list[1]["active"]?.boolValue, true, "a freshly opened tab is the active tab")
        XCTAssertEqual(list[1]["url"]?.stringValue, "http://127.0.0.1:1/b")

        let id = try XCTUnwrap(list[0]["id"]?.stringValue)
        let prefix = String(id.replacingOccurrences(of: "-", with: "").prefix(6))
        _ = try harness.mutation(try run("browser.goto", target: handle(browser),
                                         args: ["tab": .string("#\(prefix)"),
                                                "url": .string("http://127.0.0.1:1/from-list")]))
        XCTAssertEqual(browser.tabs[0].effectiveURL?.absoluteString, "http://127.0.0.1:1/from-list")

        // The pane record in state carries the same list (`tabs` is still that integer, the shape
        // did not change)
        let state = try harness.run("state", token: ControlEnvironment.token)
        let pane = try XCTUnwrap(state.data?["panes"]?.arrayValue?
            .first { $0["handle"]?.stringValue == handle(browser) }?.objectValue)
        XCTAssertEqual(pane["tabs"]?.intValue, 2)
        XCTAssertEqual(pane["tabList"]?.arrayValue?.count, 2)
    }

    /// **The redaction rule does not bend an inch.** A tokenless caller can read index / id /
    /// active (it needs them to address a tab) and no title or URL at all — and the diff in the
    /// mutation envelope is redacted the same way
    func testPerTabDetailIsRedactedForATokenlessCaller() throws {
        let browser = try newBrowser()
        _ = try run("browser.open", target: handle(browser),
                    args: ["url": .string("http://127.0.0.1:1/secret")])

        let reply = try harness.run("get", target: handle(browser))   // no token
        let pane = try XCTUnwrap(reply.data?["pane"]?.objectValue)
        XCTAssertEqual(pane["redacted"]?.boolValue, true)
        XCTAssertEqual(pane["url"]?.stringValue, ControlStateEncoder.redacted)
        let list = try XCTUnwrap(pane["tabList"]?.arrayValue)
        XCTAssertEqual(list.count, 2, "that tabs exist and how many there are was always public "
                       + "(`tabs` has been there all along)")
        for tab in list {
            XCTAssertEqual(tab["url"]?.stringValue, ControlStateEncoder.redacted)
            XCTAssertEqual(tab["title"]?.stringValue, ControlStateEncoder.redacted)
            XCTAssertNotNil(tab["index"]?.intValue, "an index leaks nothing and addressing needs it")
            XCTAssertNotNil(tab["id"]?.stringValue)
        }
        let encoded = String(decoding: try ControlJSON.encoder.encode(pane), as: UTF8.self)
        XCTAssertFalse(encoded.contains("secret"), "the URL must not appear anywhere in the pane record: \(encoded)")

        // The mutation envelope: `from` is the URL the page was on before the command ran —
        // leaking it is no different from reading state outright
        let moved = try harness.mutation(try harness.run(
            "browser.goto", target: handle(browser),
            args: ["url": .string("http://127.0.0.1:1/next")]))
        let changes = try XCTUnwrap(moved["changes"]?.arrayValue)
        XCTAssertEqual(changes.first?["from"]?.stringValue, ControlStateEncoder.redacted)
        XCTAssertEqual(changes.first?["to"]?.stringValue, ControlStateEncoder.redacted,
                       "even the one the caller wrote itself gets redacted -- otherwise the diff becomes a probe")
    }

    // MARK: Closing the last tab = closing the pane (word for word what Cmd+W does)

    /// **The same act through two entry points has to end in the same place.**
    /// First establish the semantics through the UI path (`perform(.closePane)`): with several tabs
    /// it closes a tab, on the last tab it closes the pane. Then walk the command-line path and the
    /// result has to be identical
    func testClosingTheLastTabClosesThePaneExactlyLikeTheUI() throws {
        let controller = try harness.controller

        // 1. The UI path: two tabs -> Cmd+W closes only the tab
        let viaUI = try newBrowser()
        _ = try run("browser.open", target: handle(viaUI), args: ["url": .string("http://127.0.0.1:1/b")])
        XCTAssertEqual(viaUI.tabs.count, 2)
        controller.requestFocus(to: viaUI)
        harness.spin(0.2)
        controller.perform(.closePane)
        harness.spin(0.2)
        XCTAssertEqual(viaUI.tabs.count, 1, "precondition: with several tabs, Cmd+W closes the tab")
        XCTAssertTrue(controller.model.allPanes.contains { $0 === viaUI })
        // The last tab -> Cmd+W closes the whole pane
        controller.perform(.closePane)
        harness.spin(0.4)
        controller.flushPendingCloses()
        XCTAssertFalse(controller.model.allPanes.contains { $0 === viaUI },
                       "precondition: on the last tab, Cmd+W closes the whole pane")

        // 2. The command-line path: the same two steps, the same result
        let viaCLI = try newBrowser()
        _ = try run("browser.open", target: handle(viaCLI), args: ["url": .string("http://127.0.0.1:1/b")])
        XCTAssertEqual(viaCLI.tabs.count, 2)
        _ = try harness.mutation(try run("browser.close", target: handle(viaCLI)))
        XCTAssertEqual(viaCLI.tabs.count, 1)
        XCTAssertTrue(controller.model.allPanes.contains { $0 === viaCLI })

        let last = try harness.mutation(try run("browser.close", target: handle(viaCLI),
                                                args: ["force": .bool(true)]))
        harness.spin(0.4)
        controller.flushPendingCloses()
        XCTAssertEqual(last["applied"]?.boolValue, true)
        XCTAssertFalse(controller.model.allPanes.contains { $0 === viaCLI },
                       "the last tab: the command line has to close the whole pane too")
        XCTAssertTrue(last["note"]?.stringValue?.contains("last tab") ?? false,
                      "it has to say outright that the pane went with it: \(String(describing: last["note"]))")
    }

    /// `--others` always keeps the tab `--tab` points at, which is why it **can never close the
    /// pane**; with a single tab left it is a no-op
    func testCloseOthersKeepsExactlyTheAddressedTab() throws {
        let browser = try newBrowser()
        for path in ["b", "c", "d"] {
            _ = try run("browser.open", target: handle(browser),
                        args: ["url": .string("http://127.0.0.1:1/\(path)")])
        }
        XCTAssertEqual(browser.tabs.count, 4)
        let keep = browser.tabs[1]

        let payload = try harness.mutation(try run("browser.close", target: handle(browser),
                                                   args: ["tab": .string("2"), "others": .bool(true)]))
        XCTAssertEqual(payload["applied"]?.boolValue, true)
        XCTAssertEqual(browser.tabs.count, 1)
        XCTAssertTrue(browser.tabs[0] === keep, "the tab left standing has to be the one --tab named")
        XCTAssertTrue(try harness.controller.model.allPanes.contains { $0 === browser },
                      "--others always leaves one tab, so it never closes the pane")

        // One tab left: a no-op (not "close that one too")
        let again = try harness.mutation(try run("browser.close", target: handle(browser),
                                                 args: ["others": .bool(true)]))
        XCTAssertEqual(again["changed"]?.boolValue, false)
        XCTAssertEqual(browser.tabs.count, 1)
    }

    /// Destructive classification, plus an alert that names **the specific thing about to happen**
    /// (closing a tab, or closing the pane along with it)
    func testCloseIsDestructiveAndTheDialogSaysWhatWillHappen() throws {
        pinUILanguage(.en)
        let spec = try XCTUnwrap(ControlCommandTable.command("browser.close"))
        XCTAssertEqual(spec.cls, .destructive, "closing a tab destroys the user's work (page state, an unsubmitted form)")
        for other in ControlCommandTable.commands(inGroup: "browser") where other.verb != "close" {
            XCTAssertEqual(other.cls, .mutate, "\(other.cli) should not be destructive")
        }

        let browser = try newBrowser()
        _ = try run("browser.open", target: handle(browser), args: ["url": .string("http://127.0.0.1:1/b")])
        var seen: [ControlConsent.Request] = []
        harness.consent.decisionStub = { request, reply in
            seen.append(request)
            reply(.allow)
        }
        _ = try run("browser.close", target: handle(browser))
        XCTAssertTrue(seen.first?.summary.contains("1 tab left") ?? false,
                      "several tabs: the alert has to say only one tab closes -- "
                      + "\(String(describing: seen.first?.summary))")

        // **Start over every time**: a destructive command caches one grant per (pid, class), so
        // without clearing it the second call sails straight through and this case never gets to
        // see what the alert said
        seen.removeAll()
        harness.consent.reset()
        _ = try run("browser.close", target: handle(browser), args: ["force": .bool(true)])
        harness.spin(0.3)
        XCTAssertTrue(seen.first?.summary.contains("the whole pane closes with it") ?? false,
                      "the last tab: the alert has to spell out that the pane goes with it -- "
                      + "\(String(describing: seen.first?.summary))")

        // The user denies = nothing happens
        let browser2 = try newBrowser()
        harness.consent.reset()
        harness.consent.decisionStub = { _, reply in reply(.deny) }
        let denied = try run("browser.close", target: handle(browser2))
        XCTAssertFalse(denied.ok)
        XCTAssertEqual(denied.error?.code, ControlErrorCode.denied.rawValue)
        XCTAssertEqual(browser2.tabs.count, 1)
        XCTAssertTrue(try harness.controller.model.allPanes.contains { $0 === browser2 })
    }

    // MARK: URLs and titles never reach the system log

    /// **Redaction must not be routed around by a log that sticks around.**
    /// `ControlActivityLog` mirrors every mutation into OSLog (privacy: .public), and that log
    /// lands in /var/db/diagnostics: it outlives the app and sysdiagnose packages it up. A caller
    /// with a token — which is the user's own everyday path — sees the real URL, so it is exactly
    /// that path which would write the URL out. The in-app copy still records everything (the only
    /// person reading it is the user sitting at this machine)
    func testBrowserURLsAndTitlesNeverReachTheSystemLog() throws {
        let browser = try newBrowser()
        let secret = "http://127.0.0.1:1/leaky-\(UUID().uuidString.prefix(6))"
        ControlActivityLog.shared.clear()
        _ = try run("browser.goto", target: handle(browser), args: ["url": .string(secret)])
        let entry = try XCTUnwrap(ControlActivityLog.shared.recent(1).first)
        XCTAssertTrue(entry.line.contains(secret), "the in-app panel still records it in full: \(entry.line)")
        XCTAssertFalse(entry.logLine.contains(secret), "the OSLog copy may not carry the URL: \(entry.logLine)")
        XCTAssertTrue(entry.logLine.contains(".url"),
                      "the path still has to be there, otherwise the log entry was pointless")

        // A dry run is no different (`--dry-run` is still logged: a command that changes nothing
        // must not become the hole through which things get written)
        ControlActivityLog.shared.clear()
        _ = try run("browser.goto", target: handle(browser),
                    args: ["url": .string(secret + "/dry"),
                           ControlCommandTable.Flag.dryRun: .bool(true)])
        let dry = try XCTUnwrap(ControlActivityLog.shared.recent(1).first)
        XCTAssertFalse(dry.logLine.contains(secret), "a dry run even less so: \(dry.logLine)")

        // The `from` of reload is the current URL too; the `from` of close is the tab title
        // (falling back to the host name when the title is empty)
        ControlActivityLog.shared.clear()
        _ = try run("browser.reload", target: handle(browser))
        XCTAssertFalse(try XCTUnwrap(ControlActivityLog.shared.recent(1).first).logLine.contains(secret))

        _ = try run("browser.open", target: handle(browser), args: ["url": .string(secret + "/2")])
        ControlActivityLog.shared.clear()
        harness.consent.decisionStub = { _, reply in reply(.allow) }
        _ = try run("browser.close", target: handle(browser), args: ["tab": .string("2")])
        let closed = try XCTUnwrap(ControlActivityLog.shared.recent(1).first)
        XCTAssertFalse(closed.logLine.contains("127.0.0.1"),
                       "titles and host names stay out of the system log as well: \(closed.logLine)")
    }

    // MARK: goto must not become a probe for the current URL

    /// A caller that cannot read the URL (no token) must not work out where a tab is parked from
    /// "did anything change". Regression: `goto` used to compare the caller's URL against the tab's
    /// live URL, which turned a `--dry-run --fail-if-noop` goto into a yes/no oracle — while the
    /// same caller reading `state` gets `<redacted>`
    func testGotoNeverConfirmsACurrentURLToACallerThatCannotReadIt() throws {
        let browser = try newBrowser(url: "http://127.0.0.1:1/private")
        harness.spin(0.3)
        let current = try XCTUnwrap(browser.tabs[0].effectiveURL?.absoluteString)

        // Without a token: guessing right must not be confirmed as a hit
        let probe = try harness.run("browser.goto", target: handle(browser),
                                    args: ["url": .string(current),
                                           ControlCommandTable.Flag.dryRun: .bool(true),
                                           ControlCommandTable.Flag.failIfNoop: .bool(true)])
        XCTAssertTrue(probe.ok,
                      "guessing the current URL must not turn into exit code 7: \(String(describing: probe.error))")
        let payload = try harness.mutation(probe)
        XCTAssertEqual(payload["changed"]?.boolValue, true,
                       "for a caller that cannot read the URL, goto always counts as a change")
        let changes = try XCTUnwrap(payload["changes"]?.arrayValue)
        XCTAssertEqual(changes.first?["from"]?.stringValue, ControlStateEncoder.redacted)
        XCTAssertEqual(changes.first?["to"]?.stringValue, ControlStateEncoder.redacted)

        // A miss looks exactly the same (the channel is only really closed once the two are
        // indistinguishable)
        let miss = try harness.mutation(try harness.run(
            "browser.goto", target: handle(browser),
            args: ["url": .string("http://127.0.0.1:1/nope"),
                   ControlCommandTable.Flag.dryRun: .bool(true),
                   ControlCommandTable.Flag.failIfNoop: .bool(true)]))
        XCTAssertEqual(miss["changed"]?.boolValue, true)
        XCTAssertEqual(miss["changes"]?.arrayValue?.count, changes.count)

        // For a caller with a token it stays an absolute set: already there means a no-op
        let noop = try run("browser.goto", target: handle(browser),
                           args: ["url": .string(current),
                                  ControlCommandTable.Flag.failIfNoop: .bool(true)])
        XCTAssertFalse(noop.ok, "a caller that can read the URL still gets idempotence")
        XCTAssertEqual(noop.error?.code, ControlErrorCode.noop.rawValue)
    }

    // MARK: The trailing slash people leave off

    /// `browser goto --url http://127.0.0.1:1` aimed at a tab that is **already sitting there** is
    /// a no-op. The URL WebKit settles on carries the normalized path (`...:1/`), and nobody types
    /// it that way — compare literally and the most common spelling (`http://localhost:3000`)
    /// always reports "changed", which voids the absolute-set promise on the spot and reloads the
    /// page for nothing
    func testGotoIsIdempotentAcrossAnOmittedTrailingSlash() throws {
        let browser = try newBrowser(url: "http://127.0.0.1:1/")
        harness.spin(0.3)
        XCTAssertEqual(browser.tabs[0].effectiveURL?.absoluteString, "http://127.0.0.1:1/",
                       "precondition: the tab is parked on the one with the slash")

        let noop = try run("browser.goto", target: handle(browser),
                           args: ["url": .string("http://127.0.0.1:1"),
                                  ControlCommandTable.Flag.failIfNoop: .bool(true)])
        XCTAssertFalse(noop.ok, "leaving the slash off is the same URL and must not count as a change")
        XCTAssertEqual(noop.error?.code, ControlErrorCode.noop.rawValue)

        // An actual navigation still reports "changed" (do not over-normalize)
        let changed = try harness.mutation(try run("browser.goto", target: handle(browser),
                                                   args: ["url": .string("http://127.0.0.1:1/b")]))
        XCTAssertEqual(changed["changed"]?.boolValue, true)
    }
}
