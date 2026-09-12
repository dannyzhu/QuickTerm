import XCTest
import AppKit
@testable import QuickTerm

@MainActor
final class ScrollingStripTests: XCTestCase {
    private func pane() throws -> Ghostty.SurfaceView {
        let appDelegate = try XCTUnwrap(NSApp.delegate as? AppDelegate)
        return Ghostty.SurfaceView(try XCTUnwrap(appDelegate.ghostty.app), baseConfig: nil)
    }

    func testInsertColumnRightOfAnchor() throws {
        let a = try pane(), b = try pane(), c = try pane()
        var strip = ScrollingStrip(pane: a)
        strip = strip.insertingColumnRight(of: a, pane: b)   // [a][b]
        strip = strip.insertingColumnRight(of: a, pane: c)   // [a][c][b]
        XCTAssertEqual(strip.columns.count, 3)
        XCTAssertTrue(strip.columns[1].panes.first === c, "the new column goes in right of the anchor column")
        XCTAssertTrue(strip.columns[2].panes.first === b)
    }

    /// The structural signature: swapping, merging and splitting change it, which drives viewport
    /// realignment. Resizing deliberately does not: a right-drag resize fires per event, and folding it
    /// into the signature would hijack a viewport the user panned by hand.
    func testLayoutSignatureStructuralOnly() throws {
        let a = try pane(), b = try pane()
        var strip = ScrollingStrip(pane: a)
        strip = strip.insertingColumnRight(of: a, pane: b)   // [a][b]
        let base = strip.layoutSignature
        XCTAssertEqual(strip.layoutSignature, base, "the same layout keeps the same signature")
        XCTAssertNotEqual(strip.swapping(a, direction: .right).layoutSignature, base,
                          "swapping columns changes the signature: Cmd+Shift+arrow has to make the scroll follow")
        XCTAssertNotEqual(strip.mergingOrSplitting(b).layoutSignature, base,
                          "merging changes the signature ([a][b] -> [a,b])")
        XCTAssertEqual(strip.resizingWidth(of: a, delta: 0.05).layoutSignature, base,
                       "resizing does not change the signature")
    }

    func testRemoveDeletesEmptyColumn() throws {
        let a = try pane(), b = try pane()
        var strip = ScrollingStrip(pane: a).insertingColumnRight(of: a, pane: b)
        strip = strip.removing(b)
        XCTAssertEqual(strip.columns.count, 1)
        XCTAssertEqual(strip.paneList.count, 1)
    }

    func testFocusTargetsAcrossAndWithinColumns() throws {
        let a = try pane(), b = try pane(), c = try pane()
        // [a][b], then stack on b: add c to b's column (dropping on .bottom is how a stack is modelled)
        var strip = ScrollingStrip(pane: a).insertingColumnRight(of: a, pane: b)
        strip = strip.insertingColumnRight(of: b, pane: c)
        strip = strip.dropping(c, on: b, zone: .bottom)      // [a][b/c]
        XCTAssertEqual(strip.columns.count, 2)
        XCTAssertEqual(strip.columns[1].panes.count, 2)
        XCTAssertTrue(strip.focusTarget(from: a, direction: .right) === b)
        XCTAssertTrue(strip.focusTarget(from: b, direction: .down) === c)
        XCTAssertTrue(strip.focusTarget(from: c, direction: .up) === b)
        XCTAssertTrue(strip.focusTarget(from: c, direction: .left) === a, "across columns it takes the nearest row")
        XCTAssertNil(strip.focusTarget(from: a, direction: .left), "the left end does not wrap")
    }

    func testSwapColumnAndRow() throws {
        let a = try pane(), b = try pane()
        var strip = ScrollingStrip(pane: a).insertingColumnRight(of: a, pane: b)
        strip = strip.swapping(a, direction: .right)         // [b][a]
        XCTAssertTrue(strip.columns[0].panes.first === b)
        strip = strip.dropping(b, on: a, zone: .top)         // [b/a], a single column
        strip = strip.swapping(a, direction: .up)            // swap inside the column: [a/b]
        XCTAssertTrue(strip.columns[0].panes.first === a)
    }

