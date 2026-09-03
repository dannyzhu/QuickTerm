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

    /// 结构签名：换位/併拆改变签名（驱动视口重对齐）；
    /// 调宽刻意不改（右键拖拽逐事件调宽，入签名会劫持手动平移的视口）
    func testLayoutSignatureStructuralOnly() throws {
        let a = try pane(), b = try pane()
        var strip = ScrollingStrip(pane: a)
        strip = strip.insertingColumnRight(of: a, pane: b)   // [a][b]
        let base = strip.layoutSignature
        XCTAssertEqual(strip.layoutSignature, base, "同一布局签名稳定")
        XCTAssertNotEqual(strip.swapping(a, direction: .right).layoutSignature, base,
                          "换列改变签名——Cmd+Shift+方向 需触发滚动跟随")
        XCTAssertNotEqual(strip.mergingOrSplitting(b).layoutSignature, base,
                          "併列改变签名（[a][b] → [a,b]）")
        XCTAssertEqual(strip.resizingWidth(of: a, delta: 0.05).layoutSignature, base,
                       "调宽不改签名")
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

    /// Cmd+L 往返：pane 集合没变时恢复原 scrolling 排布（列栈与列宽），而非摊成 N 个单列
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
        guard case .dwindle(let tree) = model.layout else { return XCTFail("应切到 dwindle") }
        XCTAssertEqual(tree.root?.leaves().count, 5, "dwindle 保 5 个 pane")

        model.toggleLayout(columnFactor: 0.327)
        guard case .scrolling(let back) = model.layout else { return XCTFail("应切回 scrolling") }
        XCTAssertEqual(back.columns.count, 3, "恢复 3 列排布，而非 5 个单列（否则溢出视口只见 3 个）")
        XCTAssertTrue(back.columns[1].panes.count == 2 && back.columns[1].panes[0] === b
                      && back.columns[1].panes[1] === c, "列栈原样恢复")
        XCTAssertEqual(back.columns[0].widthFactor, 0.327, accuracy: 0.001, "列宽原样恢复")

        // pane 集合变了（dwindle 里关掉 e）→ 退回转换：4 个单列，列宽遵循每屏列数设置
        model.toggleLayout(columnFactor: 0.327)
        guard case .dwindle(let tree2) = model.layout else { return XCTFail() }
        model.layout = .dwindle(tree2.removing(.leaf(view: e)))
        model.toggleLayout(columnFactor: 0.327)
        guard case .scrolling(let converted) = model.layout else { return XCTFail() }
        XCTAssertEqual(converted.columns.count, 4, "集合变化后按保 pane 保序转换")
        XCTAssertEqual(converted.columns[0].widthFactor, 0.327, accuracy: 0.001,
                       "转换列宽遵循当前每屏列数（原来固定 0.49）")
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

extension ScrollingStripTests {
    @MainActor
    func testSingleColumnFillsViewport() throws {
        let a = try pane()
        let strip = ScrollingStrip(pane: a)
        XCTAssertEqual(strip.columnWidths(viewport: 1000, gap: 0), [1000],
                       "单列填满视口（填充模式特例）")
        XCTAssertEqual(strip.targetOffset(for: a, current: 0, viewport: 1000, gap: 0), 0)
    }

    @MainActor
    func testTwoColumnsFillWithEqualGaps() throws {
        // 填充模式（参照 Hyprland gaps 语义）：不溢出时列宽按比例放大填满，
        // 间隙固定 → 左中右三个间隔精确相等（间隙本身由 PaneChrome/外圈 padding 构成）
        let a = try pane(), b = try pane()
        let strip = ScrollingStrip(pane: a).insertingColumnRight(of: a, pane: b)
        let vp: CGFloat = 1000, gap: CGFloat = 0
        let widths = strip.columnWidths(viewport: vp, gap: gap)
        XCTAssertEqual(widths.reduce(0, +), vp, accuracy: 0.01, "两列放大到恰好填满")
        XCTAssertEqual(widths[0], widths[1], accuracy: 0.01, "等 factor 等宽")
        XCTAssertEqual(strip.targetOffset(for: b, current: 0, viewport: vp, gap: gap), 0,
                       "填满即无偏移（无多余留白可分配）")
    }

    @MainActor
    func testThreeColumnsOverflowStillLeftClamped() throws {
        let a = try pane(), b = try pane(), c = try pane()
        var strip = ScrollingStrip(pane: a).insertingColumnRight(of: a, pane: b)
        strip = strip.insertingColumnRight(of: b, pane: c)
        // 溢出模式回归：焦点 a、current 0 → 0（左缘贴边，右露边）
        XCTAssertEqual(strip.targetOffset(for: a, current: 0, viewport: 1000, gap: 5), 0)
    }
}

extension ScrollingStripTests {
    func testVisibleColumnsFactor() {
        XCTAssertEqual(ScrollingStrip.factor(forVisibleColumns: 2), 0.49, accuracy: 0.001,
                       "N=2 与 Omarchy column_width 一致")
        XCTAssertEqual(ScrollingStrip.factor(forVisibleColumns: 3), 0.98 / 3, accuracy: 0.001)
        XCTAssertEqual(ScrollingStrip.factor(forVisibleColumns: 4), 0.245, accuracy: 0.001)
        XCTAssertEqual(ScrollingStrip.factor(forVisibleColumns: 0), 0.98, accuracy: 0.001, "clamp 下限")
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
        // 三列 × (0.98/3) 不溢出 → 填充模式：三列填满、间隙等宽
        let widths = strip.columnWidths(viewport: 1200, gap: 0)
        XCTAssertEqual(widths.reduce(0, +), 1200, accuracy: 0.1, "3 列恰好填满超宽视口")
    }
}
