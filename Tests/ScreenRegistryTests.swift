import XCTest
import AppKit
@testable import QuickTerm

/// The registry and routing behind multiple "screens" (multiple windows), spec v9 §1.6.
/// Every case has to close the second screen and hand key back to the first, or it poisons the cases
/// that run after it.
@MainActor
final class ScreenRegistryTests: XCTestCase {
    private var app: AppDelegate {
        get throws { try XCTUnwrap(NSApp.delegate as? AppDelegate) }
    }

    /// Turn the runloop once so SwiftUI mounting and the asynchronous registry removal actually land.
    private func spin(_ seconds: TimeInterval = 0.3) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    /// Run a case with a second screen open, always closing it and handing key back to the first afterwards.
    private func withSecondScreen(
        on screen: NSScreen? = NSScreen.main,
        _ body: (AppDelegate, MainWindowController, MainWindowController) throws -> Void
    ) throws {
        let app = try self.app
        let primary = try XCTUnwrap(app.screens.primary)
        let second = app.newScreen(on: screen)
        spin()
        defer {
            if app.controllers.contains(where: { $0 === second }) {
                app.closeScreen(second)
            }
            primary.window?.makeKeyAndOrderFront(nil)
            spin()
        }
        try body(app, primary, second)
    }

    // MARK: Registry and placement

    /// A pane detached from its window still resolves to the controller of **its own screen**, not whichever
    /// screen holds key right now, and once that screen is closed it must not resurrect it: a Cmd+clicked link
    /// has to land on the right screen.
    func testDetachedPaneResolvesItsOwnScreenController() throws {
        var orphan: PaneView?
        try withSecondScreen { app, primary, second in
            let content = try XCTUnwrap(second.window?.contentView)
            let pane = PaneView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
            orphan = pane
            content.addSubview(pane)
            spin(0.1)
            XCTAssertTrue(pane.controller === second)
            pane.removeFromSuperview()
            primary.window?.makeKeyAndOrderFront(nil)
            spin(0.1)
            XCTAssertNil(pane.window, "precondition: it is off the window")
            XCTAssertTrue(pane.controller === second,
                          "detached, it resolves to its own screen and never to whichever window holds key")
            app.closeScreen(second)
            spin()
            XCTAssertNil(pane.controller, "the controller of a closed screen must not come back to life")
        }
        XCTAssertNotNil(orphan)
    }


    func testNewScreenRegistersSecondWindow() throws {
        try withSecondScreen { app, primary, second in
            XCTAssertEqual(app.controllers.count, 2, "after opening a screen the registry holds two controllers")
            XCTAssertTrue(app.controllers.contains { $0 === primary })
            XCTAssertTrue(app.controllers.contains { $0 === second })
            XCTAssertEqual(primary.window?.title, "QuickTerm", "the first screen's title has to be exactly QuickTerm")
            XCTAssertEqual(second.window?.title, "QuickTerm 2")
            XCTAssertEqual(second.screenIndex, 1)
        }
    }

    func testNewScreenLandsOnRequestedDisplay() throws {
        let target = try XCTUnwrap(NSScreen.main)
        try withSecondScreen(on: target) { _, primary, second in
            let frame = try XCTUnwrap(second.window?.frame)
            // Allow 1pt of slack for constrainFrameRect's rounding.
            XCTAssertTrue(target.visibleFrame.insetBy(dx: -1, dy: -1).contains(frame),
                          "the second window has to land in the target display's visible area (frame \(frame) / visible \(target.visibleFrame))")
            if primary.window?.screen === target {
                XCTAssertNotEqual(frame.origin, primary.window?.frame.origin,
                                  "with a window already on that display it cascades instead of landing exactly on the first one")
            }
        }
    }

    func testScreenIndexReusesLowestFreeSlot() throws {
        let app = try self.app
        let primary = try XCTUnwrap(app.screens.primary)
        let second = app.newScreen(on: NSScreen.main)
        spin()
        XCTAssertEqual(second.screenIndex, 1)
        app.closeScreen(second)
        spin()
        let third = app.newScreen(on: NSScreen.main)
        spin()
        defer {
            app.closeScreen(third)
            primary.window?.makeKeyAndOrderFront(nil)
            spin()
        }
        XCTAssertEqual(third.screenIndex, 1, "indices reuse the lowest free slot: close number 2 and the next one is 2 again")
        XCTAssertEqual(third.window?.title, "QuickTerm 2")
    }

    // MARK: Closing and deallocation

