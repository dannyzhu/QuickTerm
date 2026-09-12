import AppKit

/// The **absolute setter** entry points the control plane (`Sources/Control`) needs.
///
/// The only reason this layer exists: the app's own WM actions are all toggles and
/// "relative to the focused pane" (`toggle-zoom`, `moveFocusedPane(to:)`), while an agent cannot
/// see state - retrying a toggle once undoes what it just did.
/// So every switch gets a "set it to this value" form, and every relative operation gets a
/// "name the target explicitly" form.
///
/// The implementation **always reuses the existing value-type operations** (`ScrollingStrip`,
/// `SplitTree`, `insertNewPane`, and the dropping semantics of `scrollingDrop`) and never writes a
/// second set: a second set will eventually disagree with drag and drop about where a pane lands.
///
/// Everything here is main-thread only. `MainWindowController` carries no `@MainActor` annotation
/// and Swift 5.10 will not check it for us, so the caller - `ControlCommandRunner` - has a
/// `dispatchPrecondition` at every entry point.
extension MainWindowController {
    // MARK: Snapshots (for undo)

    /// A complete layout snapshot of one screen. `layouts` and `floatings` are value types, so
    /// capturing them is a complete copy of the old state - reconstructing an undo operation by
    /// operation will sooner or later miss something that was cleared as a side effect, like the
    /// zoom or a column width.
    /// `controller` is weak: the undo stack must never resurrect a screen that has been closed.
    struct ControlSnapshot {
        weak var controller: MainWindowController?
        var layouts: [WorkspaceLayout]
        var floatings: [[FloatingPane]]
        var activeIndex: Int
        /// Per-workspace names: restored together with the whole layout, otherwise Cmd+Z on a
        /// rename does nothing at all.
        var titles: [String?]
        var visibleColumns: Int
        /// The set of panes this screen should have **after** the change (ids only, no strong
        /// references).
        /// Restoring the whole layout replaces the entire set of panes, so an undo is only valid
        /// while "nobody has touched the pane set since". If it does not match, the whole entry is
        /// discarded - otherwise panes created afterwards would be wiped out silently (with not one
        /// teardown running), and panes closed afterwards would be resurrected as they were.
        var expectedPaneIDs: Set<UUID> = []

        /// The set of panes the snapshot itself holds (the set that should exist after an undo)
        var snapshotPaneIDs: Set<UUID> {
            Set(layouts.flatMap { $0.paneList.map(\.id) }
                + floatings.flatMap { $0.map(\.pane.id) })
        }

        /// Undoing this step also closes panes (undoing a `pane new` is exactly this case)
        var closesPanesOnRestore: Bool { !expectedPaneIDs.subtracting(snapshotPaneIDs).isEmpty }

        /// The screen still holds exactly the set of panes this change left behind
        @MainActor
        func matchesLive() -> Bool {
            guard let controller, !controller.isClosed else { return false }
            controller.flushPendingCloses()
            return controller.controlLivePaneIDs() == expectedPaneIDs
        }

        /// Re-stamp "which panes should exist" after the change. **Must be called after apply()**
        @MainActor
        mutating func stampExpectedPanes() {
            expectedPaneIDs = controller?.controlLivePaneIDs() ?? []
        }

        @discardableResult
        @MainActor
        func restore() -> Bool {
            guard let controller, !controller.isClosed else { return false }
            controller.flushPendingCloses()
            // Do not undo once the pane set has changed: restoring the whole layout would replace
            // the pane set itself along with it.
            guard controller.controlLivePaneIDs() == expectedPaneIDs else { return false }
            // Panes this change **created**: undoing has to close them, and "close" means going
            // through the close path (a browser pane cancels its downloads and tells extensions the
            // window is gone; a file manager deletes its cwd temp file).
            // Simply having them vanish from `layouts` leaks a terminal.
            let keep = snapshotPaneIDs
            for pane in controller.model.layouts.flatMap(\.paneList)
                + controller.model.floatings.flatMap({ $0.map(\.pane) })
            where !keep.contains(pane.id) {
                controller.removeFromAnyWorkspace(pane)
            }
            // Restore the visible column count first (it re-lays out every scrolling column
            // width), then restore the layouts wholesale - the other order lets setVisibleColumns
            // wipe the column widths.
            controller.setVisibleColumns(visibleColumns, persist: false)
            controller.model.layouts = layouts
            controller.model.floatings = floatings
            controller.model.titles = titles
            controller.model.activeIndex = min(max(activeIndex, 0), max(layouts.count - 1, 0))
            if let focus = controller.model.layouts[controller.model.activeIndex].paneList.first
                ?? controller.model.floatings[controller.model.activeIndex].first?.pane {
                controller.requestFocus(to: focus)
            }
            return true
        }
    }

