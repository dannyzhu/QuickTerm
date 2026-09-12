import AppKit

/// The process-level session (spec v9 §2): everything that should exist exactly once per process
/// lives here - loading config.toml and the **single** watcher on it, the shared `KeybindingMap`,
/// the one `SystemStatsService`, the global settings (file manager / link-opener / browser pane
/// settings / the extension switch / theme and engine overlay), and the ownership ledger behind the
/// process-wide `NSApp.presentationOptions` used by non-native fullscreen.
///
/// How the work is split with `ScreenRegistry` (which is why the two are not one class): the
/// registry answers "which screens exist, and which screen does this action land on", while this
/// class answers "what is the one piece of state every screen shares". Their lifetimes match but
/// their responsibilities are orthogonal; the registry is held separately by other App-level
/// collaborators (the extension host aggregator), and folding the config and fullscreen ledger into
/// it would tie those together.
///
/// Ownership chain: AppDelegate -> AppSession -> ScreenRegistry -> MainWindowController. A
/// controller's back-reference to this object has to be `unowned` (see
/// `MainWindowController.session`), otherwise it is a retain cycle.
@MainActor
final class AppSession {
    let screens: ScreenRegistry
    let themeManager: ThemeManager
    /// The one system-stats poller in the process (a 2s Timer plus NWPathMonitor plus
    /// CoreAudio/IOKit), injected into every screen's RootView. Back when each screen had its own,
    /// N windows meant N pollers.
    let stats = SystemStatsService()

    /// The session archive (multi-screen v5): the single entry point for reading from disk,
    /// migration, and debounced writes
    let sessionStore: SessionStore

    /// The consent gate and the server for the control plane (the CLI and AI agents). On by
    /// default, in ask mode; `applyGlobalConfig` starts and stops it when `[control]` changes, so
    /// editing the config and saving takes effect immediately with no restart.
    let controlConsent: ControlConsent
    let controlServer: ControlServer
    /// Only a test that explicitly injected a socket path (in a temp directory) is allowed to
    /// really bind: the test host must never take over the socket of the QuickTerm the user is
    /// actually running (the same policy as SessionStore.writesAllowed).
    private let controlAllowed: Bool

    /// The most recently applied config (a new screen takes it from here instead of reading the
    /// file itself)
    private(set) var settings = ConfigStore.Settings()

    /// The shared keybinding table. Controllers only read it (`MainWindowController.keybindings` is
    /// a computed property); on reload we swap in a new one here and every screen is in sync at
    /// once - a controller never rebuilds its own.
    private(set) var keybindings = KeybindingMap()

    /// Global settings (derived from the config, nothing to do with a window): the same-named
    /// properties on the controller are computed properties forwarding to here.
    var fileManagerCommand = FileManagerLaunch.defaultProgram
    /// Where a Cmd+clicked link in a terminal opens: browser-pane = in a browser pane,
    /// system = in the system default browser
    var linkOpener = "browser-pane"

    /// How many times `applyGlobalConfig` has run (a counter the tests assert on: one reload must
    /// bump it by exactly 1, no matter how many screens exist)
    private(set) var globalConfigApplyCount = 0

    /// The one config.toml watcher in the process
    private var configWatcher: ConfigWatcher?
    /// Deduplicate by content: saving from an editor fires several filesystem events in a row.
    private var lastConfigContent: String?

    /// The screens currently in non-native fullscreen (a per-window refcount ledger; see the MARK
    /// further down)
    private var fullscreenOwners = Set<ObjectIdentifier>()

    /// Debounce for display configuration changes (plugging a display in or out, waking, changing
    /// resolution): a single plug event fires several notifications in a row.
    static let screenChangeDebounce: TimeInterval = 0.5
    private var screenParametersObserver: Any?
    private var pendingScreenReflow: DispatchWorkItem?

    init(screens: ScreenRegistry, themeManager: ThemeManager, stateURL: URL? = nil,
         controlSocketPath: String? = nil) {
        self.screens = screens
        self.themeManager = themeManager
        self.sessionStore = SessionStore(screens: screens, url: stateURL)
        let consent = ControlConsent(screens: screens)
        self.controlConsent = consent
        self.controlServer = ControlServer(screens: screens, consent: consent,
                                           socketPath: controlSocketPath)
        self.controlAllowed = controlSocketPath != nil || !AppDelegate.isRunningTests
        // Hook the event bus up to the registry and take "right now" as the baseline: without
        // that, the first scan reports every screen and every pane that already exists as if it had
        // just been created.
        ControlEventBus.shared.attach(screens: screens)
    }

