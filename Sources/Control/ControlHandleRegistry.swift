import AppKit

/// Registry of short handles: `t7` / `b3` (Zellij's type-prefixed ids).
/// Stable within the process, monotonically increasing, and **never reused** — reuse would let
/// a stale handle in an agent's hands quietly start pointing at a different pane.
/// The UUID is still in every JSON record and is the only identity that survives a restart; the
/// short handle is the one people and models actually type.
@MainActor
final class ControlHandleRegistry {
    static let shared = ControlHandleRegistry()

    private var handles: [UUID: String] = [:]
    private var owners: [String: UUID] = [:]
    /// One shared counter, not one per kind: handles are unique process-wide, and `t1 t2 b3 t4`
    /// still shows the order they were created in
    private var counter = 0

    private init() {}

    static func prefix(for kind: PaneKind) -> String {
        switch kind {
        case .terminal: "t"
        case .browser: "b"
        }
    }

    /// Fetch a pane's handle, allocating one the first time
    func handle(for pane: PaneView) -> String {
        if let existing = handles[pane.id] { return existing }
        counter += 1
        let handle = "\(Self.prefix(for: pane.kind))\(counter)"
        handles[pane.id] = handle
        owners[handle] = pane.id
        return handle
    }

    /// An already-allocated handle; never allocates. For everywhere that is not encoding
    /// "what is this pane's handle right now"
    func existingHandle(for id: UUID) -> String? { handles[id] }

    func paneID(forHandle handle: String) -> UUID? { owners[handle.lowercased()] }

    /// Tests only: clear the tables and reset the counter
    func reset() {
        handles.removeAll()
        owners.removeAll()
        counter = 0
    }
}
