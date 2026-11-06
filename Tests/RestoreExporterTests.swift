import AppKit
import XCTest
@testable import QuickTerm

/// `RestoreExporter`: which panes get a file at quit, how big it may be, and what is cleaned up.
/// Panes are real surfaces (never in a window); the engine read is replaced by a closure.
@MainActor
final class RestoreExporterTests: XCTestCase {
    private var dir: URL!
    private var store: RestoreStore!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("restore-export-\(UUID().uuidString)")
        store = RestoreStore(directory: dir, keyStore: MemoryRestoreKeyStore())
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    private func pane() throws -> Ghostty.SurfaceView {
        let appDelegate = try XCTUnwrap(NSApp.delegate as? AppDelegate)
        return Ghostty.SurfaceView(try XCTUnwrap(appDelegate.ghostty.app), baseConfig: nil)
    }

    private func content(_ pane: Ghostty.SurfaceView) -> Data {
        Data("screen of \(pane.id.uuidString)\r\n".utf8)
    }

    func testExportWritesOneFilePerPane() throws {
        let panes = [try pane(), try pane()]
        var asked: [Int] = []
        RestoreExporter.export(panes: panes, settings: ConfigStore.Settings(), store: store) { pane, lines in
            asked.append(lines)
            return self.content(pane)
        }
        XCTAssertEqual(asked, [5000, 5000], "the read asks for `[restore] lines` rows")
        XCTAssertEqual(store.files().count, 2)
        XCTAssertEqual(Set(store.files().map(\.pathExtension)), ["qtr"], "encrypted by default")
        for pane in panes {
            XCTAssertEqual(store.take(pane: pane.id), content(pane))
        }
    }

    func testPlainWhenEncryptionIsOff() throws {
        let only = try pane()
        var settings = ConfigStore.Settings()
        settings.restoreEncrypt = false
        settings.restoreLines = 123
        var asked = 0
        RestoreExporter.export(panes: [only], settings: settings, store: store) { pane, lines in
            asked = lines
            return self.content(pane)
        }
        XCTAssertEqual(asked, 123)
        XCTAssertEqual(store.files().map(\.pathExtension), ["vt"])
    }

    func testAlternateScreenPaneGetsNoFile() throws {
        let normal = try pane(), fullScreen = try pane()
        RestoreExporter.export(panes: [normal, fullScreen], settings: ConfigStore.Settings(),
                               store: store) { pane, _ in
            pane === fullScreen ? nil : self.content(pane)
        }
        XCTAssertEqual(store.files().count, 1)
        XCTAssertNil(store.take(pane: fullScreen.id))
        XCTAssertNotNil(store.take(pane: normal.id))
    }

    func testAlternateScreenDropsAnOlderFileForThatPane() throws {
        let fullScreen = try pane()
        try store.write(Data("old".utf8), pane: fullScreen.id, encrypt: true)
        RestoreExporter.export(panes: [fullScreen], settings: ConfigStore.Settings(), store: store) { _, _ in nil }
        XCTAssertTrue(store.files().isEmpty, "a pane that exported nothing keeps no stale content")
    }

    func testExportIsCappedAtTheByteLimit() throws {
        let only = try pane()
        // About 5 MiB of numbered lines; the last one is unique.
        var text = ""
        var i = 0
        while text.utf8.count < 5 * 1024 * 1024 {
            text += "line \(i) \(String(repeating: "x", count: 80))\r\n"
            i += 1
        }
        let lastLine = "the very last line \(i)\r\n"
        text += lastLine
        let input = Data(text.utf8)
        RestoreExporter.export(panes: [only], settings: ConfigStore.Settings(), store: store) { _, _ in input }
        let stored = try XCTUnwrap(store.take(pane: only.id), "a capped export must still be readable")
        XCTAssertLessThanOrEqual(stored.count, RestoreExporter.maxBytes)
        XCTAssertTrue(stored.count > RestoreExporter.maxBytes - 200, "only the head is dropped, not more")
        XCTAssertTrue(stored.suffix(lastLine.utf8.count).elementsEqual(Data(lastLine.utf8)),
                      "the tail is kept: the export ends with the input's last line")
        XCTAssertTrue(stored.starts(with: Data("line ".utf8)), "the cut lands on a line start")
    }

