import XCTest
@testable import QuickTerm

final class FloatingPaneTests: XCTestCase {
    private let rect = CGRect(x: 0.2, y: 0.2, width: 0.5, height: 0.4)
    private let band: CGFloat = 0.02

    func testDragEdgesZones() {
        func edges(_ x: CGFloat, _ y: CGFloat) -> FloatingPane.DragEdges? {
            FloatingPane.dragEdges(at: CGPoint(x: x, y: y), in: rect, bandX: band, bandY: band)
        }
        XCTAssertEqual(edges(0.45, 0.4), [], "中间 = 移动")
        XCTAssertEqual(edges(0.21, 0.4), [.left])
        XCTAssertEqual(edges(0.69, 0.4), [.right])
        XCTAssertEqual(edges(0.45, 0.21), [.top])
        XCTAssertEqual(edges(0.45, 0.59), [.bottom])
        XCTAssertEqual(edges(0.21, 0.21), [.left, .top], "角 = 双轴")
        XCTAssertEqual(edges(0.69, 0.59), [.right, .bottom])
        XCTAssertEqual(edges(0.69, 0.21), [.right, .top])
        XCTAssertEqual(edges(0.21, 0.59), [.left, .bottom])
        XCTAssertNil(edges(0.1, 0.4), "矩形外 = 不命中")
        XCTAssertTrue(edges(0.45, 0.4)?.isMove ?? false)
    }

    func testDragEdgesBandNeverOverlapsOnTinyPane() {
        let tiny = CGRect(x: 0.5, y: 0.5, width: 0.02, height: 0.02)
        let e = FloatingPane.dragEdges(at: CGPoint(x: 0.5195, y: 0.5195), in: tiny, bandX: 0.05, bandY: 0.05)
        XCTAssertEqual(e, [.right, .bottom], "带宽不超过半边：右下点只命中右/下")
    }

    @MainActor
    func testResizeKeepsOppositeEdgeAndMinSize() throws {
        let pane = try XCTUnwrap((NSApp.delegate as? AppDelegate)?.controller?.newSurface(inheritingFrom: nil))
        let fp = FloatingPane(pane: pane, rect: rect)
        let right = fp.resized(edges: [.right], dx: 0.1, dy: 0)
        XCTAssertEqual(right.rect.minX, 0.2, accuracy: 1e-9, "拖右边：左边不动")
        XCTAssertEqual(right.rect.width, 0.6, accuracy: 1e-9)
        XCTAssertEqual(right.rect.height, 0.4, accuracy: 1e-9)
        let left = fp.resized(edges: [.left], dx: 0.1, dy: 0)
        XCTAssertEqual(left.rect.maxX, 0.7, accuracy: 1e-9, "拖左边：右边不动")
        XCTAssertEqual(left.rect.width, 0.4, accuracy: 1e-9)
        let top = fp.resized(edges: [.top], dx: 0, dy: -0.1)
        XCTAssertEqual(top.rect.maxY, 0.6, accuracy: 1e-9, "拖上边向上：下边不动，变高")
        XCTAssertEqual(top.rect.height, 0.5, accuracy: 1e-9)
        let corner = fp.resized(edges: [.right, .bottom], dx: 0.1, dy: 0.1)
        XCTAssertEqual(corner.rect.width, 0.6, accuracy: 1e-9)
        XCTAssertEqual(corner.rect.height, 0.5, accuracy: 1e-9)
        XCTAssertEqual(corner.rect.minX, rect.minX, accuracy: 1e-9)
        XCTAssertEqual(corner.rect.minY, rect.minY, accuracy: 1e-9)
        let shrink = fp.resized(edges: [.left], dx: 10, dy: 0)
        XCTAssertEqual(shrink.rect.width, FloatingPane.minSize, accuracy: 1e-9, "不小于最小尺寸")
        XCTAssertEqual(shrink.rect.maxX, 0.7, accuracy: 1e-9, "到最小尺寸时右边仍不动")
        // 拖过内容区边缘：被拖的边停在边缘，对边绝不动（原先 clamped() 会把对边推走）
        let overTop = fp.resized(edges: [.top], dx: 0, dy: -5)
        XCTAssertEqual(overTop.rect.minY, 0, accuracy: 1e-9, "上边停在顶端")
        XCTAssertEqual(overTop.rect.maxY, 0.6, accuracy: 1e-9, "下边不动")
        let overRight = fp.resized(edges: [.right], dx: 5, dy: 0)
        XCTAssertEqual(overRight.rect.maxX, 1, accuracy: 1e-9, "右边停在右端")
        XCTAssertEqual(overRight.rect.minX, 0.2, accuracy: 1e-9, "左边不动")
        // 已经出界的 pane 不被强行拉回
        let offscreen = FloatingPane(pane: pane, rect: CGRect(x: -0.1, y: 0.2, width: 0.5, height: 0.4))
        let nudged = offscreen.resized(edges: [.left], dx: -0.02, dy: 0)
        XCTAssertEqual(nudged.rect.minX, -0.1, accuracy: 1e-9, "出界的边不再向外，但也不拉回")
        pane.removeFromSuperview()
    }
}
