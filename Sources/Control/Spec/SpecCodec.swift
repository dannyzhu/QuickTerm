import AppKit

/// **The projection pair**: the live model <-> the public schema `quickterm.workspace/1`.
///
/// This is the only seam between the public format and the internal saved state v5. The two sides
/// evolve independently: when v5 changes its envelope or adds a field, one line of projection
/// changes here and not a single character of the workspace files in a user's dotfiles has to move;
/// conversely, when the public schema gains a field (say, reading `cmd` back some day), the saved
/// state format does not have to bump its version along with it.
///
/// **Read-only**: this file does not write a single thing into the model (that lands in
/// `SpecApplier`).
@MainActor
enum SpecCodec {
    struct DumpOptions {
        /// Write paths as `~/...` wherever possible (so they still work on another machine)
        var relocatable = false
        /// Attach id / handle / title: for diffs and `--reuse`, and **not part of the fixed-point
        /// comparison**
        var includeIDs = false
        /// Whether the caller may see a browser pane's URL / title (same rule as `state`)
        var exposesBrowser = true

        init(relocatable: Bool = false, includeIDs: Bool = false, exposesBrowser: Bool = true) {
            self.relocatable = relocatable
            self.includeIDs = includeIDs
            self.exposesBrowser = exposesBrowser
        }
    }

    // MARK: dump (live model -> spec)

    static func workspace(_ controller: MainWindowController, index: Int,
                          options: DumpOptions, nested: Bool = false) -> WorkspaceSpec {
        let model = controller.model
        let closing = model.closingPanes
        func live(_ panes: [PaneView]) -> [PaneView] { panes.filter { !closing.contains($0.id) } }

        var spec = WorkspaceSpec()
        spec.schema = nested ? nil : SpecSchema.workspace
        spec.index = nested ? index + 1 : nil
        spec.layout = model.layouts[index].name
        // Only written when a name was actually given: absent = apply leaves the target
        // workspace's name alone.
        spec.title = model.title(at: index)
        spec.visibleColumns = controller.visibleColumns

        let focused = index == model.activeIndex ? controller.focusedPane : nil

        switch model.layouts[index] {
        case .scrolling(let strip):
            var columns: [ColumnSpec] = []
            for column in strip.columns {
                let panes = live(column.panes)
                guard !panes.isEmpty else { continue }
                columns.append(ColumnSpec(width: rounded(column.widthFactor),
                                          panes: panes.map { pane($0, controller: controller, options: options) }))
            }
            spec.columns = columns
            if let zoomed = strip.zoomedPane, !closing.contains(zoomed.id) {
                spec.zoom = position(of: zoomed, in: model.layouts[index], closing: closing)
            }
            if let focused, model.layouts[index].paneList.contains(where: { $0 === focused }) {
                spec.focus = position(of: focused, in: model.layouts[index], closing: closing)
            }
        case .dwindle(let tree):
            spec.tree = node(tree.root, controller: controller, options: options, closing: closing)
            if let zoomed = tree.zoomed, case .leaf(let view) = zoomed, !closing.contains(view.id) {
                spec.zoom = position(of: view, in: model.layouts[index], closing: closing)
            }
            if let focused, model.layouts[index].paneList.contains(where: { $0 === focused }) {
                spec.focus = position(of: focused, in: model.layouts[index], closing: closing)
            }
        }

        let floating = live(model.floatings[index].map(\.pane))
        if !floating.isEmpty {
            spec.floating = model.floatings[index].filter { !closing.contains($0.pane.id) }.map {
                FloatingSpec(rect: [rounded($0.rect.origin.x), rounded($0.rect.origin.y),
                                    rounded($0.rect.size.width), rounded($0.rect.size.height)],
                             pane: pane($0.pane, controller: controller, options: options))
            }
            if let focused, let at = model.floatings[index].firstIndex(where: { $0.pane === focused }) {
                spec.focus = PaneRef(floating: at)
            }
        }
        return spec
    }

    static func screen(_ controller: MainWindowController, options: DumpOptions,
                       nested: Bool = false) -> ScreenSpec {
        var spec = ScreenSpec()
        spec.schema = nested ? nil : SpecSchema.screen
        spec.index = controller.screenIndex + 1
        if let display = DisplayRef(screen: controller.window?.screen) {
            spec.display = DisplaySpec(uuid: display.uuid, name: display.name)
        }
        if let frame = controller.savedFrame ?? controller.window?.frame {
            spec.frame = [rounded(frame.origin.x, 2), rounded(frame.origin.y, 2),
                          rounded(frame.size.width, 2), rounded(frame.size.height, 2)]
        }
        spec.fullscreen = controller.isSimpleFullscreen
        spec.joinAllSpaces = controller.joinsAllSpaces
        spec.visibleColumns = controller.visibleColumns
        spec.activeWorkspace = controller.model.activeIndex + 1
        spec.workspaces = controller.model.layouts.indices.map {
            var child = workspace(controller, index: $0, options: options, nested: true)
            // The screen level already said it once; do not repeat it inside every workspace.
            child.visibleColumns = nil
            return child
        }
        return spec
    }

