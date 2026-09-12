import XCTest
@testable import QuickTerm

/// The two halves of "a dwindle pane can be resized" as seen from the control plane:
/// **it can be read** (every state output carries sizes, and the dwindle skeleton carries the ratio
/// of every divider) and **it can be driven** (the command line can make every adjustment the mouse
/// can, clamped by the same rules).
///
/// Expected values are always **computed a second time inside the case** (worked out by hand from
/// the ratio / widthFactor in the model). Never take the encoder's own output as the expectation —
/// that only proves it agrees with itself.
@MainActor
final class ControlSizeTests: XCTestCase {
    private var harness: ControlHarness!
    private var temporaries: [String] = []
    private var touched: Set<Int> = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        harness = try ControlHarness()
        let controller = try harness.controller
        try XCTSkipUnless(controller.model.layouts.count >= 3, "this group needs three workspaces")
        try XCTSkipUnless(ControlGeometry.contentSize(controller) != nil,
                          "the test host has no measurable window content area")
        for index in [1, 2] {
            _ = controller.controlClearWorkspace(index, confirmIfNeeded: false)
            _ = controller.model.setLayout("scrolling", at: index, columnFactor: controller.columnFactor)
        }
        controller.switchWorkspace(1)
        harness.spin(0.25)
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
        let path = NSTemporaryDirectory() + "quickterm-size-\(name)-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        temporaries.append(path)
        return URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    @discardableResult
    private func apply(_ text: String, target: String,
                       file: StaticString = #filePath, line: UInt = #line) throws -> ControlReply {
        let reply = try harness.run("spec.apply", target: target, args: ["spec": .string(text)])
        XCTAssertTrue(reply.ok, "apply failed: \(String(describing: reply.error))", file: file, line: line)
        harness.spin(0.8)
        return reply
    }

    private func dump(_ target: String) throws -> String {
        let reply = try harness.run("spec.dump", target: target)
        XCTAssertTrue(reply.ok, "dump failed: \(String(describing: reply.error))")
        let spec = try XCTUnwrap(reply.data?["spec"])
        return String(decoding: try ControlJSON.encoder.encode(spec), as: UTF8.self)
    }

    /// The state of the workspace at `:2` (index 1)
    private func state() throws -> JSONValue {
        let reply = try harness.run("state", target: ":2")
        XCTAssertTrue(reply.ok, "state failed: \(String(describing: reply.error))")
        return try XCTUnwrap(reply.data)
    }

    private func panes(in state: JSONValue) -> [[String: JSONValue]] {
        (state["panes"]?.arrayValue ?? []).compactMap(\.objectValue)
            .filter { $0["workspace"]?.intValue == 2 }
    }

    private func pane(at path: String, in state: JSONValue) throws -> [String: JSONValue] {
        try XCTUnwrap(panes(in: state).first { $0["at"]?["path"]?.stringValue == path },
                      "state holds no pane with at.path = \(path)")
    }

    private func workspace(in state: JSONValue) throws -> [String: JSONValue] {
        let screens = try XCTUnwrap(state["screens"]?.arrayValue)
        let workspaces = try XCTUnwrap(screens.first?["workspaces"]?.arrayValue)
        return try XCTUnwrap(workspaces.first { $0["index"]?.intValue == 2 }?.objectValue)
    }

    private func rect(_ pane: [String: JSONValue]) throws -> [Double] {
        let raw = try XCTUnwrap(pane["size"]?["rect"]?.arrayValue, "the pane record has no size.rect")
        return raw.compactMap(\.doubleValue)
    }

    private func assertRect(_ got: [Double], _ want: [Double], _ what: String,
                            file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(got.count, 4, what, file: file, line: line)
        guard got.count == 4 else { return }
        for i in 0..<4 {
            XCTAssertEqual(got[i], want[i], accuracy: 0.0002,
                           "component \(i) of \(what): \(got) != \(want)", file: file, line: line)
        }
    }

