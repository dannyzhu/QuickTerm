import Darwin
import XCTest
@testable import QuickTerm

/// **The scan's promise is mostly a promise about what it does *not* read** (plan §2.7, spec §2.3).
///
/// `KERN_PROCARGS2` hands over another program's entire environment, and on this machine it does
/// so for any non-platform binary of the same user, related to us or not. So the interesting
/// assertions here are negative ones: the buffer of a process that is not our descendant is never
/// asked for, nor is the buffer of a descendant whose executable no rule file names — not the
/// pane's own shell, not a dev server somebody started in a pane, not an unrelated editor.
///
/// The synthetic cases describe a process tree that does not exist, because a case that walked the
/// developer's real one would prove whatever that machine happened to be running. One case at the
/// end does a real pass, over a real child it spawned itself.
@MainActor
final class ProcessScannerTests: XCTestCase {
    // MARK: Fixtures

    /// A process tree that does not exist, and a record of every question asked about it.
    ///
    /// `@unchecked Sendable` with a clear conscience: every case drives a `synchronous` scanner,
    /// so the walk happens on the calling thread and there is no concurrency here to check.
    private final class FakeTree: @unchecked Sendable {
        var children: [pid_t: [pid_t]] = [:]
        var names: [pid_t: String] = [:]
        /// The `QUICKTERM_PANE` a pid's environment carries, if any.
        var panes: [pid_t: UUID] = [:]

        private(set) var namesRead: [pid_t] = []
        private(set) var argumentsRead: [pid_t] = []

        var listChildren: ProcessScan.ChildLister {
            { [self] pid in children[pid] ?? [] }
        }

        var readName: ProcessScan.NameReader {
            { [self] pid in
                namesRead.append(pid)
                return names[pid]
            }
        }

        var readArguments: ProcessScan.ArgumentReader {
            { [self] pid in
                argumentsRead.append(pid)
                guard let pane = panes[pid] else { return nil }
                return ProcessScannerTests.procargs(
                    execPath: "/opt/bin/\(names[pid] ?? "x")",
                    argv: [names[pid] ?? "x", "--resume"],
                    environment: ["PATH=/usr/bin", "\(ControlProtocol.Env.pane)=\(pane.uuidString)",
                                  "TERM=xterm-ghostty"])
            }
        }
    }

    /// A buffer shaped exactly like `KERN_PROCARGS2`: `argc`, the executable path, the NUL padding
    /// after it, `argc` arguments, then the environment. The parser has to walk all of that to
    /// reach the marker, so the fixture builds all of it.
    nonisolated private static func procargs(execPath: String, argv: [String],
                                             environment: [String]) -> Data {
        var bytes = Data()
        var argc = Int32(argv.count)
        withUnsafeBytes(of: &argc) { bytes.append(contentsOf: $0) }
        bytes.append(contentsOf: Array(execPath.utf8))
        bytes.append(contentsOf: [0, 0, 0])
        for argument in argv {
            bytes.append(contentsOf: Array(argument.utf8))
            bytes.append(0)
        }
        for entry in environment {
            bytes.append(contentsOf: Array(entry.utf8))
            bytes.append(0)
        }
        return bytes
    }

    private static let ruleText = """
    id = "demo"
    name = "Demo"
    process = ["claude"]

    [fields]
    session = "$.session_id"
    message = "$.message"
    tool    = "$.tool_name"
    error   = "$.error_type"
    summary = ["$.message"]

    [hooks]
    SessionStart = "idle"
    SessionEnd   = "released"
    """

    private var app: AppDelegate {
        get throws { try XCTUnwrap(NSApp.delegate as? AppDelegate) }
    }

    private var locator = NoticeLocatorStub()
    private var center: NoticeCenter!
    private var registry: AgentRegistry!
    private var now = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUp() async throws {
        try await super.setUp()
        locator = NoticeLocatorStub()
        center = NoticeCenter(locator: locator, clock: { [self] in now })
        registry = AgentRegistry(rules: [try AgentRules.parse(Self.ruleText)], center: center,
                                 locator: locator, clock: { [self] in now })
        registry.settings.enabled = ["demo"]
    }