    func testMergeAndSplit() throws {
        let a = try pane(), b = try pane()
        var strip = ScrollingStrip(pane: a).insertingColumnRight(of: a, pane: b)
        strip = strip.mergingOrSplitting(b)                  // b merges into the left column: [a/b]
        XCTAssertEqual(strip.columns.count, 1)
        XCTAssertEqual(strip.columns[0].panes.count, 2)
        strip = strip.mergingOrSplitting(b)                  // b splits back out: [a][b]
        XCTAssertEqual(strip.columns.count, 2)
        XCTAssertTrue(strip.columns[1].panes.first === b)
    }

    func testResizeClampAndEqualize() throws {
        let a = try pane()
        var strip = ScrollingStrip(pane: a)
        for _ in 0..<20 { strip = strip.resizingWidth(of: a, delta: ScrollingStrip.widthStep) }
        XCTAssertEqual(strip.columns[0].widthFactor, 0.90, accuracy: 0.001, "upper bound 90%")
        strip = strip.equalized()
        XCTAssertEqual(strip.columns[0].widthFactor, ScrollingStrip.defaultWidth, accuracy: 0.001)
        XCTAssertEqual(ScrollingStrip.defaultWidth, 0.485, accuracy: 0.001, "two columns = (1−2×1.5%)/2")
    }

    func testTargetOffsetMinimalScroll() throws {
        let a = try pane(), b = try pane(), c = try pane()
        var strip = ScrollingStrip(pane: a)
        strip = strip.insertingColumnRight(of: a, pane: b)
        strip = strip.insertingColumnRight(of: b, pane: c)   // [a][b][c] at 0.485 each: 1465 wide, 2 gaps included
        let vp: CGFloat = 1000, gap: CGFloat = 5
        // Focus on a: offset 0, nothing moves.
        XCTAssertEqual(strip.targetOffset(for: a, current: 0, viewport: vp, gap: gap), 0)
        // Focus on b: [490,975] is fully visible and a peek still shows on the right, so the minimal scroll is none.
        XCTAssertEqual(strip.targetOffset(for: b, current: 0, viewport: vp, gap: gap), 0)
        // Focus on c, the last column: x=980, right-edge alignment plus a peek gives 480, but the total width
        // clamps it to 1465-1000 = 465, so the last column sits flush.
        XCTAssertEqual(strip.targetOffset(for: c, current: 0, viewport: vp, gap: gap), 465, accuracy: 0.5)
        // Focusing back to a from the right: left-edge alignment plus a peek goes negative, clamped to 0.
        XCTAssertEqual(strip.targetOffset(for: a, current: 465, viewport: vp, gap: gap), 0)
        // Focus b at current 465: b is fully visible, with a peeking 20 on the left, so nothing moves.
        XCTAssertEqual(strip.targetOffset(for: b, current: 465, viewport: vp, gap: gap), 465)
    }

    /// Four columns with focus in the middle: the two central columns show in full and the ones on either
    /// side each show exactly one peek, symmetrically. The old 2% peek left nothing but a sliver, and edge
    /// alignment only ever exposed one side (per the user's screenshot).
    func testInteriorFocusShowsSymmetricPeeks() throws {
        let a = try pane(), b = try pane(), c = try pane(), d = try pane()
        var strip = ScrollingStrip(pane: a).insertingColumnRight(of: a, pane: b)
        strip = strip.insertingColumnRight(of: b, pane: c).insertingColumnRight(of: c, pane: d)
        let vp: CGFloat = 1000, gap: CGFloat = 0
        let w = ScrollingStrip.factor(forVisibleColumns: 2) * 1000   // 485
        let peek = ScrollingStrip.peek * 1000                         // 15
        let offset = strip.targetOffset(for: c, current: 0, viewport: vp, gap: gap)
        XCTAssertEqual(offset, 2 * w + w + peek - vp, accuracy: 0.5, "c aligns its right edge and keeps a peek on the right -> 470")
        // Visible range [470,1470): a peeks 15, b and c in full, d peeks 15.
        XCTAssertEqual(w - offset, peek, accuracy: 0.5, "the left neighbour a shows exactly one peek")
        XCTAssertEqual(offset + vp - 3 * w, peek, accuracy: 0.5, "the right neighbour d shows exactly one peek")
        XCTAssertGreaterThanOrEqual(w - offset, 0); XCTAssertLessThanOrEqual(3 * w - offset, vp)
        // The last column d sits flush right: with no neighbour on that side there is nothing to leave room for.
        XCTAssertEqual(strip.targetOffset(for: d, current: offset, viewport: vp, gap: gap),
                       4 * w - vp, accuracy: 0.5)
    }

