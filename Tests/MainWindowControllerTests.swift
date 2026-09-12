import XCTest
import GhosttyKit
@testable import QuickTerm

@MainActor
final class MainWindowControllerTests: XCTestCase {
    private var controller: MainWindowController {
        get throws {
            try XCTUnwrap((NSApp.delegate as? AppDelegate)?.controller)
        }
    }

    func testFocusFollowsMouseEnabled() throws {
        XCTAssertTrue(try controller.focusFollowsMouse, "focus-follows-mouse (spec §4.2) must be on")
    }

    func testEngineOverlayInjectsOpacity() throws {
        // Layer 3 of the config chain, end to end: the overlay file exists and the engine read the injected value.
        XCTAssertTrue(FileManager.default.fileExists(atPath: EngineOverlay.url.path))
        let ghostty = try XCTUnwrap((NSApp.delegate as? AppDelegate)?.ghostty)
        // The getter means "dim opacity" = 1 - the configured value: inject 0.96, read back 0.04.
        XCTAssertEqual(ghostty.config.unfocusedSplitOpacity, 1 - 0.96, accuracy: 0.001,
                       "unfocused-split-opacity must come from the QuickTerm overlay (which injects 0.96)")
    }

    func testNewPaneInsertAndClose() throws {
        let c = try controller
        c.model.switchTo(0)
        let before = c.paneList.count
        c.perform(.newTerminal)
        XCTAssertEqual(c.paneList.count, before + 1)
        let newPane = try XCTUnwrap(c.focusedSurface)
        c.closePane(newPane, confirmIfNeeded: false, animated: false)
        XCTAssertEqual(c.paneList.count, before,
                       "closing must reclaim the slot (the scrolling layout drops the emptied column)")
    }
}
