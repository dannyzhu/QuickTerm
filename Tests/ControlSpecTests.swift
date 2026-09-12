import XCTest
@testable import QuickTerm

/// The **format** half of Phase 3: parsing and validating `quickterm.workspace/1`.
/// All pure functions, no live screen required — the half that actually lands a spec lives in
/// `ControlSpecApplyTests`.
final class ControlSpecTests: XCTestCase {
    private func parse(_ text: String) throws -> SpecDocument {
        try SpecParser.parse(text)
    }

    private func issues(_ text: String) -> ControlErrorBody? {
        do {
            _ = try SpecParser.parse(text)
            return nil
        } catch let body as ControlErrorBody {
            return body
        } catch {
            return ControlErrorBody(.failed, "\(error)")
        }
    }

    // MARK: The value ranges stay in step with the app's own

    /// Wire may only import Foundation, so it cannot reach `ScrollingStrip`: each side keeps its
    /// own copy of the range, and this case is what nails the two together.
    ///
    /// What it pins is **containment**, not equality: the public schema has to cover every value
    /// the engine can actually hold. The 0.25-0.90 of `pane set --width` only governs manual
    /// resizing, whereas "N columns visible per screen" sets the column width to (1-2*peek)/N
    /// (0.97 at N=1, 0.1617 at N=6) — copy the manual range here instead and a file produced by
    /// `spec dump` gets rejected on the spot by `spec validate`
    func testSpecLimitsCoverEveryValueTheEngineCanHold() {
        XCTAssertTrue(SpecLimits.widthRange.contains(ScrollingStrip.widthRange.lowerBound))
        XCTAssertTrue(SpecLimits.widthRange.contains(ScrollingStrip.widthRange.upperBound))
        for n in SpecLimits.visibleColumns {
            // dump rounds it to 4 decimal places, so round it the same way here
            let factor = (ScrollingStrip.factor(forVisibleColumns: n) * 10000).rounded() / 10000
            XCTAssertTrue(SpecLimits.widthRange.contains(factor),
                          "the column width \(factor) for \(n) columns per screen must be a legal spec value")
        }
        // Split ratios: dragging the divider with the mouse only clamps at 10pt, so dragging a
        // 1600pt-wide pane all the way over lands on 0.00625
        XCTAssertTrue(SpecLimits.ratioRange.contains(10.0 / 1600))
        XCTAssertEqual(SpecLimits.maxPanes, ControlRateLimiter.maxPanesPerWorkspace)
        XCTAssertEqual(SpecLimits.visibleColumns, 1...6)
    }

    // MARK: The smallest spec that still works

