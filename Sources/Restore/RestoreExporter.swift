import Foundation

/// **Quit-time export of every terminal pane's screen** (session restore, spec decisions 1, 2, 4, 7).
///
/// One file per pane that returned content, then every other file is pruned, so the store only
/// ever holds content for panes that were open at this quit. A pane on the alternate screen
/// returns nothing from the engine and therefore keeps no file. With `[restore] content = false`
/// nothing is read and the whole store is removed.
@MainActor
enum RestoreExporter {
    /// The content cap per pane. `RestoreStore.maxFileBytes` adds the encryption overhead on top,
    /// so an export of exactly this size still reads back.
    static let maxBytes = 4 * 1024 * 1024

    /// `read` is the engine call (`Ghostty.SurfaceView.exportVT`), injected for tests: it gets the
    /// pane and `[restore] lines` and returns nil when there is nothing to keep.
    static func export(panes: [Ghostty.SurfaceView], settings: ConfigStore.Settings,
                       store: RestoreStore, read: (Ghostty.SurfaceView, Int) -> Data?) {
        guard settings.restoreContent else {
            store.removeAll()
            return
        }
        var exported = Set<UUID>()
        for pane in panes {
            guard let data = read(pane, settings.restoreLines), !data.isEmpty else { continue }
            do {
                try store.write(tail(data, maxBytes: maxBytes), pane: pane.id,
                                encrypt: settings.restoreEncrypt)
                exported.insert(pane.id)
            } catch {
                DiagnosticLog.shared.note("restore", "export of \(pane.id.uuidString.prefix(8)) failed: \(error)")
            }
        }
        store.prune(keeping: exported)
    }

    /// Spec decision 11: turning content off deletes what is stored at once, not at the next quit.
    static func applyContentSetting(_ settings: ConfigStore.Settings, store: RestoreStore) {
        if !settings.restoreContent { store.removeAll() }
    }

    /// The last `maxBytes` of `data`, starting on a line: the oldest part is dropped, and the cut
    /// moves forward past the first newline so it never lands inside a line, an escape sequence
    /// or a UTF-8 character. A window with no newline at all is cut at the byte.
    static func tail(_ data: Data, maxBytes: Int) -> Data {
        guard data.count > maxBytes else { return data }
        let start = data.endIndex - maxBytes
        let newline = UInt8(ascii: "\n")
        // Already on a line start: nothing to skip.
        if data[start - 1] == newline { return Data(data[start...]) }
        guard let cut = data[start...].firstIndex(of: newline) else { return Data(data[start...]) }
        return Data(data[(cut + 1)...])
    }

    /// Every terminal pane on every screen and workspace, tiled and floating; not browser panes,
    /// not the scratchpad, and not a pane that is already fading out (it has been closed).
    static func terminalPanes(of controllers: [MainWindowController]) -> [Ghostty.SurfaceView] {
        controllers.flatMap { controller in
            controller.model.allPanes
                .compactMap { $0 as? Ghostty.SurfaceView }
                .filter { $0 !== controller.model.scratchpadSurface
                    && !controller.model.closingPanes.contains($0.id) }
        }
    }
}