    /// A dwindle workspace with three leaves and two ratios, neither of them 0.5:
    /// the root splits left/right at 0.3, the right subtree splits top/bottom at 0.7
    @discardableResult
    private func buildDeepTree(target: String = ":2") throws -> String {
        touched.formUnion([1, 2])
        let directory = try makeDirectory("tree")
        let leaf = "{\"pane\":{\"cwd\":\"\(directory)\"}}"
        let text = "{\"layout\":\"dwindle\",\"tree\":{\"split\":\"horizontal\",\"ratio\":0.3,"
            + "\"a\":\(leaf),\"b\":{\"split\":\"vertical\",\"ratio\":0.7,"
            + "\"a\":\(leaf),\"b\":\(leaf)}}}"
        try apply(text, target: target)
        return text
    }

    // MARK: Reading it back

    /// dwindle: the normalized rect, the size in points and the parent split ratio of every pane
    /// have to agree with the model. The expected rects are worked out by hand from 0.3 / 0.7, not
    /// by calling the encoder a second time
    func testDwindlePaneSizesMatchTheModel() throws {
        try buildDeepTree()
        let controller = try harness.controller
        let content = try XCTUnwrap(ControlGeometry.contentSize(controller))
        let state = try state()

        let a = try pane(at: "a", in: state)
        let ba = try pane(at: "b.a", in: state)
        let bb = try pane(at: "b.b", in: state)

        assertRect(try rect(a), [0, 0, 0.3, 1], "a")
        assertRect(try rect(ba), [0.3, 0, 0.7, 0.7], "b.a")
        assertRect(try rect(bb), [0.3, 0.7, 0.7, 0.3], "b.b")

        // Parent splits: a hangs off the root's left/right divider, b.* off the right subtree's
        // top/bottom divider
        XCTAssertEqual(a["size"]?["split"]?.stringValue, "horizontal")
        XCTAssertEqual(a["size"]?["ratio"]?.doubleValue, 0.3)
        XCTAssertEqual(ba["size"]?["split"]?.stringValue, "vertical")
        XCTAssertEqual(ba["size"]?["ratio"]?.doubleValue, 0.7)
        XCTAssertEqual(bb["size"]?["ratio"]?.doubleValue, 0.7)

        // Size in points = normalized rect * content area (computed independently here)
        let points = try XCTUnwrap(ba["size"]?["points"]?.arrayValue).compactMap(\.doubleValue)
        XCTAssertEqual(points[0], 0.7 * Double(content.width), accuracy: 0.2)
        XCTAssertEqual(points[1], 0.7 * Double(content.height), accuracy: 0.2)

        // The terminal grid: report it once the engine has measured it (before that the whole
        // section is absent — never report a made-up number)
        if let cols = ba["size"]?["cols"]?.intValue {
            XCTAssertGreaterThan(cols, 0)
            XCTAssertGreaterThan(try XCTUnwrap(ba["size"]?["rows"]?.intValue), 0)
        }
    }

    /// **The points that get reported stand on the area the panes really occupy.**
    /// The expected values are measured straight off the rendered NSViews (`measuredLayoutBox`),
    /// independent of the encoder's formula. It used to take `window.contentLayoutRect`: that
    /// always counted one ring of outer padding too many horizontally, and the vertical error even
    /// **changed sign** with `app set bar off` — which is why this case turns the status bar off
    /// and measures again
    func testReportedPointsStandOnTheAreaThePanesActuallyOccupy() throws {
        try buildDeepTree()
        let controller = try harness.controller
        harness.spin(0.4)

        let measured = try measuredLayoutBox()
        let reported = try XCTUnwrap(ControlGeometry.contentSize(controller))
        XCTAssertEqual(Double(reported.width), Double(measured.width), accuracy: 1.5,
                       "the reported width is not the area the split tree occupies")
        XCTAssertEqual(Double(reported.height), Double(measured.height), accuracy: 1.5,
                       "the reported height is not the area the split tree occupies")

        // A single pane: its slot is its view grown by one pane-gap on every side
        let gap = controller.themeManager.gapsEnabled ? controller.themeManager.paneGap : 0
        let content = try XCTUnwrap(controller.window?.contentView)
        let state = try state()
        let ba = try pane(at: "b.a", in: state)
        let handle = try XCTUnwrap(ba["handle"]?.stringValue)
        let view = try XCTUnwrap(controller.model.layouts[1].paneList.first {
            ControlHandleRegistry.shared.handle(for: $0) == handle
        })
        let slot = view.convert(view.bounds, to: content).insetBy(dx: -gap, dy: -gap)
        let points = try XCTUnwrap(ba["size"]?["points"]?.arrayValue).compactMap(\.doubleValue)
        XCTAssertEqual(points[0], Double(slot.width), accuracy: 1.5, "the slot width of b.a")
        XCTAssertEqual(points[1], Double(slot.height), accuracy: 1.5, "the slot height of b.a")

        // Turn the status bar off: the layout area grows by exactly the height of the status bar
        // (this used to come out with the opposite sign)
        controller.model.barVisible = false
        harness.spin(0.5)
        defer { controller.model.barVisible = true }
        let grown = try XCTUnwrap(ControlGeometry.contentSize(controller))
        XCTAssertEqual(Double(grown.height), Double(measured.height) + Double(StatusBarView.height),
                       accuracy: 1.5, "turning the status bar off should add exactly 26pt")
        XCTAssertEqual(Double(grown.height), Double(try measuredLayoutBox().height), accuracy: 1.5,
                       "with the status bar off, the reported height still has to equal the measured height")
    }

