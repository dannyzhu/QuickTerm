import XCTest
@testable import QuickTerm

/// The **semantics** of the individual Phase 2 commands: where a pane lands, moving across
/// workspaces and across screens, setting the layout of a workspace that is not active, rewriting
/// the config. The cross-cutting rules (idempotence / dry-run / rate limiting / undo) live in
/// `ControlMutationTests`.
@MainActor
final class ControlPaneCommandTests: XCTestCase {
    private var harness: ControlHarness!

    override func setUpWithError() throws {
        try super.setUpWithError()
        harness = try ControlHarness()
        try harness.controller.model.switchTo(0)
    }

    override func tearDown() {
        harness?.cleanup()
        harness = nil
        super.tearDown()
    }

    private func handle(_ pane: PaneView) -> String { ControlHandleRegistry.shared.handle(for: pane) }

    private func newPane(_ args: [String: JSONValue], target: String? = nil) throws -> PaneView {
        let controller = try harness.controller
        let before = Set(controller.model.allPanes.map(\.id))
        let payload = try harness.mutation(try harness.run("pane.new", target: target, args: args))
        XCTAssertEqual(payload["applied"]?.boolValue, true)
        harness.spin(0.35)
        let pane = try XCTUnwrap(harness.app.screens.allPanes.first { !before.contains($0.id) },
                                 "pane new did not create a pane")
        harness.track(pane)
        XCTAssertEqual(payload["pane"]?["handle"]?.stringValue, handle(pane),
                       "the echoed handle has to point at the pane that was just created")
        return pane
    }

    // MARK: pane new

    /// `--cmd` has to turn `closesOnChildExit` on: the engine forces wait-after-command on a
    /// surface that carries a command and never closes it itself, so without taking that over the
    /// pane sits there frozen forever once the command finishes
    func testPaneNewWithCommandWiresChildExitBehaviour() throws {
        let withCommand = try newPane(["cmd": .string("true"), "cwd": .string(NSTemporaryDirectory())])
        let surface = try XCTUnwrap(withCommand as? Ghostty.SurfaceView)
        XCTAssertTrue(surface.closesOnChildExit, "a pane created by --cmd closes itself when the child process exits")

        let held = try newPane(["cmd": .string("true"), "hold": .bool(true)])
        let heldSurface = try XCTUnwrap(held as? Ghostty.SurfaceView)
        XCTAssertFalse(heldSurface.closesOnChildExit, "--hold explicitly asks for the pane to stay after the command exits")

        let plain = try newPane([:])
        let plainSurface = try XCTUnwrap(plain as? Ghostty.SurfaceView)
        XCTAssertFalse(plainSurface.closesOnChildExit, "an ordinary interactive shell must not be taken over")
    }

    /// `--cwd` lands on the new surface (both persistence and "a new terminal inherits the
    /// directory" read it)
    func testPaneNewHonoursCwd() throws {
        let dir = NSTemporaryDirectory()
        let pane = try newPane(["cwd": .string(dir)])
        let surface = try XCTUnwrap(pane as? Ghostty.SurfaceView)
        harness.spin(0.4)
        let pwd = try XCTUnwrap(surface.workingDirectory)
        XCTAssertTrue(dir.hasPrefix(pwd) || pwd.hasPrefix(dir) || pwd.contains("/T/"),
                      "cwd should be \(dir), got \(pwd)")
    }

    /// `--at/--where` maps onto the **drag-and-drop** placement semantics (in scrolling, left
    /// means the column to the left of the anchor)
    func testPaneNewAtWhereMapsOntoTheDropPaths() throws {
        let controller = try harness.controller
        let anchor = try harness.newTerminal()
        harness.spin(0.3)
        guard case .scrolling(let strip0) = controller.model.layout,
              let anchorColumn = strip0.position(of: anchor)?.col else {
            return XCTFail("precondition: the active workspace is scrolling and the anchor is in it")
        }

        let left = try newPane(["at": .string(handle(anchor)), "where": .string("left")])
        guard case .scrolling(let strip1) = controller.model.layout else { return XCTFail("the layout changed") }
        let leftColumn = try XCTUnwrap(strip1.position(of: left)?.col)
        let anchorNow = try XCTUnwrap(strip1.position(of: anchor)?.col)
        XCTAssertEqual(leftColumn, anchorNow - 1, "--where left has to land in the column left of the anchor")
        XCTAssertEqual(leftColumn, anchorColumn, "inserting on the left shifts the anchor one column to the right")

        let stacked = try newPane(["at": .string(handle(anchor)), "where": .string("stack")])
        guard case .scrolling(let strip2) = controller.model.layout else { return XCTFail("the layout changed") }
        let stackedPos = try XCTUnwrap(strip2.position(of: stacked))
        let anchorPos = try XCTUnwrap(strip2.position(of: anchor))
        XCTAssertEqual(stackedPos.col, anchorPos.col, "--where stack has to merge into the anchor's column")
        XCTAssertEqual(stackedPos.row, anchorPos.row + 1, "stack means one row below the anchor")
    }