    func testExactlyMaxBytesIsReadable() throws {
        let only = try pane()
        let input = Data(repeating: UInt8(ascii: "a"), count: RestoreExporter.maxBytes)
        RestoreExporter.export(panes: [only], settings: ConfigStore.Settings(), store: store) { _, _ in input }
        XCTAssertEqual(store.take(pane: only.id), input)
    }

    func testExportPrunesClosedPanes() throws {
        let open = try pane()
        let closed = UUID()
        try store.write(Data("closed".utf8), pane: closed, encrypt: true)
        RestoreExporter.export(panes: [open], settings: ConfigStore.Settings(), store: store) { pane, _ in
            self.content(pane)
        }
        XCTAssertEqual(store.files().count, 1)
        XCTAssertNil(store.take(pane: closed))
        XCTAssertNotNil(store.take(pane: open.id))
    }

    func testContentOffRemovesEverything() throws {
        let only = try pane()
        try store.write(Data("old".utf8), pane: UUID(), encrypt: false)
        try store.write(Data("old".utf8), pane: only.id, encrypt: true)
        var settings = ConfigStore.Settings()
        settings.restoreContent = false
        var reads = 0
        RestoreExporter.export(panes: [only], settings: settings, store: store) { _, _ in
            reads += 1
            return Data("new".utf8)
        }
        XCTAssertEqual(reads, 0, "with content off nothing is read from the engine")
        XCTAssertTrue(store.files().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path), "the whole directory is gone")
    }

    /// Spec decision 11: the config apply path deletes at once when content is off, and leaves
    /// the store alone otherwise.
    func testApplyingContentOffDeletesImmediately() throws {
        try store.write(Data("old".utf8), pane: UUID(), encrypt: true)
        RestoreExporter.applyContentSetting(ConfigStore.Settings(), store: store)
        XCTAssertEqual(store.files().count, 1, "content on: nothing is touched")
        var off = ConfigStore.Settings()
        off.restoreContent = false
        RestoreExporter.applyContentSetting(off, store: store)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
    }

    /// Quitting by closing the last screen exports, then `applicationWillTerminate` runs with an
    /// empty model; the second call must not prune what the first one wrote.
    func testTheSessionExportsOncePerProcess() throws {
        let registry = ScreenRegistry()
        let session = AppSession(screens: registry, themeManager: ThemeManager(),
                                 stateURL: dir.appendingPathComponent("state.json"),
                                 restoreDirectory: dir)
        defer {
            session.controlServer.stop()
            // The session pointed the process-wide event bus at its own registry; hand it back.
            if let app = NSApp.delegate as? AppDelegate { ControlEventBus.shared.attach(screens: app.screens) }
        }
        let restoreStore = try XCTUnwrap(session.restoreStore, "an injected directory enables the store on a test host")
        try restoreStore.write(Data("stale".utf8), pane: UUID(), encrypt: false)
        session.exportRestoreContentOnce()
        XCTAssertTrue(session.restoreExported)
        XCTAssertTrue(restoreStore.files().isEmpty, "no panes open: the first export prunes the stale file")
        let kept = UUID()
        try restoreStore.write(Data("first export".utf8), pane: kept, encrypt: false)
        session.exportRestoreContentOnce()
        XCTAssertEqual(restoreStore.files().count, 1, "the second call is a no-op")
    }

    func testTheTestHostSessionHasNoStore() throws {
        let session = try XCTUnwrap((NSApp.delegate as? AppDelegate)?.session)
        XCTAssertNil(session.restoreStore, "the test host never touches the user's restore directory")
    }

    func testTrimmedTailHelper() {
        let data = Data("aaaa\nbbbb\ncccc\n".utf8)
        XCTAssertEqual(RestoreExporter.tail(data, maxBytes: 100), data, "under the cap: unchanged")
        XCTAssertEqual(RestoreExporter.tail(data, maxBytes: 7), Data("cccc\n".utf8), "cut after a newline")
        XCTAssertEqual(RestoreExporter.tail(Data("abcdefgh".utf8), maxBytes: 3), Data("fgh".utf8),
                       "no newline in the window: a plain byte cut")
    }
}
