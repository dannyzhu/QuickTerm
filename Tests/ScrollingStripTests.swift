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
        XCTAssertEqual(strip.columns[0].widthFactor, ScrollingStrip.defaultWidth, accuracy: 0.001)
        XCTAssertEqual(ScrollingStrip.defaultWidth, 0.485, accuracy: 0.001, "两列 = (1−2×1.5%)/2")
    }

    func testTargetOffsetMinimalScroll() throws {
        let a = try pane(), b = try pane(), c = try pane()
        var strip = ScrollingStrip(pane: a)
        strip = strip.insertingColumnRight(of: a, pane: b)
        strip = strip.insertingColumnRight(of: b, pane: c)   // [a][b][c] 各 0.485，总宽 1465（含 2 个 gap）
        let vp: CGFloat = 1000, gap: CGFloat = 5
        // 焦点在 a：offset 0 不动
        XCTAssertEqual(strip.targetOffset(for: a, current: 0, viewport: vp, gap: gap), 0)
        // 焦点在 b：[490,975] 完整可见且右侧仍有露边 → 最小滚动 = 不动
        XCTAssertEqual(strip.targetOffset(for: b, current: 0, viewport: vp, gap: gap), 0)
        // 焦点在 c（末列）：x=980，右缘对齐+露边 = 480，但被总宽钳到 1465-1000 = 465（末列贴边）
        XCTAssertEqual(strip.targetOffset(for: c, current: 0, viewport: vp, gap: gap), 465, accuracy: 0.5)
        // 从右往左回焦 a：左缘对齐+露边 → 负值钳到 0
        XCTAssertEqual(strip.targetOffset(for: a, current: 465, viewport: vp, gap: gap), 0)
        // 焦点 b、当前 465：b 完整可见（左侧 a 露 20）→ 不动
        XCTAssertEqual(strip.targetOffset(for: b, current: 465, viewport: vp, gap: gap), 465)
    }

    /// 4 列、焦点在内部：中间两列全显，左右两列各露出一个露边（对称）——
    /// 原 2% 露边只剩空壳、且贴边对齐永远只露一侧（用户截图）
    func testInteriorFocusShowsSymmetricPeeks() throws {
        let a = try pane(), b = try pane(), c = try pane(), d = try pane()
        var strip = ScrollingStrip(pane: a).insertingColumnRight(of: a, pane: b)
        strip = strip.insertingColumnRight(of: b, pane: c).insertingColumnRight(of: c, pane: d)
        let vp: CGFloat = 1000, gap: CGFloat = 0
        let w = ScrollingStrip.factor(forVisibleColumns: 2) * 1000   // 485
        let peek = ScrollingStrip.peek * 1000                         // 15
        let offset = strip.targetOffset(for: c, current: 0, viewport: vp, gap: gap)
        XCTAssertEqual(offset, 2 * w + w + peek - vp, accuracy: 0.5, "c 右缘对齐并留右露边 → 470")
        // 可见区 [470,1470)：a 露 15、b 全、c 全、d 露 15
        XCTAssertEqual(w - offset, peek, accuracy: 0.5, "左邻 a 露出一个露边")
        XCTAssertEqual(offset + vp - 3 * w, peek, accuracy: 0.5, "右邻 d 露出一个露边")
        XCTAssertGreaterThanOrEqual(w - offset, 0); XCTAssertLessThanOrEqual(3 * w - offset, vp)
        // 末列 d：贴右边（右侧无邻列不留白）
        XCTAssertEqual(strip.targetOffset(for: d, current: offset, viewport: vp, gap: gap),
                       4 * w - vp, accuracy: 0.5)
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

    /// dwindle 分裂方向由树的空间几何决定：宽 > 高 → 右，否则 → 下（不依赖视图 frame）
    func testDwindleDirectionFollowsSpatialAspect() throws {
        let a = try pane(), b = try pane()
        let bounds = CGSize(width: 1000, height: 600)
        var tree = SplitTree(view: a)
        XCTAssertEqual(tree.dwindleDirection(for: a, in: bounds), .right, "整屏宽 > 高 → 右侧")
        tree = try tree.inserting(view: b, at: a, direction: .right)      // a 占左半 500×600
        XCTAssertEqual(tree.dwindleDirection(for: a, in: bounds), .down, "左半列高 > 宽 → 下方")
        XCTAssertEqual(tree.dwindleDirection(for: b, in: bounds), .down)
        let c = try pane()
        tree = try tree.inserting(view: c, at: b, direction: .down)      // b 占右上 500×300
        XCTAssertEqual(tree.dwindleDirection(for: b, in: bounds), .right, "右上 500×300 宽 > 高 → 右侧")
    }

    /// dwindle 关闭后的焦点去向：接管空间的兄弟子树里最近的叶（左孩子→兄弟首叶；右孩子→兄弟末叶）
    func testDwindleCloseSuccessorGoesToSibling() throws {
        let a = try pane(), b = try pane(), c = try pane(), d = try pane()
        var tree = SplitTree(view: a)
        XCTAssertNil(tree.closeSuccessor(of: a), "单叶无后继")
        tree = try tree.inserting(view: b, at: a, direction: .right)   // [a | b]
        tree = try tree.inserting(view: c, at: b, direction: .down)    // [a | (b / c)]
        tree = try tree.inserting(view: d, at: c, direction: .down)    // [a | (b / (c / d))]
        XCTAssertTrue(tree.closeSuccessor(of: a) === b, "关 a：兄弟子树 (b/(c/d)) 的第一个叶 b")
        XCTAssertTrue(tree.closeSuccessor(of: b) === c, "关 b（左/上孩子）：兄弟 (c/d) 的首叶 c（下一个）")
        XCTAssertTrue(tree.closeSuccessor(of: d) === c, "关 d（右/下孩子）：兄弟 c（上一个）")
        XCTAssertTrue(tree.closeSuccessor(of: c) === d, "关 c（左/上孩子）：兄弟 d（下一个）")
    }

    func testCodableRoundTrip() throws {
        let a = try pane(), b = try pane()
        let strip = ScrollingStrip(pane: a).insertingColumnRight(of: a, pane: b)
            .resizingWidth(of: b, delta: 0.05)
        let data = try JSONEncoder().encode(strip)
        let decoded = try JSONDecoder().decode(ScrollingStrip.self, from: data)
        XCTAssertEqual(decoded.columns.count, 2)
        XCTAssertEqual(decoded.columns[1].widthFactor, ScrollingStrip.defaultWidth + ScrollingStrip.widthStep, accuracy: 0.001)
        XCTAssertEqual(decoded.columns.map(\.id), strip.columns.map(\.id), "列稳定 id 随存档往返")
    }

    /// 露边随 pane-gap 取下限：gap 大时 1.5% 视口会全是透明留白，露边至少 gap + 边框 2 + 4
    @MainActor
    func testPeekGrowsWithLargePaneGap() throws {
        let a = try pane(), b = try pane(), c = try pane(), d = try pane()
        let strip = ScrollingStrip(pane: a).insertingColumnRight(of: a, pane: b)
            .insertingColumnRight(of: b, pane: c).insertingColumnRight(of: c, pane: d)
        XCTAssertGreaterThan(strip.totalWidth(viewport: 1000, gap: 0), 1000, "四列溢出")
        let x = strip.columnWidths(viewport: 1000, gap: 0)[0]   // 焦点列 b 的左缘
        let normal = strip.targetOffset(for: b, current: 1500, viewport: 1000, gap: 0)
        XCTAssertEqual(x - normal, 15, accuracy: 0.5, "默认露边 = 1.5% 视口")
        let wide = strip.targetOffset(for: b, current: 1500, viewport: 1000, gap: 0, paneGap: 20)
        XCTAssertEqual(x - wide, 26, accuracy: 0.5, "pane-gap 20 → 露边 26，邻列边框仍露出")
        XCTAssertEqual(ScrollingStrip.peekPoints(viewport: 1000, paneGap: 5), 15, accuracy: 0.01)
    }

    /// 新建列必须沿用当前列宽因子：拆出叠栈列（Cmd+J）、从叠栈列拖出、首列初始化——
    /// 否则每屏 3 列（0.323）时这些列拿到两列默认 0.485，水平不等分（用户截图）
    @MainActor
    func testNewColumnsInheritPrevailingWidthFactor() throws {
        let f = ScrollingStrip.factor(forVisibleColumns: 3)
        let a = try pane(), b = try pane(), c = try pane()
        var strip = ScrollingStrip(pane: a, widthFactor: f).insertingColumnRight(of: a, pane: b, widthFactor: f)
        XCTAssertEqual(strip.columns.map(\.widthFactor), [f, f])
        strip = strip.mergingOrSplitting(b)            // [a/b]
        strip = strip.mergingOrSplitting(b)            // 拆出 [a][b]
        XCTAssertEqual(strip.columns.map(\.widthFactor), [f, f], "拆出的列沿用原列宽度")
        strip = strip.insertingColumnRight(of: b, pane: c, widthFactor: f).mergingOrSplitting(c)   // [a][b/c]
        let dropped = strip.dropping(c, on: a, zone: .left)   // 从叠栈列拖出到最左
        XCTAssertEqual(dropped.columns.map(\.widthFactor), [f, f, f], "从叠栈列拖出的列沿用原列宽度")
        XCTAssertEqual(ScrollingStrip(pane: a).columns[0].widthFactor, ScrollingStrip.defaultWidth, "未指定时仍是默认")
    }

    /// 旧存档的列没有 id / widthFactor：解码补新 id 与默认宽
    func testColumnDecodesLegacyArchiveWithoutId() throws {
        let legacy = try JSONDecoder().decode(ScrollingStrip.Column.self,
                                              from: Data(#"{"panes":[]}"#.utf8))
        XCTAssertEqual(legacy.widthFactor, ScrollingStrip.defaultWidth, accuracy: 0.0001)
        let another = try JSONDecoder().decode(ScrollingStrip.Column.self,
                                               from: Data(#"{"panes":[],"widthFactor":0.6}"#.utf8))
        XCTAssertEqual(another.widthFactor, 0.6, accuracy: 0.0001)
        XCTAssertNotEqual(legacy.id, another.id, "缺 id 时各自补新 id")
    }

    /// 拖拽换位：载荷独占一列时沿用原列（id 不变 → SwiftUI 视作移动，pane 不重挂）
    @MainActor
    func testDroppingSoleColumnKeepsColumnIdentity() throws {
        let a = try pane(), b = try pane()
        let strip = ScrollingStrip(pane: a).insertingColumnRight(of: a, pane: b)
        let ids = strip.columns.map(\.id)
        let moved = strip.dropping(a, on: b, zone: .right)
        XCTAssertTrue(moved.columns[0].panes.first === b)
        XCTAssertTrue(moved.columns[1].panes.first === a)
        XCTAssertEqual(moved.columns.map(\.id), [ids[1], ids[0]], "列身份随 pane 一起移动")
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
        XCTAssertEqual(ScrollingStrip.factor(forVisibleColumns: 2), 0.485, accuracy: 0.001,
                       "N=2 → (1−2×1.5%)/2 = 0.485")
        XCTAssertEqual(ScrollingStrip.factor(forVisibleColumns: 3), 0.97 / 3, accuracy: 0.001)
        XCTAssertEqual(ScrollingStrip.factor(forVisibleColumns: 4), 0.2425, accuracy: 0.001)
        XCTAssertEqual(ScrollingStrip.factor(forVisibleColumns: 0), 0.97, accuracy: 0.001, "clamp 下限（N=1 = 1−2×1.5%）")
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