    func testDwindleRoundTripPreservesPanes() throws {
        let a = try pane(), b = try pane(), c = try pane()
        var strip = ScrollingStrip(pane: a).insertingColumnRight(of: a, pane: b)
        strip = strip.insertingColumnRight(of: b, pane: c)
        strip = strip.dropping(c, on: b, zone: .bottom)      // [a][b/c]
        let tree = strip.toTree()
        XCTAssertEqual(tree.root?.leaves().count, 3, "converting to a tree keeps every pane")
        let back = ScrollingStrip.from(tree: tree)
        XCTAssertEqual(back.paneList.count, 3, "converting back keeps every pane")
        XCTAssertTrue(back.paneList[0] === a)
    }

    /// The Cmd+L round trip: when the set of panes has not changed, the original scrolling arrangement comes
    /// back (column stacks and widths), instead of being flattened into N single-pane columns.
    func testToggleLayoutRestoresRememberedArrangement() throws {
        let a = try pane(), b = try pane(), c = try pane(), d = try pane(), e = try pane()
        var strip = ScrollingStrip(pane: a)
        strip = strip.insertingColumnRight(of: a, pane: b)                                   // [a][b]
        strip = strip.insertingColumnRight(of: b, pane: c).dropping(c, on: b, zone: .bottom)  // [a][b/c]
        strip = strip.insertingColumnRight(of: c, pane: d)                                   // [a][b/c][d]
        strip = strip.insertingColumnRight(of: d, pane: e).dropping(e, on: d, zone: .bottom)  // [a][b/c][d/e]
        strip = strip.equalized(to: 0.327)
        XCTAssertEqual(strip.columns.count, 3)
        XCTAssertEqual(strip.paneList.count, 5)

        let model = WorkspaceModel()
        model.layout = .scrolling(strip)
        model.toggleLayout(columnFactor: 0.327)
        guard case .dwindle(let tree) = model.layout else { return XCTFail("it should switch to dwindle") }
        XCTAssertEqual(tree.root?.leaves().count, 5, "dwindle keeps all 5 panes")

        model.toggleLayout(columnFactor: 0.327)
        guard case .scrolling(let back) = model.layout else { return XCTFail("it should switch back to scrolling") }
        XCTAssertEqual(back.columns.count, 3,
                       "restores the 3-column arrangement, not 5 single columns (which would overflow and show only 3)")
        XCTAssertTrue(back.columns[1].panes.count == 2 && back.columns[1].panes[0] === b
                      && back.columns[1].panes[1] === c, "the column stack comes back exactly")
        XCTAssertEqual(back.columns[0].widthFactor, 0.327, accuracy: 0.001, "the column width comes back exactly")

        // The set of panes changed (e was closed inside dwindle), so it falls back to conversion: 4 single
        // columns, widths following the visible-columns setting.
        model.toggleLayout(columnFactor: 0.327)
        guard case .dwindle(let tree2) = model.layout else { return XCTFail() }
        model.layout = .dwindle(tree2.removing(.leaf(view: e)))
        model.toggleLayout(columnFactor: 0.327)
        guard case .scrolling(let converted) = model.layout else { return XCTFail() }
        XCTAssertEqual(converted.columns.count, 4, "once the set changes, conversion keeps every pane in order")
        XCTAssertEqual(converted.columns[0].widthFactor, 0.327, accuracy: 0.001,
                       "converted widths follow the current visible-columns setting (this used to be a hard-coded 0.49)")
    }