    /// In a dwindle workspace, `--where` goes through the very same SplitTree dropping code
    func testPaneNewAtWhereInDwindle() throws {
        let controller = try harness.controller
        let anchor = try harness.newTerminal()
        _ = try harness.mutation(try harness.run("workspace.set-layout", args: ["layout": .string("dwindle")]))
        harness.spin(0.3)
        guard case .dwindle = controller.model.layout else { return XCTFail("precondition: dwindle") }

        let pane = try newPane(["at": .string(handle(anchor)), "where": .string("down")])
        guard case .dwindle(let tree) = controller.model.layout else { return XCTFail("the layout changed") }
        XCTAssertNotNil(tree.root?.node(view: pane), "the new pane has to be in the tree")
        XCTAssertNotNil(tree.root?.node(view: anchor), "and the anchor is still there")
        _ = try harness.run("workspace.set-layout", args: ["layout": .string("scrolling")])
    }

    /// `--kind file-manager` goes through the same construction as `perform(.fileManager)`: role
    /// reports file-manager, it closes on exit, and the session is registered (so closing no longer
    /// raises the running-process confirmation)
    func testPaneNewFileManagerRegistersTheSession() throws {
        let controller = try harness.controller
        let pane = try newPane(["kind": .string("file-manager"), "cwd": .string(NSTemporaryDirectory())])
        XCTAssertEqual(controller.controlRole(of: pane), "file-manager",
                       "a file-manager pane still has kind terminal; role is what tells them apart")
        let surface = try XCTUnwrap(pane as? Ghostty.SurfaceView)
        XCTAssertTrue(surface.closesOnChildExit)
    }

    /// `--kind browser` creates a real browser pane (and does not run the old "insert into the
    /// active layout" path twice)
    func testPaneNewBrowser() throws {
        let pane = try newPane(["kind": .string("browser"), "url": .string("http://127.0.0.1:1/")])
        XCTAssertTrue(pane is BrowserPaneView)
        XCTAssertEqual(pane.kind, .browser)
        XCTAssertTrue(handle(pane).hasPrefix("b"), "a browser pane handle is prefixed with b, got \(handle(pane))")
    }

    /// `--url` only means something for a browser pane: getting it wrong has to be an explicit
    /// error, not a silent no-op
    func testPaneNewRejectsMismatchedArguments() throws {
        let bad = try harness.run("pane.new", args: ["url": .string("https://example.com")])
        XCTAssertFalse(bad.ok)
        XCTAssertEqual(bad.error?.code, ControlErrorCode.badRequest.rawValue)

        let badEnv = try harness.run("pane.new", args: ["env": .array([.string("NOPE")])])
        XCTAssertFalse(badEnv.ok)
        XCTAssertEqual(badEnv.error?.code, ControlErrorCode.badRequest.rawValue)
    }

    // MARK: set-layout (on a workspace that is not active)

    /// **This is the headline of Phase 2**: `toggle-layout` can only act on the active workspace,
    /// while `set-layout` names the workspace it sets — and it must not lose a pane on the way
    func testSetLayoutWorksOnANonActiveWorkspaceAndKeepsPanes() throws {
        let controller = try harness.controller
        try XCTSkipUnless(controller.model.layouts.count >= 3, "this case needs at least three workspaces")
        let active = controller.model.activeIndex
        let other = (active + 1) % controller.model.layouts.count

        // Put two panes into a workspace that is not active (created right there: pane new -t :N)
        let first = try newPane([:], target: ":\(other + 1)")
        let second = try newPane(["at": .string(handle(first))], target: ":\(other + 1)")
        XCTAssertEqual(controller.model.activeIndex, active,
                       "creating a pane in another workspace must not switch the active workspace away")
        XCTAssertEqual(controller.model.layouts[other].paneList.count, 2)

        let payload = try harness.mutation(try harness.run("workspace.set-layout",
                                                           target: ":\(other + 1)",
                                                           args: ["layout": .string("dwindle")]))
        XCTAssertEqual(payload["applied"]?.boolValue, true)
        XCTAssertEqual(controller.model.layouts[other].name, "dwindle")
        XCTAssertEqual(controller.model.activeIndex, active,
                       "setting another workspace's layout must never switch to it on the way "
                       + "(an agent assumes the focus did not move)")
        XCTAssertEqual(Set(controller.model.layouts[other].paneList.map(\.id)),
                       Set([first.id, second.id]), "the conversion has to preserve every pane")
        XCTAssertEqual(controller.model.layouts[active].name, "scrolling", "the active workspace is untouched")

        // Convert back: the panes are still there, and in the same order
        _ = try harness.run("workspace.set-layout", target: ":\(other + 1)",
                            args: ["layout": .string("scrolling")])
        XCTAssertEqual(controller.model.layouts[other].paneList.map(\.id), [first.id, second.id])
    }

    // MARK: move / swap

