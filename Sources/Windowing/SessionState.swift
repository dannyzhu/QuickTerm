import AppKit

// MARK: - Data structures of archive v5 (spec v9 §3.1)
//
// What "restore everything in one go" means (settled with the user on 2026-09-08): quit and reopen,
// and you get back every "screen" you had, the panes and layout on each screen, the directory each
// terminal pane was in, and the page each browser pane had open.
// The first three were already being persisted back in v4 (`WorkspaceLayout` /
// `ScrollingStrip.Column` / `SplitTree` / `FloatingPane` / `PaneCodable`) - v5 **only changes the
// envelope**: it wraps the three single-window fields into `windows[]` and adds "which display this
// window is on, how big it is, and whether it is fullscreen". Not one byte of the pane and layout
// encoding changes, so a v2-v4 archive only needs a new envelope to be readable and not a single
// pane-level test has to change.

/// Display identity: the UUID first, the name second. `frame` is only used for repositioning -
/// it changes the moment the resolution or the display arrangement does, so it must never be
/// treated as identity.
struct DisplayRef: Codable, Equatable {
    /// The UUID string from `CGDisplayCreateUUIDFromDisplayID` (stable across reconnects and
    /// reboots)
    var uuid: String?
    /// `NSScreen.localizedName` (the fallback when the UUID does not match; two displays of the
    /// same model share a name)
    var name: String?
    /// The display's frame at archive time (informational, for debugging)
    var frame: CGRect?

    init(uuid: String? = nil, name: String? = nil, frame: CGRect? = nil) {
        self.uuid = uuid
        self.name = name
        self.frame = frame
    }

    /// Take the identity from an NSScreen (a nil screen gives nil, meaning "we do not know where
    /// it was" = the historical behavior of centering on the main display)
    init?(screen: NSScreen?) {
        guard let screen else { return nil }
        self.uuid = screen.displayUUID?.uuidString
        self.name = screen.localizedName
        self.frame = screen.frame
    }
}

/// The archived state of one "screen" (window)
struct WindowState: Codable {
    var id: UUID
    /// Per-workspace layout (encoded exactly as in v2-v4)
    var layouts: [WorkspaceLayout]
    /// Per-workspace floating layer (v3 and later; absent = an empty floating layer)
    var floatings: [[FloatingPane]]?
    var activeIndex: Int
    /// Per-workspace name (parallel to `layouts`; nil = no workspace in this archive was ever
    /// named).
    /// It is an **optional field**: an older v5 archive without it still decodes, which is why the
    /// envelope version is left alone.
    var workspaceTitles: [String?]?
    /// Visible columns per screen in scrolling mode (nil = use the global default / the config)
    var visibleColumns: Int?
    /// The display the window was on at archive time (nil = unknown, so the main display)
    var display: DisplayRef?
    /// The non-fullscreen frame (in global coordinates; while fullscreen this holds the frame to
    /// restore on leaving fullscreen)
    var frame: CGRect?
    var isFullscreen: Bool
    var joinAllSpaces: Bool
    /// The pane that held focus at archive time (an envelope field, so the pane encoding is
    /// untouched). nil, or an id that no longer resolves, means the first pane.
    var focusedPaneID: UUID?

    init(id: UUID = UUID(), layouts: [WorkspaceLayout], floatings: [[FloatingPane]]? = nil,
         activeIndex: Int = 0, workspaceTitles: [String?]? = nil, visibleColumns: Int? = nil,
         display: DisplayRef? = nil,
         frame: CGRect? = nil, isFullscreen: Bool = false, joinAllSpaces: Bool = false,
         focusedPaneID: UUID? = nil) {
        self.id = id
        self.layouts = layouts
        self.floatings = floatings
        self.activeIndex = activeIndex
        self.workspaceTitles = workspaceTitles
        self.visibleColumns = visibleColumns
        self.display = display
        self.frame = frame
        self.isFullscreen = isFullscreen
        self.joinAllSpaces = joinAllSpaces
        self.focusedPaneID = focusedPaneID
    }

    /// This window has no pane at all (both tiled and floating are empty) - it is dropped on
    /// restore rather than opening an empty window.
    var isEmpty: Bool {
        layouts.allSatisfy(\.isEmpty) && (floatings ?? []).allSatisfy(\.isEmpty)
    }

    private enum CodingKeys: String, CodingKey {
        case id, layouts, floatings, activeIndex, workspaceTitles, visibleColumns, display, frame,
             isFullscreen, joinAllSpaces, focusedPaneID
    }

