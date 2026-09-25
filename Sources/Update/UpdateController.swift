import AppKit
import Combine
import OSLog
import Sparkle

// Ported from Ghostty (macos/Sources/Features/Update/UpdateController.swift, MIT) and adapted.

/// Owns the Sparkle updater and the view model every status bar observes.
///
/// `updater` is nil when updating is off for this process (`isEnabled`): the test host, a build
/// without a public key, or a Debug build without the feed override. Everything else still works —
/// settings are stored, the view model idles, the simulator can drive the UI — so the app never has
/// two code paths.
///
/// Not `@MainActor`: `UpdateDriver` is a plain `NSObject` implementing Sparkle's nonisolated
/// Objective-C protocols and calls back into this controller synchronously from Sparkle's main
/// thread. Every caller (Sparkle, and the app's own UI) is already on the main thread by contract.
final class UpdateController {
    static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "dev.danny.quickterm",
                               category: "updates")
    /// How long "You're up to date" stays on the bar before the state goes idle again.
    static var notFoundClearDelay: TimeInterval = 5

    let viewModel: UpdateViewModel
    private(set) var updater: SPUUpdater?
    private let driver: UpdateDriver
    private(set) var settings = UpdateSettings()
    private(set) var started = false
    /// Sparkle is about to terminate the app to install (Restart Now, `showReady`,
    /// `showInstallingUpdate`): the quit confirmation stands aside (`AppDelegate`). Not set by an
    /// Install click, which only starts a download — the user's own Cmd+Q during it still asks.
    private(set) var relaunchRequested = false
    /// Opens the update sheet for the current state; wired by the app once the sheet exists.
    var showSheet: () -> Void = {}
    private var installCancellable: AnyCancellable?
    private var stateCancellable: AnyCancellable?
    private var notFoundClearTask: DispatchWorkItem?
    /// The last transition logged; progress ticks inside one state are not transitions.
    private var loggedState = UpdateController.logDescription(.idle)

    init(enabled: Bool, feedOverride: URL? = nil, hostBundle: Bundle = .main) {
        let viewModel = UpdateViewModel()
        self.viewModel = viewModel
        self.driver = UpdateDriver(viewModel: viewModel, feedOverride: feedOverride)
        if enabled {
            updater = SPUUpdater(hostBundle: hostBundle, applicationBundle: hostBundle,
                                 userDriver: driver, delegate: driver)
        }
        driver.controller = self
        stateCancellable = viewModel.$state.sink { [weak self] state in self?.stateDidChange(state) }
    }

    /// The gate, as a pure function.
    static func isEnabled(isRunningTests: Bool, hasPublicKey: Bool, isDebugBuild: Bool,
                          feedOverride: URL?) -> Bool {
        if isRunningTests || !hasPublicKey { return false }
        return !isDebugBuild || feedOverride != nil
    }

    static var isDebugBuild: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    /// Whether `--update-feed-url` / `QUICKTERM_UPDATE_FEED_URL` is honoured: Debug builds, and the
    /// Release builds `scripts/make-release.sh` makes for the end-to-end test (`E2E_BUNDLE_ID` /
    /// `E2E_BUILD_NUMBER` add the `UPDATE_E2E` compilation condition). A shipped release is built
    /// without either flag and always reads `SUFeedURL`.
    static var allowsFeedOverride: Bool {
        #if DEBUG || UPDATE_E2E
        true
        #else
        false
        #endif
    }

    /// `SUPublicEDKey` present and non-empty: without it Sparkle's `start()` fails, which would
    /// put an error icon on every user's bar at every launch.
    static func hasPublicKey(in bundle: Bundle) -> Bool {
        guard let key = bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String else { return false }
        return !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var canCheckForUpdates: Bool { updater?.canCheckForUpdates ?? false }

    /// The config is the source of truth over Sparkle's persisted preferences: both flags are
    /// written on every apply, checks first (Sparkle drops a downloads=true while checks is false).
    func apply(_ settings: UpdateSettings) {
        self.settings = settings
        guard let updater else { return }
        updater.automaticallyChecksForUpdates = settings.checksEnabled
        updater.automaticallyDownloadsUpdates = settings.install
    }

    /// Once, at the end of `applicationDidFinishLaunching`.
    func start() {
        guard let updater, !started else { return }
        started = true
        do {
            try updater.start()
        } catch {
            Self.logger.error("updater failed to start: \(error.localizedDescription, privacy: .public)")
            viewModel.state = .error(.init(
                error: error, kind: .other,
                retry: { [weak self] in
                    self?.viewModel.state = .idle
                    self?.started = false
                    self?.start()
                },
                dismiss: { [weak self] in self?.viewModel.state = .idle }))
            return
        }
        apply(settings)
        // Sparkle's own scheduler checks at launch only when a day has passed since the last check;
        // this is what makes "at launch" true and what brings an unhandled update back after a
        // relaunch. Dispatched: start() finishes its own setup asynchronously.
        if settings.checksEnabled {
            DispatchQueue.main.async { [weak self] in self?.updater?.checkForUpdatesInBackground() }
        }
    }

    /// Check for Updates… (menu item, engine keybind action).
    ///
    /// The state switch runs before the updater is even consulted: tearing down whatever is in
    /// flight (`installCancellable`, the current state's own `cancel()`) must not depend on
    /// Sparkle being present, or a disabled controller (no updater: the test host, a build
    /// without a public key) would leave a stale install chain behind forever, wedging every
    /// later Install click. Only the actual re-check needs an updater to send it to.
    func checkForUpdates() {
        switch viewModel.state {
        case .idle, .updateAvailable, .installing:
            // With an update on screen Sparkle routes this to showUpdateInFocus (the sheet).
            guard let updater else { return }
            updater.checkForUpdates()
        case .downloading, .extracting:
            // SPUUpdater keeps canCheckForUpdates true while progress is shown, so the menu item
            // is live here. The user already said Install: show that download instead of
            // cancelling it (Ghostty's port cancelled and re-checked, losing the download).
            showSheet()
        case .checking, .notFound, .error:
            // Close it and check afresh. The settle delay is Ghostty's: one run-loop tick is not
            // enough for Sparkle to end the session. Dropping the AnyCancellable cancels the sink;
            // installUpdate()'s `== nil` guard needs this reset, or a later Install click is
            // silently ignored forever.
            installCancellable = nil
            viewModel.state.cancel()
            guard updater != nil else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(100)) { [weak self] in
                self?.updater?.checkForUpdates()
            }
        }
    }

    /// Install and Relaunch: says yes to every step from here to the installer. The relaunch flag
    /// is set later, by `showReady` / `showInstallingUpdate`, when Sparkle actually terminates.
    func installUpdate() {
        guard viewModel.state.isInstallable, installCancellable == nil else { return }
        // The sink runs at once with the current state, so the first confirm needs no extra call.
        installCancellable = viewModel.$state.sink { [weak self] state in
            guard let self else { return }
            guard state.isInstallable else {
                self.installCancellable = nil
                return
            }
            state.confirm()
        }
    }

    /// Restart Now on a staged update.
    func requestRelaunch(_ restart: () -> Void) {
        relaunchRequested = true
        restart()
    }

    /// Sparkle is about to terminate the app to install (`showReady` / `showInstallingUpdate`).
    func noteInstallerTerminating() {
        relaunchRequested = true
    }

    private func stateDidChange(_ state: UpdateState) {
        let described = Self.logDescription(state)
        if described != loggedState {
            loggedState = described
            Self.logger.info("state \(described, privacy: .public)")
        }
        switch state {
        case .idle, .notFound, .error, .updateAvailable:
            relaunchRequested = false
        case .checking, .downloading, .extracting, .installing:
            break
        }
        notFoundClearTask?.cancel()
        notFoundClearTask = nil
        if case .notFound(let notFound) = state {
            let task = DispatchWorkItem { [weak self] in self?.clearNotFound(notFound.id) }
            notFoundClearTask = task
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.notFoundClearDelay, execute: task)
        }
    }

    /// One line per state for the `updates` log: the case and what its payload says about the
    /// update (version, stage, who asked), never the progress figures.
    static func logDescription(_ state: UpdateState) -> String {
        switch state {
        case .idle: "idle"
        case .checking: "checking"
        case .updateAvailable(let a):
            "updateAvailable version=\(a.version) stage=\(a.stage) userInitiated=\(a.userInitiated)"
        case .downloading(let d): "downloading version=\(d.version ?? "?")"
        case .extracting(let e): "extracting version=\(e.version ?? "?")"
        case .installing(let i):
            "installing version=\(i.version ?? "?") autoUpdate=\(i.isAutoUpdate) userInitiated=\(i.userInitiated)"
        case .notFound: "notFound"
        case .error(let f): "error kind=\(f.kind)"
        }
    }

    /// The 5 s timer, or a click on the bar during "up to date": back to idle. `id` guards a
    /// timer that outlived its own not-found (a second check meanwhile).
    func clearNotFound(_ id: UUID? = nil) {
        guard case .notFound(let notFound) = viewModel.state else { return }
        if let id, id != notFound.id { return }
        viewModel.state = .idle
    }
}
