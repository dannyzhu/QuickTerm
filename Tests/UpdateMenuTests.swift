import AppKit
import XCTest
@testable import QuickTerm

/// The menu item, its validation without an updater, and the quit confirmation standing aside for
/// a relaunch.
@MainActor
final class UpdateMenuTests: XCTestCase {
    func testShouldConfirmQuitStandsAsideForARelaunch() {
        XCTAssertTrue(AppDelegate.shouldConfirmQuit(openPaneCount: 3, relaunchRequested: false))
        XCTAssertFalse(AppDelegate.shouldConfirmQuit(openPaneCount: 3, relaunchRequested: true))
        XCTAssertFalse(AppDelegate.shouldConfirmQuit(openPaneCount: 0, relaunchRequested: false))
    }

    func testTheAppMenuCarriesCheckForUpdatesAfterAbout() throws {
        let appMenu = try XCTUnwrap(NSApp.mainMenu?.items.first?.submenu)
        let titles = appMenu.items.map(\.title)
        let about = try XCTUnwrap(titles.firstIndex(of: L("menu.app.about")))
        XCTAssertEqual(titles[about + 1], L("menu.app.check-updates"))
        let item = appMenu.items[about + 1]
        XCTAssertEqual(item.action, #selector(AppDelegate.checkForUpdates(_:)))
        XCTAssertTrue(item.target === NSApp.delegate)
    }

    func testTheItemIsDisabledWithoutAnUpdater() throws {
        let delegate = try XCTUnwrap(NSApp.delegate as? AppDelegate)
        let item = NSMenuItem(title: "x", action: #selector(AppDelegate.checkForUpdates(_:)), keyEquivalent: "")
        XCTAssertFalse(delegate.validateMenuItem(item), "the test host has no Sparkle updater")
        // Calling it anyway is harmless.
        delegate.checkForUpdates(nil)
        XCTAssertTrue(delegate.session.updates.viewModel.state.isIdle)
    }
}