    func testCloseScreenReleasesController() throws {
        let app = try self.app
        let primary = try XCTUnwrap(app.screens.primary)
        weak var weakSecond: MainWindowController?
        weak var weakPane: PaneView?
        autoreleasepool {
            let second = app.newScreen(on: NSScreen.main)
            spin()
            weakSecond = second
            weakPane = second.paneList.first
            XCTAssertEqual(app.controllers.count, 2)
            app.closeScreen(second)
        }
        spin(0.8)
        XCTAssertEqual(app.controllers.count, 1, "after closing a screen the registry is back to one")
        XCTAssertNil(weakSecond, "the controller has to be fully released: monitors, observers and the theme listener all torn down")
        XCTAssertNil(weakPane, "the screen's panes go with it, which ends their shell processes")
        primary.window?.makeKeyAndOrderFront(nil)
        spin()
    }

    func testThemeListenersAreRemovedWithTheScreen() throws {
        let app = try self.app
        let themeManager = try XCTUnwrap(app.themeManager)
        let before = themeManager.overlayListenerCount
        try withSecondScreen { _, _, _ in
            XCTAssertEqual(themeManager.overlayListenerCount, before + 1,
                           "each screen registers a theme listener of its own (back when it was one closure, only the last window responded)")
        }
        spin(0.4)
        XCTAssertEqual(themeManager.overlayListenerCount, before, "closing a screen has to remove its listener completely")
    }

    // MARK: Routing

    func testControllerFollowsKeyWindow() throws {
        try withSecondScreen { app, primary, second in
            NSApp.activate(ignoringOtherApps: true)
            second.window?.makeKeyAndOrderFront(nil)
            spin(0.3)
            if NSApp.keyWindow === second.window {
                XCTAssertTrue(app.controller === second, "AppDelegate.controller is the key window's controller")
            } else {
                // No window-server focus (the suite is running in the background): at least check the fallback.
                XCTAssertTrue(app.controller === primary, "with no key window it falls back to the first screen")
            }
            primary.window?.makeKeyAndOrderFront(nil)
            spin(0.3)
            XCTAssertTrue(app.controller === primary)
        }
    }

    func testGhosttySurfaceLookupSpansAllScreens() throws {
        try withSecondScreen { app, _, second in
            let pane = try XCTUnwrap(second.paneList.first)
            XCTAssertTrue(app.ghosttySurface(id: pane.id) === pane,
                          "looking a surface up by UUID has to span every screen (drag-and-drop resolution)")
        }
    }

    // MARK: Each screen's workspaces are independent

    func testWorkspacesAreIndependentPerScreen() throws {
        try withSecondScreen { _, primary, second in
            primary.model.switchTo(0)
            let primaryBefore = primary.paneList.count
            let secondBefore = second.paneList.count
            second.perform(.newTerminal)
            XCTAssertEqual(second.paneList.count, secondBefore + 1, "the new pane lands on the second screen")
            XCTAssertEqual(primary.paneList.count, primaryBefore, "the first screen's workspaces are untouched")
            XCTAssertFalse(primary.model.layouts.contains { layout in
                layout.paneList.contains { second.paneList.contains($0) }
            }, "the two screens share no pane at all")
            if let pane = second.focusedPane {
                second.closePane(pane, confirmIfNeeded: false, animated: false)
            }
        }
    }

    // MARK: Notification crosstalk (the three observers registered with object: nil)

    func testEqualizeNotificationOnlyAffectsOwningScreen() throws {
        try withSecondScreen { _, primary, second in
            primary.perform(.equalize)   // Equalize A first, so a notification landing on A changes nothing
            second.perform(.newTerminal)
            guard case .scrolling(var strip) = second.model.layout, strip.columns.count >= 2 else {
                return XCTFail("the second screen should be a two-column scrolling layout")
            }
            strip.columns[0].widthFactor = 0.8
            second.model.layout = .scrolling(strip)

            let paneA = try XCTUnwrap(primary.paneList.first)
            NotificationCenter.default.post(
                name: Ghostty.Notification.didEqualizeSplits, object: paneA)
            guard case .scrolling(let afterForeign) = second.model.layout else {
                return XCTFail("the layout must not change type")
            }
            XCTAssertEqual(afterForeign.columns[0].widthFactor, 0.8, accuracy: 0.001,
                           "an equalize notification from screen A must not touch screen B's column widths")

            let paneB = try XCTUnwrap(second.paneList.first)
            NotificationCenter.default.post(
                name: Ghostty.Notification.didEqualizeSplits, object: paneB)
            guard case .scrolling(let afterOwn) = second.model.layout else {
                return XCTFail("the layout must not change type")
            }
            XCTAssertEqual(afterOwn.columns[0].widthFactor, second.columnFactor, accuracy: 0.001,
                           "an equalize notification from its own screen still applies")
            for pane in second.paneList.dropFirst() {
                second.closePane(pane, confirmIfNeeded: false, animated: false)
            }
        }
    }