    /// Moving across workspaces: the pane stays alive, lands in the destination workspace, and the
    /// view **does not follow** by default
    func testMoveAcrossWorkspacesKeepsThePaneAliveAndDoesNotFollowByDefault() throws {
        let controller = try harness.controller
        try XCTSkipUnless(controller.model.layouts.count >= 2, "this case needs at least two workspaces")
        let pane = try harness.newTerminal()
        harness.spin(0.3)
        let active = controller.model.activeIndex
        let destination = (active + 1) % controller.model.layouts.count

        let payload = try harness.mutation(try harness.run("pane.move", target: handle(pane),
                                                           args: ["to": .string(":\(destination + 1)")]))
        harness.spin(0.25)
        XCTAssertEqual(payload["applied"]?.boolValue, true)
        XCTAssertEqual(controller.model.activeIndex, active, "no follow by default")
        XCTAssertTrue(controller.model.layouts[destination].paneList.contains { $0 === pane },
                      "the pane has to be in the destination workspace")
        XCTAssertFalse(controller.model.layouts[active].paneList.contains { $0 === pane },
                       "the source workspace must not still be holding it")
        XCTAssertFalse(pane.id.uuidString.isEmpty, "the pane is still alive")
        XCTAssertNotNil(payload["note"]?.stringValue, "without follow, it has to say where the pane went")

        // Move it back, following this time
        _ = try harness.mutation(try harness.run("pane.move", target: handle(pane),
                                                 args: ["to": .string(":\(active + 1)"),
                                                        "follow": .bool(true)]))
        harness.spin(0.3)
        XCTAssertEqual(controller.model.activeIndex, active)
        XCTAssertTrue(controller.model.layouts[active].paneList.contains { $0 === pane })
    }

    /// Moving across **screens**: the app had no path for this at all before
    func testMoveAcrossScreensReparentsThePane() throws {
        let app = harness.app
        let primary = try harness.controller
        let pane = try harness.newTerminal()
        harness.spin(0.3)
        let second = app.newScreen(on: NSScreen.main)
        harness.spin(0.4)
        defer {
            if app.controllers.contains(where: { $0 === second }) {
                app.closeScreen(second, confirmed: true)
            }
            primary.window?.makeKeyAndOrderFront(nil)
            harness.spin(0.3)
        }
        let screenNumber = second.screenIndex + 1

        let payload = try harness.mutation(try harness.run(
            "pane.move", target: handle(pane),
            args: ["to": .string("\(screenNumber):1"), "follow": .bool(true)]))
        harness.spin(0.4)
        XCTAssertEqual(payload["applied"]?.boolValue, true)
        XCTAssertTrue(second.model.allPanes.contains { $0 === pane }, "the pane has to land on the second screen")
        XCTAssertFalse(primary.model.allPanes.contains { $0 === pane }, "the source screen must not still be holding it")
        XCTAssertEqual(payload["pane"]?["screen"]?.intValue, screenNumber, "the echo has to report the new screen number")

        // Move it back, otherwise closing the second screen takes the pane with it
        _ = try harness.mutation(try harness.run("pane.move", target: handle(pane),
                                                 args: ["to": .string("1:1"), "follow": .bool(true)]))
        harness.spin(0.4)
        XCTAssertTrue(primary.model.allPanes.contains { $0 === pane })
    }

    /// Swap the positions of two panes (by name, without moving the focus there first)
    func testSwapExchangesPositions() throws {
        let controller = try harness.controller
        let a = try harness.newTerminal()
        let b = try newPane(["at": .string(handle(a))])
        harness.spin(0.3)
        guard case .scrolling(let before) = controller.model.layout,
              let posA = before.position(of: a), let posB = before.position(of: b) else {
            return XCTFail("precondition: both panes are in the scrolling layout")
        }
        _ = try harness.mutation(try harness.run("pane.swap", target: handle(a),
                                                 args: ["with": .string(handle(b))]))
        harness.spin(0.2)
        guard case .scrolling(let after) = controller.model.layout else { return XCTFail("the layout changed") }
        XCTAssertEqual(after.position(of: a)?.col, posB.col, "a should now hold b's position")
        XCTAssertEqual(after.position(of: b)?.col, posA.col, "b should now hold a's position")

        let crossWorkspace = try harness.run("pane.swap", target: handle(a),
                                             args: ["with": .string("@self")])
        XCTAssertFalse(crossWorkspace.ok,
                       "@self does not resolve in the test host, so it has to error out instead of "
                       + "swapping something at random")
    }

    // MARK: resize

