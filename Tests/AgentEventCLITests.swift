import Darwin
import XCTest
@testable import QuickTerm

/// **The `quickterm agent-event` binary itself** (plan §2.2, §4.1): the one command that must
/// never fail, never print and never block the agent that ran it.
///
/// Everything else in this package drives the runner in-process; this file spawns the **real CLI**
/// out of `QuickTerm.app/Contents/SharedSupport/quickterm`, because the promises being tested are
/// promises about a process: its exit status, its two output streams, and how much of stdin it is
/// willing to read. None of them can be observed from inside the app.
///
/// **It never reaches the QuickTerm the developer is running.** Every case strips `QUICKTERM_*`
/// out of the inherited environment (a test run started from inside a QuickTerm pane inherits the
/// real socket) and passes `--socket` explicitly — either a path with nobody on it, or a server
/// this case bound in a temp directory itself.
@MainActor
final class AgentEventCLITests: XCTestCase {
    private var harness: ControlHarness!
    private var socketPaths: [String] = []
    private var scratch: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        harness = try ControlHarness()
        NoticeCenter.shared.attach(locator: NoticeLocator(screens: harness.app.screens))
        NoticeCenter.shared.resetForTesting()
        AgentRegistry.shared.attach(locator: NoticeLocator(screens: harness.app.screens),
                                    userRuleDirectory: nil)
        if AgentRegistry.shared.rules["claude-code"] == nil {
            AgentRegistry.shared.reloadRulesForTesting(AgentRulesLoader.load(userDirectory: nil).rules)
        }
        AgentRegistry.shared.settings = AgentSettings()
        AgentRegistry.shared.resetForTesting()
        scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("qt-agent-cli-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDown() {
        for path in socketPaths { unlink(path) }
        socketPaths.removeAll()
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
        NoticeCenter.shared.resetForTesting()
        AgentRegistry.shared.resetForTesting()
        harness?.cleanup()
        harness = nil
        super.tearDown()
    }

    // MARK: Running the real binary

