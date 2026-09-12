import XCTest
import AppKit
@testable import QuickTerm

/// Session archive v5: multiple screens, display/frame restoration, and one-shot restore (spec v9 §3.6).
///
/// Every case here uses a state.json inside a **temporary directory**. None of them may touch the user's
/// real `~/Library/Application Support/QuickTerm/state.json` (in a test host `SessionStore` only writes
/// when a URL is injected explicitly, and the last case in this file guards that line).
@MainActor
final class SessionStateTests: XCTestCase {
    private var app: AppDelegate {
        get throws { try XCTUnwrap(NSApp.delegate as? AppDelegate) }
    }

    private var tempDirs: [URL] = []
    /// Keep-alive: `SessionStore` holds the registry, and the registry holds the controllers.
    private var registries: [ScreenRegistry] = []

    override func tearDown() {
        for dir in tempDirs { try? FileManager.default.removeItem(at: dir) }
        tempDirs.removeAll()
        registries.removeAll()
        super.tearDown()
    }

    private func spin(_ seconds: TimeInterval = 0.3) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    /// A state.json inside a temporary directory, one per case.
    private func tempStateURL() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("quickterm-session-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDirs.append(dir)
        let url = dir.appendingPathComponent("state.json")
        XCTAssertNotEqual(url, SessionStore.defaultURL, "a test must never write the user's real archive")
        return url
    }

    private func makeStore(at url: URL) -> SessionStore {
        let registry = ScreenRegistry()
        registries.append(registry)
        return SessionStore(screens: registry, url: url)
    }

    // MARK: v5 round trip: two screens

    /// Two screens (a terminal, a floating pane, a multi-tab browser) saved and read back: layouts,
    /// activeIndex, the floating layer, the terminal's pwd and the browser tab URLs all survive.
    func testV5RoundTripRestoresTwoWindows() throws {
        let c = try XCTUnwrap(try app.controller)
        let url = try tempStateURL()
        let store = makeStore(at: url)

        // Screen A: one terminal with a cwd, plus one floating terminal.
        let tiled = c.newSurface(workingDirectory: nil)
        tiled.pwd = "/usr/local/quickterm-test-a"
        let floated = c.newSurface(workingDirectory: nil)
        floated.pwd = "/usr/local/quickterm-test-float"
        let windowA = WindowState(
            layouts: [.scrolling(ScrollingStrip(pane: tiled, widthFactor: 0.5)), .empty],
            floatings: [[FloatingPane(pane: floated, rect: CGRect(x: 0.1, y: 0.2, width: 0.4, height: 0.5))], []],
            activeIndex: 0, visibleColumns: 3,
            display: DisplayRef(screen: NSScreen.main),
            frame: CGRect(x: 40, y: 60, width: 900, height: 600))

        // Screen B: one browser pane with three tabs, the second of them active.
        let browser = BrowserPaneView(url: URL(string: "about:blank"))
        browser.newTab(url: URL(string: "https://example.com/a"))
        browser.newTab(url: URL(string: "https://example.com/b"))
        browser.selectTab(at: 1)
        let windowB = WindowState(
            layouts: [.scrolling(ScrollingStrip(pane: browser, widthFactor: 0.5))],
            floatings: [[]], activeIndex: 0,
            frame: CGRect(x: 10, y: 20, width: 800, height: 500))

        store.snapshotOverride = { PersistedState(windows: [windowA, windowB], keyWindowID: windowB.id) }
        store.saveNow()

        let json = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(json.contains("quickterm-test-a"), "a terminal pane's cwd has to reach the archive; one-shot restore hinges on it")
        XCTAssertTrue(json.contains("quickterm-test-float"), "a floating terminal's cwd is archived too")

        let restored = try XCTUnwrap(store.load())
        XCTAssertEqual(restored.version, 5)
        XCTAssertEqual(restored.windows.count, 2, "both screens have to come back")
        XCTAssertEqual(restored.keyWindowID, windowB.id)

        let a = restored.windows[0]
        XCTAssertEqual(a.id, windowA.id)
        XCTAssertEqual(a.layouts.count, 2)
        XCTAssertEqual(a.activeIndex, 0)
        XCTAssertEqual(a.visibleColumns, 3)
        XCTAssertEqual(a.frame, CGRect(x: 40, y: 60, width: 900, height: 600))
        XCTAssertEqual(a.display?.uuid, NSScreen.main?.displayUUID?.uuidString)
        XCTAssertEqual(a.layouts[0].paneList.count, 1)
        XCTAssertEqual(a.floatings?[0].count, 1, "the floating layer comes back with its screen")
        XCTAssertEqual(a.floatings?[0].first?.rect, CGRect(x: 0.1, y: 0.2, width: 0.4, height: 0.5))
        XCTAssertTrue(a.layouts[0].paneList[0] is Ghostty.SurfaceView, "a terminal pane is still a terminal")

        let b = restored.windows[1]
        let decodedBrowser = try XCTUnwrap(b.layouts[0].paneList.first as? BrowserPaneView)
        XCTAssertEqual(decodedBrowser.tabs.count, 3, "every page the browser had open comes back")
        XCTAssertEqual(decodedBrowser.activeTabIndex, 1)
        XCTAssertEqual(decodedBrowser.tabs[1].lastRequestedURL?.absoluteString, "https://example.com/a")
        XCTAssertEqual(decodedBrowser.tabs[2].lastRequestedURL?.absoluteString, "https://example.com/b")
    }