    /// The panes alive on this screen right now (the Scratchpad is excluded: it is not part of a
    /// layout snapshot)
    func controlLivePaneIDs() -> Set<UUID> {
        Set(model.layouts.flatMap { $0.paneList.map(\.id) }
            + model.floatings.flatMap { $0.map(\.pane.id) })
    }

    func controlSnapshot() -> ControlSnapshot {
        ControlSnapshot(controller: self, layouts: model.layouts, floatings: model.floatings,
                        activeIndex: model.activeIndex, titles: model.titles,
                        visibleColumns: visibleColumns)
    }

    // MARK: Detach and insert

    /// Take a pane out of whatever workspace it is in, running **not a single teardown** - these
    /// are move semantics.
    ///
    /// The difference from `removeFromAnyWorkspace` is the entire point: that one means "close",
    /// and calls `BrowserPaneView.paneWillClose()` (cancelling downloads, telling extensions the
    /// window is gone) and deletes the file manager's cwd temp file. Moving a browser pane to
    /// another workspace while running all that presents as "the download disappeared after the
    /// drag and the extension icon does nothing" - with no error anywhere.
    @discardableResult
    func controlDetach(_ pane: PaneView) -> Bool {
        flushPendingCloses()
        for i in model.layouts.indices {
            if let index = model.floatings[i].firstIndex(where: { $0.pane === pane }) {
                model.floatings[i].remove(at: index)
                return true
            }
            switch model.layouts[i] {
            case .dwindle(let tree):
                if let node = tree.root?.node(view: pane) {
                    model.layouts[i] = .dwindle(tree.removing(node))
                    return true
                }
            case .scrolling(let strip):
                if strip.paneList.contains(where: { $0 === pane }) {
                    model.layouts[i] = .scrolling(strip.removing(pane))
                    return true
                }
            }
        }
        return false
    }

    /// Insert a pane at a given position in **any** workspace, including an inactive one.
    ///
    /// - `zone == nil`: use the app's own default position (`insertNewPane`: a new column to the
    ///   right of the anchor in scrolling, a split by spatial geometry plus the local entry
    ///   animation in dwindle).
    /// - `zone != nil`: insert at the default position first, then move it into place with **the
    ///   drag-and-drop** semantics (`ScrollingStrip.dropping` / `SplitTree.dropping`) - the command
    ///   line and the mouse share one landing algorithm.
    @discardableResult
    func controlInsert(_ pane: PaneView, workspace: Int, anchor: PaneView?,
                       zone: TerminalSplitDropZone?, focus: Bool) -> Bool {
        flushPendingCloses()
        guard model.layouts.indices.contains(workspace) else { return false }
        let anchorInWorkspace = anchor.flatMap { candidate in
            model.layouts[workspace].paneList.contains { $0 === candidate } ? candidate : nil
        }

        if workspace == model.activeIndex {
            guard insertNewPane(pane, anchor: anchorInWorkspace) else { return false }
        } else {
            guard insertIntoInactive(pane, workspace: workspace, anchor: anchorInWorkspace) else { return false }
        }

        // Fine-tune the position: the default insert is equivalent to .right (a new column right
        // of the anchor in scrolling, a geometric split in dwindle).
        if let zone, let anchorInWorkspace {
            switch model.layouts[workspace] {
            case .scrolling(let strip):
                model.layouts[workspace] = .scrolling(strip.dropping(pane, on: anchorInWorkspace, zone: zone))
            case .dwindle(let tree):
                if let moved = tree.dropping(pane, on: anchorInWorkspace, zone: zone) {
                    model.layouts[workspace] = .dwindle(moved)
                }
            }
        }
        if focus, workspace == model.activeIndex { requestFocus(to: pane, from: anchorInWorkspace) }
        return true
    }

