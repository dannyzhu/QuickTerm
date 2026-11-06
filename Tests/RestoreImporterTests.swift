import AppKit
import GhosttyKit
import XCTest
@testable import QuickTerm

/// `RestoreImporter`: what a pane restored from the archive shows above its fresh shell — the
/// previous output, one dim marker line, and the "directory gone" line when it applies.
@MainActor
final class RestoreImporterTests: XCTestCase {
    private var dir: URL!
    private var store: RestoreStore!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("restore-import-\(UUID().uuidString)")
        store = RestoreStore(directory: dir, keyStore: MemoryRestoreKeyStore())
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    private let restoredAt = Date(timeIntervalSince1970: 1_793_000_000)
    private var marker: String { RestoreText.marker(restoredAt) }

    private func text(_ data: Data?) throws -> String {
        try XCTUnwrap(String(data: try XCTUnwrap(data), encoding: .utf8))
    }

    // MARK: Shell integration

    /// Spec decision 5: a restored pane carries no command (and no typed input), so the engine
    /// starts the login shell itself and still injects its shell integration.
    func testRestoredPaneHasNoCommand() {
        let config = Ghostty.SurfaceView.archiveConfiguration(pwd: "/tmp", uuid: UUID())
        XCTAssertNil(config.command)
        XCTAssertNil(config.initialInput)
        XCTAssertEqual(config.workingDirectory, "/tmp")
        XCTAssertNotNil(config.environmentVariables["QUICKTERM_PANE"],
                        "the control-plane variables still travel with the pane")
    }

    // MARK: Payload

    func testPayloadEndsWithTheMarker() throws {
        let payload = try text(RestoreImporter.payload(content: Data("old \u{1b}[31mred".utf8),
                                                       restoredAt: restoredAt, directoryGone: false))
        XCTAssertTrue(payload.hasPrefix("old \u{1b}[31mred"), "the content comes first, unchanged")
        XCTAssertTrue(payload.hasSuffix("\u{1b}[0m\r\n\u{1b}[2m\(marker)\u{1b}[0m\r\n"),
                      "a reset, a new line, the dim marker, a new line: \(payload.debugDescription)")
        XCTAssertTrue(marker.contains(RestoreText.time(restoredAt)))
    }

    func testNoContentNoLineNoPayload() {
        XCTAssertNil(RestoreImporter.payload(content: nil, restoredAt: restoredAt, directoryGone: false))
        XCTAssertNil(RestoreImporter.payload(content: Data(), restoredAt: restoredAt, directoryGone: false),
                     "an empty file is no content")
    }

    func testDirectoryGoneLineFollowsTheMarker() throws {
        let gone = RestoreText.directoryGone
        let payload = try text(RestoreImporter.payload(content: Data("old".utf8),
                                                       restoredAt: restoredAt, directoryGone: true))
        let markerEnd = try XCTUnwrap(payload.range(of: "\(marker)\u{1b}[0m\r\n"))
        XCTAssertEqual(String(payload[markerEnd.upperBound...]), "\(gone)\r\n")

        // With no content the line still shows, under the marker.
        let alone = try text(RestoreImporter.payload(content: nil, restoredAt: restoredAt, directoryGone: true))
        XCTAssertTrue(alone.hasSuffix("\(marker)\u{1b}[0m\r\n\(gone)\r\n"))
    }

    /// Ruling 4: the line is for a conversation that cannot be resumed, so it needs both a
    /// missing directory and an agent record.
    func testDirectoryGoneNeedsAMissingDirectoryAndAnAgentRecord() {
        let missing = dir.appendingPathComponent("no-such-dir").path
        XCTAssertTrue(RestoreImporter.directoryGone(saved: missing, hasAgentRecord: true))
        XCTAssertFalse(RestoreImporter.directoryGone(saved: missing, hasAgentRecord: false))
        XCTAssertFalse(RestoreImporter.directoryGone(saved: NSTemporaryDirectory(), hasAgentRecord: true))
        XCTAssertFalse(RestoreImporter.directoryGone(saved: nil, hasAgentRecord: true))
        XCTAssertFalse(RestoreImporter.directoryGone(saved: "", hasAgentRecord: true))
    }

    // MARK: Import

    /// Ruling 2: the store deletes the file before anything is fed. The pane takes its content
    /// before its surface exists, and the surface feeds it right after `ghostty_surface_new`.
    func testFileIsDeletedBeforeContentIsFed() throws {
        let id = UUID()
        try store.write(Data("previous output".utf8), pane: id, encrypt: true)
        let output = RestoreImporter.restoredOutput(pane: id, store: store, contentEnabled: true,
                                                    directoryGone: false, now: restoredAt)
        var fed: Data?
        let appDelegate = try XCTUnwrap(NSApp.delegate as? AppDelegate)
        let pane = Ghostty.SurfaceView(try XCTUnwrap(appDelegate.ghostty.app), baseConfig: nil,
                                       uuid: id, restoredOutput: output) { payload, _ in
            XCTAssertTrue(self.store.files().isEmpty, "the file is gone before anything reaches the screen")
            fed = payload
        }
        XCTAssertNotNil(pane.surface)
        XCTAssertEqual(fed, RestoreImporter.payload(content: Data("previous output".utf8),
                                                     restoredAt: restoredAt, directoryGone: false))
    }

    func testNothingStoredFeedsNothing() throws {
        XCTAssertNil(RestoreImporter.restoredOutput(pane: UUID(), store: store, contentEnabled: true,
                                                    directoryGone: false, now: restoredAt))
        var calls = 0
        let appDelegate = try XCTUnwrap(NSApp.delegate as? AppDelegate)
        _ = Ghostty.SurfaceView(try XCTUnwrap(appDelegate.ghostty.app), baseConfig: nil,
                                restoredOutput: nil) { _, _ in calls += 1 }
        XCTAssertEqual(calls, 0, "a pane with nothing restored never calls the engine import")
    }

    /// Ruling 7: with `[restore] content = false` nothing reaches the screen — not the content,
    /// not the marker, not the directory line — and a stray file is still removed.
    func testContentOffFeedsNothing() throws {
        let id = UUID()
        try store.write(Data("previous output".utf8), pane: id, encrypt: false)
        XCTAssertNil(RestoreImporter.restoredOutput(pane: id, store: store, contentEnabled: false,
                                                    directoryGone: true, now: restoredAt))
        XCTAssertTrue(store.files().isEmpty, "the stray file does not outlive the launch")
    }

    // MARK: Engine

    func testImportedContentIsOnScreen() throws {
        let appDelegate = try XCTUnwrap(NSApp.delegate as? AppDelegate)
        let payload = try XCTUnwrap(RestoreImporter.payload(content: Data("hello\r\n".utf8),
                                                            restoredAt: restoredAt, directoryGone: false))
        // The default feeder: the real engine import, right after the surface is created.
        let pane = Ghostty.SurfaceView(try XCTUnwrap(appDelegate.ghostty.app), baseConfig: nil,
                                       restoredOutput: payload)
        let screen = try XCTUnwrap(pane.controlReadText(tag: GHOSTTY_POINT_SCREEN))
        XCTAssertTrue(screen.contains("hello"), screen)
        XCTAssertTrue(screen.contains(marker), screen)
    }
}
