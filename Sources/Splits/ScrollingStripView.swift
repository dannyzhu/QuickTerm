import SwiftUI

/// Renderer for the scrolling layout's endless canvas (spec §4.2-bis):
/// a horizontal strip of columns, each widthFactor x viewport wide, with panes stacked in equal
/// shares vertically inside a column.
/// The viewport follows the focused column by the smallest scroll that works (~0.15s easeOut), and
/// the neighbouring columns peek in naturally at either edge.
struct ScrollingStripView: View {
    let strip: ScrollingStrip
    let workspaceIndex: Int
    let pan: WorkspaceModel.StripPanEvent?
    let onDrop: (PaneView, PaneView, TerminalSplitDropZone) -> Void
    /// Panes currently fading out; once the fade finishes the controller removes them and the strip
    /// reflows.
    var closingPanes: Set<UUID> = []

    @EnvironmentObject var theme: ThemeManager   // pane-gap (the floor on the peek moves with it)
    @State private var offset: CGFloat = 0
    @State private var lastPanSerial: Int = -1
    /// Pane identities seen so far: used on a structural change to recognize a just-inserted column
    /// (see revealTarget).
    @State private var knownPaneIDs: Set<UUID>?

    // The gap between columns comes from adjacent PaneChrome pane-gap paddings composing into
    // 2x gap (= gaps_in x 2).
    private let columnGap: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            // Column widths are computed **outside** the zoom branch: widths keep changing while
            // zoomed (visible column count, window resize), and the offset has to be clamped along
            // with them, or leaving zoom drops the strip somewhere outside its own content.
            let widths = strip.columnWidths(viewport: geo.size.width, gap: columnGap)
            ZStack(alignment: .topLeading) {
                if let zoomed = strip.zoomedPane {
                    // Zoom: the focused pane fills the content area (same semantics as dwindle)
                    ScrollingPaneCell(surfaceView: zoomed, onDrop: onDrop,
                                      closing: closingPanes.contains(zoomed.id))
                        // zooming a different pane needs a new view identity (state such as
                        // `faded` must not carry over)
                        .id(zoomed.id)
                } else {
                    HStack(alignment: .top, spacing: columnGap) {
                        ForEach(Array(strip.columns.enumerated()),
                                id: \.element.id) { index, column in
                            VStack(spacing: 0) {
                                ForEach(column.panes, id: \.id) { pane in
                                    ScrollingPaneCell(surfaceView: pane, onDrop: onDrop,
                                                      closing: closingPanes.contains(pane.id))
                                }
                            }
                            .frame(width: max(widths[index], 50))
                        }
                    }
                    .frame(height: geo.size.height, alignment: .top)
                    .offset(x: -offset)
                    .onPreferenceChange(FocusedStripPaneKey.self) { focusedID in
                        scrollToFocus(id: focusedID, viewport: geo.size.width)
                    }
                    .onChange(of: pan) {
                        // Panning only means anything once the strip is laid out.
                        applyPan(viewport: geo.size.width)
                    }
                }
            }
            // ↓ Viewport alignment always hangs **outside** the zoom branch. Toggling zoom tears
            // down the whole HStack and rebuilds it, and every structural operation clears zoom on
            // the way past (insertingColumnRight and friends), so "Cmd+B / Cmd+click a link after
            // Cmd+F" lands the column insert and the un-zoom in one update. Attached inside the
            // branch, the rebuilt HStack only runs onAppear - which records the just-inserted pane
            // as one it has "seen all along" - and onChange never fires for a freshly created view,
            // so nothing is left to reveal the new column and we fall back to the old focus-only
            // path.
            .onAppear {
                // Record the existing identities on first mount: only panes that show up later
                // count as newly inserted.
                knownPaneIDs = Set(strip.paneList.map(\.id))
            }
            .onChange(of: strip.layoutSignature) {
                // Realign after a structural change (insert/remove a column, Cmd+Shift+direction
                // swap, merge/split): a newly inserted column wins, otherwise current focus, so the
                // pane that was moved or created is always fully visible.
                scrollToFocus(id: revealTarget(), viewport: geo.size.width)
            }
            .onChange(of: widths) { old, new in
                // Column width / viewport changed (a different "visible columns per screen",
                // Cmd+Ctrl+= reset, drag-resize, window resize): only pull the offset back into
                // legal range, never chase focus - chasing would hijack a manual pan.
                // Same column count = a pure width change: clamp per event with **no animation**,
                // tracking the hand (the same treatment applyPan gives an in-flight gesture).
                // Cmd+right-drag resizing writes a width per event, and with the strip parked at
                // the right end every one of those events triggers a clamp: animated, each frame
                // restarts a 0.15s easeOut, so the viewport drags a tail behind it and the right
                // edge opens up empty.
                clampOffset(viewport: geo.size.width, animated: old.count != new.count)
            }
            .onChange(of: workspaceIndex) {
                // A new workspace is a whole new strip: relearn the identities.
                knownPaneIDs = Set(strip.paneList.map(\.id))
                offset = 0
                scrollToFocus(id: currentFocusedID(), viewport: geo.size.width)
            }
        }
        .clipped()
    }

    /// Which column to reveal after a structural change: **a newly inserted pane wins**, and only
    /// when there is none does it fall back to current focus.
    ///
    /// Focus lands asynchronously (PaneView.moveFocus waits for the new pane to be mounted into the
    /// window; a browser pane's first responder is the inner WKWebView, which is another beat
    /// slower behind that), so when this callback runs focus is usually still on the old pane -
    /// aligning by focus alone parks the viewport on the old column and strands the new one past
    /// the right edge of the viewport. What the user sees is "the new browser has the wrong width":
    /// the focus border already belongs to the new browser, but its content is clipped off by the
    /// window's right edge. Revealing by identity is independent of when focus lands, and of
    /// whether hover steals it first.
    private func revealTarget() -> UUID? {
        let ids = strip.paneList.map(\.id)
        defer { knownPaneIDs = Set(ids) }
        // The whole strip being replaced (switching workspaces, dwindle→scrolling) is not "a
        // column was inserted": at least one old pane has to survive before the panes that are new
        // this round count as an insertion target.
        guard let known = knownPaneIDs, ids.contains(where: known.contains) else {
            return currentFocusedID()
        }
        return ids.last { !known.contains($0) } ?? currentFocusedID()
    }

    private func currentFocusedID() -> UUID? {
        // Ground truth first: which pane holds the window's first responder (or one of its
        // descendants - a browser pane's FR is the inner WKWebView).
        // During a SwiftUI remount the `focused` flag can linger on two panes at once (see
        // PaneView.viewWillMove(toWindow:)), so the fallback takes the **last** match, matching
        // FocusedStripPaneKey.reduce (last one wins). Both scroll paths have to pick the same pane:
        // otherwise one scrolls to the old column while the other stops firing, and the viewport
        // sits at the wrong place.
        let panes = strip.paneList
        if let window = panes.compactMap(\.window).first,
           let holder = panes.first(where: { $0.holdsFirstResponder(of: window) }) {
            return holder.id
        }
        return panes.last { $0.focused }?.id
    }

    private func scrollToFocus(id: UUID?, viewport: CGFloat) {
        let target: CGFloat
        let total = strip.totalWidth(viewport: viewport, gap: columnGap)
        if total <= viewport {
            // Not overflowing: center unconditionally, regardless of focus (one column = full
            // width, offset 0; two columns = equal gaps left and right).
            target = (total - viewport) / 2
        } else if let id, let pane = strip.paneList.first(where: { $0.id == id }) {
            target = strip.targetOffset(for: pane, current: offset, viewport: viewport, gap: columnGap,
                                        paneGap: theme.paneGap)
        } else {
            return
        }
        guard abs(target - offset) > 0.5 else { return }
        withAnimation(.easeOut(duration: 0.15)) { offset = target }
    }

    /// Pull the offset back into legal range: centered when the strip does not overflow, clamped to
    /// [0, total width − viewport] when it does.
    /// When column widths change without a reflow the viewport ends up outside the content
    /// (narrower columns leave the left side empty and clip the column on the right), and
    /// layoutSignature deliberately excludes widthFactor (see ScrollingStrip), so only the widths
    /// themselves can trigger this.
    /// `animated` is true only when the column count changes (insert/remove); a pure width change
    /// is a per-event gesture, and animating it drags a tail behind the hand.
    private func clampOffset(viewport: CGFloat, animated: Bool) {
        guard viewport > 0 else { return }
        let total = strip.totalWidth(viewport: viewport, gap: columnGap)
        let target = total <= viewport
            ? (total - viewport) / 2
            : min(max(offset, 0), total - viewport)
        guard abs(target - offset) > 0.5 else { return }
        guard animated else {
            var transaction = Transaction()
            transaction.disablesAnimations = true   // gesture in flight: track the hand, no tail
            withTransaction(transaction) { offset = target }
            return
        }
        withAnimation(.easeOut(duration: 0.15)) { offset = target }
    }

    /// Two-finger horizontal pan (a side feature): the strip tracks the fingers while swiping and
    /// snaps to the nearest column's left edge when the gesture ends.
    /// With content that does not overflow (one column, or two centered ones) there is nothing to
    /// pan, so this is ignored outright.
    private func applyPan(viewport: CGFloat) {
        guard let pan, pan.serial != lastPanSerial else { return }
        lastPanSerial = pan.serial
        let total = strip.totalWidth(viewport: viewport, gap: columnGap)
        guard total > viewport else { return }
        let maxOffset = total - viewport
        if pan.ended {
            // Snap to the nearest "column left edge − peek" (the same alignment rule focus
            // scrolling uses).
            let widths = strip.columnWidths(viewport: viewport, gap: columnGap)
            let peek = ScrollingStrip.peekPoints(viewport: viewport, paneGap: theme.paneGap)
            var x: CGFloat = 0
            var best: CGFloat = 0
            for width in widths {
                let candidate = x - peek
                if abs(candidate - offset) < abs(best - offset) { best = candidate }
                x += width + columnGap
            }
            withAnimation(.easeOut(duration: 0.15)) { offset = min(max(best, 0), maxOffset) }
        } else {
            offset = min(max(offset - pan.delta, 0), maxOffset)
        }
    }
}

