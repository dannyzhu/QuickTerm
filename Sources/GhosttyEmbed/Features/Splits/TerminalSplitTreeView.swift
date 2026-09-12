import SwiftUI

/// A single operation within the split tree.
///
/// Rather than binding the split tree (which is immutable), any mutable operations are
/// exposed via this enum to the embedder to handle.
enum TerminalSplitOperation {
    case resize(Resize)
    case drop(Drop)
    /// QuickTerm: double-clicking the divider equalizes the whole tree (the controller runs
    /// perform(.equalize)).
    case equalize

    struct Resize {
        let node: SplitTree<PaneView>.Node
        let ratio: Double
    }

    struct Drop {
        /// The surface being dragged.
        let payload: PaneView

        /// The surface it was dragged onto
        let destination: PaneView

        /// The zone it was dropped to determine how to split the destination.
        let zone: TerminalSplitDropZone
    }
}

struct TerminalSplitTreeView: View {
    let tree: SplitTree<PaneView>
    let action: (TerminalSplitOperation) -> Void
    /// QuickTerm: the pane that was just split off. The new split node it lives in plays the local
    /// shrink / fade-in animation.
    var appearingPane: UUID? = nil
    /// QuickTerm: panes that are fading out. Their parent split node plays the collapse animation
    /// while the leaf itself fades.
    var closingPanes: Set<UUID> = []

    var body: some View {
        if let node = tree.zoomed ?? tree.root {
            TerminalSplitSubtreeView(
                node: node,
                isRoot: node == tree.root,
                action: action,
                appearingPane: appearingPane,
                closingPanes: closingPanes)
            // QuickTerm: no more .id(structuralIdentity) on the whole tree — that made any
            // structural change rebuild every pane (the entire app flashes, every pane replays its
            // pop-in, the first-responder view leaves the window). What upstream issue 7546 was
            // worried about, a surface being swapped at the same position while the view is reused,
            // is solved by the leaf's own .id(surface.id), and a structural change then rebuilds
            // only the affected subtree.
        }
    }
}

private struct TerminalSplitSubtreeView: View {
    let node: SplitTree<PaneView>.Node
    var isRoot: Bool = false
    let action: (TerminalSplitOperation) -> Void
    /// QuickTerm: id of the pane that was just split off; handed down to the split branch view to
    /// decide whether it plays the entrance animation.
    var appearingPane: UUID? = nil
    var closingPanes: Set<UUID> = []

    var body: some View {
        switch node {
        case .leaf(let leafView):
            TerminalSplitLeaf(surfaceView: leafView, isSplit: !isRoot, action: action,
                              closing: closingPanes.contains(leafView.id))
                .id(leafView.id)   // new surface at the same position -> rebuild (upstream 7546)

        case .split:
            // The split branch lives in its own view: when a leaf turns into a split in place that
            // view is a brand new SwiftUI identity, which is the only way the entrance animation's
            // State(initialValue:) takes effect. Put it on this view instead and it inherits the
            // stale state from back when this position was a leaf.
            SplitBranchView(node: node, action: action, appearingPane: appearingPane,
                            closingPanes: closingPanes)
        }
    }
}

/// QuickTerm: renders a split node, plus the local entrance animation for a new split and the local
/// collapse animation for a closing child leaf.
/// Entrance: the original pane shrinks from filling the node down to `ratio` (real geometry, it
/// shrinks along with its slot), while the new pane's content is laid out at its **final size** and
/// gets "uncovered" and faded in as its slot grows. It never passes through intermediate widths, so
/// the new shell never starts up against a 1-column PTY.
/// Closing (the mirror image): the closing side's slot collapses to 0 (its content pinned at the
/// size it had before the close, clipped away in place, with the leaf itself fading), while the
/// surviving subtree is pinned at its **final size** (filling this node) and uncovered from the near
/// edge. The controller only really deletes the node once the animation lands, so the survivor's
/// size is unchanged when it is re-attached and nothing reflows.
/// `animating` / `closingSide` are latched the first time they appear, so the model clearing those
/// flags afterwards cannot interrupt an animation in flight.
private struct SplitBranchView: View {
    @EnvironmentObject var ghostty: Ghostty.App
    // the 1pt divider hairline is made translucent by divider-opacity
    @EnvironmentObject var theme: ThemeManager

