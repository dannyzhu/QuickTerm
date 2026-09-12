import XCTest
import GhosttyKit
@testable import QuickTerm

@MainActor
final class SplitTreeQuickTermTests: XCTestCase {
    private func makeSurface() throws -> Ghostty.SurfaceView {
        let appDelegate = try XCTUnwrap(NSApp.delegate as? AppDelegate)
        return Ghostty.SurfaceView(try XCTUnwrap(appDelegate.ghostty.app), baseConfig: nil)
    }

    func testDwindleDirectionFollowsAspectRatio() throws {
        let v = try makeSurface()
        let tree = SplitTree(view: v)
        v.frame = NSRect(x: 0, y: 0, width: 800, height: 400)
        XCTAssertEqual(tree.dwindleDirection(for: v), .right, "a wide pane splits to the right")
        v.frame = NSRect(x: 0, y: 0, width: 400, height: 800)
        XCTAssertEqual(tree.dwindleDirection(for: v), .down, "a tall pane splits downward")
    }

    func testSwappingExchangesLeaves() throws {
        let a = try makeSurface(), b = try makeSurface()
        let tree = try SplitTree(view: a).inserting(view: b, at: a, direction: .right)
        let swapped = try tree.swapping(a, b)
        guard case .split(let s) = swapped.root else { return XCTFail("root should be a split") }
        XCTAssertEqual(s.left, .leaf(view: b), "after the swap the left leaf is b")
        XCTAssertEqual(s.right, .leaf(view: a), "after the swap the right leaf is a")
    }

    func testSwappingMissingViewThrows() throws {
        let a = try makeSurface(), b = try makeSurface()
        let tree = SplitTree(view: a)
        XCTAssertThrowsError(try tree.swapping(a, b), "swapping must throw when b is not in the tree")
    }

    func testTogglingSplitDirectionFlipsParent() throws {
        let a = try makeSurface(), b = try makeSurface()
        let tree = try SplitTree(view: a).inserting(view: b, at: a, direction: .right)
        guard case .split(let before) = tree.root else { return XCTFail() }
        let toggled = try tree.togglingSplitDirection(around: a)
        guard case .split(let after) = toggled.root else { return XCTFail("the root must still be a split") }
        XCTAssertNotEqual(after.direction, before.direction, "the parent split's direction must flip")
        XCTAssertEqual(after.left, before.left, "leaf positions stay put")
        XCTAssertEqual(after.right, before.right, "leaf positions stay put")
    }

    func testTogglingOnRootLeafThrows() throws {
        let a = try makeSurface()
        XCTAssertThrowsError(try SplitTree(view: a).togglingSplitDirection(around: a))
    }
}
