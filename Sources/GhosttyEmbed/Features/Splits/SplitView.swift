import SwiftUI

/// A split view shows a left and right (or top and bottom) view with a divider in the middle to do resizing.
/// The terminlogy "left" and "right" is always used but for vertical splits "left" is "top" and "right" is "bottom".
///
/// This view is purpose built for our use case and I imagine we'll continue to make it more configurable
/// as time goes on. For example, the splitter divider size and styling is all hardcoded.
struct SplitView<L: View, R: View>: View {
    /// Direction of the split
    let direction: SplitViewDirection

    /// Divider color
    let dividerColor: Color

    /// QuickTerm: how far the divider's visual fill extends past the visible line width. It paints
    /// over the gap padding of the panes on either side so that only a sliver of wallpaper still
    /// shows through the gap. It affects neither layout nor the hit area.
    let dividerFillExtra: CGFloat

    /// Minimum increment (in points) that this split can be resized by, in
    /// each direction. Both `height` and `width` should be whole numbers
    /// greater than or equal to 1.0
    let resizeIncrements: NSSize

    /// The left and right views to render.
    let left: L
    let right: R

    /// Called when the divider is double-tapped to equalize splits.
    let onEqualize: () -> Void

    /// The minimum size (in points) of a split
    /// QuickTerm: moved to `SplitViewMetrics.minSize` — the control plane's `pane resize` has to
    /// clamp against the same limit. Keep two copies of the number and the command line can put the
    /// divider somewhere the mouse can never drag it to.
    var minSize: CGFloat { SplitViewMetrics.minSize }

    /// The current fractional width of the split view. 0.5 means L/R are equally sized, for example.
    @Binding var split: CGFloat

    /// The visible size of the splitter, in points. The invisible size is a transparent hitbox that can still
    /// be used for getting a resize handle. The total width/height of the splitter is the sum of both.
    /// QuickTerm: the divider line **takes up no layout space**
    /// (SplitViewMetrics.splitterLayoutSize = 0) — the gap padding of the two adjacent panes adds up
    /// to 2x pane-gap and that is the whole spacing, identical to scrolling. The 1pt hairline is
    /// drawn on the boundary itself (0.5pt into the padding on each side); the hit area is still
    /// 6pt.
    private let splitterVisibleSize: CGFloat
    private let splitterLineSize: CGFloat = 1
    private let splitterInvisibleSize: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            let leftRect = self.leftRect(for: geo.size)
            let rightRect = self.rightRect(for: geo.size, leftRect: leftRect)
            let splitterPoint = self.splitterPoint(for: geo.size, leftRect: leftRect)