    /// A scanner that runs its pass inline, so a case can read the registry on the next line.
    private func makeScanner(root: pid_t = 1000) -> ProcessScanner {
        let scanner = ProcessScanner(registry: registry)
        scanner.root = root
        scanner.clock = { [self] in now }
        scanner.synchronous = true
        return scanner
    }

    @discardableResult
    private func addPane() throws -> (id: UUID, view: PaneView) {
        let host = try XCTUnwrap(app.screens.primary)
        let pane = PaneView(frame: .zero)
        locator.entries[pane.id] = .init(pane: pane, controller: host, workspace: 0,
                                         activity: PaneActivity(appActive: false, screenKey: false,
                                                                workspaceVisible: false,
                                                                focused: false))
        return (pane.id, pane)
    }

    /// QuickTerm(1000) → shell(1001) → claude(1002) → sh(1003) → quickterm(1004), plus a sibling
    /// `node` server(1005) in a second pane's shell(1006), plus an unrelated `claude`(2000) that
    /// is not in the tree at all.
    private func syntheticTree(pane: UUID, otherPane: UUID) -> FakeTree {
        let tree = FakeTree()
        tree.children = [1000: [1001, 1006], 1001: [1002], 1002: [1003], 1003: [1004],
                         1006: [1005]]
        tree.names = [1001: "zsh", 1002: "claude", 1003: "sh", 1004: "quickterm",
                      1006: "zsh", 1005: "node", 2000: "claude"]
        tree.panes = [1002: pane, 1004: pane, 1005: otherPane, 2000: otherPane]
        return tree
    }

    // MARK: What the walk reads

    func testOnlyTheNamedDescendantsBufferIsEverRead() throws {
        let pane = try addPane().id
        let other = try addPane().id
        let tree = syntheticTree(pane: pane, otherPane: other)
        let scanner = makeScanner()
        scanner.listChildren = tree.listChildren
        scanner.readName = tree.readName
        scanner.readArguments = tree.readArguments

        scanner.scanNow()
        let result = try XCTUnwrap(scanner.lastResult)

        XCTAssertEqual(tree.argumentsRead, [1002],
                       "only the pid whose executable a rule file names may have its environment "
                       + "read — not the shell, not the node server, not the nested quickterm")
        XCTAssertEqual(result.matches, [ProcessScan.Match(pid: 1002, name: "claude", pane: pane)])
        XCTAssertEqual(result.byPane, [pane: ["demo": [1002]]],
                       "presence is attributed: the name that matched is also whose it is")
    }

    /// One pane, two agents — a nested `claude` under another agent's session. The name match is
    /// the attribution, so the pass yields two presences rather than one merged pid set that
    /// neither rule could be released by on its own.
    func testTwoAgentsInOnePaneAreTwoPresences() throws {
        registry.reloadRulesForTesting([
            try AgentRules.parse(Self.ruleText),
            try AgentRules.parse(Self.ruleText
                .replacingOccurrences(of: "id = \"demo\"", with: "id = \"other\"")
                .replacingOccurrences(of: "process = [\"claude\"]", with: "process = [\"nested\"]"))])
        registry.settings.enabled = ["demo", "other"]

        let pane = try addPane().id
        let tree = syntheticTree(pane: pane, otherPane: try addPane().id)
        tree.children[1002] = [1003, 1007]
        tree.names[1007] = "nested"
        tree.panes[1007] = pane

        let scanner = makeScanner()
        scanner.listChildren = tree.listChildren
        scanner.readName = tree.readName
        scanner.readArguments = tree.readArguments
        scanner.scanNow()

        let result = try XCTUnwrap(scanner.lastResult)
        XCTAssertEqual(result.byPane, [pane: ["demo": [1002], "other": [1007]]])
    }

