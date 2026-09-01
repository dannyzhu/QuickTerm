import AppKit
import GhosttyKit

// QuickTerm shim（M0）：GhosttyEmbed 移植层引用的 Ghostty 应用侧类型的最小替身。
// M1 的 MainWindowController 将继承 BaseTerminalController，接管 SplitTree 与 WM 动作。
// 记录见 docs/porting-notes.md。

class BaseTerminalController: NSWindowController {
    var surfaceTree: SplitTree<Ghostty.SurfaceView> = .init()
    var focusedSurface: Ghostty.SurfaceView? { nil }
    var titleOverride: String?
    var commandPaletteIsShowing: Bool { false }
    /// 悬停即焦点（spec §4.2）：M1 的 MainWindowController 覆写为 true
    var focusFollowsMouse: Bool { false }
    /// hover 遮挡判定（spec v7 修订）：pane 在该窗口坐标处是否被浮动层/遮罩盖住。
    /// MainWindowController 覆写为模型几何判定；默认无遮挡。
    func surfaceIsOccluded(_ pane: Ghostty.SurfaceView,
                           at locationInWindow: NSPoint) -> Bool { false }
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
