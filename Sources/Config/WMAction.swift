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
    case gotoWorkspace1 = "goto-workspace-1", gotoWorkspace2 = "goto-workspace-2"
    case gotoWorkspace3 = "goto-workspace-3", gotoWorkspace4 = "goto-workspace-4"
    case gotoWorkspace5 = "goto-workspace-5"
    case moveToWorkspace1 = "move-to-workspace-1", moveToWorkspace2 = "move-to-workspace-2"
    case moveToWorkspace3 = "move-to-workspace-3", moveToWorkspace4 = "move-to-workspace-4"
    case moveToWorkspace5 = "move-to-workspace-5"
    case gotoWorkspace6 = "goto-workspace-6", gotoWorkspace7 = "goto-workspace-7"
    case gotoWorkspace8 = "goto-workspace-8", gotoWorkspace9 = "goto-workspace-9"
    case gotoWorkspace10 = "goto-workspace-10"
    case moveToWorkspace6 = "move-to-workspace-6", moveToWorkspace7 = "move-to-workspace-7"
    case moveToWorkspace8 = "move-to-workspace-8", moveToWorkspace9 = "move-to-workspace-9"
    case moveToWorkspace10 = "move-to-workspace-10"
    case toggleBar = "toggle-bar"
    case themePicker = "theme-picker"
    case backgroundMenu = "next-background"
    case toggleOpacity = "toggle-opacity"
    case toggleGaps = "toggle-gaps"
    case keybindingHelp = "keybind-help"
    case mainMenu = "main-menu"
    case scratchpad = "scratchpad"
    case toggleFullscreen = "toggle-fullscreen"
    case toggleLayout = "toggle-layout"
    case openSettings = "open-settings"
    case exitFullscreen = "exit-fullscreen"

    /// goto/move 系列的工作区序号（0-based），非工作区动作为 nil
    var workspaceIndex: Int? {
        switch self {
        case .gotoWorkspace1, .moveToWorkspace1: 0
        case .gotoWorkspace2, .moveToWorkspace2: 1
        case .gotoWorkspace3, .moveToWorkspace3: 2
        case .gotoWorkspace4, .moveToWorkspace4: 3
        case .gotoWorkspace5, .moveToWorkspace5: 4
        case .gotoWorkspace6, .moveToWorkspace6: 5
        case .gotoWorkspace7, .moveToWorkspace7: 6
        case .gotoWorkspace8, .moveToWorkspace8: 7
        case .gotoWorkspace9, .moveToWorkspace9: 8
        case .gotoWorkspace10, .moveToWorkspace10: 9
        default: nil
        }
    }

    var isGotoWorkspace: Bool { rawValue.hasPrefix("goto-workspace-") }
    var isMoveToWorkspace: Bool { rawValue.hasPrefix("move-to-workspace-") }

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
        case .gotoWorkspace1: "切到工作区 1"
        case .gotoWorkspace2: "切到工作区 2"
        case .gotoWorkspace3: "切到工作区 3"
        case .gotoWorkspace4: "切到工作区 4"
        case .gotoWorkspace5: "切到工作区 5"
        case .moveToWorkspace1: "移动 pane 到工作区 1"
        case .moveToWorkspace2: "移动 pane 到工作区 2"
        case .moveToWorkspace3: "移动 pane 到工作区 3"
        case .moveToWorkspace4: "移动 pane 到工作区 4"
        case .moveToWorkspace5: "移动 pane 到工作区 5"
        case .gotoWorkspace6: "切到工作区 6"
        case .gotoWorkspace7: "切到工作区 7"
        case .gotoWorkspace8: "切到工作区 8"
        case .gotoWorkspace9: "切到工作区 9"
        case .gotoWorkspace10: "切到工作区 10"
        case .moveToWorkspace6: "移动 pane 到工作区 6"
        case .moveToWorkspace7: "移动 pane 到工作区 7"
        case .moveToWorkspace8: "移动 pane 到工作区 8"
        case .moveToWorkspace9: "移动 pane 到工作区 9"
        case .moveToWorkspace10: "移动 pane 到工作区 10"
        case .toggleBar: "顶栏显示/隐藏"
        case .themePicker: "主题选择器"
        case .backgroundMenu: "背景选择/下一张"
        case .toggleOpacity: "透明度开关"
        case .toggleGaps: "gaps 开关"
        case .keybindingHelp: "快捷键速查"
        case .mainMenu: "QuickTerm 主菜单"
        case .scratchpad: "Scratchpad 浮动终端"
        case .toggleFullscreen: "整窗全屏 开/关"
        case .toggleLayout: "布局切换（scrolling ⇄ dwindle）"
        case .openSettings: "打开配置文件（QuickTerm + ghostty）"
        case .exitFullscreen: "退出全屏（仅全屏时生效）"
        }
    }
}
