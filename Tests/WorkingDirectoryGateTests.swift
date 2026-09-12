import XCTest
import AppKit
@testable import QuickTerm

/// Regression line for the launch hang (2026-09-11):
/// when a terminal's archived cwd sits inside a TCC-protected directory (~/Desktop ~/Documents
/// ~/Downloads) and the binary was started by LaunchServices without that grant, the `openat` that
/// libghostty performs inside `ghostty_surface_new` **never** returns: the whole app wedges in
/// `applicationDidFinishLaunching` and not one window comes up.
///
/// These cases move that environment into the suite with a probe that never answers: restore still has
/// to build every pane, and still has to come back in time.
/// (TCC itself cannot be simulated in a unit test; the `open`-launch half is checked by hand, see
/// docs/manual-launch-check.md.)
@MainActor
final class WorkingDirectoryGateTests: XCTestCase {
    private var app: AppDelegate {
        get throws { try XCTUnwrap(NSApp.delegate as? AppDelegate) }
    }

    private var tempDirs: [URL] = []
    private var registries: [ScreenRegistry] = []
    /// Process-wide globals the AppSession built in this file stomps on (`apply` resets them to defaults).
    private var savedBrowserSettings: BrowserPaneView.Settings?
    private var savedBrowserExtensions: Bool?
    private var savedSocketPath: String?
    private var restoreGlobals = false

    override func tearDown() {
        WorkingDirectoryGate.resetForTesting()
        for dir in tempDirs { try? FileManager.default.removeItem(at: dir) }
        tempDirs.removeAll()
        registries.removeAll()
        if restoreGlobals {
            // The AppSession built here points the event bus at its own registry, which is about to be
            // deallocated. The bus holds it weakly, so without reattaching, every later case in this
            // class would be talking to a dead bus.
            if let app = NSApp.delegate as? AppDelegate {
                ControlEventBus.shared.attach(screens: app.screens)
            }
            if let savedBrowserSettings { BrowserPaneView.settings = savedBrowserSettings }
            if let savedBrowserExtensions { BrowserExtensionManager.shared.isEnabled = savedBrowserExtensions }
            ControlEnvironment.socketPath = savedSocketPath
            restoreGlobals = false
        }
        super.tearDown()
    }

    /// What a pane looks like in the archive (hand-built JSON: decoding is the exact path launch restore takes).
    private func paneJSON(pwd: String?, uuid: UUID = UUID()) -> Data {
        let pwdField = pwd.map { "\"\($0)\"" } ?? "null"
        return Data("""
        {"pwd": \(pwdField), "uuid": "\(uuid.uuidString)", "title": "t", "isUserSetTitle": false}
        """.utf8)
    }

    /// Read the cwd back out of an archived pane.
    private func archivedPwd(_ data: Data) throws -> String? {
        struct Probe: Decodable { let pwd: String? }
        return try JSONDecoder().decode(Probe.self, from: data).pwd
    }

    /// A probe that never answers, which is what TCC does to an unauthorized binary launched by LaunchServices.
    private func denyProtectedRoots() {
        WorkingDirectoryGate.resetForTesting()
        WorkingDirectoryGate.deadline = 0.05
        WorkingDirectoryGate.prober = { _, deadline in
            Thread.sleep(forTimeInterval: deadline)
            return false
        }
    }

    private func spin(_ seconds: TimeInterval = 0.3) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private var home: String { NSHomeDirectory() }

    // MARK: The gate itself

    /// Only the three protected roots need probing; every other path (~ itself, ~/Library, /tmp) passes through.
    func testProtectedRootClassification() {
        let home = "/Users/probe"
        XCTAssertEqual(WorkingDirectoryGate.protectedRoot(for: "\(home)/Documents", home: home),
                       "\(home)/Documents")
        XCTAssertEqual(WorkingDirectoryGate.protectedRoot(for: "\(home)/Documents/a/b", home: home),
                       "\(home)/Documents")
        XCTAssertEqual(WorkingDirectoryGate.protectedRoot(for: "\(home)/Desktop/x", home: home),
                       "\(home)/Desktop")
        XCTAssertEqual(WorkingDirectoryGate.protectedRoot(for: "\(home)/Downloads", home: home),
                       "\(home)/Downloads")
        XCTAssertNil(WorkingDirectoryGate.protectedRoot(for: home, home: home))
        XCTAssertNil(WorkingDirectoryGate.protectedRoot(for: "\(home)/Library/Caches", home: home))
        XCTAssertNil(WorkingDirectoryGate.protectedRoot(for: "/tmp", home: home))
        XCTAssertNil(WorkingDirectoryGate.protectedRoot(for: "/usr/local", home: home),
                     "a similar prefix is not a subdirectory: Documents2 and friends must not be misread")
        XCTAssertNil(WorkingDirectoryGate.protectedRoot(for: "\(home)/Documents2", home: home))
    }