    /// While zoomed, **that one pane is all there is on screen**: not one of the other tiled panes
    /// renders. The zoomed pane reports the whole layout area, and the ones nobody can see get no
    /// `points` and are flagged `hidden`. `rect` / `ratio` still describe the tiled layer
    /// underneath — which is exactly what `pane resize` adjusts
    func testZoomedWorkspaceDoesNotHandOutPointsForPanesThatAreNotOnScreen() throws {
        try buildDeepTree()
        let controller = try harness.controller
        let zoomedHandle = try handleOfPane(at: "b.a")

        let set = try harness.run("pane.set", target: zoomedHandle, args: ["zoom": .string("on")])
        XCTAssertTrue(set.ok, "zoom would not turn on: \(String(describing: set.error))")
        harness.spin(0.5)

        let state = try state()
        let zoomed = try pane(at: "b.a", in: state)
        let sibling = try pane(at: "b.b", in: state)
        let far = try pane(at: "a", in: state)

        // The zoomed pane: the full screen
        let content = try XCTUnwrap(ControlGeometry.contentSize(controller))
        let points = try XCTUnwrap(zoomed["size"]?["points"]?.arrayValue).compactMap(\.doubleValue)
        XCTAssertEqual(points[0], Double(content.width), accuracy: 0.2, "the zoomed pane fills the width")
        XCTAssertEqual(points[1], Double(content.height), accuracy: 0.2, "the zoomed pane fills the height")
        XCTAssertNil(zoomed["size"]?["hidden"], "the zoomed pane is not one of the hidden ones")

        // The rest: they occupy nothing on screen, so they get no point sizes
        for (name, record) in [("b.b", sibling), ("a", far)] {
            XCTAssertEqual(record["size"]?["hidden"]?.boolValue, true, "\(name) should be flagged hidden")
            XCTAssertNil(record["size"]?["points"], "\(name) is 0x0 right now and must not carry points")
        }

        // rect / ratio still describe the tiled layer underneath (un-zooming returns to it, and
        // resize adjusts it)
        assertRect(try rect(sibling), [0.3, 0.7, 0.7, 0.3], "the tiled rect of b.b (worked out by hand from 0.3/0.7)")
        XCTAssertEqual(sibling["size"]?["ratio"]?.doubleValue, 0.7, "ratio is still the one from the tree")
        assertRect(try rect(far), [0, 0, 0.3, 1], "the tiled rect of a is unaffected by the zoom")

        // Asking `get` about a sibling on its own (with no workspace context) still has to show
        // that flag
        let got = try harness.run("get", target: try XCTUnwrap(sibling["handle"]?.stringValue))
        XCTAssertEqual(got.data?["pane"]?["size"]?["hidden"]?.boolValue, true)
        XCTAssertNil(got.data?["pane"]?["size"]?["points"])
    }

