import AppKit
import Sparkle
import XCTest
@testable import QuickTerm

/// The sheet's buttons per state, what each one replies, and that a state change takes it down.
@MainActor
final class UpdateSheetTests: XCTestCase {
    private var controller: UpdateController!
    private var sheet: UpdateSheet!

    override func setUp() {
        super.setUp()
        controller = UpdateController(enabled: false)
        sheet = UpdateSheet(controller: controller, notes: ReleaseNotes.Loader(), currentVersion: "1.6.7")
    }

    private func available(userInitiated: Bool = false, stage: UpdateState.UpdateAvailable.Stage = .notDownloaded,
                           reply: @escaping @Sendable (SPUUserUpdateChoice) -> Void = { _ in }) -> UpdateState {
        .updateAvailable(.init(appcastItem: SUAppcastItem.empty(), stage: stage, userInitiated: userInitiated, reply: reply))
    }

    private func kinds(_ state: UpdateState, install: Bool = false) -> [UpdateSheet.Button.Kind] {
        UpdateSheet.buttons(for: state, installMode: install).map(\.kind)
    }

    func testButtonsPerState() {
        XCTAssertEqual(kinds(.checking(.init(cancel: {}))), [.cancel])
        XCTAssertEqual(kinds(available()), [.install, .later, .skip])
        XCTAssertEqual(kinds(available(stage: .downloaded)), [.install, .later, .skip])
        XCTAssertEqual(kinds(.downloading(.init(cancel: {}, version: nil, expectedLength: nil, progress: 0))), [.cancel])
        XCTAssertEqual(kinds(.extracting(.init(version: nil, progress: 0))), [.ok])
        XCTAssertEqual(kinds(.installing(.init(isAutoUpdate: true, version: nil, restart: {}, later: {}, skip: {}))), [.restart, .later, .skip])
        XCTAssertEqual(kinds(.installing(.init(isAutoUpdate: true, version: nil, restart: {}, later: {}, skip: nil))), [.restart, .later])
        XCTAssertEqual(kinds(.error(.init(error: NSError(domain: "SUSparkleErrorDomain", code: 1005), kind: .translocated, retry: {}, dismiss: {}))), [.ok])
        XCTAssertEqual(kinds(.error(.init(error: NSError(domain: "x", code: 1), kind: .other, retry: {}, dismiss: {}))), [.retry, .ok])
        XCTAssertTrue(kinds(.idle).isEmpty)
        XCTAssertTrue(kinds(.notFound(.init())).isEmpty)
    }

    func testTheFirstButtonIsReturnAndLaterOrCancelIsEscape() {
        let buttons = UpdateSheet.buttons(for: available(), installMode: false)
        XCTAssertEqual(buttons.map(\.keyEquivalent), ["\r", "\u{1b}", ""])
        XCTAssertEqual(UpdateSheet.buttons(for: .checking(.init(cancel: {})), installMode: false).map(\.keyEquivalent), ["\u{1b}"])
        let failed = UpdateSheet.buttons(for: .error(.init(error: NSError(domain: "x", code: 1), kind: .other, retry: {}, dismiss: {})), installMode: false)
        XCTAssertEqual(failed.map(\.keyEquivalent), ["\r", "\u{1b}"])
    }

    func testMakeAlertUsesTheCatalogAndTheScrollableBody() throws {
        let built = try XCTUnwrap(UpdateSheet.makeAlert(for: available(), currentVersion: "1.6.7", language: .en))
        XCTAssertEqual(built.alert.buttons.map(\.title), [L("update.sheet.button.install"), L("update.sheet.button.later"), L("update.sheet.button.skip")])
        XCTAssertNotNil(built.body, "the notes area exists before the notes arrive")
        XCTAssertEqual(built.body?.string, L("update.sheet.notes.loading"))
        let staged = try XCTUnwrap(UpdateSheet.makeAlert(for: .installing(.init(isAutoUpdate: true, version: "1.6.8", restart: {}, later: {}, skip: nil)), currentVersion: "1.6.7", language: .en))
        XCTAssertEqual(staged.alert.messageText, L("update.sheet.installing.title", "1.6.8"))
        XCTAssertNil(UpdateSheet.makeAlert(for: .idle, currentVersion: "1.6.7", language: .en))
        XCTAssertNil(UpdateSheet.makeAlert(for: .notFound(.init()), currentVersion: "1.6.7", language: .en))
    }

    func testLaterInCheckOnlyModeHoldsTheReply() {
        var replies: [SPUUserUpdateChoice] = []
        let state = available { replies.append($0) }
        controller.apply(UpdateSettings(check: true, install: false))
        controller.viewModel.state = state
        sheet.perform(.later, for: state)
        XCTAssertTrue(replies.isEmpty, "no reply: Sparkle keeps the session, the icon stays")
        guard case .updateAvailable = controller.viewModel.state else { return XCTFail("state untouched") }
    }

    func testLaterInInstallModeDismisses() {
        var replies: [SPUUserUpdateChoice] = []
        let state = available { replies.append($0) }
        controller.apply(UpdateSettings(check: true, install: true))
        controller.viewModel.state = state
        sheet.perform(.later, for: state)
        XCTAssertEqual(replies, [.dismiss], "the scheduler downloads and stages it unattended")
    }

    func testInstallGoesThroughTheControllerAndSkipReplies() {
        var replies: [SPUUserUpdateChoice] = []
        let state = available { replies.append($0) }
        controller.viewModel.state = state
        sheet.perform(.install, for: state)
        XCTAssertEqual(replies, [.install])
        XCTAssertTrue(controller.relaunchRequested)
        controller.viewModel.state = .idle
        let again = available { replies.append($0) }
        controller.viewModel.state = again
        sheet.perform(.skip, for: again)
        XCTAssertEqual(replies.last, .skip)
    }

    func testRestartNowAsksForTheRelaunch() {
        var restarted = false
        let state = UpdateState.installing(.init(isAutoUpdate: true, version: "1.6.8", restart: { restarted = true }, later: {}, skip: nil))
        controller.viewModel.state = state
        sheet.perform(.restart, for: state)
        XCTAssertTrue(restarted)
        XCTAssertTrue(controller.relaunchRequested)
    }

    func testAStateChangeTakesTheSheetDown() {
        controller.viewModel.state = .checking(.init(cancel: {}))
        sheet.present()
        XCTAssertTrue(sheet.isPresented)
        controller.viewModel.state = .idle
        XCTAssertFalse(sheet.isPresented)
    }

    func testAManualFindOpensTheSheetByItself() {
        controller.viewModel.state = available(userInitiated: true)
        XCTAssertTrue(sheet.isPresented)
        sheet.dismiss()
        controller.viewModel.state = .idle
        controller.viewModel.state = available(userInitiated: false)
        XCTAssertFalse(sheet.isPresented, "a scheduled find only lights the icon")
    }

    /// Controller ruling 1: a click on the indicator during "You're up to date" clears the
    /// not-found state early instead of building a sheet for it.
    func testPresentDuringNotFoundClearsInstead() {
        controller.viewModel.state = .notFound(.init())
        sheet.present()
        XCTAssertEqual(controller.viewModel.state, .idle)
        XCTAssertFalse(sheet.isPresented)
    }
}
