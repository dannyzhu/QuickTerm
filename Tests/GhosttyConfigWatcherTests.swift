import XCTest
@testable import QuickTerm

/// `[terminal] watch-ghostty-config`: a saved Ghostty config reloads the engine, once per real
/// change, and nothing else next to it does.
final class GhosttyConfigWatcherTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("qt-ghostty-watch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private var config: URL { dir.appendingPathComponent("config") }

    private func makeWatcher(_ reloads: @escaping () -> Void) -> GhosttyConfigWatcher {
        let file = config
        return GhosttyConfigWatcher(
            snapshot: { (try? String(contentsOf: file, encoding: .utf8)) ?? "" },
            directories: { [dir] in [dir!] },
            onChange: reloads)
    }

    func testAnAtomicSaveReloadsOnce() throws {
        try "font-family = Monaco\n".write(to: config, atomically: true, encoding: .utf8)
        let reloaded = expectation(description: "reload")
        var count = 0
        let watcher = makeWatcher { count += 1; reloaded.fulfill() }
        // `atomically: true` writes a temp file and renames it over: the editor's way of saving.
        try "font-family = Monaco\nfont-size = 16\n".write(to: config, atomically: true, encoding: .utf8)
        wait(for: [reloaded], timeout: 3)
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        XCTAssertEqual(count, 1, "one save is one reload, however many events it fires")
        withExtendedLifetime(watcher) {}
    }

    func testAnUnrelatedFileOrAnUnchangedSaveDoesNotReload() throws {
        try "font-family = Monaco\n".write(to: config, atomically: true, encoding: .utf8)
        var count = 0
        let watcher = makeWatcher { count += 1 }
        try "x".write(to: dir.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        try "font-family = Monaco\n".write(to: config, atomically: true, encoding: .utf8)
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        XCTAssertEqual(count, 0)
        withExtendedLifetime(watcher) {}
    }

    func testAFileCreatedLaterIsPickedUp() throws {
        var count = 0
        let watcher = makeWatcher { count += 1 }
        try "font-family = Monaco\n".write(to: config, atomically: true, encoding: .utf8)
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        XCTAssertEqual(count, 1, "creating the config file is a change: the fallback config steps aside")
        withExtendedLifetime(watcher) {}
    }

    func testTheKeyDefaultsOnAndCanBeTurnedOff() {
        XCTAssertTrue(ConfigStore.parse("").watchGhosttyConfig)
        XCTAssertFalse(ConfigStore.parse("[terminal]\nwatch-ghostty-config = false\n").watchGhosttyConfig)
    }
}
