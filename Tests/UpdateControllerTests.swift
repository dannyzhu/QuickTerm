import Sparkle
import XCTest
@testable import QuickTerm

/// The controller without a Sparkle updater (the test host never has one): the gate, the stored
/// settings, the relaunch flag, the not-found timer and the driver's callback mapping.
@MainActor
final class UpdateControllerTests: XCTestCase {
    private var controller: UpdateController!
    private var driver: UpdateDriver!

    override func setUp() {
        super.setUp()
        controller = UpdateController(enabled: false)
        driver = UpdateDriver(viewModel: controller.viewModel, feedOverride: nil)
        driver.controller = controller
    }

    override func tearDown() {
        UpdateController.notFoundClearDelay = 5
        super.tearDown()
    }

    private func spin(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    // MARK: The gate

    func testTheGateIsPure() {
        let feed = URL(string: "https://example.invalid/appcast.xml")
        XCTAssertFalse(UpdateController.isEnabled(isRunningTests: true, hasPublicKey: true, isDebugBuild: false, feedOverride: nil))
        XCTAssertFalse(UpdateController.isEnabled(isRunningTests: false, hasPublicKey: false, isDebugBuild: false, feedOverride: nil))
        XCTAssertTrue(UpdateController.isEnabled(isRunningTests: false, hasPublicKey: true, isDebugBuild: false, feedOverride: nil))
        XCTAssertFalse(UpdateController.isEnabled(isRunningTests: false, hasPublicKey: true, isDebugBuild: true, feedOverride: nil))
        XCTAssertTrue(UpdateController.isEnabled(isRunningTests: false, hasPublicKey: true, isDebugBuild: true, feedOverride: feed))
    }

    func testDisabledControllerHasNoUpdaterAndStoresSettings() {
        XCTAssertNil(controller.updater)
        XCTAssertFalse(controller.canCheckForUpdates)
        controller.apply(UpdateSettings(check: false, install: true))
        XCTAssertEqual(controller.settings, UpdateSettings(check: false, install: true))
        controller.start()
        controller.checkForUpdates()
        XCTAssertTrue(controller.viewModel.state.isIdle, "nothing to do without an updater")
    }

    // MARK: relaunchRequested

    func testRelaunchRequestedFollowsTheInstallPaths() {
        var replies: [SPUUserUpdateChoice] = []
        controller.viewModel.state = .updateAvailable(.init(appcastItem: SUAppcastItem.empty(), stage: .notDownloaded,
                                                            userInitiated: true, reply: { replies.append($0) }))
        XCTAssertFalse(controller.relaunchRequested)
        controller.installUpdate()
        XCTAssertTrue(controller.relaunchRequested, "Install and Relaunch asks for a relaunch")
        XCTAssertEqual(replies, [.install], "the chain confirmed the available state")
        controller.viewModel.state = .downloading(.init(cancel: {}, version: "9", expectedLength: 10, progress: 1))
        XCTAssertTrue(controller.relaunchRequested, "still set through the download")
        controller.viewModel.state = .idle
        XCTAssertFalse(controller.relaunchRequested, "cancelled: cleared")

        var restarted = false
        controller.viewModel.state = .installing(.init(isAutoUpdate: true, version: "9", restart: { restarted = true }, later: {}, skip: nil))
        XCTAssertFalse(controller.relaunchRequested, "a staged update alone asks for nothing")
        if case .installing(let installing) = controller.viewModel.state { controller.requestRelaunch(installing.restart) }
        XCTAssertTrue(restarted)
        XCTAssertTrue(controller.relaunchRequested, "Restart Now asks for a relaunch")

        controller.viewModel.state = .error(.init(error: NSError(domain: "x", code: 1), kind: .other, retry: {}, dismiss: {}))
        XCTAssertFalse(controller.relaunchRequested, "an error clears it")
        controller.noteInstallerTerminating()
        XCTAssertTrue(controller.relaunchRequested, "Sparkle terminating the app sets it")
    }

    /// installUpdate() cancels its confirm-everything sink but must leave `installCancellable` at
    /// nil, or every later Install click is silently ignored until restart (the `== nil` guard).
    /// checkForUpdates() has to do that teardown itself — the test host has no updater, so if the
    /// teardown depended on one (the old top-of-function `guard let updater`), it would never run,
    /// and only a later, unrelated state change would happen to reset the chain via the sink's own
    /// guard. Proven two ways: the download's own `cancel` closure only fires through
    /// checkForUpdates() itself (not through some other state assignment), and no state is set
    /// between the check and the second `installUpdate()` — a still-stale chain would block it.
    func testInstallUpdateRecoversAfterACheckForUpdatesDuringInstall() {
        var firstReplies: [SPUUserUpdateChoice] = []
        controller.viewModel.state = .updateAvailable(.init(appcastItem: SUAppcastItem.empty(), stage: .notDownloaded,
                                                            userInitiated: true, reply: { firstReplies.append($0) }))
        controller.installUpdate()
        XCTAssertEqual(firstReplies, [.install])

        var cancelled = false
        controller.viewModel.state = .downloading(.init(cancel: { cancelled = true }, version: "9", expectedLength: 10, progress: 1))
        controller.checkForUpdates() // no updater in tests: this alone must tear the chain down
        XCTAssertTrue(cancelled, "checkForUpdates must cancel the in-flight download itself, updater or not")
        XCTAssertTrue(controller.relaunchRequested, "downloading leaves relaunchRequested as installUpdate() set it")

        var secondReplies: [SPUUserUpdateChoice] = []
        controller.viewModel.state = .updateAvailable(.init(appcastItem: SUAppcastItem.empty(), stage: .notDownloaded,
                                                            userInitiated: true, reply: { secondReplies.append($0) }))
        controller.installUpdate()
        XCTAssertEqual(secondReplies, [.install], "a fresh Install must still go through: checkForUpdates already dropped the stale chain")
        XCTAssertTrue(controller.relaunchRequested)
    }

    // MARK: not found

    func testNotFoundClearsItselfAfterTheDelay() {
        UpdateController.notFoundClearDelay = 0.05
        controller.viewModel.state = .notFound(.init())
        spin(0.2)
        XCTAssertTrue(controller.viewModel.state.isIdle)
    }

    func testAClickClearsNotFoundEarlyAndOnlyThatInstance() {
        UpdateController.notFoundClearDelay = 10
        controller.viewModel.state = .notFound(.init())
        controller.clearNotFound(UUID())
        XCTAssertFalse(controller.viewModel.state.isIdle, "a stale id is ignored")
        controller.clearNotFound()
        XCTAssertTrue(controller.viewModel.state.isIdle)
    }

    // MARK: the driver

    func testNotFoundAndErrorAcknowledgeSparkleImmediately() {
        var acknowledged = 0
        driver.showUpdateNotFoundWithError(NSError(domain: "SUSparkleErrorDomain", code: 1001)) { acknowledged += 1 }
        XCTAssertEqual(acknowledged, 1)
        guard case .notFound = controller.viewModel.state else { return XCTFail("expected notFound") }
        driver.showUpdaterError(NSError(domain: "SUSparkleErrorDomain", code: 1005)) { acknowledged += 1 }
        XCTAssertEqual(acknowledged, 2)
        guard case .error(let failure) = controller.viewModel.state else { return XCTFail("expected error") }
        XCTAssertEqual(failure.kind, .translocated)
        failure.dismiss()
        XCTAssertTrue(controller.viewModel.state.isIdle)
    }

    /// Sparkle's abortUpdate calls dismissUpdateInstallation one run-loop turn after
    /// showUpdateNotFoundWithError / showUpdaterError acknowledge it; that must not erase the
    /// state QuickTerm is still displaying (the 5 s timer / a click / Retry / OK do that instead).
    /// Every other state is a live Sparkle session and still tears down to idle.
    func testDismissUpdateInstallationLeavesAcknowledgedStatesAlone() {
        driver.showUpdateNotFoundWithError(NSError(domain: "SUSparkleErrorDomain", code: 1001)) {}
        driver.dismissUpdateInstallation()
        guard case .notFound = controller.viewModel.state else { return XCTFail("expected notFound to survive dismissUpdateInstallation") }

        driver.showUpdaterError(NSError(domain: "SUSparkleErrorDomain", code: 1005)) {}
        driver.dismissUpdateInstallation()
        guard case .error = controller.viewModel.state else { return XCTFail("expected error to survive dismissUpdateInstallation") }

        controller.viewModel.state = .updateAvailable(.init(appcastItem: SUAppcastItem.empty(), stage: .notDownloaded,
                                                            userInitiated: false, reply: { _ in }))
        driver.dismissUpdateInstallation()
        XCTAssertTrue(controller.viewModel.state.isIdle, "updateAvailable still tears down")

        controller.viewModel.state = .installing(.init(isAutoUpdate: true, version: "9", restart: {}, later: {}, skip: nil))
        driver.dismissUpdateInstallation()
        XCTAssertTrue(controller.viewModel.state.isIdle, "installing still tears down")
    }

    func testAStagedUpdateMapsToInstalling() {
        var replies: [SPUUserUpdateChoice] = []
        let state = UpdateDriver.foundState(item: SUAppcastItem.empty(), stage: .installing, userInitiated: false) { replies.append($0) }
        guard case .installing(let installing) = state else { return XCTFail("expected installing, got \(state)") }
        XCTAssertTrue(installing.isAutoUpdate)
        installing.restart(); installing.later(); installing.skip?()
        XCTAssertEqual(replies, [.install, .dismiss, .skip])
    }

    func testADownloadedUpdateKeepsItsStage() {
        let downloaded = UpdateDriver.foundState(item: SUAppcastItem.empty(), stage: .downloaded, userInitiated: true) { _ in }
        guard case .updateAvailable(let available) = downloaded else { return XCTFail("expected updateAvailable") }
        XCTAssertEqual(available.stage, .downloaded)
        XCTAssertTrue(available.userInitiated)
        let fresh = UpdateDriver.foundState(item: SUAppcastItem.empty(), stage: .notDownloaded, userInitiated: false) { _ in }
        guard case .updateAvailable(let a) = fresh else { return XCTFail() }
        XCTAssertEqual(a.stage, .notDownloaded)
    }

    func testDownloadProgressAccumulatesAndKeepsTheVersion() {
        controller.viewModel.state = .updateAvailable(.init(appcastItem: SUAppcastItem.empty(), stage: .notDownloaded, userInitiated: false, reply: { _ in }))
        driver.showDownloadInitiated(cancellation: {})
        driver.showDownloadDidReceiveExpectedContentLength(100)
        driver.showDownloadDidReceiveData(ofLength: 30)
        driver.showDownloadDidReceiveData(ofLength: 30)
        guard case .downloading(let d) = controller.viewModel.state else { return XCTFail() }
        XCTAssertEqual(d.progress, 60)
        XCTAssertEqual(d.fraction!, 0.6, accuracy: 0.001)
        driver.showDownloadDidStartExtractingUpdate()
        driver.showExtractionReceivedProgress(0.5)
        guard case .extracting(let e) = controller.viewModel.state else { return XCTFail() }
        XCTAssertEqual(e.progress, 0.5)
    }

    func testReadyToInstallRepliesInstallAndMarksTheRelaunch() {
        var choice: SPUUserUpdateChoice?
        driver.showReady(toInstallAndRelaunch: { choice = $0 })
        XCTAssertEqual(choice, .install)
        XCTAssertTrue(controller.relaunchRequested)
        driver.showInstallingUpdate(withApplicationTerminated: false, retryTerminatingApplication: {})
        guard case .installing(let i) = controller.viewModel.state else { return XCTFail() }
        XCTAssertFalse(i.isAutoUpdate)
    }

    func testPermissionRequestIsAnsweredFromTheSettings() {
        controller.apply(UpdateSettings(check: false, install: false))
        var response: SUUpdatePermissionResponse?
        driver.show(SPUUpdatePermissionRequest(systemProfile: [])) { response = $0 }
        XCTAssertEqual(response?.automaticUpdateChecks, false)
        XCTAssertEqual(response?.sendSystemProfile, false)
        XCTAssertTrue(controller.viewModel.state.isIdle, "no UI for a question the config answers")
    }

    func testRelaunchPolicyAndFeedOverride() {
        let feed = URL(string: "https://example.invalid/e2e/appcast.xml")!
        let overridden = UpdateDriver(viewModel: UpdateViewModel(), feedOverride: feed)
        let stock = UpdateDriver(viewModel: UpdateViewModel(), feedOverride: nil)
        XCTAssertEqual(overridden.feedURLOverrideString, feed.absoluteString)
        XCTAssertNil(stock.feedURLOverrideString, "nil = Sparkle reads SUFeedURL")
        XCTAssertFalse(overridden.shouldRelaunch, "the E2E tester relaunches by hand")
        XCTAssertTrue(stock.shouldRelaunch)
    }
}
