import Darwin
import XCTest
@testable import QuickTerm

/// Socket lifecycle plus one end-to-end round trip.
/// **Never touches the socket of the QuickTerm the user is actually running**: every case injects
/// a path under a temp directory, and the test host's own `AppSession` never binds at all because
/// of `AppDelegate.isRunningTests` (the same policy as `SessionStore.writesAllowed`).
@MainActor
final class ControlServerTests: XCTestCase {
    private var paths: [String] = []

    private func tempSocketPath() throws -> String {
        let path = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("qtc-\(UUID().uuidString.prefix(8)).sock")
        try XCTSkipUnless(ControlPaths.fits(path),
                          "temp directory is too long to fit in the 104 bytes of sun_path "
                          + "(these cases will not grab the default $TMPDIR fallback path)")
        paths.append(path)
        return path
    }

    override func tearDown() {
        for path in paths { unlink(path) }
        paths.removeAll()
        super.tearDown()
    }

    private func spin(_ seconds: TimeInterval = 0.2) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private func makeServer(at path: String, mode: String = "ask") throws -> ControlServer {
        let app = try XCTUnwrap(NSApp.delegate as? AppDelegate)
        let consent = ControlConsent(screens: app.screens)
        let server = ControlServer(screens: app.screens, consent: consent, socketPath: path)
        var config = ControlCommandRunner.Config()
        config.mode = mode
        server.apply(config)
        XCTAssertTrue(server.isListening, "the server should already be listening on \(path)")
        return server
    }

    // MARK: Binding and permissions

    func testBindsWithTightPermissions() throws {
        let path = try tempSocketPath()
        let server = try makeServer(at: path)
        defer { server.stop() }

        var st = stat()
        XCTAssertEqual(lstat(path, &st), 0)
        XCTAssertEqual(st.st_mode & S_IFMT, S_IFSOCK)
        XCTAssertEqual(st.st_mode & 0o777, 0o600, "the socket has to be 0600")
    }

    func testDirectoryIsForcedTo0700() throws {
        let directory = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("qtc-dir-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o755])
        defer { try? FileManager.default.removeItem(atPath: directory) }
        try ControlSocket.prepareDirectory(directory)
        var st = stat()
        XCTAssertEqual(lstat(directory, &st), 0)
        XCTAssertEqual(st.st_mode & 0o777, 0o700, "the parent directory has to be tightened to 0700")
    }

    func testRefusesToBindThroughASymlink() throws {
        let real = try tempSocketPath()
        let link = real + ".link"
        paths.append(link)
        FileManager.default.createFile(atPath: real, contents: Data())
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: real)
        XCTAssertThrowsError(try ControlSocket.reclaimStaleSocket(at: link),
                             "a symlink for a path means somebody else gets to pick where we write")
    }

    func testRefusesToDeleteANonSocketFile() throws {
        let path = try tempSocketPath()
        FileManager.default.createFile(atPath: path, contents: Data("not a socket".utf8))
        XCTAssertThrowsError(try ControlSocket.reclaimStaleSocket(at: path),
                             "never delete a regular file on the user's behalf")
    }

