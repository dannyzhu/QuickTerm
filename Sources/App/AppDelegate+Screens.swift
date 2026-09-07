import AppKit

/// 多「屏幕」的创建 / 放置 / 关闭 / 迁移，以及 Window 菜单的动作落点（spec v9 §1.1–§1.3）。
/// 「屏幕」= 一个窗口 + 一组自己的工作区；只能从菜单栏驱动（没有快捷键——⌘N 已被占用）。
extension AppDelegate {
    /// 新建一个屏幕。新屏幕的首个终端继承源窗口焦点 pane 的 cwd（与新建终端同规则）
    @discardableResult
    func newScreen(on screen: NSScreen? = nil, inheritingFrom pane: PaneView? = nil) -> MainWindowController {
        let index = screens.nextIndex()
        let controller = MainWindowController(
            ghostty: ghostty, session: session,
            screen: screen, index: index, restoring: !screens.didCreateFirstScreen,
            inheritedDirectory: pane?.workingDirectory)
        screens.add(controller)
        return controller
    }

    /// 关闭一个屏幕（有活跃 pane 时先确认）。返回是否真的关了。
    /// 关掉最后一个屏幕 → applicationShouldTerminateAfterLastWindowClosed 让程序退出
    @discardableResult
    func closeScreen(_ controller: MainWindowController) -> Bool {
        guard let window = controller.window else { return false }
        guard controller.confirmCloseScreen() else { return false }
        // 关掉最后一个屏幕 = 程序退出：先存档，因为 windowWillClose 的 teardown 会清空模型，
        // 之后 applicationWillTerminate 就没有布局可存了
        if !Self.isRunningTests, screens.controllers.count == 1 { controller.saveState() }
        window.close()   // → windowWillClose：拆监视器/观察者，下一轮 runloop 摘注册表
        return true
    }

    /// 把一个屏幕搬到指定显示器
    func moveScreen(_ controller: MainWindowController, to screen: NSScreen) {
        controller.move(to: screen)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    /// 窗口已经关闭：摘掉注册表里的强引用（由 windowWillClose 在下一轮 runloop 调用）
    func forgetScreen(_ controller: MainWindowController) {
        screens.remove(controller)
    }

    // MARK: Window 菜单动作（无快捷键）

    @objc func newScreenAction(_ sender: Any?) {
        newScreen(inheritingFrom: screens.current?.focusedPane)
    }

    @objc func newScreenOnDisplay(_ sender: NSMenuItem) {
        guard let screen = Self.screen(forRepresentedObject: sender.representedObject) else { return }
        newScreen(on: screen, inheritingFrom: screens.current?.focusedPane)
    }

    @objc func moveScreenToDisplay(_ sender: NSMenuItem) {
        guard let controller = screens.key ?? screens.primary,
              let screen = Self.screen(forRepresentedObject: sender.representedObject) else { return }
        moveScreen(controller, to: screen)
    }

    /// Spaces（虚拟桌面）无法用公开 API 指定，能诚实提供的只有「在所有桌面显示」
    @objc func toggleJoinAllSpaces(_ sender: NSMenuItem) {
        guard let controller = screens.key ?? screens.primary else { return }
        controller.joinsAllSpaces.toggle()
    }

    @objc func closeScreenAction(_ sender: Any?) {
        guard let controller = screens.key ?? screens.primary else { return }
        closeScreen(controller)
    }

    /// 菜单项里带的显示器标识（displayUUID 字符串——显示器配置一变 NSScreen 实例就换了，不能直接存实例）
    static func screen(forRepresentedObject object: Any?) -> NSScreen? {
        guard let uuid = object as? String else { return nil }
        return NSScreen.screens.first { $0.displayUUID?.uuidString == uuid }
    }
}

extension AppDelegate: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(moveScreenToDisplay(_:)), #selector(closeScreenAction(_:)):
            return screens.key != nil
        case #selector(toggleJoinAllSpaces(_:)):
            let controller = screens.key
            menuItem.state = controller?.joinsAllSpaces == true ? .on : .off
            return controller != nil
        default:
            return true
        }
    }
}

/// Window ▸「在显示器上新建屏幕 / 将此屏幕移到显示器」两个子菜单：显示器列表随插拔变化，
/// 每次打开都重建（representedObject 存 displayUUID 字符串，不存 NSScreen 实例）
final class DisplayMenuDelegate: NSObject, NSMenuDelegate {
    enum Mode {
        case newScreen
        case moveScreen
    }

    private let mode: Mode
    private weak var target: AppDelegate?

    init(mode: Mode, target: AppDelegate) {
        self.mode = mode
        self.target = target
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let current = target?.screens.current?.window?.screen
        let screens = NSScreen.screens
        guard !screens.isEmpty else {
            let item = menu.addItem(withTitle: "没有可用的显示器", action: nil, keyEquivalent: "")
            item.isEnabled = false
            return
        }
        for (i, screen) in screens.enumerated() {
            let isCurrent = screen === current
            var title = screen.localizedName
            if title.isEmpty { title = "显示器 \(i + 1)" }
            if isCurrent { title += "（当前）" }
            let action = mode == .newScreen
                ? #selector(AppDelegate.newScreenOnDisplay(_:))
                : #selector(AppDelegate.moveScreenToDisplay(_:))
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = target
            item.representedObject = screen.displayUUID?.uuidString
            if mode == .moveScreen, isCurrent {
                // 已经在这台显示器上：打勾且不可点
                item.state = .on
                item.action = nil
            }
            // displayUUID 取不到（极少数虚拟显示器）时条目无从落点，直接禁用
            if item.representedObject == nil, item.action != nil { item.action = nil }
        }
    }
}
