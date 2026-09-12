import AppKit
import XCTest
@testable import QuickTerm

/// The **control-plane** half of workspace names: `workspace set --title`, the echo in `state` / `list`,
/// the `workspace.changed` event, the spec round trip, and what "the name belongs to the slot" means when
/// a workspace is cleared.
@MainActor
final class WorkspaceTitleControlTests: XCTestCase {
    private var harness: ControlHarness!
    private var temporaries: [String] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        harness = try ControlHarness()
        let controller = try harness.controller
        try XCTSkipUnless(controller.model.layouts.count >= 3, "this group of cases needs three workspaces")
        clearNames()
    }

    override func tearDown() {
        // Names are process-wide shared state: leave one behind and the `spec dump -> apply -> dump`
        // fixed-point case goes red.
        clearNames()
        harness?.cleanup()
        harness = nil
        for path in temporaries { try? FileManager.default.removeItem(atPath: path) }
        temporaries = []
        super.tearDown()
    }

    private func clearNames() {
        guard let controller = try? harness?.controller else { return }
        controller.model.titles = Array(repeating: nil, count: controller.model.layouts.count)
    }

    private func title(of workspace: Int) throws -> String? {
        try harness.controller.model.title(at: workspace - 1)
    }

    // MARK: Commands

    /// Setting is absolute: set it, set the same value again for a no-op (`--fail-if-noop` exits 7), pass
    /// an empty string to clear it.
    func testSetTitleIsAbsoluteAndIdempotent() throws {
        let first = try harness.mutation(try harness.run("workspace.set", target: ":2",
                                                         args: ["title": .string("dev")]))
        XCTAssertEqual(first["changed"]?.boolValue, true)
        XCTAssertEqual(try title(of: 2), "dev")

        let second = try harness.mutation(try harness.run("workspace.set", target: ":2",
                                                          args: ["title": .string("dev")]))
        XCTAssertEqual(second["changed"]?.boolValue, false, "the same value a second time must change nothing")

        let strict = try harness.run("workspace.set", target: ":2",
                                     args: ["title": .string("dev"),
                                            ControlCommandTable.Flag.failIfNoop: .bool(true)])
        XCTAssertFalse(strict.ok)
        XCTAssertEqual(strict.error?.exit, ControlExit.noop.rawValue)

        let cleared = try harness.mutation(try harness.run("workspace.set", target: ":2",
                                                           args: ["title": .string("")]))
        XCTAssertEqual(cleared["changed"]?.boolValue, true, "an empty string is a meaningful value: it clears the name")
        XCTAssertNil(try title(of: 2))
    }

    /// Without `-t` the target is the **active** workspace of the addressed screen.
    func testDefaultTargetIsTheActiveWorkspace() throws {
        let controller = try harness.controller
        try harness.run("workspace.set", args: ["title": .string("here")]).assertOK()
        XCTAssertEqual(controller.model.title(at: controller.model.activeIndex), "here")
    }

    /// Validation matches `pane set --title` point for point: control characters rejected, a 200-character
    /// cap, and a missing --title is an error.
    func testValidationMatchesPaneSetTitle() throws {
        let control = try harness.run("workspace.set", target: ":2",
                                      args: ["title": .string("dev\u{7}log")])
        XCTAssertFalse(control.ok)
        XCTAssertEqual(control.error?.code, ControlErrorCode.badRequest.rawValue)

        let long = String(repeating: "a", count: ControlCommandRunner.maxTitleLength + 1)
        let tooLong = try harness.run("workspace.set", target: ":2", args: ["title": .string(long)])
        XCTAssertFalse(tooLong.ok)

        let exact = String(repeating: "a", count: ControlCommandRunner.maxTitleLength)
        try harness.run("workspace.set", target: ":2", args: ["title": .string(exact)]).assertOK()

        let nothing = try harness.run("workspace.set", target: ":2", args: [:])
        XCTAssertFalse(nothing.ok, "no value given at all")
        XCTAssertNil(try title(of: 3), "a failed command must not change a single byte")
    }

    /// The copy that goes to OSLog keeps only the path (same rule as pane titles: /var/db/diagnostics is
    /// world-readable).
    func testTheValueStaysOutOfTheSystemLog() throws {
        try harness.run("workspace.set", target: ":2", args: ["title": .string("秘密项目")]).assertOK()
        let entry = try XCTUnwrap(ControlActivityLog.shared.recent(1).first)
        XCTAssertTrue(entry.line.contains("秘密项目"), "the in-app copy keeps the full text; the only reader is the user")
        XCTAssertFalse(entry.logLine.contains("秘密项目"), "the copy that reaches OSLog keeps only the path")
    }

    // MARK: Echo and events

    func testTitleShowsUpInStateAndList() throws {
        try harness.run("workspace.set", target: ":2", args: ["title": .string("dev")]).assertOK()

        let state = try harness.mutation(try harness.run("state"))
        let screen = try XCTUnwrap(state["screens"]?.arrayValue?.first?.objectValue)
        let workspaces = try XCTUnwrap(screen["workspaces"]?.arrayValue)
        XCTAssertEqual(workspaces[1]["title"]?.stringValue, "dev")
        XCTAssertNil(workspaces[0]["title"], "an unnamed workspace omits the field entirely")

        let list = try harness.mutation(try harness.run("list", args: ["what": .string("workspaces")]))
        XCTAssertEqual(list["workspaces"]?.arrayValue?[1]["title"]?.stringValue, "dev")
    }

    /// A rename reports the **existing** `workspace.changed` (carrying title); it does not invent a new
    /// event type.
    func testRenameEmitsWorkspaceChanged() throws {
        let since = harness.seq
        try harness.run("workspace.set", target: ":2", args: ["title": .string("dev")]).assertOK()
        harness.spin(0.3)
        let events = harness.events(since: since)
            .filter { $0.type == ControlEventType.workspaceChanged.rawValue && $0.workspace == 2 }
        let renamed = try XCTUnwrap(events.first, "a rename must emit one workspace.changed")
        XCTAssertEqual(renamed.title, "dev")
        XCTAssertNil(renamed.redacted, "the user typed it themselves, so it is not redacted")
    }

    // MARK: A name belongs to the slot

    /// Clearing a workspace (closing every pane in it) leaves the name in place: that is exactly what "the
    /// name names the slot" means.
    func testClearingAWorkspaceKeepsItsName() throws {
        let controller = try harness.controller
        controller.switchWorkspace(1)
        try harness.newTerminal()
        harness.spin(0.3)
        try harness.run("workspace.set", target: ":2", args: ["title": .string("dev")]).assertOK()

        try harness.run("workspace.clear", target: ":2").assertOK()
        harness.spin(0.4)
        XCTAssertTrue(controller.model.isEmpty(1), "the panes really were closed")
        XCTAssertEqual(try title(of: 2), "dev", "the name does not follow the panes out")
        controller.switchWorkspace(0)
    }

    /// Cmd+Z on a rename has to **actually** put the old name back: undo pastes the whole previous layout
    /// over the current one, and the name has to travel with it.
    func testUndoRestoresThePreviousName() throws {
        try harness.run("workspace.set", target: ":2", args: ["title": .string("before")]).assertOK()
        harness.app.undoManager.removeAllActions()
        let payload = try harness.mutation(try harness.run("workspace.set", target: ":2",
                                                           args: ["title": .string("after")]))
        XCTAssertEqual(payload["undo"]?.stringValue, "Control plane: workspace set")
        harness.app.undoManager.undo()
        harness.spin(0.2)
        XCTAssertEqual(try title(of: 2), "before")
    }

    // MARK: spec

    /// A temporary directory owned by the case (tearDown removes it).
    private func makeDirectory() throws -> String {
        let path = NSTemporaryDirectory() + "quickterm-wstitle-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        temporaries.append(path)
        return URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    private func dump(_ target: String) throws -> String {
        let reply = try harness.run("spec.dump", target: target)
        reply.assertOK()
        let spec = try XCTUnwrap(reply.data?["spec"])
        return String(decoding: try ControlJSON.encoder.encode(spec), as: UTF8.self)
    }

    /// `dump -> apply -> dump` is still a byte-for-byte fixed point, with the name round-tripping inside it.
    func testSpecRoundTripsTheName() throws {
        let controller = try harness.controller
        controller.switchWorkspace(1)
        // Spelling out the directory **is required**: without it a new pane has no cwd until the shell
        // reports one via OSC 7, so one dump would carry a cwd and the other would not. That is a timing
        // artifact, not a fixed-point failure.
        let directory = try makeDirectory()
        try harness.run("pane.new", target: ":2", args: ["cwd": .string(directory)]).assertOK()
        harness.spin(0.5)
        try harness.run("workspace.set", target: ":2", args: ["title": .string("dev")]).assertOK()

        let text = try dump(":2")
        XCTAssertTrue(text.contains("\"title\":\"dev\""), text)

        controller.switchWorkspace(2)
        harness.spin(0.2)
        try harness.run("spec.apply", target: ":3", args: ["spec": .string(text)]).assertOK()
        harness.spin(0.8)
        XCTAssertEqual(try title(of: 3), "dev", "apply wrote the name through as well")
        XCTAssertEqual(try dump(":3"), text, "dump -> apply -> dump must be a fixed point")

        // Neither pane is on the harness's books (one came from pane.new, the other from apply): clean up here.
        for target in [":2", ":3"] { _ = try harness.run("workspace.clear", target: target) }
        harness.spin(0.4)
        controller.switchWorkspace(0)
    }

    /// A spec that never mentions `title` leaves the target workspace's name **alone** (same rule as
    /// visibleColumns).
    func testSpecWithoutTitleLeavesTheNameAlone() throws {
        let controller = try harness.controller
        try harness.run("workspace.set", target: ":3", args: ["title": .string("keep")]).assertOK()
        let spec = "{\"schema\":\"quickterm.workspace/1\",\"columns\":[{\"panes\":[{}]}]}"
        try harness.run("spec.apply", target: ":3",
                        args: ["spec": .string(spec), "replace": .bool(true)]).assertOK()
        harness.spin(0.8)
        XCTAssertFalse(controller.model.isEmpty(2), "the spec really was applied")
        XCTAssertEqual(try title(of: 3), "keep", "--replace swaps every pane and still does not touch the name")

        _ = try harness.run("workspace.clear", target: ":3")
        harness.spin(0.4)
    }

    /// An empty string in the spec clears the name ("absent" and "present but empty" are two different things).
    func testSpecCanClearTheName() throws {
        try harness.run("workspace.set", target: ":3", args: ["title": .string("gone")]).assertOK()
        let spec = "{\"schema\":\"quickterm.workspace/1\",\"title\":\"\",\"columns\":[]}"
        try harness.run("spec.apply", target: ":3",
                        args: ["spec": .string(spec), "replace": .bool(true)]).assertOK()
        harness.spin(0.4)
        XCTAssertNil(try title(of: 3))
    }

    /// The spec is validated by the same ruler as the command: control characters are rejected on the spot.
    func testSpecValidationRejectsControlCharacters() throws {
        let spec = "{\"schema\":\"quickterm.workspace/1\",\"title\":\"a\\u0007b\",\"columns\":[]}"
        let reply = try harness.run("spec.validate", args: ["spec": .string(spec)])
        XCTAssertFalse(reply.ok)
        XCTAssertEqual(reply.error?.code, ControlErrorCode.badRequest.rawValue)
    }

    // MARK: Archiving

    /// Save -> read back -> restore onto a real screen: the names come back with their slots.
    func testNamesSurviveASaveAndRestore() throws {
        let app = try XCTUnwrap(NSApp.delegate as? AppDelegate)
        let controller = try harness.controller
        let source = controller.newSurface(workingDirectory: nil)
        let saved = WindowState(
            layouts: [.scrolling(ScrollingStrip(pane: source, widthFactor: 0.5)), .empty],
            floatings: [[], []], activeIndex: 0, workspaceTitles: ["dev", "日志"],
            visibleColumns: 2)
        let data = try JSONEncoder().encode(PersistedState(windows: [saved], keyWindowID: saved.id))
        let decoded = try XCTUnwrap(SessionStore.decode(data)).windows[0]
        XCTAssertEqual(decoded.workspaceTitles?.first, "dev", "the names made it into the archive")

        let restored = app.newScreen(on: NSScreen.main, restoring: true, id: decoded.id)
        defer {
            if app.controllers.contains(where: { $0 === restored }) { app.closeScreen(restored) }
            controller.window?.makeKeyAndOrderFront(nil)
            harness.spin(0.3)
        }
        XCTAssertTrue(restored.restore(from: decoded))
        harness.spin(0.3)
        XCTAssertEqual(restored.model.title(at: 0), "dev")
        XCTAssertEqual(restored.model.title(at: 1), "日志")
        XCTAssertEqual(restored.windowState().workspaceTitles?.compactMap { $0 }, ["dev", "日志"],
                       "saving again yields the same two names")
    }

    /// A screen where nothing was ever named omits the field: in most archives it would only be a run of nulls.
    func testArchiveOmitsTheFieldWhenNothingIsNamed() throws {
        let controller = try harness.controller
        XCTAssertNil(controller.windowState().workspaceTitles)
        controller.model.setTitle("dev", at: 0)
        XCTAssertNotNil(controller.windowState().workspaceTitles)
    }
}

private extension ControlReply {
    func assertOK(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(ok, "command failed: \(String(describing: error))", file: file, line: line)
    }
}