    /// The default insert for an inactive workspace (`insertNewPane` only handles the active one):
    /// scrolling = a new column right of the anchor, or at the end; dwindle = split the anchor by
    /// spatial geometry, or the first leaf.
    private func insertIntoInactive(_ pane: PaneView, workspace: Int, anchor: PaneView?) -> Bool {
        switch model.layouts[workspace] {
        case .scrolling(let strip):
            model.layouts[workspace] = .scrolling(
                strip.insertingColumnRight(of: anchor ?? strip.paneList.last, pane: pane,
                                           widthFactor: columnFactor))
            return true
        case .dwindle(let tree):
            if tree.isEmpty {
                model.layouts[workspace] = .dwindle(SplitTree(view: pane))
                return true
            }
            guard let target = anchor ?? tree.root?.leaves().first,
                  let next = try? tree.inserting(
                    view: pane, at: target,
                    direction: tree.dwindleDirection(for: target, in: dwindleLayoutSize)) else { return false }
            model.layouts[workspace] = .dwindle(next)
            return true
        }
    }

    // MARK: Absolute setters

    func controlIsZoomed(_ pane: PaneView, workspace: Int) -> Bool {
        guard model.layouts.indices.contains(workspace) else { return false }
        switch model.layouts[workspace] {
        // Use **the same** test as the render side (`ScrollingStripView` reads `zoomedPane`) and
        // as `ControlStateEncoder`: comparing ids alone would let a dangling zoomedID pointing at a
        // non-member (a floating pane, say) make the two read paths disagree.
        case .scrolling(let strip): return strip.zoomedPane === pane
        case .dwindle(let tree):
            guard let zoomed = tree.zoomed, case .leaf(let view) = zoomed else { return false }
            return view === pane
        }
    }

    /// `--zoom on|off`. `off` only clears the zoom of **this** pane: while some other pane is
    /// zoomed, "set t7 to not zoomed" already holds, and we must not unzoom somebody else on the
    /// way past.
    func controlSetZoom(_ pane: PaneView, workspace: Int, on: Bool) {
        guard model.layouts.indices.contains(workspace) else { return }
        switch model.layouts[workspace] {
        case .scrolling(var strip):
            if on {
                // If it is not in this strip (a floating pane) do not write: that would be a
                // dangling id the render side cannot see, which nonetheless reads back as true and
                // evicts somebody else's real zoom.
                guard strip.position(of: pane) != nil else { return }
                strip.zoomedID = pane.id
            } else if strip.zoomedID == pane.id {
                strip.zoomedID = nil
            }
            model.layouts[workspace] = .scrolling(strip)
        case .dwindle(let tree):
            guard let node = tree.root?.node(view: pane) else { return }
            if on {
                model.layouts[workspace] = .dwindle(SplitTree(root: tree.root, zoomed: node))
            } else if tree.zoomed == node {
                model.layouts[workspace] = .dwindle(SplitTree(root: tree.root, zoomed: nil))
            }
        }
    }

    func controlIsFloating(_ pane: PaneView, workspace: Int) -> Bool {
        guard model.floatings.indices.contains(workspace) else { return false }
        return model.floatings[workspace].contains { $0.pane === pane }
    }

    /// scrolling: the width factor of the column this pane is in (nil under dwindle)
    func controlColumnWidth(of pane: PaneView, workspace: Int) -> Double? {
        guard model.layouts.indices.contains(workspace),
              case .scrolling(let strip) = model.layouts[workspace],
              let (column, _) = strip.position(of: pane) else { return nil }
        return strip.columns[column].widthFactor
    }

    /// `--width 0.33` (absolute). Range validation belongs to the caller: **an out-of-range value
    /// must error out, not be silently clamped** - after a clamp the agent reads back a different
    /// value than it wrote, with nothing telling it so.
    func controlSetColumnWidth(_ pane: PaneView, workspace: Int, to width: Double) {
        guard model.layouts.indices.contains(workspace),
              case .scrolling(var strip) = model.layouts[workspace],
              let (column, _) = strip.position(of: pane) else { return }
        strip.columns[column].widthFactor = width
        model.layouts[workspace] = .scrolling(strip)
    }

