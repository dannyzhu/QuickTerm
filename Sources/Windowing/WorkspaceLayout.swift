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

    /// Cmd+L 的兜底转换：保 pane 保序（spec §4.2-bis）。
    /// 有损（列栈/列宽不可逆），所以 WorkspaceModel.toggleLayout 优先恢复记忆的布局。
    func toggled(columnFactor: Double = ScrollingStrip.defaultWidth) -> WorkspaceLayout {
        switch self {
        case .dwindle(let tree): .scrolling(ScrollingStrip.from(tree: tree, widthFactor: columnFactor))
        case .scrolling(let strip): .dwindle(strip.toTree())
        }
    }

    /// 两个布局包含完全相同的一组 pane（按对象身份，不看顺序/结构）
    func hasSamePanes(as other: WorkspaceLayout) -> Bool {
        Set(paneList.map(ObjectIdentifier.init)) == Set(other.paneList.map(ObjectIdentifier.init))
    }

    /// 名称（通知/调试）
    var name: String {
        switch self {
        case .dwindle: "dwindle"
        case .scrolling: "scrolling"
        }
    }
}