    /// During the 0.28s a pane takes to close, **the tree, `at.path` and every pane's rect have to
    /// describe one and the same shape**. The tree used to collapse while the rects did not:
    /// `state` said "t1 is the whole workspace" out of one side and handed t1 a half-width rect and
    /// a divider that did not exist in the tree out of the other
    func testGeometryAgreesWithTheReportedTreeWhileAPaneIsFadingOut() throws {
        let pane = try twoPaneTree()
        let controller = try harness.controller
        let survivor = try XCTUnwrap(controller.model.layouts[1].paneList.first { $0 !== pane })

        // Close with the animation (the path `action close-pane` / a shell exit / Cmd+W take),
        // without flushing
        controller.closePane(pane, confirmIfNeeded: false, animated: true)
        XCTAssertTrue(controller.model.closingPanes.contains(pane.id), "the fade-out should be running at this point")

        let state = try state()
        let workspace = try workspace(in: state)
        // The tree collapses onto the survivor
        XCTAssertEqual(workspace["tree"]?["pane"]?.stringValue,
                       ControlHandleRegistry.shared.handle(for: survivor),
                       "the tree should hold nothing but the survivor: \(String(describing: workspace["tree"]))")
        XCTAssertNil(workspace["tree"]?["ratio"], "a collapsed tree has no divider")

        let record = try XCTUnwrap(panes(in: state).first {
            $0["handle"]?.stringValue == ControlHandleRegistry.shared.handle(for: survivor)
        })
        XCTAssertEqual(record["at"]?["path"]?.stringValue, "", "with one leaf left, the path is the root")
        assertRect(try rect(record), [0, 0, 1, 1], "the last leaf standing fills the whole workspace")
        XCTAssertNil(record["size"]?["ratio"], "there is no divider left in the tree, so size must not report one either")
        XCTAssertNil(record["size"]?["split"])

        controller.flushPendingCloses()
        harness.spin(0.4)
    }

    /// The dwindle workspace skeleton carries the ratio of **every** divider, in exactly the same
    /// vocabulary as `spec dump`
    func testStateTreeCarriesEveryRatioInTheSameVocabularyAsSpecDump() throws {
        try buildDeepTree()
        let tree = try XCTUnwrap(try workspace(in: try state())["tree"]?.objectValue,
                                 "a dwindle workspace has to produce a tree")
        XCTAssertEqual(tree["split"]?.stringValue, "horizontal")
        XCTAssertEqual(tree["ratio"]?.doubleValue, 0.3)
        XCTAssertEqual(tree["a"]?["pane"]?.stringValue?.isEmpty, false, "a leaf holds a handle")
        let b = try XCTUnwrap(tree["b"]?.objectValue)
        XCTAssertEqual(b["split"]?.stringValue, "vertical")
        XCTAssertEqual(b["ratio"]?.doubleValue, 0.7)

        // The same vocabulary as spec dump: both trees use the same keys, with the same ratios
        let dumped = try dump(":2")
        XCTAssertTrue(dumped.contains("\"split\":\"horizontal\""), dumped)
        XCTAssertTrue(dumped.contains("\"ratio\":0.3"), dumped)
        XCTAssertTrue(dumped.contains("\"ratio\":0.7"), dumped)
    }