    let node: SplitTree<PaneView>.Node
    let action: (TerminalSplitOperation) -> Void
    let appearingPane: UUID?
    let closingPanes: Set<UUID>

    @State private var animating: Bool       // latched: does this node play the entrance animation
    @State private var progress: CGFloat     // 0 = original fills it, new pane hidden; 1 = in place
    @State private var settled: Bool         // animation done: unpin the new pane's size
    @State private var closingSide: ClosingSide?      // latched: which direct child leaf is closing
    @State private var closingLeaf: UUID?             // latched: the closing leaf (validates the latch)
    @State private var closeProgress: CGFloat = 0     // 0 = normal geometry; 1 = closing slot collapsed
    @State private var closingStartSize: CGSize?      // the closing side's size before the close (pinning)

    enum ClosingSide { case left, right }

    /// Closing leaves whose collapse has already played (or already snapped into place). When a
    /// split view takes over a leaf, this is what decides between replaying the 0.28s animation and
    /// jumping straight to the end state.
    /// Looking only at "was it in the previous round's closingPanes" is not enough: when one split
    /// node has two leaves closing at the same time it latches only one of them, and the other
    /// merely fades without collapsing — its first real collapse happens when it is promoted to the
    /// parent node.
    private static var collapsed = Set<UUID>()

    /// The identity of the direct child leaves plus the closing set: a change in either means the
    /// latch has to be re-evaluated (the node was displaced by a sibling subtree, or a new close
    /// started).
    private struct CloseKey: Equatable {
        let leftLeaf: UUID?
        let rightLeaf: UUID?
        let closing: Set<UUID>

        init(node: SplitTree<PaneView>.Node, closing: Set<UUID>) {
            if case .split(let split) = node {
                leftLeaf = { if case .leaf(let v) = split.left { return v.id } else { return nil } }()
                rightLeaf = { if case .leaf(let v) = split.right { return v.id } else { return nil } }()
            } else {
                leftLeaf = nil
                rightLeaf = nil
            }
            self.closing = closing
        }

        /// Which side's direct child leaf is closing; right/bottom wins.
        var pending: (side: ClosingSide, leaf: UUID)? {
            if let r = rightLeaf, closing.contains(r) { return (.right, r) }
            if let l = leftLeaf, closing.contains(l) { return (.left, l) }
            return nil
        }

        func isDirectChild(_ leaf: UUID) -> Bool { leaf == leftLeaf || leaf == rightLeaf }
    }

    init(node: SplitTree<PaneView>.Node,
         action: @escaping (TerminalSplitOperation) -> Void,
         appearingPane: UUID?,
         closingPanes: Set<UUID> = []) {
        self.node = node
        self.action = action
        self.appearingPane = appearingPane
        self.closingPanes = closingPanes
        let anim = Self.isAppearingSplit(node, appearingPane)
        _animating = State(initialValue: anim)
        _progress = State(initialValue: anim ? 0 : 1)
        _settled = State(initialValue: !anim)
    }

    private static func isAppearingSplit(_ node: SplitTree<PaneView>.Node, _ id: UUID?) -> Bool {
        guard let id, case .split(let split) = node, case .leaf(let v) = split.right else { return false }
        return v.id == id
    }

