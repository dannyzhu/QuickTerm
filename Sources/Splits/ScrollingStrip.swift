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

    /// "每屏可见 N 列" → 列宽因子（N=2 → 0.49 与 Omarchy 一致，留 2% 露边余量）
    static func factor(forVisibleColumns n: Int) -> Double {
        0.98 / Double(min(max(n, 1), 6))
    }

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

    /// 结构签名（列序/行序）：变化时视口需按焦点重新对齐——
    /// 换位/併拆不改焦点 ID 与列数，仅靠它们触发不了滚动跟随。
    /// 刻意不含 widthFactor：右键拖拽调宽是逐事件写宽度，
    /// 入签名会把手动平移的视口逐帧劫持回焦点列。
    var layoutSignature: Int {
        var hasher = Hasher()
        for column in columns {
            hasher.combine(column.panes.count)  // 分组定界：[a][b,c] ≠ [a,b][c]
            for pane in column.panes { hasher.combine(pane.id) }
        }
        return hasher.finalize()
    }

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
    func insertingColumnRight(of anchor: Ghostty.SurfaceView?, pane: Ghostty.SurfaceView,
                              widthFactor: Double = ScrollingStrip.defaultWidth) -> Self {
        var next = self
        next.zoomedID = nil
        let insertAt = anchor.flatMap { position(of: $0)?.col.advanced(by: 1) } ?? columns.count
        next.columns.insert(Column(panes: [pane], widthFactor: widthFactor),
                            at: min(insertAt, columns.count))
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

    /// 全列宽重置为统一因子（Cmd+Ctrl+= / 可见列数切换）
    func equalized(to factor: Double = ScrollingStrip.defaultWidth) -> Self {
        var next = self
        for i in next.columns.indices {
            next.columns[i].widthFactor = factor
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

    // MARK: 视口几何（纯函数，可测；渲染与滚动共用同一套有效列宽）

    /// 有效列宽（pt，参照 Omarchy/Hyprland scrolling）：
    /// - **填充模式**：名义宽度装得下时，按比例放大到恰好填满（间隙固定）——
    ///   单列即满屏、两列时左中右间隙精确相等
    /// - **溢出模式**：按名义 widthFactor（最小滚动 + 露边）
    /// 底层 factor 不被改写（溢出时恢复名义值）。
    func columnWidths(viewport: CGFloat, gap: CGFloat) -> [CGFloat] {
        guard !columns.isEmpty, viewport > 0 else { return [] }
        let nominal = columns.map { CGFloat($0.widthFactor) * viewport }
        let gapsTotal = gap * CGFloat(columns.count - 1)
        let nominalSum = nominal.reduce(0, +)
        let available = viewport - gapsTotal
        guard nominalSum < available, nominalSum > 0 else { return nominal }
        let scale = available / nominalSum
        return nominal.map { $0 * scale }
    }

    func totalWidth(viewport: CGFloat, gap: CGFloat) -> CGFloat {
        let widths = columnWidths(viewport: viewport, gap: gap)
        guard !widths.isEmpty else { return 0 }
        return widths.reduce(0, +) + gap * CGFloat(widths.count - 1)
    }

    /// 视口偏移：
    /// - 内容总宽 ≤ 视口：整组**居中**（两侧等隙——两列 0.49 时左右间隙相等，参照 Omarchy）
    /// - 溢出：最小滚动量让锚 pane 所在列完全可见（露边行为，截图 1/2）
    /// 偏移为内容坐标向右为正；居中时可为负（负值 = 左侧留白）。
    func targetOffset(for pane: Ghostty.SurfaceView,
                      current: CGFloat, viewport: CGFloat, gap: CGFloat) -> CGFloat {
        guard viewport > 0, let (c, _) = position(of: pane) else { return current }
        let widths = columnWidths(viewport: viewport, gap: gap)
        let total = totalWidth(viewport: viewport, gap: gap)
        if total <= viewport {
            return (total - viewport) / 2
        }
        var x: CGFloat = 0
        for i in 0..<c { x += widths[i] + gap }
        let minOffset = x + widths[c] - viewport   // 右缘对齐
        let maxOffset = x                          // 左缘对齐
        let desired = min(max(current, minOffset), maxOffset)
        return min(max(desired, 0), total - viewport)
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
