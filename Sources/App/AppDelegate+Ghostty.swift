import AppKit

// The interface the GhosttyEmbed porting layer requires the app delegate to provide.
// M0 supplies minimal implementations; they are taken over one at a time from M1 on
// (see docs/porting-notes.md for the details).
extension AppDelegate {
    func checkForUpdates(_ sender: Any?) {}                     // QuickTerm has no Sparkle updater
    func closeAllWindows(_ sender: Any?) {}                     // taken over in M1
    func toggleVisibility(_ sender: Any) {}                     // taken over in M1
    func syncFloatOnTopMenu(_ window: NSWindow) {}              // QuickTerm has no such menu item
    func setSecureInput(_ mode: Ghostty.SetSecureInput) {}      // taken over in a later milestone
    func toggleQuickTerminal(_ sender: Any) {}                  // v2 global drop-down terminal
    func performGhosttyBindingMenuKeyEquivalent(with event: NSEvent) -> Bool { false }
}
