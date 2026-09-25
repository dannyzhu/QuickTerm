import Sparkle
import XCTest
@testable import QuickTerm

/// The state enum's own rules: which states the install chain may push through, what cancel and
/// confirm reply, and the two error kinds.
final class UpdateStateTests: XCTestCase {
    private func available(stage: UpdateState.UpdateAvailable.Stage = .notDownloaded,
                           reply: @escaping @Sendable (SPUUserUpdateChoice) -> Void = { _ in }) -> UpdateState {
        .updateAvailable(.init(appcastItem: SUAppcastItem.empty(), stage: stage,
                               userInitiated: false, reply: reply))
    }

    func testInstallableStates() {
        XCTAssertFalse(UpdateState.idle.isInstallable)
        XCTAssertTrue(UpdateState.checking(.init(cancel: {})).isInstallable)
        XCTAssertTrue(available().isInstallable)
        XCTAssertTrue(UpdateState.downloading(.init(cancel: {}, version: nil, expectedLength: nil, progress: 0)).isInstallable)
        XCTAssertTrue(UpdateState.extracting(.init(version: nil, progress: 0)).isInstallable)
        XCTAssertTrue(UpdateState.installing(.init(isAutoUpdate: true, version: "9.9.9", restart: {}, later: {}, skip: nil)).isInstallable)
        XCTAssertFalse(UpdateState.notFound(.init()).isInstallable)
    }

    func testConfirmInstallsOnlyAnAvailableUpdate() {
        var choice: SPUUserUpdateChoice?
        available { choice = $0 }.confirm()
        XCTAssertEqual(choice, .install)
        var restarted = false
        UpdateState.installing(.init(isAutoUpdate: true, version: nil, restart: { restarted = true }, later: {}, skip: nil)).confirm()
        XCTAssertFalse(restarted, "confirm never restarts on its own; Restart Now is a click")
    }

    func testCancelRepliesDismissOrCancels() {
        var choice: SPUUserUpdateChoice?
        available { choice = $0 }.cancel()
        XCTAssertEqual(choice, .dismiss)
        var cancelled = false
        UpdateState.downloading(.init(cancel: { cancelled = true }, version: nil, expectedLength: nil, progress: 0)).cancel()
        XCTAssertTrue(cancelled)
        var dismissed = false
        UpdateState.error(.init(error: NSError(domain: "x", code: 1), kind: .other, retry: {}, dismiss: { dismissed = true })).cancel()
        XCTAssertTrue(dismissed)
    }

    func testDownloadFraction() {
        XCTAssertNil(UpdateState.Downloading(cancel: {}, version: nil, expectedLength: nil, progress: 10).fraction)
        XCTAssertEqual(UpdateState.Downloading(cancel: {}, version: nil, expectedLength: 200, progress: 50).fraction!, 0.25, accuracy: 0.001)
        XCTAssertEqual(UpdateState.Downloading(cancel: {}, version: nil, expectedLength: 200, progress: 500).fraction!, 1, "never over 100 %")
    }

    func testFailureKind() {
        XCTAssertEqual(UpdateState.Failure.kind(domain: "SUSparkleErrorDomain", code: 1005), .translocated)
        XCTAssertEqual(UpdateState.Failure.kind(domain: "SUSparkleErrorDomain", code: 1003), .translocated)
        XCTAssertEqual(UpdateState.Failure.kind(domain: "SUSparkleErrorDomain", code: 2000), .other)
        XCTAssertEqual(UpdateState.Failure.kind(domain: "NSURLErrorDomain", code: 1005), .other)
    }

    func testEqualityIgnoresClosures() {
        XCTAssertEqual(available(), available())
        XCTAssertNotEqual(available(stage: .downloaded), available(stage: .notDownloaded))
        XCTAssertEqual(UpdateState.extracting(.init(version: nil, progress: 0.5)), .extracting(.init(version: "1", progress: 0.5)))
        XCTAssertNotEqual(UpdateState.idle, UpdateState.notFound(.init()))
    }
}