            ZStack(alignment: .topLeading) {
                left
                    .frame(width: leftRect.size.width, height: leftRect.size.height)
                    .offset(x: leftRect.origin.x, y: leftRect.origin.y)
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel(leftPaneLabel)
                right
                    .frame(width: rightRect.size.width, height: rightRect.size.height)
                    .offset(x: rightRect.origin.x, y: rightRect.origin.y)
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel(rightPaneLabel)
                Divider(direction: direction,
                        visibleSize: splitterVisibleSize,
                        invisibleSize: splitterInvisibleSize,
                        fillSize: splitterLineSize + dividerFillExtra,
                        color: dividerColor,
                        split: $split)
                    .position(splitterPoint)
                    .gesture(dragGesture(geo.size, splitterPoint: splitterPoint))
                    .onTapGesture(count: 2) {
                        onEqualize()
                    }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(splitViewLabel)
        }
    }

    /// Initialize a split view that can be resized by manually dragging the divider.
    init(
        _ direction: SplitViewDirection,
        _ split: Binding<CGFloat>,
        dividerColor: Color,
        dividerFillExtra: CGFloat = 0,
        dividerLayoutSize: CGFloat = SplitViewMetrics.splitterLayoutSize,
        resizeIncrements: NSSize = .init(width: 1, height: 1),
        @ViewBuilder left: (() -> L),
        @ViewBuilder right: (() -> R),
        onEqualize: @escaping () -> Void
    ) {
        self.direction = direction
        self._split = split
        self.dividerColor = dividerColor
        self.dividerFillExtra = dividerFillExtra
        self.splitterVisibleSize = dividerLayoutSize
        self.resizeIncrements = resizeIncrements
        self.left = left()
        self.right = right()
        self.onEqualize = onEqualize
    }

    private func dragGesture(_ size: CGSize, splitterPoint: CGPoint) -> some Gesture {
        return DragGesture()
            .onChanged { gesture in
                // QuickTerm: the conversion and the minimum-size clamp both live in
                // SplitViewMetrics.ratio, and the control plane's `pane resize --ratio` calls that
                // same function — dragging all the way and setting it all the way have to land on
                // the same number.
                switch direction {
                case .horizontal:
                    split = SplitViewMetrics.ratio(dividerAt: gesture.location.x, in: size.width)
                case .vertical:
                    split = SplitViewMetrics.ratio(dividerAt: gesture.location.y, in: size.height)
                }
            }
    }

    /// Calculates the bounding rect for the left view.
    private func leftRect(for size: CGSize) -> CGRect {
        // Initially the rect is the full size
        var result = CGRect(x: 0, y: 0, width: size.width, height: size.height)
        switch direction {
        case .horizontal:
            result.size.width *= split
            result.size.width -= splitterVisibleSize / 2
            result.size.width -= result.size.width.truncatingRemainder(dividingBy: self.resizeIncrements.width)

        case .vertical:
            result.size.height *= split
            result.size.height -= splitterVisibleSize / 2
            result.size.height -= result.size.height.truncatingRemainder(dividingBy: self.resizeIncrements.height)
        }

        return result
    }

    /// Calculates the bounding rect for the right view.
    private func rightRect(for size: CGSize, leftRect: CGRect) -> CGRect {
        // Initially the rect is the full size
        var result = CGRect(x: 0, y: 0, width: size.width, height: size.height)
        switch direction {
        case .horizontal:
            // For horizontal layouts we offset the starting X by the left rect
            // and make the width fit the remaining space.
            result.origin.x += leftRect.size.width
            result.origin.x += splitterVisibleSize / 2
            result.size.width -= result.origin.x

        case .vertical:
            result.origin.y += leftRect.size.height
            result.origin.y += splitterVisibleSize / 2
            result.size.height -= result.origin.y
        }

        return result
    }

    /// Calculates the point at which the splitter should be rendered.
    private func splitterPoint(for size: CGSize, leftRect: CGRect) -> CGPoint {
        switch direction {
        case .horizontal:
            return CGPoint(x: leftRect.size.width, y: size.height / 2)

        case .vertical:
            return CGPoint(x: size.width / 2, y: leftRect.size.height)
        }
    }

    // MARK: Accessibility

    private var splitViewLabel: String {
        switch direction {
        case .horizontal:
            return "Horizontal split view"
        case .vertical:
            return "Vertical split view"
        }
    }

    private var leftPaneLabel: String {
        switch direction {
        case .horizontal:
            return "Left pane"
        case .vertical:
            return "Top pane"
        }
    }

    private var rightPaneLabel: String {
        switch direction {
        case .horizontal:
            return "Right pane"
        case .vertical:
            return "Bottom pane"
        }
    }
}

enum SplitViewDirection: Codable {
    case horizontal, vertical
}

/// QuickTerm: SplitView layout constants. SplitBranchView's pinned-size calculation runs off the
/// same algorithm.
enum SplitViewMetrics {
    /// Minimum size of one side, in points: dragging the divider can squeeze a side down to this
    /// and no further.
    static let minSize: CGFloat = 10

    /// Divider at `points` -> a ratio, applying the same minimum-size rule the drag gesture uses.
    /// **Shared by mouse and command line**: `pane resize --ratio / --points` clamps through this,
    /// so "dragged all the way left" and "--ratio 0" come out as the same ratio.
    /// When the slot is too narrow to hold even two minimum sizes there is nothing to clamp
    /// against, so fall back to an even split.
    static func ratio(dividerAt points: CGFloat, in size: CGFloat) -> CGFloat {
        guard size > 2 * minSize else { return 0.5 }
        return min(max(minSize, points), size - minSize) / size
    }

    /// Size the divider line occupies in layout while gaps are on: 0 = none, the whole spacing
    /// comes from the padding of the panes on either side.
    static let splitterLayoutSize: CGFloat = 0
    /// With gaps off (Cmd+Shift+Backspace) it goes back to occupying 1pt, otherwise the hairline
    /// sits right on top of the borders of the panes now flush against it.
    static let splitterLayoutSizeWithoutGaps: CGFloat = 1

    static func splitterLayoutSize(gapsEnabled: Bool) -> CGFloat {
        gapsEnabled ? splitterLayoutSize : splitterLayoutSizeWithoutGaps
    }
}
