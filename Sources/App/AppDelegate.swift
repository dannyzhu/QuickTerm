import AppKit
import GhosttyKit
import OSLog

final class AppDelegate: NSObject, NSApplicationDelegate {
    static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "dev.danny.quickterm",
        category: String(describing: AppDelegate.self)
    )

    private var window: NSWindow!
    private var surfaceView: Ghostty.SurfaceView!

    /// 引擎实例（GhosttyEmbed 层通过 NSApp.delegate 访问）
    var ghostty: Ghostty.App!
    let undoManager = UndoManager()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)

        // 引擎：内部完成 ghostty_init / 配置加载（含 ~/.config/ghostty/config）/ app_new
        ghostty = Ghostty.App()
        guard ghostty.readiness == .ready, let app = ghostty.app else {
            let alert = NSAlert()
            alert.messageText = "QuickTerm 引擎初始化失败"
            alert.informativeText = "libghostty 未能启动（readiness: \(ghostty.readiness)）。请检查 GhosttyKit 构建与资源包。"
            alert.runModal()
            NSApp.terminate(nil)
            return
        }

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1024, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "QuickTerm"

        surfaceView = Ghostty.SurfaceView(app, baseConfig: nil)
        window.contentView = surfaceView
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(surfaceView)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