    /// `--width +0.05` is **relative**, and at the boundary it becomes a no-op (exit 7) rather
    /// than pretending something changed
    func testResizeIsRelativeAndStopsAtTheBoundary() throws {
        let controller = try harness.controller
        let pane = try harness.newTerminal()
        _ = try newPane(["at": .string(handle(pane))])
        harness.spin(0.3)
        let workspace = controller.model.activeIndex
        let before = try XCTUnwrap(controller.controlColumnWidth(of: pane, workspace: workspace))

        let payload = try harness.mutation(try harness.run("pane.resize", target: handle(pane),
                                                           args: ["width": .string("+0.05")]))
        let after = try XCTUnwrap(controller.controlColumnWidth(of: pane, workspace: workspace))
        XCTAssertEqual(after, before + 0.05, accuracy: 0.001)
        XCTAssertEqual(payload["changes"]?.arrayValue?.count, 1)

        // Once it is pinned at the upper bound (0.90), adding more is a no-op
        for _ in 0..<20 { _ = try harness.run("pane.resize", target: handle(pane), args: ["width": .string("+0.05")]) }
        XCTAssertEqual(controller.controlColumnWidth(of: pane, workspace: workspace) ?? 0,
                       ScrollingStrip.widthRange.upperBound, accuracy: 0.001)
        let noop = try harness.run("pane.resize", target: handle(pane),
                                   args: ["width": .string("+0.05"),
                                          ControlCommandTable.Flag.failIfNoop: .bool(true)])
        XCTAssertEqual(noop.error?.code, ControlErrorCode.noop.rawValue, "at the boundary it has to admit that nothing changed")
    }

    /// An absolute width out of range has to **error out**, never clamp silently (after a clamp
    /// the value an agent reads back does not match the one it wrote)
    func testAbsoluteWidthOutOfRangeIsAnError() throws {
        let pane = try harness.newTerminal()
        let reply = try harness.run("pane.set", target: handle(pane), args: ["width": .double(0.95)])
        XCTAssertFalse(reply.ok)
        XCTAssertEqual(reply.error?.code, ControlErrorCode.badRequest.rawValue)
        XCTAssertTrue(reply.error?.message.contains("0.9") ?? false, "the error message has to spell out the legal range")
    }

    // MARK: workspace count (rewrites config.toml)

    /// `workspace count N` rewrites the config file and **leaves applying it to the existing
    /// config watcher**: it must not apply the value itself (applying twice rebuilds the keymap
    /// twice and races the watcher)
    func testWorkspaceCountRewritesConfigAndDoesNotDoubleApply() throws {
        let controller = try harness.controller
        let temporary = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("qt-config-\(UUID().uuidString.prefix(8)).toml")
        try ConfigStore.template.write(to: temporary, atomically: true, encoding: .utf8)
        ConfigStore.configURLOverride = temporary
        defer {
            ConfigStore.configURLOverride = nil
            try? FileManager.default.removeItem(at: temporary)
        }
        let before = controller.model.layouts.count

        let payload = try harness.mutation(try harness.run("workspace.count", args: ["n": .int(7)]))
        XCTAssertEqual(payload["applied"]?.boolValue, true)
        let text = try String(contentsOf: temporary, encoding: .utf8)
        XCTAssertTrue(text.contains("workspaces = 7"), "the new count has to land in the config file:\n\(text)")
        XCTAssertFalse(text.contains("# workspaces = 5"), "the commented-out line it replaces should be gone")
        XCTAssertEqual(ConfigStore.parse(text).workspaces, 7, "whatever it writes has to parse back through our own parser")
        XCTAssertEqual(controller.model.layouts.count, before,
                       "the command does not apply the value itself: that is the config watcher's "
                       + "job (applying twice fights the watcher)")
        XCTAssertNotNil(payload["note"]?.stringValue, "the caller has to be told it takes effect a moment later")

        // Out-of-range and shrink protection
        let tooMany = try harness.run("workspace.count", args: ["n": .int(11)])
        XCTAssertEqual(tooMany.error?.code, ControlErrorCode.badRequest.rawValue)
    }

    // MARK: The edges of target resolution

    /// A pane that is fading out is not addressable; pending closes are flushed before a command
    /// runs
    func testClosingPanesAreNotAddressable() throws {
        let controller = try harness.controller
        let pane = try harness.newTerminal()
        let name = handle(pane)
        controller.closeAnimationEnabled = true
        controller.closePane(pane, confirmIfNeeded: false, animated: true)
        XCTAssertTrue(controller.model.closingPanes.contains(pane.id), "precondition: the fade-out is running")
        let reply = try harness.run("pane.set", target: name, args: ["zoom": .string("on")])
        XCTAssertFalse(reply.ok, "a pane that is fading out must not still be modifiable")
        XCTAssertEqual(reply.error?.exit, ControlExit.badTarget.rawValue)
        harness.spin(0.4)
    }

    /// A destructive command goes through the consent gate; a denial does nothing at all
    func testPaneCloseNeedsConsent() throws {
        let controller = try harness.controller
        let pane = try harness.newTerminal()
        harness.consent.reset()
        harness.consent.decisionStub = { _, reply in reply(.deny) }
        let denied = try harness.run("pane.close", target: handle(pane), args: ["force": .bool(true)])
        XCTAssertFalse(denied.ok)
        XCTAssertEqual(denied.error?.exit, ControlExit.denied.rawValue)
        XCTAssertTrue(controller.model.allPanes.contains { $0 === pane }, "a denial does nothing")

        harness.consent.reset()
        harness.consent.decisionStub = { _, reply in reply(.allow) }
        _ = try harness.mutation(try harness.run("pane.close", target: handle(pane),
                                                 args: ["force": .bool(true)]))
        harness.spin(0.4)
        XCTAssertFalse(controller.model.allPanes.contains { $0 === pane }, "once confirmed, it really closes")
    }