    var body: some View {
        if case .split(let split) = node {
            let splitViewDirection: SplitViewDirection = switch split.direction {
            case .horizontal: .horizontal
            case .vertical: .vertical
            }
            let key = CloseKey(node: node, closing: closingPanes)
            // The latch only counts while the latched leaf is still a direct child of this node.
            // Once the close finishes and a sibling subtree takes over this view's position (SwiftUI
            // reuses the .split view at that position along with its @State), the derived values go
            // back to normal geometry immediately instead of waiting for the reset.
            let latchedValid = closingLeaf.map(key.isDirectChild) ?? false
            let side: ClosingSide? = latchedValid ? closingSide : nil
            GeometryReader { geo in
                SplitView(
                    splitViewDirection,
                    .init(get: {
                        let ratio = CGFloat(split.ratio)
                        // Entrance animation: shrink from "the original pane fills it" (1) to ratio
                        var r = animating ? ratio * progress + (1 - progress) : ratio
                        // Close animation: the closing side's slot collapses to 0, the survivor
                        // grows to fill
                        switch side {
                        case .right: r += (1 - r) * closeProgress
                        case .left: r *= (1 - closeProgress)
                        case nil: break
                        }
                        return r
                    }, set: {
                        action(.resize(.init(node: node, ratio: $0)))
                    }),
                    dividerColor: ghostty.config.splitDividerColor.opacity(theme.effectiveDividerOpacity),
                    dividerLayoutSize: splitterLayoutSize,
                    resizeIncrements: .init(width: 1, height: 1),
                    left: {
                        // Closing the right/bottom child: the left/top child is the survivor,
                        // pinned at its final size (filling this node) and aligned top-leading, so
                        // it is uncovered from the near edge as the slot grows. It stays pinned
                        // until this node is deleted, so its size does not change when it is
                        // re-attached.
                        // Closing the left/top child: that child is the closing side, pinned at its
                        // pre-close size and aligned top-leading, clipped away as its slot
                        // collapses.
                        // The modifier chain keeps the same shape throughout (frame(nil) = no
                        // constraint) so switching between these cases does not rebuild the child.
                        let size: CGSize? = switch side {
                        case .right: geo.size
                        case .left: closingStartSize
                        case nil: nil
                        }
                        TerminalSplitSubtreeView(node: split.left, action: action,
                                                 appearingPane: appearingPane, closingPanes: closingPanes)
                            .frame(width: size?.width, height: size?.height, alignment: .topLeading)
                            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity,
                                   alignment: .topLeading)
                            .clipped()
                            // No mouse during the animation: clipped only trims what is drawn, so
                            // the part of the survivor that overflows into the closing side's slot
                            // while pinned at its final size is still clickable and hoverable, and
                            // would steal focus.
                            .allowsHitTesting(side == nil)
                    },
                    right: {
                        // During the entrance animation the new pane is pinned at its final size
                        // (top-leading, clipped to the slot), which is what produces the uncovering
                        // effect; the pin is released when it ends.
                        // Closing the left/top child: the right/bottom child is the survivor, pinned
                        // at its final size and aligned bottom-trailing, so its content stays where
                        // it will end up and is uncovered from the near edge as the slot grows
                        // left/up. Closing itself: pinned at its pre-close size, bottom-trailing,
                        // covered over in place.
                        let pin = animating && !settled
                        let final = finalRightSize(total: geo.size, split: split)
                        let size: CGSize? = switch side {
                        case .left: geo.size
                        case .right: closingStartSize
                        case nil: pin ? final : nil
                        }
                        let align: Alignment = side == nil ? .topLeading : .bottomTrailing
                        TerminalSplitSubtreeView(node: split.right, action: action,
                                                 appearingPane: appearingPane, closingPanes: closingPanes)
                            .frame(width: size?.width, height: size?.height, alignment: align)
                            // min and max are both given so the frame unconditionally takes the
                            // slot's proposed size; only then does clipped trim to the slot and only
                            // then does the alignment apply. With max alone, a child larger than the
                            // proposal expands the frame and overflows centered.
                            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity,
                                   alignment: align)
                            .clipped()
                            .opacity(animating ? progress : 1)
                            .allowsHitTesting(side == nil)
                    },
                    onEqualize: {
                        // QuickTerm: no longer routed through the engine, since a leaf is not
                        // necessarily a terminal
                        action(.equalize)
                    }
                )
                .onChange(of: key, initial: true) { _, key in
                    // 1) The latched leaf is no longer a direct child (the close finished, or this
                    //    view was reused after a sibling subtree displaced it) -> reset, so this
                    //    view can play the next close.
                    if let leaf = closingLeaf, !key.isDirectChild(leaf) {
                        closingLeaf = nil
                        closingSide = nil
                        closingStartSize = nil
                        closeProgress = 0
                    }
                    // 2) A new close -> latch once and start the animation. The model clearing
                    //    closingPanes afterwards (on flush, or when the animation lands) does not
                    //    roll back an animation already in flight.
                    guard closingLeaf == nil, let pending = key.pending else { return }
                    closingLeaf = pending.leaf
                    closingSide = pending.side
                    closingStartSize = childSize(pending.side, total: geo.size, split: split)
                    // If this leaf's collapse already played in the (now displaced) child split
                    // view and this view picked it up after resetting, jump straight to the end
                    // state instead of snapping the survivor back to replay it.
                    let alreadyCollapsed = Self.collapsed.contains(pending.leaf)
                    Self.collapsed.insert(pending.leaf)
                    if alreadyCollapsed {
                        closeProgress = 1
                    } else {
                        withAnimation(.easeOut(duration: 0.28)) { closeProgress = 1 }
                    }
                }
            }
            .onAppear {
                guard animating, progress < 1 else { return }
                DispatchQueue.main.async {
                    withAnimation(.easeOut(duration: 0.28), completionCriteria: .logicallyComplete) {
                        progress = 1
                    } completion: {
                        settled = true
                    }
                }
            }
        }
    }

    /// The divider's layout footprint, matching what we hand to SplitView; 1pt with gaps off.
    private var splitterLayoutSize: CGFloat {
        SplitViewMetrics.splitterLayoutSize(gapsEnabled: theme.gapsEnabled)
    }

    /// The final size of the new pane (the right/bottom child) — the same algorithm as
    /// SplitView.rightRect: the divider's layout size (SplitViewMetrics.splitterLayoutSize) straddles
    /// the boundary, with an increment of 1.
    private func finalRightSize(total: CGSize, split: SplitTree<PaneView>.Node.Split) -> CGSize {
        let ratio = CGFloat(split.ratio)
        let half = splitterLayoutSize / 2
        switch split.direction {
        case .horizontal:
            var lw = total.width * ratio - half
            lw -= lw.truncatingRemainder(dividingBy: 1)
            return CGSize(width: max(total.width - (lw + half), 1), height: total.height)
        case .vertical:
            var lh = total.height * ratio - half
            lh -= lh.truncatingRemainder(dividingBy: 1)
            return CGSize(width: total.width, height: max(total.height - (lh + half), 1))
        }
    }

    /// The current size of the child on one side (per `ratio`) — the same algorithm as
    /// SplitView.leftRect/rightRect: left/top is its size after rounding, right/bottom = total -
    /// left - the divider's layout size. Matching it exactly is what keeps a pin from landing a
    /// fraction of a point off the existing slot and triggering a pointless PTY reflow.
    private func childSize(_ side: ClosingSide, total: CGSize,
                           split: SplitTree<PaneView>.Node.Split) -> CGSize {
        let ratio = CGFloat(split.ratio)
        let half = splitterLayoutSize / 2
        switch (side, split.direction) {
        case (.right, _):
            return finalRightSize(total: total, split: split)
        case (.left, .horizontal):
            var lw = total.width * ratio - half
            lw -= lw.truncatingRemainder(dividingBy: 1)
            return CGSize(width: max(lw, 1), height: total.height)
        case (.left, .vertical):
            var lh = total.height * ratio - half
            lh -= lh.truncatingRemainder(dividingBy: 1)
            return CGSize(width: total.width, height: max(lh, 1))
        }
    }
}

