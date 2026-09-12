import AppKit

/// The **geometry** of a layout: how big every pane is, and where every divider sits.
///
/// One rule runs through all of it: **the model is the source of truth**. Every normalized rect
/// is computed from dwindle's ratio or scrolling's column-width factors (using the very two
/// formulas the renderer uses: `SplitTree.spatial` and `ScrollingStrip.columnWidths`), never by
/// reading `NSView.frame` — a pane leaves the window hierarchy while SwiftUI rebuilds it, and
/// for that instant the frame is zero or stale, while "read me the size" must never wait a
/// frame, let alone report last frame's number.
/// Point sizes are the normalized rect times the content area, computed the same way; when the
/// content area cannot be read (the window is not mounted) the whole section is left out.
@MainActor
enum ControlGeometry {
    /// The unit box used for normalization (origin top-left, same orientation as `spatial` and
    /// SwiftUI).
    /// `nonisolated` because it is a constant and doubles as a default argument — and default
    /// arguments are evaluated in the caller's isolation domain
    nonisolated static let unit = CGSize(width: 1, height: 1)

    /// The workspace layout area in points = `MainWindowController.workspaceLayoutSize`: the
    /// contentView minus the status strip at the top, minus the ring of pane-gap padding around
    /// the outside — **the ground the split tree / strip actually spreads out over**, and
    /// exactly what `SplitView`'s `GeometryReader` measures.
    ///
    /// **Same source as the divider-dragging path**: `controlResizeSplit`, `resizeFocused` and
    /// Cmd+right-drag all convert points through this same `workspaceLayoutSize`. The sizes we
    /// report and the `--points` conversion have to stand on the same ground, or an agent
    /// resizing by the numbers we reported lands short, and clamping parks the divider
    /// somewhere the mouse cannot reach
    static func contentSize(_ controller: MainWindowController) -> CGSize? {
        controller.workspaceLayoutSize
    }

    // MARK: dwindle

    /// The rect of every pane in the tree, within the box `size`
    static func paneRects(in tree: SplitTree<PaneView>, size: CGSize) -> [UUID: CGRect] {
        guard let root = tree.root else { return [:] }
        var out: [UUID: CGRect] = [:]
        for slot in root.spatial(within: size).slots {
            if case .leaf(let view) = slot.node { out[view.id] = slot.bounds }
        }
        return out
    }

    /// One split in the tree (= one divider)
    struct SplitSlot {
        /// Dotted `a`/`b` string, empty at the root — the same spelling as `pane.at.path` and
        /// `spec`'s `focus.path`
        var path: String
        var node: SplitTree<PaneView>.Node
        /// `horizontal` = a left, b right; `vertical` = a on top, b below
        var direction: String
        var ratio: Double
        /// The rect this split occupies (its divider sits at `ratio` within it)
        var bounds: CGRect
    }

    /// Every split node in the tree (pre-order, so the root comes first)
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

    /// This split's length in points along the dividing axis: converting between `--points` and
    /// a ratio is a division by exactly this
    static func span(of slot: SplitSlot) -> CGFloat {
        slot.direction == "horizontal" ? slot.bounds.width : slot.bounds.height
    }

    // MARK: scrolling

    /// The rect of every pane in the strip (column widths come from `columnWidths`, the same
    /// code the renderer uses: scaled up proportionally to fill when everything fits, nominal
    /// column widths once it overflows; panes inside a column split the height evenly)
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

    // MARK: Common entry point

    static func paneRects(in layout: WorkspaceLayout, size: CGSize) -> [UUID: CGRect] {
        switch layout {
        case .dwindle(let tree): paneRects(in: tree, size: size)
        case .scrolling(let strip): paneRects(in: strip, size: size)
        }
    }

    /// Fixed decimals: 4 for normalized values, 1 for points.
    /// The rounding is there for `dump → apply → dump` and for "the number you read back equals
    /// the number you wrote" — a floating-point tail makes the fixed-point tests differ by one
    /// ULP at random
    static func rounded(_ value: CGFloat, _ digits: Int = 4) -> Double {
        let scale = pow(10.0, Double(digits))
        return (Double(value) * scale).rounded() / scale
    }

    static func rect(_ rect: CGRect, digits: Int = 4) -> [Double] {
        [rounded(rect.origin.x, digits), rounded(rect.origin.y, digits),
         rounded(rect.size.width, digits), rounded(rect.size.height, digits)]
    }
}
