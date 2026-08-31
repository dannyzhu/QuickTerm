import AppKit

/// 全局修饰键状态（由 MainWindowController 的 flagsChanged 监视器更新）。
/// TerminalSplitLeaf 据此在按住 ⌘ 时浮出拖拽源覆盖层（spec §4.2 Cmd+拖拽）。
final class ModifierState: ObservableObject {
    static let shared = ModifierState()
    @Published var commandHeld = false
}
