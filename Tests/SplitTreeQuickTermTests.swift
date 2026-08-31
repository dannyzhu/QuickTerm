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
        XCTAssertEqual(tree.dwindleDirection(for: v), .right, "宽 pane 应向右分裂")
        v.frame = NSRect(x: 0, y: 0, width: 400, height: 800)
        XCTAssertEqual(tree.dwindleDirection(for: v), .down, "高 pane 应向下分裂")
    }

    func testSwappingExchangesLeaves() throws {
        let a = try makeSurface(), b = try makeSurface()
        let tree = try SplitTree(view: a).inserting(view: b, at: a, direction: .right)
        let swapped = try tree.swapping(a, b)
        guard case .split(let s) = swapped.root else { return XCTFail("应为 split 根") }
        XCTAssertEqual(s.left, .leaf(view: b), "交换后左叶应为 b")
        XCTAssertEqual(s.right, .leaf(view: a), "交换后右叶应为 a")
    }

    func testSwappingMissingViewThrows() throws {
        let a = try makeSurface(), b = try makeSurface()
        let tree = SplitTree(view: a)
        XCTAssertThrowsError(try tree.swapping(a, b), "b 不在树中应抛错")
    }

    func testTogglingSplitDirectionFlipsParent() throws {
        let a = try makeSurface(), b = try makeSurface()
        let tree = try SplitTree(view: a).inserting(view: b, at: a, direction: .right)
        guard case .split(let before) = tree.root else { return XCTFail() }
        let toggled = try tree.togglingSplitDirection(around: a)
        guard case .split(let after) = toggled.root else { return XCTFail("应保持 split 根") }
        XCTAssertNotEqual(after.direction, before.direction, "父 split 方向应取反")
        XCTAssertEqual(after.left, before.left, "叶位置不变")
        XCTAssertEqual(after.right, before.right, "叶位置不变")
    }

    func testTogglingOnRootLeafThrows() throws {
        let a = try makeSurface()
        XCTAssertThrowsError(try SplitTree(view: a).togglingSplitDirection(around: a))
    }
}
