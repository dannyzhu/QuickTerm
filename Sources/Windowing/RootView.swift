import SwiftUI

/// Multi-workspace state (spec §5.2 plus §4.2-bis: five by default, each with its own layout, and a
/// new workspace defaults to the scrolling infinite canvas). The AppKit controller is the only
/// writer; SwiftUI only reads.
final class WorkspaceModel: ObservableObject {
    static let workspaceCount = 5

    @Published var layouts: [WorkspaceLayout]
    /// Per-workspace floating layer (indexed in parallel with `layouts`; spec v7)
    @Published var floatings: [[FloatingPane]]
    /// Per-workspace name (indexed in parallel with `layouts`; nil = never named).
    ///
    /// The name belongs to the **slot**, not to the panes inside it: `workspace clear`, closing the
    /// last pane, and `spec apply --replace` all leave it alone - only renaming (or clearing the
    /// name) changes it.
    /// Every write goes through `setTitle(_:at:)`, which handles normalization and bounds
    /// checking.
    @Published var titles: [String?]
    /// The layout each workspace was last switched away from (used by Cmd+L to round-trip; not
    /// persisted)
    private var alternates: [WorkspaceLayout?] = []
    @Published var activeIndex: Int = 0
    @Published var barVisible = true

    init() {
        layouts = (0..<Self.workspaceCount).map { _ in .empty }
        floatings = Array(repeating: [], count: Self.workspaceCount)
        titles = Array(repeating: nil, count: Self.workspaceCount)
    }

    /// The active workspace's layout
    var layout: WorkspaceLayout {
        get { layouts[activeIndex] }
        set { layouts[activeIndex] = newValue }
    }

    /// The active workspace's floating layer
    var floating: [FloatingPane] {
        get { floatings[activeIndex] }
        set { floatings[activeIndex] = newValue }
    }

    /// Every pane across every workspace (used by theme reloads and to look a pane up by id)
    var allPanes: [PaneView] {
        layouts.flatMap(\.paneList)
            + floatings.flatMap { $0.map(\.pane) }
            + (scratchpadSurface.map { [$0] } ?? [])
    }

    var allEmpty: Bool {
        layouts.allSatisfy(\.isEmpty) && floatings.allSatisfy(\.isEmpty)
    }

    func switchTo(_ index: Int) {
        guard layouts.indices.contains(index) else { return }
        activeIndex = index
    }

    func isEmpty(_ index: Int) -> Bool {
        guard layouts.indices.contains(index) else { return true }
        return layouts[index].isEmpty && floatings[index].isEmpty
    }

    // MARK: Workspace names

    // The rules themselves - trimming, the printable-scalar test, the 200-character cap and what a
    // rename dialog does to a typed string - are **not** written here: they are `TitleRules`, one
    // copy shared with pane titles, the control plane and the spec validator. This model only
    // decides what a slot holds.

    /// The names for the row the status bar actually draws: **only the slots that exist**.
    /// `titles` is never trimmed when the count shrinks (the name belongs to the slot and has to
    /// still be there when the workspace count goes back up), so it has to be cut to `layouts`
    /// here - computing "does this fit" from the raw `titles` pays for pills that are never drawn,
    /// and the whole row falls back to plain numbers because of names nobody can see.
    var visibleTitles: [String?] { (0..<layouts.count).map { title(at: $0) } }

    /// The name of this slot. **A slot that does not exist never has a name** - the workspace count
    /// is hot-reloadable, so `titles` may still hold the entries from before it shrank (see
    /// `alignTitles`), but a workspace that does not exist must not turn up with a name in the
    /// status bar, in `state`, or in a spec.
    func title(at index: Int) -> String? {
        guard layouts.indices.contains(index), titles.indices.contains(index) else { return nil }
        return titles[index]
    }

    /// Name, rename or clear (nil, an empty string, or nothing but whitespace all clear it -
    /// `TitleRules.normalized`). Returns whether anything actually changed - that is what lets an
    /// idempotent command exit 7, and why the comparison happens on the **normalized** value: a
    /// name re-set with different padding is the same name.
    @discardableResult
    func setTitle(_ raw: String?, at index: Int) -> Bool {
        guard layouts.indices.contains(index) else { return false }
        alignTitles()
        let next = TitleRules.normalized(raw)
        guard titles[index] != next else { return false }
        titles[index] = next
        return true
    }

    /// Align with `layouts`. **Never trimmed when shrinking**: the name belongs to the slot, and
    /// lowering the workspace count and raising it again (one config hot reload is exactly such a
    /// shrink-and-grow) must not lose names. The extra entries are simply unreadable by anyone.
    private func alignTitles() {
        guard titles.count < layouts.count else { return }
        titles.append(contentsOf: Array(repeating: nil, count: layouts.count - titles.count))
    }

