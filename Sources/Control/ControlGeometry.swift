import AppKit

/// 布局的**几何**：每个 pane 有多大、每条分隔条在哪儿。
///
/// 一条规则贯穿始终：**以模型为准**。归一化矩形全部由 dwindle 的 ratio / scrolling 的列宽因子
/// 算出来（用的正是渲染那两套公式：`SplitTree.spatial` 与 `ScrollingStrip.columnWidths`），
/// 而不是去读 `NSView.frame`——pane 在 SwiftUI 重建期间会脱离窗口，那一瞬间 frame 是零或过期的，
/// 而"读一下尺寸"绝不该等一帧、更不该报一个上一帧的数。
/// 点尺寸是归一化矩形乘上内容区，同样是算出来的；内容区读不到（窗口没挂上）时整段省略。
@MainActor
enum ControlGeometry {
    /// 归一化用的单位方框（左上角原点，与 `spatial` / SwiftUI 同向）。
    /// `nonisolated`：它是个常量，还要当默认参数用（默认参数在调用方的隔离域里求值）
    nonisolated static let unit = CGSize(width: 1, height: 1)

    /// 工作区布局区（pt）= `MainWindowController.workspaceLayoutSize`：
    /// contentView 去掉顶部状态条、再去掉外圈那一圈 pane-gap 留白——**分裂树 / 条带
    /// 真正铺开的那块地**，也正是 `SplitView` 的 `GeometryReader` 量到的那块。
    ///
    /// **与调分隔条那条路径同源**：`controlResizeSplit` / `resizeFocused` / ⌘右键拖拽
    /// 换算点数用的是同一个 `workspaceLayoutSize`。报出来的尺寸和 `--points` 的换算
    /// 必须踩在同一块底上，否则 agent 按报出来的点数去调会差一截，
    /// 夹取也会把分隔条放到鼠标拖不到的地方
    static func contentSize(_ controller: MainWindowController) -> CGSize? {
        controller.workspaceLayoutSize
    }

    // MARK: dwindle

    /// 树里每个 pane 的矩形（在 `size` 这个方框里）
    static func paneRects(in tree: SplitTree<PaneView>, size: CGSize) -> [UUID: CGRect] {
        guard let root = tree.root else { return [:] }
        var out: [UUID: CGRect] = [:]
        for slot in root.spatial(within: size).slots {
            if case .leaf(let view) = slot.node { out[view.id] = slot.bounds }
        }
        return out
    }

    /// 树里的一条分裂（= 一条分隔条）
    struct SplitSlot {
        /// `a`/`b` 点号串（根是空串）——与 `pane.at.path`、`spec` 的 `focus.path` 同一套写法
        var path: String
        var node: SplitTree<PaneView>.Node
        /// `horizontal` = a 左 b 右；`vertical` = a 上 b 下
        var direction: String
        var ratio: Double
        /// 这条分裂占的矩形（分隔条就在它的 `ratio` 处）
        var bounds: CGRect
    }

    /// 树里全部分裂节点（前序：根在最前）
    static func splits(in tree: SplitTree<PaneView>, size: CGSize) -> [SplitSlot] {
        guard let root = tree.root else { return [] }
        var out: [SplitSlot] = []
        func walk(_ node: SplitTree<PaneView>.Node, path: [String], bounds: CGRect) {
            guard case .split(let split) = node else { return }
            let horizontal = split.direction == .horizontal
            out.append(SplitSlot(path: path.joined(separator: "."), node: node,
                                 direction: horizontal ? "horizontal" : "vertical",
                                 ratio: split.ratio, bounds: bounds))
            let a: CGRect
            let b: CGRect
            if horizontal {
                a = CGRect(x: bounds.minX, y: bounds.minY,
                           width: bounds.width * split.ratio, height: bounds.height)
                b = CGRect(x: bounds.minX + bounds.width * split.ratio, y: bounds.minY,
                           width: bounds.width * (1 - split.ratio), height: bounds.height)
            } else {
                a = CGRect(x: bounds.minX, y: bounds.minY,
                           width: bounds.width, height: bounds.height * split.ratio)
                b = CGRect(x: bounds.minX, y: bounds.minY + bounds.height * split.ratio,
                           width: bounds.width, height: bounds.height * (1 - split.ratio))
            }
            walk(split.left, path: path + ["a"], bounds: a)
            walk(split.right, path: path + ["b"], bounds: b)
        }
        walk(root, path: [], bounds: CGRect(origin: .zero, size: size))
        return out
    }

    /// 这条分裂沿分隔方向的长度（pt）：`--points` 与比例之间就是除以它
    static func span(of slot: SplitSlot) -> CGFloat {
        slot.direction == "horizontal" ? slot.bounds.width : slot.bounds.height
    }

    // MARK: scrolling

    /// 条带里每个 pane 的矩形（列宽走 `columnWidths`，与渲染同一套：
    /// 装得下时按比例放大填满，溢出时用名义列宽；列内等分纵栈）
    static func paneRects(in strip: ScrollingStrip, size: CGSize) -> [UUID: CGRect] {
        let widths = strip.columnWidths(viewport: size.width, gap: 0)
        var out: [UUID: CGRect] = [:]
        var x: CGFloat = 0
        for (index, column) in strip.columns.enumerated() {
            let width = index < widths.count ? widths[index] : 0
            let rows = max(column.panes.count, 1)
            let height = size.height / CGFloat(rows)
            for (row, pane) in column.panes.enumerated() {
                out[pane.id] = CGRect(x: x, y: CGFloat(row) * height, width: width, height: height)
            }
            x += width
        }
        return out
    }

    // MARK: 统一入口

    static func paneRects(in layout: WorkspaceLayout, size: CGSize) -> [UUID: CGRect] {
        switch layout {
        case .dwindle(let tree): paneRects(in: tree, size: size)
        case .scrolling(let strip): paneRects(in: strip, size: size)
        }
    }

    /// 数值定点：归一化 4 位、点数 1 位。
    /// 定点是为了 `dump → apply → dump` 与"读回来的数等于写下去的数"——
    /// 浮点尾巴会让不动点用例随机地差一个 ULP
    static func rounded(_ value: CGFloat, _ digits: Int = 4) -> Double {
        let scale = pow(10.0, Double(digits))
        return (Double(value) * scale).rounded() / scale
    }

    static func rect(_ rect: CGRect, digits: Int = 4) -> [Double] {
        [rounded(rect.origin.x, digits), rounded(rect.origin.y, digits),
         rounded(rect.size.width, digits), rounded(rect.size.height, digits)]
    }
}
