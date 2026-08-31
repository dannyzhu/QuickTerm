import SwiftUI

/// 单工作区状态（M2 扩展为多工作区数组）。AppKit 控制器是唯一写入方，SwiftUI 纯读。
final class WorkspaceModel: ObservableObject {
    @Published var tree: SplitTree<Ghostty.SurfaceView> = .init()
}

/// SwiftUI 根视图：底色 + 平铺树（gaps_out = 10，spec §1.1）。
/// M2 在 VStack 顶部加状态栏；M3 底层换连续壁纸。
struct RootView: View {
    @ObservedObject var model: WorkspaceModel
    let ghostty: Ghostty.App
    let action: (TerminalSplitOperation) -> Void

    var body: some View {
        ZStack {
            // M3 之前的固定底色：Tokyo Night background #1a1b26
            Color(red: 0x1a / 255.0, green: 0x1b / 255.0, blue: 0x26 / 255.0)
            TerminalSplitTreeView(tree: model.tree, action: action)
                .padding(10)
        }
        .ignoresSafeArea(.container, edges: .top)
        .environmentObject(ghostty)
    }
}