/// Reports the focused pane id upward, driving the viewport's scroll-follow (hover focus included).
private struct FocusedStripPaneKey: PreferenceKey {
    static var defaultValue: UUID?
    static func reduce(value: inout UUID?, nextValue: () -> UUID?) {
        value = nextValue() ?? value
    }
}

/// A pane cell in the scrolling layout: SurfaceWrapper + chrome + drop target + Cmd+drag source.
/// Its behavior matches dwindle's TerminalSplitLeaf (see porting-notes).
struct ScrollingPaneCell: View {
    @ObservedObject var surfaceView: PaneView
    let onDrop: (PaneView, PaneView, TerminalSplitDropZone) -> Void
    /// Rendering in the floating layer (RootView): passed through to PaneChrome to turn off the
    /// inactive frosting.
    var floating: Bool = false
    /// Closing → fade out and stop taking the mouse (hover no longer steals focus).
    var closing: Bool = false
    /// The fade is state-driven so that a cell born already closing still fades out; see
    /// TerminalSplitLeaf.
    @State private var faded = false

    @ObservedObject private var modifierState = ModifierState.shared
    @State private var dropZone: TerminalSplitDropZone?
    @State private var dragSourceDragging = false
    @State private var dragSourceHovering = false

    var body: some View {
        GeometryReader { geo in
            PaneContentView(pane: surfaceView, isSplit: true)   // dispatches content by pane kind
                .background {
                    // A floating pane is not a drop target (getting it back into the tiling is
                    // Cmd+T): registering no delegate avoids lighting up a drop zone that would
                    // do nothing.
                    if !floating {
                        Color.clear.onDrop(
                            of: [.ghosttySurfaceId],
                            delegate: StripDropDelegate(
                                zone: $dropZone,
                                viewSize: geo.size,
                                destination: surfaceView,
                                onDrop: onDrop))
                    }
                }
                .overlay {
                    if let dropZone {
                        dropZone.overlay(in: geo).allowsHitTesting(false)
                    }
                }
                .overlay {
                    // Stay mounted while a drag is in flight: releasing Cmd before the left button
                    // must not tear down a live NSDraggingSource, or draggingSession(endedAt:)
                    // never reaches a view that is still in the window and PaneDragState never gets
                    // to clean up after itself.
                    if modifierState.commandHeld || dragSourceDragging {
                        Ghostty.SurfaceDragSource(
                            surfaceView: surfaceView,
                            isDragging: $dragSourceDragging,
                            isHovering: $dragSourceHovering)
                    }
                }
                .modifier(PaneChrome(surfaceView: surfaceView, floating: floating))
                .opacity(faded ? 0 : 1)
                .allowsHitTesting(!closing)
                .onChange(of: closing, initial: true) { _, closing in
                    // Identities get reused: a cell that is not closing has to be visible.
                    if !closing { faded = false; return }
                    guard !faded else { return }
                    withAnimation(.easeOut(duration: 0.28)) { faded = true }
                }
                .preference(key: FocusedStripPaneKey.self,
                            value: surfaceView.focused ? surfaceView.id : nil)
        }
    }
}