    /// A probe that does not get through returns nil, leaving the engine's default directory, and each root
    /// is probed only once.
    func testUnansweredProbeFallsBackAndIsMemoised() {
        var probed: [String] = []
        WorkingDirectoryGate.resetForTesting()
        WorkingDirectoryGate.deadline = 0.05
        WorkingDirectoryGate.prober = { root, deadline in
            probed.append(root)
            Thread.sleep(forTimeInterval: deadline)   // Never answers: sleep until the deadline
            return false
        }
        XCTAssertNil(WorkingDirectoryGate.usable("\(home)/Documents/quickterm"))
        XCTAssertNil(WorkingDirectoryGate.usable("\(home)/Documents/another/deep/path"))
        XCTAssertEqual(probed, ["\(home)/Documents"], "the same root pays for the probe only once")

        // A path that passes through is never probed at all.
        XCTAssertEqual(WorkingDirectoryGate.usable("/tmp/x"), "/tmp/x")
        XCTAssertNil(WorkingDirectoryGate.usable(nil))
        XCTAssertEqual(probed.count, 1)
    }

    /// A probe that gets through passes the path along verbatim. This is the release build with the grant
    /// in place, behaving exactly as it did before the fix.
    func testAnsweredProbePassesThrough() {
        WorkingDirectoryGate.resetForTesting()
        WorkingDirectoryGate.prober = { _, _ in true }
        let path = "\(home)/Documents/quickterm"
        XCTAssertEqual(WorkingDirectoryGate.usable(path), path)
    }

    /// The default probe is instantaneous on a directory it can open (/tmp as the baseline, no protected
    /// directory touched).
    func testDefaultProberOpensReachableDirectory() {
        XCTAssertTrue(WorkingDirectoryGate.probeByOpening("/tmp", 1.0))
        XCTAssertFalse(WorkingDirectoryGate.probeByOpening("/quickterm-no-such-dir", 1.0))
    }

    // MARK: The real restore path (this is the coverage that was missing)

    /// A realistic archive: two screens, five workspaces each, several terminals whose cwds all live under
    /// ~/Documents, and a browser pane with several tabs. Restore it in an environment where the probe never
    /// answers: every pane still has to be built,
    /// and the whole thing has to return on the order of the timeout (before the fix it never returned).
    func testRestoreWithUnansweredProbeStillBuildsEveryPane() throws {
        let app = try self.app
        let primary = try XCTUnwrap(app.controller)
        let docs = "\(home)/Documents"

        // The archive: screen A = 3 terminals (two tiled, one floating), screen B = 1 terminal + a browser
        // with three tabs.
        var terminals: [Ghostty.SurfaceView] = []
        func terminal(_ suffix: String) -> Ghostty.SurfaceView {
            let pane = primary.newSurface(workingDirectory: nil)
            pane.pwd = "\(docs)/\(suffix)"
            terminals.append(pane)
            return pane
        }
        let a1 = terminal("workspace/quickterm")
        let a2 = terminal("notes")
        let aFloat = terminal("scratch")
        let windowA = WindowState(
            layouts: [.scrolling(ScrollingStrip(pane: a1, widthFactor: 0.5)),
                      .scrolling(ScrollingStrip(pane: a2, widthFactor: 0.5)),
                      .empty, .empty, .empty],
            floatings: [[FloatingPane(pane: aFloat,
                                      rect: CGRect(x: 0.1, y: 0.1, width: 0.4, height: 0.4))],
                        [], [], [], []],
            activeIndex: 0, visibleColumns: 2,
            display: DisplayRef(screen: NSScreen.main),
            frame: CGRect(x: 40, y: 60, width: 900, height: 600))

        let b1 = terminal("workspace/other")
        let browser = BrowserPaneView(url: URL(string: "https://example.com/tab0"))
        browser.newTab(url: URL(string: "https://example.com/tab1"))
        browser.newTab(url: URL(string: "https://example.com/tab2"))
        browser.selectTab(at: 1)
        let windowB = WindowState(
            layouts: [.scrolling(ScrollingStrip(pane: b1, widthFactor: 0.5)),
                      .scrolling(ScrollingStrip(pane: browser, widthFactor: 0.5)),
                      .empty, .empty, .empty],
            floatings: [[], [], [], [], []], activeIndex: 1,
            frame: CGRect(x: 10, y: 20, width: 800, height: 500))

        let data = try JSONEncoder().encode(
            PersistedState(windows: [windowA, windowB], keyWindowID: windowB.id,
                           stackingOrder: [windowB.id, windowA.id]))
        for pane in terminals { pane.removeFromSuperview() }

        // The environment where TCC never answers. The gate is paid for during **decoding**:
        // `SessionStore.decode` already constructs every pane for real (a terminal means spawning a shell),
        // and that is precisely the stretch that hung at launch.
        // So the stub has to be installed before decode, and the timing has to bracket decode as well.
        var probeCount = 0
        WorkingDirectoryGate.resetForTesting()
        WorkingDirectoryGate.deadline = 0.05
        WorkingDirectoryGate.prober = { _, deadline in
            probeCount += 1
            Thread.sleep(forTimeInterval: deadline)
            return false
        }

        // A real restore comes out of JSON: run the whole decode, so these panes are freshly constructed ones.
        let started = Date()
        let state = try XCTUnwrap(SessionStore.decode(data))
        let restored = app.restoreSession(from: state)
        let elapsed = Date().timeIntervalSince(started)
        defer {
            for controller in restored where app.controllers.contains(where: { $0 === controller }) {
                app.closeScreen(controller)
            }
            primary.window?.makeKeyAndOrderFront(nil)
            spin()
        }
        spin()

        XCTAssertEqual(restored.count, 2, "both screens have to come back")
        XCTAssertEqual(restored[0].model.allPanes.count, 3, "screen A: two tiled terminals plus one floating")
        XCTAssertEqual(restored[1].model.allPanes.count, 2, "screen B: one terminal plus one browser")
        XCTAssertTrue(restored[0].model.layouts[0].paneList.first is Ghostty.SurfaceView)
        let decodedBrowser = try XCTUnwrap(
            restored[1].model.layouts[1].paneList.first as? BrowserPaneView)
        XCTAssertEqual(decodedBrowser.tabs.count, 3, "the browser pane keeps every tab")
        XCTAssertEqual(decodedBrowser.activeTabIndex, 1)
        XCTAssertEqual(probeCount, 1, "four terminals share a single ~/Documents probe")
        XCTAssertLessThan(elapsed, 5, "restore has to return promptly: before the fix it never returned")
    }