    // MARK: Cross-window drops are refused outright

    func testCrossWindowDropIsRejected() throws {
        try withSecondScreen { _, primary, second in
            let paneA = try XCTUnwrap(primary.paneList.first)
            let paneB = try XCTUnwrap(second.paneList.first)
            try XCTSkipIf(paneA.window == nil || paneB.window == nil, "the panes are not mounted in a window yet")
            PaneDragState.shared.begin(pane: paneA)
            defer { PaneDragState.shared.end() }
            XCTAssertFalse(PaneDragState.shared.allowsDrop(on: paneB),
                           "a cross-window drop has to be refused outright (no-drop cursor), not silently ignored")
            XCTAssertTrue(PaneDragState.shared.allowsDrop(on: paneA), "a drop inside the same window still works")
        }
    }

    func testNoDragSessionAllowsEveryDrop() throws {
        let app = try self.app
        let primary = try XCTUnwrap(app.screens.primary)
        PaneDragState.shared.end()
        let pane = try XCTUnwrap(primary.paneList.first)
        XCTAssertTrue(PaneDragState.shared.allowsDrop(on: pane), "with no drag session in flight nothing is blocked")
    }

    // MARK: The extension host aggregates across screens

    func testExtensionHostAggregatesBrowserPanesAcrossScreens() throws {
        try withSecondScreen { app, primary, second in
            let host = try XCTUnwrap(BrowserExtensionManager.shared.host)
            XCTAssertTrue(host is AppBrowserExtensionHost, "the extension host is the app-level aggregator, not one window")
            let before = host.browserPanes.count
            let url = try XCTUnwrap(URL(string: "about:blank"))
            let a = try XCTUnwrap(primary.openBrowserPane(url: url, from: primary.focusedPane))
            let b = try XCTUnwrap(second.openBrowserPane(url: url, from: second.focusedPane))
            defer {
                primary.closePane(a, confirmIfNeeded: false, animated: false)
                second.closePane(b, confirmIfNeeded: false, animated: false)
            }
            XCTAssertEqual(host.browserPanes.count, before + 2,
                           "one browser pane on each screen, so the host sees two")
            XCTAssertTrue(host.browserPanes.contains { $0 === a })
            XCTAssertTrue(host.browserPanes.contains { $0 === b })
        }
    }

    // MARK: Config-reload fan-out (AppDelegate owns the watch, the settings land on every screen)

    func testConfigAppliesToEveryScreen() throws {
        try withSecondScreen { app, primary, second in
            let real = ConfigStore.load()
            var bumped = real
            bumped.workspaces = 7
            app.applyConfigToAllScreens(bumped)   // AppDelegate's fan-out is itself the thing under test
            XCTAssertEqual(primary.model.layouts.count, 7)
            XCTAssertEqual(second.model.layouts.count, 7)
            app.applyConfigToAllScreens(real)
            XCTAssertEqual(second.model.layouts.count, real.workspaces)
            XCTAssertEqual(primary.model.layouts.count, real.workspaces)
        }
    }

    // MARK: Screen-close cleanup (teardown does not take the closePane path)

    /// The presentationOptions behind non-native fullscreen are process-wide: closing a screen while it is
    /// fullscreen has to hand them back, or the remaining screens sit with no Dock and no menu bar while
    /// having no idea they are "in fullscreen".
    func testClosingFullscreenScreenReleasesPresentationOptions() throws {
        try XCTSkipIf(NSScreen.main == nil, "non-native fullscreen is a no-op with no display attached")
        let app = try self.app
        let primary = try XCTUnwrap(app.screens.primary)
        defer {
            NSApp.presentationOptions = []
            primary.window?.makeKeyAndOrderFront(nil)
            spin()
        }
        let second = app.newScreen(on: NSScreen.main)
        spin()
        second.perform(.toggleFullscreen)
        XCTAssertFalse(NSApp.presentationOptions.isEmpty, "non-native fullscreen hides the Dock and the menu bar")
        XCTAssertTrue(app.closeScreen(second))
        XCTAssertTrue(NSApp.presentationOptions.isEmpty,
                      "closing a screen has to hand back the process-wide presentationOptions this window took")
        spin(0.5)
    }

