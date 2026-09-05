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

        // Edit 菜单：浏览器 pane / 地址栏 / 文件选择器等 AppKit 控件的 Cmd+C/V/X/A/Z 经菜单键等价路由；
        // 终端 pane 自己在 performKeyEquivalent 里处理绑定键，不受影响
        let editItem = main.addItem(withTitle: "Edit", action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.delegate = EditMenuDelegate.shared
        main.setSubmenu(editMenu, for: editItem)

        // Shell 菜单
        let shellItem = main.addItem(withTitle: "Shell", action: nil, keyEquivalent: "")
        let shellMenu = NSMenu(title: "Shell")
        shellMenu.addItem(wm(.newTerminal, title: "新建终端", key: "\r", delegate: delegate))
        shellMenu.addItem(wm(.fileManager, title: "文件管理器", key: "b", modifiers: [.command, .shift], delegate: delegate))
        shellMenu.addItem(wm(.newBrowser, title: "新建浏览器", key: "b", delegate: delegate))
        shellMenu.addItem(wm(.clearTerminal, title: "清屏", key: "k", modifiers: [.command, .shift], delegate: delegate))
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
