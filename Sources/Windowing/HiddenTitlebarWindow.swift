import AppKit

/// 隐藏标题栏配方（源自 Ghostty HiddenTitlebarTerminalWindow 的做法，MIT；
/// QuickTerm 简化版：无原生 tab、无标题栏 accessory）。
/// 保留 `.titled` 以获得正常阴影/外框/状态恢复；`.fullSizeContentView` 让内容
/// 延伸到标题栏区域；标题与红绿灯隐藏。
class HiddenTitlebarWindow: TerminalWindow {
    override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask,
                  backing: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(
            contentRect: contentRect,
            styleMask: [.titled, .fullSizeContentView, .resizable, .closable, .miniaturizable],
            backing: backing, defer: flag)
        reapplyHiddenStyle()
    }

    // macOS 15 起设置 title 会重新显示标题栏元素，需要重刷样式
    override var title: String {
        didSet { reapplyHiddenStyle() }
    }

    private func reapplyHiddenStyle() {
        styleMask.insert(.fullSizeContentView)
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        [.closeButton, .miniaturizeButton, .zoomButton].forEach {
            standardWindowButton($0)?.isHidden = true
        }
        tabbingMode = .disallowed
    }
}
