import AppKit

/// 进行中的 pane 拖拽会话（⌘+拖拽源在 SurfaceDragSource 里登记）。
/// 多屏幕：一个 pane 同一时刻只能挂在一个窗口里（PaneHostView 返回同一个 NSView 实例），
/// 所以**跨窗口拖放明确拒绝**——落区不亮、光标给禁止标记，而不是静默失败。
/// 只在主线程读写（拖拽全程都在主线程）。
final class PaneDragState {
    static let shared = PaneDragState()

    /// 正在被拖的 pane
    private(set) weak var sourcePane: PaneView?
    /// 拖拽开始时源 pane 所在的窗口（拖动过程中 pane 不会换窗口）
    private(set) weak var sourceWindow: NSWindow?

    func begin(pane: PaneView?) {
        sourcePane = pane
        sourceWindow = pane?.window
    }

    func end() {
        sourcePane = nil
        sourceWindow = nil
    }

    /// 目标 pane 是否接受当前拖拽：同窗口才接受；没有进行中的会话（状态未知）不拦
    func allowsDrop(on destination: PaneView) -> Bool {
        guard let sourceWindow else { return true }
        guard let destinationWindow = destination.window else { return true }
        return sourceWindow === destinationWindow
    }

    /// 指针所在的屏幕点落在别的 QuickTerm 窗口上（拖拽源据此给禁止光标）
    func pointsAtForeignWindow(_ screenPoint: NSPoint, from sourceWindow: NSWindow?) -> Bool {
        guard let sourceWindow else { return false }
        // orderedWindows 是前后顺序：跳过拖拽影像窗口，只看真正的终端窗口
        guard let hit = NSApp.orderedWindows.first(where: {
            $0.isVisible && $0.windowController is BaseTerminalController && $0.frame.contains(screenPoint)
        }) else { return false }
        return hit !== sourceWindow
    }
}
