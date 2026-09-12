import AppKit

/// Data model for the Omarchy `scrolling` layout (spec §4.2-bis):
/// a workspace is an endless horizontal strip of columns; each column is 0.49x the viewport wide
/// (adjustable), and panes stack vertically inside a column.
/// Same style as SplitTree: immutable value semantics, and no stored focus - every operation is
/// anchored on "some pane", which the controller looks up through focusedSurface, so hover focus
/// stays in sync for free.
struct ScrollingStrip: Codable {
    struct Column: Codable {
        /// Stable identity (for SwiftUI's ForEach): closing a column's first pane no longer
        /// rebuilds the whole column - otherwise the SurfaceViews of the remaining panes detach
        /// from the window and remount into it (one flashed frame, and first responder silently
        /// reset). Older saved sessions have no such field, so one is minted on decode.
        var id = UUID()
        var panes: [PaneView]
        var widthFactor: Double = ScrollingStrip.defaultWidth

        init(panes: [PaneView], widthFactor: Double = ScrollingStrip.defaultWidth) {
            self.panes = panes
            self.widthFactor = widthFactor
        }

        private enum CodingKeys: String, CodingKey { case id, panes, widthFactor }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
            var list = try c.nestedUnkeyedContainer(forKey: .panes)
            var decoded: [PaneView] = []
            while !list.isAtEnd { decoded.append(try PaneView.decodePane(from: list.superDecoder())) }
            panes = decoded
            widthFactor = try c.decodeIfPresent(Double.self, forKey: .widthFactor) ?? ScrollingStrip.defaultWidth
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(id, forKey: .id)
            var list = c.nestedUnkeyedContainer(forKey: .panes)
            for pane in panes { try pane.encodePane(to: list.superEncoder()) }
            try c.encode(widthFactor, forKey: .widthFactor)
        }
    }

    /// Peek (per side, as a fraction of the viewport): when the strip overflows, a sliver of the
    /// neighbouring column shows outside the focused one (gap + border + a little background,
    /// ~15pt in a 1000pt viewport) as a hint that there is more over there; a focused column in
    /// the middle gets a symmetric sliver on both sides.
    /// 6% came back from the user as too wide (2026-09-03), so this is a quarter of that.
    static let peek = 0.015

    /// The peek in actual points: the larger of the viewport fraction and "the neighbour's padding
    /// + 2pt border + 4pt of background" - with a large pane-gap (15 or more), 1.5% of the
    /// viewport is all transparent padding, the neighbour's border never shows, and the hint is
    /// gone.
    static func peekPoints(viewport: CGFloat, paneGap: CGFloat) -> CGFloat {
        max(CGFloat(peek) * viewport, paneGap + 2 + 4)
    }
    /// Default column width = 2 columns per screen (0.485)
    static var defaultWidth: Double { factor(forVisibleColumns: 2) }
    static let widthStep = 0.05
    static let widthRange = 0.25...0.90

    /// "N columns visible per screen" → width factor = (1 − both peeks) / N (N=2 → 0.485)
    static func factor(forVisibleColumns n: Int) -> Double {
        (1 - 2 * peek) / Double(min(max(n, 1), 6))
    }

    var columns: [Column] = []
    /// Zoom: this pane fills the content area (cleared by any structural change).
    var zoomedID: UUID?

    enum Direction { case left, right, up, down }

    init() {}

    init(pane: PaneView, widthFactor: Double = ScrollingStrip.defaultWidth) {
        columns = [Column(panes: [pane], widthFactor: widthFactor)]
    }

    init(columns: [Column], zoomedID: UUID? = nil) {
        self.columns = columns
        self.zoomedID = zoomedID
    }

    var isEmpty: Bool { columns.isEmpty }
    var paneList: [PaneView] { columns.flatMap(\.panes) }

    /// Structure signature (column order / row order): when it changes, the viewport has to
    /// realign on focus - swapping or merging/splitting changes neither the focused id nor the
    /// column count, so those alone can never trigger scroll-follow.
    /// It deliberately excludes widthFactor: right-drag resizing writes a width per event, and
    /// having the width in the signature would hijack a manually panned viewport back onto the
    /// focused column on every frame.
    var layoutSignature: Int {
        var hasher = Hasher()
        for column in columns {
            hasher.combine(column.panes.count)  // group boundaries: [a][b,c] != [a,b][c]
            for pane in column.panes { hasher.combine(pane.id) }
        }
        return hasher.finalize()
    }

    var zoomedPane: PaneView? {
        guard let zoomedID else { return nil }
        return paneList.first { $0.id == zoomedID }
    }

    /// pane → (column, row)
    func position(of pane: PaneView) -> (col: Int, row: Int)? {
        for (c, column) in columns.enumerated() {
            if let r = column.panes.firstIndex(where: { $0 === pane }) {
                return (c, r)
            }
        }
        return nil
    }

    // MARK: Structural operations (all return a new value; a structural change clears zoom)

    /// Insert a new column to the right of the focused one (Cmd+Return semantics, screenshot 3)
    func insertingColumnRight(of anchor: PaneView?, pane: PaneView,
                              widthFactor: Double = ScrollingStrip.defaultWidth) -> Self {
        var next = self
        next.zoomedID = nil
        let insertAt = anchor.flatMap { position(of: $0)?.col.advanced(by: 1) } ?? columns.count
        next.columns.insert(Column(panes: [pane], widthFactor: widthFactor),
                            at: min(insertAt, columns.count))
        return next
    }

    /// Close a pane; an emptied column is removed (per spec, moving focus left is the controller's
    /// job).
    func removing(_ pane: PaneView) -> Self {
        guard let (c, r) = position(of: pane) else { return self }
        var next = self
        next.zoomedID = nil
        next.columns[c].panes.remove(at: r)
        if next.columns[c].panes.isEmpty {
            next.columns.remove(at: c)
        }
        return next
    }

    /// Directional focus target: left/right crosses columns picking the nearest row at the same
    /// height, up/down moves within the column, and neither wraps.
    func focusTarget(from pane: PaneView, direction: Direction) -> PaneView? {
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

    /// Linear cycle (Alt+Tab / Cmd+[ ]): column order x row order, wrapping around.
    func linearTarget(from pane: PaneView, next: Bool) -> PaneView? {
        let all = paneList
        guard all.count > 1, let i = all.firstIndex(where: { $0 === pane }) else { return nil }
        return all[(i + (next ? 1 : all.count - 1)) % all.count]
    }

    /// Swap: left/right swaps whole columns, up/down swaps within the column.
    func swapping(_ pane: PaneView, direction: Direction) -> Self {
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

    /// Cmd+J: a single-pane column merges into the vertical stack of the column on its left; a
    /// multi-pane column splits the focused pane out into its own column on the right.
    func mergingOrSplitting(_ pane: PaneView) -> Self {
        guard let (c, r) = position(of: pane) else { return self }
        var next = self
        next.zoomedID = nil
        if columns[c].panes.count == 1 {
            guard c > 0 else { return self }
            next.columns[c - 1].panes.append(pane)
            next.columns.remove(at: c)
        } else {
            // The split-off column keeps the source column's width. It must not fall back to the
            // two-column default of 0.485: at 3 columns per screen that comes out half again as
            // wide as every other column.
            next.columns[c].panes.remove(at: r)
            next.columns.insert(Column(panes: [pane], widthFactor: columns[c].widthFactor), at: c + 1)
        }
        return next
    }

    /// Resize a column (Cmd+Ctrl+←/→, +/-5%, clamped to 25%-90%)
    func resizingWidth(of pane: PaneView, delta: Double) -> Self {
        guard let (c, _) = position(of: pane) else { return self }
        var next = self
        next.columns[c].widthFactor = min(
            max(columns[c].widthFactor + delta, Self.widthRange.lowerBound),
            Self.widthRange.upperBound)
        return next
    }

    /// Reset every column to one uniform factor (Cmd+Ctrl+=, or changing the visible column count)
    func equalized(to factor: Double = ScrollingStrip.defaultWidth) -> Self {
        var next = self
        for i in next.columns.indices {
            next.columns[i].widthFactor = factor
        }
        return next
    }

    func togglingZoom(_ pane: PaneView) -> Self {
        var next = self
        next.zoomedID = (zoomedID == pane.id) ? nil : pane.id
        return next
    }

    /// Drag and drop (spec §4.2-bis): the left or right edge inserts a new column beside the
    /// target's; the top or bottom edge merges into the target column's stack; the center swaps.
    func dropping(_ payload: PaneView,
                  on destination: PaneView,
                  zone: TerminalSplitDropZone) -> Self {
        guard payload !== destination,
              let (pc, _) = position(of: payload) else { return self }
        // If the payload had a column to itself, carry that column over (keeping its id and its
        // width): SwiftUI then sees a move rather than a delete plus an insert, which is what keeps
        // the pane from detaching and remounting into the window. Dragged out of a stacked column
        // instead, the new column inherits the source column's width.
        let carried: Column? = columns[pc].panes.count == 1 ? columns[pc] : nil
        let sourceWidth = columns[pc].widthFactor
        var next = removing(payload)
        guard let (dc, dr) = next.position(of: destination) else { return self }
        next.zoomedID = nil
        switch zone {
        case .left:
            next.columns.insert(carried ?? Column(panes: [payload], widthFactor: sourceWidth), at: dc)
        case .right:
            next.columns.insert(carried ?? Column(panes: [payload], widthFactor: sourceWidth), at: dc + 1)
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

    // MARK: Viewport geometry (pure and testable; rendering and scrolling share one set of
    // effective column widths)

    /// Effective column widths in points (following Omarchy/Hyprland scrolling):
    /// - **Fill mode**: when the nominal widths fit, scale them up proportionally to fill exactly
    ///   (the gaps stay fixed) - a single column becomes full-screen, and with two columns the
    ///   left, middle and right gaps come out precisely equal.
    /// - **Overflow mode**: use the nominal widthFactor (minimal scrolling + peek).
    /// The underlying factors are never rewritten, so overflowing restores the nominal values.
    func columnWidths(viewport: CGFloat, gap: CGFloat) -> [CGFloat] {
        guard !columns.isEmpty, viewport > 0 else { return [] }
        let nominal = columns.map { CGFloat($0.widthFactor) * viewport }
        let gapsTotal = gap * CGFloat(columns.count - 1)
        let nominalSum = nominal.reduce(0, +)
        let available = viewport - gapsTotal
        guard nominalSum < available, nominalSum > 0 else { return nominal }
        let scale = available / nominalSum
        var scaled = nominal.map { $0 * scale }
        // The floating-point remainder goes into the last column, so the sum equals the available
        // width exactly (a filled strip means zero offset and no judder).
        if let last = scaled.indices.last { scaled[last] += available - scaled.reduce(0, +) }
        return scaled
    }

    func totalWidth(viewport: CGFloat, gap: CGFloat) -> CGFloat {
        let widths = columnWidths(viewport: viewport, gap: gap)
        guard !widths.isEmpty else { return 0 }
        return widths.reduce(0, +) + gap * CGFloat(widths.count - 1)
    }

    /// Viewport offset:
    /// - Total content width <= viewport: **center** the whole group (equal gaps on both sides -
    ///   with two columns at 0.49 the left and right gaps match, as in Omarchy).
    /// - Overflowing: scroll the smallest amount that makes the anchor pane's column fully visible
    ///   (the peek behavior, screenshots 1/2).
    /// The offset is in content coordinates, positive to the right; while centering it can go
    /// negative (negative = padding on the left).
    func targetOffset(for pane: PaneView,
                      current: CGFloat, viewport: CGFloat, gap: CGFloat,
                      paneGap: CGFloat = 5) -> CGFloat {
        guard viewport > 0, let (c, _) = position(of: pane) else { return current }
        let widths = columnWidths(viewport: viewport, gap: gap)
        let total = totalWidth(viewport: viewport, gap: gap)
        if total <= viewport {
            return (total - viewport) / 2
        }
        var x: CGFloat = 0
        for i in 0..<c { x += widths[i] + gap }
        // The focused column fully visible with one peek left outside it (the neighbour shows real
        // content; at either end the strip naturally sits flush).
        let peek = Self.peekPoints(viewport: viewport, paneGap: paneGap)
        var minOffset = x + widths[c] + peek - viewport   // right edge aligned + peek on the right
        var maxOffset = x - peek                          // left edge aligned + peek on the left
        if minOffset > maxOffset {                        // too wide for a peek: fall back to flush
            minOffset = x + widths[c] - viewport
            maxOffset = x
        }
        let desired = min(max(current, minOffset), maxOffset)
        return min(max(desired, 0), total - viewport)
    }

    // MARK: Conversion to and from dwindle (Cmd+L; panes and their order are preserved)

    static func from(tree: SplitTree<PaneView>,
                     widthFactor: Double = ScrollingStrip.defaultWidth) -> Self {
        ScrollingStrip(columns: tree.root?.leaves().map {
            Column(panes: [$0], widthFactor: widthFactor)
        } ?? [])
    }

    func toTree() -> SplitTree<PaneView> {
        var tree = SplitTree<PaneView>()
        var previousHead: PaneView?
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
