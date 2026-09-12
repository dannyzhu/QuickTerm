import XCTest
import AppKit
@testable import QuickTerm

/// Process-level session (spec v9 §2): the global vs. per-window split of a config reload, the shared
/// keybinding map and system-stats service, the ref-counted presentationOptions behind non-native
/// fullscreen, and surface scaling under mixed DPI.
/// Every case in here has to close the screens it opened and hand key back to the first screen, or it
/// poisons the cases that run after it.
@MainActor
final class AppSessionTests: XCTestCase {
    private var app: AppDelegate {
        get throws { try XCTUnwrap(NSApp.delegate as? AppDelegate) }
    }

    private func spin(_ seconds: TimeInterval = 0.3) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private func withSecondScreen(
        _ body: (AppDelegate, AppSession, MainWindowController, MainWindowController) throws -> Void
    ) throws {
        let app = try self.app
        let session = try XCTUnwrap(app.session)
        let primary = try XCTUnwrap(app.screens.primary)
        let second = app.newScreen(on: NSScreen.main)
        spin()
        defer {
            if app.controllers.contains(where: { $0 === second }) { app.closeScreen(second) }
            primary.window?.makeKeyAndOrderFront(nil)
            spin()
        }
        try body(app, session, primary, second)
    }

    // MARK: Config reload: the global half runs once, the window half once per screen

    func testGlobalConfigAppliesOncePerReloadWhileEveryScreenUpdates() throws {
        try withSecondScreen { app, session, primary, second in
            let real = ConfigStore.load()
            defer { app.applyConfigToAllScreens(real) }
            var bumped = real
            bumped.workspaces = 7
            let before = session.globalConfigApplyCount
            app.applyConfigToAllScreens(bumped)
            XCTAssertEqual(session.globalConfigApplyCount, before + 1,
                           "one reload runs the global half (keybinding map / engine overlay / global browser"
                           + " settings) exactly once, however many screens are open")
            XCTAssertEqual(primary.model.layouts.count, 7, "the window half has to land on the first screen")
            XCTAssertEqual(second.model.layouts.count, 7, "the window half has to land on the second screen too")
            XCTAssertEqual(session.settings.workspaces, 7, "the session remembers the config that was applied last")
        }
    }

    /// A freshly opened screen takes the config straight out of the session: no second read from disk, no
    /// keybinding map built on its own.
    func testNewScreenPicksUpSessionSettingsWithoutReloadingFromDisk() throws {
        let app = try self.app
        let session = try XCTUnwrap(app.session)
        let primary = try XCTUnwrap(app.screens.primary)
        let real = ConfigStore.load()
        var bumped = real
        bumped.workspaces = 8
        app.applyConfigToAllScreens(bumped)
        let afterApply = session.globalConfigApplyCount
        let second = app.newScreen(on: NSScreen.main)
        spin()
        defer {
            app.closeScreen(second)
            app.applyConfigToAllScreens(real)
            primary.window?.makeKeyAndOrderFront(nil)
            spin()
        }
        XCTAssertEqual(second.model.layouts.count, 8, "a new screen starts from the config held by the session")
        XCTAssertEqual(session.globalConfigApplyCount, afterApply,
                       "opening a screen must not run the global config again (otherwise every new window"
                       + " rewrites the engine overlay)")
    }

    // MARK: Shared process-level services

    func testScreensShareOneStatsServiceAndOneKeybindingMap() throws {
        try withSecondScreen { app, session, primary, second in
            XCTAssertTrue(primary.stats === second.stats,
                          "there is exactly one stats service per process (one per screen would mean N 2s"
                          + " polling loops and N NWPathMonitors)")
            XCTAssertTrue(primary.stats === session.stats)

            let real = ConfigStore.load()
            defer { app.applyConfigToAllScreens(real) }
            var bumped = real
            bumped.overrides[.newTerminal] = KeyCombo(key: "y", [.command, .shift])
            let before = session.globalConfigApplyCount
            app.applyConfigToAllScreens(bumped)
            XCTAssertEqual(session.globalConfigApplyCount, before + 1, "the session rebuilds the keybinding map once, for everyone")
            for (name, controller) in [("first", primary), ("second", second)] {
                XCTAssertEqual(controller.keybindings.action(key: "y", modifiers: [.command, .shift])?.action,
                               .newTerminal, "the \(name) screen reads the keybinding map held by the session")
                XCTAssertNil(controller.keybindings.action(key: "return", modifiers: .command),
                             "the \(name) screen must not keep its own stale map")
            }
        }
    }

