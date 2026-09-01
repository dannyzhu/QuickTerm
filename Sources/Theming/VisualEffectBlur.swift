import AppKit
import SwiftUI

/// 窗口内 backdrop 高斯模糊（磨砂玻璃）：只模糊自己身后的内容（壁纸层），
/// 盖在其上的终端文字不受影响。用于非激活 pane 背景（spec：磨砂区分焦点）。
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
