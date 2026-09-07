import AppKit

/// 进程级会话（spec v9 §2）：一个进程只该有一份的东西全归这里——
/// config.toml 的加载与**唯一**监听、共享的 `KeybindingMap`、唯一的 `SystemStatsService`、
/// 全局设置（文件管理器 / link-opener / 浏览器 pane 设置 / 扩展开关 / 主题与引擎 overlay），
/// 以及非原生全屏那份进程级 `NSApp.presentationOptions` 的归属账本。
///
/// 与 `ScreenRegistry` 分工（所以不合并成一个类）：注册表回答「有哪些屏幕、动作落在哪个屏幕」，
/// 本类回答「所有屏幕共用的那一份状态是什么」。两者生命周期一致但职责正交；
/// 注册表被 App 级的其它协作方（扩展宿主聚合器）单独持有，混进配置/全屏账本会把它们绑死。
///
/// 持有关系：AppDelegate → AppSession → ScreenRegistry → MainWindowController；
/// 控制器反向持有本对象必须是 `unowned`（见 `MainWindowController.session`），否则成环。
@MainActor
final class AppSession {
    let screens: ScreenRegistry
    let themeManager: ThemeManager
    /// 全进程唯一的系统状态轮询（2s Timer + NWPathMonitor + CoreAudio/IOKit）：
    /// 注入每个屏幕的 RootView。每屏一个的时代 N 个窗口就是 N 份轮询
    let stats = SystemStatsService()

    /// 会话存档（多屏幕 v5）：读盘 / 迁移 / 防抖写盘的唯一入口
    let sessionStore: SessionStore

    /// 最近一次生效的配置（新屏幕创建时直接拿它，不再各自读盘）
    private(set) var settings = ConfigStore.Settings()

    /// 共享键位表：控制器只读引用（`MainWindowController.keybindings` 是计算属性），
    /// 重载时这里换一份，所有屏幕立刻同步——绝不由控制器各自重建
    private(set) var keybindings = KeybindingMap()

    /// 全局设置（配置派生，与窗口无关）：控制器上的同名属性是转发到这里的计算属性
    var fileManagerCommand = FileManagerLaunch.defaultProgram
    /// 终端里 ⌘+点击的链接开在哪：browser-pane = 浏览器 pane；system = 系统默认浏览器
    var linkOpener = "browser-pane"

    /// `applyGlobalConfig` 的执行次数（测试计数桩：一次重载无论几个屏幕都只该 +1）
    private(set) var globalConfigApplyCount = 0

    /// 进程内唯一的 config.toml 监听
    private var configWatcher: ConfigWatcher?
    /// 内容去重（编辑器保存会连发多次文件系统事件）
    private var lastConfigContent: String?

    /// 当前处于非原生全屏的屏幕（按窗口引用计数的账本，见下方 MARK）
    private var fullscreenOwners = Set<ObjectIdentifier>()

    /// 显示器配置变化（插拔 / 唤醒 / 改分辨率）的防抖：一次插拔会连发好几条通知
    static let screenChangeDebounce: TimeInterval = 0.5
    private var screenParametersObserver: Any?
    private var pendingScreenReflow: DispatchWorkItem?

    init(screens: ScreenRegistry, themeManager: ThemeManager, stateURL: URL? = nil) {
        self.screens = screens
        self.themeManager = themeManager
        self.sessionStore = SessionStore(screens: screens, url: stateURL)
    }

    deinit {
        if let screenParametersObserver {
            NotificationCenter.default.removeObserver(screenParametersObserver)
        }
    }

    // MARK: 显示器热插拔（spec v9 §3.5）