    /// `action` is the keyboard-shortcut parity path straight through to `perform()`: it cannot
    /// compute a diff, and there is no such thing as a dry run for it. Accepting `--dry-run`
    /// silently costs twice over — a "dry run" that actually strikes, and a flag that switches off
    /// the consent gate for destructive actions along the way
    func testDryRunOnAnActionIsRefusedAndDoesNothing() throws {
        let controller = try harness.controller
        let pane = try harness.newTerminal()
        harness.spin(0.3)
        controller.requestFocus(to: pane)
        harness.spin(0.3)
        var asked = 0
        harness.consent.reset()
        harness.consent.decisionStub = { _, reply in
            asked += 1
            reply(.allow)
        }
        for flag in [ControlCommandTable.Flag.dryRun, ControlCommandTable.Flag.failIfNoop] {
            let reply = try harness.run("action", args: ["name": .string("close-pane"), flag: .bool(true)])
            XCTAssertFalse(reply.ok, "action must not accept \(flag)")
            XCTAssertEqual(reply.error?.code, ControlErrorCode.badRequest.rawValue, flag)
            XCTAssertEqual(asked, 0, "a refused command must not disturb the user")
            XCTAssertTrue(controller.model.allPanes.contains { $0 === pane },
                          "\(flag) must never let a destructive action skip the consent gate "
                              + "and strike for real")
        }
        harness.spin(0.3)
    }

    // MARK: The floating layer versus properties that live inside the tiled layer

    /// zoom / column width / split ratio are all properties **inside the tiled layer**. Setting
    /// them on a floating pane has to be an explicit error: writing them silently leaves two read
    /// paths contradicting each other (the write side says on, `state` says off) and an agent never
    /// converges
    func testTiledOnlySettersRefuseAFloatingPane() throws {
        let controller = try harness.controller
        let anchor = try harness.newTerminal()
        let pane = try harness.newTerminal()
        harness.spin(0.3)
        let name = handle(pane)
        _ = try harness.mutation(try harness.run("pane.set", target: name, args: ["float": .string("on")]))
        harness.spin(0.3)
        XCTAssertTrue(controller.controlIsFloating(pane, workspace: controller.model.activeIndex),
                      "precondition: it is floating right now")

        for args in [["zoom": JSONValue.string("on")], ["width": JSONValue.double(0.4)]] {
            let reply = try harness.run("pane.set", target: name, args: args)
            XCTAssertFalse(reply.ok, "\(args) on a floating pane should be an explicit error, not a silent no-op")
            XCTAssertEqual(reply.error?.code, ControlErrorCode.badRequest.rawValue, "\(args)")
        }
        XCTAssertFalse(controller.controlIsZoomed(pane, workspace: controller.model.activeIndex),
                       "a refused --zoom must not leave a dangling zoomedID behind")
        XCTAssertFalse(controller.controlIsZoomed(anchor, workspace: controller.model.activeIndex),
                       "and it certainly must not knock out somebody else's real zoom")

        // Within one command, drop back into the tiled layer first and then set the in-layer
        // properties: the order has to be float -> zoom / width
        let payload = try harness.mutation(try harness.run(
            "pane.set", target: name,
            args: ["float": .string("off"), "zoom": .string("on"), "width": .double(0.4)]))
        XCTAssertEqual(payload["applied"]?.boolValue, true)
        harness.spin(0.3)
        XCTAssertFalse(controller.controlIsFloating(pane, workspace: controller.model.activeIndex))
        XCTAssertTrue(controller.controlIsZoomed(pane, workspace: controller.model.activeIndex),
                      "a zoom set before the pane is put back into the tiled layer is "
                      + "cleared by the insert -- the order is wrong")
        XCTAssertEqual(controller.controlColumnWidth(of: pane, workspace: controller.model.activeIndex) ?? 0,
                       0.4, accuracy: 0.001, "same for the column width")
        _ = try harness.run("pane.set", target: name, args: ["zoom": .string("off")])
        harness.spin(0.2)
    }

    /// `workspace clear` really has to empty the workspace, and it reports only the panes that
    /// **actually closed**. (If QuickTerm's own per-pane confirmation comes up, this run closes
    /// nothing at all while the payload still reports applied.)
    func testWorkspaceClearReallyClearsAndReportsWhatItClosed() throws {
        let controller = try harness.controller
        // Do it in the **empty** workspace 2: clearing workspace 1 would take the app's own
        // starter pane with it, leaving later cases without an addressable focused pane
        let index = 1
        defer { controller.switchWorkspace(0) }
        let a = try harness.newTerminal(in: index)
        let b = try harness.newTerminal(in: index)
        harness.spin(0.3)
        XCTAssertEqual(controller.model.activeIndex, index,
                       "precondition: what is cleared is the **active** workspace "
                       + "(which goes down the closePane path)")
        let live = controller.model.layouts[index].paneList.count
        XCTAssertGreaterThanOrEqual(live, 2, "precondition: this workspace has something to clear")

        let payload = try harness.mutation(try harness.run("workspace.clear", target: ":\(index + 1)"))
        harness.spin(0.4)
        XCTAssertEqual(payload["applied"]?.boolValue, true)
        XCTAssertNil(payload["confirmPending"], "it landed in one pass, so nothing may report a pending confirmation")
        XCTAssertEqual(payload["panes"]?.arrayValue?.count, live, "what is reported is exactly what was really closed")
        XCTAssertTrue(controller.model.layouts[index].paneList.isEmpty, "the workspace has to be genuinely empty")
        XCTAssertTrue(controller.model.floatings[index].isEmpty)
        XCTAssertFalse(controller.model.allPanes.contains { $0 === a || $0 === b })
    }