    /// One-shot restore, end to end: pour an archive into a real new screen (a window built with
    /// restoring = true brings no starter terminal of its own).
    func testRestoreAppliesArchiveToRealScreen() throws {
        let app = try self.app
        let c = try XCTUnwrap(app.controller)
        let source = c.newSurface(workingDirectory: nil)
        source.pwd = "/usr/local/quickterm-restore"
        let browser = BrowserPaneView(url: URL(string: "https://example.com/restore"))
        let saved = WindowState(
            layouts: [.scrolling(ScrollingStrip(pane: source, widthFactor: 0.5)),
                      .scrolling(ScrollingStrip(pane: browser, widthFactor: 0.5))],
            floatings: [[], []], activeIndex: 1, visibleColumns: 2,
            display: DisplayRef(screen: NSScreen.main),
            frame: CGRect(x: 30, y: 40, width: 700, height: 480))
        // A JSON round trip hands us a different set of panes, which is how a real restore arrives.
        let data = try JSONEncoder().encode(PersistedState(windows: [saved], keyWindowID: saved.id))
        let decoded = try XCTUnwrap(SessionStore.decode(data)).windows[0]

        let screen = SessionStore.resolveScreen(for: decoded.display)
        let restored = app.newScreen(on: screen, restoring: true, id: decoded.id,
                                     restoredFrame: decoded.frame)
        defer {
            if app.controllers.contains(where: { $0 === restored }) { app.closeScreen(restored) }
            c.window?.makeKeyAndOrderFront(nil)
            spin()
        }
        XCTAssertTrue(restored.model.allPanes.isEmpty, "a restoring window must not bring a starter terminal")
        XCTAssertTrue(restored.restore(from: decoded))
        spin()
        XCTAssertEqual(restored.windowID, saved.id, "window identity survives across launches")
        XCTAssertEqual(restored.model.layouts.count, 2)
        XCTAssertEqual(restored.model.activeIndex, 1)
        XCTAssertEqual(restored.model.layouts[0].paneList.count, 1)
        XCTAssertTrue(restored.model.layouts[1].paneList.first is BrowserPaneView,
                      "the browser pane is restored into the workspace it came from")
        let frame = try XCTUnwrap(restored.window?.frame)
        let visible = try XCTUnwrap(screen?.visibleFrame)
        XCTAssertTrue(visible.insetBy(dx: -1, dy: -1).contains(frame),
                      "the restored frame has to land in the target display's visible area (\(frame) / \(visible))")

        // Save again: this screen's snapshot has to be self-consistent, id / display / frame included.
        let snapshot = restored.windowState()
        XCTAssertEqual(snapshot.id, saved.id)
        XCTAssertEqual(snapshot.activeIndex, 1)
        XCTAssertNotNil(snapshot.frame)
        XCTAssertEqual(snapshot.layouts.count, 2)
    }

    // MARK: Migration (v2-v4 -> v5) and the old-archive backup

