import AppKit

/// Encode the live registries as `quickterm.state/1`.
/// **Everything goes through JSONEncoder** (`ControlStatePayload` is Codable) — never hand-build
/// JSON: yabai once shipped a release whose `query --windows` emitted a trailing comma, and it
/// broke every downstream jq pipeline.
@MainActor
struct ControlStateEncoder {
    let screens: ScreenRegistry
    /// The request carried a valid origin token (this decides whether a browser pane's URL /
    /// title get redacted)
    let trusted: Bool
    /// `[control] expose-browser`: token | always | never
    let exposeBrowser: String
    let mode: String

    static let redacted = "<redacted>"

    var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
    }

    /// Whether a browser pane's URL / title are visible at all.
    /// One rule, answering head-on the fact that a browser pane holds the user's logged-in
    /// sessions: a caller without the token does not get to read them — `quickterm state` is
    /// itself an exfiltration surface
    var exposesBrowser: Bool {
        switch exposeBrowser {
        case "always": true
        case "never": false
        default: trusted
        }
    }

    func payload(scope: MainWindowController? = nil) -> ControlStatePayload {
        let controllers = scope.map { [$0] } ?? screens.controllers
        // **`screens.key` must not be used here**: that is `NSApp.keyWindow`, which is nil
        // while the app is not frontmost, so every screen would report `key: false` while each
        // of them reported a pane with `focused: true` — and describe's disambiguation rule,
        // "the globally unique one is on the screen with `key: true`", would have no answer at
        // all. An agent driving from Terminal.app or a background job is running in **exactly**
        // the situation where the app is not frontmost, which is why this never reproduces
        // locally, where QuickTerm is always in front.
        // Using the same ladder as target resolution (controlCurrent) guarantees there is
        // always one key screen and only one
        let keyController = screens.controlCurrent
        return ControlStatePayload(
            app: .init(version: appVersion,
                       protocolVersion: ControlProtocol.version,
                       workspaceCount: screens.primary?.model.layouts.count ?? 0,
                       mode: mode,
                       trusted: trusted),
            screens: controllers.map { screenInfo($0, isKey: $0 === keyController) },
            panes: controllers.flatMap { paneInfos(of: $0) })
    }

    func screenInfo(_ controller: MainWindowController, isKey: Bool) -> ControlStatePayload.ScreenInfo {
        let model = controller.model
        let display = DisplayRef(screen: controller.window?.screen)
        let frame = controller.savedFrame ?? controller.window?.frame
        return .init(
            index: controller.screenIndex + 1,
            id: controller.windowID.uuidString,
            title: controller.window?.title ?? ScreenRegistry.title(forIndex: controller.screenIndex),
            key: isKey,
            activeWorkspace: model.activeIndex + 1,
            visibleColumns: controller.visibleColumns,
            fullscreen: controller.isSimpleFullscreen,
            joinAllSpaces: controller.joinsAllSpaces,
            display: display.map { .init(uuid: $0.uuid, name: $0.name) },
            frame: frame.map { [$0.origin.x, $0.origin.y, $0.size.width, $0.size.height] },
            workspaces: model.layouts.indices.map { workspaceInfo(controller, index: $0) })
    }

    /// The layout with the leaves that are fading out taken out of it.
    /// **The tree, the columns and the geometry all share this one copy**: it used to be only
    /// the tree that collapsed while the rects were still computed from the uncollapsed one, so
    /// for the 0.28 s it takes to close a pane `state` would say "t1 is the entire workspace"
    /// and in the same breath hand t1 a half-width rect and a divider that no longer exists in
    /// the tree. Everywhere else in the control plane (addressing, event snapshots) has long
    /// treated a fading pane as already gone; this follows the same rule
    static func pruned(_ layout: WorkspaceLayout, closing: Set<UUID>) -> WorkspaceLayout {
        guard !closing.isEmpty else { return layout }
        switch layout {
        case .dwindle(let tree):
            var next = tree
            for pane in tree.root?.leaves() ?? [] where closing.contains(pane.id) {
                guard let node = next.root?.node(view: pane) else { continue }
                next = next.removing(node)
            }
            return .dwindle(next)
        case .scrolling(let strip):
            guard strip.paneList.contains(where: { closing.contains($0.id) }) else { return layout }
            var next = strip
            // Empty columns are kept: the column is still on screen and so is its width; all
            // that went away is the one pane fading out of it
            for index in next.columns.indices {
                next.columns[index].panes.removeAll { closing.contains($0.id) }
            }
            return .scrolling(next)
        }
    }

    /// The pane zoomed in this workspace (while one is zoomed, not a single one of the other
    /// tiled panes renders)
    static func zoomedPaneID(in layout: WorkspaceLayout) -> UUID? {
        switch layout {
        case .scrolling(let strip):
            return strip.zoomedPane?.id
        case .dwindle(let tree):
            guard let zoomed = tree.zoomed, case .leaf(let view) = zoomed else { return nil }
            return view.id
        }
    }

    func workspaceInfo(_ controller: MainWindowController, index: Int) -> ControlStatePayload.WorkspaceInfo {
        let model = controller.model
        let closing = model.closingPanes
        // One shape: the tree, the columns and every pane's rect all come out of this copy
        let layout = Self.pruned(model.layouts[index], closing: closing)
        let handles = layout.paneList.map { ControlHandleRegistry.shared.handle(for: $0) }
        let floating = model.floatings[index].map(\.pane).filter { !closing.contains($0.id) }
            .map { ControlHandleRegistry.shared.handle(for: $0) }

        var columns: [ControlStatePayload.ColumnInfo]?
        var tree: ControlStatePayload.TreeNode?
        var zoom: String?
        switch layout {
        case .scrolling(let strip):
            columns = strip.columns.map { column in
                .init(width: column.widthFactor,
                      panes: column.panes.map { ControlHandleRegistry.shared.handle(for: $0) })
            }
        case .dwindle(let splitTree):
            tree = Self.treeNode(splitTree.root, closing: [])
        }
        if let id = Self.zoomedPaneID(in: layout),
           let pane = layout.paneList.first(where: { $0.id == id }) {
            zoom = ControlHandleRegistry.shared.handle(for: pane)
        }

        return .init(
            index: index + 1,
            title: model.title(at: index),
            layout: layout.name,
            empty: handles.isEmpty && floating.isEmpty,
            active: index == model.activeIndex,
            panes: handles,
            zoom: zoom,
            columns: columns,
            tree: tree,
            floating: floating)
    }

    /// The dwindle skeleton: `{split,ratio,a,b}`, leaves `{pane:"t1"}` — **word for word the
    /// same vocabulary as `spec dump`**, where a leaf holds the pane's whole record while here
    /// it holds only the handle.
    /// A leaf that is fading out counts as already gone and the tree collapses onto the other
    /// side (the same rule as `SpecCodec.node` / `SplitTree.removing`)
    static func treeNode(_ node: SplitTree<PaneView>.Node?,
                         closing: Set<UUID>) -> ControlStatePayload.TreeNode? {
        guard let node else { return nil }
        switch node {
        case .leaf(let view):
            guard !closing.contains(view.id) else { return nil }
            return .leaf(ControlHandleRegistry.shared.handle(for: view))
        case .split(let split):
            let a = treeNode(split.left, closing: closing)
            let b = treeNode(split.right, closing: closing)
            guard let a else { return b }
            guard let b else { return a }
            let direction = split.direction == .horizontal ? "horizontal" : "vertical"
            return .split(.init(split: direction, ratio: ControlGeometry.rounded(split.ratio),
                                a: a, b: b))
        }
    }

    /// Position within the dwindle tree: left = `a`, right = `b`, joined with dots (the root is
    /// the empty string)
    static func pathString(_ path: SplitTree<PaneView>.Path) -> String {
        path.path.map { component in
            switch component {
            case .left: "a"
            case .right: "b"
            }
        }.joined(separator: ".")
    }

    /// One pane's geometry (see `PaneSize`). **All of it computed from the model**, never read
    /// off a frame.
    /// When the size cannot be worked out — the pane is no longer in this workspace — it returns
    /// nil: better to leave the section out than to hand back a number from last frame
    static func paneSize(_ pane: PaneView, controller: MainWindowController,
                         workspace: Int, float: Bool) -> ControlStatePayload.PaneInfo.PaneSize? {
        guard controller.model.layouts.indices.contains(workspace) else { return nil }
        let content = ControlGeometry.contentSize(controller)
        // The same shape as the tree / columns in `workspaceInfo` (leaves that are fading out
        // have already collapsed)
        let layout = pruned(controller.model.layouts[workspace], closing: controller.model.closingPanes)
        let zoomedID = zoomedPaneID(in: layout)
        var size = ControlStatePayload.PaneInfo.PaneSize(rect: [])

        if float {
            guard let item = controller.model.floatings[workspace].first(where: { $0.pane === pane })
            else { return nil }
            size.rect = ControlGeometry.rect(item.rect)
        } else {
            guard let normalized = ControlGeometry.paneRects(in: layout, size: ControlGeometry.unit)[pane.id]
            else { return nil }
            size.rect = ControlGeometry.rect(normalized)
            switch layout {
            case .dwindle(let tree):
                // The nearest parent split = this pane's own path minus its last component; a
                // lone leaf at the root has no parent split
                if let root = tree.root, let node = root.node(view: pane),
                   let path = root.path(to: node), !path.path.isEmpty {
                    let parent = pathString(SplitTree<PaneView>.Path(path: Array(path.path.dropLast())))
                    if let slot = ControlGeometry.splits(in: tree, size: ControlGeometry.unit)
                        .first(where: { $0.path == parent }) {
                        size.split = slot.direction
                        size.ratio = ControlGeometry.rounded(slot.ratio)
                    }
                }
            case .scrolling(let strip):
                if let (column, _) = strip.position(of: pane) {
                    // The **nominal column-width factor** (the number the model holds, i.e. the
                    // one `pane set --width` writes), not the effective width after fill mode
                    // has scaled it up: that one is in the rect
                    size.width = ControlGeometry.rounded(strip.columns[column].widthFactor)
                    size.share = ControlGeometry.rounded(1.0 / Double(max(strip.columns[column].panes.count, 1)))
                }
            }
        }

        // zoom: the magnified pane has the whole content area to itself, and **not one of the
        // other tiled panes renders**. rect / ratio / width still report the tiling underneath
        // (that is what `pane resize` adjusts, and un-zooming returns to it), but "how big is
        // this on screen right now" has to be answered honestly: the ones nobody can see get no
        // points and a hidden flag instead — `get -t <some sibling>` has no workspace context,
        // and without that flag it would be taken in by the point size of a 0×0 pane
        let hidden = !float && zoomedID != nil && pane.id != zoomedID
        if hidden { size.hidden = true }
        if let content, !hidden {
            if zoomedID == pane.id {
                size.points = [ControlGeometry.rounded(content.width, 1),
                               ControlGeometry.rounded(content.height, 1)]
            } else {
                size.points = [ControlGeometry.rounded(size.rect[2] * content.width, 1),
                               ControlGeometry.rounded(size.rect[3] * content.height, 1)]
            }
        }
        if let surface = (pane as? Ghostty.SurfaceView)?.surfaceSize {
            size.cols = Int(surface.columns)
            size.rows = Int(surface.rows)
        }
        return size
    }

    func paneInfos(of controller: MainWindowController) -> [ControlStatePayload.PaneInfo] {
        let model = controller.model
        var out: [ControlStatePayload.PaneInfo] = []
        for index in model.layouts.indices {
            let workspaceInfo = self.workspaceInfo(controller, index: index)
            let positions = Self.positions(in: model.layouts[index], closing: model.closingPanes)
            for pane in model.layouts[index].paneList where !model.closingPanes.contains(pane.id) {
                out.append(paneInfo(pane, controller: controller, workspace: index,
                                    at: positions[pane.id], float: false,
                                    zoomed: workspaceInfo.zoom == ControlHandleRegistry.shared.handle(for: pane)))
            }
            for floating in model.floatings[index] where !model.closingPanes.contains(floating.pane.id) {
                out.append(paneInfo(floating.pane, controller: controller, workspace: index,
                                    at: nil, float: true, zoomed: false))
            }
        }
        return out
    }

    /// Each pane's position within the layout (`at`). Pass `closing` and the fading leaves
    /// collapse first — `at.path` has to have the same shape as the tree reported under `tree`,
    /// or an agent following `at.path` into `pane resize --split` lands on a different divider
    static func positions(in layout: WorkspaceLayout,
                          closing: Set<UUID> = []) -> [UUID: ControlStatePayload.PaneInfo.Position] {
        var out: [UUID: ControlStatePayload.PaneInfo.Position] = [:]
        switch pruned(layout, closing: closing) {
        case .scrolling(let strip):
            for (c, column) in strip.columns.enumerated() {
                for (r, pane) in column.panes.enumerated() {
                    out[pane.id] = .init(column: c, row: r, path: nil)
                }
            }
        case .dwindle(let tree):
            for pane in tree.root?.leaves() ?? [] {
                guard let node = tree.root?.node(view: pane),
                      let path = tree.root?.path(to: node) else { continue }
                out[pane.id] = .init(column: nil, row: nil, path: pathString(path))
            }
        }
        return out
    }

    /// The per-tab detail of a browser pane. **The redaction rule is word for word the one used
    /// at pane level** for url / title (the same `hide`): a caller without the token still gets
    /// index / id / active — those are what addressing needs and they leak nothing — but the
    /// title and the URL are always `<redacted>`.
    /// Opening a "tab level is not redacted" hole here would void the pane-level rule entirely
    static func tabList(of pane: BrowserPaneView, hide: Bool)
        -> [ControlStatePayload.PaneInfo.TabInfo] {
        pane.tabs.enumerated().map { index, tab in
            .init(index: index + 1,
                  id: tab.id.uuidString,
                  active: index == pane.activeTabIndex,
                  title: hide ? redacted : tab.displayTitle,
                  url: hide ? redacted : (tab.effectiveURL?.absoluteString ?? ""),
                  loading: tab.webView.isLoading ? true : nil)
        }
    }

    func paneInfo(_ pane: PaneView, controller: MainWindowController, workspace: Int,
                  at position: ControlStatePayload.PaneInfo.Position?,
                  float: Bool, zoomed: Bool) -> ControlStatePayload.PaneInfo {
        let browser = pane as? BrowserPaneView
        let hide = browser != nil && !exposesBrowser
        return .init(
            handle: ControlHandleRegistry.shared.handle(for: pane),
            id: pane.id.uuidString,
            kind: pane.kind.rawValue,
            role: controller.controlRole(of: pane),
            screen: controller.screenIndex + 1,
            workspace: workspace + 1,
            at: position,
            size: Self.paneSize(pane, controller: controller, workspace: workspace, float: float),
            title: hide ? Self.redacted : pane.paneTitle,
            // "Has it been taken over" - `customTitle` is the base class's hook onto exactly that
            // (a terminal pane's `hasControlTitle`; a browser pane has no such thing, its title is
            // the page's). Encoded only when true, the same way `redacted` is: an absent field
            // means the shell still owns the title.
            titleSet: pane.customTitle != nil ? true : nil,
            cwd: pane.workingDirectory,
            url: browser.map { hide ? Self.redacted : ($0.currentURL?.absoluteString ?? "") },
            tabs: browser?.tabs.count,
            tabList: browser.map { Self.tabList(of: $0, hide: hide) },
            focused: controller.focusedPane === pane && controller.model.activeIndex == workspace,
            busy: pane.wantsConfirmClose,
            float: float,
            zoom: zoomed,
            redacted: hide ? true : nil)
    }
}
