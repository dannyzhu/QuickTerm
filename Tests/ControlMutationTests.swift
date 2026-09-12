import XCTest
@testable import QuickTerm

/// The **cross-cutting** rules of Phase 2: idempotence, --dry-run, --fail-if-noop, the modal
/// guard, rate limiting, undo, visibility. None of these belongs to one command; they are one
/// control flow every mutating command shares — which is why they are pinned by walking the
/// command table wherever possible: add a command and forget the rules, and the case goes red.
@MainActor
final class ControlMutationTests: XCTestCase {
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

    // MARK: Idempotence (the entire point of an absolute set)

    /// Every setter runs twice: the second run has to change nothing and exit 7 under
    /// `--fail-if-noop`. An agent cannot see the state and will retry — a setter that is not
    /// idempotent undoes itself on the second call
    func testEverySetterIsIdempotent() throws {
        let controller = try harness.controller
        let pane = try harness.newTerminal()
        let handle = ControlHandleRegistry.shared.handle(for: pane)
        let workspace = controller.model.activeIndex + 1

        // The visible-column count is written to UserDefaults (the test host shares one with the
        // user's app), so it has to be handed back when we are done
        let originalColumns = controller.visibleColumns
        defer { controller.setVisibleColumns(originalColumns) }
        let wantedColumns = originalColumns == 3 ? 4 : 3

        let cases: [(cmd: String, target: String?, args: [String: JSONValue])] = [
            ("pane.set", handle, ["zoom": .string("on")]),
            ("pane.set", handle, ["zoom": .string("off")]),
            ("pane.set", handle, ["width": .double(0.5)]),
            ("pane.focus", handle, [:]),
            ("workspace.goto", ":\(workspace)", ["index": .int(workspace)]),
            ("workspace.set-layout", ":\(workspace)", ["layout": .string("dwindle")]),
            ("workspace.set-layout", ":\(workspace)", ["layout": .string("scrolling")]),
            ("workspace.equalize", ":\(workspace)", [:]),
            // One round to set the name and one to clear it: the first run of the second case
            // hands the name back rather than leaving it for later cases
            ("workspace.set", ":\(workspace)", ["title": .string("idempotent")]),
            ("workspace.set", ":\(workspace)", ["title": .string("")]),
            ("screen.set", "1", ["visible-columns": .int(wantedColumns)]),
            ("screen.set", "1", ["join-all-spaces": .string("off")]),
            ("app.set", nil, ["key": .string("gaps"), "value": .string("off")]),
            ("app.set", nil, ["key": .string("gaps"), "value": .string("on")]),
            ("screen.focus", "1", [:]),
        ]

        for (cmd, target, args) in cases {
            let first = try harness.mutation(try harness.run(cmd, target: target, args: args))
            XCTAssertEqual(first["command"]?.stringValue, cmd)
            harness.spin(0.15)

            // The second run: same input, nothing should change
            let second = try harness.mutation(try harness.run(cmd, target: target, args: args))
            XCTAssertEqual(second["changed"]?.boolValue, false,
                           "\(cmd) \(args) still reports a change on the second run -- it is not an absolute set")
            XCTAssertEqual(second["applied"]?.boolValue, false, cmd)
            XCTAssertEqual(second["changes"]?.arrayValue?.count ?? 0, 0, cmd)

            // The third run with --fail-if-noop: exit code 7, not a silent success
            var strict = args
            strict[ControlCommandTable.Flag.failIfNoop] = .bool(true)
            let third = try harness.run(cmd, target: target, args: strict)
            XCTAssertFalse(third.ok, "\(cmd) --fail-if-noop should fail")
            XCTAssertEqual(third.error?.code, ControlErrorCode.noop.rawValue, cmd)
            XCTAssertEqual(third.error?.exit, ControlExit.noop.rawValue, cmd)
        }
    }

    /// `--fail-if-noop` only errors when **nothing actually changed**; the first run still
    /// exits 0
    func testFailIfNoopDoesNotFireOnARealChange() throws {
        let pane = try harness.newTerminal()
        let handle = ControlHandleRegistry.shared.handle(for: pane)
        let reply = try harness.run("pane.set", target: handle,
                                    args: ["zoom": .string("on"),
                                           ControlCommandTable.Flag.failIfNoop: .bool(true)])
        XCTAssertTrue(reply.ok, "\(String(describing: reply.error))")
        _ = try harness.run("pane.set", target: handle, args: ["zoom": .string("off")])
    }