    /// The dwindle split direction comes from the tree's own geometry: wider than tall -> right, otherwise
    /// -> down. It never looks at a view frame.
    func testDwindleDirectionFollowsSpatialAspect() throws {
        let a = try pane(), b = try pane()
        let bounds = CGSize(width: 1000, height: 600)
        var tree = SplitTree(view: a)
        XCTAssertEqual(tree.dwindleDirection(for: a, in: bounds), .right, "the whole screen is wider than tall -> right")
        tree = try tree.inserting(view: b, at: a, direction: .right)      // a takes the left half, 500×600
        XCTAssertEqual(tree.dwindleDirection(for: a, in: bounds), .down, "the left half is taller than wide -> down")
        XCTAssertEqual(tree.dwindleDirection(for: b, in: bounds), .down)
        let c = try pane()
        tree = try tree.inserting(view: c, at: b, direction: .down)      // b takes the top right, 500×300
        XCTAssertEqual(tree.dwindleDirection(for: b, in: bounds), .right, "top right at 500×300 is wider than tall -> right")
    }

    /// Where focus goes after a dwindle close: the nearest leaf in the sibling subtree that takes over the
    /// space (a left child hands off to the sibling's first leaf, a right child to its last).
    func testDwindleCloseSuccessorGoesToSibling() throws {
        let a = try pane(), b = try pane(), c = try pane(), d = try pane()
        var tree = SplitTree(view: a)
        XCTAssertNil(tree.closeSuccessor(of: a), "a lone leaf has no successor")
        tree = try tree.inserting(view: b, at: a, direction: .right)   // [a | b]
        tree = try tree.inserting(view: c, at: b, direction: .down)    // [a | (b / c)]
        tree = try tree.inserting(view: d, at: c, direction: .down)    // [a | (b / (c / d))]
        XCTAssertTrue(tree.closeSuccessor(of: a) === b, "close a: the first leaf of the sibling subtree (b/(c/d)), which is b")
        XCTAssertTrue(tree.closeSuccessor(of: b) === c, "close b (a left/top child): the sibling (c/d)'s first leaf c, the next one")
        XCTAssertTrue(tree.closeSuccessor(of: d) === c, "close d (a right/bottom child): the sibling c, the previous one")
        XCTAssertTrue(tree.closeSuccessor(of: c) === d, "close c (a left/top child): the sibling d, the next one")
    }

    func testCodableRoundTrip() throws {
        let a = try pane(), b = try pane()
        let strip = ScrollingStrip(pane: a).insertingColumnRight(of: a, pane: b)
            .resizingWidth(of: b, delta: 0.05)
        let data = try JSONEncoder().encode(strip)
        let decoded = try JSONDecoder().decode(ScrollingStrip.self, from: data)
        XCTAssertEqual(decoded.columns.count, 2)
        XCTAssertEqual(decoded.columns[1].widthFactor, ScrollingStrip.defaultWidth + ScrollingStrip.widthStep, accuracy: 0.001)
        XCTAssertEqual(decoded.columns.map(\.id), strip.columns.map(\.id), "stable column ids round-trip through the archive")
    }

