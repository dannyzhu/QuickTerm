import Foundation

/// Every WM-level action (spec §5.1). Both the cheat sheet and config `[keybinds]` (M4) take
/// their action list from here.
enum WMAction: String, CaseIterable {
    case newTerminal = "new-terminal"
    case fileManager = "file-manager"
    case newBrowser = "new-browser"
    // Terminal panes only (passed through when a terminal is not focused): Cmd+K belongs to the
    // cheat sheet, so clear-screen moved to Cmd+Shift+K
    case clearTerminal = "clear-terminal"
    // Browser panes only (passed through to the terminal when a browser pane is not focused;
    // see MainWindowController's key monitor)
    case webBack = "web-back", webForward = "web-forward", webReload = "web-reload"
    case webFocusAddress = "web-focus-address", webOpenExternal = "web-open-external"
    case webZoomIn = "web-zoom-in", webZoomOut = "web-zoom-out", webZoomReset = "web-zoom-reset"
    case webNewTab = "web-new-tab", webNextTab = "web-next-tab", webPrevTab = "web-prev-tab"
    case webExtensions = "web-extensions"
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
    case toggleFloat = "toggle-float"

    /// The workspace index (0-based) for the goto/move family; nil for every other action.
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

    /// Actions that only apply to a focused browser pane: with a terminal focused the key is not
    /// consumed (Cmd+R, Cmd+= and the rest still belong to the terminal).
    var browserOnly: Bool { rawValue.hasPrefix("web-") }
    /// Actions that only apply to a focused terminal pane: the key is not consumed while a
    /// browser or any other kind of pane has focus.
    var terminalOnly: Bool { self == .clearTerminal }

    var isGotoWorkspace: Bool { rawValue.hasPrefix("goto-workspace-") }
    var isMoveToWorkspace: Bool { rawValue.hasPrefix("move-to-workspace-") }

    /// The description to draw **in the app's own window** (the Cmd+K cheat sheet, the control
    /// plane's consent alert): the active UI language, picked from the fixed pair below.
    ///
    /// `help` (Chinese) and `helpEN` stay exactly as they are — `describe --json` and the MCP
    /// tool table hand out *both* wordings at once, and the CLI is English in either language.
    /// `ConfigSchema.templateLanguage` rather than `Localization`: this file is compiled into
    /// the `quickterm` CLI too, which has no AppKit and no `.lproj` directories. The app keeps
    /// the two in sync (`Localization.setLanguage`).
    ///
    /// A SwiftUI view that draws this must still read its `Localization` environment object
    /// somewhere in the same body, or nothing tells it to re-render when the language changes.
    var localizedHelp: String {
        ConfigSchema.templateLanguage == .zh ? help : helpEN
    }

    /// The Chinese description shown in the Cmd+K cheat sheet.
    var help: String {
        switch self {
        case .newTerminal: "新建终端（scrolling 右插新列 / dwindle 分裂，继承当前目录）"
        case .fileManager: "文件管理器（新 pane 运行 yazi，继承当前目录；退出时目录已变则原位开终端）"
        case .newBrowser: "新建浏览器 pane（打开 browser-home）"
        case .clearTerminal: "清屏（清除屏幕与回滚；仅终端 pane 聚焦时生效）"
        case .webBack: "浏览器：后退（仅焦点在浏览器 pane 时）"
        case .webForward: "浏览器：前进"
        case .webReload: "浏览器：重新加载"
        case .webFocusAddress: "浏览器：焦点到地址栏"
        case .webOpenExternal: "浏览器：在系统默认浏览器打开当前页"
        case .webZoomIn: "浏览器：放大页面"
        case .webZoomOut: "浏览器：缩小页面"
        case .webZoomReset: "浏览器：页面缩放复位"
        case .webNewTab: "浏览器：新标签页（Cmd+W 关当前标签，最后一个标签关 pane）"
        case .webNextTab: "浏览器：下一个标签"
        case .webPrevTab: "浏览器：上一个标签"
        case .webExtensions: "浏览器：扩展菜单（安装 / 启停 / 从 Chrome 导入）"
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
        case .toggleFloat: "pane 浮动 ⇄ 平铺（⌘拖中间移动、⌘拖四边/四角缩放、⌘右拖调大小）"
        }
    }