    /// dwindle: the ratio of this pane's nearest parent split (`handleSplitOperation(.resize)`
    /// drives the very same thing)
    func controlSplitRatio(of pane: PaneView, workspace: Int) -> Double? {
        guard let (_, split) = controlParentSplit(of: pane, workspace: workspace) else { return nil }
        guard case .split(let s) = split else { return nil }
        return s.ratio
    }

    /// `--ratio 0.5` (absolute): equivalent to dragging the divider to a position, and it goes
    /// through exactly the divider-drag path
    @discardableResult
    func controlSetSplitRatio(_ pane: PaneView, workspace: Int, to ratio: Double) -> Bool {
        guard model.layouts.indices.contains(workspace),
              case .dwindle(let tree) = model.layouts[workspace],
              let (_, split) = controlParentSplit(of: pane, workspace: workspace),
              let next = try? tree.replacing(node: split, with: split.resizing(to: ratio)) else { return false }
        model.layouts[workspace] = .dwindle(next)
        return true
    }

    /// dwindle: address a split by **path** (`a.b`; the empty string is the root).
    /// `pane resize --split a` uses it to reach "an ancestor's divider" - the mouse can grab any
    /// divider directly, while a command line that only knows "my own parent split" cannot reach
    /// the ones further up.
    /// `size` determines the unit of `bounds`: by default it is the normalized unit box, and
    /// passing the content area size gives points (which is exactly what converting between
    /// `--points` and a ratio needs).
    func controlSplitSlot(workspace: Int, path: String,
                          size: CGSize = ControlGeometry.unit) -> ControlGeometry.SplitSlot? {
        guard model.layouts.indices.contains(workspace),
              case .dwindle(let tree) = model.layouts[workspace] else { return nil }
        return ControlGeometry.splits(in: tree, size: size).first { $0.path == path }
    }

    /// dwindle: the path of this pane's nearest parent split (a lone leaf at the root has none)
    func controlParentSplitPath(of pane: PaneView, workspace: Int) -> String? {
        guard let (path, _) = controlParentSplit(of: pane, workspace: workspace) else { return nil }
        return ControlStateEncoder.pathString(path)
    }

    /// Set a split's ratio by path (absolute; range validation belongs to the caller)
    @discardableResult
    func controlSetSplitRatio(workspace: Int, path: String, to ratio: Double) -> Bool {
        guard case .dwindle(let tree) = model.layouts[workspace],
              let slot = controlSplitSlot(workspace: workspace, path: path),
              let next = try? tree.replacing(node: slot.node, with: slot.node.resizing(to: ratio))
        else { return false }
        model.layouts[workspace] = .dwindle(next)
        return true
    }

    /// **The one divider-resize path** (dwindle): the nearest parent split along the same axis,
    /// adjusted in points.
    /// Cmd+right-drag (`resizeByDrag`), the `resize-*` shortcuts (`resizeFocused`) and the control
    /// plane's `pane resize --dir` all call it - with three separate implementations, the command
    /// line would eventually produce a different ratio than the mouse.
    /// The basis is `workspaceLayoutSize` (the area the tree is actually laid out in), the same
    /// source `size.points` uses.
    @discardableResult
    func controlResizeSplit(_ pane: PaneView, workspace: Int, points: CGFloat,
                            direction: SplitTree<PaneView>.Spatial.Direction) -> Bool {
        guard model.layouts.indices.contains(workspace),
              case .dwindle(let tree) = model.layouts[workspace],
              let node = tree.root?.node(view: pane),
              let size = workspaceLayoutSize,
              let next = try? tree.resizing(node: node,
                                            by: UInt16(min(max(points, 1), 30000)),
                                            in: direction,
                                            with: CGRect(origin: .zero, size: size))
        else { return false }
        model.layouts[workspace] = .dwindle(next)
        return true
    }

    /// **The one column-resize path** (scrolling): horizontal displacement / viewport = the delta
    /// of the width factor.
    /// Again the same one shared by Cmd+right-drag and the control plane's
    /// `--dir left|right --points`.
    /// The viewport is `workspaceLayoutSize.width`, which is precisely what `ScrollingStripView`'s
    /// `GeometryReader` measured - both sides of a column-width conversion must use the same
    /// basis.
    @discardableResult
    func controlResizeColumn(_ pane: PaneView, workspace: Int, deltaPoints: CGFloat) -> Bool {
        guard model.layouts.indices.contains(workspace),
              case .scrolling(let strip) = model.layouts[workspace],
              strip.position(of: pane) != nil, deltaPoints != 0 else { return false }
        let viewport = max(workspaceLayoutSize?.width ?? 1000, 1)
        model.layouts[workspace] = .scrolling(strip.resizingWidth(of: pane, delta: deltaPoints / viewport))
        return true
    }

