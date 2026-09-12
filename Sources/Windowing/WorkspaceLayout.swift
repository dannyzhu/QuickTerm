import AppKit

/// Per-workspace layout (spec §4.2-bis v5): either a scrolling infinite canvas (the default) or
/// dwindle tiling.
enum WorkspaceLayout: Codable {
    case dwindle(SplitTree<PaneView>)
    case scrolling(ScrollingStrip)

    /// Default for a new workspace: scrolling (confirmed with the user in v5)
    static var empty: WorkspaceLayout { .scrolling(ScrollingStrip()) }

    var isEmpty: Bool {
        switch self {
        case .dwindle(let tree): tree.isEmpty
        case .scrolling(let strip): strip.isEmpty
        }
    }

    var paneList: [PaneView] {
        switch self {
        case .dwindle(let tree): tree.root?.leaves() ?? []
        case .scrolling(let strip): strip.paneList
        }
    }

    /// The fallback conversion behind Cmd+L: every pane survives, in the same order
    /// (spec §4.2-bis).
    /// It is lossy - column stacking and column widths cannot be reconstructed - which is why
    /// WorkspaceModel.toggleLayout prefers restoring the remembered layout instead.
    func toggled(columnFactor: Double = ScrollingStrip.defaultWidth) -> WorkspaceLayout {
        switch self {
        case .dwindle(let tree): .scrolling(ScrollingStrip.from(tree: tree, widthFactor: columnFactor))
        case .scrolling(let strip): .dwindle(strip.toTree())
        }
    }

    /// Whether the two layouts hold exactly the same set of panes (by object identity; order and
    /// structure are ignored)
    func hasSamePanes(as other: WorkspaceLayout) -> Bool {
        Set(paneList.map(ObjectIdentifier.init)) == Set(other.paneList.map(ObjectIdentifier.init))
    }

    /// Name (for notifications and debugging)
    var name: String {
        switch self {
        case .dwindle: "dwindle"
        case .scrolling: "scrolling"
        }
    }
}
