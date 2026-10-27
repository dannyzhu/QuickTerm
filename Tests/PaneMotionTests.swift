import AppKit
import XCTest
@testable import QuickTerm

/// The pure halves of three pane behaviours: a two-finger swipe is one column (`SwipeStep`), a
/// swap slides from the old frame (`PaneSwapAnimation.transform`), and a scrolling column that only
/// peeks in at the edge takes a click rather than hover (`isFullyVisible`).
final class PaneMotionTests: XCTestCase {
    // MARK: SwipeStep

    func testOneGestureIsOneStepHoweverFarItGoes() {
        var step = SwipeStep()
        XCTAssertNil(step.feed(deltaX: -5, phase: .began, momentum: [], at: 0))
        XCTAssertNil(step.feed(deltaX: -10, phase: .changed, momentum: [], at: 0.01))
        XCTAssertEqual(step.feed(deltaX: -20, phase: .changed, momentum: [], at: 0.02), .right)
        // The rest of the gesture, and the fling after it, are swallowed.
        XCTAssertNil(step.feed(deltaX: -200, phase: .changed, momentum: [], at: 0.03))
        XCTAssertNil(step.feed(deltaX: 0, phase: .ended, momentum: [], at: 0.04))
        XCTAssertNil(step.feed(deltaX: -300, phase: [], momentum: .changed, at: 0.05))
        XCTAssertNil(step.feed(deltaX: 0, phase: [], momentum: .ended, at: 0.3))
        // A new gesture steps again, the other way.
        XCTAssertNil(step.feed(deltaX: 10, phase: .began, momentum: [], at: 1))
        XCTAssertEqual(step.feed(deltaX: 25, phase: .changed, momentum: [], at: 1.01), .left)
    }

    func testAShortFlickIsNotASwipe() {
        var step = SwipeStep()
        XCTAssertNil(step.feed(deltaX: -5, phase: .began, momentum: [], at: 0))
        XCTAssertNil(step.feed(deltaX: -10, phase: .changed, momentum: [], at: 0.01))
        XCTAssertNil(step.feed(deltaX: 0, phase: .ended, momentum: [], at: 0.02))
        XCTAssertFalse(step.inGesture)
    }

    func testAPhaselessWheelStepsOncePerCooldown() {
        var step = SwipeStep()
        XCTAssertEqual(step.feed(deltaX: -40, phase: [], momentum: [], at: 0), .right)
        XCTAssertNil(step.feed(deltaX: -40, phase: [], momentum: [], at: 0.1))
        XCTAssertEqual(step.feed(deltaX: -40, phase: [], momentum: [], at: 0.5), .right)
    }

    // MARK: Swap slide

    func testTransformDrawsTheNewFrameOverTheOldOne() throws {
        let from = CGRect(x: 0, y: 0, width: 400, height: 300)
        let to = CGRect(x: 400, y: 0, width: 200, height: 600)
        let t = try XCTUnwrap(PaneSwapAnimation.transform(from: from, to: to))
        XCTAssertEqual(t.offset, CGSize(width: -400, height: 0))
        XCTAssertEqual(t.scale.width, 2, accuracy: 0.0001)
        XCTAssertEqual(t.scale.height, 0.5, accuracy: 0.0001)
        // Scale about the top-leading corner, then offset: the corners land on the old frame.
        XCTAssertEqual(to.minX + t.offset.width, from.minX)
        XCTAssertEqual(to.width * t.scale.width, from.width, accuracy: 0.0001)
    }

    func testNoTransformWhenNothingMoved() {
        let frame = CGRect(x: 10, y: 10, width: 300, height: 200)
        XCTAssertNil(PaneSwapAnimation.transform(from: frame, to: frame))
        XCTAssertNil(PaneSwapAnimation.transform(from: frame, to: .zero))
    }

    // MARK: Peeking columns

    @MainActor
    func testOnlyAFullyVisibleColumnTakesHoverFocus() {
        let viewport = CGRect(x: 0, y: 0, width: 1000, height: 800)
        XCTAssertTrue(MainWindowController.isFullyVisible(CGRect(x: 20, y: 0, width: 480, height: 800), in: viewport))
        XCTAssertTrue(MainWindowController.isFullyVisible(CGRect(x: -0.5, y: 0, width: 500, height: 800), in: viewport),
                      "a point of rounding is not a peek")
        XCTAssertFalse(MainWindowController.isFullyVisible(CGRect(x: 960, y: 0, width: 480, height: 800), in: viewport))
        XCTAssertFalse(MainWindowController.isFullyVisible(CGRect(x: -440, y: 0, width: 480, height: 800), in: viewport))
    }
}
