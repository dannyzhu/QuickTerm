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

    /// 多「屏幕」注册表：控制器的唯一强引用
    let screens = ScreenRegistry()
    var controllers: [MainWindowController] { screens.controllers }

    /// 进程级会话（配置 / 键位 / 系统状态 / 全屏 presentationOptions 账本）。
    /// `applicationDidFinishLaunching` 里建；建第一个屏幕之前必须已经加载完配置
    private(set) var session: AppSession!

    /// 动作落点：key 窗口的控制器，回退第一个屏幕。
    /// （历史上是唯一的主控制器；6 个测试文件按这个名字取夹具）
    var controller: MainWindowController! { screens.current }

    /// 引擎实例（GhosttyEmbed 层通过 NSApp.delegate 访问）
    var ghostty: Ghostty.App!
    private(set) var themeManager: ThemeManager!
    let undoManager = UndoManager()

    /// 扩展宿主聚合器（BrowserExtensionManager.host 是 weak，必须由这里强持有）
    private var extensionHost: AppBrowserExtensionHost?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // CLI / 冒烟：`open -a QuickTerm --args --open-browser [url]` 启动后开一个浏览器 pane
        if let i = CommandLine.arguments.firstIndex(of: "--open-browser") {
            let raw = CommandLine.arguments.dropFirst(i + 1).first
            // 延后解析：此时控制器已建、config.toml 的 browser-home/search 已写进 settings；
            // 裸域名 / 搜索词按地址栏规则解析
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let controller = self?.screens.primary else { return }
                let url = raw.flatMap { BrowserPaneView.settings.url(forInput: $0) } ?? BrowserPaneView.settings.homeURL
                controller.openBrowserPane(url: url, from: controller.focusedPane)
            }
        }
        NSApp.setActivationPolicy(.regular)

        // 配置链第 3 层：ThemeManager 在 init 中写入 overlay（主题配色 + 透明度），
        // 必须先于引擎创建，引擎首次加载即带主题
        Ghostty.Config.quickTermOverlayPath = EngineOverlay.url.path
        let themeManager = ThemeManager()
        self.themeManager = themeManager

        // 引擎：内部完成配置加载（含 ~/.config/ghostty/config）/ app_new；
        // ghostty_init 已在 main.swift 中先于 NSApplicationMain 调用
        ghostty = Ghostty.App()
        guard ghostty.readiness == .ready else {
            let alert = NSAlert()
            alert.messageText = L("window.engine.failed-title")
            alert.informativeText = L("window.engine.failed-detail", String(describing: ghostty.readiness))
            alert.runModal()
            NSApp.terminate(nil)
            return
        }

        // 主题热切换的 app 级那一半：引擎 reloadConfig 每次只做一次
        // （每个屏幕的 per-surface reload / 窗口外观由各自的控制器登记，见 MainWindowController.init）
        themeManager.addOverlayListener(token: self) { [weak self] in
            self?.ghostty.reloadConfig(soft: false)
        }

        // 浏览器扩展：pane 就是扩展眼里的"窗口"；宿主聚合所有屏幕
        let host = AppBrowserExtensionHost(registry: screens)
        extensionHost = host
        BrowserExtensionManager.shared.host = host

        // 进程级会话：配置在建窗口之前就位（控制器不再各自读盘 / 各自装 watcher）。
        // 顺序要紧：ThemeManager 与引擎必须已就绪（applyGlobalConfig 会写引擎 overlay 并触发一次热重载）
        // 第二实例（开发 / 冒烟）：用环境变量把存档与控制 socket 指到别处，
        // 这样跑一个 Debug 版不会去抢用户那个 QuickTerm 的 socket，也不会覆盖他的会话存档。
        // 两个都不设时就是正常的单实例行为（Application Support 里那一份）
        let environment = ProcessInfo.processInfo.environment
        // 配置文件也能指到别处：`[control] send-text` 这类开关只能从配置读，
        // 冒烟一个 Debug 版时绝不该去动用户真正的 ~/.config/quickterm/config.toml。
        // 必须在 loadInitialConfig 之前设好
        if let path = environment["QUICKTERM_CONFIG_FILE"], !path.isEmpty {
            ConfigStore.configURLOverride = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        }
        let session = AppSession(
            screens: screens, themeManager: themeManager,
            stateURL: environment["QUICKTERM_STATE_FILE"].flatMap {
                $0.isEmpty ? nil : URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath)
            },
            controlSocketPath: environment["QUICKTERM_CONTROL_SOCKET"].flatMap {
                $0.isEmpty ? nil : ($0 as NSString).expandingTildeInPath
            })
        self.session = session
        // 顺序是硬要求：先 `loadInitialConfig()`（顺带把控制 socket 绑起来），再复原。
        // 复原里建出来的每一个 pane 都要在 spawn 那一刻拿到 QUICKTERM_SOCKET / TOKEN /
        // PANE_TOKEN——晚绑一步就永远补不上了。见 `AppSession.applyGlobalConfig`
        session.loadInitialConfig()

        // 一键复原：存档里的每个屏幕（含显示器 / frame / 全屏）；没有存档就一个新屏幕
        restoreSession()
        session.installConfigWatcher()
        session.installScreenParametersObserver()
        // 配置已由控制器加载（browser-extensions 决定开关）：装好的扩展在这里异步加载。
        // 测试宿主里不加载（与 restoreState 同一策略）：用户装的扩展会跑进测试的 WebView，
        // 扩展工具条的用例也会跟着变红
        if !Self.isRunningTests {
            Task { @MainActor in await BrowserExtensionManager.shared.loadInstalled() }
        }
        MainMenu.install(delegate: self)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: config.toml 热重载（监听与全局部分归 AppSession，这里只留落点）

    /// 一次重载：`applyGlobalConfig` 只跑一次 + 每个屏幕各跑一次 `applyWindowConfig`
    @MainActor
    func applyConfigToAllScreens(_ settings: ConfigStore.Settings) {
        session?.apply(settings)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !Self.isRunningTests
    }

    /// 退出语义（用户 2026-09-04）：有打开的 pane → 确认；一个都没有 → 直接退出。
    /// 菜单 Cmd+Q 与引擎 quit 动作都经此处。
    static func shouldConfirmQuit(openPaneCount: Int) -> Bool { openPaneCount > 0 }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !Self.isRunningTests, !controllers.isEmpty else { return .terminateNow }
        for controller in controllers { controller.flushPendingCloses() }   // 淡出中的 pane 已经关了，不算"还开着"
        let open = screens.allPanes.count
        guard Self.shouldConfirmQuit(openPaneCount: open) else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = L("window.quit.title")
        alert.informativeText = Lp("window.quit.detail", count: open, open)
        alert.addButton(withTitle: L("window.button.quit"))
        alert.addButton(withTitle: L("window.button.cancel"))
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        session?.controlServer.stop()   // 退出时把 socket 摘掉，下次启动不必去清陈旧残留
        // spec §4.8 / v9 §3.4：退出时同步写一次（防抖那份可能还没到点）——
        // 布局、每个终端 pane 的目录、每个浏览器 pane 的标签页、窗口所在显示器与 frame
        session?.sessionStore.saveNow()
    }
}

// 拖放按 UUID 反查 surface（SurfaceView+Transferable 的 find(uuid:) 依赖此协议）
extension AppDelegate: Ghostty.Delegate {
    func ghosttySurface(id: UUID) -> PaneView? {
        for controller in controllers {
            if let pane = controller.allPanes.first(where: { $0.id == id }) { return pane }
        }
        return nil
    }
}