    func testV4ArchiveMigratesIntoSingleWindowAndWritesBackup() throws {
        let c = try XCTUnwrap(try app.controller)
        let url = try tempStateURL()
        let pane = c.newSurface(workingDirectory: nil)
        pane.pwd = "/usr/local/quickterm-v4"
        let legacy = LegacyPersistedState(
            layouts: [.scrolling(ScrollingStrip(pane: pane, widthFactor: 0.5)), .empty],
            floatings: [[], []], activeIndex: 1)
        try JSONEncoder().encode(legacy).write(to: url, options: .atomic)

        let store = makeStore(at: url)
        let state = try XCTUnwrap(store.load())
        XCTAssertEqual(state.version, 5, "a v4 archive reads back as v5")
        XCTAssertEqual(state.windows.count, 1, "an old archive is a single screen")
        let window = state.windows[0]
        XCTAssertEqual(state.keyWindowID, window.id)
        XCTAssertNil(window.display, "an old archive carries no display info, so keep the historical center-on-main behavior")
        XCTAssertNil(window.frame)
        XCTAssertFalse(window.isFullscreen)
        XCTAssertEqual(window.activeIndex, 1)
        XCTAssertEqual(window.layouts.count, 2)
        XCTAssertEqual(window.layouts[0].paneList.count, 1, "pane for pane: the terminal in the layout is still there")
        XCTAssertTrue(window.layouts[0].paneList[0] is Ghostty.SurfaceView)
        XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).contains("quickterm-v4"))

        // Keep a copy of the old archive before the first v5 write; v5 cannot be downgraded.
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.backupURL.path))
        store.snapshotOverride = { state }
        store.saveNow()
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.backupURL.path), "after migration there has to be a state.pre-v5.json")
        let backup = try Data(contentsOf: store.backupURL)
        XCTAssertEqual((try JSONDecoder().decode(LegacyPersistedState.self, from: backup)).version, 4,
                       "the copy is the old archive, untouched")
        XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).contains("\"windows\""), "the new archive is a v5 envelope")
    }

    func testV2ArchiveWithoutFloatingsMigrates() throws {
        let c = try XCTUnwrap(try app.controller)
        let url = try tempStateURL()
        let pane = c.newSurface(workingDirectory: nil)
        pane.pwd = "/usr/local/quickterm-v2"
        let legacy = LegacyPersistedState(
            layouts: [.scrolling(ScrollingStrip(pane: pane, widthFactor: 0.5))],
            floatings: nil, activeIndex: 0)
        var raw = try JSONSerialization.jsonObject(with: try JSONEncoder().encode(legacy)) as! [String: Any]
        raw["version"] = 2
        raw.removeValue(forKey: "floatings")
        try JSONSerialization.data(withJSONObject: raw).write(to: url, options: .atomic)

        let state = try XCTUnwrap(makeStore(at: url).load())
        XCTAssertEqual(state.windows.count, 1)
        XCTAssertNil(state.windows[0].floatings, "v2 has no floatings field: it defaults, it must not fail to decode")
        XCTAssertEqual(state.windows[0].layouts[0].paneList.count, 1)
        XCTAssertFalse(state.windows[0].isEmpty)
    }

    // MARK: Display resolution and frame constraints

    func testDisplayRefResolution() throws {
        let main = try XCTUnwrap(NSScreen.main)
        let hit = DisplayRef(screen: main)
        XCTAssertNotNil(hit)
        XCTAssertEqual(SessionStore.matchScreen(for: hit), main, "matched by UUID")

        let byName = DisplayRef(uuid: UUID().uuidString, name: main.localizedName, frame: main.frame)
        let named = NSScreen.screens.filter { $0.localizedName == main.localizedName }
        if named.count == 1 {
            XCTAssertEqual(SessionStore.matchScreen(for: byName), main, "when the UUID misses, the name finds it")
        }

        let miss = DisplayRef(uuid: UUID().uuidString, name: "QuickTerm nonexistent display", frame: .zero)
        XCTAssertNil(SessionStore.matchScreen(for: miss), "nothing matches -> no screen")
        XCTAssertEqual(SessionStore.resolveScreen(for: miss), NSScreen.main, "fall back to the main screen; never lose a window")
        XCTAssertEqual(SessionStore.resolveScreen(for: nil), NSScreen.main, "an old archive has no display info -> the main screen")
    }

    func testFrameIsConstrainedIntoVisibleArea() {
        let visible = CGRect(x: 0, y: 0, width: 1440, height: 900)
        // Archived while on another display, further out and larger.
        let offscreen = SessionStore.constrain(CGRect(x: 3000, y: 1800, width: 1000, height: 700), into: visible)
        XCTAssertTrue(visible.contains(offscreen), "an offscreen frame has to be pulled back into the visible area: \(offscreen)")
        XCTAssertEqual(offscreen.size, CGSize(width: 1000, height: 700), "if moving it is enough, the size is left alone")

        let oversized = SessionStore.constrain(CGRect(x: -500, y: -500, width: 4000, height: 3000), into: visible)
        XCTAssertEqual(oversized, visible, "larger than the screen -> shrunk to the whole visible area")

        let inside = CGRect(x: 100, y: 80, width: 800, height: 600)
        XCTAssertEqual(SessionStore.constrain(inside, into: visible), inside, "already inside -> unchanged")

        // A visible area whose origin is not zero: an external display to the right of the main one.
        let right = CGRect(x: 1440, y: 0, width: 1920, height: 1080)
        let moved = SessionStore.constrain(CGRect(x: 0, y: 0, width: 800, height: 600), into: right)
        XCTAssertTrue(right.contains(moved))
    }

    // MARK: When it writes

    /// Ten changes in a row produce a single write (a 1.5s debounce).
    func testDebouncedSaveWritesOnce() throws {
        let url = try tempStateURL()
        let store = makeStore(at: url)
        store.snapshotOverride = { PersistedState(windows: [WindowState(layouts: [.empty])]) }
        for _ in 0..<10 { store.scheduleSave() }
        XCTAssertEqual(store.writeCount, 0, "nothing is written during the debounce")
        spin(SessionStore.debounceInterval + 0.8)
        XCTAssertEqual(store.writeCount, 1, "a burst of changes writes once")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    /// The quit path writes synchronously and does not wait out the debounce.
    func testSaveNowWritesSynchronously() throws {
        let url = try tempStateURL()
        let store = makeStore(at: url)
        store.snapshotOverride = { PersistedState(windows: [WindowState(layouts: [.empty])]) }
        store.scheduleSave()
        store.saveNow()
        XCTAssertEqual(store.writeCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "saveNow has to hit the disk immediately")
        spin(SessionStore.debounceInterval + 0.5)
        XCTAssertEqual(store.writeCount, 1, "saveNow cancels the pending debounced write")
    }

    /// Never write when there is no window at all, or closing the last screen would overwrite the user's
    /// session with an empty archive.
    func testEmptySnapshotNeverOverwritesArchive() throws {
        let url = try tempStateURL()
        let store = makeStore(at: url)
        store.snapshotOverride = { PersistedState(windows: []) }
        store.saveNow()
        XCTAssertEqual(store.writeCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    // MARK: Missing or corrupt archive -> start fresh

    func testMissingOrCorruptArchiveStartsFresh() throws {
        let url = try tempStateURL()
        XCTAssertNil(makeStore(at: url).load(), "no archive -> start fresh")

        try Data("this is not JSON".utf8).write(to: url, options: .atomic)
        XCTAssertNil(makeStore(at: url).load(), "a corrupt archive -> start fresh")

        try Data(#"{"version":99,"windows":[]}"#.utf8).write(to: url, options: .atomic)
        XCTAssertNil(makeStore(at: url).load(), "an empty window list -> start fresh")

        // A completely empty window, with no panes at all, must not open an empty window.
        let empty = PersistedState(windows: [WindowState(layouts: [.empty, .empty], floatings: [[], []])])
        try JSONEncoder().encode(empty).write(to: url, options: .atomic)
        XCTAssertNil(makeStore(at: url).load(), "an entirely empty archive -> start fresh, as in 1.5.x")
    }

    /// One broken screen in the archive must not take the others down with it (lenient decoding).
    func testBrokenWindowDoesNotDropTheOthers() throws {
        let c = try XCTUnwrap(try app.controller)
        let url = try tempStateURL()
        let good = WindowState(layouts: [.scrolling(ScrollingStrip(pane: c.newSurface(workingDirectory: nil),
                                                                  widthFactor: 0.5))],
                               floatings: [[]], activeIndex: 0)
        let data = try JSONEncoder().encode(PersistedState(windows: [good], keyWindowID: good.id))
        var raw = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        var windows = raw["windows"] as! [[String: Any]]
        var broken = windows[0]
        broken["id"] = UUID().uuidString
        broken["layouts"] = ["this is not a layout"]   // The broken screen
        windows.append(broken)
        raw["windows"] = windows
        try JSONSerialization.data(withJSONObject: raw).write(to: url, options: .atomic)

        let state = try XCTUnwrap(makeStore(at: url).load())
        XCTAssertEqual(state.windows.count, 1, "the broken window is dropped and the good one still restores")
        XCTAssertEqual(state.windows[0].id, good.id)
        XCTAssertEqual(state.keyWindowID, good.id)
    }

    // MARK: A newer archive (downgrade safety)

    /// An archive written by a newer version (v6+): this version **refuses to read it**, and keeps a
    /// byte-for-byte copy before its first write. The regression is "running an old build once permanently
    /// truncates and downgrades a newer session": read in the v5 shape, a pane kind this version does not
    /// know makes the whole window fail to decode and get dropped, and 1.5s after launch that loss is written back.
    func testNewerArchiveIsRefusedAndBackedUpBeforeOverwrite() throws {
        let c = try XCTUnwrap(try app.controller)
        let url = try tempStateURL()
        let good = WindowState(
            layouts: [.scrolling(ScrollingStrip(pane: c.newSurface(workingDirectory: nil), widthFactor: 0.5))],
            floatings: [[]], activeIndex: 0)
        let goodJSON = try XCTUnwrap(String(data: try JSONEncoder().encode(good), encoding: .utf8))
        // The second window carries a pane kind this version does not know, something only a future version has.
        let futureJSON = goodJSON
            .replacingOccurrences(of: #""kind":"terminal""#, with: #""kind":"quickterm-future-pane""#)
            .replacingOccurrences(of: good.id.uuidString, with: UUID().uuidString)
        XCTAssertNotEqual(futureJSON, goodJSON, "the fixture really has to carry a pane kind this version does not know")
        let future = PersistedState.currentVersion + 1
        let original = Data(#"{"version":\#(future),"windows":[\#(goodJSON),\#(futureJSON)]}"#.utf8)
        try original.write(to: url, options: .atomic)

        let store = makeStore(at: url)
        XCTAssertNil(store.load(), "a newer archive is always refused, never truncated into the v5 shape")

        // After the refusal a new session starts and writes as usual: the original has to be backed up in full first.
        store.snapshotOverride = { PersistedState(windows: [WindowState(layouts: [.empty])]) }
        store.saveNow()
        let backup = store.backupURL(forVersion: future)
        XCTAssertEqual(backup.lastPathComponent, "state.v\(future).json")
        XCTAssertNotEqual(backup, store.backupURL, "the newer-archive copy must not collide with the pre-v5 copy")
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path), "a copy has to exist before anything is overwritten")
        XCTAssertEqual(try Data(contentsOf: backup), original, "the copy is byte-for-byte the original")
        XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).contains(#""version":\#(PersistedState.currentVersion)"#))
    }

    // MARK: Archiving a terminal's cwd

    /// A debounced save that lands before the shell has sent OSC 7 (a slow-starting zsh, or a restore that
    /// brings up a pile of panes at once) must never write a known start directory as null: that is exactly
    /// what gets lost after a crash or a force quit.
    func testArchivedCwdSurvivesSaveBeforeShellReportsPwd() throws {
        let c = try XCTUnwrap(try app.controller)
        let url = try tempStateURL()
        let seed = url.deletingLastPathComponent().path   // A directory that really exists
        let store = makeStore(at: url)
        let pane = c.newSurface(workingDirectory: seed)
        XCTAssertNil(pane.pwd, "before OSC 7, pwd is simply nil")
        let window = WindowState(layouts: [.scrolling(ScrollingStrip(pane: pane, widthFactor: 0.5))],
                                 floatings: [[]], activeIndex: 0)
        store.snapshotOverride = { PersistedState(windows: [window]) }
        store.saveNow()

        let json = try String(contentsOf: url, encoding: .utf8)
        // JSONEncoder escapes "/" as "\/", so assert on the directory name, which carries no separator.
        XCTAssertTrue(json.contains(url.deletingLastPathComponent().lastPathComponent),
                      "the archive falls back to the start directory it was created with")
        XCTAssertFalse(json.contains(#""pwd":null"#), "a known cwd must never be written as null")
        let restored = try XCTUnwrap(SessionStore.decode(Data(json.utf8)))
        let decoded = try XCTUnwrap(restored.windows[0].layouts[0].paneList.first as? Ghostty.SurfaceView)
        XCTAssertEqual(decoded.workingDirectory, seed, "the restored terminal comes back in the same directory")
    }

    /// A `cd` (OSC 7) has to schedule a save of its own, or a long session whose layout never changes comes
    /// back in the old directory after a crash.
    func testTerminalCwdChangeSchedulesSave() throws {
        let app = try self.app
        let primary = try XCTUnwrap(app.controller)
        let store = try XCTUnwrap(app.session).sessionStore
        let screen = app.newScreen()
        defer {
            if app.controllers.contains(where: { $0 === screen }) { app.closeScreen(screen) }
            primary.window?.makeKeyAndOrderFront(nil)
            spin()
        }
        spin()
        let pane = try XCTUnwrap(screen.model.allPanes.first as? Ghostty.SurfaceView)
        let before = store.scheduleCount
        pane.pwd = "/usr/local/quickterm-cd"
        XCTAssertGreaterThan(store.scheduleCount, before, "a cd has to schedule a save")
        let repeated = store.scheduleCount
        pane.pwd = "/usr/local/quickterm-cd"   // Most shells send OSC 7 at every prompt
        XCTAssertEqual(store.scheduleCount, repeated, "the same directory reported again schedules nothing")
    }

    // MARK: Snapshotting is read-only

    /// Saves are driven by a debounce timer, so taking a snapshot must not change anything on screen: a pane
    /// that is fading out is filtered out of the copy while its animation keeps playing (1.5.x only
    /// snapshotted on quit, where flushing it did not matter).
    func testSnapshotFiltersFadingPanesWithoutCuttingTheAnimation() throws {
        let c = try XCTUnwrap(try app.controller)
        let prevAnim = c.closeAnimationEnabled
        let home = c.model.activeIndex
        let ws = c.model.layouts.count - 1
        c.model.switchTo(ws)
        defer {
            // The last workspace has to be handed back: other cases take it as their "empty workspace" fixture.
            for pane in c.paneList { c.closePane(pane, confirmIfNeeded: false, animated: false) }
            c.closeAnimationEnabled = prevAnim
            c.model.switchTo(home)
        }
        XCTAssertTrue(c.model.layout.isEmpty, "the last workspace should be empty")
        c.closeAnimationEnabled = true
        spin(0.2)
        c.perform(.newTerminal)
        let a = try XCTUnwrap(c.paneList.first)
        spin(0.5)
        c.perform(.newTerminal)
        let b = try XCTUnwrap(c.paneList.first { $0 !== a })
        spin(0.6)

        c.closePane(b, confirmIfNeeded: false)
        XCTAssertTrue(c.model.closingPanes.contains(b.id))
        let snapshot = c.windowState()
        XCTAssertEqual(snapshot.layouts[ws].paneList.count, 1, "a pane that is fading out does not enter the archive")
        XCTAssertFalse(snapshot.layouts[ws].paneList.contains { $0 === b })
        XCTAssertEqual(c.paneList.count, 2, "a snapshot must not cut the close animation short")
        XCTAssertTrue(c.model.closingPanes.contains(b.id), "the fading state is not touched by the snapshot")
        spin(0.5)
        XCTAssertEqual(c.paneList.count, 1, "once the animation is done it is removed as usual")
    }

    // MARK: New envelope fields: the focused pane and the stacking order

    func testFocusedPaneAndStackingOrderRoundTrip() throws {
        let c = try XCTUnwrap(try app.controller)
        let pane = c.newSurface(workingDirectory: nil)
        let window = WindowState(layouts: [.scrolling(ScrollingStrip(pane: pane, widthFactor: 0.5))],
                                 floatings: [[]], activeIndex: 0, focusedPaneID: pane.id)
        let other = UUID()
        let data = try JSONEncoder().encode(
            PersistedState(windows: [window], keyWindowID: window.id, stackingOrder: [other, window.id]))
        let restored = try XCTUnwrap(SessionStore.decode(data))
        XCTAssertEqual(restored.windows[0].focusedPaneID, pane.id)
        XCTAssertEqual(restored.stackingOrder, [other, window.id])

        // Older v5 archives have neither key: read them as absent and fall back to the historical behavior.
        var raw = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        raw.removeValue(forKey: "stackingOrder")
        var windows = raw["windows"] as! [[String: Any]]
        windows[0].removeValue(forKey: "focusedPaneID")
        raw["windows"] = windows
        let legacy = try XCTUnwrap(SessionStore.decode(try JSONSerialization.data(withJSONObject: raw)))
        XCTAssertNil(legacy.stackingOrder)
        XCTAssertNil(legacy.windows[0].focusedPaneID)
    }

    // MARK: The entry point for one-shot restore

    /// `restoreSession(from:)`: build a screen per window, pour the archive in, bring it forward. A window
    /// whose display is gone falls back to the main screen, and the archive's key screen is fronted last.
    func testRestoreSessionRebuildsEveryScreen() throws {
        let app = try self.app
        let primary = try XCTUnwrap(app.controller)
        let before = app.controllers.count
        let terminal = primary.newSurface(workingDirectory: nil)
        terminal.pwd = "/usr/local/quickterm-restore-session"
        let browser = BrowserPaneView(url: URL(string: "https://example.com/session"))
        // Screen A: the display named in the archive is gone, so it falls back to the main screen and the
        // window is never lost.
        let a = WindowState(
            layouts: [.scrolling(ScrollingStrip(pane: terminal, widthFactor: 0.5))],
            floatings: [[]], activeIndex: 0,
            display: DisplayRef(uuid: UUID().uuidString, name: "QuickTerm nonexistent display", frame: .zero))
        // Screen B: the key screen recorded in the archive.
        let b = WindowState(layouts: [.scrolling(ScrollingStrip(pane: browser, widthFactor: 0.5))],
                            floatings: [[]], activeIndex: 0)
        let data = try JSONEncoder().encode(
            PersistedState(windows: [a, b], keyWindowID: b.id, stackingOrder: [b.id, a.id]))
        let state = try XCTUnwrap(SessionStore.decode(data))

        let restored = app.restoreSession(from: state)
        defer {
            for controller in restored where app.controllers.contains(where: { $0 === controller }) {
                app.closeScreen(controller)
            }
            primary.window?.makeKeyAndOrderFront(nil)
            spin()
        }
        spin()
        XCTAssertEqual(restored.count, 2, "every screen in the archive has to come back")
        XCTAssertEqual(app.controllers.count, before + 2)
        XCTAssertEqual(restored[0].windowID, a.id)
        XCTAssertEqual(restored[1].windowID, b.id)
        XCTAssertEqual(restored[0].window?.screen, NSScreen.main, "display gone -> fall back to the main screen")
        XCTAssertEqual(restored[0].model.layouts[0].paneList.count, 1)
        XCTAssertTrue(restored[0].model.layouts[0].paneList[0] is Ghostty.SurfaceView)
        XCTAssertTrue(restored[1].model.layouts[0].paneList.first is BrowserPaneView,
                      "the browser pane comes back with the pages it had open")
        // A test host is not guaranteed to get key (see ScreenRegistryTests), so only assert the target if it did.
        if NSApp.keyWindow === restored[1].window { XCTAssertTrue(app.controller === restored[1]) }
    }

    /// When not one screen can be built, because every window in the archive is empty, fall back to opening
    /// a single new screen: never end up with zero windows.
    func testRestoreSessionFallsBackToOneScreen() throws {
        let app = try self.app
        let primary = try XCTUnwrap(app.controller)
        let before = app.controllers.count
        let restored = app.restoreSession(from: PersistedState(windows: []))
        defer {
            for controller in restored where app.controllers.contains(where: { $0 === controller }) {
                app.closeScreen(controller)
            }
            primary.window?.makeKeyAndOrderFront(nil)
            spin()
        }
        spin()
        XCTAssertEqual(restored.count, 1)
        XCTAssertEqual(app.controllers.count, before + 1)
        XCTAssertEqual(restored[0].model.allPanes.count, 1, "the fallback screen brings a starter terminal")
    }

    // MARK: The safety line: a test host never writes the app's real archive

    func testAppSessionStoreNeverWritesRealArchiveUnderTests() throws {
        let store = try XCTUnwrap(try app.session).sessionStore
        XCTAssertEqual(store.url, SessionStore.defaultURL)
        store.scheduleSave()
        store.saveNow()
        spin(SessionStore.debounceInterval + 0.5)
        XCTAssertEqual(store.writeCount, 0, "a test host must never write the user's state.json")
    }
}
