import SwiftUI

/// 多工作区状态（spec §5.2：默认 5 个，值语义切换 = 瞬时无动画）。
/// AppKit 控制器是唯一写入方，SwiftUI 纯读。
final class WorkspaceModel: ObservableObject {
    static let workspaceCount = 5

    @Published var trees: [SplitTree<Ghostty.SurfaceView>]
    @Published var activeIndex: Int = 0
    @Published var barVisible = true

    init() {
        trees = Array(repeating: SplitTree<Ghostty.SurfaceView>(), count: Self.workspaceCount)
    }

    /// 活动工作区的树（M1 全部调用点经此代理，无需改动）
    var tree: SplitTree<Ghostty.SurfaceView> {
        get { trees[activeIndex] }
        set { trees[activeIndex] = newValue }
    }

    func switchTo(_ index: Int) {
        guard trees.indices.contains(index) else { return }
        activeIndex = index
    }

    func isEmpty(_ index: Int) -> Bool {
        trees.indices.contains(index) ? trees[index].isEmpty : true
    }

    // 浮动面板 UI 状态（键盘导航由控制器监视器驱动）
    @Published var activePanel: OverlayPanel?
    @Published var panelSelection: Int = 0
}

/// SwiftUI 根视图：底色 + 平铺树（gaps_out = 10，spec §1.1）。
/// M2 在 VStack 顶部加状态栏；M3 底层换连续壁纸。
struct RootView: View {
    @ObservedObject var model: WorkspaceModel
    @EnvironmentObject var theme: ThemeManager
    let ghostty: Ghostty.App
    let stats: SystemStatsService
    let action: (TerminalSplitOperation) -> Void
    let onSelectWorkspace: (Int) -> Void
    let onPanelChoose: (Int) -> Void

    var body: some View {
        VStack(spacing: 0) {
            if model.barVisible {
                StatusBarView(
                    model: model, stats: stats,
                    onSelectWorkspace: onSelectWorkspace,
                    onToggleMute: { [weak stats] in stats?.toggleMute() })
            }
            ZStack {
                // 连续壁纸层（spec §3.2）：一张图横跨所有 pane，透过微透明表面与 gaps 露出
                theme.background
                if let url = theme.currentBackgroundURL {
                    WallpaperThumb(url: url).id(url)
                }
                TerminalSplitTreeView(tree: model.tree, action: action)
                    .padding(theme.gapsEnabled ? 10 : 0)

                if model.activePanel != nil {
                    Color.black.opacity(0.25).onTapGesture { model.activePanel = nil }
                    OverlayPanelView(model: model, onChoose: onPanelChoose)
                        .padding(40)
                }
            }
        }
        .background(theme.background)
        .ignoresSafeArea(.container, edges: .top)
        .environmentObject(ghostty)
    }
}
