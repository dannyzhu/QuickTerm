import AppKit
import Sparkle

// Ported from Ghostty (macos/Sources/Features/Update/UpdateDriver.swift + UpdateDelegate.swift,
// MIT) and adapted: no SPUStandardUserDriver fallback and no terminal-window observers; a
// stage-aware showUpdateFound; showUpdateInFocus opens the sheet; errors and not-found are
// acknowledged at once so no Sparkle session is ever held by a view.

/// Mirrors every Sparkle callback into the view model.
final class UpdateDriver: NSObject, SPUUserDriver, SPUUpdaterDelegate {
    let viewModel: UpdateViewModel
    /// Debug-only feed override (`--update-feed-url`); nil = Sparkle reads `SUFeedURL`.
    let feedOverride: URL?
    weak var controller: UpdateController?

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
        viewModel.state = .checking(.init(cancel: cancellation))
    }

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState,
                         reply: @escaping @Sendable (SPUUserUpdateChoice) -> Void) {
        viewModel.state = Self.foundState(item: appcastItem, stage: state.stage,
                                          userInitiated: state.userInitiated, reply: reply)
    }

    /// Pure, so tests need no `SPUUserUpdateState`. A staged update (`.installing`) is the
    /// "quit or restart to finish" state, not a fresh "78 MB available".
    static func foundState(item: SUAppcastItem, stage: SPUUserUpdateStage, userInitiated: Bool,
                           reply: @escaping @Sendable (SPUUserUpdateChoice) -> Void) -> UpdateState {
        switch stage {
        case .installing:
            return .installing(.init(isAutoUpdate: true, version: item.displayVersionString,
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
        acknowledgement()
        viewModel.state = .notFound(.init())
    }

    func showUpdaterError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        let nsError = error as NSError
        UpdateController.logger.error("updater error \(nsError.domain, privacy: .public)/\(nsError.code): \(error.localizedDescription, privacy: .public)")
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
        controller?.noteInstallerTerminating()
        reply(.install)
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool,
                              retryTerminatingApplication: @escaping () -> Void) {
        controller?.noteInstallerTerminating()
        viewModel.state = .installing(.init(isAutoUpdate: false, version: versionInFlight,
                                            restart: retryTerminatingApplication, later: {}, skip: nil))
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
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
    func dismissUpdateInstallation() {
        switch viewModel.state {
        case .notFound, .error:
            break
        default:
            viewModel.state = .idle
        }
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
        viewModel.state = .installing(.init(isAutoUpdate: true, version: item.displayVersionString,
                                            restart: immediateInstallHandler, later: {}, skip: nil))
        return true
    }

    func updaterShouldRelaunchApplication(_ updater: SPUUpdater) -> Bool {
        shouldRelaunch
    }

    func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        NSApp.invalidateRestorableState()
        for window in NSApp.windows { window.invalidateRestorableState() }
    }
}
