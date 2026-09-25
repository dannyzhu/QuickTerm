import AppKit
import Sparkle

// Ported from Ghostty (macos/Sources/Features/Update/UpdateDriver.swift + UpdateDelegate.swift,
// MIT) and adapted: no SPUStandardUserDriver fallback and no terminal-window observers; a
// stage-aware showUpdateFound; showUpdateInFocus opens the sheet; errors and not-found are
// acknowledged at once so no Sparkle session is ever held by a view.

/// Mirrors every Sparkle callback into the view model.
final class UpdateDriver: NSObject, SPUUserDriver, SPUUpdaterDelegate {
    let viewModel: UpdateViewModel
    /// The feed override (`--update-feed-url`, Debug and E2E builds only:
    /// `UpdateController.allowsFeedOverride`); nil = Sparkle reads `SUFeedURL`.
    let feedOverride: URL?
    weak var controller: UpdateController?
    /// Later on a staged update that a manual check resumed: Sparkle follows the `.dismiss` with
    /// `dismissUpdateInstallation`, but the update stays staged and still installs on quit (spec
    /// §3), so that one teardown keeps the "quit or restart to finish" state instead of going idle.
    private var keepInstallingOnDismiss = false
    /// Restart Now on that kept state: its reply block is spent, so it re-enters through a fresh
    /// manual check, and the staged update Sparkle resumes for it is answered `.install` at once.
    private var installOnResume = false

    init(viewModel: UpdateViewModel, feedOverride: URL?) {
        self.viewModel = viewModel
        self.feedOverride = feedOverride
        super.init()
    }

    /// The version an in-flight state is about, for the download / extraction states.
    private var versionInFlight: String? {
        switch viewModel.state {
        case .updateAvailable(let a): return a.version
        case .downloading(let d): return d.version
        case .extracting(let e): return e.version
        case .installing(let i): return i.version
        default: return nil
        }
    }

    // MARK: SPUUserDriver

