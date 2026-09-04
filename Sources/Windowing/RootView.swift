import SwiftUI

/// 多工作区状态（spec §5.2 + §4.2-bis：默认 5 个、每工作区独立布局，
/// 新工作区默认 scrolling 无限画布）。AppKit 控制器是唯一写入方，SwiftUI 纯读。
final class WorkspaceModel: ObservableObject {
    static let workspaceCount = 5

    @Published var layouts: [WorkspaceLayout]
    /// 每工作区的浮动层（与 layouts 平行索引；spec v7）
    @Published var floatings: [[FloatingPane]]
    /// 每工作区上一次离开的布局（Cmd+L 往返恢复用；不持久化）
    private var alternates: [WorkspaceLayout?] = []
    @Published var activeIndex: Int = 0
    @Published var barVisible = true

    init() {
        layouts = (0..<Self.workspaceCount).map { _ in .empty }
        floatings = Array(repeating: [], count: Self.workspaceCount)
    }

    /// 活动工作区布局
    var layout: WorkspaceLayout {
        get { layouts[activeIndex] }
        set { layouts[activeIndex] = newValue }
    }

    /// 活动工作区浮动层
    var floating: [FloatingPane] {
        get { floatings[activeIndex] }
        set { floatings[activeIndex] = newValue }
    }

    /// 全部工作区的所有 pane（主题重载/按 id 反查用）
    var allPanes: [Ghostty.SurfaceView] {
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

    /// Cmd+L：优先恢复该工作区上次离开的另一种布局——只要 pane 集合没变，
    /// 列栈/列宽/顺序原样回来（转换是有损的：dwindle→scrolling 会把叠栈摊成独立列，
    /// 5 个 pane 变 5 列就溢出视口）；pane 有增减时才退回保 pane 保序的转换。
    func toggleLayout(columnFactor: Double = ScrollingStrip.defaultWidth) {
        if alternates.count != layouts.count {  // 状态恢复/扩缩容后对齐
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

    /// config workspaces=N（1–10）：扩容补空；缩容仅当被裁的全空（否则保留至最后非空）
    func setWorkspaceCount(_ n: Int) {
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

    // 浮动面板 UI 状态（键盘导航由控制器监视器驱动）
    @Published var activePanel: OverlayPanel?
    @Published var panelSelection: Int = 0

    // Scratchpad（spec §4.1：跨工作区浮动终端）
    @Published var scratchpadVisible = false
    @Published var scratchpadSurface: Ghostty.SurfaceView?

    /// 新建终端的当前绑定（空工作区提示用；控制器在键位表构建后写入）
    @Published var newTerminalCombo: String = "Cmd+Return"
    /// dwindle 刚分裂出的新 pane（局部动效：原 pane 收缩到 ratio、新 pane 渐显；动画结束后清空）
    @Published var appearingPane: UUID?

    // 每屏可见列数（菜单显示用镜像）
    @Published var visibleColumnsDisplay: Int =
        UserDefaults.standard.object(forKey: "quickterm.visibleColumns") as? Int ?? 2

    /// 全部 scrolling 工作区的列因子是否已等于给定值（避免无谓重排）
    func layoutsMatch(factor: Double) -> Bool {
        layouts.allSatisfy { layout in
            guard case .scrolling(let strip) = layout else { return true }
            return strip.columns.allSatisfy { abs($0.widthFactor - factor) < 0.001 }
        }
    }

    // Cmd+K 速查数据（打开面板时由控制器按当前生效映射填充）
    @Published var keybindingRows: [(combo: String, action: WMAction)] = []

    // scrolling 画布的双指横滑（附带项）：控制器滚轮监视器投递，视图消费
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
    let ghostty: Ghostty.App
    let stats: SystemStatsService
    let action: (TerminalSplitOperation) -> Void
    let onScrollingDrop: (Ghostty.SurfaceView, Ghostty.SurfaceView, TerminalSplitDropZone) -> Void
    let onSelectWorkspace: (Int) -> Void
    let onPanelChoose: (Int) -> Void

    var body: some View {
        ZStack {
            // 连续壁纸层（spec §3.2）升为整窗背景：延伸到状态条身后，
            // 半透明状态条（与 pane-opacity 同源）才能真正透出壁纸。
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
                    onToggleMute: { [weak stats] in stats?.toggleMute() })
            }
            ZStack {
                switch model.layout {
                case .dwindle(let tree):
                    TerminalSplitTreeView(tree: tree, action: action, appearingPane: model.appearingPane)
                        .padding(theme.gapsEnabled ? theme.dwindleGap : 0)   // 外圈与 pane 留白同值
                case .scrolling(let strip):
                    ScrollingStripView(
                        strip: strip,
                        workspaceIndex: model.activeIndex,
                        pan: model.stripPan,
                        onDrop: onScrollingDrop)
                        .padding(theme.gapsEnabled ? 5 : 0)
                }

                // 空工作区：最后一个 pane 关掉后窗口保留，提示怎么开新终端
                if model.layout.isEmpty && model.floating.isEmpty {
                    VStack(spacing: 6) {
                        Text("\(model.newTerminalCombo)  新建终端")
                        Text("Cmd+Q  退出").opacity(0.6)
                    }
                    .font(.custom("Monaco", size: 14))
                    .foregroundStyle(theme.foreground.opacity(0.55))
                    .allowsHitTesting(false)
                }

                // 浮动层（spec v7）：悬浮于平铺之上；数组序 = z 序
                GeometryReader { geo in
                    ForEach(model.floating) { fp in
                        ScrollingPaneCell(surfaceView: fp.pane, onDrop: { _, _, _ in },
                                          floating: true)
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