    /// A destructive command under `--dry-run` **does not ask the user** (it is not going to do
    /// anything), and it must certainly not close anything for real
    func testDestructiveDryRunNeitherPromptsNorCloses() throws {
        let controller = try harness.controller
        let pane = try harness.newTerminal()
        var asked = 0
        harness.consent.reset()
        harness.consent.decisionStub = { _, reply in
            asked += 1
            reply(.allow)
        }
        let payload = try harness.mutation(try harness.run(
            "pane.close", target: handle(pane),
            args: [ControlCommandTable.Flag.dryRun: .bool(true)]))
        XCTAssertEqual(asked, 0, "a dry run must not disturb the user")
        XCTAssertEqual(payload["applied"]?.boolValue, false)
        XCTAssertTrue(controller.model.allPanes.contains { $0 === pane }, "a dry run must never really close it")
    }

    // MARK: pane set --title (naming a pane)

    /// **An absolute set that is also addressable**: once the name is set, `-t 'title:~...'` finds
    /// the pane; running the same command twice does nothing the second time; and an empty string
    /// hands the title back to the shell
    func testPaneSetTitleIsAbsoluteAndAnEmptyValueGivesItBackToTheShell() throws {
        let pane = try harness.newTerminal()
        let surface = try XCTUnwrap(pane as? Ghostty.SurfaceView)
        harness.spin(0.4)
        let shellTitle = surface.paneTitle
        let wanted = "qt-title-\(UUID().uuidString.prefix(6))"

        // 1. Set it: the state side reads it immediately (no waiting on the debounce timer)
        let set = try harness.mutation(try harness.run("pane.set", target: handle(pane),
                                                        args: ["title": .string(wanted)]))
        XCTAssertEqual(set["applied"]?.boolValue, true)
        XCTAssertEqual(set["pane"]?["title"]?.stringValue, wanted)
        XCTAssertEqual(surface.paneTitle, wanted)
        XCTAssertTrue(surface.hasControlTitle)

        // 2. Set it a second time: a no-op (--fail-if-noop exits 7)
        let again = try harness.mutation(try harness.run("pane.set", target: handle(pane),
                                                          args: ["title": .string(wanted)]))
        XCTAssertEqual(again["changed"]?.boolValue, false)
        let noop = try harness.run("pane.set", target: handle(pane),
                                   args: ["title": .string(wanted),
                                          ControlCommandTable.Flag.failIfNoop: .bool(true)])
        XCTAssertFalse(noop.ok)
        XCTAssertEqual(noop.error?.code, ControlErrorCode.noop.rawValue)

        // 3. Once set, the pane can be addressed by title (which is the whole reason this command
        // exists)
        let found = try harness.run("get", target: "title:~\(wanted)")
        XCTAssertTrue(found.ok, "\(String(describing: found.error))")
        XCTAssertEqual(found.data?["pane"]?["handle"]?.stringValue, handle(pane))

        // 4. `--dry-run` does not change a character
        let dry = try harness.mutation(try harness.run(
            "pane.set", target: handle(pane),
            args: ["title": .string("nope"), ControlCommandTable.Flag.dryRun: .bool(true)]))
        XCTAssertEqual(dry["applied"]?.boolValue, false)
        XCTAssertEqual(surface.paneTitle, wanted)

        // 5. An empty string hands the title back to the shell (it does **not** set an empty
        // title)
        let cleared = try harness.mutation(try harness.run("pane.set", target: handle(pane),
                                                            args: ["title": .string("")]))
        XCTAssertEqual(cleared["applied"]?.boolValue, true)
        XCTAssertFalse(surface.hasControlTitle, "the title goes back into the engine's hands")
        XCTAssertNotEqual(surface.paneTitle, wanted)
        XCTAssertEqual(surface.paneTitle, shellTitle.isEmpty ? "👻" : shellTitle)
        // It already belongs to the shell: clearing it again is a no-op
        let clearedAgain = try harness.mutation(try harness.run("pane.set", target: handle(pane),
                                                                 args: ["title": .string("")]))
        XCTAssertEqual(clearedAgain["changed"]?.boolValue, false)
    }

