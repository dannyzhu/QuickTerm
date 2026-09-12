import AppKit

/// 程序化主菜单：macOS 惯例条目 + WM 动作的可见快捷键注册表。
/// 实际按键由 MainWindowController 的局部监视器先行消费；菜单点击走这里的 action。
enum MainMenu {
    /// Rebuild the whole main menu when the language changes. An NSMenuItem title is a
    /// **value**, not a binding: once installed, a menu keeps showing the old language until
    /// something rebuilds it. The observer lives here rather than in AppDelegate — whoever
    /// builds the menu owns keeping it in the current language.
    private static var languageObserver: Any?
    /// The delegate of the last install, reused to rebuild on a language change.
    private static weak var installedDelegate: AppDelegate?

    static func install(delegate: AppDelegate) {
        installedDelegate = delegate
        if languageObserver == nil {
            languageObserver = NotificationCenter.default.addObserver(
                forName: Localization.didChangeNotification, object: nil, queue: .main
            ) { _ in
                guard let delegate = installedDelegate else { return }
                install(delegate: delegate)
            }
        }
        // The two display submenu delegates are re-registered on every rebuild; the old ones
        // must not pile up.
        displayDelegates.removeAll()

        let main = NSMenu()

        // App 菜单
        let appItem = main.addItem(withTitle: "QuickTerm", action: nil, keyEquivalent: "")
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: L("menu.app.about"),
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        // VS Code 的 `code` 那一招：把随包的 quickterm 软链进 PATH。绝不弹管理员密码
        let installItem = appMenu.addItem(withTitle: L("menu.app.install-cli"),
                                          action: #selector(AppDelegate.installCLIAction(_:)),
                                          keyEquivalent: "")
        installItem.target = delegate
        // 控制面是**静默执行**的（读免确认、改不弹框）：静默的前提是事后可查。
        // 状态栏闪一下负责"刚刚发生了什么"，这里负责"到底发生过哪些"
        let logItem = appMenu.addItem(withTitle: L("menu.app.control-activity"),
                                      action: #selector(AppDelegate.controlActivityAction(_:)),
                                      keyEquivalent: "")
        logItem.target = delegate
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L("menu.app.hide"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: L("menu.app.quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.setSubmenu(appMenu, for: appItem)

        // Edit 菜单：浏览器 pane / 地址栏 / 文件选择器等 AppKit 控件的 Cmd+C/V/X/A/Z 经菜单键等价路由；
        // 终端 pane 自己在 performKeyEquivalent 里处理绑定键，不受影响
        let editItem = main.addItem(withTitle: L("menu.edit"), action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: L("menu.edit"))
        editMenu.addItem(withTitle: L("menu.edit.undo"), action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: L("menu.edit.redo"), action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: L("menu.edit.cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: L("menu.edit.copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: L("menu.edit.paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: L("menu.edit.select-all"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.delegate = EditMenuDelegate.shared
        main.setSubmenu(editMenu, for: editItem)

        // Shell 菜单
        let shellItem = main.addItem(withTitle: L("menu.shell"), action: nil, keyEquivalent: "")
        let shellMenu = NSMenu(title: L("menu.shell"))
        shellMenu.addItem(wm(.newTerminal, title: L("menu.shell.new-terminal"), key: "\r", delegate: delegate))
        shellMenu.addItem(wm(.fileManager, title: L("menu.shell.file-manager"), key: "b", modifiers: [.command, .shift], delegate: delegate))
        shellMenu.addItem(wm(.newBrowser, title: L("menu.shell.new-browser"), key: "b", delegate: delegate))
        shellMenu.addItem(wm(.clearTerminal, title: L("menu.shell.clear-terminal"), key: "k", modifiers: [.command, .shift], delegate: delegate))
        shellMenu.addItem(wm(.closePane, title: L("menu.shell.close-pane"), key: "w", delegate: delegate))
        main.setSubmenu(shellMenu, for: shellItem)

        // Pane 菜单
        let paneItem = main.addItem(withTitle: L("menu.pane"), action: nil, keyEquivalent: "")
        let paneMenu = NSMenu(title: L("menu.pane"))
        paneMenu.addItem(wm(.focusLeft, title: L("menu.pane.focus-left"), key: String(UnicodeScalar(NSLeftArrowFunctionKey)!), delegate: delegate))
        paneMenu.addItem(wm(.focusRight, title: L("menu.pane.focus-right"), key: String(UnicodeScalar(NSRightArrowFunctionKey)!), delegate: delegate))
        paneMenu.addItem(wm(.focusUp, title: L("menu.pane.focus-up"), key: String(UnicodeScalar(NSUpArrowFunctionKey)!), delegate: delegate))
        paneMenu.addItem(wm(.focusDown, title: L("menu.pane.focus-down"), key: String(UnicodeScalar(NSDownArrowFunctionKey)!), delegate: delegate))
        paneMenu.addItem(.separator())
        paneMenu.addItem(wm(.toggleSplitDirection, title: L("menu.pane.toggle-split-direction"), key: "j", delegate: delegate))
        paneMenu.addItem(wm(.toggleZoom, title: L("menu.pane.toggle-zoom"), key: "f", delegate: delegate))
        paneMenu.addItem(wm(.equalize, title: L("menu.pane.equalize"), key: "=", modifiers: [.command, .control], delegate: delegate))
        main.setSubmenu(paneMenu, for: paneItem)

        // Window 菜单（系统标准；AppKit 会自动在末尾追加窗口列表）。
        // 多「屏幕」只从这里驱动：一律不给快捷键（⌘N 已被系统/习惯占用，用户明确要求无键位）
        let windowItem = main.addItem(withTitle: L("menu.window"), action: nil, keyEquivalent: "")
        let windowMenu = NSMenu(title: L("menu.window"))
        windowMenu.addItem(withTitle: L("menu.window.new-screen"),
                           action: #selector(AppDelegate.newScreenAction(_:)), keyEquivalent: "")
            .target = delegate
        let newOnItem = windowMenu.addItem(withTitle: L("menu.window.new-screen-on-display"), action: nil, keyEquivalent: "")
        let newOnMenu = NSMenu(title: L("menu.window.new-screen-on-display"))
        newOnMenu.delegate = newScreenDisplayDelegate(for: delegate)
        windowMenu.setSubmenu(newOnMenu, for: newOnItem)
        let moveItem = windowMenu.addItem(withTitle: L("menu.window.move-screen-to-display"), action: nil, keyEquivalent: "")
        let moveMenu = NSMenu(title: L("menu.window.move-screen-to-display"))
        moveMenu.delegate = moveScreenDisplayDelegate(for: delegate)
        windowMenu.setSubmenu(moveMenu, for: moveItem)
        windowMenu.addItem(withTitle: L("menu.window.join-all-spaces"),
                           action: #selector(AppDelegate.toggleJoinAllSpaces(_:)), keyEquivalent: "")
            .target = delegate
        windowMenu.addItem(withTitle: L("menu.window.close-screen"),
                           action: #selector(AppDelegate.closeScreenAction(_:)), keyEquivalent: "")
            .target = delegate
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: L("menu.window.minimize"), action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: L("menu.window.zoom"), action: #selector(NSWindow.zoom(_:)), keyEquivalent: "")
        windowMenu.addItem(withTitle: L("menu.window.bring-all-to-front"),
                           action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        main.setSubmenu(windowMenu, for: windowItem)
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = main
    }

    /// 两个显示器子菜单的委托：随插拔变化，每次打开都重建（必须被强持有，NSMenu.delegate 是 weak）
    private static var displayDelegates: [DisplayMenuDelegate] = []

    private static func newScreenDisplayDelegate(for delegate: AppDelegate) -> DisplayMenuDelegate {
        let d = DisplayMenuDelegate(mode: .newScreen, target: delegate)
        displayDelegates.append(d)
        return d
    }

    private static func moveScreenDisplayDelegate(for delegate: AppDelegate) -> DisplayMenuDelegate {
        let d = DisplayMenuDelegate(mode: .moveScreen, target: delegate)
        displayDelegates.append(d)
        return d
    }

    private static func wm(_ action: WMAction, title: String, key: String,
                           modifiers: NSEvent.ModifierFlags = .command,
                           delegate: AppDelegate) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(AppDelegate.performWMAction(_:)), keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = delegate
        item.representedObject = action.rawValue
        return item
    }
}

extension AppDelegate {
    @objc func performWMAction(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let action = WMAction(rawValue: raw), let controller else { return }
        // 键等价触发（currentEvent 是 keyDown）时以 [keybinds] 为准：解绑 / 改键，或焦点 pane 不消费该动作
        // （清屏时焦点在浏览器）就不执行，按键交还焦点终端；鼠标点菜单项始终执行。菜单里的快捷键只是提示
        let event = NSApp.currentEvent
        guard MainWindowController.menuShortcutAllowed(action, event: event, keybindings: controller.keybindings,
                                                       focusedPane: controller.focusedPane) else {
            if let event, let surface = event.window?.firstResponder as? Ghostty.SurfaceView {
                surface.keyDown(with: event)
            }
            return
        }
        controller.perform(action)
    }
}

/// Edit 菜单的键等价只在焦点是 AppKit 文本 / 网页控件时认领；焦点在终端 pane 时不认领——
/// 否则 Cmd+X / Cmd+Z / Cmd+A 这类引擎没绑定的键会被（禁用的）菜单项吞掉并 beep，到不了终端
/// （kitty 键盘协议应用如 neovim 是收得到 super+x 的）。
final class EditMenuDelegate: NSObject, NSMenuDelegate {
    static let shared = EditMenuDelegate()

    func menuHasKeyEquivalent(_ menu: NSMenu, for event: NSEvent,
                              target: AutoreleasingUnsafeMutablePointer<AnyObject?>?,
                              action: UnsafeMutablePointer<Selector?>?) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let key = (event.charactersIgnoringModifiers ?? "").lowercased()
        guard let item = menu.items.first(where: { Self.matches($0, key: key, flags: flags) }) else { return false }
        // 返回 false 并不能阻止 AppKit 继续枚举菜单项（探针验证：禁用项照样消费按键并 beep）。
        // 焦点在终端时明确给出 target/action：把这次按键原样转交给终端的 keyDown
        if let surface = (event.window ?? NSApp.keyWindow)?.firstResponder as? Ghostty.SurfaceView {
            target?.pointee = surface
            action?.pointee = #selector(Ghostty.SurfaceView.quicktermForwardMenuKey(_:))
            return true
        }
        target?.pointee = item.target
        action?.pointee = item.action
        return true
    }

    /// 菜单项键等价匹配：大写 keyEquivalent 隐含 Shift（AppKit 约定）
    static func matches(_ item: NSMenuItem, key: String, flags: NSEvent.ModifierFlags) -> Bool {
        guard !item.keyEquivalent.isEmpty else { return false }
        var required = item.keyEquivalentModifierMask
        if item.keyEquivalent != item.keyEquivalent.lowercased() { required.insert(.shift) }
        return item.keyEquivalent.lowercased() == key && required == flags
    }
}

extension Ghostty.SurfaceView {
    /// Edit 菜单键等价在终端聚焦时的落点：把当前按键事件交还给终端（kitty 键盘协议应用能收到 super+x/z）
    @objc func quicktermForwardMenuKey(_ sender: Any?) {
        guard let event = NSApp.currentEvent, event.type == .keyDown else { return }
        keyDown(with: event)
    }
}