private struct TerminalSplitLeaf: View {
    @EnvironmentObject var theme: ThemeManager   // QuickTerm: pane padding (pane-gap)
    let surfaceView: PaneView
    let isSplit: Bool
    let action: (TerminalSplitOperation) -> Void
    /// QuickTerm: while closing, fade out and stop taking mouse input, so hovering no longer steals
    /// focus.
    var closing: Bool = false
    /// The fade is driven by state rather than bound to `closing` directly: a leaf that is already
    /// closing the moment it is born (its structural identity changed in the same round as the
    /// flush) has no value change to animate and would just be invisible.
    @State private var faded = false

    @State private var dropState: DropState = .idle
    @State private var isSelfDragging: Bool = false
    // QuickTerm: whether Cmd is held, which is what surfaces the drag source
    @ObservedObject private var modifierState = ModifierState.shared
    @State private var dragSourceDragging: Bool = false
    @State private var dragSourceHovering: Bool = false

    var body: some View {
        GeometryReader { geometry in
            // QuickTerm trim: InspectableSurface (the inspector split wrapper) -> plain SurfaceWrapper
            PaneContentView(pane: surfaceView, isSplit: isSplit)   // QuickTerm: dispatch by pane kind
            .background {
                // If we're dragging ourself, we hide the entire drop zone. This makes
                // it so that a released drop animates back to its source properly
                // so it is a proper invalid drop zone.
                if !isSelfDragging {
                    Color.clear
                        .onDrop(of: [.ghosttySurfaceId], delegate: SplitDropDelegate(
                            dropState: $dropState,
                            viewSize: geometry.size,
                            destinationSurface: surfaceView,
                            action: action
                        ))
                }
            }
            .overlay {
                if !isSelfDragging, case .dropping(let zone) = dropState {
                    zone.overlay(in: geometry)
                        .allowsHitTesting(false)
                }
            }
            .overlay {
                // QuickTerm (spec §4.2): holding Cmd turns the whole pane into a drag source — drop
                // on the target's center to swap, on an edge to split and insert. It disappears the
                // moment Cmd is released and never gets in the way of normal mouse work.
                // It also stays mounted while a drag is in progress: if Cmd is released before the
                // left button, we must not tear down a live NSDraggingSource, or
                // draggingSession(endedAt:) never reaches a view that is still in the window and
                // PaneDragState never gets to clean up.
                if modifierState.commandHeld || dragSourceDragging {
                    Ghostty.SurfaceDragSource(
                        surfaceView: surfaceView,
                        isDragging: $dragSourceDragging,
                        isHovering: $dragSourceHovering)
                }
            }
            .onPreferenceChange(Ghostty.DraggingSurfaceKey.self) { value in
                isSelfDragging = value == surfaceView.id
                if isSelfDragging {
                    dropState = .idle
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Terminal pane")
            // QuickTerm: pane visuals (focus border / gaps_in / pop-in animation); see PaneChrome.swift
            .modifier(PaneChrome(surfaceView: surfaceView))
            // Close animation: fade out. The geometric collapse is the parent SplitBranchView's
            // job; a lone leaf at the root only fades.
            .opacity(faded ? 0 : 1)
            .allowsHitTesting(!closing)
            .onChange(of: closing, initial: true) { _, closing in
                if !closing { faded = false; return }   // identity reuse: not closing = visible
                guard !faded else { return }
                withAnimation(.easeOut(duration: 0.28)) { faded = true }
            }
        }
    }

    private enum DropState: Equatable {
        case idle
        case dropping(TerminalSplitDropZone)
    }

    private struct SplitDropDelegate: DropDelegate {
        @Binding var dropState: DropState
        let viewSize: CGSize
        let destinationSurface: PaneView
        let action: (TerminalSplitOperation) -> Void

        func validateDrop(info: DropInfo) -> Bool {
            // QuickTerm: cross-window drops are refused outright; a pane lives in exactly one window
            guard PaneDragState.shared.allowsDrop(on: destinationSurface) else { return false }
            return info.hasItemsConforming(to: [.ghosttySurfaceId])
        }

        func dropEntered(info: DropInfo) {
            // QuickTerm: a cross-window drag does not light up the drop zone
            guard PaneDragState.shared.allowsDrop(on: destinationSurface) else { return }
            dropState = .dropping(.calculate(at: info.location, in: viewSize))
        }

        func dropUpdated(info: DropInfo) -> DropProposal? {
            // QuickTerm: a cross-window drag gets the not-allowed cursor
            guard PaneDragState.shared.allowsDrop(on: destinationSurface) else {
                return DropProposal(operation: .forbidden)
            }
            // For some reason dropUpdated is sent after performDrop is called
            // and we don't want to reset our drop zone to show it so we have
            // to guard on the state here.
            guard case .dropping = dropState else { return DropProposal(operation: .forbidden) }
            dropState = .dropping(.calculate(at: info.location, in: viewSize))
            return DropProposal(operation: .move)
        }

        func dropExited(info: DropInfo) {
            dropState = .idle
        }

        func performDrop(info: DropInfo) -> Bool {
            let zone = TerminalSplitDropZone.calculate(at: info.location, in: viewSize)
            dropState = .idle
            // QuickTerm: cross-window drops are refused outright
            guard PaneDragState.shared.allowsDrop(on: destinationSurface) else { return false }

            // Load the dropped surface asynchronously using Transferable
            let providers = info.itemProviders(for: [.ghosttySurfaceId])
            guard let provider = providers.first else { return false }

            // Capture action before the async closure
            _ = provider.loadTransferable(type: PaneView.self) { [weak destinationSurface] result in
                switch result {
                case .success(let sourceSurface):
                    DispatchQueue.main.async {
                        // Don't allow dropping on self
                        guard let destinationSurface else { return }
                        guard sourceSurface !== destinationSurface else { return }
                        action(.drop(.init(payload: sourceSurface, destination: destinationSurface, zone: zone)))
                    }

                case .failure:
                    break
                }
            }

            return true
        }
    }
}

enum TerminalSplitDropZone: String, Equatable {
    case top
    case bottom
    case left
    case right
    // QuickTerm extension (spec §4.2): dropping on the target's center swaps the two panes
    case center

    /// Determines which drop zone the cursor is in based on proximity to edges.
    ///
    /// Divides the view into four triangular regions by drawing diagonals from
    /// corner to corner. The drop zone is determined by which edge the cursor
    /// is closest to, creating natural triangular hit regions for each side.
    /// QuickTerm: the central 40%×40% region is .center (swap).
    static func calculate(at point: CGPoint, in size: CGSize) -> TerminalSplitDropZone {
        let relX = point.x / size.width
        let relY = point.y / size.height

        if (0.3...0.7).contains(relX), (0.3...0.7).contains(relY) {
            return .center
        }

        let distToLeft = relX
        let distToRight = 1 - relX
        let distToTop = relY
        let distToBottom = 1 - relY

        let minDist = min(distToLeft, distToRight, distToTop, distToBottom)

        if minDist == distToLeft { return .left }
        if minDist == distToRight { return .right }
        if minDist == distToTop { return .top }
        return .bottom
    }

    @ViewBuilder
    func overlay(in geometry: GeometryProxy) -> some View {
        let overlayColor = Color.accentColor.opacity(0.3)

        switch self {
        case .top:
            VStack(spacing: 0) {
                Rectangle()
                    .fill(overlayColor)
                    .frame(height: geometry.size.height / 2)
                Spacer()
            }
        case .bottom:
            VStack(spacing: 0) {
                Spacer()
                Rectangle()
                    .fill(overlayColor)
                    .frame(height: geometry.size.height / 2)
            }
        case .left:
            HStack(spacing: 0) {
                Rectangle()
                    .fill(overlayColor)
                    .frame(width: geometry.size.width / 2)
                Spacer()
            }
        case .right:
            HStack(spacing: 0) {
                Spacer()
                Rectangle()
                    .fill(overlayColor)
                    .frame(width: geometry.size.width / 2)
            }
        case .center:
            Rectangle()
                .fill(overlayColor)
                .padding(geometry.size.width * 0.15)
        }
    }
}
