import AppKit
import GhosttyKit
import OSLog
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// 作为 TEST_HOST 运行时隔离生命周期副作用：
    /// 不恢复/保存用户状态、空树不关窗、关窗不退出（宿主必须活到测试结束）
    static let isRunningTests =
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
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

        // 配置链第 3 层：ThemeManager 在 init 中写入 overlay（主题配色 + 透明度），
        // 必须先于引擎创建，引擎首次加载即带主题
        Ghostty.Config.quickTermOverlayPath = EngineOverlay.url.path
        let themeManager = ThemeManager()

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

        controller = MainWindowController(ghostty: ghostty, themeManager: themeManager)
        MainMenu.install(delegate: self)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !Self.isRunningTests
    }

    /// 退出语义（用户 2026-09-04）：有打开的 pane → 确认；一个都没有 → 直接退出。
    /// 菜单 Cmd+Q 与引擎 quit 动作都经此处。
    static func shouldConfirmQuit(openPaneCount: Int) -> Bool { openPaneCount > 0 }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !Self.isRunningTests, let controller else { return .terminateNow }
        controller.flushPendingCloses()   // 淡出中的 pane 已经关了，不算"还开着"
        let open = controller.model.allPanes.count
        guard Self.shouldConfirmQuit(openPaneCount: open) else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "退出 QuickTerm？"
        alert.informativeText = "还有 \(open) 个终端打开着，退出会结束其中的进程。布局与目录会保存，下次启动恢复。"
        alert.addButton(withTitle: "退出")
        alert.addButton(withTitle: "取消")
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        if !Self.isRunningTests {
            controller?.saveState()  // spec §4.8：退出保存布局与 cwd
        }
    }
}

// 拖放按 UUID 反查 surface（SurfaceView+Transferable 的 find(uuid:) 依赖此协议）
extension AppDelegate: Ghostty.Delegate {
    func ghosttySurface(id: UUID) -> PaneView? {
        controller?.paneList.first { $0.id == id }
    }
}
