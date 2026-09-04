import SwiftUI

/// pane 内容按种类分发：终端 → Ghostty.SurfaceWrapper；浏览器 → BrowserPaneRepresentable（Phase C）
struct PaneContentView: View {
    let pane: PaneView
    let isSplit: Bool

    var body: some View {
        if let surface = pane as? Ghostty.SurfaceView {
            Ghostty.SurfaceWrapper(surfaceView: surface, isSplit: isSplit)
        } else {
            Color.clear
        }
    }
}