    // MARK: --dry-run

    /// `--dry-run` must not change **a single byte** (compared byte for byte through the
    /// persistence serialisation), while still reporting the diff faithfully — it is the only way
    /// an agent can check itself before doing the real thing
    func testDryRunReportsTheDiffAndMutatesNothing() throws {
        let controller = try harness.controller
        let pane = try harness.newTerminal()
        let handle = ControlHandleRegistry.shared.handle(for: pane)
        harness.spin(0.2)

        // Actually widen a column first: otherwise "everything is already equal" holds and the
        // dry run of equalize produces no diff at all
        _ = try harness.run("pane.resize", target: handle, args: ["width": .string("+0.05")])
        harness.spin(0.2)

        let cases: [(String, String?, [String: JSONValue])] = [
            ("pane.set", handle, ["zoom": .string("on"), "width": .double(0.6)]),
            ("pane.new", nil, ["kind": .string("terminal")]),
            ("workspace.set-layout", nil, ["layout": .string("dwindle")]),
            ("workspace.equalize", nil, [:]),
            ("pane.resize", handle, ["width": .string("+0.05")]),
        ]
        for (cmd, target, args) in cases {
            let before = try harness.fingerprint(controller)
            let paneCount = controller.model.allPanes.count
            var dry = args
            dry[ControlCommandTable.Flag.dryRun] = .bool(true)
            let payload = try harness.mutation(try harness.run(cmd, target: target, args: dry))
            harness.spin(0.15)

            XCTAssertEqual(payload["dryRun"]?.boolValue, true, cmd)
            XCTAssertEqual(payload["applied"]?.boolValue, false, cmd)
            XCTAssertEqual(payload["changed"]?.boolValue, true, "\(cmd) should report what it would change")
            XCTAssertFalse(payload["changes"]?.arrayValue?.isEmpty ?? true, "the diff of \(cmd) is empty")
            XCTAssertEqual(try harness.fingerprint(controller), before,
                           "\(cmd) --dry-run modified the model")
            XCTAssertEqual(controller.model.allPanes.count, paneCount,
                           "\(cmd) --dry-run created or closed a pane "
                           + "(a dry run of pane new must never start a real shell)")
        }
    }

    /// --dry-run on a read command means the caller misread the semantics: error out explicitly,
    /// never ignore it silently
    func testDryRunOnAReadCommandIsAnError() throws {
        let reply = try harness.run("state", args: [ControlCommandTable.Flag.dryRun: .bool(true)])
        XCTAssertFalse(reply.ok)
        XCTAssertEqual(reply.error?.code, ControlErrorCode.badRequest.rawValue)
    }

    // MARK: The modal guard (**every** mutating command)

    /// While the user is blocked behind a dialog, **any** mutating command has to be refused.
    /// This walks the command table, so adding a command and forgetting to route it through the
    /// same gate turns the case red. (The finding from the Phase 1 review: back then the gate only
    /// stopped the destructive class.)
    func testModalGuardRefusesEveryMutatingCommand() throws {
        let pane = try harness.newTerminal()
        let handle = ControlHandleRegistry.shared.handle(for: pane)
        // The sensitive commands (send-text / capture-text) are off by default and would be
        // refused (denied) by the "sensitive commands are off" gate first, never reaching the modal
        // gate — and the modal gate is what this case is about, so turn them on. For the same
        // reason every call below carries the origin token: without it capture-text is refused
        // before the modal gate as well
        var config = ControlCommandRunner.Config()
        config.sendText = true
        config.captureText = true
        harness.runner.config = config
        harness.runner.modalBusyProbe = { true }
        defer { harness.runner.modalBusyProbe = { false } }

        var checked = 0
        for spec in ControlCommandTable.commands where spec.cls.isMutation && !spec.local {
            let reply = try harness.run(spec.name, target: spec.acceptsTarget ? handle : nil,
                                        args: Self.minimalArgs(for: spec, handle: handle),
                                        token: ControlEnvironment.token)
            XCTAssertFalse(reply.ok, "\(spec.name) executed while a modal was up")
            XCTAssertEqual(reply.error?.code, ControlErrorCode.busy.rawValue, spec.name)
            XCTAssertEqual(reply.error?.exit, ControlExit.busy.rawValue, spec.name)
            checked += 1
        }
        XCTAssertGreaterThanOrEqual(checked, 16, "there should be well over a dozen mutating commands, got \(checked)")

        // Reads are never affected
        harness.runner.modalBusyProbe = { true }
        XCTAssertTrue(try harness.run("state").ok, "a read-class command must not be held up by a dialog")
    }

