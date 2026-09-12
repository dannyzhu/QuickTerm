import AppKit

/// Global modifier-key state, updated by `MainWindowController`'s mouse and scroll-wheel
/// monitors. `TerminalSplitLeaf` reads it to float the drag-source overlay while Cmd is held
/// (spec §4.2, Cmd+drag).
///
/// Self-healing is a hard requirement: what feeds this is a **local** NSEvent monitor, and a
/// local monitor only sees events delivered to this app. If the Cmd key-up lands in some other app
/// (Cmd+Tab, Cmd+Space, the Cmd+Shift+4 screenshot, Cmd+H, Cmd+clicking another window or the Dock, the
/// lock screen), the local monitor never receives it and `commandHeld` stays stuck at true: the
/// drag-source overlay then covers the entire pane, which the user sees as "the grab cursor
/// won't go away, and the terminal doesn't scroll any more" (see "local monitor blind spots" in
/// porting-notes). Hence: clear it when the app resigns active, rebuild it from the real
/// keyboard state on the way back to the front, and `sync` on the side of every mouse and
/// scroll-wheel event.
final class ModifierState: ObservableObject {
    static let shared = ModifierState()
    @Published var commandHeld = false

    private init() {
        let center = NotificationCenter.default
        center.addObserver(forName: NSApplication.didResignActiveNotification,
                           object: nil, queue: .main) { [weak self] _ in
            self?.commandHeld = false
        }
        center.addObserver(forName: NSApplication.didBecomeActiveNotification,
                           object: nil, queue: .main) { [weak self] _ in
            self?.sync()
        }
    }

    /// Re-sync from the authoritative current modifier state (`NSEvent.modifierFlags` needs no
    /// Accessibility permission). Idempotent: an unchanged value publishes nothing.
    func sync(_ flags: NSEvent.ModifierFlags = NSEvent.modifierFlags) {
        let held = flags.contains(.command)
        if commandHeld != held { commandHeld = held }
    }
}
