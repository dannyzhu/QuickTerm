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

    /// 动作落点：key 窗口的控制器，回退第一个屏幕。
    /// （历史上是唯一的主控制器；6 个测试文件按这个名字取夹具）
    var controller: MainWindowController! { screens.current }

    /// 引擎实例（GhosttyEmbed 层通过 NSApp.delegate 访问）
    var ghostty: Ghostty.App!
    private(set) var themeManager: ThemeManager!
    let undoManager = UndoManager()

    /// 扩展宿主聚合器（BrowserExtensionManager.host 是 weak，必须由这里强持有）
    private var extensionHost: AppBrowserExtensionHost?
    /// 进程内唯一的 config.toml 监听（重载后 fan-out 到全部屏幕；Phase 2 上提到 AppSession）
    private var configWatcher: ConfigWatcher?
    private var lastConfigContent: String?

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
            alert.messageText = "QuickTerm 引擎初始化失败"
            alert.informativeText = "libghostty 未能启动（readiness: \(ghostty.readiness)）。请检查 GhosttyKit 构建与资源包。"
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

        newScreen()
        installConfigWatcher()
        // 配置已由控制器加载（browser-extensions 决定开关）：装好的扩展在这里异步加载。
        // 测试宿主里不加载（与 restoreState 同一策略）：用户装的扩展会跑进测试的 WebView，
        // 扩展工具条的用例也会跟着变红
        if !Self.isRunningTests {
            Task { @MainActor in await BrowserExtensionManager.shared.loadInstalled() }
        }
        MainMenu.install(delegate: self)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: config.toml 热重载（进程唯一 watcher → fan-out 到全部屏幕）

    private func installConfigWatcher() {
        lastConfigContent = (try? String(contentsOf: ConfigStore.configURL, encoding: .utf8)) ?? ""
        configWatcher = ConfigWatcher(
            directory: ConfigStore.configURL.deletingLastPathComponent()
        ) { [weak self] in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self?.reloadConfigFile() }
        }
    }

    /// 文件内容真变了才重载（编辑器保存会连发多次事件），然后广播给每个屏幕
    func reloadConfigFile() {
        let content = (try? String(contentsOf: ConfigStore.configURL, encoding: .utf8)) ?? ""
        guard content != lastConfigContent else { return }
        lastConfigContent = content
        applyConfigToAllScreens(ConfigStore.parse(content))
    }

    /// 重载后的 fan-out：一份 settings 落到每一个屏幕
    /// （Phase 2 拆成 applyGlobalConfig 只做一次 + 每屏 applyWindowConfig，整段上提到 AppSession）
    func applyConfigToAllScreens(_ settings: ConfigStore.Settings) {
        for controller in controllers { controller.applyConfig(settings) }
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
        alert.messageText = "退出 QuickTerm？"
        alert.informativeText = "还有 \(open) 个终端打开着，退出会结束其中的进程。布局与目录会保存，下次启动恢复。"
        alert.addButton(withTitle: "退出")
        alert.addButton(withTitle: "取消")
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        if !Self.isRunningTests {
            // Phase 1：存档仍是单窗口 v4（primary），行为与 1.5.x 一致；
            // 多窗口存档是 Phase 3 的 SessionStore
            screens.primary?.saveState()  // spec §4.8：退出保存布局与 cwd
        }
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
