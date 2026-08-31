import AppKit
import GhosttyKit
import OSLog
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "dev.danny.quickterm",
        category: String(describing: AppDelegate.self)
    )

    private var window: HiddenTitlebarWindow!
    private let model = WorkspaceModel()

    /// 引擎实例（GhosttyEmbed 层通过 NSApp.delegate 访问）
    var ghostty: Ghostty.App!
    let undoManager = UndoManager()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)

        // 引擎：内部完成配置加载（含 ~/.config/ghostty/config）/ app_new；
        // ghostty_init 已在 main.swift 中先于 NSApplicationMain 调用
        ghostty = Ghostty.App()
        guard ghostty.readiness == .ready, let app = ghostty.app else {
            let alert = NSAlert()
            alert.messageText = "QuickTerm 引擎初始化失败"
            alert.informativeText = "libghostty 未能启动（readiness: \(ghostty.readiness)）。请检查 GhosttyKit 构建与资源包。"
            alert.runModal()
            NSApp.terminate(nil)
            return
        }

        window = HiddenTitlebarWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1024, height: 720),
            styleMask: [],  // HiddenTitlebarWindow 内部固定样式
            backing: .buffered, defer: false)
        window.title = "QuickTerm"

        let surfaceView = Ghostty.SurfaceView(app, baseConfig: nil)
        model.tree = SplitTree(view: surfaceView)

        window.contentView = NSHostingView(rootView: RootView(
            model: model, ghostty: ghostty, action: { _ in }))
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(surfaceView)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