    /// Titles belong to terminal panes only (a browser pane's title comes from the page), and
    /// control characters or an over-long string are always refused
    func testPaneSetTitleRefusesWhatItCannotHonour() throws {
        let pane = try harness.newTerminal()
        for bad in [String(repeating: "x", count: ControlCommandRunner.maxTitleLength + 1), "a\u{1B}[31m"] {
            let reply = try harness.run("pane.set", target: handle(pane), args: ["title": .string(bad)])
            XCTAssertFalse(reply.ok, "a title like this should be refused")
            XCTAssertEqual(reply.error?.code, ControlErrorCode.badRequest.rawValue)
        }
        let browser = try newPane(["kind": .string("browser"), "url": .string("http://127.0.0.1:1/")])
        let wrongKind = try harness.run("pane.set", target: handle(browser),
                                        args: ["title": .string("nope")])
        XCTAssertFalse(wrongKind.ok)
        XCTAssertEqual(wrongKind.error?.code, ControlErrorCode.wrongPaneKind.rawValue)
    }

    /// **The test is whether the title has been taken over, not whether it happens to look the
    /// same.**
    /// Regression: when the title the shell reports is exactly the one being set (using a directory
    /// name as the pane name is very common), a literal comparison turns the call into a no-op —
    /// `setControlTitle` is never invoked, the title is not pinned, the shell's next title report
    /// replaces it, and the caller was told success
    func testSettingTheTitleToWhatTheShellAlreadyReportsStillPinsIt() throws {
        let pane = try harness.newTerminal()
        let surface = try XCTUnwrap(pane as? Ghostty.SurfaceView)
        let reported = "qt-shell-\(UUID().uuidString.prefix(6))"
        surface.setTitle(reported)               // The path the engine reports on (75ms debounce)
        harness.spin(0.2)
        XCTAssertEqual(surface.paneTitle, reported)
        XCTAssertFalse(surface.hasControlTitle, "precondition: the title is still in the shell's hands at this point")

        let set = try harness.mutation(try harness.run("pane.set", target: handle(pane),
                                                        args: ["title": .string(reported)]))
        XCTAssertEqual(set["applied"]?.boolValue, true, "the text matches, but there is real work to do this time: pinning it")
        XCTAssertTrue(surface.hasControlTitle)

        // Pinned means exactly this: whatever the shell reports next cannot overwrite it
        surface.setTitle("something-else")
        harness.spin(0.2)
        XCTAssertEqual(surface.paneTitle, reported, "once pinned, a shell report must not change the visible title")

        // Setting the same title again after it is pinned is the no-op (the absolute-set rule
        // still holds)
        let again = try harness.run("pane.set", target: handle(pane),
                                    args: ["title": .string(reported),
                                           ControlCommandTable.Flag.failIfNoop: .bool(true)])
        XCTAssertFalse(again.ok)
        XCTAssertEqual(again.error?.code, ControlErrorCode.noop.rawValue)
    }

    /// A terminal title shows up in the activity log, and that log is mirrored into OSLog (which
    /// outlives the app). Titles routinely carry the cwd or the command line that is running: the
    /// in-app panel records it in full, the system log keeps only the path
    func testTerminalTitlesNeverReachTheSystemLog() throws {
        let pane = try harness.newTerminal()
        let secret = "qt-secret-\(UUID().uuidString.prefix(6))"
        ControlActivityLog.shared.clear()
        _ = try harness.run("pane.set", target: handle(pane), args: ["title": .string(secret)])
        let entry = try XCTUnwrap(ControlActivityLog.shared.recent(1).first)
        XCTAssertTrue(entry.line.contains(secret), "the in-app panel still records it in full")
        XCTAssertFalse(entry.logLine.contains(secret), "the OSLog copy may not carry the title: \(entry.logLine)")

        // The `open "<title>"` that pane close records is the same story (for a browser pane that
        // is the page title)
        ControlActivityLog.shared.clear()
        harness.consent.decisionStub = { _, reply in reply(.allow) }
        _ = try harness.run("pane.close", target: handle(pane), args: ["force": .bool(true)])
        harness.spin(0.3)
        let closed = try XCTUnwrap(ControlActivityLog.shared.recent(1).first)
        XCTAssertFalse(closed.logLine.contains(secret), "the pane close entry may not either: \(closed.logLine)")
    }

    // MARK: --cwd refused by the privacy gate (**say so**, do not swallow it)

