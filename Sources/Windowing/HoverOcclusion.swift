import Foundation

/// 浮动 pane 遮挡判定（spec v7 修订）。
/// NSTrackingArea 不感知兄弟视图遮挡，浮动 pane 叠在平铺 pane 上时两层都收到
/// hover 事件——需按**模型几何**过滤：只有「更高 z 的浮动 pane」构成遮挡。
/// 刻意不用 hitTest：⌘ 拖拽源浮层、overlay 滚动条等可命中的非 surface
/// 覆盖视图会让 hitTest 方案把毫无遮挡的 pane 误判为被遮挡。
enum HoverOcclusion {
    /// point 为归一化内容区坐标（SwiftUI top-left，0–1）。
    /// paneFloatIndex：pane 在浮动数组的下标（数组序 = z 序，末位最顶）；
    /// 平铺 pane 传 nil——浮动层整体在平铺层之上。
    static func isOccluded(paneFloatIndex: Int?, floatingRects: [CGRect],
                           at point: CGPoint) -> Bool {
        let start = paneFloatIndex.map { $0 + 1 } ?? 0
        guard start < floatingRects.count else { return false }
        return floatingRects[start...].contains { $0.contains(point) }
    }
}
