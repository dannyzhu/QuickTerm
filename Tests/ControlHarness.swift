import XCTest
@testable import QuickTerm

/// Shared fixture for the Phase 2 cases: **drives `ControlCommandRunner` directly**, no socket.
///
/// Why not go through the socket: Phase 1 already nailed down the "socket -> main-thread hop ->
/// runner" leg (`ControlServerTests`), and walking it a second time would only turn every case
/// async. The command semantics themselves (idempotence, dry-run, rate limiting, modal guard,
/// undo) all live in the runner layer, and running them synchronously is both faster and steadier.
///
/// Every reply is **encoded through JSONEncoder and decoded back again**: that pins the "all JSON
/// goes through JSONEncoder" invariant onto every single case (yabai's trailing-comma incident
/// happened in hand-assembled JSON).
@MainActor
final class ControlHarness {
    let app: AppDelegate
    let runner: ControlCommandRunner
    let consent: ControlConsent
    private var nextID = 0
    /// Panes a case created: tearDown closes every one of them, so they never pollute later cases
    private(set) var created: [PaneView] = []

    init(allowDestructive: Bool = true) throws {
        // The consent alert text follows the UI language (`[general] language`). These cases
        // compare that text verbatim, so the harness pins the language to Chinese — otherwise
        // the very same case would go red on a machine whose system language is English.
        Localization.shared.setLanguage(.zh)
        app = try XCTUnwrap(NSApp.delegate as? AppDelegate)
        consent = ControlConsent(screens: app.screens)
        if allowDestructive { consent.decisionStub = { _, reply in reply(.allow) } }
        runner = ControlCommandRunner(screens: app.screens, consent: consent)
        runner.config = ControlCommandRunner.Config()
        // The event bus is a process-wide singleton: record "now" as the baseline, otherwise the
        // panes left behind by the previous case turn into a stream of inexplicable pane.closed
        // events inside this one
        ControlEventBus.shared.resetForTesting()
    }

    /// The seq as of right now (the starting point for `events poll --since`)
    var seq: Int { ControlEventBus.shared.seq }

    /// Events after `since` (unredacted; redaction is pinned separately by `ControlEventTests`)
    func events(since: Int) -> [ControlEvent] {
        ControlEventBus.shared.flush()
        return ControlEventBus.shared.batch(since: since, limit: ControlEventLimits.maxBatch,
                                            types: nil, exposesBrowser: true).events
    }

    var controller: MainWindowController {
        get throws { try XCTUnwrap(app.controller) }
    }

    func spin(_ seconds: TimeInterval = 0.25) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    /// Send one command and get the decoded reply back synchronously
    @discardableResult
    func run(_ cmd: String, target: String? = nil, args: [String: JSONValue] = [:],
             token: String? = nil, origin: ControlRequestOrigin? = nil,
             file: StaticString = #filePath, line: UInt = #line) throws -> ControlReply {
        nextID += 1
        let request = ControlRequest(id: String(nextID), cmd: cmd, target: target, args: args,
                                     token: token, origin: origin)
        let peer = ControlSocket.Peer(fd: -1, uid: getuid(), pid: getpid(), processName: "xctest")
        var response: ControlResponse?
        runner.handle(request, peer: peer) { response = $0 }
        let got = try XCTUnwrap(response, "command did not return synchronously (is the consent gate stuck?)",
                                file: file, line: line)
        let data = try ControlJSON.line(got)
        return try ControlJSON.decoder.decode(ControlReply.self, from: data)
    }

    /// The mutation envelope (prints the error on failure, so you are not staring at a nil guessing)
    func mutation(_ reply: ControlReply, file: StaticString = #filePath, line: UInt = #line) throws
        -> [String: JSONValue] {
        XCTAssertTrue(reply.ok, "command failed: \(String(describing: reply.error))", file: file, line: line)
        return try XCTUnwrap(reply.data?.objectValue, "reply carries no data", file: file, line: line)
    }

    /// Create a terminal pane and book it (they all get closed when the case ends)
    @discardableResult
    func newTerminal(in workspace: Int? = nil) throws -> PaneView {
        let controller = try self.controller
        if let workspace { controller.switchWorkspace(workspace) }
        let before = Set(controller.model.allPanes.map(\.id))
        controller.perform(.newTerminal)
        spin(0.3)
        let pane = try XCTUnwrap(controller.model.allPanes.first { !before.contains($0.id) },
                                 "failed to create the new pane")
        created.append(pane)
        return pane
    }

    func track(_ pane: PaneView) { created.append(pane) }

    /// **Byte-level** structural state of one screen: this is how the `--dry-run` cases prove
    /// that "not a single byte changed". `windowState()` is a pure read in itself (it is the
    /// persistence path) and Codable, which makes it exactly the right baseline — but the leaf
    /// fields that **change on their own** have to be scrubbed first: a real shell is running in
    /// there, and the OSC 7 pwd and the terminal title can update at any moment, which is not the
    /// control command's doing
    func fingerprint(_ controller: MainWindowController) throws -> String {
        let data = try ControlJSON.encoder.encode(controller.windowState())
        let value = try ControlJSON.decoder.decode(JSONValue.self, from: data)
        let scrubbed = Self.scrub(value)
        return String(decoding: try ControlJSON.encoder.encode(scrubbed), as: UTF8.self)
    }

    /// Scrub the fields the shell changes on its own (title / cwd) — structure, ids, column
    /// widths, zoom and focus are all kept
    static let volatileKeys: Set<String> = ["title", "pwd", "isUserSetTitle"]

    static func scrub(_ value: JSONValue) -> JSONValue {
        switch value {
        case .object(let object):
            var out: [String: JSONValue] = [:]
            for (key, child) in object where !volatileKeys.contains(key) { out[key] = scrub(child) }
            return .object(out)
        case .array(let array):
            return .array(array.map(scrub))
        default:
            return value
        }
    }

    func cleanup() {
        for controller in app.screens.controllers {
            for pane in created where controller.model.allPanes.contains(where: { $0 === pane }) {
                controller.closePane(pane, confirmIfNeeded: false, animated: false)
                controller.removeFromAnyWorkspace(pane)
            }
            controller.flushPendingCloses()
        }
        created.removeAll()
        spin(0.2)
    }
}