    /// scrolling: the column width factor, the share within a column, and the rects that fall out
    /// of accumulating widths horizontally
    func testScrollingSizesReportColumnWidthAndShareWithinTheColumn() throws {
        touched.formUnion([1, 2])
        let directory = try makeDirectory("cols")
        let leaf = "{\"cwd\":\"\(directory)\"}"
        try apply("{\"layout\":\"scrolling\",\"columns\":["
                  + "{\"width\":0.3,\"panes\":[\(leaf)]},"
                  + "{\"width\":0.45,\"panes\":[\(leaf),\(leaf)]}]}", target: ":2")
        let controller = try harness.controller
        guard case .scrolling(let strip) = controller.model.layouts[1] else {
            return XCTFail("this workspace should be scrolling")
        }
        // Effective column widths, computed independently (when they fit, they are scaled up to
        // fill, exactly as the renderer does)
        let widths = strip.columnWidths(viewport: 1, gap: 0).map(Double.init)
        XCTAssertEqual(widths.count, 2)

        let state = try state()
        let first = try XCTUnwrap(panes(in: state).first { $0["at"]?["column"]?.intValue == 0 })
        let stackedTop = try XCTUnwrap(panes(in: state).first {
            $0["at"]?["column"]?.intValue == 1 && $0["at"]?["row"]?.intValue == 0
        })
        let stackedBottom = try XCTUnwrap(panes(in: state).first {
            $0["at"]?["column"]?.intValue == 1 && $0["at"]?["row"]?.intValue == 1
        })

        assertRect(try rect(first), [0, 0, widths[0], 1], "column one")
        assertRect(try rect(stackedTop), [widths[0], 0, widths[1], 0.5], "column two, top")
        assertRect(try rect(stackedBottom), [widths[0], 0.5, widths[1], 0.5], "column two, bottom")

        // The width factor is **the nominal value the model holds**; the share is an even split
        // within the column
        XCTAssertEqual(first["size"]?["width"]?.doubleValue, 0.3)
        XCTAssertEqual(first["size"]?["share"]?.doubleValue, 1)
        XCTAssertEqual(stackedTop["size"]?["width"]?.doubleValue, 0.45)
        XCTAssertEqual(stackedTop["size"]?["share"]?.doubleValue, 0.5)
        XCTAssertEqual(stackedBottom["size"]?["share"]?.doubleValue, 0.5)

        // The column widths in the workspace skeleton are unchanged
        let columns = try XCTUnwrap(try workspace(in: state)["columns"]?.arrayValue)
        XCTAssertEqual(columns.first?["width"]?.doubleValue, 0.3)
        XCTAssertEqual(columns.last?["width"]?.doubleValue, 0.45)
    }

    /// `get`, `list panes` and `state` report one and the same size (three read commands must not
    /// each tell their own story)
    func testGetAndListReportTheSameSizeAsState() throws {
        try buildDeepTree()
        let state = try state()
        let target = try pane(at: "b.a", in: state)
        let handle = try XCTUnwrap(target["handle"]?.stringValue)

        let got = try harness.run("get", target: handle)
        XCTAssertEqual(got.data?["pane"]?["size"], target["size"])

        let listed = try harness.run("list", args: ["what": .string("panes")])
        let row = try XCTUnwrap((listed.data?["panes"]?.arrayValue ?? [])
            .first { $0["handle"]?.stringValue == handle })
        XCTAssertEqual(row["size"], target["size"])
    }

    /// The `--fields` projection: size appears only when it was asked for, and not otherwise (the
    /// handle always survives)
    func testFieldsProjectionIncludesAndExcludesSize() throws {
        try buildDeepTree()
        let withSize = try harness.run("state", target: ":2",
                                       args: ["fields": .string("handle,size")])
        let one = try XCTUnwrap((withSize.data?["panes"]?.arrayValue ?? []).first?.objectValue)
        XCTAssertNotNil(one["size"], "ask for size and it has to be there")
        XCTAssertNotNil(one["handle"])
        XCTAssertNil(one["title"])
        XCTAssertNil(one["workspace"], "a projection keeps only the fields that were listed")

        let without = try harness.run("state", target: ":2",
                                      args: ["fields": .string("handle,title")])
        let plain = try XCTUnwrap((without.data?["panes"]?.arrayValue ?? []).first?.objectValue)
        XCTAssertNil(plain["size"], "size must not appear when it was not asked for")
        XCTAssertNotNil(plain["handle"])
    }

    // MARK: It survives being composed

    /// A deep tree with distinct ratios: apply has to land every one of them on the model
    func testSpecApplyHonoursADeepTreeOfDistinctRatios() throws {
        try buildDeepTree()
        let controller = try harness.controller
        guard case .dwindle(let tree) = controller.model.layouts[1] else {
            return XCTFail("this workspace should be dwindle")
        }
        let splits = ControlGeometry.splits(in: tree, size: ControlGeometry.unit)
        XCTAssertEqual(splits.map(\.path), ["", "b"])
        XCTAssertEqual(splits[0].direction, "horizontal")
        XCTAssertEqual(splits[0].ratio, 0.3, accuracy: 0.0001)
        XCTAssertEqual(splits[1].direction, "vertical")
        XCTAssertEqual(splits[1].ratio, 0.7, accuracy: 0.0001)
    }