    private func controlParentSplit(of pane: PaneView, workspace: Int)
        -> (path: SplitTree<PaneView>.Path, node: SplitTree<PaneView>.Node)? {
        guard model.layouts.indices.contains(workspace),
              case .dwindle(let tree) = model.layouts[workspace],
              let root = tree.root,
              let node = root.node(view: pane),
              let path = root.path(to: node), !path.path.isEmpty else { return nil }
        let parentPath = SplitTree<PaneView>.Path(path: Array(path.path.dropLast()))
        guard let parent = root.node(at: parentPath), case .split = parent else { return nil }
        return (parentPath, parent)
    }

    /// Every comparable geometric quantity in a workspace (column widths, split ratios), used to
    /// decide whether an equalize was a no-op.
    /// **Pane identity is not compared**: this diff only cares about geometry.
    func controlGeometry(workspace: Int) -> [Double] {
        guard model.layouts.indices.contains(workspace) else { return [] }
        switch model.layouts[workspace] {
        case .scrolling(let strip): return strip.columns.map(\.widthFactor)
        case .dwindle(let tree): return Self.ratios(of: tree.root)
        }
    }

    private static func ratios(of node: SplitTree<PaneView>.Node?) -> [Double] {
        guard let node else { return [] }
        switch node {
        case .leaf: return []
        case .split(let s): return [s.ratio] + ratios(of: s.left) + ratios(of: s.right)
        }
    }

    /// Equalize (in any workspace). Returns whether anything actually changed.
    @discardableResult
    func controlEqualize(workspace: Int) -> Bool {
        guard model.layouts.indices.contains(workspace) else { return false }
        let before = controlGeometry(workspace: workspace)
        switch model.layouts[workspace] {
        case .scrolling(let strip):
            model.layouts[workspace] = .scrolling(strip.equalized(to: columnFactor))
        case .dwindle(let tree):
            model.layouts[workspace] = .dwindle(tree.equalized())
        }
        let after = controlGeometry(workspace: workspace)
        return !Self.geometryMatches(before, after)
    }

    static func geometryMatches(_ a: [Double], _ b: [Double]) -> Bool {
        guard a.count == b.count else { return false }
        return zip(a, b).allSatisfy { abs($0 - $1) < 0.0005 }
    }

    /// Construct a browser pane **without inserting it into a layout**.
    /// `openBrowserPane(url:from:)` inserts into the **active** layout as soon as it is built, so
    /// it is unusable for an inactive workspace or a custom position. Applying the theme must not
    /// be skipped - without it a freshly opened browser pane has a white background that does not
    /// match the theme.
    func controlMakeBrowserPane(url: URL) -> BrowserPaneView {
        let pane = BrowserPaneView(url: url)
        applyBrowserTheme(pane)
        return pane
    }

    /// Move a pane to a different position inside the same workspace (what `pane move --at/--where`
    /// does when it targets the pane's own workspace).
    /// It goes through the drag-and-drop semantics.
    @discardableResult
    func controlReplace(_ pane: PaneView, workspace: Int, anchor: PaneView,
                        zone: TerminalSplitDropZone) -> Bool {
        guard model.layouts.indices.contains(workspace), pane !== anchor else { return false }
        switch model.layouts[workspace] {
        case .scrolling(let strip):
            model.layouts[workspace] = .scrolling(strip.dropping(pane, on: anchor, zone: zone))
        case .dwindle(let tree):
            guard let moved = tree.dropping(pane, on: anchor, zone: zone) else { return false }
            model.layouts[workspace] = .dwindle(moved)
        }
        if workspace == model.activeIndex { requestFocus(to: pane) }
        return true
    }

