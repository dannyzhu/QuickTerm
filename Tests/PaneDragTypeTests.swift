import UniformTypeIdentifiers
import XCTest
@testable import QuickTerm

/// The pasteboard type behind Cmd+drag of a pane. An exported type that the app does not declare
/// is unknown to Launch Services, and then every drop target refuses the drag. The port used
/// Ghostty's identifier, which Ghostty.app declares for the whole machine, so the missing
/// declaration only showed on a Mac without Ghostty installed (Mac mini, 2026-09-27).
final class PaneDragTypeTests: XCTestCase {
    func testTheAppDeclaresItsOwnPaneDragType() throws {
        // The test host is QuickTerm.app itself, so its Info.plist is the one that ships.
        let declarations = try XCTUnwrap(
            Bundle.main.infoDictionary?["UTExportedTypeDeclarations"] as? [[String: Any]],
            "Info.plist declares no exported types at all")
        let declared = declarations.compactMap { $0["UTTypeIdentifier"] as? String }
        XCTAssertTrue(declared.contains(UTType.quickTermPaneId.identifier),
                      "the pane drag type is not declared: \(declared)")
        let pane = try XCTUnwrap(declarations.first { $0["UTTypeIdentifier"] as? String == UTType.quickTermPaneId.identifier })
        XCTAssertEqual(pane["UTTypeConformsTo"] as? [String], ["public.data"])
    }

    func testThePaneDragTypeIsQuickTermsOwn() {
        XCTAssertEqual(UTType.quickTermPaneId.identifier, "dev.danny.quickterm.pane",
                       "Ghostty's identifier would depend on Ghostty.app being installed")
        XCTAssertEqual(NSPasteboard.PasteboardType.quickTermPaneId.rawValue, UTType.quickTermPaneId.identifier)
    }
}