    /// The minimal legal arguments for every mutating command in the table (a missing required
    /// argument is caught by argument validation first, and then the modal gate is never reached)
    static func minimalArgs(for spec: ControlCommandSpec, handle: String) -> [String: JSONValue] {
        switch spec.name {
        case "action": return ["name": .string("new-terminal")]
        case "pane.move": return ["to": .string(":2")]
        case "pane.swap": return ["with": .string(handle)]
        case "pane.set": return ["zoom": .string("on")]
        case "pane.resize": return ["width": .string("+0.05")]
        case "workspace.goto": return ["index": .int(1)]
        case "workspace.set-layout": return ["layout": .string("dwindle")]
        case "workspace.count": return ["n": .int(5)]
        case "screen.move": return ["display": .string("1")]
        case "screen.set": return ["visible-columns": .int(2)]
        case "app.set": return ["key": .string("gaps"), "value": .string("on")]
        case "input.send-text": return ["text": .string("echo hi")]
        default: return [:]
        }
    }

    // MARK: Rate limiting

    /// The token bucket itself (a pure value type with an injected clock): it trips, and it
    /// recovers on its own
    func testRateLimiterTripsAndRecovers() {
        var limiter = ControlRateLimiter(now: Date(timeIntervalSince1970: 0))
        let start = Date(timeIntervalSince1970: 0)
        var allowed = 0
        var limited = false
        for i in 0..<200 {
            // Fired within the same millisecond: refill is negligible
            let verdict = limiter.admit(origin: "pane:A", now: start.addingTimeInterval(Double(i) * 0.001))
            switch verdict {
            case .allowed: allowed += 1
            case .limited(let retry, _):
                limited = true
                XCTAssertGreaterThan(retry, 0,
                                     "rate limiting has to hand back a retryAfterMs, otherwise an "
                                     + "agent can only guess")
            }
        }
        XCTAssertTrue(limited, "two hundred calls back to back have to trip it")
        XCTAssertLessThanOrEqual(allowed, Int(ControlRateLimiter.originLimit.capacity) + 2)

        // Wait a while and it should recover
        let later = start.addingTimeInterval(10)
        XCTAssertEqual(limiter.admit(origin: "pane:A", now: later), .allowed, "ten seconds later it has to let one through")

        // A different origin is not dragged down with it
        var fresh = ControlRateLimiter(now: start)
        for _ in 0..<Int(ControlRateLimiter.originLimit.capacity) {
            _ = fresh.admit(origin: "pane:A", now: start)
        }
        XCTAssertEqual(fresh.admit(origin: "pane:B", now: start), .allowed,
                       "the limit is per origin, not across everybody")
    }

    /// End to end: a runaway retry loop gets exit code 6 and a retryAfterMs back, instead of
    /// churning the layout into a mess
    func testRunnerRateLimitsARunawayLoop() throws {
        let pane = try harness.newTerminal()
        let handle = ControlHandleRegistry.shared.handle(for: pane)
        var limitedAt: Int?
        for i in 0..<80 {
            let reply = try harness.run("pane.focus", target: handle)
            if !reply.ok, reply.error?.code == ControlErrorCode.rateLimited.rawValue {
                XCTAssertEqual(reply.error?.exit, ControlExit.busy.rawValue)
                XCTAssertNotNil(reply.error?.retryAfterMs)
                limitedAt = i
                break
            }
        }
        XCTAssertNotNil(limitedAt, "eighty calls back to back never tripped it: the rate limiter is not doing anything")
        harness.runner.rateLimiter.reset()
        XCTAssertTrue(try harness.run("pane.focus", target: handle).ok, "it has to work again after a reset")
    }

    // MARK: Undo

