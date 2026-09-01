import AppKit

/// 每工作区的布局（spec §4.2-bis v5）：scrolling 无限画布（默认）或 dwindle 平铺。
enum WorkspaceLayout: Codable {
    case dwindle(SplitTree<Ghostty.SurfaceView>)
    case scrolling(ScrollingStrip)

    /// 新工作区默认：scrolling（v5 用户确认）
    static var empty: WorkspaceLayout { .scrolling(ScrollingStrip()) }

    var isEmpty: Bool {
        switch self {
        case .dwindle(let tree): tree.isEmpty
        case .scrolling(let strip): strip.isEmpty
        }
    }

    var paneList: [Ghostty.SurfaceView] {
        switch self {
        case .dwindle(let tree): tree.root?.leaves() ?? []
        case .scrolling(let strip): strip.paneList
        }
    }

    /// Cmd+L：布局互转，保 pane 保序（spec §4.2-bis）
    func toggled() -> WorkspaceLayout {
        switch self {
        case .dwindle(let tree): .scrolling(ScrollingStrip.from(tree: tree))
        case .scrolling(let strip): .dwindle(strip.toTree())
        }
    }

    /// 名称（通知/调试）
    var name: String {
        switch self {
        case .dwindle: "dwindle"
        case .scrolling: "scrolling"
        }
    }
}