/// Drop target, mirroring dwindle's SplitDropDelegate; the zone calculation reuses
/// TerminalSplitDropZone.
private struct StripDropDelegate: DropDelegate {
    @Binding var zone: TerminalSplitDropZone?
    let viewSize: CGSize
    let destination: PaneView
    let onDrop: (PaneView, PaneView, TerminalSplitDropZone) -> Void

    /// Cross-window drops are refused explicitly: a pane can only be mounted in one window
    /// (PaneHostView hands back the same NSView instance), so when source and destination are in
    /// different windows this does not claim the drop - the zone stays dark and the cursor carries
    /// the "not allowed" badge, rather than failing silently.
    func validateDrop(info: DropInfo) -> Bool {
        guard PaneDragState.shared.allowsDrop(on: destination) else { return false }
        return info.hasItemsConforming(to: [.ghosttySurfaceId])
    }

    func dropEntered(info: DropInfo) {
        guard PaneDragState.shared.allowsDrop(on: destination) else { return }
        zone = .calculate(at: info.location, in: viewSize)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard PaneDragState.shared.allowsDrop(on: destination) else { return DropProposal(operation: .forbidden) }
        guard zone != nil else { return DropProposal(operation: .forbidden) }
        zone = .calculate(at: info.location, in: viewSize)
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) { zone = nil }

    func performDrop(info: DropInfo) -> Bool {
        let dropZone = TerminalSplitDropZone.calculate(at: info.location, in: viewSize)
        zone = nil
        guard PaneDragState.shared.allowsDrop(on: destination) else { return false }
        guard let provider = info.itemProviders(for: [.ghosttySurfaceId]).first else { return false }
        _ = provider.loadTransferable(type: PaneView.self) { [weak destination] result in
            if case .success(let source) = result {
                DispatchQueue.main.async {
                    guard let destination, source !== destination else { return }
                    onDrop(source, destination, dropZone)
                }
            }
        }
        return true
    }
}