    // MARK: Non-native fullscreen: a per-window savedFrame plus ref-counted presentationOptions

    func testFullscreenPresentationOptionsAreRefCountedPerScreen() throws {
        try XCTSkipIf(NSScreen.main == nil, "non-native fullscreen is a no-op with no display attached")
        let app = try self.app
        let session = try XCTUnwrap(app.session)
        let primary = try XCTUnwrap(app.screens.primary)
        let a = app.newScreen(on: NSScreen.main)
        spin()
        let b = app.newScreen(on: NSScreen.main)
        spin()
        defer {
            for controller in [a, b] where app.controllers.contains(where: { $0 === controller }) {
                app.closeScreen(controller)
            }
            NSApp.presentationOptions = []
            primary.window?.makeKeyAndOrderFront(nil)
            spin()
        }

        a.perform(.toggleFullscreen)
        XCTAssertTrue(a.isSimpleFullscreen)
        XCTAssertTrue(NSApp.presentationOptions.contains(.autoHideMenuBar), "A goes fullscreen -> hide the menu bar")

        b.perform(.toggleFullscreen)
        XCTAssertEqual(session.fullscreenScreenCount, 2)
        // Simulate AppKit rewriting presentationOptions on a window switch: when B becomes key it has to
        // pull them back according to the ledger. Call the delegate method directly rather than going
        // through makeKeyAndOrderFront: a test host is not guaranteed to actually get key (see the key
        // checks in ScreenRegistryTests), so driving this from a real key switch is flaky.
        // Setting the options here bypasses acquire/release, so GhosttyEmbed's own count is untouched and
        // the releases further down still balance.
        NSApp.presentationOptions = []
        b.windowDidBecomeKey(Foundation.Notification(name: NSWindow.didBecomeKeyNotification, object: b.window))
        XCTAssertTrue(NSApp.presentationOptions.contains(.autoHideMenuBar),
                      "a screen is still fullscreen -> a key switch has to hide the menu bar again")
        XCTAssertTrue(NSApp.presentationOptions.contains(.autoHideDock),
                      "a screen is still fullscreen -> a key switch has to hide the Dock again")

        a.perform(.toggleFullscreen)   // A leaves fullscreen, B stays in it
        XCTAssertFalse(a.isSimpleFullscreen)
        XCTAssertTrue(b.isSimpleFullscreen)
        XCTAssertEqual(session.fullscreenScreenCount, 1)
        XCTAssertTrue(NSApp.presentationOptions.contains(.autoHideMenuBar),
                      "A leaving fullscreen must not give the menu bar back: B is still fullscreen")

        XCTAssertTrue(app.closeScreen(b))   // Close B while it is fullscreen: it releases only its own share
        spin(0.2)
        XCTAssertEqual(session.fullscreenScreenCount, 0)
        XCTAssertFalse(NSApp.presentationOptions.contains(.autoHideMenuBar),
                       "closing the last fullscreen screen has to give the Dock and the menu bar back")
        XCTAssertFalse(NSApp.presentationOptions.contains(.autoHideDock))

        // The other direction: with an empty ledger a key switch has to give both of them up, or the menu
        // bar stays hidden for good once A leaves fullscreen.
        NSApp.presentationOptions = [.autoHideDock, .autoHideMenuBar]
        a.windowDidBecomeKey(Foundation.Notification(name: NSWindow.didBecomeKeyNotification, object: a.window))
        XCTAssertFalse(NSApp.presentationOptions.contains(.autoHideMenuBar), "empty ledger -> the menu bar comes back")
        XCTAssertFalse(NSApp.presentationOptions.contains(.autoHideDock), "empty ledger -> the Dock comes back")

        XCTAssertTrue(app.closeScreen(a))
        spin(0.5)
    }