    /// Undo has to **actually** put the state back (registering a name does not count)
    func testUndoActuallyReversesAMutation() throws {
        let controller = try harness.controller
        let pane = try harness.newTerminal()
        _ = try harness.newTerminal()   // Column widths only mean something with two panes
        harness.spin(0.3)
        let handle = ControlHandleRegistry.shared.handle(for: pane)
        let workspace = controller.model.activeIndex
        let before = try XCTUnwrap(controller.controlColumnWidth(of: pane, workspace: workspace))

        harness.app.undoManager.removeAllActions()
        let payload = try harness.mutation(try harness.run("pane.set", target: handle,
                                                           args: ["width": .double(0.75)]))
        XCTAssertEqual(payload["undo"]?.stringValue, "Control plane: pane set",
                       "a mutation has to register an undo entry, otherwise Cmd+Z cannot "
                       + "take back what an agent did")
        XCTAssertEqual(controller.controlColumnWidth(of: pane, workspace: workspace) ?? 0, 0.75,
                       accuracy: 0.001)
        XCTAssertTrue(harness.app.undoManager.canUndo)

        harness.app.undoManager.undo()
        harness.spin(0.2)
        XCTAssertEqual(controller.controlColumnWidth(of: pane, workspace: workspace) ?? 0, before,
                       accuracy: 0.001, "the column width has to be back at its old value after an undo")
        XCTAssertTrue(harness.app.undoManager.canRedo, "redo has to be available after an undo")
    }

    /// **Closing a pane invalidates the entire control-plane undo stack.**
    ///
    /// The layouts / floatings inside a snapshot hold a strong reference to every `PaneView`, and
    /// closing relies entirely on dropping the last reference to trigger `SurfaceView.deinit`.
    /// Keeping the snapshot means the closed shell never exits, and Cmd+Z can shove a pane that has
    /// already run its one-shot `paneWillClose()` straight back into the layout
    func testClosingAPaneInvalidatesTheUndoStack() throws {
        let controller = try harness.controller
        let keeper = try harness.newTerminal()
        let victim = try harness.newTerminal()
        harness.spin(0.3)
        harness.app.undoManager.removeAllActions()

        _ = try harness.mutation(try harness.run(
            "pane.set", target: ControlHandleRegistry.shared.handle(for: keeper),
            args: ["width": .double(0.6)]))
        XCTAssertTrue(harness.app.undoManager.canUndo, "precondition: this step was undoable to begin with")

        controller.closePane(victim, confirmIfNeeded: false, animated: false)
        controller.flushPendingCloses()
        harness.spin(0.3)
        XCTAssertFalse(harness.app.undoManager.canUndo,
                       "once a pane is closed, the undo snapshot pinning it has to be "
                       + "invalidated (or its shell never exits)")

        harness.app.undoManager.undo()
        harness.spin(0.3)
        XCTAssertFalse(controller.model.allPanes.contains { $0 === victim },
                       "Cmd+Z must never put an already-closed pane back into the layout")
    }

    /// Closing a screen ends the processes inside it: a screen a control command has touched still
    /// has to be released in full. (While an undo snapshot pins all of its SurfaceViews, the
    /// surfaces are never released and the shells never exit.)
    func testUndoSnapshotsDoNotPinAClosedScreensPanes() throws {
        weak var weakSecond: MainWindowController?
        weak var weakPane: PaneView?
        try autoreleasepool {
            let second = harness.app.newScreen(on: NSScreen.main)
            harness.spin(0.5)
            weakSecond = second
            let pane = try XCTUnwrap(second.paneList.first, "the new screen should hold one pane")
            weakPane = pane
            // Run an **undoable** command against this screen: now the undo stack holds a
            // snapshot containing every pane it has
            let payload = try harness.mutation(try harness.run(
                "pane.set", target: ControlHandleRegistry.shared.handle(for: pane),
                args: ["width": .double(0.6)]))
            XCTAssertEqual(payload["undo"]?.stringValue, "Control plane: pane set",
                           "precondition: this step registered an undo entry")
            harness.app.closeScreen(second)
        }
        harness.spin(1.0)
        XCTAssertNil(weakSecond, "a screen a control command modified still has to be released in full")
        XCTAssertNil(weakPane, "an undo snapshot must never keep a closed screen's shell alive")
        try harness.controller.window?.makeKeyAndOrderFront(nil)
        harness.spin(0.2)
    }

