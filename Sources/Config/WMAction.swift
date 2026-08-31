import Foundation

/// WM 级动作全集（spec §5.1）。速查表与 config `[keybinds]`（M4）都以此为动作清单。
enum WMAction: String, CaseIterable {
    case newTerminal = "new-terminal"
    case closePane = "close-pane"
    case focusLeft = "focus-left", focusRight = "focus-right"
    case focusUp = "focus-up", focusDown = "focus-down"
    case swapLeft = "swap-left", swapRight = "swap-right"
    case swapUp = "swap-up", swapDown = "swap-down"
    case toggleSplitDirection = "toggle-split-dir"
    case toggleZoom = "toggle-zoom"
    case equalize = "equalize"
    case resizeLeft = "resize-left", resizeRight = "resize-right"
    case resizeUp = "resize-up", resizeDown = "resize-down"
    case cyclePaneNext = "cycle-pane-next", cyclePanePrev = "cycle-pane-prev"

    /// 速查表（Cmd+K）展示用中文说明
    var help: String {
        switch self {
        case .newTerminal: "新建终端（dwindle 分裂，继承当前目录）"
        case .closePane: "关闭焦点 pane"
        case .focusLeft: "焦点左移"
        case .focusRight: "焦点右移"
        case .focusUp: "焦点上移"
        case .focusDown: "焦点下移"
        case .swapLeft: "与左侧交换"
        case .swapRight: "与右侧交换"
        case .swapUp: "与上方交换"
        case .swapDown: "与下方交换"
        case .toggleSplitDirection: "切换分裂方向"
        case .toggleZoom: "pane 缩放（占满内容区）"
        case .equalize: "全部等分"
        case .resizeLeft: "向左调整大小（+⇧ 微调）"
        case .resizeRight: "向右调整大小（+⇧ 微调）"
        case .resizeUp: "向上调整大小（+⇧ 微调）"
        case .resizeDown: "向下调整大小（+⇧ 微调）"
        case .cyclePaneNext: "下一个 pane"
        case .cyclePanePrev: "上一个 pane"
        }
    }
}