    /// The headline: for a deep tree with **non-default** ratios, dump -> apply -> dump is
    /// byte-for-byte identical
    func testDumpApplyDumpIsAFixedPointWithNonDefaultNestedRatios() throws {
        try buildDeepTree()
        let controller = try harness.controller
        // Drag one more divider so a ratio carries four decimal places (which pins the rounding
        // rule along the way)
        _ = try harness.run("pane.resize", target: try handleOfPane(at: "a"),
                            args: ["ratio": .string("0.2345")])
        harness.spin(0.3)

        let before = try dump(":2")
        XCTAssertTrue(before.contains("0.2345"), "a ratio produced by dragging goes into dump verbatim: \(before)")
        XCTAssertTrue(before.contains("0.7"), before)

        touched.insert(2)
        controller.switchWorkspace(2)
        harness.spin(0.3)
        let reply = try harness.run("spec.apply", target: ":3", args: ["spec": .string(before)])
        XCTAssertTrue(reply.ok, "apply failed: \(String(describing: reply.error))")
        harness.spin(0.9)
        XCTAssertEqual(try dump(":3"), before, "a fixed point, sizes included")
    }

    // MARK: Driving it (on equal footing with the mouse)

    /// `--ratio` means dragging that divider to that position: it lands on **the same number** a
    /// drag gesture does, and out of range it clamps in the same place (10pt left on either side,
    /// not 0.1-0.9)
    func testResizeByRatioLandsWhereTheDividerDragWould() throws {
        let pane = try twoPaneTree()
        let controller = try harness.controller
        let span = try XCTUnwrap(ControlGeometry.contentSize(controller)?.width)

        _ = try harness.run("pane.resize", target: handle(pane), args: ["ratio": .string("0.25")])
        XCTAssertEqual(try rootRatio(), 0.25, accuracy: 0.0005)

        // The same position, this time through the drag path (the SwiftUI divider binding calls
        // handleSplitOperation)
        try drag(dividerAt: 0.4 * span)
        let dragged = try rootRatio()
        _ = try harness.run("pane.resize", target: handle(pane), args: ["ratio": .string("0.4")])
        XCTAssertEqual(try rootRatio(), dragged, accuracy: 0.0005, "the same target position has to land on the same ratio")

        // Clamping: the command line asks for a ratio it cannot reach, and lands where dragging
        // the divider past the left edge lands
        try drag(dividerAt: -80)
        let clampedByMouse = try rootRatio()
        _ = try harness.run("pane.resize", target: handle(pane), args: ["ratio": .string("0.001")])
        XCTAssertEqual(try rootRatio(), clampedByMouse, accuracy: 0.0005,
                       "the command line must not put a divider where the mouse cannot drag it")
        XCTAssertGreaterThan(try rootRatio(), 0, "it clamps at 10pt, not at 0")
    }

    /// `--points` means "move the divider by this many points": +N is the same as dragging to
    /// (current position + N)
    func testResizeByPointsIsTheSameDragExpressedInPoints() throws {
        let pane = try twoPaneTree()
        let controller = try harness.controller
        let span = try XCTUnwrap(ControlGeometry.contentSize(controller)?.width)

        _ = try harness.run("pane.resize", target: handle(pane), args: ["ratio": .string("0.5")])
        let start = try rootRatio()
        _ = try harness.run("pane.resize", target: handle(pane), args: ["points": .string("+120")])
        let byPoints = try rootRatio()
        XCTAssertEqual(byPoints, start + 120 / Double(span), accuracy: 0.001)

        try drag(dividerAt: CGFloat(start) * span + 120)
        XCTAssertEqual(try rootRatio(), byPoints, accuracy: 0.0005, "points and a drag have to land in the same place")

        // A bare number sets the a side to that many points
        _ = try harness.run("pane.resize", target: handle(pane), args: ["points": .string("400")])
        XCTAssertEqual(try rootRatio(), 400 / Double(span), accuracy: 0.001)
    }

