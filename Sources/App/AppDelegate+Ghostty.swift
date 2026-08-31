import AppKit

// GhosttyEmbed 移植层要求应用委托提供的接口。
// M0 提供最小实现；M1 起逐项接管（详见 docs/porting-notes.md）。
extension AppDelegate {
    func checkForUpdates(_ sender: Any?) {}                     // QuickTerm 无 Sparkle 更新器
    func closeAllWindows(_ sender: Any?) {}                     // M1 接管
    func toggleVisibility(_ sender: Any) {}                     // M1 接管
    func syncFloatOnTopMenu(_ window: NSWindow) {}              // QuickTerm 无该菜单项
    func setSecureInput(_ mode: Ghostty.SetSecureInput) {}      // 后续里程碑接管
    func toggleQuickTerminal(_ sender: Any) {}                  // v2 全局下拉终端
    func performGhosttyBindingMenuKeyEquivalent(with event: NSEvent) -> Bool { false }
}
