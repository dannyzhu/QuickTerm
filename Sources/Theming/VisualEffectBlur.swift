import AppKit
import SwiftUI

/// Within-window backdrop blur (frosted glass): it blurs only what is behind the view (the
/// wallpaper layer), so the terminal text drawn on top of it stays sharp. Used for the
/// background of inactive panes (the spec distinguishes focus by frosting).
struct VisualEffectBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .withinWindow
        view.material = .hudWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
