import AppKit
import GhosttyKit
import OSLog
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "dev.danny.quickterm",
        category: String(describing: AppDelegate.self)
    )

    private(set) var controller: MainWindowController!

    /// 引擎实例（GhosttyEmbed 层通过 NSApp.delegate 访问）
    var ghostty: Ghostty.App!
    let undoManager = UndoManager()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)

        // 配置链第 3 层：QuickTerm 覆盖文件（透明度等），必须先于引擎创建
        Ghostty.Config.quickTermOverlayPath = EngineOverlay.install()

        // 引擎：内部完成配置加载（含 ~/.config/ghostty/config）/ app_new；
        // ghostty_init 已在 main.swift 中先于 NSApplicationMain 调用
        ghostty = Ghostty.App()
        guard ghostty.readiness == .ready else {
            let alert = NSAlert()
            alert.messageText = "QuickTerm 引擎初始化失败"
            alert.informativeText = "libghostty 未能启动（readiness: \(ghostty.readiness)）。请检查 GhosttyKit 构建与资源包。"
            alert.runModal()
            NSApp.terminate(nil)
            return
        }

        controller = MainWindowController(ghostty: ghostty)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