    /// Cmd+L: prefer restoring the other layout this workspace was last switched away from - as
    /// long as the set of panes is unchanged, the column stacks, column widths and order all come
    /// back exactly. The conversion is lossy (dwindle -> scrolling flattens a stack into separate
    /// columns, so 5 panes become 5 columns and overflow the viewport), so we only fall back to the
    /// pane- and order-preserving conversion when panes have been added or removed.
    func toggleLayout(columnFactor: Double = ScrollingStrip.defaultWidth) {
        if alternates.count != layouts.count {  // Realign after a state restore or a count change
            alternates = (0..<layouts.count).map { alternates.indices.contains($0) ? alternates[$0] : nil }
        }
        let current = layout
        let remembered = alternates[activeIndex]
        let next: WorkspaceLayout
        if let remembered, remembered.name != current.name, remembered.hasSamePanes(as: current) {
            next = remembered
        } else {
            next = current.toggled(columnFactor: columnFactor)
        }
        alternates[activeIndex] = current
        layout = next
    }

    /// **Absolute set**: switch any workspace, **including an inactive one**, to the named layout.
    /// `toggleLayout` only touches the active workspace and is a toggle - an agent cannot see
    /// state, so one retry undoes what it just did.
    /// The memory (`alternates`) is shared with the toggle: when the set of panes is unchanged the
    /// remembered layout is restored verbatim, otherwise we fall back to the lossy pane- and
    /// order-preserving conversion. Returns whether anything actually changed (already in the
    /// target layout = false).
    @discardableResult
    func setLayout(_ name: String, at index: Int,
                   columnFactor: Double = ScrollingStrip.defaultWidth) -> Bool {
        guard layouts.indices.contains(index), layouts[index].name != name else { return false }
        if alternates.count != layouts.count {
            alternates = (0..<layouts.count).map { alternates.indices.contains($0) ? alternates[$0] : nil }
        }
        let current = layouts[index]
        let remembered = alternates[index]
        let next: WorkspaceLayout
        if let remembered, remembered.name == name, remembered.hasSamePanes(as: current) {
            next = remembered
        } else {
            next = current.toggled(columnFactor: columnFactor)
        }
        // The conversion did not produce the target layout: do nothing at all.
        guard next.name == name else { return false }
        alternates[index] = current
        layouts[index] = next
        return true
    }

    /// What the control plane just did, flashed in the status bar. A `mutate` command being allowed
    /// to run silently rests on it being visible afterwards.
    @Published var controlFlash: ControlFlash?
    struct ControlFlash: Equatable, Identifiable {
        let id = UUID()
        var text: String
    }
    /// How long the flash stays up
    static let controlFlashDuration: TimeInterval = 2.5

    func showControlFlash(_ text: String) {
        let flash = ControlFlash(text: text)
        controlFlash = flash
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.controlFlashDuration) { [weak self] in
            // Another flash arrived meanwhile: let that one serve out its own duration.
            guard self?.controlFlash?.id == flash.id else { return }
            self?.controlFlash = nil
        }
    }

    /// config workspaces=N (1-10): growing appends empty workspaces; shrinking only drops slots
    /// that are entirely empty (otherwise we keep everything up to the last non-empty one).
    func setWorkspaceCount(_ n: Int) {
        defer { alignTitles() }
        let target = min(max(n, 1), 10)
        if target > layouts.count {
            layouts.append(contentsOf: (layouts.count..<target).map { _ in WorkspaceLayout.empty })
            floatings.append(contentsOf: Array(repeating: [], count: target - floatings.count))
        } else if target < layouts.count {
            let lastNonEmpty = (0..<layouts.count).last { !isEmpty($0) }.map { $0 + 1 } ?? 0
            let safeTarget = max(target, lastNonEmpty)
            layouts.removeLast(layouts.count - safeTarget)
            floatings.removeLast(floatings.count - safeTarget)
        }
        activeIndex = min(activeIndex, layouts.count - 1)
    }

    // UI state of the overlay panels (keyboard navigation is driven by the controller's monitor)
    @Published var activePanel: OverlayPanel?
    @Published var panelSelection: Int = 0

    // Scratchpad (spec §4.1: a floating terminal shared across workspaces)
    @Published var scratchpadVisible = false
    @Published var scratchpadSurface: Ghostty.SurfaceView?

    /// The current binding for "new terminal" (shown in the empty-workspace hint; the controller
    /// writes it once the keybinding table is built)
    @Published var newTerminalCombo: String = "Cmd+Return"
    /// The pane dwindle has just split off (a local animation: the original pane shrinks to its
    /// ratio while the new one fades in; cleared once the animation ends)
    @Published var appearingPane: UUID?
    /// Panes currently fading out. They are still in the layout: the view layer plays the collapse
    /// and fade, and only once the animation ends does the controller actually remove them.
    @Published var closingPanes: Set<UUID> = []

    // Visible columns per screen (a mirror for the menu to display)
    @Published var visibleColumnsDisplay: Int =
        UserDefaults.standard.object(forKey: "quickterm.visibleColumns") as? Int ?? 2

    /// Whether every scrolling workspace already has this column factor (so we can skip a pointless
    /// relayout)
    func layoutsMatch(factor: Double) -> Bool {
        layouts.allSatisfy { layout in
            guard case .scrolling(let strip) = layout else { return true }
            return strip.columns.allSatisfy { abs($0.widthFactor - factor) < 0.001 }
        }
    }

    // The Cmd+K cheat sheet data (the controller fills it from the currently effective mapping when
    // the panel opens)
    @Published var keybindingRows: [(combo: String, action: WMAction)] = []

    // Two-finger horizontal panning on the scrolling canvas (an incidental feature): the
    // controller's scroll-wheel monitor posts it and the view consumes it.
    @Published var stripPan: StripPanEvent?
    struct StripPanEvent: Equatable {
        var delta: CGFloat
        var ended: Bool
        var serial: Int
    }
}

