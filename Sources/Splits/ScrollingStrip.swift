import AppKit

/// Omarchy `scrolling` 布局的数据模型（spec §4.2-bis）：
/// 工作区 = 无限横向列条带；每列宽 0.49×视口（可调），列内纵向栈叠。
/// 与 SplitTree 同风格：不可变值语义；不存焦点——所有操作以"某个 pane"为锚，
/// 由控制器用 focusedSurface 反查，悬停焦点因此天然同步。
struct ScrollingStrip: Codable {
    struct Column: Codable {
        var panes: [Ghostty.SurfaceView]
        var widthFactor: Double = ScrollingStrip.defaultWidth
    }

    static let defaultWidth = 0.49
    static let widthStep = 0.05
    static let widthRange = 0.25...0.90

    var columns: [Column] = []
    /// zoom：该 pane 占满内容区（结构性变更时清空）
    var zoomedID: UUID?

    enum Direction { case left, right, up, down }

    init() {}

    init(pane: Ghostty.SurfaceView) {
        columns = [Column(panes: [pane])]
    }

    init(columns: [Column], zoomedID: UUID? = nil) {
        self.columns = columns
        self.zoomedID = zoomedID
    }

    var isEmpty: Bool { columns.isEmpty }
    var paneList: [Ghostty.SurfaceView] { columns.flatMap(\.panes) }

    var zoomedPane: Ghostty.SurfaceView? {
        guard let zoomedID else { return nil }
        return paneList.first { $0.id == zoomedID }
    }

    /// pane → (列, 行)
    func position(of pane: Ghostty.SurfaceView) -> (col: Int, row: Int)? {
        for (c, column) in columns.enumerated() {
            if let r = column.panes.firstIndex(where: { $0 === pane }) {
                return (c, r)
            }
        }
        return nil
    }

    // MARK: 结构操作（全部返回新值；结构变更清 zoom）

    /// 焦点列右侧插入新列（Cmd+Return 语义，截图 3）
    func insertingColumnRight(of anchor: Ghostty.SurfaceView?, pane: Ghostty.SurfaceView) -> Self {
        var next = self
        next.zoomedID = nil
        let insertAt = anchor.flatMap { position(of: $0)?.col.advanced(by: 1) } ?? columns.count
        next.columns.insert(Column(panes: [pane]), at: min(insertAt, columns.count))
        return next
    }

    /// 关 pane：空列删除（spec：焦点左移由控制器处理）
    func removing(_ pane: Ghostty.SurfaceView) -> Self {
        guard let (c, r) = position(of: pane) else { return self }
        var next = self
        next.zoomedID = nil
        next.columns[c].panes.remove(at: r)
        if next.columns[c].panes.isEmpty {
            next.columns.remove(at: c)
        }
        return next
    }

    /// 方向焦点目标（左右跨列取同高度就近行；上下列内移动；不回绕）
    func focusTarget(from pane: Ghostty.SurfaceView, direction: Direction) -> Ghostty.SurfaceView? {
        guard let (c, r) = position(of: pane) else { return nil }
        switch direction {
        case .left:
            guard c > 0 else { return nil }
            let target = columns[c - 1]
            return target.panes[min(r, target.panes.count - 1)]
        case .right:
            guard c < columns.count - 1 else { return nil }
            let target = columns[c + 1]
            return target.panes[min(r, target.panes.count - 1)]
        case .up:
            guard r > 0 else { return nil }
            return columns[c].panes[r - 1]
        case .down:
            guard r < columns[c].panes.count - 1 else { return nil }
            return columns[c].panes[r + 1]
        }
    }

    /// 线性循环（Alt+Tab / Cmd+[]）：列序×行序，回绕
    func linearTarget(from pane: Ghostty.SurfaceView, next: Bool) -> Ghostty.SurfaceView? {
        let all = paneList
        guard all.count > 1, let i = all.firstIndex(where: { $0 === pane }) else { return nil }
        return all[(i + (next ? 1 : all.count - 1)) % all.count]
    }

    /// 换位：左右 = 整列换位；上下 = 列内换位
    func swapping(_ pane: Ghostty.SurfaceView, direction: Direction) -> Self {
        guard let (c, r) = position(of: pane) else { return self }
        var next = self
        next.zoomedID = nil
        switch direction {
        case .left where c > 0:
            next.columns.swapAt(c, c - 1)
        case .right where c < columns.count - 1:
            next.columns.swapAt(c, c + 1)
        case .up where r > 0:
            next.columns[c].panes.swapAt(r, r - 1)
        case .down where r < columns[c].panes.count - 1:
            next.columns[c].panes.swapAt(r, r + 1)
        default:
            return self
        }
        return next
    }