    /// **Two lines have to be enough**: kind defaults to terminal, width defaults to whatever the
    /// visible-columns-per-screen setting implies, cwd is inherited from the anchor. This case is
    /// the floor for "can a model write a spec off the top of its head"
    func testTwoLineSpecParsesWithDefaults() throws {
        let document = try parse(#"{"columns":[{"panes":[{}]},{"panes":[{},{}]}]}"#)
        guard case .workspace(let workspace) = document else { return XCTFail("should be read as a workspace") }
        XCTAssertEqual(workspace.layoutName, "scrolling", "no layout means scrolling")
        XCTAssertEqual(workspace.paneCount, 3)
        let slots = SpecApplier.tiledSlots(workspace)
        XCTAssertEqual(slots.map(\.key), ["c:0.0", "c:1.0", "c:1.1"])
        XCTAssertEqual(SpecApplier.kind(of: slots[0].pane), "terminal")
        XCTAssertNil(slots[0].pane.cwd, "no cwd means inherit from the anchor, not an empty string")
    }

    /// A tree with no layout is read as dwindle — rather than the silent wrong answer
    /// "scrolling, and the tree is ignored"
    func testTreeImpliesDwindle() throws {
        let document = try parse(#"{"tree":{"a":{},"b":{"a":{},"b":{}}}}"#)
        guard case .workspace(let workspace) = document else { return XCTFail("should be read as a workspace") }
        XCTAssertEqual(workspace.layoutName, "dwindle")
        XCTAssertEqual(SpecApplier.tiledSlots(workspace).map(\.key), ["p:a", "p:b.a", "p:b.b"])
    }

    // MARK: The three scopes

    func testSchemaDecidesTheScopeAndShapeSniffingIsTheFallback() throws {
        XCTAssertEqual(try parse(#"{"schema":"quickterm.screen/1"}"#).kind, .screen)
        XCTAssertEqual(try parse(#"{"schema":"quickterm.session/1"}"#).kind, .session)
        XCTAssertEqual(try parse(#"{"workspaces":[]}"#).kind, .screen, "workspaces present = a screen")
        XCTAssertEqual(try parse(#"{"screens":[]}"#).kind, .session, "screens present = a session")
        XCTAssertEqual(try parse(#"{"columns":[]}"#).kind, .workspace)
    }

    /// The envelope shape (the entire output of `spec dump --json`) is accepted when it is fed
    /// straight back in — otherwise the user has to pipe it through jq first, and that is exactly
    /// the step where things go wrong
    func testEnvelopeShapeIsAccepted() throws {
        let text = #"{"v":1,"ok":true,"data":{"spec":{"schema":"quickterm.workspace/1","columns":[{}]}}}"#
        XCTAssertEqual(try parse(text).kind, .workspace)
    }

    // MARK: Rejections (every one of them has to say **where**)

    /// A misspelled key is the hardest class of mistake to track down: ignore it silently and the
    /// caller is handed "it succeeded and nothing happened"
    func testUnknownKeysAreRefusedWithTheirPath() throws {
        let body = try XCTUnwrap(issues(#"{"colums":[{}]}"#))
        XCTAssertEqual(body.code, ControlErrorCode.badRequest.rawValue)
        XCTAssertTrue(body.message.contains("colums"), "the error has to name the key that was misspelled: \(body.message)")
        let nested = try XCTUnwrap(issues(#"{"columns":[{"panes":[{"kimd":"browser"}]}]}"#))
        XCTAssertTrue(nested.message.contains("columns[0].panes[0].kimd"),
                      "it has to give the full path: \(nested.message)")
    }

    /// Out of range **errors out and names the valid range**, and never silently clamps: after a
    /// clamp the value you read back no longer matches the one you wrote
    func testOutOfRangeNumbersNameTheValidRange() throws {
        let width = try XCTUnwrap(issues(#"{"columns":[{"width":1.5}]}"#))
        XCTAssertTrue(width.message.contains("\(SpecLimits.widthRange.lowerBound)"), width.message)
        XCTAssertTrue(width.message.contains("\(SpecLimits.widthRange.upperBound)"), width.message)
        let ratio = try XCTUnwrap(issues(#"{"tree":{"ratio":1.4,"a":{},"b":{}}}"#))
        XCTAssertTrue(ratio.message.contains("\(SpecLimits.ratioRange.lowerBound)"), ratio.message)
        // An extreme ratio produced by dragging is **legal input**: dump has to write it out
        // faithfully and must never silently clamp it into 0.1-0.9
        XCTAssertNil(issues(#"{"tree":{"ratio":0.02,"a":{},"b":{}}}"#),
                     "a divider dragged down to 2% has to be accepted as well")
        let columns = try XCTUnwrap(issues(#"{"visibleColumns":9}"#))
        XCTAssertTrue(columns.message.contains("1–6"), columns.message)
    }

    /// Control characters (they would ride all the way into the child process's environment /
    /// command line) and bad paths
    func testAdversarialStringsAreRefused() throws {
        XCTAssertNotNil(issues("{\"columns\":[{\"panes\":[{\"cmd\":\"ls\\u0007\"}]}]}"), "control character inside cmd")
        XCTAssertNotNil(issues("{\"columns\":[{\"panes\":[{\"cwd\":\"\\u0000/tmp\"}]}]}"), "NUL inside cwd")
        XCTAssertNotNil(issues(#"{"columns":[{"panes":[{"cwd":"relative/path"}]}]}"#), "relative path")
        XCTAssertNotNil(issues("{\"columns\":[{\"panes\":[{\"env\":{\"A B\":\"1\"}}]}]}"), "space inside an env var name")
        XCTAssertNotNil(issues(#"{"columns":[{"panes":[{"env":{"A":1}}]}]}"#), "env var value is not a string")
    }

    /// `..` normalisation: `/tmp/a/../b` = `/tmp/b` (not a security boundary, it only makes paths comparable)
    func testPathTraversalIsNormalisedNotRejected() {
        XCTAssertEqual(SpecValidator.normalizedPath("/tmp/a/../b"), "/tmp/b")
        XCTAssertTrue(SpecValidator.normalizedPath("~/x").hasPrefix("/"))
    }

    /// Mutually exclusive: url only means something for a browser, cmd means nothing for one, and
    /// a node cannot be a split and a leaf at the same time
    func testMutuallyExclusiveFieldsAreRefused() throws {
        XCTAssertNotNil(issues(#"{"columns":[{"panes":[{"url":"https://x"}]}]}"#))
        XCTAssertNotNil(issues(#"{"columns":[{"panes":[{"kind":"browser","cmd":"ls"}]}]}"#))
        XCTAssertNotNil(issues(#"{"tree":{"pane":{},"a":{},"b":{}}}"#))
        XCTAssertNotNil(issues(#"{"layout":"scrolling","tree":{"pane":{}}}"#))
        XCTAssertNotNil(issues(#"{"layout":"dwindle","columns":[{}]}"#))
        XCTAssertNotNil(issues(#"{"tree":{"a":{}}}"#),
                        "a split node with one side missing does not get filled in by guesswork")
    }

    func testUnknownSchemaListsTheOnesWeKnow() throws {
        let body = try XCTUnwrap(issues(#"{"schema":"quickterm.workspace/2"}"#))
        XCTAssertEqual(body.candidates, SpecSchema.all)
    }

    func testEmptyAndOversizedInputs() throws {
        XCTAssertNotNil(issues("   "))
        XCTAssertNotNil(issues("not json"))
        XCTAssertNotNil(issues("[]"), "the outermost value has to be an object")
        let huge = String(repeating: "x", count: SpecLimits.maxBytes + 1)
        XCTAssertNotNil(issues(huge))
    }

    /// At most 32 panes per workspace: an agent will happily write 200 of them
    func testPaneCapIsEnforcedByTheParser() throws {
        let columns = (0..<(SpecLimits.maxPanes + 1)).map { _ in #"{"panes":[{}]}"# }.joined(separator: ",")
        let body = try XCTUnwrap(issues("{\"columns\":[\(columns)]}"))
        XCTAssertTrue(body.message.contains("\(SpecLimits.maxPanes)"), body.message)
    }

    // MARK: Positional references

    func testPositionRefsMapOntoWalkOrder() {
        XCTAssertEqual(SpecApplier.key(for: PaneRef(column: 1, row: 2)), "c:1.2")
        XCTAssertEqual(SpecApplier.key(for: PaneRef(path: "b.a")), "p:b.a")
        XCTAssertEqual(SpecApplier.key(for: PaneRef(floating: 0)), "f:0")
        XCTAssertNil(SpecApplier.key(for: PaneRef()))
        XCTAssertNotNil(issues(#"{"focus":{"path":"x.y"}}"#), "a tree path may only be built out of a / b")
    }

    // MARK: Encode/decode round-trip

    /// Typed spec -> JSON -> typed spec, without losing a single field
    func testTypedRoundTrip() throws {
        let workspace = WorkspaceSpec(
            schema: SpecSchema.workspace, layout: "dwindle", visibleColumns: 3,
            tree: .split(.init(direction: "vertical", ratio: 0.6,
                               a: .leaf(PaneSpec(kind: "terminal", cwd: "/tmp", cmd: "ls", hold: true,
                                                 env: ["A": "1"])),
                               b: .leaf(PaneSpec(kind: "browser", url: "https://example.com",
                                                 tabs: ["https://example.com", "https://a.test"])))),
            zoom: PaneRef(path: "a"), focus: PaneRef(path: "b"),
            floating: [FloatingSpec(rect: [0.1, 0.2, 0.3, 0.4], pane: PaneSpec())])
        let text = try SpecDocument.workspace(workspace).canonicalJSONString()
        guard case .workspace(let back) = try parse(text) else { return XCTFail("did not parse back") }
        XCTAssertEqual(back, workspace)
    }

    // MARK: Command table / describe

    /// No command may be executable without showing up in describe (the invariant since Phase 1;
    /// the three spec commands are no exception)
    func testSpecCommandsAreDeclaredInTheTable() throws {
        let verbs = ControlCommandTable.commands(inGroup: "spec").map(\.verb)
        XCTAssertEqual(verbs, ["dump", "validate", "apply"])
        let apply = try XCTUnwrap(ControlCommandTable.command("spec apply"))
        XCTAssertEqual(apply.cls, .destructive, "the command table declares the worst case (--replace)")
        XCTAssertTrue(apply.honorsMutationFlags, "spec apply has to honor --dry-run / --fail-if-noop")
        XCTAssertTrue(apply.readsFile,
                      "-f / stdin is read by the CLI; the server never touches the caller's file system")
        XCTAssertTrue(try XCTUnwrap(ControlCommandTable.command("spec dump")).cls == .read)
        for spec in ControlCommandTable.commands(inGroup: "spec") {
            XCTAssertFalse(spec.examples.isEmpty, "the help for \(spec.cli) must end with EXAMPLES")
        }
        // All three modes are in the table (miss one and it is "executable, but nobody knows
        // about it")
        let modes = Set(apply.args.map(\.name))
        for mode in SpecApplier.Mode.allCases {
            XCTAssertTrue(modes.contains(mode.rawValue), "\(mode.rawValue) is not in the command table")
        }
    }

    func testDescribeCarriesTheWorkspaceSchema() throws {
        let document = ControlDescribeDocument.make(cliVersion: "t", appVersion: "t",
                                                    socket: nil, mode: "ask")
        XCTAssertEqual(document.phase, 5)
        XCTAssertEqual(document.specSchema.workspace, SpecSchema.workspace)
        XCTAssertFalse(document.specSchema.fields.isEmpty)
        // The "smallest spec that works" printed by describe has to actually parse — letting the
        // docs drift from the implementation is lying to the agent
        XCTAssertEqual(try parse(document.specSchema.minimal).kind, .workspace)
        // Every sample embedded in the help / describe has to actually parse — letting the docs
        // drift from the implementation is lying to the agent, and it has no other way to find out
        XCTAssertEqual(document.specSchema.examples.count, 2, "one for scrolling and one for dwindle")
        for sample in document.specSchema.examples {
            XCTAssertEqual(try parse(sample).kind, .workspace, sample)
        }
        XCTAssertEqual(try parse(ControlCommandTable.specSample).kind, .workspace)
        XCTAssertEqual(try parse(ControlCommandTable.specTreeSample).kind, .workspace)
    }

    /// Error codes are append-only: partial_apply, new in Phase 3, needs its own exit-code mapping
    func testPartialApplyErrorCode() {
        XCTAssertEqual(ControlErrorCode.partialApply.exit, .failure)
        XCTAssertEqual(ControlErrorCode(rawValue: "partial_apply"), .partialApply)
    }
}