struct RootView: View {
    @ObservedObject var model: WorkspaceModel
    @EnvironmentObject var theme: ThemeManager
    // Installed on the root view by MainWindowController; reading it here is what re-renders
    // the empty-workspace hint when the language changes.
    @EnvironmentObject private var i18n: Localization
    let ghostty: Ghostty.App
    let stats: SystemStatsService
    let action: (TerminalSplitOperation) -> Void
    let onScrollingDrop: (PaneView, PaneView, TerminalSplitDropZone) -> Void
    let onSelectWorkspace: (Int) -> Void
    /// Right-click on a workspace pill: name or rename it
    let onRenameWorkspace: (Int) -> Void
    let onPanelChoose: (Int) -> Void

    var body: some View {
        ZStack {
            // The continuous wallpaper layer (spec §3.2) is promoted to the whole-window
            // background so it extends behind the status bar - only then does the translucent
            // status bar (whose alpha comes from the same source as pane-opacity) really show the
            // wallpaper through.
            theme.background
            if let url = theme.currentBackgroundURL {
                WallpaperThumb(url: url).id(url)
            }
            content
        }
        .background(theme.background)
        .ignoresSafeArea(.container, edges: .top)
        .environmentObject(ghostty)
    }

    private var content: some View {
        VStack(spacing: 0) {
            if model.barVisible {
                StatusBarView(
                    model: model, stats: stats,
                    onSelectWorkspace: onSelectWorkspace,
                    onRenameWorkspace: onRenameWorkspace,
                    onToggleMute: { [weak stats] in stats?.toggleMute() })
            }
            ZStack {
                switch model.layout {
                case .dwindle(let tree):
                    TerminalSplitTreeView(tree: tree, action: action, appearingPane: model.appearingPane,
                                          closingPanes: model.closingPanes)
                        // Outer margin matches the inter-pane gap
                        .padding(theme.gapsEnabled ? theme.paneGap : 0)
                case .scrolling(let strip):
                    ScrollingStripView(
                        strip: strip,
                        workspaceIndex: model.activeIndex,
                        pan: model.stripPan,
                        onDrop: onScrollingDrop,
                        closingPanes: model.closingPanes)
                        // Outer margin matches the inter-pane gap
                        .padding(theme.gapsEnabled ? theme.paneGap : 0)
                }

                // Empty workspace: the window stays after the last pane is closed, so tell the
                // user how to open a new terminal.
                if model.layout.isEmpty && model.floating.isEmpty {
                    VStack(spacing: 6) {
                        Text(i18n("window.empty.new-terminal", model.newTerminalCombo))
                        Text(i18n("window.empty.quit")).opacity(0.6)
                    }
                    .font(.custom("Monaco", size: 14))
                    .foregroundStyle(theme.foreground.opacity(0.55))
                    .allowsHitTesting(false)
                }

                // The floating layer (spec v7): hovers above the tiled one, array order = z order
                GeometryReader { geo in
                    ForEach(model.floating) { fp in
                        ScrollingPaneCell(surfaceView: fp.pane, onDrop: { _, _, _ in },
                                          floating: true,
                                          closing: model.closingPanes.contains(fp.id))
                            .frame(width: fp.rect.width * geo.size.width,
                                   height: fp.rect.height * geo.size.height)
                            .position(x: (fp.rect.origin.x + fp.rect.width / 2) * geo.size.width,
                                      y: (fp.rect.origin.y + fp.rect.height / 2) * geo.size.height)
                            .shadow(color: .black.opacity(0.45), radius: 18, y: 8)
                    }
                }
                .allowsHitTesting(!model.floating.isEmpty)

                if model.scratchpadVisible, let scratch = model.scratchpadSurface {
                    Color.black.opacity(0.2)
                        .onTapGesture { model.scratchpadVisible = false }
                    GeometryReader { geo in
                        Ghostty.SurfaceWrapper(surfaceView: scratch)
                            .frame(width: geo.size.width * 0.7, height: geo.size.height * 0.6)
                            .border(theme.accent, width: 2)
                            .position(x: geo.size.width / 2, y: geo.size.height / 2)
                    }
                }

                if model.activePanel != nil {
                    Color.black.opacity(0.25).onTapGesture { model.activePanel = nil }
                    OverlayPanelView(model: model, onChoose: onPanelChoose)
                        .padding(40)
                }
            }
        }
    }
}
