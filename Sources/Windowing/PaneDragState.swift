import AppKit

/// The pane drag session currently in flight (the Cmd+drag source registers itself here from
/// SurfaceDragSource).
/// Multi-screen: a pane can only be mounted in one window at a time (PaneHostView hands back the
/// same NSView instance), so **a cross-window drop is refused explicitly** - the drop zone stays
/// dark and the cursor gets the no-drop badge, rather than the drop failing silently.
/// Read and written on the main thread only (a drag runs entirely on the main thread).
final class PaneDragState {
    static let shared = PaneDragState()

    /// The pane currently being dragged
    private(set) weak var sourcePane: PaneView?
    /// The window the source pane lived in when the drag started (a pane never changes window
    /// mid-drag)
    private(set) weak var sourceWindow: NSWindow?

    func begin(pane: PaneView?) {
        sourcePane = pane
        sourceWindow = pane?.window
    }

    func end() {
        sourcePane = nil
        sourceWindow = nil
    }

    /// Whether the destination pane accepts the current drag: only inside the same window. If
    /// there is no session in flight the state is unknown, and we do not block the drop.
    func allowsDrop(on destination: PaneView) -> Bool {
        guard let sourceWindow else { return true }
        guard let destinationWindow = destination.window else { return true }
        return sourceWindow === destinationWindow
    }

    /// True when the screen point under the pointer lands on a different QuickTerm window (the
    /// drag source uses this to switch to the no-drop cursor)
    func pointsAtForeignWindow(_ screenPoint: NSPoint, from sourceWindow: NSWindow?) -> Bool {
        guard let sourceWindow else { return false }
        // orderedWindows is front-to-back order: skip the drag image window, look only at real
        // terminal windows.
        guard let hit = NSApp.orderedWindows.first(where: {
            $0.isVisible && $0.windowController is BaseTerminalController && $0.frame.contains(screenPoint)
        }) else { return false }
        return hit !== sourceWindow
    }
}