    /// A protected directory (~/Downloads and friends) cannot be handed to the engine without
    /// authorisation, so the shell starts in the default directory instead. That fact **has to
    /// appear in the reply** — an unremarkable ok is exactly where "the pane opened and the
    /// directory did not change" comes from. The gate's prober is injected, so the case does not
    /// depend on this machine's real TCC state
    func testARefusedWorkingDirectoryIsReportedAsAWarning() throws {
        let denied = "\(NSHomeDirectory())/Downloads"
        WorkingDirectoryGate.resetForTesting()
        WorkingDirectoryGate.prober = { root, _ in !root.hasSuffix("/Downloads") }
        defer { WorkingDirectoryGate.resetForTesting() }

        let payload = try harness.mutation(try harness.run("pane.new", args: ["cwd": .string(denied)]))
        harness.spin(0.35)
        if let made = harness.app.screens.allPanes.first(where: {
            ControlHandleRegistry.shared.handle(for: $0) == payload["pane"]?["handle"]?.stringValue
        }) {
            harness.track(made)
            XCTAssertNotEqual((made as? Ghostty.SurfaceView)?.pwd, denied,
                              "a refused directory must never be planted into pwd -- that would "
                              + "have state assert something instantly falsifiable")
        }
        let warning = try XCTUnwrap(payload["warnings"]?.arrayValue?.first?.objectValue,
                                    "a refused --cwd has to come back with a warning")
        XCTAssertEqual(warning["code"]?.stringValue, ControlWarning.cwdDenied,
                       "machines branch on the code, not by matching prose")
        XCTAssertEqual(warning["path"]?.stringValue, denied)
        XCTAssertTrue(warning["message"]?.stringValue?.contains(denied) ?? false)
        XCTAssertTrue(warning["hint"]?.stringValue?.contains("--require-cwd") ?? false,
                      "point the way: how to spell it if you want an outright failure")
        XCTAssertEqual(payload["applied"]?.boolValue, true, "the pane opened all the same (this is not a failure)")

        // The other side: a directory that was not refused carries no warning at all
        let fine = try harness.mutation(try harness.run("pane.new",
                                                        args: ["cwd": .string(NSTemporaryDirectory())]))
        harness.spin(0.35)
        if let made = harness.app.screens.allPanes.first(where: {
            ControlHandleRegistry.shared.handle(for: $0) == fine["pane"]?["handle"]?.stringValue
        }) {
            harness.track(made)
        }
        XCTAssertNil(fine["warnings"], "a usable directory must not carry a warning")
    }

    /// `--require-cwd`: if the directory cannot be used, **error out** and create no pane at
    /// all
    func testRequireCwdTurnsTheRefusalIntoAnError() throws {
        let denied = "\(NSHomeDirectory())/Documents"
        WorkingDirectoryGate.resetForTesting()
        WorkingDirectoryGate.prober = { root, _ in !root.hasSuffix("/Documents") }
        defer { WorkingDirectoryGate.resetForTesting() }

        let controller = try harness.controller
        let before = controller.model.allPanes.count
        let reply = try harness.run("pane.new", args: ["cwd": .string(denied),
                                                        "require-cwd": .bool(true)])
        XCTAssertFalse(reply.ok)
        XCTAssertEqual(reply.error?.code, ControlErrorCode.denied.rawValue)
        XCTAssertEqual(reply.error?.exit, ControlExit.denied.rawValue)
        XCTAssertTrue(reply.error?.message.contains(denied) ?? false)
        harness.spin(0.3)
        XCTAssertEqual(controller.model.allPanes.count, before, "the call that failed must not have created a single pane")

        // When the directory is usable, --require-cwd changes nothing
        let ok = try harness.mutation(try harness.run("pane.new",
                                                      args: ["cwd": .string(NSTemporaryDirectory()),
                                                             "require-cwd": .bool(true)]))
        harness.spin(0.35)
        if let made = harness.app.screens.allPanes.first(where: {
            ControlHandleRegistry.shared.handle(for: $0) == ok["pane"]?["handle"]?.stringValue
        }) {
            harness.track(made)
        }
        XCTAssertEqual(ok["applied"]?.boolValue, true)
        XCTAssertNil(ok["warnings"])
    }


    /// **A browser pane does not consume `--cwd` at all.**
    /// Regression: the warning and `--require-cwd` used to look at the path alone, so
    /// `pane new --kind browser --cwd ~/Downloads` came back saying "the shell started in the
    /// default directory" (there is no shell in there), and adding `--require-cwd` turned a
    /// perfectly ordinary pane creation into exit code 5. Any script that always passes
    /// `--cwd "$PWD"` runs into it the moment the current directory happens to be a protected
    /// one
    func testAProtectedCwdIsIrrelevantToBrowserPanes() throws {
        let denied = "\(NSHomeDirectory())/Downloads"
        WorkingDirectoryGate.resetForTesting()
        WorkingDirectoryGate.prober = { root, _ in !root.hasSuffix("/Downloads") }
        defer { WorkingDirectoryGate.resetForTesting() }

        let payload = try harness.mutation(try harness.run("pane.new", args: [
            "kind": .string("browser"), "url": .string("http://127.0.0.1:1/"),
            "cwd": .string(denied), "require-cwd": .bool(true),
        ]))
        harness.spin(0.35)
        if let made = harness.app.screens.allPanes.first(where: {
            ControlHandleRegistry.shared.handle(for: $0) == payload["pane"]?["handle"]?.stringValue
        }) {
            harness.track(made)
        }
        XCTAssertEqual(payload["applied"]?.boolValue, true, "--require-cwd must not block a pane that has no use for a cwd")
        XCTAssertNil(payload["warnings"], "with no shell in the picture there is no such thing as an unused directory")
    }
}