    /// 装上进程内唯一的显示器变化监听
    func installScreenParametersObserver() {
        guard screenParametersObserver == nil else { return }
        screenParametersObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.scheduleScreenReflow()
        }
    }

    /// 防抖 0.5s 后把每个屏幕重新贴合它当前所在的显示器
    func scheduleScreenReflow() {
        pendingScreenReflow?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.reflowScreens() }
        pendingScreenReflow = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.screenChangeDebounce, execute: item)
    }

    /// 逐屏重新约束（目标显示器没了 → AppKit 已经把窗口挪到别处，按它当前所在屏收）+ 排一次存档
    func reflowScreens() {
        pendingScreenReflow = nil
        for controller in screens.controllers { controller.reflowForScreenChange() }
        sessionStore.scheduleSave()
    }

    // MARK: 配置链第 4 层（config.toml，spec §4.7）

    /// 启动时的首次加载：补全模板键 → 读盘 → 落全局设置。
    /// 必须在建第一个屏幕**之前**调用：控制器 init 直接用 `settings`（不再自己读盘），
    /// 而 `visibleColumns` / 工作区数在状态恢复前就得是最终值
    func loadInitialConfig() {
        ConfigStore.ensureTemplateKeys()   // 已有配置文件补全新增键（注释形式，幂等）
        apply(ConfigStore.load())
    }

    /// 装上进程内唯一的目录监听（编辑器原子替换也能捕获）
    func installConfigWatcher() {
        lastConfigContent = (try? String(contentsOf: ConfigStore.configURL, encoding: .utf8)) ?? ""
        configWatcher = ConfigWatcher(
            directory: ConfigStore.configURL.deletingLastPathComponent()
        ) { [weak self] in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self?.reloadConfigFile() }
        }
    }

    /// 文件内容真变了才重载（保存会连发多次事件），然后走一次 apply
    func reloadConfigFile() {
        let content = (try? String(contentsOf: ConfigStore.configURL, encoding: .utf8)) ?? ""
        guard content != lastConfigContent else { return }
        lastConfigContent = content
        apply(ConfigStore.parse(content))
    }

    /// 一次重载 = 全局部分做**一次** + 每个屏幕各做一次窗口部分。
    /// （单窗口时代每个控制器都重写一遍键位表 / 引擎 overlay / 浏览器全局设置，N 个屏幕就是 N 遍）
    func apply(_ settings: ConfigStore.Settings) {
        applyGlobalConfig(settings)
        for controller in screens.controllers { controller.applyWindowConfig(settings) }
    }

    /// 进程级那一半：键位表、浏览器 pane 全局设置、扩展开关、主题 / 引擎 overlay。
    /// 一次重载只跑一次——引擎 overlay 写盘会触发全屏幕热重载，做 N 遍就是 N 次闪烁
    func applyGlobalConfig(_ settings: ConfigStore.Settings) {
        globalConfigApplyCount += 1
        self.settings = settings
        keybindings = KeybindingMap(
            workspaceCount: settings.workspaces,
            overrides: settings.overrides,
            unbound: settings.unbound)
        fileManagerCommand = settings.fileManagerCommand
        linkOpener = settings.linkOpener
        BrowserPaneView.settings = .init(home: settings.browserHome, search: settings.browserSearch,
                                         userAgent: settings.browserUserAgent, inspectable: settings.browserInspectable,
                                         tabBar: settings.browserTabBar,
                                         tabWidth: settings.browserTabWidth, tabMinWidth: settings.browserTabMinWidth,
                                         downloadDirectory: settings.browserDownloadDir)
        BrowserExtensionManager.shared.isEnabled = settings.browserExtensions
        themeManager.updateFromConfig(
            passthrough: settings.ghosttyPassthrough,
            followEngine: settings.themeName == "ghostty",
            panePadding: settings.panePadding,
            paneOpacity: settings.paneOpacity,
            inactiveBlur: settings.inactiveBlur,
            activeOpacity: settings.activeOpacity,
            barOpacity: settings.barOpacity,
            dividerOpacity: settings.dividerOpacity,
            paneGap: settings.paneGap)
        if let name = settings.themeName, name != "ghostty",
           let theme = themeManager.themes.first(where: { $0.name == name }),
           theme != themeManager.current {
            themeManager.apply(theme)
        }
    }

    // MARK: 非原生全屏的进程级 presentationOptions（按窗口引用计数）

    /// 全屏要藏起来的两样（进程级：macOS 没有「只藏这台显示器的菜单栏」这种 API）
    private static let fullscreenOptions: [NSApplication.PresentationOptions.Element] =
        [.autoHideDock, .autoHideMenuBar]

    /// 有几个屏幕正处在非原生全屏
    var fullscreenScreenCount: Int { fullscreenOwners.count }

    /// 某个屏幕进入 / 退出非原生全屏。按窗口记账后再 acquire/release：
    /// 同一个窗口重复进入不会多拿，关屏幕时（`teardown`）也只还回它真拿过的那一份——
    /// 于是 A 退出全屏不会在 B 还全屏时把菜单栏放回来
    func setSimpleFullscreen(_ on: Bool, for controller: MainWindowController) {
        let id = ObjectIdentifier(controller)
        if on {
            guard fullscreenOwners.insert(id).inserted else { return }
            for option in Self.fullscreenOptions { NSApp.acquirePresentationOption(option) }
        } else {
            guard fullscreenOwners.remove(id) != nil else { return }
            for option in Self.fullscreenOptions { NSApp.releasePresentationOption(option) }
        }
    }

    /// key 窗口切换时重算：AppKit 会在窗口/激活状态变化时改写 presentationOptions，
    /// 以账本为准把它扳回来（账本空 = 一个屏幕都不在全屏 → 必须让出 Dock 与菜单栏）
    func refreshPresentationOptions() {
        var options = NSApp.presentationOptions
        for option in Self.fullscreenOptions {
            if fullscreenOwners.isEmpty { options.remove(option) } else { options.insert(option) }
        }
        guard options != NSApp.presentationOptions else { return }
        NSApp.presentationOptions = options
    }
}
