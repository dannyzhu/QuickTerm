import AppKit
import GhosttyKit

// QuickTerm shim（M0）：GhosttyEmbed 移植层引用的 Ghostty 应用侧类型的最小替身。
// M1 的 MainWindowController 将继承 BaseTerminalController，接管 SplitTree 与 WM 动作。
// 记录见 docs/porting-notes.md。

class BaseTerminalController: NSWindowController {
    var surfaceTree: SplitTree<PaneView> = .init()
    /// 焦点 pane（真相：窗口 first responder 是它或其后代）
    var focusedPane: PaneView? { nil }
    /// 焦点 pane 是终端时（引擎侧 goto_split 等只认终端）
    var focusedSurface: Ghostty.SurfaceView? { focusedPane as? Ghostty.SurfaceView }
    var titleOverride: String?
    var commandPaletteIsShowing: Bool { false }
    /// 悬停即焦点（spec §4.2）：M1 的 MainWindowController 覆写为 true
    var focusFollowsMouse: Bool { false }
    /// hover 遮挡判定（spec v7 修订）：pane 在该窗口坐标处是否被浮动层/遮罩盖住。
    /// MainWindowController 覆写为模型几何判定；默认无遮挡。
    func surfaceIsOccluded(_ pane: PaneView,
                           at locationInWindow: NSPoint) -> Bool { false }
    /// 某 pane（或其托管视图）成为 first responder（单焦点不变量：控制器清掉其他 pane 残留的 focused）
    func paneDidBecomeFirstResponder(_ pane: PaneView) {}
    /// 脱离窗口后重挂的 pane 是否可以夺回焦点（控制器有明确的待聚焦目标时不允许别人夺回）
    func paneMayReclaimFocus(_ pane: PaneView) -> Bool { true }
    /// 打开一个浏览器 pane（target=_blank / window.open 也走这里）
    func openBrowserPane(url: URL, from: PaneView?) {}
    func toggleBackgroundOpacity() {}
    func promptTabTitle() {}
    @objc func changeTabTitle(_ sender: Any?) {}
}

class TerminalWindow: NSWindow {}

/// 窗口状态恢复错误（源自 Ghostty TerminalRestorable.swift；M0 只需要类型存在）
enum TerminalRestoreError: Error {
    case identifierUnknown
    case delegateInvalid
    case windowDidNotLoad
    case stateDecodeFailed
    case surfaceHasNoWindows
}
