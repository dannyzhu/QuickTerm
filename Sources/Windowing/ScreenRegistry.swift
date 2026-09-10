import AppKit

/// 多「屏幕」注册表（spec v9 §1）：进程内所有 `MainWindowController` 的**唯一强引用**。
/// 一个「屏幕」= 一个窗口 + 一组自己的工作区 + 自己的 Scratchpad / 浮动层 / 面板；
/// 进程级只留一份的东西（引擎、ThemeManager、配置、扩展管理器）不在这里。
///
/// 路由约定：菜单动作与 App 级回调一律走 `current`（key 窗口的控制器，回退第一个），
/// 只有明确"主窗口语义"的路径（CLI `--open-browser`、退出时存档）才用 `primary`。
final class ScreenRegistry {
    private(set) var controllers: [MainWindowController] = []
    /// 进程内是否已经建过第一个屏幕（存档恢复归 `SessionStore`，这里只记录事实）
    private(set) var didCreateFirstScreen = false

    /// 第一个屏幕（标题恒为 `QuickTerm`；存档 / CLI 的落点）
    var primary: MainWindowController? { controllers.first }

    /// key 窗口**自己**的控制器（key 是 sheet / 面板 / 没有 key 窗口时为 nil）。
    /// 「关闭屏幕 / 移到显示器」等破坏性菜单项按它来 validate：sheet 挂着时宁可禁用
    var key: MainWindowController? {
        NSApp.keyWindow?.windowController as? MainWindowController
    }

    /// 动作的默认落点：key 窗口的控制器，回退第一个。
    /// key 是 sheet（JS 对话框、文件选择器）或弹出层（下载 popover）时它自己没有 windowController，
    /// 沿 sheetParent / parent 找回宿主窗口——否则菜单动作会静默落到第一个屏幕上去
    var current: MainWindowController? {
        guard let keyWindow = NSApp.keyWindow else { return primary }
        var window: NSWindow? = keyWindow
        while let cur = window {
            if let controller = cur.windowController as? MainWindowController { return controller }
            window = cur.sheetParent ?? cur.parent
        }
        // sheet 期间 main 窗口仍是宿主窗口
        if let controller = NSApp.mainWindow?.windowController as? MainWindowController { return controller }
        return primary
    }

    /// 最近一次成为 key 的窗口身份（`windowDidBecomeKey` 记录）。
    /// 控制面（IPC）专用：agent 从 Terminal.app / 后台任务驱动时 `NSApp.keyWindow` 是 nil，
    /// `current` 会静默退回第一个屏幕——每条命令都打在 1 号屏上，而且**本地测试永远复现不出来**
    /// （本地测的时候 QuickTerm 总是最前台的）。有了它才能诚实回答"应用不在前台时的当前屏幕"
    private(set) var lastKeyWindowID: UUID?

    func recordKeyWindow(_ controller: MainWindowController) {
        lastKeyWindowID = controller.windowID
    }

    func controller(id: UUID) -> MainWindowController? {
        controllers.first { $0.windowID == id }
    }

    /// 1 起的屏幕序号（= 窗口标题里的数字）
    func controller(screenNumber: Int) -> MainWindowController? {
        controllers.first { $0.screenIndex + 1 == screenNumber }
    }

    /// 控制面的"当前屏幕"（与菜单动作的 `current` 刻意不同）：
    /// 只有应用真的在前台时才认 key 窗口，否则用最近一次 key 的那一块，最后才退回 primary。
    /// 顺序见 docs：显式 -t → 调用方所在 pane → 本属性 → primary
    var controlCurrent: MainWindowController? {
        if NSApp.isActive, let key = current { return key }
        if let id = lastKeyWindowID, let controller = controller(id: id) { return controller }
        return primary
    }

    /// 当前屏幕优先的遍历顺序（扩展宿主聚合用）
    var orderedByKeyFirst: [MainWindowController] {
        guard let current else { return controllers }
        return [current] + controllers.filter { $0 !== current }
    }

    /// 全部屏幕的全部 pane（拖放按 UUID 反查、退出确认计数）
    var allPanes: [PaneView] { controllers.flatMap(\.allPanes) }

    /// 序号复用最小空位：0 → 标题 `QuickTerm`，其后 `QuickTerm 2`…
    /// （关掉 2 号再新建仍叫 `QuickTerm 2`，窗口菜单里不会越编越大）
    func nextIndex() -> Int {
        let used = Set(controllers.map(\.screenIndex))
        var i = 0
        while used.contains(i) { i += 1 }
        return i
    }

    func add(_ controller: MainWindowController) {
        guard !controllers.contains(where: { $0 === controller }) else { return }
        controllers.append(controller)
        didCreateFirstScreen = true
        ControlEventBus.noteChange()   // screen.opened
    }

    func remove(_ controller: MainWindowController) {
        controllers.removeAll { $0 === controller }
        ControlEventBus.noteChange()   // screen.closed
    }

    /// 屏幕标题：第一个必须恰好是 `QuickTerm`（EngineSmokeTests 按标题找窗口）
    static func title(forIndex index: Int) -> String {
        index == 0 ? "QuickTerm" : "QuickTerm \(index + 1)"
    }
}

/// App 级浏览器扩展宿主：把所有屏幕的浏览器 pane 聚合成扩展眼里的"窗口集合"。
/// 单 weak 指针时代只有最后创建的窗口对扩展可见（BrowserExtensionManager.host 是 weak，
/// 所以 AppDelegate 必须强持有本对象）。协议签名不变——测试里的桩不受影响。
final class AppBrowserExtensionHost: BrowserExtensionHost {
    private let registry: ScreenRegistry

    init(registry: ScreenRegistry) {
        self.registry = registry
    }

    var browserPanes: [BrowserPaneView] {
        registry.orderedByKeyFirst.flatMap(\.browserPanes)
    }

    /// 取 key 窗口的（spec v9 §1.4）：先它的 first responder，再它自己最近激活的。
    /// 非 key 窗口的 first responder 只是残留焦点（收不到键盘事件），不能拿来当"焦点窗口"——
    /// 否则 key 屏幕焦点在终端上时，扩展会把选项页 / 新标签开到另一台显示器上去。
    /// key 屏幕一个浏览器 pane 都没有时才退回全局最近激活的那个
    var focusedBrowserPane: BrowserPaneView? {
        if let pane = registry.current?.focusedBrowserPane { return pane }
        return registry.controllers.compactMap { $0.mostRecentBrowserPaneAnywhere() }
            .max { $0.lastActivatedAt < $1.lastActivatedAt }
    }

    /// 扩展的 windows.create：开在 key 窗口（回退第一个屏幕）
    @discardableResult
    func openBrowserWindow(url: URL?) -> BrowserPaneView? {
        registry.current?.openBrowserWindow(url: url)
    }
}
