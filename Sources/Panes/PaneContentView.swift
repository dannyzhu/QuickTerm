import SwiftUI

/// Dispatches pane content by kind: terminal -> Ghostty.SurfaceWrapper; browser ->
/// BrowserPaneRepresentable (Phase C).
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

/// Mounts an already-existing PaneView instance into SwiftUI. The model owns the instance, so a
/// remount never rebuilds it and the page state is not lost.
struct PaneHostView: NSViewRepresentable {
    let pane: PaneView

    func makeNSView(context: Context) -> PaneView { pane }
    func updateNSView(_ nsView: PaneView, context: Context) {}
}
