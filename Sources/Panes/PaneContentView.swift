import SwiftUI

/// pane 内容按种类分发：终端 → Ghostty.SurfaceWrapper；浏览器 → BrowserPaneRepresentable（Phase C）
struct PaneContentView: View {
    let pane: PaneView
    let isSplit: Bool

    var body: some View {
        if let surface = pane as? Ghostty.SurfaceView {
            Ghostty.SurfaceWrapper(surfaceView: surface, isSplit: isSplit)
        } else {
            PaneHostView(pane: pane)
        }
    }
}

/// 把已存在的 PaneView 实例挂进 SwiftUI（实例由模型持有，重挂时不重建——页面状态不丢）
struct PaneHostView: NSViewRepresentable {
    let pane: PaneView

    func makeNSView(context: Context) -> PaneView { pane }
    func updateNSView(_ nsView: PaneView, context: Context) {}
}