    /// Cmd+J：单 pane 列 → 併入左列纵栈；多 pane 列 → 焦点 pane 拆出为右侧独立列
    func mergingOrSplitting(_ pane: Ghostty.SurfaceView) -> Self {
        guard let (c, r) = position(of: pane) else { return self }
        var next = self
        next.zoomedID = nil
        if columns[c].panes.count == 1 {
            guard c > 0 else { return self }
            next.columns[c - 1].panes.append(pane)
            next.columns.remove(at: c)
        } else {
            next.columns[c].panes.remove(at: r)
            next.columns.insert(Column(panes: [pane]), at: c + 1)
        }
        return next
    }

    /// 调列宽（Cmd+Ctrl+←/→，±5%，25%–90%）
    func resizingWidth(of pane: Ghostty.SurfaceView, delta: Double) -> Self {
        guard let (c, _) = position(of: pane) else { return self }
        var next = self
        next.columns[c].widthFactor = min(
            max(columns[c].widthFactor + delta, Self.widthRange.lowerBound),
            Self.widthRange.upperBound)
        return next
    }

    /// 全列宽重置 0.49（Cmd+Ctrl+=）
    func equalized() -> Self {
        var next = self
        for i in next.columns.indices {
            next.columns[i].widthFactor = Self.defaultWidth
        }
        return next
    }

    func togglingZoom(_ pane: Ghostty.SurfaceView) -> Self {
        var next = self
        next.zoomedID = (zoomedID == pane.id) ? nil : pane.id
        return next
    }

    /// 拖放（spec §4.2-bis）：左右缘 = 目标列旁插新列；上下缘 = 併入目标列栈；中心 = 交换
    func dropping(_ payload: Ghostty.SurfaceView,
                  on destination: Ghostty.SurfaceView,
                  zone: TerminalSplitDropZone) -> Self {
        guard payload !== destination,
              position(of: payload) != nil else { return self }
        var next = removing(payload)
        guard let (dc, dr) = next.position(of: destination) else { return self }
        next.zoomedID = nil
        switch zone {
        case .left:
            next.columns.insert(Column(panes: [payload]), at: dc)
        case .right:
            next.columns.insert(Column(panes: [payload]), at: dc + 1)
        case .top:
            next.columns[dc].panes.insert(payload, at: dr)
        case .bottom:
            next.columns[dc].panes.insert(payload, at: dr + 1)
        case .center:
            guard let (pc, pr) = position(of: payload),
                  let (odc, odr) = position(of: destination) else { return self }
            var swapped = self
            swapped.zoomedID = nil
            swapped.columns[pc].panes[pr] = destination
            swapped.columns[odc].panes[odr] = payload
            return swapped
        }
        return next
    }

    // MARK: 视口滚动（纯函数，可测）

    /// 最小滚动量让锚 pane 所在列完全可见。
    /// - current: 当前偏移（内容坐标，向右为正）
    /// - 返回 clamp 到 [0, 内容总宽−视口] 的新偏移
    func targetOffset(for pane: Ghostty.SurfaceView,
                      current: CGFloat, viewport: CGFloat, gap: CGFloat) -> CGFloat {
        guard viewport > 0, let (c, _) = position(of: pane) else { return current }
        var x: CGFloat = 0
        for i in 0..<c { x += CGFloat(columns[i].widthFactor) * viewport + gap }
        let width = CGFloat(columns[c].widthFactor) * viewport
        let total = columns.reduce(CGFloat(0)) { $0 + CGFloat($1.widthFactor) * viewport + gap } - gap
        let minOffset = x + width - viewport   // 右缘对齐
        let maxOffset = x                      // 左缘对齐
        let desired = min(max(current, minOffset), maxOffset)
        return min(max(desired, 0), max(0, total - viewport))
    }

    // MARK: 与 dwindle 互转（Cmd+L；保 pane 保序）

    static func from(tree: SplitTree<Ghostty.SurfaceView>) -> Self {
        ScrollingStrip(columns: tree.root?.leaves().map { Column(panes: [$0]) } ?? [])
    }

    func toTree() -> SplitTree<Ghostty.SurfaceView> {
        var tree = SplitTree<Ghostty.SurfaceView>()
        var previousHead: Ghostty.SurfaceView?
        for column in columns {
            guard let head = column.panes.first else { continue }
            if let anchor = previousHead {
                tree = (try? tree.inserting(view: head, at: anchor, direction: .right)) ?? tree
            } else {
                tree = SplitTree(view: head)
            }
            var stackAnchor = head
            for pane in column.panes.dropFirst() {
                tree = (try? tree.inserting(view: pane, at: stackAnchor, direction: .down)) ?? tree
                stackAnchor = pane
            }
            previousHead = head
        }
        return tree
    }
}
