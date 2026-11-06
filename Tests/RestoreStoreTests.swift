import CryptoKit
import XCTest
@testable import QuickTerm

/// In-memory key store: the tests never touch the real keychain.
final class MemoryRestoreKeyStore: RestoreKeyStore, @unchecked Sendable {
    var stored: SymmetricKey?
    func key(createIfMissing: Bool) throws -> SymmetricKey? {
        if stored == nil, createIfMissing { stored = SymmetricKey(size: .bits256) }
        return stored
    }
}

@MainActor
final class RestoreStoreTests: XCTestCase {
    private var dir: URL!
    private var keys: MemoryRestoreKeyStore!
    private var store: RestoreStore!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("restore-test-\(UUID().uuidString)")
        keys = MemoryRestoreKeyStore()
        store = RestoreStore(directory: dir, keyStore: keys)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    private let text = Data("hello \u{1b}[31mred\u{1b}[0m world".utf8)

    func testRoundTripEncrypted() throws {
        let pane = UUID()
        try store.write(text, pane: pane, encrypt: true)
        XCTAssertEqual(store.files().map(\.pathExtension), ["qtr"])
        let raw = try Data(contentsOf: store.files()[0])
        XCTAssertEqual(raw.prefix(4), Data("QTR1".utf8))
        XCTAssertNil(raw.range(of: Data("hello".utf8)))
        XCTAssertEqual(store.take(pane: pane), text)
    }

    func testRoundTripPlain() throws {
        let pane = UUID()
        try store.write(text, pane: pane, encrypt: false)
        XCTAssertEqual(store.files().map(\.pathExtension), ["vt"])
        XCTAssertEqual(store.take(pane: pane), text)
    }

    func testTakeDeletesTheFile() throws {
        let pane = UUID()
        try store.write(text, pane: pane, encrypt: true)
        XCTAssertNotNil(store.take(pane: pane))
        XCTAssertNil(store.take(pane: pane))
        XCTAssertTrue(store.files().isEmpty)
    }

    func testSwitchingModeLeavesOneFormat() throws {
        let pane = UUID()
        try store.write(text, pane: pane, encrypt: true)
        try store.write(text, pane: pane, encrypt: false)
        XCTAssertEqual(store.files().map(\.pathExtension), ["vt"])
    }

    func testWrongKeyIsDeletedNotShown() throws {
        let pane = UUID()
        try store.write(text, pane: pane, encrypt: true)
        keys.stored = SymmetricKey(size: .bits256)
        XCTAssertNil(store.take(pane: pane))
        XCTAssertTrue(store.files().isEmpty)
    }

    func testMissingKeyIsDeletedNotShown() throws {
        let pane = UUID()
        try store.write(text, pane: pane, encrypt: true)
        keys.stored = nil
        XCTAssertNil(store.take(pane: pane))
        XCTAssertTrue(store.files().isEmpty)
    }

    func testTruncatedFileIsDeleted() throws {
        let pane = UUID()
        try store.write(text, pane: pane, encrypt: true)
        let file = store.files()[0]
        let raw = try Data(contentsOf: file)
        try raw.prefix(10).write(to: file)
        XCTAssertNil(store.take(pane: pane))
        XCTAssertTrue(store.files().isEmpty)
    }

    func testSymlinkIsNeverFollowed() throws {
        let pane = UUID()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let target = dir.deletingLastPathComponent()
            .appendingPathComponent("restore-target-\(UUID().uuidString)")
        try Data("secret".utf8).write(to: target)
        defer { try? FileManager.default.removeItem(at: target) }
        let link = dir.appendingPathComponent("\(pane.uuidString).vt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertNil(store.take(pane: pane))
        XCTAssertEqual(try Data(contentsOf: target), Data("secret".utf8))

        // Writing over a link replaces the link, never the target.
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        try store.write(text, pane: pane, encrypt: false)
        XCTAssertEqual(try Data(contentsOf: target), Data("secret".utf8))
        XCTAssertEqual(store.take(pane: pane), text)
    }

    func testDirectoryIsPrivateAndExcludedFromBackup() throws {
        try store.write(text, pane: UUID(), encrypt: false)
        let attrs = try FileManager.default.attributesOfItem(atPath: dir.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        let values = try dir.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)
        let file = try FileManager.default.attributesOfItem(atPath: store.files()[0].path)
        XCTAssertEqual((file[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testPruneKeepsOnlyTheGivenPanes() throws {
        let keep = UUID(), drop = UUID()
        try store.write(text, pane: keep, encrypt: true)
        try store.write(text, pane: drop, encrypt: false)
        store.prune(keeping: [keep])
        XCTAssertEqual(store.files().map(\.lastPathComponent), ["\(keep.uuidString).qtr"])
    }

    func testRemoveAllDeletesTheDirectory() throws {
        try store.write(text, pane: UUID(), encrypt: true)
        store.removeAll()
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
    }
}