    /// Undo works by writing the whole layout back, which swaps out the pane set along with it.
    /// So if the pane set has moved since (the user opened a pane themselves) the whole entry has
    /// to be **dropped** — otherwise those new panes are wiped out silently, with not one piece of
    /// cleanup running (a browser pane's downloads are never cancelled, a file manager's temp files
    /// are never deleted)
    func testUndoIsRefusedWhenThePaneSetChangedSince() throws {
        let controller = try harness.controller
        let pane = try harness.newTerminal()
        harness.spin(0.3)
        harness.app.undoManager.removeAllActions()
        let handle = ControlHandleRegistry.shared.handle(for: pane)
        let before = try XCTUnwrap(controller.controlColumnWidth(of: pane,
                                                                workspace: controller.model.activeIndex))
        _ = try harness.mutation(try harness.run("pane.set", target: handle,
                                                 args: ["width": .double(0.75)]))
        XCTAssertTrue(harness.app.undoManager.canUndo)

        // The user opened another pane themselves
        let fresh = try harness.newTerminal()
        harness.spin(0.3)

        harness.app.undoManager.undo()
        harness.spin(0.3)
        XCTAssertTrue(controller.model.allPanes.contains { $0 === fresh },
                      "an undo must never wipe out panes created after the mutation")
        XCTAssertNotEqual(controller.controlColumnWidth(of: pane,
                                                        workspace: controller.model.activeIndex) ?? 0,
                          before, accuracy: 0.0001,
                          "the layout set has moved: this undo should be dropped whole, not rolled back halfway")
    }

    /// Undoing `pane new` means closing the pane that was just created, and that has to go through
    /// the **close** semantics (`removeFromAnyWorkspace`: a browser pane cancels its downloads, a
    /// file manager deletes its temp files). Letting it simply vanish out of layouts leaks a
    /// terminal
    func testUndoOfPaneNewClosesTheCreatedPane() throws {
        let controller = try harness.controller
        _ = try harness.newTerminal()
        harness.spin(0.3)
        harness.app.undoManager.removeAllActions()
        let existing = Set(controller.model.allPanes.map(\.id))

        let payload = try harness.mutation(try harness.run("pane.new", args: ["kind": .string("terminal")]))
        XCTAssertEqual(payload["undo"]?.stringValue, "Control plane: pane new")
        harness.spin(0.4)
        let created = try XCTUnwrap(controller.model.allPanes.first { !existing.contains($0.id) })
        harness.track(created)

        harness.app.undoManager.undo()
        harness.spin(0.4)
        XCTAssertFalse(controller.model.allPanes.contains { $0 === created },
                       "after undoing pane new that pane should really be gone")
        XCTAssertEqual(Set(controller.model.allPanes.map(\.id)), existing,
                       "and only that one: not one of the other panes may go missing")
        XCTAssertFalse(harness.app.undoManager.canRedo,
                       "the undo closed the pane, so no redo entry that would shove it back may be left behind")
    }

    // MARK: A failed apply is not a mutation

    /// A command that fails inside `apply` **counts for nothing**: seq does not move, nothing goes
    /// on the undo stack, and the activity log must not record it as applied. (A floating pane is
    /// not in the tiled layer, so `pane swap` is guaranteed to fail — the shortest repro there
    /// is.)
    func testFailedApplyIsNotCountedAsAMutation() throws {
        let a = try harness.newTerminal()
        let b = try harness.newTerminal()
        harness.spin(0.3)
        _ = try harness.mutation(try harness.run(
            "pane.set", target: ControlHandleRegistry.shared.handle(for: b),
            args: ["float": .string("on")]))
        harness.spin(0.3)

        harness.app.undoManager.removeAllActions()
        ControlActivityLog.shared.clear()
        try harness.controller.model.controlFlash = nil
        let seqBefore = harness.runner.seq

        let reply = try harness.run("pane.swap",
                                    target: ControlHandleRegistry.shared.handle(for: a),
                                    args: ["with": .string(ControlHandleRegistry.shared.handle(for: b))])
        XCTAssertFalse(reply.ok, "a floating pane cannot be swapped")
        XCTAssertEqual(reply.error?.code, ControlErrorCode.failed.rawValue)
        XCTAssertEqual(harness.runner.seq, seqBefore,
                       "a command that never landed must not advance seq (agents use it to tell "
                       + "whether a snapshot is stale)")
        XCTAssertFalse(harness.app.undoManager.canUndo,
                       "a command that never landed must not push anything onto the undo stack")
        XCTAssertNil(try harness.controller.model.controlFlash,
                     "a command that never landed must not flash the status bar")
        let entry = try XCTUnwrap(ControlActivityLog.shared.recent(1).first)
        XCTAssertEqual(entry.command, "pane.swap")
        XCTAssertNotEqual(entry.outcome, "applied", "the activity log recorded a failure as applied")

        _ = try harness.run("pane.set", target: ControlHandleRegistry.shared.handle(for: b),
                            args: ["float": .string("off")])
        harness.spin(0.3)
    }

