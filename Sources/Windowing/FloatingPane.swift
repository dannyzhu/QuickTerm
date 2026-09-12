import AppKit

/// A pane on the floating layer (spec v7: Cmd+T, Hyprland's togglefloating semantics).
/// `rect` is in normalized coordinates (0-1, SwiftUI top-left coordinate system) so the pane scales
/// proportionally when the window is resized.
/// Array order is z order (last entry is topmost).
struct FloatingPane: Codable, Identifiable {
    var pane: PaneView
    var rect: CGRect

    var id: UUID { pane.id }

    init(pane: PaneView, rect: CGRect) {
        self.pane = pane
        self.rect = rect
    }

    private enum CodingKeys: String, CodingKey { case pane, rect }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pane = try PaneView.decodePane(from: c.superDecoder(forKey: .pane))
        rect = try c.decode(CGRect.self, forKey: .rect)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try pane.encodePane(to: c.superEncoder(forKey: .pane))
        try c.encode(rect, forKey: .rect)
    }

    /// Default geometry when a pane floats up (Omarchy-style togglefloating: fixed size, centered):
    /// width = default column width x 0.75, height = 45% of the content area.
    static func defaultRect(columnFactor: Double) -> CGRect {
        let w = min(max(columnFactor * 0.75, 0.15), 1.0)
        let h = 0.45
        return CGRect(x: (1 - w) / 2, y: (1 - h) / 2, width: w, height: h)
    }

    /// Clamp into the content area while keeping a minimum usable size
    func clamped() -> FloatingPane {
        var next = self
        next.rect.size.width = min(max(rect.width, 0.15), 1.0)
        next.rect.size.height = min(max(rect.height, 0.15), 1.0)
        next.rect.origin.x = min(max(rect.origin.x, -next.rect.width * 0.5), 1 - next.rect.width * 0.5)
        next.rect.origin.y = min(max(rect.origin.y, 0), 1 - next.rect.height * 0.5)
        return next
    }
}

extension FloatingPane {
    /// What a Cmd+left-drag on a floating pane means: the middle = move, an edge band = resize
    /// along that axis, a corner = resize on both axes.
    struct DragEdges: OptionSet, Equatable {
        let rawValue: Int
        static let left = DragEdges(rawValue: 1)
        static let right = DragEdges(rawValue: 2)
        static let top = DragEdges(rawValue: 4)
        static let bottom = DragEdges(rawValue: 8)
        /// Empty = the middle region (move)
        var isMove: Bool { isEmpty }
    }

    static let minSize: CGFloat = 0.15

    /// Hit-region test. `point` / `rect` are normalized content coordinates (top-left); `bandX` and
    /// `bandY` are the edge band width converted to normalized units, separately per axis.
    /// Returns nil when the point is outside `rect`.
    static func dragEdges(at point: CGPoint, in rect: CGRect, bandX: CGFloat, bandY: CGFloat) -> DragEdges? {
        guard rect.contains(point) else { return nil }
        // Cap each band at half the side so the left and right bands do not overlap on a tiny
        // pane.
        let bx = min(bandX, rect.width / 2), by = min(bandY, rect.height / 2)
        var edges: DragEdges = []
        if point.x - rect.minX < bx { edges.insert(.left) } else if rect.maxX - point.x < bx { edges.insert(.right) }
        if point.y - rect.minY < by { edges.insert(.top) } else if rect.maxY - point.y < by { edges.insert(.bottom) }
        return edges
    }

    /// Edge resize: the dragged edge follows the pointer and the opposite edge **never moves**. The
    /// dragged edge is clamped into [content-area edge, opposite edge - minSize] (a pane that is
    /// already outside the content area is not yanked back in: the lower bound is
    /// min(0, current edge)). The clamping happens right here instead of going through clamped() -
    /// clamped() only clamps the origin and never compensates the size, so dragging past the top or
    /// the right edge would push the very edge that is supposed to stay pinned.
    func resized(edges: DragEdges, dx: CGFloat, dy: CGFloat) -> FloatingPane {
        var r = rect
        if edges.contains(.left) {
            let minX = min(max(r.minX + dx, min(0, r.minX)), r.maxX - Self.minSize)
            r.size.width = r.maxX - minX
            r.origin.x = minX
        }
        if edges.contains(.right) {
            let maxX = max(min(r.maxX + dx, max(1, r.maxX)), r.minX + Self.minSize)
            r.size.width = maxX - r.minX
        }
        if edges.contains(.top) {
            let minY = min(max(r.minY + dy, min(0, r.minY)), r.maxY - Self.minSize)
            r.size.height = r.maxY - minY
            r.origin.y = minY
        }
        if edges.contains(.bottom) {
            let maxY = max(min(r.maxY + dy, max(1, r.maxY)), r.minY + Self.minSize)
            r.size.height = maxY - r.minY
        }
        var next = self
        next.rect = r
        return next
    }
}
