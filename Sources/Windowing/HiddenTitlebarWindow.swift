import AppKit

/// Hidden-titlebar recipe (lifted from Ghostty's HiddenTitlebarTerminalWindow, MIT; this is the
/// simplified QuickTerm version: no native tabs, no titlebar accessory).
/// Keep `.titled` so the window still gets the normal shadow / frame / state restoration;
/// `.fullSizeContentView` lets the content extend into the titlebar area; the title and the traffic
/// lights are hidden.
class HiddenTitlebarWindow: TerminalWindow {
    override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask,
                  backing: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(
            contentRect: contentRect,
            styleMask: [.titled, .fullSizeContentView, .resizable, .closable, .miniaturizable],
            backing: backing, defer: flag)
        reapplyHiddenStyle()
    }

    // As of macOS 15, setting `title` brings the titlebar elements back, so the style has to be
    // reapplied every time.
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
