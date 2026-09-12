import Foundation

/// Occlusion test for floating panes (spec v7 revision).
/// NSTrackingArea knows nothing about a sibling view covering it: when a floating pane sits on top
/// of a tiled one, both layers receive the hover events - so the filtering is done on **model
/// geometry** instead, where only a "floating pane with a higher z" counts as occluding.
/// hitTest is deliberately not used: hittable non-surface overlay views (the drag overlay behind
/// a Cmd+drag, overlay scrollers, ...) would make a hitTest-based check report a pane that is not
/// covered at all as occluded.
enum HoverOcclusion {
    /// `point` is in normalized content-area coordinates (SwiftUI top-left, 0-1).
    /// `paneFloatIndex`: the pane's index in the floating array (array order = z order, last entry
    /// is topmost); pass nil for a tiled pane - the floating layer as a whole is above the tiled
    /// layer.
    static func isOccluded(paneFloatIndex: Int?, floatingRects: [CGRect],
                           at point: CGPoint) -> Bool {
        let start = paneFloatIndex.map { $0 + 1 } ?? 0
        guard start < floatingRects.count else { return false }
        return floatingRects[start...].contains { $0.contains(point) }
    }
}