    static func session(_ screens: ScreenRegistry, options: DumpOptions) -> SessionSpec {
        var spec = SessionSpec()
        spec.schema = SpecSchema.session
        let controllers = screens.controllers.filter { !$0.isClosed }
        spec.screens = controllers.map { screen($0, options: options, nested: true) }
        spec.keyScreen = screens.controlCurrent.map { $0.screenIndex + 1 }
        return spec
    }

    // MARK: pane

    static func pane(_ view: PaneView, controller: MainWindowController,
                     options: DumpOptions) -> PaneSpec {
        var spec = PaneSpec()
        let role = controller.controlRole(of: view)
        spec.kind = role == "file-manager" ? "file-manager" : view.kind.rawValue
        if let cwd = view.workingDirectory, !cwd.isEmpty {
            spec.cwd = options.relocatable ? relocatable(cwd) : cwd
        }
        if let browser = view as? BrowserPaneView {
            if options.exposesBrowser {
                spec.url = browser.currentURL?.absoluteString
                // A tab that has not navigated yet (`effectiveURL` is nil) is **dropped entirely**:
                // writing an empty string would leave `url(forInput:)` on the apply side with
                // nothing to resolve, which costs a tab at best and gets the whole spec refused at
                // worst.
                let tabs = browser.tabs.compactMap { $0.effectiveURL?.absoluteString }
                if tabs.count > 1 { spec.tabs = tabs }
            } else {
                // Same rule as `state`: a caller without a token cannot read a browser pane's URL.
                // The field is **left out entirely** rather than written as "<redacted>" - written
                // in, applying this spec back would genuinely try to open a URL called
                // <redacted>.
                spec.redacted = true
            }
        }
        if options.includeIDs {
            spec.id = view.id.uuidString
            spec.handle = ControlHandleRegistry.shared.handle(for: view)
            // A title is volatile (running one command changes it): it is only handed out in
            // --include-ids, the "for humans / for diffs" mode, and never in the copy that takes
            // part in the fixed-point comparison.
            spec.title = (view as? BrowserPaneView) != nil && !options.exposesBrowser
                ? ControlStateEncoder.redacted : view.paneTitle
        }
        return spec
    }

    private static func node(_ node: SplitTree<PaneView>.Node?, controller: MainWindowController,
                             options: DumpOptions, closing: Set<UUID>) -> NodeSpec? {
        guard let node else { return nil }
        switch node {
        case .leaf(let view):
            guard !closing.contains(view.id) else { return nil }
            return .leaf(pane(view, controller: controller, options: options))
        case .split(let split):
            let a = self.node(split.left, controller: controller, options: options, closing: closing)
            let b = self.node(split.right, controller: controller, options: options, closing: closing)
            // A side that is fading out counts as already gone: the tree collapses onto the other
            // side (the same result `SplitTree.removing` produces).
            guard let a else { return b }
            guard let b else { return a }
            let direction: String = switch split.direction {
            case .horizontal: "horizontal"
            case .vertical: "vertical"
            }
            // The ratio is written out **as it is**: a divider can be dragged down to 10pt (0.006
            // on a 1600pt-wide pane), and clamping it into 0.1-0.9 would make this dump describe a
            // workspace other than the one in front of us - and applying it back would visibly jump
            // the divider.
            return .split(.init(direction: direction, ratio: rounded(split.ratio), a: a, b: b))
        }
    }

    /// A positional reference to a pane inside a layout (this is exactly what `focus` / `zoom`
    /// use)
    static func position(of pane: PaneView, in layout: WorkspaceLayout,
                         closing: Set<UUID>) -> PaneRef? {
        switch layout {
        case .scrolling(let strip):
            var column = 0
            for candidate in strip.columns {
                let panes = candidate.panes.filter { !closing.contains($0.id) }
                if panes.isEmpty { continue }
                if let row = panes.firstIndex(where: { $0 === pane }) {
                    return PaneRef(column: column, row: row)
                }
                column += 1
            }
            return nil
        case .dwindle(let tree):
            guard let root = tree.root, let node = root.node(view: pane),
                  let path = root.path(to: node) else { return nil }
            return PaneRef(path: ControlStateEncoder.pathString(path))
        }
    }

    // MARK: Parts

    /// Every number is pinned to 4 decimal places: a dump has to be readable by a human and
    /// comparable by a diff tool, and what apply writes back is that same rounded value, which is
    /// what makes `dump -> apply -> dump` stable byte for byte
    static func rounded(_ value: Double, _ digits: Int = 4) -> Double {
        let scale = pow(10.0, Double(digits))
        return (value * scale).rounded() / scale
    }

    static func rounded(_ value: CGFloat, _ digits: Int = 4) -> Double {
        rounded(Double(value), digits)
    }

    /// `/Users/danny/proj` -> `~/proj` (`--relocatable`)
    static func relocatable(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard path == home || path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }
}