    /// Swap two panes (`pane swap`). dwindle uses the tree's swapping, scrolling uses drag and
    /// drop's .center semantics - the same result as the four `swap-left/right/up/down` actions,
    /// except that here the targets can be named explicitly.
    @discardableResult
    func controlSwap(_ a: PaneView, _ b: PaneView, workspace: Int) -> Bool {
        guard model.layouts.indices.contains(workspace), a !== b else { return false }
        switch model.layouts[workspace] {
        case .scrolling(let strip):
            guard strip.position(of: a) != nil, strip.position(of: b) != nil else { return false }
            model.layouts[workspace] = .scrolling(strip.dropping(a, on: b, zone: .center))
        case .dwindle(let tree):
            guard let swapped = try? tree.swapping(a, b) else { return false }
            model.layouts[workspace] = .dwindle(swapped)
        }
        if workspace == model.activeIndex { requestFocus(to: a) }
        return true
    }

    /// Hand a pane over to **another workspace, or another screen**.
    ///
    /// The app had no cross-screen path at all before this (both drop handlers assume source and
    /// destination are in the same layout). The order matters:
    /// 1. **Detach** at the source first (`controlDetach`, running not a single teardown - a
    ///    move is not a close);
    /// 2. the file manager session travels with it, otherwise its new owner does not know about it
    ///    (the close confirmation comes back, and quitting no longer opens a terminal in its
    ///    place);
    /// 3. then insert into the destination;
    /// 4. focus: when following, hand it to the destination screen (and bring that window to the
    ///    front); when not following, install a successor at the source - otherwise the source
    ///    screen's focus dangles on a pane that no longer lives there.
    /// Ownership for engine callbacks (`owns(_:)` reads `model.allPanes`) and the pane archive
    /// subscription (the layouts sink) follow along on their own, with nothing to re-register.
    @discardableResult
    func controlHandOff(_ pane: PaneView, to target: MainWindowController, workspace: Int,
                        anchor: PaneView?, zone: TerminalSplitDropZone?, follow: Bool) -> Bool {
        guard target.model.layouts.indices.contains(workspace) else { return false }
        flushPendingCloses()
        target.flushPendingCloses()
        let wasFocused = focusedPane === pane
        // The source workspace has to be recorded **before** the detach: a rollback must put the
        // pane back into the one it came from, not into "whatever is active right now" - moving it
        // out of an inactive workspace and then rolling back would relocate it somewhere else.
        let sourceWorkspace = model.layouts.indices.first { index in
            model.layouts[index].paneList.contains { $0 === pane }
                || model.floatings[index].contains { $0.pane === pane }
        } ?? model.activeIndex
        let successor = model.layouts[sourceWorkspace].paneList.first { $0 !== pane }
            ?? model.floatings[sourceWorkspace].map(\.pane).first { $0 !== pane }
        let session = controlTakeFileManagerSession(pane)
        guard controlDetach(pane) else { return false }
        guard target.controlInsert(pane, workspace: workspace, anchor: anchor, zone: zone,
                                   focus: follow) else {
            // If it will not go in, put it back where it was: never leave a pane somewhere no
            // workspace references it, which is a leaked terminal.
            controlInsert(pane, workspace: sourceWorkspace, anchor: nil, zone: nil, focus: wasFocused)
            if let session { registerFileManagerSession(pane, session) }
            return false
        }
        if let session { target.registerFileManagerSession(pane, session) }
        if follow {
            if target.model.activeIndex != workspace { target.switchWorkspace(workspace) }
            target.window?.makeKeyAndOrderFront(nil)
            target.requestFocus(to: pane)
        } else if wasFocused, let successor {
            requestFocus(to: successor)
        }
        return true
    }

    /// Close every pane in a workspace (`workspace clear`). The active workspace goes through the
    /// real close path (with focus succession and the animation), an inactive one through
    /// `removeFromAnyWorkspace` - both run the per-pane teardown.
    func controlClearWorkspace(_ index: Int, confirmIfNeeded: Bool) -> [PaneView] {
        flushPendingCloses()
        guard model.layouts.indices.contains(index) else { return [] }
        let victims = model.layouts[index].paneList + model.floatings[index].map(\.pane)
        for pane in victims {
            if index == model.activeIndex {
                closePane(pane, confirmIfNeeded: confirmIfNeeded, animated: false)
            } else {
                removeFromAnyWorkspace(pane)
            }
        }
        flushPendingCloses()
        return victims
    }
}