    /// Each window keeps its own savedFrame: A going fullscreen must not move B's window, and leaving
    /// fullscreen puts each one back to its own frame.
    func testSavedFrameIsPerScreen() throws {
        try XCTSkipIf(NSScreen.main == nil, "non-native fullscreen is a no-op with no display attached")
        try withSecondScreen { app, session, primary, second in
            defer {
                if second.isSimpleFullscreen { second.perform(.toggleFullscreen) }
                NSApp.presentationOptions = []
            }
            let primaryFrame = try XCTUnwrap(primary.window?.frame)
            let secondFrame = try XCTUnwrap(second.window?.frame)
            second.perform(.toggleFullscreen)
            XCTAssertTrue(second.isSimpleFullscreen)
            XCTAssertFalse(primary.isSimpleFullscreen, "fullscreen is per window")
            XCTAssertEqual(primary.window?.frame, primaryFrame, "the other screen's window must not be touched")
            second.perform(.toggleFullscreen)
            XCTAssertEqual(second.window?.frame, secondFrame, "leaving fullscreen restores its own savedFrame")
        }
    }

    // MARK: Mixed DPI: a surface's backing scale follows the display its own window sits on

    /// A surface is built in init, when it is not in any window yet, so scale_factor can only be seeded from
    /// the main display. Once it is mounted in a window that seeded value has to be corrected, or a new pane
    /// on a second display with a different DPI renders at the wrong scale.
    /// On a single display there is no way to tell which display's scale was picked up, so this case only
    /// proves the correction ran at all; the value itself is guarded by the two-display case below.
    func testSurfaceAdoptsItsOwnWindowBackingScaleAfterMount() throws {
        let app = try self.app
        let primary = try XCTUnwrap(app.screens.primary)
        spin(0.4)
        let surface = try XCTUnwrap(primary.paneList.compactMap { $0 as? Ghostty.SurfaceView }.first)
        let window = try XCTUnwrap(surface.window)
        XCTAssertEqual(surface.appliedBackingScale, window.backingScaleFactor, accuracy: 0.001,
                       "after mounting, the surface's backing scale must equal its own window's")
        // AppKit fires viewDidChangeBackingProperties by itself when the view is inserted into a window, so
        // on a single display the assertion above holds on system behavior alone. The next one is what
        // actually catches whether the explicit refresh inside viewDidMoveToWindow ran.
        XCTAssertGreaterThanOrEqual(surface.mountBackingRefreshCount, 1,
                                    "viewDidMoveToWindow has to push one backing correction of its own")
    }

    func testSurfaceOnSecondaryDisplayUsesThatDisplaysScale() throws {
        let all = NSScreen.screens
        try XCTSkipIf(all.count < 2, "only one display attached, mixed DPI cannot be verified")
        let app = try self.app
        let primary = try XCTUnwrap(app.screens.primary)
        let target = try XCTUnwrap(all.first { $0 !== NSScreen.main })
        let second = app.newScreen(on: target)
        spin(0.8)
        defer {
            app.closeScreen(second)
            primary.window?.makeKeyAndOrderFront(nil)
            spin()
        }
        let surface = try XCTUnwrap(second.paneList.compactMap { $0 as? Ghostty.SurfaceView }.first)
        let window = try XCTUnwrap(surface.window)
        let screen = try XCTUnwrap(window.screen)
        XCTAssertEqual(surface.appliedBackingScale, screen.backingScaleFactor, accuracy: 0.001,
                       "a window on a non-main display must render its panes at that display's scale")
    }
}
