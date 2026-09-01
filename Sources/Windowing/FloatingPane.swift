import AppKit

/// 浮动层的 pane（spec v7：Cmd+T / Hyprland togglefloating 语义）。
/// rect 为归一化坐标（0–1，SwiftUI top-left 坐标系）——窗口缩放时按比例跟随。
/// 数组序即 z 序（末位最顶）。
struct FloatingPane: Codable, Identifiable {
    var pane: Ghostty.SurfaceView
    var rect: CGRect

    var id: UUID { pane.id }

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