    /// Never write to disk while restoring: landing half a model on disk truncates the user's session.
    func testNoSaveLandsWhileRestoring() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("quickterm-gate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDirs.append(dir)
        let url = dir.appendingPathComponent("state.json")
        XCTAssertNotEqual(url, SessionStore.defaultURL)
        let registry = ScreenRegistry()
        registries.append(registry)
        let store = SessionStore(screens: registry, url: url)
        store.snapshotOverride = { PersistedState(windows: [WindowState(layouts: [.empty],
                                                                        floatings: [[]],
                                                                        activeIndex: 0)]) }

        store.beginRestore()
        store.scheduleSave()
        store.saveNow()
        spin(SessionStore.debounceInterval + 0.4)
        XCTAssertEqual(store.writeCount, 0, "not one write may land while restoring")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))

        store.endRestore()
        store.saveNow()
        XCTAssertEqual(store.writeCount, 1, "once restore is over, writing resumes as usual")
    }

    // MARK: A blocked directory must not poison the archive

    /// Once TCC blocks it the shell starts in the engine's default directory (the home directory), and a few
    /// milliseconds later OSC 7 reports that back. That value must **never** reach the archive: the
    /// ~/Documents the user saved would be rewritten to the home directory by the first debounced save
    /// (or by `saveNow` on quit), and there would be no way to get it back.
    func testDeniedWorkingDirectorySurvivesTheOSC7Fallback() throws {
        denyProtectedRoots()
        let archived = "\(home)/Documents/quickterm"
        let pane = try JSONDecoder().decode(Ghostty.SurfaceView.self, from: paneJSON(pwd: archived))
        defer { pane.removeFromSuperview() }

        // The shell reports the engine's fallback directory back.
        pane.pwd = home
        XCTAssertEqual(try archivedPwd(JSONEncoder().encode(pane)), archived,
                       "when the probe was blocked, the archive has to keep the user's own directory")
        // Reporting the same fallback again (every prompt sends one) must not change the answer.
        pane.pwd = home
        XCTAssertEqual(try archivedPwd(JSONEncoder().encode(pane)), archived)

        // The user really did cd away, so from here on the live location is archived as usual.
        pane.pwd = "/tmp"
        XCTAssertEqual(try archivedPwd(JSONEncoder().encode(pane)), "/tmp",
                       "a real cd has to be archived, or this pane stays nailed to the old directory forever")
    }

    /// With the grant in place (release build, authorized binary) nothing changes: what gets archived is the
    /// live location the shell reported.
    func testGrantedWorkingDirectoryStillPersistsTheLivePwd() throws {
        WorkingDirectoryGate.resetForTesting()
        WorkingDirectoryGate.prober = { _, _ in true }
        let archived = "\(home)/Documents/quickterm"
        let pane = try JSONDecoder().decode(Ghostty.SurfaceView.self, from: paneJSON(pwd: archived))
        defer { pane.removeFromSuperview() }
        pane.pwd = home
        XCTAssertEqual(try archivedPwd(JSONEncoder().encode(pane)), home)
    }

    /// The `open` succeeds only after the deadline (the permission dialog stays up and the user clicks Allow
    /// a while later): the cache has to flip back to usable, so panes created after that get the real
    /// directory. A timeout is not a denial.
    func testLateProbeSuccessReopensTheRoot() {
        denyProtectedRoots()
        let root = "\(home)/Documents"
        XCTAssertNil(WorkingDirectoryGate.usable("\(root)/x"), "recorded as unusable first")
        WorkingDirectoryGate.noteLateSuccess(root)   // The probe thread came back a step late
        XCTAssertEqual(WorkingDirectoryGate.usable("\(root)/x"), "\(root)/x",
                       "a late success has to mark this root usable again")
    }

    // MARK: The previous session's copy

    /// Keep a copy of the previous session before this process's first write: one broken launch must not be
    /// allowed to overwrite the user's session for good.
    func testPreviousSessionArchiveIsKeptBeforeFirstWrite() throws {
        let dir = try makeTempDir()
        let url = dir.appendingPathComponent("state.json")
        let registry = ScreenRegistry()
        registries.append(registry)
        let store = SessionStore(screens: registry, url: url)
        let old = Data(#"{"version":5,"windows":[]}"#.utf8)
        try old.write(to: url)
        store.snapshotOverride = { PersistedState(windows: [WindowState(layouts: [.empty],
                                                                        floatings: [[]],
                                                                        activeIndex: 0)]) }

        store.saveNow()
        XCTAssertEqual(try Data(contentsOf: store.previousSessionURL), old,
                       "before the first write, whatever was on disk is kept verbatim")
        XCTAssertNotEqual(try Data(contentsOf: url), old)

        store.saveNow()
        XCTAssertEqual(try Data(contentsOf: store.previousSessionURL), old,
                       "later writes in the same session must not overwrite that copy")
    }

    // MARK: The control-plane environment (restored panes need it too)

    /// The socket **has** to be bound before restore: the environment is baked into a pane at spawn time, so
    /// binding one step late leaves every terminal in the session without QUICKTERM_SOCKET / TOKEN /
    /// PANE_TOKEN.
    /// (`input send-text` into your own pane would start raising confirmation dialogs, and in a second
    /// instance started with QUICKTERM_CONTROL_SOCKET the CLI inside its panes would drive the user's real
    /// QuickTerm instead.)
    func testControlSocketIsBoundBeforeRestoreSoPanesInheritIt() throws {
        let dir = try makeTempDir()
        // The socket path has to fit inside sun_path's 104 bytes (same line as ControlServerTests).
        let sock = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("qtg-\(UUID().uuidString.prefix(8)).sock")
        try XCTSkipUnless(ControlPaths.fits(sock), "the temp directory is too long to fit in sun_path's 104 bytes")
        defer { try? FileManager.default.removeItem(atPath: sock) }
        let registry = ScreenRegistry()
        registries.append(registry)
        savedBrowserSettings = BrowserPaneView.settings
        savedBrowserExtensions = BrowserExtensionManager.shared.isEnabled
        savedSocketPath = ControlEnvironment.socketPath
        restoreGlobals = true
        let session = AppSession(screens: registry, themeManager: ThemeManager(),
                                 stateURL: dir.appendingPathComponent("state.json"),
                                 controlSocketPath: sock)
        defer { session.controlServer.stop() }

        // This line is the half `loadInitialConfig()` does in `AppDelegate`, and it runs **before** restore.
        session.applyGlobalConfig(ConfigStore.Settings())
        XCTAssertTrue(session.controlServer.isListening, "the socket must already be bound before restore")
        XCTAssertEqual(ControlEnvironment.socketPath, sock)

        // A pane decoded at this moment (the batch launch restore builds) has to carry the whole environment.
        let paneID = UUID()
        let pane = try JSONDecoder().decode(Ghostty.SurfaceView.self,
                                            from: paneJSON(pwd: "/tmp", uuid: paneID))
        defer { pane.removeFromSuperview() }
        XCTAssertEqual(pane.initialEnvironment[ControlProtocol.Env.socket], sock)
        XCTAssertEqual(pane.initialEnvironment[ControlProtocol.Env.token], ControlEnvironment.token)
        XCTAssertEqual(pane.initialEnvironment[ControlProtocol.Env.paneToken],
                       ControlEnvironment.paneToken(for: paneID),
                       "the only basis for skipping confirmation on a self-write: a per-pane origin token")
        XCTAssertEqual(pane.initialEnvironment[ControlProtocol.Env.pane], paneID.uuidString)
    }

    private func makeTempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("quickterm-gate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDirs.append(dir)
        return dir
    }
}
