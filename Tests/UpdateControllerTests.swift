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

    /// Set only when Sparkle is about to terminate the app (spec §4): Restart Now, `showReady`,
    /// `showInstallingUpdate`. An Install click only starts a download, during which the user's
    /// own Cmd+Q must still ask about the open panes.
    func testRelaunchRequestedOnlyWhenSparkleIsAboutToTerminate() {
        var replies: [SPUUserUpdateChoice] = []
        controller.viewModel.state = .updateAvailable(.init(appcastItem: SUAppcastItem.empty(), stage: .notDownloaded,
                                                            userInitiated: true, reply: { replies.append($0) }))
        XCTAssertFalse(controller.relaunchRequested)
        controller.installUpdate()
        XCTAssertEqual(replies, [.install], "the chain confirmed the available state")
        XCTAssertFalse(controller.relaunchRequested, "Install and Relaunch alone does not bypass the quit confirmation")
        controller.viewModel.state = .downloading(.init(cancel: {}, version: "9", expectedLength: 10, progress: 1))
        XCTAssertFalse(controller.relaunchRequested, "nor does the download it starts")
        driver.showReady(toInstallAndRelaunch: { _ in })
        XCTAssertTrue(controller.relaunchRequested, "showReady: Sparkle terminates the app next")
        controller.viewModel.state = .idle
        XCTAssertFalse(controller.relaunchRequested, "cancelled: cleared")

        var restarted = false
        controller.viewModel.state = .installing(.init(isAutoUpdate: true, userInitiated: false, version: "9", restart: { restarted = true }, later: {}, skip: nil))
        XCTAssertFalse(controller.relaunchRequested, "a staged update alone asks for nothing")
        if case .installing(let installing) = controller.viewModel.state { controller.requestRelaunch(installing.restart) }
        XCTAssertTrue(restarted)
        XCTAssertTrue(controller.relaunchRequested, "Restart Now asks for a relaunch")

        controller.viewModel.state = .error(.init(error: NSError(domain: "x", code: 1), kind: .other, retry: {}, dismiss: {}))
        XCTAssertFalse(controller.relaunchRequested, "an error clears it")
        driver.showInstallingUpdate(withApplicationTerminated: false, retryTerminatingApplication: {})
        XCTAssertTrue(controller.relaunchRequested, "Sparkle terminating the app sets it")
    }

    /// installUpdate() cancels its confirm-everything sink but must leave `installCancellable` at
    /// nil, or every later Install click is silently ignored until restart (the `== nil` guard).
    /// checkForUpdates() has to do that teardown itself — the test host has no updater, so if the
    /// teardown depended on one (the old top-of-function `guard let updater`), it would never run.
    /// Proven two ways: the check's own `cancel` closure only fires through checkForUpdates()
    /// itself, and the next available update is not confirmed until Install is clicked again — a
    /// stale chain would confirm it on arrival.
    func testInstallUpdateRecoversAfterACheckForUpdatesDuringInstall() {
        var firstReplies: [SPUUserUpdateChoice] = []
        controller.viewModel.state = .updateAvailable(.init(appcastItem: SUAppcastItem.empty(), stage: .notDownloaded,
                                                            userInitiated: true, reply: { firstReplies.append($0) }))
        controller.installUpdate()
        XCTAssertEqual(firstReplies, [.install])

        var cancelled = false
        controller.viewModel.state = .checking(.init(cancel: { cancelled = true }))
        controller.checkForUpdates() // no updater in tests: this alone must tear the chain down
        XCTAssertTrue(cancelled, "checkForUpdates must cancel the in-flight check itself, updater or not")

        var secondReplies: [SPUUserUpdateChoice] = []
        controller.viewModel.state = .updateAvailable(.init(appcastItem: SUAppcastItem.empty(), stage: .notDownloaded,
                                                            userInitiated: true, reply: { secondReplies.append($0) }))
        XCTAssertTrue(secondReplies.isEmpty, "the old chain is gone: nothing confirms a new update by itself")
        controller.installUpdate()
        XCTAssertEqual(secondReplies, [.install], "a fresh Install must still go through: checkForUpdates already dropped the stale chain")
    }

    /// SPUUpdater keeps `canCheckForUpdates` true while a download shows progress, so the menu
    /// item is live: it shows the running download instead of cancelling it.
    func testCheckForUpdatesDuringADownloadShowsItsSheet() {
        var shown = 0
        controller.showSheet = { shown += 1 }
        var cancelled = false
        let downloading = UpdateState.downloading(.init(cancel: { cancelled = true }, version: "9", expectedLength: 10, progress: 1))
        controller.viewModel.state = downloading
        controller.checkForUpdates()
        XCTAssertEqual(controller.viewModel.state, downloading, "the download keeps running")
        XCTAssertFalse(cancelled)
        XCTAssertEqual(shown, 1)

        let extracting = UpdateState.extracting(.init(version: "9", progress: 0.5))
        controller.viewModel.state = extracting
        controller.checkForUpdates()
        XCTAssertEqual(controller.viewModel.state, extracting)
        XCTAssertEqual(shown, 2)
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

        controller.viewModel.state = .installing(.init(isAutoUpdate: true, userInitiated: false, version: "9", restart: {}, later: {}, skip: nil))
        driver.dismissUpdateInstallation()
        XCTAssertTrue(controller.viewModel.state.isIdle, "installing still tears down")
    }

    func testAStagedUpdateMapsToInstalling() {
        var replies: [SPUUserUpdateChoice] = []
        let state = UpdateDriver.foundState(item: SUAppcastItem.empty(), stage: .installing, userInitiated: false) { replies.append($0) }
        guard case .installing(let installing) = state else { return XCTFail("expected installing, got \(state)") }
        XCTAssertTrue(installing.isAutoUpdate)
        XCTAssertFalse(installing.userInitiated)
        installing.restart(); installing.later(); installing.skip?()
        XCTAssertEqual(replies, [.install, .dismiss, .skip])
        let resumed = UpdateDriver.foundState(item: SUAppcastItem.empty(), stage: .installing, userInitiated: true) { _ in }
        guard case .installing(let manual) = resumed else { return XCTFail("expected installing, got \(resumed)") }
        XCTAssertTrue(manual.userInitiated, "a manual check that resumed it: the sheet opens by itself")
    }

    // MARK: a staged update resumed by a manual check

    /// Later replies `.dismiss`, and Sparkle follows it with `dismissUpdateInstallation`. The
    /// update still installs on quit (spec §3), so the icon has to stay — like the
    /// `willInstallUpdateOnQuit` version of the same state.
    func testLaterOnAResumedStagedUpdateKeepsTheIcon() {
        var replies: [SPUUserUpdateChoice] = []
        driver.handleUpdateFound(item: SUAppcastItem.empty(), stage: .installing, userInitiated: true) { replies.append($0) }
        guard case .installing(let staged) = controller.viewModel.state else { return XCTFail("expected installing") }
        XCTAssertTrue(staged.userInitiated)
        staged.later()
        XCTAssertEqual(replies, [.dismiss])
        driver.dismissUpdateInstallation()
        guard case .installing(let kept) = controller.viewModel.state else {
            return XCTFail("Later keeps a staged update on the bar: it still installs on quit")
        }
        XCTAssertEqual(kept.version, staged.version)
        XCTAssertTrue(kept.isAutoUpdate)
        XCTAssertFalse(kept.userInitiated)
        XCTAssertNil(kept.skip, "the reply block behind Skip is spent")
        driver.dismissUpdateInstallation()
        XCTAssertTrue(controller.viewModel.state.isIdle, "the mark is honoured once")
    }

    /// The kept state's reply block is spent: Restart Now there re-enters through a fresh check,
    /// and the staged update Sparkle resumes for it is installed without asking again.
    func testRestartNowOnAKeptStagedUpdateInstallsItOnResume() {
        var replies: [SPUUserUpdateChoice] = []
        driver.handleUpdateFound(item: SUAppcastItem.empty(), stage: .installing, userInitiated: true) { replies.append($0) }
        guard case .installing(let staged) = controller.viewModel.state else { return XCTFail("expected installing") }
        staged.later()
        driver.dismissUpdateInstallation()
        guard case .installing(let kept) = controller.viewModel.state else { return XCTFail("expected the kept state") }
        controller.requestRelaunch(kept.restart)
        XCTAssertEqual(replies, [.dismiss], "the spent reply block is never called again")

        var resumed: [SPUUserUpdateChoice] = []
        driver.handleUpdateFound(item: SUAppcastItem.empty(), stage: .installing, userInitiated: true) { resumed.append($0) }
        XCTAssertEqual(resumed, [.install], "Restart Now was the answer already")
        XCTAssertTrue(controller.relaunchRequested)

        var again: [SPUUserUpdateChoice] = []
        driver.handleUpdateFound(item: SUAppcastItem.empty(), stage: .installing, userInitiated: true) { again.append($0) }
        XCTAssertTrue(again.isEmpty, "only the one resume is answered for the user; the next asks")
        guard case .installing = controller.viewModel.state else { return XCTFail("expected installing") }
    }

    func testSkipOnAResumedStagedUpdateGoesIdle() {
        var replies: [SPUUserUpdateChoice] = []
        driver.handleUpdateFound(item: SUAppcastItem.empty(), stage: .installing, userInitiated: true) { replies.append($0) }
        guard case .installing(let staged) = controller.viewModel.state else { return XCTFail("expected installing") }
        staged.skip?()
        XCTAssertEqual(replies, [.skip])
        driver.dismissUpdateInstallation()
        XCTAssertTrue(controller.viewModel.state.isIdle, "skipped: un-staged, nothing left to show")
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

    /// The only way into the `install = true` path: staged by Sparkle's automatic driver, shown as
    /// "quit or restart to finish", and Restart Now is Sparkle's immediate-install block.
    func testWillInstallUpdateOnQuitStagesTheUpdate() {
        let item = SUAppcastItem.empty()
        let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: driver, delegate: driver)
        var immediate = 0
        let handled = driver.updater(updater, willInstallUpdateOnQuit: item, immediateInstallationBlock: { immediate += 1 })
        XCTAssertTrue(handled, "QuickTerm shows the staged update itself")
        guard case .installing(let staged) = controller.viewModel.state else { return XCTFail("expected installing") }
        XCTAssertTrue(staged.isAutoUpdate)
        XCTAssertFalse(staged.userInitiated, "staged in the background: the icon only")
        XCTAssertEqual(staged.version, item.displayVersionString)
        XCTAssertNil(staged.skip)
        XCTAssertEqual(immediate, 0, "nothing installs until asked")
        staged.restart()
        XCTAssertEqual(immediate, 1, "Restart Now invokes the immediate-install block exactly once")
    }

    func testUpdateInstalledAndRelaunchedAcknowledgesOnceAndGoesIdle() {
        controller.viewModel.state = .installing(.init(isAutoUpdate: true, userInitiated: false, version: "9", restart: {}, later: {}, skip: nil))
        var acknowledged = 0
        driver.showUpdateInstalledAndRelaunched(true) { acknowledged += 1 }
        XCTAssertEqual(acknowledged, 1)
        XCTAssertTrue(controller.viewModel.state.isIdle)
    }

    /// The `updates` log names each transition by case and payload, never by progress figures.
    func testTheLogLineOfAState() {
        XCTAssertEqual(UpdateController.logDescription(.idle), "idle")
        XCTAssertEqual(UpdateController.logDescription(.installing(.init(isAutoUpdate: true, userInitiated: true, version: "1.6.8",
                                                                         restart: {}, later: {}, skip: nil))),
                       "installing version=1.6.8 autoUpdate=true userInitiated=true")
        XCTAssertEqual(UpdateController.logDescription(.downloading(.init(cancel: {}, version: "1.6.8", expectedLength: 100, progress: 42))),
                       UpdateController.logDescription(.downloading(.init(cancel: {}, version: "1.6.8", expectedLength: 100, progress: 43))),
                       "a progress tick is not a transition")
    }

    func testTheTestHostMayOverrideTheFeed() {
        XCTAssertTrue(UpdateController.allowsFeedOverride, "the test host is a Debug build")
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
        // A NO here makes Sparkle abort the installation outright (SPUInstallerDriver
        // mayUpdateAndRestart), so even the E2E override says yes; the E2E build carries its
        // overrides across the relaunch instead.
        XCTAssertTrue(overridden.shouldRelaunch, "NO would abort the install, not skip the relaunch")
        XCTAssertTrue(stock.shouldRelaunch)
    }
}