    private func cli() throws -> URL {
        let url = try XCTUnwrap(Bundle.main.sharedSupportURL).appendingPathComponent("quickterm")
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: url.path),
                          "the bundled quickterm CLI is not in this build's app bundle")
        return url
    }

    private struct Run {
        var status: Int32
        var out: String
        var err: String
        var elapsed: TimeInterval
    }

    /// The base environment with **every** `QUICKTERM_` variable removed: a test run started from
    /// inside a QuickTerm pane inherits the developer's own socket, pane id and pane token, and a
    /// hook that found them would report into the app they are actually using.
    private var cleanEnvironment: [String: String] {
        ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("QUICKTERM_") }
    }

    /// Spawn the CLI, feed it `stdin` **from a file** (a pipe the child stops reading would block
    /// this side, which is precisely what the megabyte case is about), and pump the main run loop
    /// while it runs — the control server under test lives on this thread.
    private func run(_ arguments: [String], stdin: Data,
                     environment: [String: String]) throws -> Run {
        let input = scratch.appendingPathComponent("stdin-\(UUID().uuidString.prefix(6)).json")
        try stdin.write(to: input)
        let process = Process()
        process.executableURL = try cli()
        process.arguments = arguments
        process.environment = environment
        process.standardInput = try FileHandle(forReadingFrom: input)
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        let started = Date()
        try process.run()
        let deadline = started.addingTimeInterval(20)
        while process.isRunning, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertFalse(process.isRunning, "the hook's command hung: it must never block an agent")
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
        let elapsed = Date().timeIntervalSince(started)
        return Run(status: process.terminationStatus,
                   out: String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
                   err: String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
                   elapsed: elapsed)
    }

    /// Exit 0, nothing on stdout, nothing on stderr — whatever happened.
    ///
    /// The budget is not a benchmark: the plan's "within 50 ms" is a claim that nothing **waits**,
    /// and a cold `dyld` on a loaded build machine costs more than that on its own. Two seconds
    /// separates "it did not wait" from "it blocked on a socket or on stdin", which is the failure
    /// this is here to catch.
    private func assertSilentSuccess(_ run: Run, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(run.status, 0, "a hook must never exit non-zero: an agent reads that as a verdict",
                       file: file, line: line)
        XCTAssertEqual(run.out, "", "a hook must write nothing at all", file: file, line: line)
        XCTAssertEqual(run.err, "", "not one line of English on stderr either", file: file, line: line)
        XCTAssertLessThan(run.elapsed, 2, "the hook did not return promptly", file: file, line: line)
    }

    private func deadSocketPath() throws -> String {
        let path = scratch.appendingPathComponent("nobody.sock").path
        try XCTSkipUnless(ControlPaths.fits(path), "the temp path does not fit in sun_path")
        return path
    }

    private func liveSocketPath() throws -> String {
        let path = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("qta-\(UUID().uuidString.prefix(8)).sock")
        try XCTSkipUnless(ControlPaths.fits(path), "the temp path does not fit in sun_path")
        socketPaths.append(path)
        return path
    }

    private func makeServer(at path: String) throws -> ControlServer {
        let consent = ControlConsent(screens: harness.app.screens)
        let server = ControlServer(screens: harness.app.screens, consent: consent, socketPath: path)
        server.apply(ControlCommandRunner.Config())
        XCTAssertTrue(server.isListening)
        return server
    }

    private func fixture(_ event: String, agent: String = "claude-code") throws -> Data {
        try AgentPayloadFixtures.data(agent, event)
    }

    // MARK: QuickTerm is not running

    /// The commonest case in life: the hook entry is installed user-wide, and the agent is running
    /// in Terminal.app. Exit 2 (`not_running`) here would put a failing hook in front of the model
    /// on every single tool call.
    func testWithNobodyListeningItExitsZeroAndSaysNothing() throws {
        let dead = try deadSocketPath()
        var environment = cleanEnvironment
        environment[ControlProtocol.Env.socket] = dead
        environment[ControlProtocol.Env.pane] = UUID().uuidString
        environment[ControlProtocol.Env.paneToken] = String(repeating: "0", count: 64)
        let run = try run(["--socket", dead, "agent-event", "--agent", "claude-code"],
                          stdin: try fixture("PermissionRequest"), environment: environment)
        assertSilentSuccess(run)
    }

    /// The same, with no QuickTerm variables in the environment at all — the shape the script's own
    /// guard catches first, and which this binary must survive anyway.
    func testWithNoQuickTermEnvironmentAtAllItExitsZeroAndSaysNothing() throws {
        let run = try run(["--socket", try deadSocketPath(), "agent-event", "--agent", "claude-code"],
                          stdin: try fixture("Stop"), environment: cleanEnvironment)
        assertSilentSuccess(run)
    }

    /// An agent id no rule file defines is a `bad_request` on the server — and still silence here.
    func testARefusedReportIsStillSilentAndZero() throws {
        let path = try liveSocketPath()
        let server = try makeServer(at: path)
        defer { server.stop() }
        let pane = try harness.newTerminal()
        let run = try run(["--socket", path, "agent-event", "--agent", "nobody-writes-this-rule"],
                          stdin: try fixture("Stop"), environment: environment(for: pane, socket: path))
        assertSilentSuccess(run)
        XCTAssertNil(AgentRegistry.shared.status(pane: pane.id))
    }

    // MARK: End to end, through a real socket

    /// The whole path in one case: the hook's JSON on stdin, the CLI's own reduction, a real
    /// connection, the report class, the pane token, the lineage of a **real** child process, and
    /// the alarm that comes out the other end.
    func testTheHookPathPostsTheAlarmEndToEnd() throws {
        let path = try liveSocketPath()
        let server = try makeServer(at: path)
        defer { server.stop() }
        let pane = try harness.newTerminal()

        let run = try run(["--socket", path, "agent-event", "--agent", "claude-code"],
                          stdin: try fixture("PermissionRequest"),
                          environment: environment(for: pane, socket: path))
        assertSilentSuccess(run)

        let status = try XCTUnwrap(AgentRegistry.shared.status(pane: pane.id),
                                   "the report never reached the registry")
        XCTAssertEqual(status.state, .blocked)
        XCTAssertEqual(status.detail, .approval)
        XCTAssertEqual(status.tool, "Bash")
        XCTAssertEqual(status.evidence, .hook)
        XCTAssertEqual(status.message, "rm -rf build")

        let notice = try XCTUnwrap(NoticeCenter.shared.live(pane: pane.id).first)
        XCTAssertEqual(notice.urgency, .needsUser)
        // The lineage really was walked: the CLI is a direct child of this process, so the root of
        // its chain is its own pid — a number nothing in the request could have claimed.
        XCTAssertNotNil(notice.origin?.lineageRoot)
        XCTAssertEqual(notice.origin?.sessionID, "c3a1f0d2-51b8-4b6a-9a2e-6d0c1f3e8a47")
        // Not one byte of what the whitelist drops made the trip.
        let text = [notice.title, notice.body].compactMap { $0 }.joined(separator: " ")
        XCTAssertFalse(text.contains(".jsonl"))
        XCTAssertFalse(text.contains("/Users/danny/repo"))
    }

    /// A megabyte on stdin — a `Write` of a large file is an everyday `PreToolUse` payload — is
    /// **cut** at the cap, and a JSON object cut in half is no longer an event: the CLI drops it
    /// and exits. The live server is what makes this observable: had the CLI read the whole
    /// megabyte and sent it, the registry would be holding a status right now.
    func testAMegabyteOnStdinIsCutAndTheEventIsDropped() throws {
        let path = try liveSocketPath()
        let server = try makeServer(at: path)
        defer { server.stop() }
        let pane = try harness.newTerminal()

        let huge = String(repeating: "a", count: 1_000_000)
        let stdin = Data(#"{"hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"content":"\#(huge)"}}"#.utf8)
        XCTAssertGreaterThan(stdin.count, 1_000_000)

        let run = try run(["--socket", path, "agent-event", "--agent", "claude-code"],
                          stdin: stdin, environment: environment(for: pane, socket: path))
        assertSilentSuccess(run)
        XCTAssertNil(AgentRegistry.shared.status(pane: pane.id),
                     "a payload past the cap is dropped, never truncated into a half-read event")
    }

    /// `--event` written out by hand (what the help says it is for) wins over stdin, and is
    /// reduced on both sides all the same: the command is not two different commands depending on
    /// where the bytes came from.
    func testAHandWrittenEventArgumentWinsOverStdin() throws {
        let path = try liveSocketPath()
        let server = try makeServer(at: path)
        defer { server.stop() }
        let pane = try harness.newTerminal()

        let byHand = String(decoding: try fixture("Stop"), as: UTF8.self)
        let run = try run(["--socket", path, "agent-event", "--agent", "claude-code",
                           "--event", byHand],
                          stdin: try fixture("PermissionRequest"),
                          environment: environment(for: pane, socket: path))
        assertSilentSuccess(run)
        XCTAssertEqual(AgentRegistry.shared.status(pane: pane.id)?.state, .done)
        XCTAssertTrue(NoticeCenter.shared.live(pane: pane.id).allSatisfy { $0.urgency != .needsUser },
                      "stdin was ignored, so no approval prompt was ever reported")
    }

    // MARK: Helpers

    /// What QuickTerm injects into a pane, for the pane this case just created.
    private func environment(for pane: PaneView, socket: String) -> [String: String] {
        var environment = cleanEnvironment
        environment[ControlProtocol.Env.socket] = socket
        environment[ControlProtocol.Env.pane] = pane.id.uuidString
        environment[ControlProtocol.Env.paneToken] = ControlEnvironment.paneToken(for: pane.id)
        environment[ControlProtocol.Env.token] = ControlEnvironment.token
        return environment
    }
}
