import AppKit
import GhosttyKit
import OSLog
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Isolates lifecycle side effects while running as the TEST_HOST: do not restore or save the
    /// user's state, do not close the window on an empty tree, and do not quit when a window
    /// closes (the host has to stay alive until the tests finish).
    static let isRunningTests =
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "dev.danny.quickterm",
        category: String(describing: AppDelegate.self)
    )

    /// The registry of "screens": the only strong reference to the controllers.
    let screens = ScreenRegistry()
    var controllers: [MainWindowController] { screens.controllers }

    /// The process-level session (config / keybindings / system stats / the ledger of fullscreen
    /// presentationOptions).
    /// Created in `applicationDidFinishLaunching`; the config has to be fully loaded before the
    /// first screen is created.
    private(set) var session: AppSession!

    /// Where actions land: the key window's controller, falling back to the first screen.
    /// (Historically this was the one main controller; 6 test files reach for the fixture by this
    /// name.)
    var controller: MainWindowController! { screens.current }

    /// The engine instance (the GhosttyEmbed layer reaches it through NSApp.delegate).
    var ghostty: Ghostty.App!
    private(set) var themeManager: ThemeManager!
    let undoManager = UndoManager()

    /// The aggregating extension host (BrowserExtensionManager.host is weak, so it has to be held
    /// strongly from here).
    private var extensionHost: AppBrowserExtensionHost?
    /// Answers the engine's clipboard questions (unsafe paste, OSC 52 read / write); installed
    /// once the engine exists, for every surface in every window.
    private(set) var clipboardConfirmation: ClipboardConfirmation?

    /// **The three "point this instance somewhere else" overrides, from arguments as well as from
    /// the environment.**
    ///
    /// The environment variables came first and still work. The arguments exist because of one
    /// hard fact about macOS: a binary started straight from a shell is not, as far as
    /// `UNUserNotificationCenter` is concerned, an app — it has no LaunchServices registration, so
    /// banners are refused and every smoke test of the notification path measured the wrong thing.
    /// The road that *is* a real launch is `open -n -a QuickTerm.app --args …`, and `open` passes
    /// **arguments but not environment**. Hence the same three switches, spelled as arguments.
    ///
    /// **An argument wins over the variable.** The variable is ambient — inherited from whatever
    /// shell, CI job or parent app happened to export it — while an argument was typed for this
    /// launch. When the two disagree, the specific one is the one that was meant.
    ///
    /// A pure value type with no side effects on purpose: this is the one piece of launch wiring
    /// that can be tested without launching anything.
    struct LaunchOverrides: Equatable {
        /// `--config-file` / `QUICKTERM_CONFIG_FILE`
        var configFile: String?
        /// `--state-file` / `QUICKTERM_STATE_FILE`
        var stateFile: String?
        /// `--control-socket` / `QUICKTERM_CONTROL_SOCKET`
        var controlSocket: String?
        /// `--update-feed-url` / `QUICKTERM_UPDATE_FEED_URL`: honoured by Debug builds and by the
        /// end-to-end test's Release builds only (`UpdateController.allowsFeedOverride`)
        var updateFeed: String?

        /// The argument names, and the variable each falls back to.
        static let switches: [(argument: String, variable: String, path: WritableKeyPath<LaunchOverrides, String?>)] = [
            ("--config-file", "QUICKTERM_CONFIG_FILE", \.configFile),
            ("--state-file", "QUICKTERM_STATE_FILE", \.stateFile),
            ("--control-socket", "QUICKTERM_CONTROL_SOCKET", \.controlSocket),
            ("--update-feed-url", "QUICKTERM_UPDATE_FEED_URL", \.updateFeed),
        ]

        init(arguments: [String], environment: [String: String]) {
            for (argument, variable, path) in Self.switches {
                self[keyPath: path] = Self.value(of: argument, in: arguments)
                    ?? Self.nonEmpty(environment[variable])
            }
        }

        /// `--config-file <path>` and `--config-file=<path>` both, because both are typed. The
        /// **last** occurrence wins, which is what every `getopt` in the world does and what a
        /// wrapper script appending a flag to an inherited command line expects.
        private static func value(of argument: String, in arguments: [String]) -> String? {
            var found: String?
            var index = arguments.startIndex
            while index < arguments.endIndex {
                let item = arguments[index]
                if item == argument {
                    // An empty value is "unset", exactly as an empty variable is: a switch with
                    // nothing after it must not point the config at the current directory.
                    found = nonEmpty(arguments.indices.contains(index + 1) ? arguments[index + 1] : nil) ?? found
                    index += 2
                    continue
                }
                if item.hasPrefix(argument + "=") {
                    found = nonEmpty(String(item.dropFirst(argument.count + 1))) ?? found
                }
                index += 1
            }
            return found
        }

        private static func nonEmpty(_ raw: String?) -> String? {
            guard let raw, !raw.isEmpty else { return nil }
            return raw
        }

        /// `~` is expanded here, once, so that the two roads cannot expand it differently —
        /// `open --args` is the road where a shell has *not* already done it.
        private static func expand(_ path: String?) -> String? {
            path.map { ($0 as NSString).expandingTildeInPath }
        }

        var configURL: URL? { Self.expand(configFile).map { URL(fileURLWithPath: $0) } }
        var stateURL: URL? { Self.expand(stateFile).map { URL(fileURLWithPath: $0) } }
        var controlSocketPath: String? { Self.expand(controlSocket) }
        var updateFeedURL: URL? { updateFeed.flatMap { URL(string: $0) } }

        /// True when this launch named nothing at all.
        var isEmpty: Bool {
            configFile == nil && stateFile == nil && controlSocket == nil && updateFeed == nil
        }

        /// The key the end-to-end build keeps its overrides under, in its own defaults domain
        /// (the E2E bundle identifier's; the tear-down's `defaults delete` wipes it).
        static let persistedKey = "e2e.launch-overrides"

        /// The end-to-end build only: the caller sits behind `UPDATE_E2E`, the function is
        /// compiled everywhere so the tests can reach it. Sparkle relaunches the app after an
        /// install with neither its arguments nor its environment, and an E2E instance that came
        /// back bare would open the user's real config, socket and `state.json`. So a launch that
        /// names any override stores the whole set, and a launch that names none takes the stored
        /// set back: the relaunched instance keeps running against the scratch locations.
        func reconciled(with defaults: UserDefaults) -> LaunchOverrides {
            guard isEmpty else {
                var stored: [String: String] = [:]
                for (argument, _, path) in Self.switches {
                    if let value = self[keyPath: path] { stored[argument] = value }
                }
                defaults.set(stored, forKey: Self.persistedKey)
                return self
            }
            guard let stored = defaults.dictionary(forKey: Self.persistedKey) as? [String: String] else {
                return self
            }
            var restored = LaunchOverrides(arguments: [], environment: [:])
            for (argument, _, path) in Self.switches { restored[keyPath: path] = stored[argument] }
            return restored
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // CLI / smoke test: `open -a QuickTerm --args --open-browser [url]` opens a browser pane
        // once the app has launched.
        if let i = CommandLine.arguments.firstIndex(of: "--open-browser") {
            let raw = CommandLine.arguments.dropFirst(i + 1).first
            // Resolve late: by then the controller exists and config.toml's browser-home/search
            // have made it into settings, so a bare domain or a search term resolves by the same
            // rules the address bar uses.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let controller = self?.screens.primary else { return }
                let url = raw.flatMap { BrowserPaneView.settings.url(forInput: $0) } ?? BrowserPaneView.settings.homeURL
                controller.openBrowserPane(url: url, from: controller.focusedPane)
            }
        }
        NSApp.setActivationPolicy(.regular)

        // Layer 3 of the config chain: ThemeManager writes the overlay (theme colors + opacity)
        // during init, and has to run before the engine is created so that the engine already
        // carries the theme on its very first load.
        Ghostty.Config.quickTermOverlayPath = EngineOverlay.url.path
        let themeManager = ThemeManager()
        self.themeManager = themeManager

        // The engine loads its own config internally (including ~/.config/ghostty/config) and calls
        // app_new; ghostty_init already ran in main.swift, ahead of NSApplicationMain.
        ghostty = Ghostty.App()
        guard ghostty.readiness == .ready else {
            let alert = NSAlert()
            alert.messageText = L("window.engine.failed-title")
            alert.informativeText = L("window.engine.failed-detail", String(describing: ghostty.readiness))
            alert.runModal()
            NSApp.terminate(nil)
            return
        }

        // The engine hands "ask the user first" clipboard requests to the app as a notification;
        // without this observer they are never completed (an OSC 52 read leaves the program
        // waiting on its reply for good).
        clipboardConfirmation = ClipboardConfirmation()

        // The app-level half of live theme switching: the engine's reloadConfig runs exactly once
        // per change. (Each screen's per-surface reload and window appearance are registered by its
        // own controller; see MainWindowController.init.)
        themeManager.addOverlayListener(token: self) { [weak self] in
            self?.ghostty.reloadConfig(soft: false)
        }

        // Browser extensions: as far as an extension is concerned a pane is a "window", and the
        // host aggregates every screen.
        let host = AppBrowserExtensionHost(registry: screens)
        extensionHost = host
        BrowserExtensionManager.shared.host = host

        // The process-level session: the config is in place before any window is built, so
        // controllers no longer each read from disk and each install their own watcher.
        // Order matters here: ThemeManager and the engine both have to be ready already
        // (applyGlobalConfig writes the engine overlay and triggers one live reload).
        // A second instance (development / smoke tests) points the saved state and the control
        // socket elsewhere through environment variables, so running a Debug build does not steal
        // the socket from the user's QuickTerm or overwrite their session.
        // With neither variable set this is the normal single-instance behavior (the copy under
        // Application Support).
        // Arguments as well as variables, argument wins - see `LaunchOverrides`. `open -n -a
        // QuickTerm.app --args --state-file …` is the only way to start a second instance that
        // macOS treats as a real app (and therefore the only way to test notifications), and
        // `open` does not pass an environment.
        let launched = LaunchOverrides(arguments: CommandLine.arguments,
                                       environment: ProcessInfo.processInfo.environment)
        #if UPDATE_E2E
        // The end-to-end build (spec §11): Sparkle's relaunch drops the arguments, so the overrides
        // ride across it in this build's own defaults domain (`LaunchOverrides.reconciled`).
        let overrides = launched.reconciled(with: .standard)
        UpdateController.logger.info("E2E launch overrides (restored: \(launched.isEmpty, privacy: .public)): config=\(overrides.configFile ?? "-", privacy: .public) state=\(overrides.stateFile ?? "-", privacy: .public) socket=\(overrides.controlSocket ?? "-", privacy: .public) feed=\(overrides.updateFeed ?? "-", privacy: .public)")
        #else
        let overrides = launched
        #endif
        // The config file can be pointed elsewhere too: switches like `[control] send-text` can
        // only be read from the config, and smoke-testing a Debug build must never touch the user's
        // real ~/.config/quickterm/config.toml.
        // This has to be set before loadInitialConfig.
        if let url = overrides.configURL { ConfigStore.configURLOverride = url }
        // The updater: the gate decides once per launch (docs/superpowers/specs/2026-09-25-auto-update-design.md §8).
        // A Debug build only updates against an explicit feed override, so a build in DerivedData is
        // never replaced by a release DMG. Release builds ignore the override, except the ones
        // make-release.sh builds for the end-to-end test (the UPDATE_E2E compilation condition).
        let feedOverride: URL? = UpdateController.allowsFeedOverride ? overrides.updateFeedURL : nil
        let updates = UpdateController(
            enabled: UpdateController.isEnabled(
                isRunningTests: Self.isRunningTests,
                hasPublicKey: UpdateController.hasPublicKey(in: .main),
                isDebugBuild: UpdateController.isDebugBuild,
                feedOverride: feedOverride),
            feedOverride: feedOverride)
        let session = AppSession(
            screens: screens, themeManager: themeManager,
            stateURL: overrides.stateURL,
            controlSocketPath: overrides.controlSocketPath,
            updates: updates)
        self.session = session
        // The notification centre, before the config is loaded: `loadInitialConfig()` pushes
        // `[notifications]` through `AppSession.applyGlobalConfig`, and a sink registered after
        // that would start out with the defaults instead of the user's settings (contract §10.10).
        Self.ensureNoticeInterfaceInstalled()
        // The order is a hard requirement: `loadInitialConfig()` first (which also binds the
        // control socket), then restore. Every pane the restore creates has to receive
        // QUICKTERM_SOCKET / TOKEN / PANE_TOKEN at the moment it spawns - bind one step later and
        // there is no way to hand them over afterwards. See `AppSession.applyGlobalConfig`.
        session.loadInitialConfig()

        // One-shot restore: every screen in the saved state (display, frame and fullscreen
        // included); with nothing saved, one new screen.
        restoreSession()
        session.installConfigWatcher()
        session.installScreenParametersObserver()
        // The config has been loaded by the controller (browser-extensions decides the switch), so
        // installed extensions are loaded asynchronously here.
        // Not in the test host (same policy as restoreState): the user's installed extensions would
        // run inside the tests' WebView and turn the extension-toolbar cases red along the way.
        if !Self.isRunningTests {
            Task { @MainActor in await BrowserExtensionManager.shared.loadInstalled() }
        }
        MainMenu.install(delegate: self)
        NSApp.activate(ignoringOtherApps: true)

        // Last: the updater. It re-applies the settings loadInitialConfig() stored and, when checks
        // are on, checks once now (Sparkle's own scheduler would wait for the daily interval).
        session.updates.start()
        #if DEBUG
        // QUICKTERM_UPDATE_SIMULATE=happyPath|notFound|error|slowDownload|cancelDuringDownload|
        // cancelDuringChecking|staged|autoUpdate drives the indicator and the sheet without a server.
        if let scenario = ProcessInfo.processInfo.environment["QUICKTERM_UPDATE_SIMULATE"].flatMap(UpdateSimulator.init(rawValue:)),
           !Self.isRunningTests {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { scenario.simulate(with: session.updates.viewModel) }
        }
        #endif
    }

    // MARK: config.toml live reload (watching and the global half belong to AppSession; only the
    // landing point is left here)

    /// One reload: `applyGlobalConfig` runs once, plus `applyWindowConfig` once per screen.
    @MainActor
    func applyConfigToAllScreens(_ settings: ConfigStore.Settings) {
        session?.apply(settings)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !Self.isRunningTests
    }

    /// Quit semantics (from the user, 2026-09-04): with panes open, confirm; with none, quit
    /// straight away. A relaunch the user asked the updater for (Install and Relaunch, Restart
    /// Now) is Sparkle terminating the app on their behalf: no confirmation in front of it.
    /// Both the Cmd+Q menu item and the engine's quit action go through here.
    static func shouldConfirmQuit(openPaneCount: Int, relaunchRequested: Bool) -> Bool {
        !relaunchRequested && openPaneCount > 0
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !Self.isRunningTests, !controllers.isEmpty else { return .terminateNow }
        // A pane that is still fading out has already been closed; it does not count as open.
        for controller in controllers { controller.flushPendingCloses() }
        let open = screens.allPanes.count
        guard Self.shouldConfirmQuit(openPaneCount: open,
                                     relaunchRequested: session?.updates.relaunchRequested ?? false)
        else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = L("window.quit.title")
        alert.informativeText = Lp("window.quit.detail", count: open, open)
        alert.addButton(withTitle: L("window.button.quit"))
        alert.addButton(withTitle: L("window.button.cancel"))
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Unbind the socket on the way out; the next launch then has no stale leftover to clear.
        session?.controlServer.stop()
        // spec §4.8 / v9 §3.4: write once synchronously on quit, since the debounced save may not
        // have fired yet - the layout, each terminal pane's directory, each browser pane's tabs,
        // and the display and frame of every window.
        session?.sessionStore.saveNow()
    }
}

// Drag and drop looks a surface up by UUID (SurfaceView+Transferable's find(uuid:) depends on this
// protocol).
extension AppDelegate: Ghostty.Delegate {
    func ghosttySurface(id: UUID) -> PaneView? {
        for controller in controllers {
            if let pane = controller.allPanes.first(where: { $0.id == id }) { return pane }
        }
        return nil
    }
}
