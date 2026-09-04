import AppKit

/// 浮动层的 pane（spec v7：Cmd+T / Hyprland togglefloating 语义）。
/// rect 为归一化坐标（0–1，SwiftUI top-left 坐标系）——窗口缩放时按比例跟随。
/// 数组序即 z 序（末位最顶）。
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

    /// 浮起默认几何（类 Omarchy togglefloating：固定尺寸 + 居中）：
    /// 宽 = 默认列宽 × 0.75，高 = 内容区 45%。
    static func defaultRect(columnFactor: Double) -> CGRect {
        let w = min(max(columnFactor * 0.75, 0.15), 1.0)
        let h = 0.45
        return CGRect(x: (1 - w) / 2, y: (1 - h) / 2, width: w, height: h)
    }

    /// 限制在内容区内且保留最小可用尺寸
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
    /// ⌘+左键在浮动 pane 上的拖动语义：中间 = 移动；四边带 = 沿该轴缩放；四角 = 双轴缩放
    struct DragEdges: OptionSet, Equatable {
        let rawValue: Int
        static let left = DragEdges(rawValue: 1)
        static let right = DragEdges(rawValue: 2)
        static let top = DragEdges(rawValue: 4)
        static let bottom = DragEdges(rawValue: 8)
        /// 空 = 中间区域（移动）
        var isMove: Bool { isEmpty }
    }

    static let minSize: CGFloat = 0.15

    /// 命中区判定。point / rect 为归一化内容坐标（top-left）；band 为边框带宽换算成的归一化值（按轴各自换算）。
    /// 点不在 rect 内返回 nil。
    static func dragEdges(at point: CGPoint, in rect: CGRect, bandX: CGFloat, bandY: CGFloat) -> DragEdges? {
        guard rect.contains(point) else { return nil }
        // 带宽不超过半边：很小的 pane 上左右带不重叠
        let bx = min(bandX, rect.width / 2), by = min(bandY, rect.height / 2)
        var edges: DragEdges = []
        if point.x - rect.minX < bx { edges.insert(.left) } else if rect.maxX - point.x < bx { edges.insert(.right) }
        if point.y - rect.minY < by { edges.insert(.top) } else if rect.maxY - point.y < by { edges.insert(.bottom) }
        return edges
    }

    /// 按边缩放：被拖的边跟随指针，对边**绝不动**；被拖的边夹在 [内容区边缘, 对边 − 最小尺寸] 之内
    /// （已经出界的 pane 不强行拉回：下界取 min(0, 当前边)）。在这里直接夹住，不依赖 clamped()——
    /// clamped() 只夹 origin 不回补尺寸，拖过顶端/右端会把本该固定的对边推走。
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