    /// The peek takes pane-gap as its floor: with a large gap, 1.5% of the viewport would be nothing but
    /// transparent padding, so the peek is at least gap + 2 for the border + 4.
    @MainActor
    func testPeekGrowsWithLargePaneGap() throws {
        let a = try pane(), b = try pane(), c = try pane(), d = try pane()
        let strip = ScrollingStrip(pane: a).insertingColumnRight(of: a, pane: b)
            .insertingColumnRight(of: b, pane: c).insertingColumnRight(of: c, pane: d)
        XCTAssertGreaterThan(strip.totalWidth(viewport: 1000, gap: 0), 1000, "four columns overflow")
        let x = strip.columnWidths(viewport: 1000, gap: 0)[0]   // Left edge of the focused column b
        let normal = strip.targetOffset(for: b, current: 1500, viewport: 1000, gap: 0)
        XCTAssertEqual(x - normal, 15, accuracy: 0.5, "the default peek is 1.5% of the viewport")
        let wide = strip.targetOffset(for: b, current: 1500, viewport: 1000, gap: 0, paneGap: 20)
        XCTAssertEqual(x - wide, 26, accuracy: 0.5, "pane-gap 20 -> a 26pt peek, so the neighbour's border still shows")
        XCTAssertEqual(ScrollingStrip.peekPoints(viewport: 1000, paneGap: 5), 15, accuracy: 0.01)
    }

    /// A new column has to inherit the prevailing width factor: splitting out of a stack (Cmd+J), dragging out
    /// of a stack, and initializing the first column. Otherwise, at 3 visible columns (0.323), those columns
    /// get the two-column default of 0.485 and the row stops dividing evenly (per the user's screenshot).
    @MainActor
    func testNewColumnsInheritPrevailingWidthFactor() throws {
        let f = ScrollingStrip.factor(forVisibleColumns: 3)
        let a = try pane(), b = try pane(), c = try pane()
        var strip = ScrollingStrip(pane: a, widthFactor: f).insertingColumnRight(of: a, pane: b, widthFactor: f)
        XCTAssertEqual(strip.columns.map(\.widthFactor), [f, f])
        strip = strip.mergingOrSplitting(b)            // [a/b]
        strip = strip.mergingOrSplitting(b)            // split back out: [a][b]
        XCTAssertEqual(strip.columns.map(\.widthFactor), [f, f], "a column split out inherits the original width")
        strip = strip.insertingColumnRight(of: b, pane: c, widthFactor: f).mergingOrSplitting(c)   // [a][b/c]
        let dropped = strip.dropping(c, on: a, zone: .left)   // Drag out of the stacked column, to the far left
        XCTAssertEqual(dropped.columns.map(\.widthFactor), [f, f, f], "a column dragged out of a stack inherits the original width")
        XCTAssertEqual(ScrollingStrip(pane: a).columns[0].widthFactor, ScrollingStrip.defaultWidth,
                       "with nothing specified it is still the default")
    }

