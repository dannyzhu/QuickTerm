import XCTest
@testable import QuickTerm

/// **The script that runs on every prompt of every agent** (plan §2.6).
///
/// Half of these cases actually run it with `/bin/sh`, because the script's whole contract is
/// behavioural and not textual: *whatever happens, the agent is not held up and is not failed*.
/// Reading the source and agreeing that it looks right is exactly the kind of check that misses a
/// missing `exit 0`.
///
/// Nothing here touches the real `~`: every path is under the case's own temporary directory.
@MainActor
final class HookScriptTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("quickterm-hook-script-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    private var scriptPath: String { root.appendingPathComponent(HookScript.fileName).path }

    // MARK: The text

    func testScriptCarriesTheVersionMarkerAndASingleQuotedBinary() throws {
        let text = try HookScript.text(binary: "/Applications/QuickTerm.app/Contents/SharedSupport/quickterm")
        XCTAssertTrue(text.hasPrefix("#!/bin/sh\n"))
        XCTAssertTrue(text.contains(HookScript.versionMarker))
        XCTAssertTrue(text.contains("QT_BIN='/Applications/QuickTerm.app/Contents/SharedSupport/quickterm'"))
        // The path is never *taken* from the environment — that is the whole reason it is baked
        // in. (The name appears once, in the comment that says never to read it.)
        XCTAssertFalse(text.contains("$QUICKTERM_BIN"))
        XCTAssertFalse(text.contains("${QUICKTERM_BIN"))
        XCTAssertTrue(text.hasSuffix("exit 0\n"))
    }

    func testBakedBinaryIsReadBackAndOnlyFromOurOwnScript() throws {
        let text = try HookScript.text(binary: "/opt/qt/quickterm")
        XCTAssertEqual(HookScript.bakedBinary(in: text), "/opt/qt/quickterm")
        // Somebody else's script that happens to set QT_BIN is not ours and is never rewritten.
        XCTAssertNil(HookScript.bakedBinary(in: "#!/bin/sh\nQT_BIN='/opt/qt/quickterm'\n"))
    }

    func testAPathWithAQuoteIsRefusedRatherThanEscaped() {
        XCTAssertNil(HookScript.quoted("/Users/dan's mac/QuickTerm.app/Contents/SharedSupport/quickterm"))
        XCTAssertNil(HookScript.command(scriptPath: "/Users/dan's/hook.sh", agent: "claude-code"))
        XCTAssertThrowsError(try HookScript.text(binary: "/Users/dan's/quickterm")) { error in
            XCTAssertEqual((error as? ControlErrorBody)?.code, ControlErrorCode.badRequest.rawValue)
        }
    }

    func testTheCommandStringIsTheMarkerAndIsSingleQuoted() {
        let command = HookScript.command(scriptPath: "/Users/dan/with space/quickterm-agent-state.sh",
                                         agent: "claude-code")
        XCTAssertEqual(command, "'/Users/dan/with space/quickterm-agent-state.sh' claude-code")
        XCTAssertTrue(HookScript.isOurs(command: try XCTUnwrap(command)))
        XCTAssertFalse(HookScript.isOurs(command: "/usr/local/bin/my-own-hook.sh"))
    }

    // MARK: On disk

    func testWritingCreatesA0755ScriptInA0700Directory() throws {
        let nested = root.appendingPathComponent(".config/quickterm/hooks")
            .appendingPathComponent(HookScript.fileName).path
        XCTAssertTrue(try HookScript.write(to: nested, binary: "/opt/qt/quickterm"))
        let manager = FileManager.default
        XCTAssertEqual(try manager.attributesOfItem(atPath: nested)[.posixPermissions] as? Int, 0o755)
        XCTAssertEqual(try manager.attributesOfItem(atPath: (nested as NSString).deletingLastPathComponent)[.posixPermissions] as? Int,
                       0o700)
        // Idempotent: the same binary writes nothing the second time.
        XCTAssertFalse(try HookScript.write(to: nested, binary: "/opt/qt/quickterm"))
        XCTAssertTrue(try HookScript.write(to: nested, binary: "/opt/other/quickterm"))
    }

    func testASymlinkedScriptPathIsRefused() throws {
        let real = root.appendingPathComponent("elsewhere.sh")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: real)
        try FileManager.default.createSymbolicLink(atPath: scriptPath, withDestinationPath: real.path)
        XCTAssertThrowsError(try HookScript.write(to: scriptPath, binary: "/opt/qt/quickterm")) { error in
            XCTAssertEqual((error as? ControlErrorBody)?.code, ControlErrorCode.badRequest.rawValue)
        }
        // Not one byte written through the link.
        XCTAssertEqual(try String(contentsOf: real, encoding: .utf8), "#!/bin/sh\nexit 0\n")
        XCTAssertTrue(HookScript.status(path: scriptPath).isSymlink)
        XCTAssertFalse(HookScript.status(path: scriptPath).ok)
    }

    func testStatusReportsTheBakedBinaryAndWhetherItIsStillThere() throws {
        let binary = try stub(exit: 0)
        try HookScript.write(to: scriptPath, binary: binary)
        var status = HookScript.status(path: scriptPath)
        XCTAssertTrue(status.exists)
        XCTAssertEqual(status.bakedBinary, binary)
        XCTAssertTrue(status.bakedBinaryExists)
        XCTAssertTrue(status.ok)

        try FileManager.default.removeItem(atPath: binary)
        status = HookScript.status(path: scriptPath)
        XCTAssertFalse(status.bakedBinaryExists)
        XCTAssertFalse(status.ok)
    }

    // MARK: The launch self-heal

    func testSelfHealRewritesOnlyWhenTheBakedBinaryIsGone() throws {
        let gone = root.appendingPathComponent("gone/quickterm").path
        let present = try stub(exit: 0)
        try HookScript.write(to: scriptPath, binary: present)

        // A different build is running: the baked path is still there, so nothing is touched — a
        // Debug build must not repoint the hooks the user's installed copy is serving.
        XCTAssertFalse(HookScript.healIfStale(path: scriptPath, binary: "/Applications/QuickTerm.app/Contents/SharedSupport/quickterm"))
        XCTAssertEqual(HookScript.status(path: scriptPath).bakedBinary, present)

        // The baked path has gone: now it is repointed, once.
        try HookScript.write(to: scriptPath, binary: gone)
        XCTAssertTrue(HookScript.healIfStale(path: scriptPath, binary: present))
        XCTAssertEqual(HookScript.status(path: scriptPath).bakedBinary, present)
        XCTAssertFalse(HookScript.healIfStale(path: scriptPath, binary: present))
    }

    func testSelfHealLeavesAScriptThatIsNotOursAlone() throws {
        try Data("#!/bin/sh\n# somebody else\nexit 0\n".utf8)
            .write(to: URL(fileURLWithPath: scriptPath))
        XCTAssertFalse(HookScript.healIfStale(path: scriptPath, binary: "/opt/qt/quickterm"))
        XCTAssertEqual(try String(contentsOfFile: scriptPath, encoding: .utf8),
                       "#!/bin/sh\n# somebody else\nexit 0\n")
    }

    // MARK: Running it (the contract that matters)

    /// No QuickTerm in the environment: the hook is a no-op, immediately. This is what makes the
    /// same entry in `~/.claude/settings.json` harmless in Terminal.app, tmux or CI.
    func testWithoutTheEnvironmentItExitsZeroAtOnceAndSaysNothing() throws {
        try HookScript.write(to: scriptPath, binary: try stub(exit: 2))
        let started = Date()
        let run = try run(environment: [:])
        XCTAssertEqual(run.status, 0)
        XCTAssertEqual(run.stdout, "")
        XCTAssertEqual(run.stderr, "")
        // "Immediately" is the claim, not a benchmark: a spawn plus three `[ -n ]` tests. The
        // bound is loose enough for a loaded machine and still fails if the script ever starts
        // waiting for a socket.
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.5)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stubLog.path),
                       "the CLI must not be spawned at all outside QuickTerm")
    }

    func testAMissingBinaryStillExitsZero() throws {
        try HookScript.write(to: scriptPath, binary: root.appendingPathComponent("not-there").path)
        XCTAssertEqual(try run(environment: paneEnvironment).status, 0)
    }

    func testABinaryThatFailsStillExitsZero() throws {
        try HookScript.write(to: scriptPath, binary: try stub(exit: 2))
        let run = try run(environment: paneEnvironment)
        XCTAssertEqual(run.status, 0, "exit 2 is 'QuickTerm is not running' — never the agent's problem")
        XCTAssertEqual(run.stdout, "")
        XCTAssertEqual(run.stderr, "")
    }

    func testStdinAndTheAgentIdReachTheBinary() throws {
        try HookScript.write(to: scriptPath, binary: try stub(exit: 0))
        let payload = String(repeating: "x", count: 4096)
        let run = try run(environment: paneEnvironment, stdin: payload)
        XCTAssertEqual(run.status, 0)
        let log = try String(contentsOf: stubLog, encoding: .utf8)
        // The stub writes down its arguments and the number of bytes it read from stdin.
        XCTAssertTrue(log.contains("agent-event --agent claude-code"), log)
        XCTAssertTrue(log.contains("bytes=4096"), log)
    }

    // MARK: Helpers

    private var stubLog: URL { root.appendingPathComponent("stub.log") }

    private var paneEnvironment: [String: String] {
        ["QUICKTERM_SOCKET": root.appendingPathComponent("socket").path,
         "QUICKTERM_PANE": UUID().uuidString,
         "QUICKTERM_PANE_TOKEN": "deadbeef"]
    }

    /// A stand-in for the `quickterm` CLI: writes down what it was called with and how much stdin
    /// it was handed, then exits with the code asked for.
    private func stub(exit code: Int) throws -> String {
        let path = root.appendingPathComponent("quickterm").path
        let text = """
        #!/bin/sh
        BYTES=$(wc -c | tr -d ' ')
        printf '%s bytes=%s\\n' "$*" "$BYTES" >> '\(stubLog.path)'
        exit \(code)
        """
        try Data(text.utf8).write(to: URL(fileURLWithPath: path))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        return path
    }

    private func run(environment: [String: String], stdin: String = "{}")
        throws -> (status: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [scriptPath, "claude-code"]
        process.environment = environment
        let out = Pipe(), err = Pipe(), input = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = input
        try process.run()
        input.fileHandleForWriting.write(Data(stdin.utf8))
        try? input.fileHandleForWriting.close()
        let stdoutData = out.fileHandleForReading.readDataToEndOfFile()
        let stderrData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus,
                String(decoding: stdoutData, as: UTF8.self),
                String(decoding: stderrData, as: UTF8.self))
    }
}