    /// `--dir` is one press of Cmd+Ctrl+arrow or a Cmd+right-button drag: it lands on the same
    /// ratio as `perform(.resize*)`
    func testResizeByDirectionMatchesTheKeyboardAndMouseDragPath() throws {
        let pane = try twoPaneTree()
        let controller = try harness.controller
        _ = try harness.run("pane.resize", target: handle(pane), args: ["ratio": .string("0.5")])
        let start = try rootRatio()

        _ = try harness.run("pane.resize", target: handle(pane),
                            args: ["dir": .string("right"), "points": .string("100")])
        let byCommand = try rootRatio()
        XCTAssertGreaterThan(byCommand, start)

        // Back to the start, this time via the shortcut (the step is 100pt as well)
        _ = try harness.run("pane.resize", target: handle(pane),
                            args: ["ratio": .string(String(start))])
        controller.requestFocus(to: pane)
        harness.spin(0.3)
        controller.perform(.resizeRight)
        XCTAssertEqual(try rootRatio(), byCommand, accuracy: 0.0005,
                       "the --dir of the command line and the shortcut have to produce the same ratio")
    }

    /// `--split` reaches an ancestor's divider (the mouse can grab any one of them directly)
    func testSplitPathAddressesAnAncestorDivider() throws {
        try buildDeepTree()
        let deep = try handleOfPane(at: "b.b")
        let before = try splits()

        _ = try harness.run("pane.resize", target: deep,
                            args: ["split": .string("root"), "ratio": .string("0.42")])
        let after = try splits()
        XCTAssertEqual(after[0].ratio, 0.42, accuracy: 0.0005, "the root divider is the one that moved")
        XCTAssertEqual(after[1].ratio, before[1].ratio, accuracy: 0.0001, "its own parent split must not be touched")

        let unknown = try harness.run("pane.resize", target: deep,
                                      args: ["split": .string("a.a"), "ratio": .string("0.5")])
        XCTAssertFalse(unknown.ok)
        XCTAssertEqual(unknown.error?.code, ControlErrorCode.notFound.rawValue)
        XCTAssertEqual(Set(unknown.error?.candidates ?? []), ["root", "b"],
                       "when it cannot be found, list the ones that do exist")
    }

    /// `--dir` together with `--split` is an error, **not** a quiet retarget of `--dir` onto some
    /// other divider. Silently changing the target is the worst class of mistake a control plane
    /// can make: the agent believes it moved the root divider while a different one moved
    func testDirectionAndSplitTogetherIsRejectedInsteadOfRetargeting() throws {
        try buildDeepTree()
        let deep = try handleOfPane(at: "b.b")
        let before = try splits().map(\.ratio)

        let reply = try harness.run("pane.resize", target: deep,
                                    args: ["split": .string("root"), "dir": .string("right"),
                                           "points": .string("100")])
        XCTAssertFalse(reply.ok, "--split together with --dir should error out")
        XCTAssertEqual(reply.error?.code, ControlErrorCode.badRequest.rawValue)
        XCTAssertEqual(try splits().map(\.ratio), before, "once it errors out, not one divider may have moved")
    }

    /// The absolute form is idempotent (the second call is a no-op and --fail-if-noop exits 7),
    /// and `--dry-run` does not change a byte
    func testAbsoluteResizeIsIdempotentAndDryRunChangesNothing() throws {
        let pane = try twoPaneTree()
        let controller = try harness.controller

        _ = try harness.run("pane.resize", target: handle(pane), args: ["ratio": .string("0.4")])
        XCTAssertEqual(try rootRatio(), 0.4, accuracy: 0.0005)
        let again = try harness.run("pane.resize", target: handle(pane),
                                    args: ["ratio": .string("0.4"),
                                           ControlCommandTable.Flag.failIfNoop: .bool(true)])
        XCTAssertEqual(again.error?.code, ControlErrorCode.noop.rawValue,
                       "the same absolute value a second time must change nothing")

        let fingerprint = try harness.fingerprint(controller)
        let dry = try harness.run("pane.resize", target: handle(pane),
                                  args: ["ratio": .string("0.8"),
                                         ControlCommandTable.Flag.dryRun: .bool(true)])
        XCTAssertTrue(dry.ok)
        XCTAssertEqual(dry.data?["changed"]?.boolValue, true, "a dry run still has to state truthfully what it would change")
        XCTAssertEqual(dry.data?["applied"]?.boolValue, false)
        XCTAssertEqual(try harness.fingerprint(controller), fingerprint, "--dry-run may not move a single byte")
        XCTAssertEqual(try rootRatio(), 0.4, accuracy: 0.0005)
    }