    func testReclaimsAStaleSocket() throws {
        let path = try tempSocketPath()
        // Bind and then close the fd outright: the file is still there, but nobody is listening
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = try ControlSocket.sockaddrUn(path)
        _ = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        Darwin.close(fd)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path), "precondition: the stale socket file is still there")

        let server = try makeServer(at: path)   // coming up at all means the stale file was reclaimed
        defer { server.stop() }
    }

    func testRefusesToStealALiveSocket() throws {
        let path = try tempSocketPath()
        let server = try makeServer(at: path)
        defer { server.stop() }
        XCTAssertThrowsError(try ControlSocket.reclaimStaleSocket(at: path),
                             "do not steal it when a real instance is listening") { error in
            guard case ControlSocket.SocketError.alreadyListening = error else {
                return XCTFail("expected alreadyListening, got \(error)")
            }
        }
    }

    func testExplicitPathNeverFallsBackToTheSharedTmpSocket() {
        // An explicit path that is too long has to error out; it must never quietly switch to
        // $TMPDIR/quickterm.sock — that is the spot the QuickTerm the user is running may be
        // holding
        let tooLong = "/tmp/" + String(repeating: "x", count: 120) + ".sock"
        XCTAssertThrowsError(try ControlSocket.prepare(preferred: tooLong, allowFallback: false))
        XCTAssertNoThrow(try ControlSocket.prepare(preferred: tooLong, allowFallback: true))
    }

    func testStopUnlinksTheSocket() throws {
        let path = try tempSocketPath()
        let server = try makeServer(at: path)
        server.stop()
        XCTAssertFalse(server.isListening)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path), "no stale socket left behind after a stop")
    }

    // MARK: Peer identity

    func testOnlySameUIDIsAccepted() {
        let mine = ControlSocket.Peer(fd: -1, uid: getuid(), pid: 1, processName: "self")
        let other = ControlSocket.Peer(fd: -1, uid: getuid() &+ 1, pid: 2, processName: "someone")
        XCTAssertTrue(ControlSocket.accepts(mine))
        XCTAssertFalse(ControlSocket.accepts(other),
                       "a different uid has to be refused outright -- this is the one identity "
                       + "check nothing can bypass")
    }

    func testPeerIdentityReportsTheRealProcess() throws {
        let path = try tempSocketPath()
        let server = try makeServer(at: path)
        defer { server.stop() }
        let client = try ControlClient.connect(candidates: [path])
        defer { client.close() }
        spin(0.2)
        XCTAssertEqual(ControlSocket.processName(for: getpid()).isEmpty, false)
    }

    /// The consent alert's **default button has to be the deny one**.
    /// This is a regression test for a real incident: the default button used to be allow, and a
    /// single Return that landed on the window during a smoke test approved a destructive command
    /// outright (the log was left holding `Control consent result: allow`, with the user
    /// never having read the alert at all). The default answer of a safety gate can only be no
    func testConsentAlertDefaultsToDeny() {
        // The alert text follows the UI language; this case pins it so it cannot go red on a
        // machine whose system language is English.
        let language = Localization.shared.language
        defer { Localization.shared.setLanguage(language) }
        Localization.shared.setLanguage(.zh)
        let alert = ControlConsent.makeAlert(.init(peerName: "node", peerPID: 4821, cls: .destructive,
                                                   summary: "close pane t7", originPane: "t3",
                                                   tokenPresent: true))
        XCTAssertEqual(alert.buttons.first?.title, "拒绝",
                       "first button = default button, and it has to be the deny one")
        XCTAssertEqual(alert.buttons.first?.keyEquivalent, "\r", "Return has to land on deny")
        XCTAssertEqual(alert.buttons.last?.title, "允许")
        XCTAssertEqual(alert.buttons.last?.keyEquivalent, "",
                       "allow may never carry a key equivalent: it has to be clicked")
        XCTAssertEqual(ControlConsent.allowResponse, .alertSecondButtonReturn,
                       "the mapping has to follow the button order, otherwise Return turns into allow")
        XCTAssertTrue(alert.informativeText.contains("pid 4821"),
                      "the alert has to state the real identity the kernel handed us")
        XCTAssertTrue(alert.informativeText.contains("自称来自 pane t3"),
                      "the origin is self-reported, so the wording has to say so -- the Chinese UI "
                      + "string reads \"claims to come from pane t3\"")
    }

    // MARK: End to end (this doubles as the "main-thread hop" case)

    /// The socket callback runs on the io queue; the command has to be handed back to the main
    /// thread to execute. Send it to the wrong thread and the `dispatchPrecondition(.onQueue(.main))`
    /// inside `ControlCommandRunner` trips the case right there, instead of leaving behind a ghost
    /// that "occasionally crashes on a SwiftUI publish from a background thread".
    func testRequestFromBackgroundThreadIsExecutedOnMain() throws {
        let path = try tempSocketPath()
        let server = try makeServer(at: path)
        defer { server.stop() }

        let box = Box<ControlReply>()
        let done = expectation(description: "state replied")
        DispatchQueue.global().async {
            defer { done.fulfill() }
            guard let client = try? ControlClient.connect(candidates: [path]) else { return }
            defer { client.close() }
            box.value = try? client.send(ControlRequest(id: "1", cmd: "state"))
        }
        // The main thread has to keep turning: the command is scheduled onto exactly this run loop
        let deadline = Date().addingTimeInterval(5)
        while box.value == nil, Date() < deadline { spin(0.05) }
        wait(for: [done], timeout: 5)

        let got = try XCTUnwrap(box.value, "no reply came back")
        XCTAssertTrue(got.ok, "\(String(describing: got.error))")
        XCTAssertEqual(got.data?["schema"]?.stringValue, "quickterm.state/1")
        XCTAssertNotNil(got.resolved?.screen)
    }

    func testProtocolMismatchIsExitEight() throws {
        let path = try tempSocketPath()
        let server = try makeServer(at: path)
        defer { server.stop() }
        var request = ControlRequest(id: "1", cmd: "state")
        request.v = ControlProtocol.version + 99
        let reply = try roundTrip(request, at: path)
        XCTAssertFalse(reply.ok)
        XCTAssertEqual(reply.error?.code, ControlErrorCode.protocolMismatch.rawValue)
        XCTAssertEqual(reply.error?.exit, ControlExit.protocolMismatch.rawValue)
        XCTAssertTrue(reply.error?.message.contains("v\(ControlProtocol.version)") ?? false,
                      "a version mismatch has to report both sides' versions")
    }

    func testInteractiveActionIsRefusedOverTheSocket() throws {
        let path = try tempSocketPath()
        let server = try makeServer(at: path)
        defer { server.stop() }
        for action in ControlCommandTable.interactiveActions {
            let reply = try roundTrip(ControlRequest(id: "1", cmd: "action",
                                                     args: ["name": .string(action.rawValue)]), at: path)
            XCTAssertFalse(reply.ok, "\(action.rawValue) should not have been executed")
            XCTAssertEqual(reply.error?.code, ControlErrorCode.interactiveAction.rawValue, action.rawValue)
            XCTAssertNotNil(reply.error?.hint, "a refusal has to name a concrete place to go")
        }
    }

    func testDestructiveActionNeedsConsentAndIsRefusedWhenDenied() throws {
        let path = try tempSocketPath()
        let app = try XCTUnwrap(NSApp.delegate as? AppDelegate)
        let consent = ControlConsent(screens: app.screens)
        consent.decisionStub = { _, reply in reply(.deny) }
        let server = ControlServer(screens: app.screens, consent: consent, socketPath: path)
        server.apply(ControlCommandRunner.Config())
        defer { server.stop() }

        let reply = try roundTrip(ControlRequest(id: "1", cmd: "action",
                                                 args: ["name": .string("close-pane")]), at: path)
        XCTAssertFalse(reply.ok)
        XCTAssertEqual(reply.error?.code, ControlErrorCode.denied.rawValue)
        XCTAssertEqual(reply.error?.exit, ControlExit.denied.rawValue)
    }

    func testConsentIsCachedPerPeerAndClass() throws {
        let app = try XCTUnwrap(NSApp.delegate as? AppDelegate)
        let consent = ControlConsent(screens: app.screens)
        var asked = 0
        consent.decisionStub = { _, reply in
            asked += 1
            reply(.allow)
        }
        let request = ControlConsent.Request(peerName: "node", peerPID: 4821, cls: .destructive,
                                             summary: "close pane", originPane: "t3", tokenPresent: true)
        for _ in 0..<3 {
            consent.evaluate(request) { XCTAssertEqual($0, .allow) }
        }
        XCTAssertEqual(asked, 1, "ask once per (pid, class) -- agents send commands in batches, "
                       + "and asking for every single one is the same as not asking")
        consent.evaluate(ControlConsent.Request(peerName: "node", peerPID: 9999, cls: .destructive,
                                                summary: "close pane", originPane: nil,
                                                tokenPresent: false)) { _ in }
        XCTAssertEqual(asked, 2, "a different process has to be asked again")
    }

    func testTokenNeverSkipsConsent() throws {
        // The token is proof of origin, not a permission boundary: even the correct token still
        // gets asked
        let app = try XCTUnwrap(NSApp.delegate as? AppDelegate)
        let consent = ControlConsent(screens: app.screens)
        var asked = 0
        consent.decisionStub = { request, reply in
            asked += 1
            XCTAssertTrue(request.tokenPresent)
            reply(.allow)
        }
        consent.evaluate(.init(peerName: "codex", peerPID: 12, cls: .destructive,
                               summary: "close pane", originPane: "t1", tokenPresent: true)) { _ in }
        XCTAssertEqual(asked, 1)
    }

    func testReadOnlyModeRefusesMutations() throws {
        let path = try tempSocketPath()
        let server = try makeServer(at: path, mode: "readonly")
        defer { server.stop() }
        let read = try roundTrip(ControlRequest(id: "1", cmd: "state"), at: path)
        XCTAssertTrue(read.ok, "reads still go through in readonly mode")
        let write = try roundTrip(ControlRequest(id: "2", cmd: "action",
                                                 args: ["name": .string("new-terminal")]), at: path)
        XCTAssertFalse(write.ok)
        XCTAssertEqual(write.error?.code, ControlErrorCode.denied.rawValue)
    }

    func testUnknownCommandAndActionListCandidates() throws {
        let path = try tempSocketPath()
        let server = try makeServer(at: path)
        defer { server.stop() }
        let unknown = try roundTrip(ControlRequest(id: "1", cmd: "frobnicate"), at: path)
        XCTAssertEqual(unknown.error?.code, ControlErrorCode.unknownCommand.rawValue)
        XCTAssertFalse(unknown.error?.candidates?.isEmpty ?? true)

        let badAction = try roundTrip(ControlRequest(id: "2", cmd: "action",
                                                     args: ["name": .string("close_pane")]), at: path)
        XCTAssertEqual(badAction.error?.code, ControlErrorCode.unknownAction.rawValue)
        XCTAssertTrue(badAction.error?.candidates?.contains("close-pane") ?? false)
    }

    func testMalformedLineGetsAStructuredError() throws {
        let path = try tempSocketPath()
        let server = try makeServer(at: path)
        defer { server.stop() }

        let box = Box<String>()
        let done = expectation(description: "a bad line gets a structured response too")
        DispatchQueue.global().async {
            defer { done.fulfill() }
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            var addr = try? ControlSocket.sockaddrUn(path)
            guard addr != nil else { return }
            _ = withUnsafePointer(to: &addr!) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            _ = "{ this is not JSON\n".withCString { write(fd, $0, strlen($0)) }
            var buffer = [UInt8](repeating: 0, count: 4096)
            let n = read(fd, &buffer, buffer.count)
            if n > 0 { box.value = String(bytes: buffer[0..<n], encoding: .utf8) }
            Darwin.close(fd)
        }
        let deadline = Date().addingTimeInterval(5)
        while box.value == nil, Date() < deadline { spin(0.05) }
        wait(for: [done], timeout: 5)
        let got = try XCTUnwrap(box.value)
        XCTAssertTrue(got.contains("bad_request"), "got: \(got)")
    }

    // MARK: Regression cases added after the adversarial review

    /// A single line over 1 MiB **has to** get a structured error back, not just an EOF.
    /// That `send()` line used to be dead code: it queued the write onto the io queue, while the
    /// `close()` right behind it ran synchronously first and set `closed`, so by the time the
    /// write came up `guard !closed` swallowed it and the peer only ever saw "QuickTerm closed the
    /// connection before answering"
    func testOversizedLineGetsAStructuredErrorNotJustEOF() throws {
        let path = try tempSocketPath()
        let server = try makeServer(at: path)
        defer { server.stop() }

        let box = Box<String>()
        let done = expectation(description: "an oversized line gets a structured response too")
        DispatchQueue.global().async {
            defer { done.fulfill() }
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard var addr = try? ControlSocket.sockaddrUn(path) else { return }
            _ = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            // One line all the way with no newline: the framer never sees an end of line and can
            // only run into the per-line cap
            var payload = Data("{\"v\":1,\"id\":\"1\",\"cmd\":\"state\",\"target\":\"".utf8)
            payload.append(Data(repeating: UInt8(ascii: "x"), count: ControlServer.maxLineBytes + 16))
            payload.withUnsafeBytes { raw in
                var offset = 0
                guard let base = raw.baseAddress else { return }
                while offset < raw.count {
                    let n = Darwin.write(fd, base.advanced(by: offset), raw.count - offset)
                    if n > 0 { offset += n; continue }
                    if errno == EINTR { continue }
                    // The server already closed the connection: an unfinished write is fine,
                    // reading the reply back is the point
                    break
                }
            }
            var buffer = [UInt8](repeating: 0, count: 8192)
            let n = read(fd, &buffer, buffer.count)
            if n > 0 { box.value = String(bytes: buffer[0..<n], encoding: .utf8) }
            Darwin.close(fd)
        }
        let deadline = Date().addingTimeInterval(10)
        while box.value == nil, Date() < deadline { spin(0.05) }
        wait(for: [done], timeout: 10)
        let got = try XCTUnwrap(box.value,
                                "the peer got nothing but an EOF -- the promised structured "
                                + "bad_request went missing")
        XCTAssertTrue(got.contains("bad_request"), "got: \(got)")
    }

    /// What the consent gate approves is **that one specific pane**: if the target moves while the
    /// alert is up, the whole command fails busy. It used to ask with the caller's own spelling
    /// (`@focused`, or nothing at all) and resolve it only after the user answered — the user read
    /// "close the focused pane", clicked allow, and a different pane took the knife
    func testConsentPinsTheResolvedPaneSoADriftingFocusCannotRedirectIt() throws {
        let path = try tempSocketPath()
        let app = try XCTUnwrap(NSApp.delegate as? AppDelegate)
        let controller = try XCTUnwrap(app.controller)
        try XCTSkipUnless(controller.model.layouts.count >= 2, "this case needs at least two workspaces")
        controller.model.switchTo(0)
        controller.perform(.newTerminal)
        spin(0.3)
        let victim = try XCTUnwrap(controller.focusedPane)
        defer {
            controller.model.switchTo(0)
            controller.closePane(victim, confirmIfNeeded: false, animated: false)
            spin(0.2)
        }

        let consent = ControlConsent(screens: app.screens)
        var summary = ""
        consent.decisionStub = { request, reply in
            summary = request.summary
            // In the ten seconds the user spends reading the alert, something else moves the
            // focus away (Cmd+2, another mutate command that needs no confirmation, ...)
            controller.model.switchTo(1)
            reply(.allow)
        }
        let server = ControlServer(screens: app.screens, consent: consent, socketPath: path)
        server.apply(ControlCommandRunner.Config())
        defer { server.stop() }

        let reply = try roundTrip(ControlRequest(id: "1", cmd: "action",
                                                 args: ["name": .string("close-pane")]), at: path)
        XCTAssertFalse(reply.ok, "the target is no longer the pane that was confirmed, so it must not be closed anyway")
        XCTAssertEqual(reply.error?.code, ControlErrorCode.busy.rawValue)
        XCTAssertTrue(controller.model.allPanes.contains { $0 === victim }, "this run must have done nothing at all")

        // The body of the alert has to name that specific pane rather than echoing back the
        // caller's spelling
        let handle = ControlHandleRegistry.shared.handle(for: victim)
        XCTAssertTrue(summary.contains(handle), "the alert has to name \(handle), got: \(summary)")
    }

    /// While an alert is up, **every** mutating command has to wait.
    /// `isExecuting` does not cover this stretch: it is already cleared by the time `handle()` puts
    /// the question up
    func testMutationsAreRefusedWhileAConfirmationIsPending() throws {
        let path = try tempSocketPath()
        let app = try XCTUnwrap(NSApp.delegate as? AppDelegate)
        let consent = ControlConsent(screens: app.screens)
        let pending = Box<(ControlConsent.Decision) -> Void>()
        consent.decisionStub = { _, reply in pending.value = reply }   // Left hanging, never answered
        let server = ControlServer(screens: app.screens, consent: consent, socketPath: path)
        server.apply(ControlCommandRunner.Config())
        defer { server.stop() }

        let first = Box<ControlReply>()
        let firstDone = expectation(description: "the destructive command eventually returns")
        DispatchQueue.global().async {
            defer { firstDone.fulfill() }
            guard let client = try? ControlClient.connect(candidates: [path]) else { return }
            defer { client.close() }
            first.value = try? client.send(ControlRequest(id: "1", cmd: "action",
                                                          args: ["name": .string("close-pane")]))
        }
        let armed = Date().addingTimeInterval(5)
        while pending.value == nil, Date() < armed { spin(0.05) }
        XCTAssertNotNil(pending.value, "precondition: the alert is up")
        XCTAssertTrue(consent.isPrompting)

        let blocked = try roundTrip(ControlRequest(id: "2", cmd: "action",
                                                   args: ["name": .string("new-terminal")]), at: path)
        XCTAssertFalse(blocked.ok, "the user is blocked behind a dialog; do not create a pane behind their back")
        XCTAssertEqual(blocked.error?.code, ControlErrorCode.busy.rawValue)
        XCTAssertEqual(blocked.error?.exit, ControlExit.busy.rawValue)

        // Reads are never affected
        let read = try roundTrip(ControlRequest(id: "3", cmd: "state"), at: path)
        XCTAssertTrue(read.ok, "a read-class command must not be held up by a dialog")

        try XCTUnwrap(pending.value)(.deny)
        wait(for: [firstDone], timeout: 10)
        XCTAssertEqual(first.value?.error?.code, ControlErrorCode.denied.rawValue)
    }

    /// The "from pane t3" line in the alert is self-reported by the caller (the CLI copies
    /// `$QUICKTERM_PANE` straight through) and the server cannot verify a word of it. Without a
    /// token from this launch, not a word of it is shown — never present a self-reported claim as
    /// fact on the very screen where the user makes a trust decision
    func testOriginPaneClaimIsSuppressedWithoutAValidToken() throws {
        let path = try tempSocketPath()
        let app = try XCTUnwrap(NSApp.delegate as? AppDelegate)
        let controller = try XCTUnwrap(app.controller)
        controller.model.switchTo(0)
        controller.perform(.newTerminal)
        spin(0.3)
        let pane = try XCTUnwrap(controller.focusedPane)
        defer {
            controller.closePane(pane, confirmIfNeeded: false, animated: false)
            spin(0.2)
        }
        let handle = ControlHandleRegistry.shared.handle(for: pane)

        let consent = ControlConsent(screens: app.screens)
        let seen = Box<String?>()
        var asked = 0
        consent.decisionStub = { request, reply in
            asked += 1
            seen.value = .some(request.originPane)
            reply(.deny)
        }
        let server = ControlServer(screens: app.screens, consent: consent, socketPath: path)
        server.apply(ControlCommandRunner.Config())
        defer { server.stop() }

        func ask(token: String?) throws -> String? {
            seen.value = nil
            var request = ControlRequest(id: "\(asked + 1)", cmd: "action",
                                         args: ["name": .string("close-pane")])
            request.token = token
            request.origin = ControlRequestOrigin(pane: pane.id.uuidString, screen: 1,
                                                  workspace: 1, pid: 4821)
            _ = try roundTrip(request, at: path)
            return seen.value ?? nil
        }

        XCTAssertNil(try ask(token: nil),
                     "no token = not even the claim \"I come from some pane\" has evidence behind it")
        XCTAssertNil(try ask(token: "a mistyped token"),
                     "a wrong token is no different: the self-reported origin stays hidden")
        consent.reset()   // The last answer was deny, so no grant was left behind; this only clears isPrompting
        XCTAssertEqual(try ask(token: ControlEnvironment.token), handle,
                       "only a token from this launch shows the origin pane (the wording still says \"自称\", i.e. claims to be)")
    }

    // MARK: Helpers

    private func roundTrip(_ request: ControlRequest, at path: String) throws -> ControlReply {
        let box = Box<ControlReply>()
        let errorBox = Box<Error>()
        let done = expectation(description: "round trip \(request.cmd)")
        DispatchQueue.global().async {
            defer { done.fulfill() }
            do {
                let client = try ControlClient.connect(candidates: [path])
                defer { client.close() }
                box.value = try client.send(request)
            } catch { errorBox.value = error }
        }
        let deadline = Date().addingTimeInterval(5)
        while box.value == nil, errorBox.value == nil, Date() < deadline { spin(0.05) }
        wait(for: [done], timeout: 5)
        if let failure = errorBox.value { throw failure }
        return try XCTUnwrap(box.value)
    }
}

/// Minimal container for passing one value across threads (in these cases the main thread turns
/// the run loop while a background thread writes the result)
final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: T?
    var value: T? {
        get { lock.lock(); defer { lock.unlock() }; return storage }
        set { lock.lock(); defer { lock.unlock() }; storage = newValue }
    }
}
