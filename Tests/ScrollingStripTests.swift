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
        XCTAssertTrue(strip.columns[1].panes.first === c, "新列应插在锚点列右侧")
        XCTAssertTrue(strip.columns[2].panes.first === b)
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
        // [a][b] 然后 b 拆栈：b 列加 c（用 dropping bottom 模拟栈叠）
        var strip = ScrollingStrip(pane: a).insertingColumnRight(of: a, pane: b)
        strip = strip.insertingColumnRight(of: b, pane: c)
        strip = strip.dropping(c, on: b, zone: .bottom)      // [a][b/c]
        XCTAssertEqual(strip.columns.count, 2)
        XCTAssertEqual(strip.columns[1].panes.count, 2)
        XCTAssertTrue(strip.focusTarget(from: a, direction: .right) === b)
        XCTAssertTrue(strip.focusTarget(from: b, direction: .down) === c)
        XCTAssertTrue(strip.focusTarget(from: c, direction: .up) === b)
        XCTAssertTrue(strip.focusTarget(from: c, direction: .left) === a, "跨列取就近行")
        XCTAssertNil(strip.focusTarget(from: a, direction: .left), "左端不回绕")
    }

    func testSwapColumnAndRow() throws {
        let a = try pane(), b = try pane()
        var strip = ScrollingStrip(pane: a).insertingColumnRight(of: a, pane: b)
        strip = strip.swapping(a, direction: .right)         // [b][a]
        XCTAssertTrue(strip.columns[0].panes.first === b)
        strip = strip.dropping(b, on: a, zone: .top)         // [b/a] 单列
        strip = strip.swapping(a, direction: .up)            // 列内换位 [a/b]
        XCTAssertTrue(strip.columns[0].panes.first === a)
    }

    func testMergeAndSplit() throws {
        let a = try pane(), b = try pane()
        var strip = ScrollingStrip(pane: a).insertingColumnRight(of: a, pane: b)
        strip = strip.mergingOrSplitting(b)                  // b 併入左列 [a/b]
        XCTAssertEqual(strip.columns.count, 1)
        XCTAssertEqual(strip.columns[0].panes.count, 2)
        strip = strip.mergingOrSplitting(b)                  // b 拆出 [a][b]
        XCTAssertEqual(strip.columns.count, 2)
        XCTAssertTrue(strip.columns[1].panes.first === b)
    }

    func testResizeClampAndEqualize() throws {
        let a = try pane()
        var strip = ScrollingStrip(pane: a)
        for _ in 0..<20 { strip = strip.resizingWidth(of: a, delta: ScrollingStrip.widthStep) }
        XCTAssertEqual(strip.columns[0].widthFactor, 0.90, accuracy: 0.001, "上限 90%")
        strip = strip.equalized()
        XCTAssertEqual(strip.columns[0].widthFactor, 0.49, accuracy: 0.001)
    }

    func testTargetOffsetMinimalScroll() throws {
        let a = try pane(), b = try pane(), c = try pane()
        var strip = ScrollingStrip(pane: a)
        strip = strip.insertingColumnRight(of: a, pane: b)
        strip = strip.insertingColumnRight(of: b, pane: c)   // [a][b][c] 各 0.49
        let vp: CGFloat = 1000, gap: CGFloat = 5
        // 焦点在 a：offset 0 不动
        XCTAssertEqual(strip.targetOffset(for: a, current: 0, viewport: vp, gap: gap), 0)
        // 焦点在 b：[495,985] 已完全可见 → 最小滚动 = 不动（露边由此而来）
        XCTAssertEqual(strip.targetOffset(for: b, current: 0, viewport: vp, gap: gap), 0)
        // 焦点在 c：x=990, 需右缘对齐 → offset = 990+490-1000 = 480
        XCTAssertEqual(strip.targetOffset(for: c, current: 0, viewport: vp, gap: gap), 480, accuracy: 0.5)
        // 从右往左回焦 a：需左缘对齐 → 0
        XCTAssertEqual(strip.targetOffset(for: a, current: 480, viewport: vp, gap: gap), 0)
        // 焦点 b、当前 480：b 完全可见 → 不动（左侧 a 露边）
        XCTAssertEqual(strip.targetOffset(for: b, current: 480, viewport: vp, gap: gap), 480)
    }

    func testDwindleRoundTripPreservesPanes() throws {
        let a = try pane(), b = try pane(), c = try pane()
        var strip = ScrollingStrip(pane: a).insertingColumnRight(of: a, pane: b)
        strip = strip.insertingColumnRight(of: b, pane: c)
        strip = strip.dropping(c, on: b, zone: .bottom)      // [a][b/c]
        let tree = strip.toTree()
        XCTAssertEqual(tree.root?.leaves().count, 3, "转树保 pane")
        let back = ScrollingStrip.from(tree: tree)
        XCTAssertEqual(back.paneList.count, 3, "转回保 pane")
        XCTAssertTrue(back.paneList[0] === a)
    }

    func testCodableRoundTrip() throws {
        let a = try pane(), b = try pane()
        let strip = ScrollingStrip(pane: a).insertingColumnRight(of: a, pane: b)
            .resizingWidth(of: b, delta: 0.05)
        let data = try JSONEncoder().encode(strip)
        let decoded = try JSONDecoder().decode(ScrollingStrip.self, from: data)
        XCTAssertEqual(decoded.columns.count, 2)
        XCTAssertEqual(decoded.columns[1].widthFactor, 0.54, accuracy: 0.001)
    }
}
