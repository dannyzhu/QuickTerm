import XCTest
@testable import QuickTerm

/// The **landing** half of Phase 3: `spec dump` / `spec apply` against live screens.
///
/// The headline case is the `dump -> apply -> dump` **fixed point**: a dumped spec applied to a
/// different workspace and dumped again has to come out byte for byte identical. That single case
/// covers both directions of the projection pair, default expansion, the round trip of column
/// widths / zoom / focus, and the fact that apply does not guess at some approximation of the
/// layout the spec describes.
///
/// Every case builds its scenario in an **empty workspace** (`:2` / `:3`) and never touches the
/// starter pane in workspace 1 — otherwise the pane count of each case depends on which case
/// happened to run first.
@MainActor
final class ControlSpecApplyTests: XCTestCase {
    private var harness: ControlHarness!
    private var temporaries: [String] = []
    /// Workspaces a case touched: tearDown clears every one of them (panes created by spec apply
    /// are not on the harness's books)
    private var touched: Set<Int> = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        harness = try ControlHarness()
        let controller = try harness.controller
        try XCTSkipUnless(controller.model.layouts.count >= 3, "this group needs three workspaces")
        // Every case starts from an empty scrolling workspace: once a previous case has set :2 to
        // dwindle, the next case's fixed point inexplicably runs against a tree (cases never share
        // layout state)
        for index in [1, 2] {
            _ = controller.controlClearWorkspace(index, confirmIfNeeded: false)
            _ = controller.model.setLayout("scrolling", at: index, columnFactor: controller.columnFactor)
        }
        controller.switchWorkspace(1)
        harness.spin(0.2)
    }

    override func tearDown() {
        let controller = try? harness?.controller
        for index in touched.sorted() {
            _ = controller?.controlClearWorkspace(index, confirmIfNeeded: false)
        }
        harness?.cleanup()
        if let controller {
            controller.switchWorkspace(0)
            if controller.model.allPanes.isEmpty { controller.ensureStarterPane() }
            harness?.spin(0.3)
        }
        for path in temporaries { try? FileManager.default.removeItem(atPath: path) }
        temporaries = []
        touched = []
        harness = nil
        super.tearDown()
    }

    // MARK: Fixtures

    private func makeDirectory(_ name: String) throws -> String {
        let path = NSTemporaryDirectory() + "quickterm-spec-\(name)-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        temporaries.append(path)
        return URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    /// The body of a `spec dump` — exactly what gets written to a file and fed back into apply
    private func dump(_ target: String?, args: [String: JSONValue] = [:],
                      file: StaticString = #filePath, line: UInt = #line) throws -> String {
        let reply = try harness.run("spec.dump", target: target, args: args)
        XCTAssertTrue(reply.ok, "dump failed: \(String(describing: reply.error))", file: file, line: line)
        let spec = try XCTUnwrap(reply.data?["spec"], "dump produced no spec", file: file, line: line)
        return String(decoding: try ControlJSON.encoder.encode(spec), as: UTF8.self)
    }

    @discardableResult
    private func apply(_ text: String, target: String?, mode: String? = nil,
                       extra: [String: JSONValue] = [:]) throws -> ControlReply {
        var args: [String: JSONValue] = ["spec": .string(text)]
        if let mode { args[mode] = .bool(true) }
        for (key, value) in extra { args[key] = value }
        return try harness.run("spec.apply", target: target, args: args)
    }

    @discardableResult
    private func newPane(_ args: [String: JSONValue], target: String? = nil) throws -> PaneView {
        let before = Set(harness.app.screens.allPanes.map(\.id))
        let reply = try harness.run("pane.new", target: target, args: args)
        XCTAssertTrue(reply.ok, "pane new failed: \(String(describing: reply.error))")
        harness.spin(0.35)
        let pane = try XCTUnwrap(harness.app.screens.allPanes.first { !before.contains($0.id) })
        harness.track(pane)
        return pane
    }

    private func panes(_ workspace: Int) throws -> [PaneView] {
        let controller = try harness.controller
        return controller.model.layouts[workspace].paneList
            + controller.model.floatings[workspace].map(\.pane)
    }

    private func handle(_ pane: PaneView) -> String { ControlHandleRegistry.shared.handle(for: pane) }

    // MARK: The headline: the fixed point

    /// scrolling: a dump applied to a different (empty) workspace and dumped again has to come out
    /// byte for byte identical. Applying it **to a different workspace** is deliberate: applying it
    /// back where it came from takes the "identical spec = no-op" path, and that path proves
    /// nothing about apply being able to build the layout from nothing
    func testDumpApplyDumpIsAFixedPointForScrolling() throws {
        let controller = try harness.controller
        touched.formUnion([1, 2])
        let a = try makeDirectory("a")
        let b = try makeDirectory("b")
        let first = try newPane(["cwd": .string(a)])
        _ = try newPane(["cwd": .string(b), "at": .string(handle(first)), "where": .string("stack")])
        _ = try newPane(["cwd": .string(a)])
        _ = try harness.run("pane.set", target: handle(first), args: ["width": .double(0.35)])
        harness.spin(0.5)

        let before = try dump(":2")
        XCTAssertTrue(before.contains("\"columns\""), before)
        XCTAssertTrue(before.contains("0.35"), "the column width has to reach the spec: \(before)")
        let sourceCount = try panes(1).count

        controller.switchWorkspace(2)
        harness.spin(0.3)
        try apply(before, target: ":3").assertOK()
        harness.spin(0.8)

        XCTAssertEqual(try panes(2).count, sourceCount, "the number of panes that landed has to match")
        XCTAssertEqual(try dump(":3"), before, "dump -> apply -> dump has to be a fixed point")
    }

    /// dwindle: the same fixed point through a different layout engine (split directions and
    /// ratios both have to round-trip)
    func testDumpApplyDumpIsAFixedPointForDwindle() throws {
        let controller = try harness.controller
        touched.formUnion([1, 2])
        _ = try harness.run("workspace.set-layout", target: ":2", args: ["layout": .string("dwindle")])
        let a = try makeDirectory("d1")
        let b = try makeDirectory("d2")
        _ = try newPane(["cwd": .string(a)])
        let second = try newPane(["cwd": .string(b)])
        _ = try harness.run("pane.set", target: handle(second), args: ["ratio": .double(0.4)])
        harness.spin(0.5)

        let before = try dump(":2")
        XCTAssertTrue(before.contains("\"tree\""), before)
        XCTAssertTrue(before.contains("\"ratio\""), before)

        controller.switchWorkspace(2)
        harness.spin(0.3)
        try apply(before, target: ":3").assertOK()
        harness.spin(0.8)

        XCTAssertEqual(controller.model.layouts[2].name, "dwindle", "apply has to carry the layout across as well")
        XCTAssertEqual(try dump(":3"), before, "the dwindle fixed point")
    }

    /// A two-line spec: every default is filled in (kind=terminal, the width from the
    /// visible-columns-per-screen setting, cwd inherited from the anchor)
    func testMinimalSpecAppliesWithEveryDefaultFilledIn() throws {
        let controller = try harness.controller
        touched.insert(1)
        try apply(#"{"columns":[{"panes":[{}]},{"panes":[{},{}]}]}"#, target: ":2").assertOK()
        harness.spin(0.6)

        guard case .scrolling(let strip) = controller.model.layouts[1] else {
            return XCTFail("the default layout should be scrolling")
        }
        XCTAssertEqual(strip.columns.map(\.panes.count), [1, 2])
        for column in strip.columns {
            XCTAssertEqual(column.widthFactor, controller.columnFactor, accuracy: 0.0005,
                           "no width means the current visible-columns-per-screen value")
        }
        XCTAssertTrue(strip.paneList.allSatisfy { $0 is Ghostty.SurfaceView }, "no kind means a terminal")
    }

    // MARK: --dry-run

    /// `--dry-run` **does not change a byte**, measured against a byte-level fingerprint taken
    /// through the persistence path
    func testDryRunMutatesNothing() throws {
        let controller = try harness.controller
        touched.insert(1)
        let before = try harness.fingerprint(controller)
        let reply = try apply(#"{"columns":[{"panes":[{}]},{"panes":[{}]}]}"#, target: ":2",
                              extra: [ControlCommandTable.Flag.dryRun: .bool(true)])
        let payload = try harness.mutation(reply)
        XCTAssertEqual(payload["applied"]?.boolValue, false)
        XCTAssertEqual(payload["changed"]?.boolValue, true)
        XCTAssertFalse((payload["changes"]?.arrayValue ?? []).isEmpty, "a dry run has to produce a readable diff")
        harness.spin(0.3)
        XCTAssertEqual(try harness.fingerprint(controller), before, "the model has to be identical after a --dry-run")
        XCTAssertTrue(try panes(1).isEmpty, "a dry run may not create a pane")
    }

    // MARK: The three modes

    /// `--into-empty` is the default mode and it **cannot destroy anything**: a non-empty target
    /// is always refused (exit code 4)
    func testIntoEmptyRefusesANonEmptyWorkspace() throws {
        touched.insert(1)
        _ = try newPane([:])
        harness.spin(0.3)
        let reply = try apply(#"{"columns":[{"panes":[{}]}]}"#, target: ":2")
        XCTAssertFalse(reply.ok)
        let error = try XCTUnwrap(reply.error)
        XCTAssertEqual(error.code, ControlErrorCode.confirmationRequired.rawValue)
        XCTAssertEqual(error.exit, ControlExit.confirmationRequired.rawValue)
        XCTAssertTrue((error.hint ?? "").contains("--replace"), "it has to tell the caller where to go: \(error.hint ?? "")")
        XCTAssertEqual(try panes(1).count, 1, "the call that was refused may not have moved anything")
    }

    /// Panes displaced by `--replace` have to go through the **real close path**.
    /// A browser pane is the litmus test for that rule: replace it by assignment and
    /// `paneWillClose()` never runs, so downloads are not cancelled and extensions never hear that
    /// the window closed — and no other case would go red
    func testReplaceRoutesDisplacedPanesThroughTheRealClosePath() throws {
        touched.insert(1)
        let browser = try XCTUnwrap(try newPane(["kind": .string("browser"),
                                                 "url": .string("about:blank")]) as? BrowserPaneView)
        harness.spin(0.5)
        XCTAssertFalse(browser.reportedWindowClose, "precondition: cleanup has not run yet")

        let directory = try makeDirectory("replace")
        try apply("{\"columns\":[{\"panes\":[{\"cwd\":\"\(directory)\"}]}]}", target: ":2",
                  mode: "replace").assertOK()
        harness.spin(0.6)

        XCTAssertTrue(browser.reportedWindowClose,
                      "a displaced browser pane has to have run paneWillClose (otherwise downloads "
                      + "and extension window events leak)")
        XCTAssertFalse(try panes(1).contains { $0 === browser }, "it must not still be in the layout")
        XCTAssertEqual(try panes(1).count, 1)
    }

    /// `--reuse` recognizes "this is still the same thing": a running pane stays where it is
    /// instead of being rebuilt
    func testReuseKeepsMatchingPanesAndOnlyRebuildsTheRest() throws {
        touched.insert(1)
        let keepDirectory = try makeDirectory("keep")
        let dropDirectory = try makeDirectory("drop")
        let freshDirectory = try makeDirectory("fresh")
        let keeper = try newPane(["cwd": .string(keepDirectory)])
        let victim = try newPane(["cwd": .string(dropDirectory)])
        harness.spin(0.5)

        let text = """
        {"columns":[{"panes":[{"cwd":"\(keepDirectory)"}]},{"panes":[{"cwd":"\(freshDirectory)"}]}]}
        """
        let payload = try harness.mutation(try apply(text, target: ":2", mode: "reuse"))
        harness.spin(0.6)

        let report = try XCTUnwrap(payload["spec"]?.objectValue, "apply has to produce a landing report")
        XCTAssertEqual(report["mode"]?.stringValue, "reuse")
        let live = try panes(1)
        XCTAssertTrue(live.contains { $0 === keeper }, "a pane that matches has to stay put and must not be rebuilt")
        XCTAssertFalse(live.contains { $0 === victim }, "the one that does not match gets closed")
        XCTAssertEqual((report["reused"]?.arrayValue ?? []).count, 1)
        XCTAssertEqual((report["created"]?.arrayValue ?? []).count, 1)
        XCTAssertEqual((report["closed"]?.arrayValue ?? []).count, 1)
    }

    /// Applying the same spec twice makes the second call a layout no-op (exit 7 under
    /// `--fail-if-noop`), and **not one pane may be rebuilt** — otherwise every retry an agent
    /// makes restarts the dev server
    func testApplyingTheSameSpecTwiceIsALayoutNoop() throws {
        touched.insert(1)
        let directory = try makeDirectory("twice")
        _ = try newPane(["cwd": .string(directory)])
        harness.spin(0.5)
        let text = try dump(":2")
        let identities = try panes(1).map(ObjectIdentifier.init)

        try apply(text, target: ":2", mode: "replace").assertOK()
        harness.spin(0.5)
        XCTAssertEqual(try panes(1).map(ObjectIdentifier.init), identities,
                       "with an identical spec, --replace may not tear things down and rebuild them")

        let again = try apply(text, target: ":2", mode: "replace",
                              extra: [ControlCommandTable.Flag.failIfNoop: .bool(true)])
        XCTAssertFalse(again.ok)
        XCTAssertEqual(again.error?.code, ControlErrorCode.noop.rawValue)
        XCTAssertEqual(again.error?.exit, ControlExit.noop.rawValue)
    }

    // MARK: The shape of a failure

    /// Validation failing means **no pane is created at all**. The directory in the second slot
    /// does not exist, and that is caught before anything is built
    func testASpecThatFailsPreflightCreatesNothing() throws {
        touched.insert(1)
        let good = try makeDirectory("good")
        let reply = try apply(
            "{\"columns\":[{\"panes\":[{\"cwd\":\"\(good)\"}]},{\"panes\":[{\"cwd\":\"/no/such/dir\"}]}]}",
            target: ":2")
        XCTAssertFalse(reply.ok)
        XCTAssertEqual(reply.error?.code, ControlErrorCode.badRequest.rawValue)
        XCTAssertTrue((reply.error?.message ?? "").contains("/no/such/dir"), reply.error?.message ?? "")
        harness.spin(0.3)
        XCTAssertTrue(try panes(1).isEmpty, "a failed preflight must never leave half a workspace behind")
    }

    /// Failing **after** the knife has gone in: the state is coherent (no ghost panes in the
    /// layout) and it reports partial_apply honestly. The injection point is `SpecApplier.fault`
    /// (always nil in production) — there is no other way to reach this path
    func testMidApplyFailureLeavesACoherentStateAndReportsPartial() throws {
        let controller = try harness.controller
        touched.insert(1)
        _ = try newPane([:])
        _ = try newPane([:])
        harness.spin(0.5)
        XCTAssertEqual(try panes(1).count, 2, "precondition: the workspace holds exactly two panes")
        let directory = try makeDirectory("partial")
        guard case .workspace(let spec) = try SpecParser.parse(
            "{\"columns\":[{\"panes\":[{\"cwd\":\"\(directory)\"}]}]}") else {
            return XCTFail("the spec failed to parse")
        }

        let applier = SpecApplier(controller: controller, workspace: 1, spec: spec, mode: .replace)
        applier.fault = { stage in
            guard stage == .tearingDown else { return }
            throw ControlErrorBody(.failed, "injected failure")
        }
        try applier.preflight()
        XCTAssertEqual(applier.displaced.count, 2, "precondition: both panes are going to be displaced")

        XCTAssertThrowsError(try applier.apply()) { error in
            let body = error as? ControlErrorBody
            XCTAssertEqual(body?.code, ControlErrorCode.partialApply.rawValue,
                           "a failure after the knife went in needs its own error code and must "
                           + "never report as \"nothing happened\"")
            XCTAssertTrue((body?.message ?? "").contains("only half applied"), body?.message ?? "")
        }
        harness.spin(0.5)

        // Coherent: every pane left in the layout is alive and addressable, and the half-built one
        // never made it in
        let live = try panes(1)
        XCTAssertEqual(live.count, 1, "the one that was closed really is gone and the rest are untouched")
        XCTAssertTrue(live.allSatisfy { !controller.model.closingPanes.contains($0.id) })
        XCTAssertFalse(live.contains { $0.workingDirectory == directory },
                       "the half-created pane was cleaned up and must never stay in the layout")
        XCTAssertEqual(Set(controller.model.allPanes.map(\.id)).count,
                       controller.model.allPanes.count, "no duplicate references")
    }

    // MARK: Structure

    /// **One assignment**: one apply schedules the debounced save exactly once. Five separate
    /// assignments mean five reflows, five animations and five passes through the Combine sink —
    /// what the user sees is the layout jumping three times while three panes are created
    func testASingleApplyAssignsTheLayoutExactlyOnce() throws {
        let store = try XCTUnwrap(harness.app.session).sessionStore
        touched.insert(1)
        harness.spin(0.4)
        let before = store.scheduleCount
        try apply(#"{"columns":[{"panes":[{}]},{"panes":[{}]},{"panes":[{}]}]}"#, target: ":2").assertOK()
        XCTAssertEqual(store.scheduleCount - before, 1,
                       "three panes, one assignment: compute the whole layout value first, then "
                       + "assign it to model.layouts[i]")
        harness.spin(0.6)
    }

    /// Column identities have to carry over: change `ScrollingStrip.Column.id` and SwiftUI rebuilds
    /// the whole column, detaching and re-attaching the SurfaceViews inside it (a dropped frame, and
    /// the first responder silently reset)
    func testColumnIdentitiesSurviveAReapply() throws {
        let controller = try harness.controller
        touched.insert(1)
        let directory = try makeDirectory("ids")
        _ = try newPane(["cwd": .string(directory)])
        harness.spin(0.5)
        guard case .scrolling(let before) = controller.model.layouts[1] else {
            return XCTFail("precondition: scrolling")
        }
        let text = try dump(":2")
        try apply(text, target: ":2", mode: "reuse").assertOK()
        harness.spin(0.5)
        guard case .scrolling(let after) = controller.model.layouts[1] else {
            return XCTFail("the layout changed")
        }
        XCTAssertEqual(before.columns.map(\.id), after.columns.map(\.id),
                       "a column whose pane set did not change has to keep its original id")
    }

    // MARK: The two envelopes

    /// `quickterm.screen/1` and `quickterm.session/1` reuse the workspace vocabulary verbatim, and
    /// both have to come back unchanged through dump -> apply -> dump
    func testScreenAndSessionWrappersRoundTrip() throws {
        touched.insert(1)
        let directory = try makeDirectory("wrap")
        _ = try newPane(["cwd": .string(directory)])
        harness.spin(0.5)

        let screen = try dump("1")
        XCTAssertTrue(screen.contains(SpecSchema.screen), screen)
        try apply(screen, target: "1", mode: "replace").assertOK()
        harness.spin(0.6)
        XCTAssertEqual(try dump("1"), screen, "the screen envelope round trip")

        let session = try dump(nil, args: ["all": .bool(true)])
        XCTAssertTrue(session.contains(SpecSchema.session), session)
        try apply(session, target: nil, mode: "replace").assertOK()
        harness.spin(0.6)
        XCTAssertEqual(try dump(nil, args: ["all": .bool(true)]), session, "the session envelope round trip")
    }

    /// `spec validate` changes nothing, and it notices that this machine does not have that many
    /// workspaces
    func testValidateChecksWorkspaceCountsAndChangesNothing() throws {
        let controller = try harness.controller
        let before = try harness.fingerprint(controller)
        let ok = try harness.run("spec.validate", args: ["spec": .string(#"{"columns":[{}]}"#)])
        XCTAssertTrue(ok.ok, String(describing: ok.error))
        XCTAssertEqual(ok.data?["valid"]?.boolValue, true)

        let count = controller.model.layouts.count
        let tooMany = try harness.run("spec.validate", args: ["spec": .string(
            "{\"schema\":\"quickterm.screen/1\",\"workspaces\":[{\"index\":\(count + 3)}]}")])
        XCTAssertFalse(tooMany.ok)
        XCTAssertTrue((tooMany.error?.message ?? "").contains("\(count)"),
                      "out of range has to say how many there really are here: \(tooMany.error?.message ?? "")")
        XCTAssertEqual(try harness.fingerprint(controller), before, "validate may not change a thing")
    }

    /// `cmd` / `env` / `hold` are input-only: a dump cannot give back a command that is already
    /// running, and validate has to say so, or an agent will believe it dumped something it can
    /// replay
    func testValidateNotesThatCommandsAreInputOnly() throws {
        let reply = try harness.run("spec.validate", args: ["spec": .string(
            #"{"columns":[{"panes":[{"cmd":"npm run dev"}]}]}"#)])
        XCTAssertTrue(reply.ok)
        let notes = (reply.data?["notes"]?.arrayValue ?? []).compactMap(\.stringValue)
        XCTAssertTrue(notes.contains { $0.contains("cmd") }, "\(notes)")
    }

    // MARK: Regressions: every one of these used to report success while doing nothing

    /// The fixed point has to hold at **every visible-column count**. `setVisibleColumns` divides
    /// the columns evenly into (1-2*peek)/N: 0.2425 at N=4 and 0.97 at N=1, both outside the
    /// 0.25-0.90 of manual resizing — copy that range into the public schema and QuickTerm refuses
    /// to read a file QuickTerm just dumped
    func testFixedPointHoldsAtEveryVisibleColumnCount() throws {
        let controller = try harness.controller
        touched.formUnion([1, 2])
        let restore = controller.visibleColumns
        defer { controller.setVisibleColumns(restore, persist: false) }
        let directory = try makeDirectory("cols")
        _ = try newPane(["cwd": .string(directory)])
        _ = try newPane(["cwd": .string(directory)])
        harness.spin(0.5)

        for count in [4, 1] {
            // Focus only reaches the spec for the **active** workspace, so both dumps have to be
            // taken while their workspace is active — otherwise the difference is about who holds
            // the focus and has nothing to do with column widths
            controller.switchWorkspace(1)
            controller.setVisibleColumns(count, persist: false)
            harness.spin(0.4)
            let text = try dump(":2")
            // Whatever we dump, we have to be able to take back
            let check = try harness.run("spec.validate", args: ["spec": .string(text)])
            XCTAssertTrue(check.ok,
                          "the dump at \(count) columns per screen was refused by our own "
                          + "validator: \(String(describing: check.error))")

            _ = try harness.run("workspace.clear", target: ":3")
            controller.switchWorkspace(2)
            harness.spin(0.4)
            try apply(text, target: ":3").assertOK()
            harness.spin(0.8)
            XCTAssertEqual(try dump(":3"), text, "the fixed point at \(count) columns per screen")
        }
    }

    /// A spec that **only rearranges** (not one pane more or fewer, just regrouped) still has to
    /// land. With an empty diff `commit()` never calls apply at all: the workspace stays exactly as
    /// it was while the caller is told "it already looks like this" — and the agent's belief that
    /// it arranged the layout is wrong from then on
    func testRearrangingTheSamePanesIsNotANoop() throws {
        let controller = try harness.controller
        touched.insert(1)
        let a = try makeDirectory("arr-a")
        let b = try makeDirectory("arr-b")
        _ = try newPane(["cwd": .string(a)])
        _ = try newPane(["cwd": .string(b)])
        harness.spin(0.5)
        guard case .scrolling(let before) = controller.model.layouts[1] else {
            return XCTFail("precondition: two columns with one pane each")
        }
        XCTAssertEqual(before.columns.map(\.panes.count), [1, 1])
        let identities = Set(try panes(1).map(ObjectIdentifier.init))

        // Merge two columns into one: the pane set is identical, only the grouping changed
        let text = "{\"columns\":[{\"panes\":[{\"cwd\":\"\(a)\"},{\"cwd\":\"\(b)\"}]}]}"
        let payload = try harness.mutation(try apply(text, target: ":2", mode: "reuse"))
        XCTAssertEqual(payload["changed"]?.boolValue, true, "a changed arrangement is a change")
        harness.spin(0.6)

        guard case .scrolling(let after) = controller.model.layouts[1] else { return XCTFail("the layout is gone") }
        XCTAssertEqual(after.columns.map(\.panes.count), [2], "the two columns really did merge into one")
        XCTAssertEqual(Set(try panes(1).map(ObjectIdentifier.init)), identities,
                       "merging columns may not rebuild panes (running processes stay where they are)")

        // Applying it once more is the real no-op
        let again = try apply(text, target: ":2", mode: "reuse",
                              extra: [ControlCommandTable.Flag.failIfNoop: .bool(true)])
        XCTAssertFalse(again.ok)
        XCTAssertEqual(again.error?.code, ControlErrorCode.noop.rawValue)
    }

    /// `dump --include-ids` -> edit a cwd -> `apply --replace`: an id says "this exact pane, by
    /// name" and only `--reuse` honors it. Honoring ids in the other modes means every slot matches
    /// by id, the edit is discarded wholesale, and the call reports "it already looks like this"
    func testEditingADumpWithIDsIsNotSwallowedByIDMatching() throws {
        touched.insert(1)
        let from = try makeDirectory("ids-from")
        let to = try makeDirectory("ids-to")
        let original = try newPane(["cwd": .string(from)])
        harness.spin(0.5)
        let text = try dump(":2", args: ["include-ids": .bool(true)])
        XCTAssertTrue(text.contains(original.id.uuidString), "precondition: the dump carries ids")
        let edited = text.replacingOccurrences(of: from, with: to)

        let payload = try harness.mutation(try apply(edited, target: ":2", mode: "replace"))
        XCTAssertEqual(payload["changed"]?.boolValue, true, "an edited spec is not a no-op")
        harness.spin(0.8)
        let live = try panes(1)
        XCTAssertEqual(live.count, 1)
        XCTAssertFalse(live.contains { $0 === original }, "the old pane should be displaced")
        XCTAssertEqual(live.first?.workingDirectory, to, "the new pane lands in the edited directory")
        for pane in live { harness.track(pane) }
    }

    /// The same workspace written twice in one spec is refused **before anything is created**.
    /// Let it through and the second `model.layouts[i] = ...` overwrites the first by assignment,
    /// leaving the panes the first one created in no layout at all and never run through the close
    /// path (downloads, extensions and file-manager sessions all leak)
    func testDuplicateWorkspaceIndicesAreRefusedBeforeAnythingIsCreated() throws {
        touched.insert(1)
        let directory = try makeDirectory("dup")
        let text = """
        {"schema":"quickterm.screen/1","workspaces":[
          {"index":2,"columns":[{"panes":[{"cwd":"\(directory)"}]}]},
          {"index":2,"columns":[{"panes":[{"cwd":"\(directory)"}]}]}]}
        """
        let reply = try apply(text, target: "1", mode: "replace")
        XCTAssertFalse(reply.ok)
        XCTAssertEqual(reply.error?.code, ControlErrorCode.badRequest.rawValue)
        XCTAssertTrue((reply.error?.message ?? "").contains("only appear once"), reply.error?.message ?? "")
        harness.spin(0.4)
        XCTAssertTrue(try panes(1).isEmpty, "the call that was refused may not have created a single pane")
    }

    /// The destructive alert has to state **what this stroke is really going to touch**. A screen
    /// spec overwrites every workspace on that screen, and an alert that names only the one `-t`
    /// points at gets the user to approve something far smaller
    func testConsentNamesEveryWorkspaceAScreenSpecWillOverwrite() throws {
        pinUILanguage(.en)
        let controller = try harness.controller
        touched.insert(1)
        _ = try newPane([:])
        harness.spin(0.4)
        var summaries: [String] = []
        harness.consent.decisionStub = { request, reply in
            summaries.append(request.summary)
            reply(.allow)
        }
        let screen = try dump("1")
        try apply(screen, target: "1", mode: "replace").assertOK()
        harness.spin(0.6)
        let summary = try XCTUnwrap(summaries.first, "the destructive command never went through the consent gate")
        XCTAssertTrue(summary.contains("\(controller.model.layouts.count) workspaces"),
                      "the alert has to say how many workspaces this stroke spans: \(summary)")
    }

    /// An extreme split ratio produced by dragging goes into the spec **faithfully**: clamp it into
    /// 0.1-0.9 and the dump no longer describes this workspace, and applying it back makes the
    /// divider jump on its own (with nothing visible in the diff)
    func testExtremeSplitRatiosRoundTripWithoutClamping() throws {
        let controller = try harness.controller
        touched.formUnion([1, 2])
        _ = try harness.run("workspace.set-layout", target: ":2", args: ["layout": .string("dwindle")])
        // Both leaves pin a cwd: without one, a new pane inherits the **anchor's** directory, and
        // the two workspaces do not share an anchor
        let directory = try makeDirectory("ratio")
        let leaf = "{\"pane\":{\"cwd\":\"\(directory)\"}}"
        try apply("{\"layout\":\"dwindle\",\"tree\":{\"split\":\"horizontal\",\"ratio\":0.05,"
                  + "\"a\":\(leaf),\"b\":\(leaf)}}", target: ":2").assertOK()
        harness.spin(0.7)
        let text = try dump(":2")
        XCTAssertTrue(text.contains("0.05"), "0.05 has to be written out verbatim: \(text)")
        controller.switchWorkspace(2)
        harness.spin(0.3)
        try apply(text, target: ":3").assertOK()
        harness.spin(0.8)
        XCTAssertEqual(try dump(":3"), text, "the fixed point of an extreme ratio")
    }

    /// An extension page (`webkit-extension://`) has been first-class state since 1.5.7: the
    /// address-bar heuristics do not recognize it, and handing it over to them turns dump -> apply
    /// on an open extension panel into a web search
    func testExtensionURLsAreNotReinterpretedAsSearchTerms() {
        let raw = "webkit-extension://abcdef12-3456/options.html"
        XCTAssertEqual(ControlPaneFactory.resolveURL(raw)?.absoluteString, raw)
        XCTAssertEqual(ControlPaneFactory.resolveURL("webkit-extension://abcdef12-3456/popup")?
            .absoluteString, "webkit-extension://abcdef12-3456/popup")
        // The path for what a person types into the address bar is untouched
        XCTAssertEqual(ControlPaneFactory.resolveURL("https://example.com")?.absoluteString,
                       "https://example.com")
        XCTAssertTrue(ControlPaneFactory.resolveURL("quickterm 是什么")?.absoluteString
            .contains("google") ?? false, "a bare word with no scheme still goes to search")
    }

    /// **The abbreviated form and the form WebKit settles on are the same URL.**
    /// People (and agents) write `http://localhost:3000`; the WebView reports
    /// `http://localhost:3000/` back. Compare literally and a browser pane in a hand-written spec
    /// never matches the live one — so every apply tears down and rebuilds a pane that was already
    /// sitting on the target page (losing the page, the login session and the scroll position)
    func testAnOmittedTrailingSlashIsTheSameURL() {
        func url(_ raw: String) -> URL? { URL(string: raw) }
        XCTAssertTrue(ControlPaneFactory.sameURL(url("http://localhost:3000"),
                                                 url("http://localhost:3000/")))
        XCTAssertTrue(ControlPaneFactory.sameURL(url("HTTPS://Example.COM/a"),
                                                 url("https://example.com/a")))
        XCTAssertTrue(ControlPaneFactory.sameURL(url("https://example.com:443/"),
                                                 url("https://example.com/")))
        // Normalisation stops here: the pairs below are **different pages** and must not be
        // "tidied" into one
        XCTAssertFalse(ControlPaneFactory.sameURL(url("https://example.com/a"),
                                                  url("https://example.com/a/")))
        XCTAssertFalse(ControlPaneFactory.sameURL(url("https://example.com/?a=1&b=2"),
                                                  url("https://example.com/?b=2&a=1")))
        XCTAssertFalse(ControlPaneFactory.sameURL(url("https://example.com/#x"),
                                                  url("https://example.com/")))
        XCTAssertFalse(ControlPaneFactory.sameURL(url("https://example.com/"), nil))
    }

    /// That rule as it lands on `spec apply --reuse`: the spec spells the abbreviated form while
    /// the live pane sits on the one with the slash — and it has to **stay put**
    func testABrowserPaneIsReusedAcrossTheTrailingSlash() throws {
        touched.insert(1)
        let keeper = try XCTUnwrap(try newPane(["kind": .string("browser"),
                                                "url": .string("http://127.0.0.1:1/")])
                                   as? BrowserPaneView)
        harness.spin(0.5)
        XCTAssertEqual(keeper.currentURL?.absoluteString, "http://127.0.0.1:1/",
                       "precondition: the live one carries the slash")

        // **Send it with a token**: a caller that cannot read the URL never matches anything to
        // begin with (that rule lives in `identityMatches`, so that "did it match" cannot become a
        // probe for guessing URLs), and then the slash is never exercised at all
        _ = try harness.mutation(try harness.run(
            "spec.apply", target: ":2",
            args: ["spec": .string("""
            {"columns":[{"panes":[{"kind":"browser","url":"http://127.0.0.1:1"}]}]}
            """), "reuse": .bool(true)],
            token: ControlEnvironment.token))
        harness.spin(0.6)
        XCTAssertTrue(try panes(1).contains { $0 === keeper },
                      "leaving the slash off must not make spec apply rebuild the very same page")
    }

    /// Panes with a command go through the same `pane new` machinery as Phase 2 (the engine forces
    /// wait-after-command on a surface that carries a command, so without taking `closesOnChildExit`
    /// over, the pane sits frozen forever once the command finishes)
    func testSpecPanesWithCommandsReuseThePaneNewMachinery() throws {
        touched.insert(1)
        let directory = try makeDirectory("cmd")
        try apply("""
        {"columns":[{"panes":[{"cwd":"\(directory)","cmd":"true"}]},
                    {"panes":[{"cwd":"\(directory)","cmd":"true","hold":true,"env":{"QT_SPEC":"1"}}]}]}
        """, target: ":2").assertOK()
        harness.spin(0.6)
        let live = try panes(1).compactMap { $0 as? Ghostty.SurfaceView }
        XCTAssertEqual(live.count, 2)
        XCTAssertTrue(live[0].closesOnChildExit, "a pane created by --cmd closes itself when the child process exits")
        XCTAssertFalse(live[1].closesOnChildExit, "hold explicitly asks for the pane to stay after the command exits")
    }
}

private extension ControlReply {
    func assertOK(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(ok, "command failed: \(String(describing: error))", file: file, line: line)
    }
}