    func show(_ request: SPUUpdatePermissionRequest,
              reply: @escaping @Sendable (SUUpdatePermissionResponse) -> Void) {
        // SUEnableAutomaticChecks is set, so Sparkle should never ask; if it does, the config answers.
        let checks = controller?.settings.checksEnabled ?? true
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: checks, sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        keepInstallingOnDismiss = false
        viewModel.state = .checking(.init(cancel: cancellation))
    }

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState,
                         reply: @escaping @Sendable (SPUUserUpdateChoice) -> Void) {
        handleUpdateFound(item: appcastItem, stage: state.stage, userInitiated: state.userInitiated, reply: reply)
    }

    /// `showUpdateFound` with Sparkle's state unpacked, so tests need no `SPUUserUpdateState`
    /// (its initializer is unavailable).
    func handleUpdateFound(item: SUAppcastItem, stage: SPUUserUpdateStage, userInitiated: Bool,
                           reply: @escaping @Sendable (SPUUserUpdateChoice) -> Void) {
        let answeredAlready = installOnResume
        installOnResume = false
        guard stage == .installing else {
            viewModel.state = Self.foundState(item: item, stage: stage, userInitiated: userInitiated, reply: reply)
            return
        }
        if answeredAlready {
            // Restart Now on the kept staged update (`resumeStagedInstall`): Sparkle terminates
            // the app to install as soon as it has the answer.
            UpdateController.logger.info("resumed staged update \(item.displayVersionString, privacy: .public): installing now (Restart Now)")
            controller?.noteInstallerTerminating()
            reply(.install)
            return
        }
        // A staged update keeps its icon after Later (see `keepInstallingOnDismiss`). The reply
        // is `@Sendable` by Sparkle's signature, but QuickTerm only ever answers on the main
        // thread (the sheet's buttons, `UpdateState.cancel()`).
        let answer: @Sendable (SPUUserUpdateChoice) -> Void = { [weak self] choice in
            if choice == .dismiss {
                MainActor.assumeIsolated { self?.keepInstallingOnDismiss = true }
            }
            reply(choice)
        }
        viewModel.state = Self.foundState(item: item, stage: stage, userInitiated: userInitiated, reply: answer)
    }

    /// Pure, so tests need no `SPUUserUpdateState`. A staged update (`.installing`) is the
    /// "quit or restart to finish" state, not a fresh "78 MB available".
    static func foundState(item: SUAppcastItem, stage: SPUUserUpdateStage, userInitiated: Bool,
                           reply: @escaping @Sendable (SPUUserUpdateChoice) -> Void) -> UpdateState {
        switch stage {
        case .installing:
            return .installing(.init(isAutoUpdate: true, userInitiated: userInitiated, version: item.displayVersionString,
                                     restart: { reply(.install) }, later: { reply(.dismiss) },
                                     skip: { reply(.skip) }))
        case .downloaded:
            return .updateAvailable(.init(appcastItem: item, stage: .downloaded,
                                          userInitiated: userInitiated, reply: reply))
        default:
            return .updateAvailable(.init(appcastItem: item, stage: .notDownloaded,
                                          userInitiated: userInitiated, reply: reply))
        }
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {
        // The feed carries no releaseNotesLink; notes are fetched by ReleaseNotes.
    }

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {}

    func showUpdateNotFoundWithError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        installOnResume = false
        acknowledgement()
        viewModel.state = .notFound(.init())
    }

    func showUpdaterError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        let nsError = error as NSError
        UpdateController.logger.error("updater error \(nsError.domain, privacy: .public)/\(nsError.code): \(error.localizedDescription, privacy: .public)")
        installOnResume = false
        acknowledgement()
        viewModel.state = .error(.init(
            error: error,
            kind: UpdateState.Failure.kind(domain: nsError.domain, code: nsError.code),
            retry: { [weak self] in
                self?.viewModel.state = .idle
                DispatchQueue.main.async { self?.controller?.checkForUpdates() }
            },
            dismiss: { [weak self] in self?.viewModel.state = .idle }))
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        viewModel.state = .downloading(.init(cancel: cancellation, version: versionInFlight,
                                             expectedLength: nil, progress: 0))
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        guard case .downloading(let d) = viewModel.state else { return }
        viewModel.state = .downloading(.init(cancel: d.cancel, version: d.version,
                                             expectedLength: expectedContentLength, progress: 0))
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        guard case .downloading(let d) = viewModel.state else { return }
        viewModel.state = .downloading(.init(cancel: d.cancel, version: d.version,
                                             expectedLength: d.expectedLength, progress: d.progress + length))
    }

    func showDownloadDidStartExtractingUpdate() {
        viewModel.state = .extracting(.init(version: versionInFlight, progress: 0))
    }

    func showExtractionReceivedProgress(_ progress: Double) {
        viewModel.state = .extracting(.init(version: versionInFlight, progress: progress))
    }

    func showReady(toInstallAndRelaunch reply: @escaping @Sendable (SPUUserUpdateChoice) -> Void) {
        // The user already said Install and Relaunch; nothing to ask again.
        UpdateController.logger.info("ready to install: replying install, Sparkle terminates the app next")
        controller?.noteInstallerTerminating()
        reply(.install)
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool,
                              retryTerminatingApplication: @escaping () -> Void) {
        UpdateController.logger.info("installing update (application terminated: \(applicationTerminated, privacy: .public))")
        controller?.noteInstallerTerminating()
        viewModel.state = .installing(.init(isAutoUpdate: false, userInitiated: false, version: versionInFlight,
                                            restart: retryTerminatingApplication, later: {}, skip: nil))
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        UpdateController.logger.info("update installed (relaunched: \(relaunched, privacy: .public))")
        acknowledgement()
        viewModel.state = .idle
    }

    func showUpdateInFocus() {
        controller?.showSheet()
    }

    /// Sparkle's `abortUpdate` calls this after acknowledging `showUpdateNotFoundWithError` /
    /// `showUpdaterError` (SPUUIBasedUpdateDriver.m), one run-loop turn after the state was set.
    /// `.notFound` and `.error` are already fully acknowledged at that point — no Sparkle session
    /// stands behind them any more — and are QuickTerm's own display from there on, cleared by the
    /// not-found timer, a click, OK or Retry; only every other state actually needs tearing down.
    ///
    /// The one exception is Later on a resumed staged update (`keepInstallingOnDismiss`): the
    /// update still installs on quit, so the state stays `.installing`, re-pointed away from the
    /// spent reply block — Restart Now resumes it through a fresh check, and Skip is gone until
    /// then (a resumed sheet offers it again).
    func dismissUpdateInstallation() {
        installOnResume = false
        let keep = keepInstallingOnDismiss
        keepInstallingOnDismiss = false
        switch viewModel.state {
        case .notFound, .error:
            break
        case .installing(let staged) where keep:
            UpdateController.logger.info("Later on a resumed staged update: it stays staged and installs on quit")
            viewModel.state = .installing(.init(isAutoUpdate: true, userInitiated: false, version: staged.version,
                                                restart: { [weak self] in self?.resumeStagedInstall() },
                                                later: {}, skip: nil))
        default:
            viewModel.state = .idle
        }
    }

    /// Restart Now on the kept staged update: a manual check makes Sparkle resume the staged
    /// update (`showUpdateFound(stage: .installing)`), which `handleUpdateFound` then answers.
    private func resumeStagedInstall() {
        installOnResume = true
        controller?.checkForUpdates()
    }

    // MARK: SPUUpdaterDelegate

    /// nil = Sparkle reads `SUFeedURL` from the Info.plist.
    var feedURLOverrideString: String? { feedOverride?.absoluteString }

    /// Under the E2E feed override Sparkle installs and quits; the tester relaunches by hand with
    /// the same arguments (Sparkle's relaunch carries neither arguments nor environment).
    var shouldRelaunch: Bool { feedOverride == nil }

    func feedURLString(for updater: SPUUpdater) -> String? {
        feedURLOverrideString
    }

    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        UpdateController.logger.info("staged \(item.displayVersionString, privacy: .public) to install on quit")
        viewModel.state = .installing(.init(isAutoUpdate: true, userInitiated: false, version: item.displayVersionString,
                                            restart: immediateInstallHandler, later: {}, skip: nil))
        return true
    }

    func updaterShouldRelaunchApplication(_ updater: SPUUpdater) -> Bool {
        UpdateController.logger.info("relaunch after install: \(self.shouldRelaunch, privacy: .public) (feed override: \(self.feedOverride != nil, privacy: .public))")
        return shouldRelaunch
    }

    func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        NSApp.invalidateRestorableState()
        for window in NSApp.windows { window.invalidateRestorableState() }
    }
}
