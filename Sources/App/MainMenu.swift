import AppKit

/// 程序化主菜单：macOS 惯例条目 + WM 动作的可见快捷键注册表。
/// 实际按键由 MainWindowController 的局部监视器先行消费；菜单点击走这里的 action。
enum MainMenu {
    static func install(delegate: AppDelegate) {
        let main = NSMenu()

        // App 菜单
        let appItem = main.addItem(withTitle: "QuickTerm", action: nil, keyEquivalent: "")
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关于 QuickTerm",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "隐藏 QuickTerm", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "退出 QuickTerm", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.setSubmenu(appMenu, for: appItem)

        // Shell 菜单
        let shellItem = main.addItem(withTitle: "Shell", action: nil, keyEquivalent: "")
        let shellMenu = NSMenu(title: "Shell")
        shellMenu.addItem(wm(.newTerminal, title: "新建终端", key: "\r", delegate: delegate))
        shellMenu.addItem(wm(.fileManager, title: "文件管理器", key: "b", modifiers: [.command, .shift], delegate: delegate))
        shellMenu.addItem(wm(.closePane, title: "关闭 Pane", key: "w", delegate: delegate))
        main.setSubmenu(shellMenu, for: shellItem)

        // Pane 菜单
        let paneItem = main.addItem(withTitle: "Pane", action: nil, keyEquivalent: "")
        let paneMenu = NSMenu(title: "Pane")
        paneMenu.addItem(wm(.focusLeft, title: "焦点左移", key: String(UnicodeScalar(NSLeftArrowFunctionKey)!), delegate: delegate))
        paneMenu.addItem(wm(.focusRight, title: "焦点右移", key: String(UnicodeScalar(NSRightArrowFunctionKey)!), delegate: delegate))
        paneMenu.addItem(wm(.focusUp, title: "焦点上移", key: String(UnicodeScalar(NSUpArrowFunctionKey)!), delegate: delegate))
        paneMenu.addItem(wm(.focusDown, title: "焦点下移", key: String(UnicodeScalar(NSDownArrowFunctionKey)!), delegate: delegate))
        paneMenu.addItem(.separator())
        paneMenu.addItem(wm(.toggleSplitDirection, title: "切换分裂方向", key: "j", delegate: delegate))
        paneMenu.addItem(wm(.toggleZoom, title: "Pane 缩放", key: "f", delegate: delegate))
        paneMenu.addItem(wm(.equalize, title: "全部等分", key: "=", modifiers: [.command, .control], delegate: delegate))
        main.setSubmenu(paneMenu, for: paneItem)

        // Window 菜单（系统标准）
        let windowItem = main.addItem(withTitle: "Window", action: nil, keyEquivalent: "")
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "最小化", action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m")
        main.setSubmenu(windowMenu, for: windowItem)
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = main
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
              let action = WMAction(rawValue: raw) else { return }
        controller?.perform(action)
    }
}