    func testAPidOutsideTheTreeIsNeverEvenNamed() throws {
        let pane = try addPane().id
        let other = try addPane().id
        let tree = syntheticTree(pane: pane, otherPane: other)
        let scanner = makeScanner()
        scanner.listChildren = tree.listChildren
        scanner.readName = tree.readName
        scanner.readArguments = tree.readArguments
        scanner.scanNow()

        XCTAssertFalse(tree.namesRead.contains(2000),
                       "2000 is an agent by name and carries a marker, and it is still none of our "
                       + "business: it does not descend from QuickTerm")
        XCTAssertFalse(tree.argumentsRead.contains(2000))
        XCTAssertEqual(Set(tree.namesRead), [1001, 1002, 1003, 1004, 1005, 1006])
    }

    func testDetectionOffTouchesNothing() throws {
        let pane = try addPane().id
        let tree = syntheticTree(pane: pane, otherPane: try addPane().id)
        registry.settings.detect = false
        let scanner = makeScanner()
        scanner.listChildren = tree.listChildren
        scanner.readName = tree.readName
        scanner.readArguments = tree.readArguments
        scanner.scanNow()

        XCTAssertEqual(tree.namesRead, [], "with detection off the process table is not walked")
        XCTAssertEqual(tree.argumentsRead, [])
    }

    func testNoEnabledRuleNamesAProcessSoNothingIsWalked() throws {
        let pane = try addPane().id
        let tree = syntheticTree(pane: pane, otherPane: try addPane().id)
        registry.settings.enabled = []
        let scanner = makeScanner()
        scanner.listChildren = tree.listChildren
        scanner.readName = tree.readName
        scanner.readArguments = tree.readArguments
        scanner.scanNow()

        XCTAssertEqual(tree.namesRead, [])
        XCTAssertEqual(tree.argumentsRead, [])
    }

    func testTheWalkIsBounded() throws {
        let pane = try addPane().id
        let tree = FakeTree()
        // A chain one link longer than the bound, with the agent at the far end.
        let depth = ProcessScan.maxDepth + 1
        for step in 0..<depth { tree.children[pid_t(1000 + step)] = [pid_t(1001 + step)] }
        for step in 1...depth { tree.names[pid_t(1000 + step)] = "sh" }
        tree.names[pid_t(1000 + depth)] = "claude"
        tree.panes[pid_t(1000 + depth)] = pane

        let scanner = makeScanner()
        scanner.listChildren = tree.listChildren
        scanner.readName = tree.readName
        scanner.readArguments = tree.readArguments
        scanner.scanNow()
        let result = try XCTUnwrap(scanner.lastResult)

        XCTAssertTrue(result.byPane.isEmpty,
                      "a chain deeper than \(ProcessScan.maxDepth) is not walked to the end")
        XCTAssertFalse(tree.namesRead.contains(pid_t(1000 + depth)))
    }

    func testACycleInTheTreeTerminates() throws {
        let tree = FakeTree()
        tree.children = [1000: [1001], 1001: [1002], 1002: [1001]]
        tree.names = [1001: "zsh", 1002: "zsh"]
        let scanner = makeScanner()
        scanner.listChildren = tree.listChildren
        scanner.readName = tree.readName
        scanner.readArguments = tree.readArguments
        scanner.scanNow()

        XCTAssertEqual(Set(tree.namesRead), [1001, 1002], "each pid is looked at once")
    }

    // MARK: The marker

    func testTheMarkerIsReadFromTheEnvironmentAndNotFromTheCommandLine() throws {
        let real = UUID()
        let forged = UUID()
        let buffer = Self.procargs(
            execPath: "/opt/homebrew/bin/claude",
            // `env QUICKTERM_PANE=<other> claude` is a claim about a command line, not about the
            // pane a process is running in: the parser walks past argv to the environment block.
            argv: ["env", "\(ControlProtocol.Env.pane)=\(forged.uuidString)", "claude"],
            environment: ["SHELL=/bin/zsh", "\(ControlProtocol.Env.pane)=\(real.uuidString)"])

        XCTAssertEqual(ProcessScan.paneMarker(in: buffer), real)
    }