    /// The mutation echo carries the new size (saving the agent a read after every adjustment)
    func testResizeEchoesTheNewSize() throws {
        let pane = try twoPaneTree()
        let payload = try harness.mutation(try harness.run(
            "pane.resize", target: handle(pane), args: ["ratio": .string("0.35")]))
        XCTAssertEqual(payload["pane"]?["size"]?["ratio"]?.doubleValue, 0.35)
        let change = try XCTUnwrap(payload["changes"]?.arrayValue?.first)
        XCTAssertEqual(change["path"]?.stringValue, "1:2.tree.ratio",
                       "the diff path has to be shaped like the JSON in state")
        let workspace = try XCTUnwrap(payload["workspace"]?["tree"]?["ratio"]?.doubleValue)
        XCTAssertEqual(workspace, 0.35, accuracy: 0.0005)
    }

    // MARK: Parts

    private func handle(_ pane: PaneView) -> String { ControlHandleRegistry.shared.handle(for: pane) }

    private func handleOfPane(at path: String) throws -> String {
        try XCTUnwrap(pane(at: path, in: try state())["handle"]?.stringValue)
    }

    private func splits() throws -> [ControlGeometry.SplitSlot] {
        let controller = try harness.controller
        guard case .dwindle(let tree) = controller.model.layouts[1] else { return [] }
        return ControlGeometry.splits(in: tree, size: ControlGeometry.unit)
    }

    private func rootRatio() throws -> Double {
        try XCTUnwrap(try splits().first(where: { $0.path == "" })?.ratio)
    }

    /// A two-leaf dwindle (one left/right divider at the root); returns one of the leaves
    private func twoPaneTree() throws -> PaneView {
        touched.formUnion([1, 2])
        let directory = try makeDirectory("two")
        let leaf = "{\"pane\":{\"cwd\":\"\(directory)\"}}"
        try apply("{\"layout\":\"dwindle\",\"tree\":{\"split\":\"horizontal\",\"ratio\":0.5,"
                  + "\"a\":\(leaf),\"b\":\(leaf)}}", target: ":2")
        let controller = try harness.controller
        return try XCTUnwrap(controller.model.layouts[1].paneList.first)
    }

    /// Go down the **real** divider-drag path: the SwiftUI binding converts the drop position into
    /// a ratio (`SplitViewMetrics.ratio`) and hands it to `handleSplitOperation(.resize)`.
    /// The span that conversion divides by comes from the **measured** layout area
    /// (`measuredLayoutBox`), not from `ControlGeometry` — feed the drag the number the code under
    /// test produced and "the command line lands where the mouse does" degenerates into it agreeing
    /// with itself
    private func drag(dividerAt points: CGFloat) throws {
        let controller = try harness.controller
        guard case .dwindle(let tree) = controller.model.layouts[1], let root = tree.root else {
            return XCTFail("this workspace should be dwindle")
        }
        let span = try measuredLayoutBox().width
        controller.switchWorkspace(1)
        controller.handleSplitOperation(.resize(.init(
            node: root, ratio: Double(SplitViewMetrics.ratio(dividerAt: points, in: span)))))
        harness.spin(0.2)
    }

    /// Measure the **rendered NSViews of the panes** directly and work backwards to the area the
    /// split tree really occupies: each pane's view is its slot inset by one pane-gap on every side
    /// (`PaneChrome`'s padding), so the union of them grown by one gap is the layout area.
    /// The expectation must never route through `ControlGeometry` again — that would only compare
    /// the encoder with itself
    private func measuredLayoutBox(file: StaticString = #filePath,
                                   line: UInt = #line) throws -> CGRect {
        let controller = try harness.controller
        let content = try XCTUnwrap(controller.window?.contentView, file: file, line: line)
        let gap = controller.themeManager.gapsEnabled ? controller.themeManager.paneGap : 0
        var union: CGRect?
        for pane in controller.model.layouts[1].paneList {
            guard pane.window != nil, pane.superview != nil else { continue }
            let frame = pane.convert(pane.bounds, to: content)
            guard frame.width > 1, frame.height > 1 else { continue }
            union = union.map { $0.union(frame) } ?? frame
        }
        let box = try XCTUnwrap(union, "not one pane is attached to the window, so the real layout cannot be measured",
                                file: file, line: line)
        return box.insetBy(dx: -gap, dy: -gap)
    }
}
