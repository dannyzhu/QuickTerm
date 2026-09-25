import AppKit
import Sparkle
import XCTest
@testable import QuickTerm

/// The sheet's buttons per state, what each one replies, that a state change takes it down, and
/// which new states open it by themselves (spec §4).
@MainActor
final class UpdateSheetTests: XCTestCase {
    private var controller: UpdateController!
    private var sheet: UpdateSheet!
    /// Only when the test host has no visible window of its own.
    private var spareWindow: NSWindow?

    /// The sheet hangs off the key (or first visible) window and falls back to a blocking
    /// `runModal` without one. A test host without a window must therefore fail here, not hang
    /// inside `runModal` until the test runner gives up.
    override func setUpWithError() throws {
        try super.setUpWithError()
        if !Self.hasHostWindow {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.orderFront(nil)
            spareWindow = window
        }
        guard Self.hasHostWindow else {
            throw NSError(domain: "UpdateSheetTests", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "no visible window to attach the update sheet to; runModal would block"])
        }
        controller = UpdateController(enabled: false)
        sheet = UpdateSheet(controller: controller, notes: ReleaseNotes.Loader(), currentVersion: "1.6.7")
    }

    private static var hasHostWindow: Bool {
        NSApp.keyWindow != nil || NSApp.windows.contains { $0.isVisible }
    }

    /// A failed assertion must never leave a real sheet attached to the test host's window for
    /// the next test to trip over. Optional chaining: `setUpWithError` may have thrown first.
    override func tearDown() {
        sheet?.dismiss()
        controller?.viewModel.state = .idle
        spareWindow?.close()
        spareWindow = nil
        super.tearDown()
    }

    /// The auto-present waits one main-queue turn (see `testAManualFindOpensTheSheetByItself`).
    private func spin() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }

    private func failure(_ kind: UpdateState.Failure.Kind = .other, retry: @escaping () -> Void = {}) -> UpdateState {
        .error(.init(error: NSError(domain: "x", code: 1), kind: kind, retry: retry, dismiss: {}))
    }

    private func installing(userInitiated: Bool) -> UpdateState {
        .installing(.init(isAutoUpdate: true, userInitiated: userInitiated, version: "1.6.8",
                          restart: {}, later: {}, skip: nil))
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
        XCTAssertEqual(kinds(.installing(.init(isAutoUpdate: true, userInitiated: false, version: nil, restart: {}, later: {}, skip: {}))), [.restart, .later, .skip])
        XCTAssertEqual(kinds(.installing(.init(isAutoUpdate: true, userInitiated: false, version: nil, restart: {}, later: {}, skip: nil))), [.restart, .later])
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
        let staged = try XCTUnwrap(UpdateSheet.makeAlert(for: .installing(.init(isAutoUpdate: true, userInitiated: false, version: "1.6.8", restart: {}, later: {}, skip: nil)), currentVersion: "1.6.7", language: .en))
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
        XCTAssertFalse(controller.relaunchRequested,
                       "Install starts a download; only Sparkle about to terminate the app bypasses the quit confirmation")
        controller.viewModel.state = .idle
        let again = available { replies.append($0) }
        controller.viewModel.state = again
        sheet.perform(.skip, for: again)
        XCTAssertEqual(replies.last, .skip)
    }

    func testRestartNowAsksForTheRelaunch() {
        var restarted = false
        let state = UpdateState.installing(.init(isAutoUpdate: true, userInitiated: false, version: "1.6.8", restart: { restarted = true }, later: {}, skip: nil))
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
        // The auto-present is deferred by one main-queue turn (Finding 2): `stateDidChange` runs
        // inside `$state`'s willSet, before the new value is stored, and presenting synchronously
        // there could read stale state back out of the controller. So right after the assignment
        // nothing has opened yet.
        XCTAssertFalse(sheet.isPresented, "the present is deferred, not synchronous")
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertTrue(sheet.isPresented)
        sheet.dismiss()
        controller.viewModel.state = .idle
        controller.viewModel.state = available(userInitiated: false)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
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

    /// Finding 1: `AppSession.updateSheet` has to be built eagerly (a stored `let`, not `lazy`)
    /// so a manual "Check for Updates…" that finds something can open the sheet by itself even
    /// when nobody has ever clicked the indicator to force the `lazy` property into existence.
    /// This goes through the live session rather than a fresh `UpdateSheet`, so it would have
    /// caught a `lazy` regression the other tests (which all construct their own `sheet` in
    /// `setUp`) cannot.
    func testALiveSessionOpensTheSheetWithoutTouchingItFirst() throws {
        let session = try XCTUnwrap((NSApp.delegate as? AppDelegate)?.session)
        defer {
            session.updateSheet.dismiss()
            session.updates.viewModel.state = .idle
        }
        // Deliberately not touching `session.updateSheet` before this: if it were still `lazy`,
        // nothing would have subscribed to `$state` yet and this assignment would be a no-op as
        // far as the sheet is concerned.
        session.updates.viewModel.state = available(userInitiated: true)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertTrue(session.updateSheet.isPresented)
    }

    // MARK: What opens by itself (spec §4: a state the user asked to see)

    /// `.checking` only ever comes from a manual "Check for Updates…", so what follows it is
    /// something the user is watching for.
    func testAManualCheckThatFailsOpensTheError() {
        controller.viewModel.state = .checking(.init(cancel: {}))
        spin()
        XCTAssertFalse(sheet.isPresented, "checking itself lives on the icon")
        controller.viewModel.state = failure()
        XCTAssertFalse(sheet.isPresented, "deferred by one main-queue turn, like every auto-present")
        spin()
        XCTAssertTrue(sheet.isPresented, "a manual check that fails says so")
    }

    func testAManualCheckThatHitsTranslocationOpensTheMoveSheet() {
        controller.viewModel.state = .checking(.init(cancel: {}))
        controller.viewModel.state = failure(.translocated)
        spin()
        XCTAssertTrue(sheet.isPresented, "the Move to Applications sheet, not just a triangle")
    }

    func testAManualCheckThatResumesAStagedUpdateOpensIt() {
        controller.viewModel.state = .checking(.init(cancel: {}))
        controller.viewModel.state = installing(userInitiated: true)
        spin()
        XCTAssertTrue(sheet.isPresented)
    }

    /// Sparkle may resume a staged update without a `.checking` first; its own `userInitiated`
    /// is enough. The staged-on-quit state (`willInstallUpdateOnQuit`) only lights the icon.
    func testAStagedUpdateOpensOnlyWhenTheUserAskedForIt() {
        controller.viewModel.state = installing(userInitiated: true)
        spin()
        XCTAssertTrue(sheet.isPresented)
        sheet.dismiss()
        controller.viewModel.state = .idle
        controller.viewModel.state = installing(userInitiated: false)
        spin()
        XCTAssertFalse(sheet.isPresented, "staged in the background: the icon only")
    }

    func testAScheduledErrorOnlyLightsTheIcon() {
        controller.viewModel.state = failure()
        spin()
        XCTAssertFalse(sheet.isPresented)
    }

    /// Spec §4: "none → notFound for 5 s (no modal)", whoever asked.
    func testNotFoundNeverOpensASheet() {
        controller.viewModel.state = .checking(.init(cancel: {}))
        controller.viewModel.state = .notFound(.init())
        spin()
        XCTAssertFalse(sheet.isPresented, "a manual check that finds nothing")
        controller.viewModel.state = .idle
        controller.viewModel.state = .notFound(.init())
        spin()
        XCTAssertFalse(sheet.isPresented)
    }

    /// A sheet the user opened by clicking the icon is watched too: when its download fails, the
    /// error replaces it instead of the sheet vanishing. Progress states never open by themselves.
    func testASheetTheUserOpenedFollowsItsStateIntoAnError() {
        controller.viewModel.state = .downloading(.init(cancel: {}, version: "1.6.8", expectedLength: nil, progress: 0))
        sheet.present()
        XCTAssertTrue(sheet.isPresented)
        controller.viewModel.state = .extracting(.init(version: "1.6.8", progress: 0))
        spin()
        XCTAssertFalse(sheet.isPresented, "extraction progress lives on the icon")
        controller.viewModel.state = .downloading(.init(cancel: {}, version: "1.6.8", expectedLength: nil, progress: 0))
        sheet.present()
        controller.viewModel.state = failure()
        spin()
        XCTAssertTrue(sheet.isPresented, "the download the user was watching failed")
    }

    /// Retry in the error sheet goes back through a manual check; failing again brings the error
    /// back rather than leaving only the triangle. The test host has no Sparkle, so the driver's
    /// callbacks play Sparkle's part.
    func testARetryThatFailsAgainReopensTheError() {
        let driver = UpdateDriver(viewModel: controller.viewModel, feedOverride: nil)
        driver.controller = controller
        driver.showUserInitiatedUpdateCheck(cancellation: {})
        driver.showUpdaterError(NSError(domain: "x", code: 1)) {}
        spin()
        XCTAssertTrue(sheet.isPresented)
        guard case .error = controller.viewModel.state else { return XCTFail("expected error") }
        // What a click on Retry does: the click closes the alert, then the button acts.
        let shown = controller.viewModel.state
        sheet.dismiss()
        sheet.perform(.retry, for: shown)
        XCTAssertTrue(controller.viewModel.state.isIdle)
        spin()
        driver.showUserInitiatedUpdateCheck(cancellation: {})
        driver.showUpdaterError(NSError(domain: "x", code: 1)) {}
        spin()
        XCTAssertTrue(sheet.isPresented, "the retry failed again: the error is back on screen")
    }

    // MARK: The GitHub link

    /// The "Full notes on GitHub" line is the only pointer when the notes fail to load: it has to
    /// be clickable and copyable, while the intro still reads the same.
    func testAnHTTPSLinkInTheIntroIsClickableAndSelectable() throws {
        let url = "https://github.com/dannyzhu/QuickTerm/releases/tag/v1.6.8"
        let notesLine = L("update.sheet.notes.github", url)
        let intro = "You have 1.6.7.\n" + notesLine
        let alert = NSAlert()
        alert.setScrollableBody("notes", intro: intro)
        let label = try XCTUnwrap(alert.accessoryView?.subviews.compactMap { $0 as? NSTextField }.first)
        XCTAssertTrue(label.isSelectable)
        XCTAssertTrue(label.allowsEditingTextAttributes, "what makes a label's link runs clickable")
        XCTAssertEqual(label.stringValue, intro, "the text itself is unchanged")
        let text = label.attributedStringValue
        let range = (text.string as NSString).range(of: url)
        XCTAssertNotEqual(range.location, NSNotFound)
        var effective = NSRange()
        let link = text.attribute(.link, at: range.location, effectiveRange: &effective)
        XCTAssertEqual(link as? URL, URL(string: url))
        XCTAssertEqual(effective, range, "exactly the URL is the link, nothing around it")
        XCTAssertNil(text.attribute(.link, at: 0, effectiveRange: nil), "plain text stays plain")
    }
}
