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
        let environment = ProcessInfo.processInfo.environment
        // The config file can be pointed elsewhere too: switches like `[control] send-text` can
        // only be read from the config, and smoke-testing a Debug build must never touch the user's
        // real ~/.config/quickterm/config.toml.
        // This has to be set before loadInitialConfig.
        if let path = environment["QUICKTERM_CONFIG_FILE"], !path.isEmpty {
            ConfigStore.configURLOverride = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        }
        let session = AppSession(
            screens: screens, themeManager: themeManager,
            stateURL: environment["QUICKTERM_STATE_FILE"].flatMap {
                $0.isEmpty ? nil : URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath)
            },
            controlSocketPath: environment["QUICKTERM_CONTROL_SOCKET"].flatMap {
                $0.isEmpty ? nil : ($0 as NSString).expandingTildeInPath
            })
        self.session = session
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
    /// straight away.
    /// Both the Cmd+Q menu item and the engine's quit action go through here.
    static func shouldConfirmQuit(openPaneCount: Int) -> Bool { openPaneCount > 0 }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !Self.isRunningTests, !controllers.isEmpty else { return .terminateNow }
        // A pane that is still fading out has already been closed; it does not count as open.
        for controller in controllers { controller.flushPendingCloses() }
        let open = screens.allPanes.count
        guard Self.shouldConfirmQuit(openPaneCount: open) else { return .terminateNow }
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