    /// Clearing the model on screen close goes through teardown, not closePane, and browser panes still have
    /// to be wound down: in-flight downloads cancelled, and the extensions told the window is gone.
    func testCloseScreenRunsPaneWillCloseForBrowserPanes() throws {
        let app = try self.app
        let primary = try XCTUnwrap(app.screens.primary)
        let second = app.newScreen(on: NSScreen.main)
        spin()
        defer {
            if app.controllers.contains(where: { $0 === second }) { app.closeScreen(second) }
            primary.window?.makeKeyAndOrderFront(nil)
            spin()
        }
        let url = try XCTUnwrap(URL(string: "about:blank"))
        let pane = try XCTUnwrap(second.openBrowserPane(url: url, from: second.focusedPane))
        var cancelled = 0
        let active = BrowserDownloadItem(filename: "big.iso", progress: Progress(totalUnitCount: 100)) {
            cancelled += 1
        }
        pane.downloads.add(active)
        XCTAssertTrue(app.closeScreen(second))
        XCTAssertEqual(cancelled, 1, "an in-flight download has to be cancelled when the screen closes, leaving no orphaned transfer")
        XCTAssertEqual(active.state, .cancelled)
        spin(0.5)
    }

    // MARK: Which pane the extension host calls focused

    /// `focusedBrowserPane` comes from the current (key) screen: the first responder of a non-key window is
    /// only leftover focus, and it must not open an options page or a new tab on another display.
    func testFocusedBrowserPaneComesFromTheCurrentScreen() throws {
        try withSecondScreen { app, primary, second in
            let host = try XCTUnwrap(BrowserExtensionManager.shared.host as? AppBrowserExtensionHost)
            let url = try XCTUnwrap(URL(string: "about:blank"))
            let a = try XCTUnwrap(primary.openBrowserPane(url: url, from: primary.focusedPane))
            let b = try XCTUnwrap(second.openBrowserPane(url: url, from: second.focusedPane))
            defer {
                primary.closePane(a, confirmIfNeeded: false, animated: false)
                second.closePane(b, confirmIfNeeded: false, animated: false)
            }
            spin(0.8)   // Wait out openBrowserPane's delayed focus fix-up, or it steals the responder back
            // The other screen's browser pane holds the first responder of its own window: leftover focus in
            // a window that is not key.
            second.window?.makeFirstResponder(b)
            // Focus on the current screen sits on a terminal.
            if let terminal = primary.paneList.first(where: { !($0 is BrowserPaneView) }) {
                primary.window?.makeFirstResponder(terminal)
            }
            primary.window?.makeKeyAndOrderFront(nil)
            spin(0.3)
            let current = try XCTUnwrap(app.screens.current)
            let focused = try XCTUnwrap(host.focusedBrowserPane)
            XCTAssertTrue(current.browserPanes.contains { $0 === focused },
                          "the focused browser pane has to come from the current screen, not a stale responder on another display")
            if current === primary {
                XCTAssertTrue(focused === a,
                              "with the key screen focused on a terminal, take that screen's most recently active browser pane")
            }
        }
    }

    // MARK: Moving displays while fullscreen

    /// Moved to another display while fullscreen: leaving fullscreen has to land on the new display, not jump
    /// back to the original one.
    func testMoveWhileFullscreenKeepsRestoreFrameOnNewDisplay() throws {
        let all = NSScreen.screens
        try XCTSkipIf(all.count < 2, "only one display attached, a cross-display move cannot be verified")
        let app = try self.app
        let primary = try XCTUnwrap(app.screens.primary)
        defer {
            NSApp.presentationOptions = []
            primary.window?.makeKeyAndOrderFront(nil)
            spin()
        }
        let start = try XCTUnwrap(all.first)
        let second = app.newScreen(on: start)
        spin()
        let target = try XCTUnwrap(all.first { $0 !== second.window?.screen })
        second.perform(.toggleFullscreen)
        second.move(to: target)
        spin(0.2)
        second.perform(.toggleFullscreen)   // Leave fullscreen
        spin(0.2)
        let frame = try XCTUnwrap(second.window?.frame)
        XCTAssertTrue(target.visibleFrame.insetBy(dx: -1, dy: -1).contains(frame),
                      "after leaving fullscreen the window has to stay on the display it was moved to (frame \(frame))")
        XCTAssertTrue(app.closeScreen(second))
        spin(0.5)
    }
}