    func testABufferWithoutAMarkerYieldsNothing() throws {
        // What a platform binary looks like from outside: macOS answers nothing at all for
        // `/bin/sleep` or `zsh`, so the scan never finds the pane's own shell (spec §2.3).
        XCTAssertNil(ProcessScan.paneMarker(in: Data()))
        XCTAssertNil(ProcessScan.paneMarker(in: Data([1, 2])))
        XCTAssertNil(ProcessScan.paneMarker(in: Self.procargs(
            execPath: "/bin/zsh", argv: ["-zsh"], environment: ["PATH=/usr/bin"])))
        XCTAssertNil(ProcessScan.paneMarker(in: Self.procargs(
            execPath: "/opt/bin/claude", argv: ["claude"],
            environment: ["\(ControlProtocol.Env.pane)=not-a-uuid"])),
                     "a marker that is not a uuid is not a pane")
    }

    // MARK: What the registry is told

    func testPresenceCreatesAnUnknownStatusAndLosingItReleasesIt() throws {
        let pane = try addPane().id
        let tree = syntheticTree(pane: pane, otherPane: try addPane().id)
        let scanner = makeScanner()
        scanner.listChildren = tree.listChildren
        scanner.readName = tree.readName
        scanner.readArguments = tree.readArguments

        scanner.scanNow()
        let status = try XCTUnwrap(registry.status(pane: pane))
        XCTAssertEqual(status.state, .unknown, "presence says an agent is there, never what it does")
        XCTAssertEqual(status.evidence, .process)
        XCTAssertTrue(status.seenByScan)

        // The agent exits: the next pass finds nothing under that pane, and the pane hears about
        // it explicitly — an empty set is the only way presence loss is ever spelled.
        tree.children[1001] = []
        scanner.scanNow()
        XCTAssertNil(registry.status(pane: pane))
    }

    func testAPaneTheLocatorNoLongerKnowsIsDropped() throws {
        let pane = try addPane().id
        let tree = syntheticTree(pane: pane, otherPane: try addPane().id)
        let scanner = makeScanner()
        scanner.listChildren = tree.listChildren
        scanner.readName = tree.readName
        scanner.readArguments = tree.readArguments
        scanner.scanNow()
        XCTAssertNotNil(registry.status(pane: pane))

        // The pane closed while the app was in the background; the next pass is where the
        // registry learns it (plan §2.5).
        locator.entries[pane] = nil
        scanner.scanNow()
        XCTAssertNil(registry.status(pane: pane))
    }

    // MARK: Coalescing

    func testRequestsAreCoalescedToOnePassPerWindow() throws {
        let pane = try addPane().id
        let tree = syntheticTree(pane: pane, otherPane: try addPane().id)
        let scanner = makeScanner()
        scanner.listChildren = tree.listChildren
        scanner.readName = tree.readName
        scanner.readArguments = tree.readArguments

        // A turn's worth of hooks arriving at once buys exactly one pass.
        scanner.requestScan()
        scanner.requestScan()
        scanner.requestScan()
        XCTAssertEqual(scanner.deferrals.count, 1)
        XCTAssertEqual(scanner.deferrals[0], 0, accuracy: 0.001,
                       "nothing has been scanned yet, so the first request runs at once")
        scanner.firePendingScan()
        XCTAssertEqual(scanner.passes, 1)

        // A request 100 ms later waits out the rest of the window rather than walking again.
        now = now.addingTimeInterval(0.1)
        scanner.requestScan()
        XCTAssertEqual(scanner.deferrals.count, 2)
        XCTAssertEqual(scanner.deferrals[1], ProcessScanner.coalescingWindow - 0.1, accuracy: 0.001)
        now = now.addingTimeInterval(0.15)
        scanner.firePendingScan()
        XCTAssertEqual(scanner.passes, 2)

        // And a request after the window is due immediately again.
        now = now.addingTimeInterval(1)
        scanner.requestScan()
        XCTAssertEqual(scanner.deferrals.count, 3)
        XCTAssertEqual(scanner.deferrals[2], 0, accuracy: 0.001)
    }