    /// Hand-written decoding so that any missing field falls back to its default. The synthesized
    /// decoder throws outright on a missing key for a non-optional field, and every field added
    /// after v5 has to be readable-while-absent from an older archive - otherwise adding one field
    /// throws away a user's session.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        layouts = try c.decode([WorkspaceLayout].self, forKey: .layouts)
        floatings = try c.decodeIfPresent([[FloatingPane]].self, forKey: .floatings)
        activeIndex = try c.decodeIfPresent(Int.self, forKey: .activeIndex) ?? 0
        workspaceTitles = try c.decodeIfPresent([String?].self, forKey: .workspaceTitles)
        visibleColumns = try c.decodeIfPresent(Int.self, forKey: .visibleColumns)
        display = try c.decodeIfPresent(DisplayRef.self, forKey: .display)
        frame = try c.decodeIfPresent(CGRect.self, forKey: .frame)
        isFullscreen = try c.decodeIfPresent(Bool.self, forKey: .isFullscreen) ?? false
        joinAllSpaces = try c.decodeIfPresent(Bool.self, forKey: .joinAllSpaces) ?? false
        focusedPaneID = try c.decodeIfPresent(UUID.self, forKey: .focusedPaneID)
    }
}

/// Archive envelope v5: several screens, plus which screen is key
struct PersistedState: Codable {
    static let currentVersion = 5

    var version: Int
    var windows: [WindowState]
    var keyWindowID: UUID?
    /// Stacking order (front to back). `windows[]` keeps the registry / creation order, since
    /// screen numbers and titles are assigned from it, so which window covers which is stored
    /// separately here. nil, or a window missing from the list, means unknown and it is ordered by
    /// its position in the archive.
    var stackingOrder: [UUID]?

    init(windows: [WindowState], keyWindowID: UUID? = nil, stackingOrder: [UUID]? = nil,
         version: Int = PersistedState.currentVersion) {
        self.version = version
        self.windows = windows
        self.keyWindowID = keyWindowID
        self.stackingOrder = stackingOrder
    }

    private enum CodingKeys: String, CodingKey { case version, windows, keyWindowID, stackingOrder }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? PersistedState.currentVersion
        stackingOrder = try c.decodeIfPresent([UUID].self, forKey: .stackingOrder)
        // Decode window by window, leniently: if one screen's archive is broken (the engine
        // refused a pane, a field was hand-edited into nonsense) only that one is dropped and the
        // remaining screens restore as usual - one bad window must not take the whole session down.
        windows = try c.decode([LossyWindow].self, forKey: .windows).compactMap(\.value)
        keyWindowID = try c.decodeIfPresent(UUID.self, forKey: .keyWindowID)
    }

    /// Wrapper that turns a decoding failure into "there is no such window" (the element's own
    /// decoder always succeeds, so it never aborts the whole array)
    private struct LossyWindow: Decodable {
        let value: WindowState?
        init(from decoder: Decoder) throws { value = try? WindowState(from: decoder) }
    }
}

/// The single-window archive of v2-v4 (only used to read old files; v5 and later never write this
/// shape)
struct LegacyPersistedState: Codable {
    var version = 4   // v4: leaves carry a kind (terminal/browser); in v2/v3 no kind means terminal
    var layouts: [WorkspaceLayout]
    /// v3 and later; in a v2 archive this is absent and means an empty floating layer
    var floatings: [[FloatingPane]]?
    var activeIndex: Int
}

// MARK: - Reading, migrating and writing the archive (spec v9 §3.2-§3.4)

/// The session archive (one per process, owned by `AppSession`).
/// What changed since 1.5.x: it is no longer "saved once, on quit" - a layout change, moving or
/// resizing a window, opening or closing a screen, and toggling fullscreen all call
/// `scheduleSave()` (debounced by 1.5s), and quitting writes once more synchronously.
@MainActor
final class SessionStore {
    /// Write debounce after a layout change (a burst of changes writes once)
    static let debounceInterval: TimeInterval = 1.5

    static var defaultURL: URL {
        EngineOverlay.url.deletingLastPathComponent().appendingPathComponent("state.json")
    }

    let url: URL
    /// Copy of the old archive kept before v5's first write (v5 cannot be downgraded to: an older
    /// build cannot read it, treats it as corrupt, and overwrites it with v4 on quit)
    var backupURL: URL { backupURL(forVersion: PersistedState.currentVersion - 1) }

    /// Copy of the previous session's archive, taken before this process's first write.
    /// This is the safety net: one bad launch (a directory permission denied, panes that failed to
    /// restore) overwrites the user's session at the very first save, and without this copy it is
    /// gone for good.
    var previousSessionURL: URL {
        url.deletingLastPathComponent().appendingPathComponent("state.previous.json")
    }

