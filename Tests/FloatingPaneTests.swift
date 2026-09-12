import XCTest
@testable import QuickTerm

final class FloatingPaneTests: XCTestCase {
    private let rect = CGRect(x: 0.2, y: 0.2, width: 0.5, height: 0.4)
    private let band: CGFloat = 0.02

    func testDragEdgesZones() {
        func edges(_ x: CGFloat, _ y: CGFloat) -> FloatingPane.DragEdges? {
            FloatingPane.dragEdges(at: CGPoint(x: x, y: y), in: rect, bandX: band, bandY: band)
        }
        XCTAssertEqual(edges(0.45, 0.4), [], "middle = move")
        XCTAssertEqual(edges(0.21, 0.4), [.left])
        XCTAssertEqual(edges(0.69, 0.4), [.right])
        XCTAssertEqual(edges(0.45, 0.21), [.top])
        XCTAssertEqual(edges(0.45, 0.59), [.bottom])
        XCTAssertEqual(edges(0.21, 0.21), [.left, .top], "corner = both axes")
        XCTAssertEqual(edges(0.69, 0.59), [.right, .bottom])
        XCTAssertEqual(edges(0.69, 0.21), [.right, .top])
        XCTAssertEqual(edges(0.21, 0.59), [.left, .bottom])
        XCTAssertNil(edges(0.1, 0.4), "outside the rect = no hit")
        XCTAssertTrue(edges(0.45, 0.4)?.isMove ?? false)
    }

    func testDragEdgesBandNeverOverlapsOnTinyPane() {
        let tiny = CGRect(x: 0.5, y: 0.5, width: 0.02, height: 0.02)
        let e = FloatingPane.dragEdges(at: CGPoint(x: 0.5195, y: 0.5195), in: tiny, bandX: 0.05, bandY: 0.05)
        XCTAssertEqual(e, [.right, .bottom], "the band never exceeds half an edge: a bottom-right point hits only right/bottom")
    }

    @MainActor
    func testResizeKeepsOppositeEdgeAndMinSize() throws {
        let pane = try XCTUnwrap((NSApp.delegate as? AppDelegate)?.controller?.newSurface(inheritingFrom: nil))
        let fp = FloatingPane(pane: pane, rect: rect)
        let right = fp.resized(edges: [.right], dx: 0.1, dy: 0)
        XCTAssertEqual(right.rect.minX, 0.2, accuracy: 1e-9, "drag the right edge: the left edge stays put")
        XCTAssertEqual(right.rect.width, 0.6, accuracy: 1e-9)
        XCTAssertEqual(right.rect.height, 0.4, accuracy: 1e-9)
        let left = fp.resized(edges: [.left], dx: 0.1, dy: 0)
        XCTAssertEqual(left.rect.maxX, 0.7, accuracy: 1e-9, "drag the left edge: the right edge stays put")
        XCTAssertEqual(left.rect.width, 0.4, accuracy: 1e-9)
        let top = fp.resized(edges: [.top], dx: 0, dy: -0.1)
        XCTAssertEqual(top.rect.maxY, 0.6, accuracy: 1e-9, "drag the top edge up: the bottom edge stays put, the pane gets taller")
        XCTAssertEqual(top.rect.height, 0.5, accuracy: 1e-9)
        let corner = fp.resized(edges: [.right, .bottom], dx: 0.1, dy: 0.1)
        XCTAssertEqual(corner.rect.width, 0.6, accuracy: 1e-9)
        XCTAssertEqual(corner.rect.height, 0.5, accuracy: 1e-9)
        XCTAssertEqual(corner.rect.minX, rect.minX, accuracy: 1e-9)
        XCTAssertEqual(corner.rect.minY, rect.minY, accuracy: 1e-9)
        let shrink = fp.resized(edges: [.left], dx: 10, dy: 0)
        XCTAssertEqual(shrink.rect.width, FloatingPane.minSize, accuracy: 1e-9, "never smaller than the minimum size")
        XCTAssertEqual(shrink.rect.maxX, 0.7, accuracy: 1e-9, "at the minimum size the right edge still does not move")
        // Dragged past the edge of the content area: the dragged edge stops at the edge and the opposite
        // edge never moves (the old clamped() used to shove the opposite edge along).
        let overTop = fp.resized(edges: [.top], dx: 0, dy: -5)
        XCTAssertEqual(overTop.rect.minY, 0, accuracy: 1e-9, "the top edge stops at the top")
        XCTAssertEqual(overTop.rect.maxY, 0.6, accuracy: 1e-9, "the bottom edge stays put")
        let overRight = fp.resized(edges: [.right], dx: 5, dy: 0)
        XCTAssertEqual(overRight.rect.maxX, 1, accuracy: 1e-9, "the right edge stops at the right")
        XCTAssertEqual(overRight.rect.minX, 0.2, accuracy: 1e-9, "the left edge stays put")
        // A pane that is already off-screen is not yanked back in.
        let offscreen = FloatingPane(pane: pane, rect: CGRect(x: -0.1, y: 0.2, width: 0.5, height: 0.4))
        let nudged = offscreen.resized(edges: [.left], dx: -0.02, dy: 0)
        XCTAssertEqual(nudged.rect.minX, -0.1, accuracy: 1e-9,
                       "an off-screen edge moves no further out, but it is not pulled back either")
        pane.removeFromSuperview()
    }
}
