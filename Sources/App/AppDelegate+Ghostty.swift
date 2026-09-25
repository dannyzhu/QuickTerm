import AppKit

// The interface the GhosttyEmbed porting layer requires the app delegate to provide.
// M0 supplies minimal implementations; they are taken over one at a time from M1 on
// (see docs/porting-notes.md for the details).
extension AppDelegate {
    /// Check for Updates…: the menu item and the engine's `check_for_updates` keybind action
    /// (Ghostty.App.swift calls this with nil) both land here. `nonisolated` (like
    /// `Ghostty.App`'s own producers) because the engine calls it from a nonisolated context on
    /// the main thread; `assumeIsolated` hops onto the main actor to reach `session.updates`.
    @objc func checkForUpdates(_ sender: Any?) { MainActor.assumeIsolated { session?.updates.checkForUpdates() } }
    func closeAllWindows(_ sender: Any?) {}                     // taken over in M1
    func toggleVisibility(_ sender: Any) {}                     // taken over in M1
    func syncFloatOnTopMenu(_ window: NSWindow) {}              // QuickTerm has no such menu item
    func setSecureInput(_ mode: Ghostty.SetSecureInput) {}      // taken over in a later milestone
    func toggleQuickTerminal(_ sender: Any) {}                  // v2 global drop-down terminal
    func performGhosttyBindingMenuKeyEquivalent(with event: NSEvent) -> Bool { false }
}