    /// The English description. `describe --json` and the MCP tool table hand out both wordings
    /// at once: describe's output gets pasted verbatim into bilingual agent prompts, and with
    /// only the Chinese half in there the model is left guessing at what an action does.
    var helpEN: String {
        switch self {
        case .newTerminal: "New terminal pane (scrolling: insert a column to the right; dwindle: split), inheriting the current directory"
        case .fileManager: "File manager pane (runs yazi in a new pane, inherits the current directory; on exit, opens a terminal in place if the directory changed)"
        case .newBrowser: "New browser pane (opens browser-home)"
        case .clearTerminal: "Clear screen and scrollback (only when a terminal pane is focused)"
        case .webBack: "Browser: back (only when a browser pane is focused)"
        case .webForward: "Browser: forward"
        case .webReload: "Browser: reload"
        case .webFocusAddress: "Browser: focus the address bar"
        case .webOpenExternal: "Browser: open the current page in the system default browser"
        case .webZoomIn: "Browser: zoom in"
        case .webZoomOut: "Browser: zoom out"
        case .webZoomReset: "Browser: reset page zoom"
        case .webNewTab: "Browser: new tab (Cmd+W closes the current tab; closing the last tab closes the pane)"
        case .webNextTab: "Browser: next tab"
        case .webPrevTab: "Browser: previous tab"
        case .webExtensions: "Browser: extensions menu (install / enable / import from Chrome)"
        case .closePane: "Close the focused pane"
        case .focusLeft: "Move focus left"
        case .focusRight: "Move focus right"
        case .focusUp: "Move focus up"
        case .focusDown: "Move focus down"
        case .swapLeft: "Swap with the pane on the left"
        case .swapRight: "Swap with the pane on the right"
        case .swapUp: "Swap with the pane above"
        case .swapDown: "Swap with the pane below"
        case .toggleSplitDirection: "Toggle the split direction"
        case .toggleZoom: "Toggle pane zoom (fill the content area)"
        case .equalize: "Equalize everything"
        case .resizeLeft: "Resize leftwards (+Shift for fine steps)"
        case .resizeRight: "Resize rightwards (+Shift for fine steps)"
        case .resizeUp: "Resize upwards (+Shift for fine steps)"
        case .resizeDown: "Resize downwards (+Shift for fine steps)"
        case .cyclePaneNext: "Next pane"
        case .cyclePanePrev: "Previous pane"
        case .gotoWorkspace1: "Switch to workspace 1"
        case .gotoWorkspace2: "Switch to workspace 2"
        case .gotoWorkspace3: "Switch to workspace 3"
        case .gotoWorkspace4: "Switch to workspace 4"
        case .gotoWorkspace5: "Switch to workspace 5"
        case .moveToWorkspace1: "Move the pane to workspace 1"
        case .moveToWorkspace2: "Move the pane to workspace 2"
        case .moveToWorkspace3: "Move the pane to workspace 3"
        case .moveToWorkspace4: "Move the pane to workspace 4"
        case .moveToWorkspace5: "Move the pane to workspace 5"
        case .gotoWorkspace6: "Switch to workspace 6"
        case .gotoWorkspace7: "Switch to workspace 7"
        case .gotoWorkspace8: "Switch to workspace 8"
        case .gotoWorkspace9: "Switch to workspace 9"
        case .gotoWorkspace10: "Switch to workspace 10"
        case .moveToWorkspace6: "Move the pane to workspace 6"
        case .moveToWorkspace7: "Move the pane to workspace 7"
        case .moveToWorkspace8: "Move the pane to workspace 8"
        case .moveToWorkspace9: "Move the pane to workspace 9"
        case .moveToWorkspace10: "Move the pane to workspace 10"
        case .toggleBar: "Show / hide the top bar"
        case .themePicker: "Theme picker"
        case .backgroundMenu: "Background picker / next wallpaper"
        case .toggleOpacity: "Toggle transparency"
        case .toggleGaps: "Toggle gaps"
        case .keybindingHelp: "Keybinding cheat sheet"
        case .mainMenu: "QuickTerm main menu"
        case .scratchpad: "Scratchpad floating terminal"
        case .toggleFullscreen: "Toggle whole-window fullscreen"
        case .toggleLayout: "Toggle layout (scrolling <-> dwindle)"
        case .openSettings: "Open the config files (QuickTerm + ghostty)"
        case .exitFullscreen: "Exit fullscreen (only while fullscreen)"
        case .toggleFloat: "Toggle pane float / tile (Cmd-drag the middle to move, the edges or corners to resize, Cmd-right-drag to resize)"
        }
    }
}