    /// Where a copy of "an archive written by a different version" goes:
    /// - an older version (< v5) always lands in `state.pre-v5.json` (the upgrade path only ever
    ///   produces one);
    /// - a newer version (> v5, which happens when the user rolls back to this build from a newer
    ///   one) gets its own `state.v<N>.json` per version number, so they never overwrite each
    ///   other - this build **refuses to read** a newer archive, and must certainly not silently
    ///   overwrite it.
    func backupURL(forVersion version: Int) -> URL {
        let name = version < PersistedState.currentVersion
            ? "state.pre-v\(PersistedState.currentVersion).json"
            : "state.v\(version).json"
        return url.deletingLastPathComponent().appendingPathComponent(name)
    }

    /// The screen registry (a strong reference: the registry holds no reference back to this
    /// object, so there is no cycle)
    private let screens: ScreenRegistry
    /// The test host never touches the user's real archive: writes are only allowed when a URL (in
    /// a temp directory) was injected explicitly.
    private let writesAllowed: Bool
    /// Snapshot source injected by tests (nil = take it from the registry)
    var snapshotOverride: (() -> PersistedState)?
    /// How many writes actually hit the disk (the counter the debounce tests assert on)
    private(set) var writeCount = 0
    /// How many debounced saves have been queued (the counter the trigger-point tests assert on;
    /// it is still counted in the test host, where nothing is written)
    private(set) var scheduleCount = 0
    private var pendingSave: DispatchWorkItem?
    private var didCheckBackup = false
    /// Whether this process has already taken its "previous session" copy (once per process)
    private var didCopyPreviousSession = false
    /// Restore in progress: the model is only half-built (the screens exist, the panes are not all
    /// filled in yet), and during that window we **never write** - one half-finished save truncates
    /// the user's session. `AppDelegate.restoreSession(from:)` brackets the whole stretch.
    private(set) var isRestoring = false

    init(screens: ScreenRegistry, url: URL? = nil) {
        self.screens = screens
        self.url = url ?? Self.defaultURL
        self.writesAllowed = url != nil || !AppDelegate.isRunningTests
    }

    // MARK: The restore gate

    /// Restore begins: every save queued in the meantime is dropped (`newScreen` queues one for
    /// each screen it creates).
    /// The one already in flight is cancelled too - it could otherwise land halfway through the
    /// restore.
    func beginRestore() {
        isRestoring = true
        pendingSave?.cancel()
        pendingSave = nil
    }

    /// Restore is done: writes resume. We deliberately do **not** save here - what is on disk is
    /// exactly what we just read in.
    func endRestore() {
        isRestoring = false
    }

    // MARK: Reading

