import AppKit

/// 全局修饰键状态（由 MainWindowController 的鼠标 / 滚轮监视器更新）。
/// TerminalSplitLeaf 据此在按住 ⌘ 时浮出拖拽源覆盖层（spec §4.2 Cmd+拖拽）。
///
/// 自愈是硬要求：喂它的是**本地** NSEvent 监视器，只看得见投递给本 app 的事件。⌘ 的抬起要是落在
/// 别的 app 上（⌘+Tab、⌘+Space、⌘+Shift+4 截图、⌘+H、按着 ⌘ 点别的窗口 / Dock、锁屏），
/// 本地监视器永远收不到，`commandHeld` 就会一直卡在 true——整个 pane 上盖着拖拽源浮层，
/// 表现为"抓手光标不消失，而且终端再也滚不动了"（见 porting-notes「本地监视器盲区」）。
/// 因此：app 失活时清零，回到前台按真实键盘状态重建，并且任何鼠标 / 滚轮事件都会顺手 `sync`。
final class ModifierState: ObservableObject {
    static let shared = ModifierState()
    @Published var commandHeld = false

    private init() {
        let center = NotificationCenter.default
        center.addObserver(forName: NSApplication.didResignActiveNotification,
                           object: nil, queue: .main) { [weak self] _ in
            self?.commandHeld = false
        }
        center.addObserver(forName: NSApplication.didBecomeActiveNotification,
                           object: nil, queue: .main) { [weak self] _ in
            self?.sync()
        }
    }

    /// 用权威的当前修饰键状态重新同步（`NSEvent.modifierFlags` 不需要辅助功能授权）。
    /// 幂等：值没变就不发 @Published 通知
    func sync(_ flags: NSEvent.ModifierFlags = NSEvent.modifierFlags) {
        let held = flags.contains(.command)
        if commandHeld != held { commandHeld = held }
    }
}