    /// Closing a pane registers **no** undo entry: the process has already been ended, and putting
    /// the layout back would only create the illusion that it is still there
    func testClosingDoesNotRegisterUndo() throws {
        let pane = try harness.newTerminal()
        let handle = ControlHandleRegistry.shared.handle(for: pane)
        harness.app.undoManager.removeAllActions()
        let payload = try harness.mutation(try harness.run("pane.close", target: handle,
                                                           args: ["force": .bool(true)]))
        XCTAssertNil(payload["undo"], "closing a pane must never pretend to be undoable")
        XCTAssertFalse(harness.app.undoManager.canUndo)
    }

    // MARK: Visibility (the status-bar flash and the activity log)

    /// A `mutate` command may run silently only **on condition** that it is visible afterwards
    func testMutationFlashesTheStatusBarAndIsLogged() throws {
        let controller = try harness.controller
        let pane = try harness.newTerminal()
        let handle = ControlHandleRegistry.shared.handle(for: pane)
        controller.model.controlFlash = nil
        ControlActivityLog.shared.clear()

        _ = try harness.mutation(try harness.run("pane.set", target: handle,
                                                 args: ["zoom": .string("on")]))
        let flash = try XCTUnwrap(controller.model.controlFlash,
                                  "the status bar did not flash: the mutation was completely silent")
        XCTAssertTrue(flash.text.contains("pane.set"), "the flash text has to name the command, got \(flash.text)")

        let entry = try XCTUnwrap(ControlActivityLog.shared.recent(1).first)
        XCTAssertEqual(entry.command, "pane.set")
        XCTAssertEqual(entry.outcome, "applied")
        XCTAssertTrue(entry.peer.contains("xctest"),
                      "the log has to record the peer identity the kernel handed us, got \(entry.peer)")
        XCTAssertFalse(entry.changes.isEmpty, "the log entry has to carry the diff")

        _ = try harness.run("pane.set", target: handle, args: ["zoom": .string("off")])
    }

    /// A no-op is logged too (an agent's "but I thought I changed it" has to be checkable) but
    /// **does not flash the status bar** — nothing happened, so nothing should take the user's
    /// attention
    func testNoopIsLoggedButNotFlashed() throws {
        let controller = try harness.controller
        let pane = try harness.newTerminal()
        let handle = ControlHandleRegistry.shared.handle(for: pane)
        _ = try harness.run("pane.set", target: handle, args: ["zoom": .string("off")])
        harness.spin(0.1)
        controller.model.controlFlash = nil
        ControlActivityLog.shared.clear()

        _ = try harness.mutation(try harness.run("pane.set", target: handle,
                                                 args: ["zoom": .string("off")]))
        XCTAssertNil(controller.model.controlFlash)
        XCTAssertEqual(ControlActivityLog.shared.recent(1).first?.outcome, "noop")
    }

    // MARK: The command table is self-consistent (the Phase 5 MCP tool table leans on it too)

    /// The `idempotent` flag on every command has to match whether it really is an absolute set,
    /// and the wire name / CLI spelling / group all have to come from the same source
    func testCommandTableIsSelfConsistent() {
        for spec in ControlCommandTable.commands {
            if let group = spec.group {
                XCTAssertEqual(spec.name, "\(group).\(spec.verb)")
                XCTAssertEqual(spec.cli, "\(group) \(spec.verb)")
            } else {
                XCTAssertEqual(spec.name, spec.verb)
                XCTAssertEqual(spec.cli, spec.verb)
            }
            XCTAssertNotNil(ControlCommandTable.command(spec.cli),
                            "the command-line spelling \(spec.cli) has to look up the very same command")
            XCTAssertFalse(spec.examples.isEmpty,
                           "\(spec.name) has no examples: a model copying an example is far more "
                           + "reliable than one reading prose")
        }
        // Every "set"-flavoured verb is an idempotent absolute set
        for spec in ControlCommandTable.commands where ["set", "set-layout", "goto", "equalize", "focus"].contains(spec.verb) {
            XCTAssertTrue(spec.idempotent, "\(spec.name) is a setter and has to be marked idempotent")
        }
    }
}