    /// Read the archive and migrate it to v5. nil means there is no archive, it is corrupt, or it
    /// is entirely empty - in which case we start fresh, exactly as 1.5.x did.
    func load() -> PersistedState? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return Self.decode(data)
    }

    /// Version probe: read only `version` first, then pick the decoding path
    private struct VersionProbe: Codable { var version: Int? }

    /// Decode and migrate: v5 is read directly; v2-v4 is wrapped into `windows[0]` (with `display`
    /// and `frame` both nil, which keeps today's center-on-the-main-display behavior).
    /// Entirely empty windows are dropped; if none are left, return nil.
    ///
    /// The version has to match **exactly**: a newer version (v6+) is refused. Reading a v6 archive
    /// through the v5 shape is lossy - a pane kind this build does not know fails the decode of the
    /// whole window (`LossyWindow` then drops it), and 1.5s later the debounced save at startup
    /// writes the truncated result back. Better to start fresh and let
    /// `backupForeignArchiveIfNeeded` keep the original archive whole.
    static func decode(_ data: Data) -> PersistedState? {
        let version = (try? JSONDecoder().decode(VersionProbe.self, from: data))?.version ?? 0
        var state: PersistedState
        switch version {
        case PersistedState.currentVersion:
            guard let decoded = try? JSONDecoder().decode(PersistedState.self, from: data) else { return nil }
            state = decoded
        case 2...4:
            guard let legacy = try? JSONDecoder().decode(LegacyPersistedState.self, from: data) else { return nil }
            let window = WindowState(
                layouts: legacy.layouts, floatings: legacy.floatings, activeIndex: legacy.activeIndex)
            state = PersistedState(windows: [window], keyWindowID: window.id)
        default:
            return nil
        }
        state.windows.removeAll(where: \.isEmpty)
        guard !state.windows.isEmpty else { return nil }
        if let key = state.keyWindowID, !state.windows.contains(where: { $0.id == key }) {
            state.keyWindowID = state.windows.first?.id
        }
        return state
    }

    // MARK: Writing

    /// Debounced write: a burst of changes (dragging a column width, opening panes one after
    /// another, dragging the window) hits the disk once.
    func scheduleSave() {
        scheduleCount += 1
        guard writesAllowed, !isRestoring else { return }
        pendingSave?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.saveNow() }
        pendingSave = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.debounceInterval, execute: item)
    }

    /// Write synchronously, right now (`applicationWillTerminate`, or closing the last screen)
    func saveNow() {
        pendingSave?.cancel()
        pendingSave = nil
        guard writesAllowed, !isRestoring else { return }
        let state = snapshot()
        // Never write when there is no window left (all closed, or all torn down): that would
        // overwrite the user's session with an empty archive.
        guard !state.windows.isEmpty else { return }
        backupForeignArchiveIfNeeded()
        backupPreviousSessionIfNeeded()
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: url, options: .atomic)
        writeCount += 1
    }

    /// A snapshot of every screen right now (a screen that has been torn down does not go into the
    /// archive)
    func snapshot() -> PersistedState {
        if let snapshotOverride { return snapshotOverride() }
        let live = screens.controllers.filter { !$0.isClosed }
        // Use `current` rather than `key` here: when a sheet (a JS dialog, a file picker) or the
        // downloads popover is the key window, `screens.key` is nil, and falling back to primary
        // would record "the screen to bring forward next launch" as the first screen.
        let key = screens.current
        // Stacking order: orderedWindows is front to back. Minimized windows and ones not yet
        // ordered in are missing from it, so append them at the end.
        var stacking = NSApp.orderedWindows
            .compactMap { $0.windowController as? MainWindowController }
            .filter { !$0.isClosed }
            .map(\.windowID)
        stacking += live.map(\.windowID).filter { !stacking.contains($0) }
        return PersistedState(windows: live.map { $0.windowState() },
                              keyWindowID: key?.windowID,
                              stackingOrder: stacking)
    }

    /// Before the first write, keep a verbatim copy of "an archive written by a different version"
    /// (done once, and never overwriting an existing copy).
    /// For an old archive (v2-v4) it is a record of the upgrade; for a newer one (v6+) it is the
    /// safety net for a downgrade - this build refuses to read it, so it certainly must not
    /// overwrite it silently.
    private func backupForeignArchiveIfNeeded() {
        guard !didCheckBackup else { return }
        didCheckBackup = true
        guard let data = try? Data(contentsOf: url),
              let probe = try? JSONDecoder().decode(VersionProbe.self, from: data),
              let version = probe.version, version != PersistedState.currentVersion else { return }
        let backup = backupURL(forVersion: version)
        guard !FileManager.default.fileExists(atPath: backup.path) else { return }
        try? data.write(to: backup, options: .atomic)
    }

    /// Before this process's first write, keep what is on disk (= what this launch read in) as
    /// `state.previous.json`.
    /// Done once per process: every later debounced save is a continuation of the same session, so
    /// overwriting the copy with one of those would defeat the point.
    private func backupPreviousSessionIfNeeded() {
        guard !didCopyPreviousSession else { return }
        didCopyPreviousSession = true
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return }
        try? data.write(to: previousSessionURL, options: .atomic)
    }

    // MARK: Resolving the display and constraining the frame (spec v9 §3.3)

    /// Resolve the archived display identity back to an NSScreen: UUID first, then the name (only
    /// if it matches exactly one display), then nothing.
    /// A pure function with an injectable screen list, so tests can cover it.
    static func matchScreen(for ref: DisplayRef?, in screens: [NSScreen] = NSScreen.screens) -> NSScreen? {
        guard let ref else { return nil }
        if let uuid = ref.uuid,
           let hit = screens.first(where: { $0.displayUUID?.uuidString == uuid }) {
            return hit
        }
        if let name = ref.name {
            let named = screens.filter { $0.localizedName == name }
            if named.count == 1 { return named[0] }
        }
        return nil
    }

    /// Which display a restored window lands on: anything that does not resolve falls back to the
    /// main display - **a missing display never costs the user the window and its layout**.
    static func resolveScreen(for ref: DisplayRef?, in screens: [NSScreen] = NSScreen.screens) -> NSScreen? {
        matchScreen(for: ref, in: screens) ?? NSScreen.main
    }

    /// Fit a frame into the visible area: clamp the size first, then the position. This is the
    /// catch-all for an archive made on a larger display, a resolution change, and a display that
    /// is gone.
    static func constrain(_ frame: CGRect, into visible: CGRect) -> CGRect {
        var f = frame
        f.size.width = min(max(f.width, 200), visible.width)
        f.size.height = min(max(f.height, 150), visible.height)
        f.origin.x = min(max(f.minX, visible.minX), visible.maxX - f.width)
        f.origin.y = min(max(f.minY, visible.minY), visible.maxY - f.height)
        return f
    }
}