    /// Columns in an old archive carry no id and no widthFactor: decoding mints a new id and fills in the
    /// default width.
    func testColumnDecodesLegacyArchiveWithoutId() throws {
        let legacy = try JSONDecoder().decode(ScrollingStrip.Column.self,
                                              from: Data(#"{"panes":[]}"#.utf8))
        XCTAssertEqual(legacy.widthFactor, ScrollingStrip.defaultWidth, accuracy: 0.0001)
        let another = try JSONDecoder().decode(ScrollingStrip.Column.self,
                                               from: Data(#"{"panes":[],"widthFactor":0.6}"#.utf8))
        XCTAssertEqual(another.widthFactor, 0.6, accuracy: 0.0001)
        XCTAssertNotEqual(legacy.id, another.id, "with no id, each one gets its own fresh id")
    }

    /// Drag to swap: when the payload is alone in its column, that column is reused, so its id does not
    /// change, SwiftUI reads it as a move, and the pane is not remounted.
    @MainActor
    func testDroppingSoleColumnKeepsColumnIdentity() throws {
        let a = try pane(), b = try pane()
        let strip = ScrollingStrip(pane: a).insertingColumnRight(of: a, pane: b)
        let ids = strip.columns.map(\.id)
        let moved = strip.dropping(a, on: b, zone: .right)
        XCTAssertTrue(moved.columns[0].panes.first === b)
        XCTAssertTrue(moved.columns[1].panes.first === a)
        XCTAssertEqual(moved.columns.map(\.id), [ids[1], ids[0]], "the column identity travels with the pane")
        let back = moved.dropping(a, on: b, zone: .left)
        XCTAssertEqual(back.columns.map(\.id), ids)
    }
}

extension ScrollingStripTests {
    @MainActor
    func testSingleColumnFillsViewport() throws {
        let a = try pane()
        let strip = ScrollingStrip(pane: a)
        XCTAssertEqual(strip.columnWidths(viewport: 1000, gap: 0), [1000],
                       "a single column fills the viewport (the fill-mode special case)")
        XCTAssertEqual(strip.targetOffset(for: a, current: 0, viewport: 1000, gap: 0), 0)
    }

    @MainActor
    func testTwoColumnsFillWithEqualGaps() throws {
        // Fill mode, following Hyprland's gaps semantics: when nothing overflows, the columns scale up
        // proportionally to fill the viewport while the gaps stay fixed, so the left, middle and right gaps
        // come out exactly equal (the gaps themselves are PaneChrome plus the outer padding).
        let a = try pane(), b = try pane()
        let strip = ScrollingStrip(pane: a).insertingColumnRight(of: a, pane: b)
        let vp: CGFloat = 1000, gap: CGFloat = 0
        let widths = strip.columnWidths(viewport: vp, gap: gap)
        XCTAssertEqual(widths.reduce(0, +), vp, accuracy: 0.01, "two columns scale up to fill exactly")
        XCTAssertEqual(widths[0], widths[1], accuracy: 0.01, "equal factors, equal widths")
        XCTAssertEqual(strip.targetOffset(for: b, current: 0, viewport: vp, gap: gap), 0,
                       "a filled viewport means no offset: there is no slack left to hand out")
    }

    @MainActor
    func testThreeColumnsOverflowStillLeftClamped() throws {
        let a = try pane(), b = try pane(), c = try pane()
        var strip = ScrollingStrip(pane: a).insertingColumnRight(of: a, pane: b)
        strip = strip.insertingColumnRight(of: b, pane: c)
        // Overflow-mode regression: focus a at current 0 -> 0, flush left with a peek on the right.
        XCTAssertEqual(strip.targetOffset(for: a, current: 0, viewport: 1000, gap: 5), 0)
    }
}

extension ScrollingStripTests {
    func testVisibleColumnsFactor() {
        XCTAssertEqual(ScrollingStrip.factor(forVisibleColumns: 2), 0.485, accuracy: 0.001,
                       "N=2 -> (1−2×1.5%)/2 = 0.485")
        XCTAssertEqual(ScrollingStrip.factor(forVisibleColumns: 3), 0.97 / 3, accuracy: 0.001)
        XCTAssertEqual(ScrollingStrip.factor(forVisibleColumns: 4), 0.2425, accuracy: 0.001)
        XCTAssertEqual(ScrollingStrip.factor(forVisibleColumns: 0), 0.97, accuracy: 0.001, "clamped to the lower bound (N=1 = 1−2×1.5%)")
    }

    @MainActor
    func testEqualizedToFactorAppliesAllColumns() throws {
        let a = try pane(), b = try pane(), c = try pane()
        var strip = ScrollingStrip(pane: a).insertingColumnRight(of: a, pane: b)
        strip = strip.insertingColumnRight(of: b, pane: c, widthFactor: 0.7)
        let f = ScrollingStrip.factor(forVisibleColumns: 3)
        strip = strip.equalized(to: f)
        for column in strip.columns {
            XCTAssertEqual(column.widthFactor, f, accuracy: 0.001)
        }
        // Three columns × (0.98/3) do not overflow, so fill mode: they fill the viewport with equal gaps.
        let widths = strip.columnWidths(viewport: 1200, gap: 0)
        XCTAssertEqual(widths.reduce(0, +), 1200, accuracy: 0.1, "3 columns fill an extra-wide viewport exactly")
    }
}