    deinit {
        if let screenParametersObserver {
            NotificationCenter.default.removeObserver(screenParametersObserver)
        }
    }

    // MARK: Display hot-plug (spec v9 §3.5)

    /// Install the one display-change observer in the process
    func installScreenParametersObserver() {
        guard screenParametersObserver == nil else { return }
        screenParametersObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.scheduleScreenReflow()
        }
    }

    /// After a 0.5s debounce, refit every screen to the display it currently sits on
    func scheduleScreenReflow() {
        pendingScreenReflow?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.reflowScreens() }
        pendingScreenReflow = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.screenChangeDebounce, execute: item)
    }

    /// Re-constrain screen by screen (if the target display is gone AppKit has already moved the
    /// window elsewhere, so fit it to whichever display it is on now), then queue one archive save.
    func reflowScreens() {
        pendingScreenReflow = nil
        for controller in screens.controllers { controller.reflowForScreenChange() }
        sessionStore.scheduleSave()
    }

    // MARK: Layer 4 of the config chain (config.toml, spec §4.7)

    /// The first load at startup: fill in the template keys, read the file, apply the global
    /// settings.
    /// It has to run **before** the first screen is created: a controller's init uses `settings`
    /// directly (it no longer reads the file itself), and `visibleColumns` and the workspace count
    /// must already hold their final values before state restoration runs.
    func loadInitialConfig() {
        // **The UI language has to be settled before the template is written.** The template
        // comments (and the autofill banner) follow `[general] language`, and writing the
        // template happens a few lines below. Settling it any later means a user who pinned
        // language = "en" gets a config file full of Chinese comments — and only on their very
        // first launch, which is a bug nobody can ever reproduce again.
        // This read records no diagnostics: the real load happens at the end of this function,
        // and the "did not take effect" lines should be complained about exactly once.
        if let text = try? String(contentsOf: ConfigStore.activeConfigURL, encoding: .utf8) {
            Localization.shared.apply(configValue: ConfigStore.parse(text).language)
        }
        // Fill newly added keys into an existing config file (as comments, idempotently).
        // **The test host writes not one byte** (the same policy as `SessionStore.writesAllowed`
        // and the control socket): appending a section to the user's real
        // ~/.config/quickterm/config.toml just because a test ran is something nobody agreed to.
        // Smoke runs point QUICKTERM_CONFIG_FILE somewhere else, and that copy does get filled in.
        if !AppDelegate.isRunningTests || ConfigStore.configURLOverride != nil {
            ConfigStore.ensureTemplateKeys()
        }
        apply(ConfigStore.load())
    }

    /// Install the one directory watcher in the process (so an editor's atomic replace is caught
    /// too)
    func installConfigWatcher() {
        lastConfigContent = (try? String(contentsOf: ConfigStore.activeConfigURL, encoding: .utf8)) ?? ""
        configWatcher = ConfigWatcher(
            directory: ConfigStore.activeConfigURL.deletingLastPathComponent()
        ) { [weak self] in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self?.reloadConfigFile() }
        }
    }

    /// Reload only when the file content actually changed (a save fires several events), then run
    /// one apply
    func reloadConfigFile() {
        let content = (try? String(contentsOf: ConfigStore.activeConfigURL, encoding: .utf8)) ?? ""
        guard content != lastConfigContent else { return }
        lastConfigContent = content
        apply(ConfigStore.parse(content))
    }

    /// One reload = the global half **once**, plus the window half once per screen.
    /// (Back in the single-window days every controller rewrote the keybinding table, the engine
    /// overlay and the global browser settings, so N screens meant doing all of that N times.)
    func apply(_ settings: ConfigStore.Settings) {
        applyGlobalConfig(settings)
        for controller in screens.controllers { controller.applyWindowConfig(settings) }
    }

    /// The process-level half: the keybinding table, the global browser pane settings, the
    /// extension switch, the theme and the engine overlay.
    /// It runs exactly once per reload - writing the engine overlay to disk triggers a hot reload
    /// on every screen, so doing it N times means N flashes.
    func applyGlobalConfig(_ settings: ConfigStore.Settings) {
        globalConfigApplyCount += 1
        self.settings = settings
        // UI language first: the menus, the consent alerts and every SwiftUI view read their
        // text from `Localization`, so saving the config switches the language live.
        // (`Localization` is idempotent on an unchanged value — no menu is rebuilt for nothing.)
        Localization.shared.apply(configValue: settings.language)
        keybindings = KeybindingMap(
            workspaceCount: settings.workspaces,
            overrides: settings.overrides,
            unbound: settings.unbound)
        fileManagerCommand = settings.fileManagerCommand
        linkOpener = settings.linkOpener
        BrowserPaneView.settings = .init(home: settings.browserHome, search: settings.browserSearch,
                                         userAgent: settings.browserUserAgent, inspectable: settings.browserInspectable,
                                         tabBar: settings.browserTabBar,
                                         tabWidth: settings.browserTabWidth, tabMinWidth: settings.browserTabMinWidth,
                                         downloadDirectory: settings.browserDownloadDir)
        BrowserExtensionManager.shared.isEnabled = settings.browserExtensions
        // Control plane: a config hot reload starts or stops it (with enabled=false or
        // mode="off" nothing listens at all).
        var control = ControlCommandRunner.Config(settings)
        if !controlAllowed { control.socket = false }
        // The socket **must** be bound here, before session restore runs. Do not reintroduce any
        // kind of "only start listening once restore is done" gate:
        // `ControlEnvironment.socketPath` is only assigned inside `ControlServer.start()`, and both
        // the restored panes and the very first pane of a fresh launch are created
        // **synchronously** inside `restoreSession()` - the environment is baked in at the moment
        // of spawn, and starting the server afterwards cannot patch it in. Start one step late and
        // no terminal in the entire session has QUICKTERM_SOCKET / TOKEN / PANE_TOKEN.
        // "A command seeing half a world" needs no gate either: every command runs through
        // `DispatchQueue.main.async`, and `restoreSession()` runs to completion synchronously on
        // the main thread, so no queued block can slip in between.
        controlServer.apply(control)
        themeManager.updateFromConfig(
            passthrough: settings.ghosttyPassthrough,
            followEngine: settings.themeName == "ghostty",
            panePadding: settings.panePadding,
            paneOpacity: settings.paneOpacity,
            inactiveBlur: settings.inactiveBlur,
            activeOpacity: settings.activeOpacity,
            barOpacity: settings.barOpacity,
            dividerOpacity: settings.dividerOpacity,
            paneGap: settings.paneGap,
            paneTitle: settings.paneTitle,
            workspaceTitle: settings.workspaceTitle)
        if let name = settings.themeName, name != "ghostty",
           let theme = themeManager.themes.first(where: { $0.name == name }),
           theme != themeManager.current {
            themeManager.apply(theme)
        }
    }

    // MARK: Process-level presentationOptions for non-native fullscreen (refcounted per window)

    /// The two things fullscreen hides. They are process-level: macOS has no "hide the menu bar on
    /// this display only" API.
    private static let fullscreenOptions: [NSApplication.PresentationOptions.Element] =
        [.autoHideDock, .autoHideMenuBar]

    /// How many screens are currently in non-native fullscreen
    var fullscreenScreenCount: Int { fullscreenOwners.count }

    /// A screen enters or leaves non-native fullscreen. The ledger is updated per window before
    /// the acquire/release, so entering twice from the same window does not take an extra
    /// reference, and closing a screen (`teardown`) only gives back the reference it really held -
    /// which is what keeps A leaving fullscreen from restoring the menu bar while B is still
    /// fullscreen.
    func setSimpleFullscreen(_ on: Bool, for controller: MainWindowController) {
        let id = ObjectIdentifier(controller)
        if on {
            guard fullscreenOwners.insert(id).inserted else { return }
            for option in Self.fullscreenOptions { NSApp.acquirePresentationOption(option) }
        } else {
            guard fullscreenOwners.remove(id) != nil else { return }
            for option in Self.fullscreenOptions { NSApp.releasePresentationOption(option) }
        }
    }

    /// Recompute when the key window changes: AppKit rewrites presentationOptions on window and
    /// activation changes, so force it back to whatever the ledger says (an empty ledger means no
    /// screen is fullscreen, and the Dock and menu bar have to be handed back).
    func refreshPresentationOptions() {
        var options = NSApp.presentationOptions
        for option in Self.fullscreenOptions {
            if fullscreenOwners.isEmpty { options.remove(option) } else { options.insert(option) }
        }
        guard options != NSApp.presentationOptions else { return }
        NSApp.presentationOptions = options
    }
}