    func testTheRegistrysScanTriggerIsTheScanner() throws {
        let scanner = makeScanner()
        scanner.install()
        registry.scanTrigger()
        XCTAssertEqual(scanner.deferrals.count, 1,
                       "a hook asks the registry for a scan and reaches the scanner")
    }

    // MARK: One real pass, over one real child

    /// Everything above describes a tree; this one walks the real process table once.
    ///
    /// The child has to be a **non-platform** binary or there would be nothing to find: macOS
    /// hides the environment of `/bin/sleep`, `/usr/bin/env` and `sh` from every other process,
    /// their own parent included (spec §2.3). The bundled `quickterm` is ad-hoc signed by this
    /// build, so it is not a platform binary; `spec validate -f -` blocks reading stdin long
    /// before it looks for a socket, which makes it a child that stays alive, talks to nothing and
    /// carries whatever environment we hand it.
    func testARealChildCarryingTheMarkerIsFoundByOneRealPass() throws {
        let cli = try XCTUnwrap(AppDelegate.bundledCLIURL)
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: cli.path),
                          "the bundled quickterm CLI is not in this build")
        registry.reloadRulesForTesting([try AgentRules.parse(
            Self.ruleText.replacingOccurrences(of: "process = [\"claude\"]",
                                               with: "process = [\"quickterm\"]"))])

        let pane = try addPane().id
        let child = Process()
        child.executableURL = cli
        // `--socket` at a path that cannot exist: even if the child ever reached EOF on stdin it
        // could not talk to the QuickTerm the developer is actually running.
        child.arguments = ["spec", "validate", "-f", "-", "--socket", "/tmp/qt-no-such.sock"]
        var environment = ProcessInfo.processInfo.environment
        environment[ControlProtocol.Env.pane] = pane.uuidString
        child.environment = environment
        let input = Pipe()
        child.standardInput = input
        child.standardOutput = Pipe()
        child.standardError = Pipe()
        try child.run()
        defer {
            if child.isRunning { child.terminate() }
            try? input.fileHandleForWriting.close()
        }

        let recorder = PidRecorder()
        let scanner = ProcessScanner(registry: registry)
        scanner.synchronous = true
        scanner.readArguments = { pid in
            recorder.record(pid)
            return ProcessScan.argumentBuffer(of: pid)
        }

        // The pid exists the moment `run()` returns, but the exec that gives it our environment
        // takes a moment; a pass is cheap, so try a few.
        let deadline = Date().addingTimeInterval(5)
        while registry.status(pane: pane) == nil, Date() < deadline {
            scanner.scanNow()
            if registry.status(pane: pane) != nil { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }

        XCTAssertTrue(child.isRunning, "the child exited before a pass could find it")
        let status = try XCTUnwrap(registry.status(pane: pane),
                                   "one real pass should have found the child in its pane")
        XCTAssertEqual(status.evidence, .process)
        XCTAssertTrue(recorder.pids.contains(child.processIdentifier))
        for pid in recorder.pids {
            XCTAssertEqual(ProcessScan.executableName(of: pid), "quickterm",
                           "a real pass may only read the buffer of a process a rule file names")
        }
    }

    /// The pids `readArguments` was called for. A class because the seam is `@Sendable`; the
    /// recording happens on the calling thread (the scanner is `synchronous`).
    private final class PidRecorder: @unchecked Sendable {
        private(set) var pids: [pid_t] = []
        func record(_ pid: pid_t) { pids.append(pid) }
    }
}
