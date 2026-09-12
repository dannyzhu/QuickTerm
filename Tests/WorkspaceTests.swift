import XCTest
import AppKit
@testable import QuickTerm

@MainActor
final class WorkspaceTests: XCTestCase {
    private var controller: MainWindowController {
        get throws { try XCTUnwrap((NSApp.delegate as? AppDelegate)?.controller) }
    }

    // Note: do not use `override func setUp() async`. The override strips the @MainActor isolation, and
    // touching @Published state from a background thread blows up the TEST_HOST (SwiftUI publishing off the
    // main thread).
    // A case that needs to reset calls switchTo(0) itself, inside its (@MainActor) body.

    func testDefaultFiveWorkspaces() throws {
        let c = try controller
        XCTAssertEqual(c.model.layouts.count, 5, "five workspaces by default (a confirmed decision point)")
        XCTAssertEqual(WorkspaceModel.workspaceCount, 5)
    }

    func testDefaultLayoutIsScrolling() throws {
        // spec §4.2-bis v5: a new workspace defaults to the scrolling infinite canvas.
        let c = try controller
        c.switchWorkspace(1)
        if case .scrolling = c.model.layout {} else {
            XCTFail("an empty workspace should default to scrolling (actual \(c.model.layout.name))")
        }
        c.model.switchTo(0)
    }

    func testSwitchKeepsLayoutsIndependent() throws {
        let c = try controller
        c.model.switchTo(0)
        let ws0Count = c.paneList.count
        c.switchWorkspace(1)
        XCTAssertEqual(c.model.activeIndex, 1)
        XCTAssertTrue(c.model.layout.isEmpty, "workspace 2 starts out empty")
        c.switchWorkspace(0)
        XCTAssertEqual(c.paneList.count, ws0Count, "workspace 1 is unchanged after switching back")
    }

    func testSwitchOutOfBoundsIsSafe() throws {
        let c = try controller
        let before = c.model.activeIndex
        c.model.switchTo(99)
        c.model.switchTo(-1)
        XCTAssertEqual(c.model.activeIndex, before)
    }

    func testMoveFocusedPaneToEmptyWorkspaceAndBack() throws {
        let c = try controller
        c.model.switchTo(0)
        c.perform(.newTerminal)                       // Inserted to the right of the focused column
        let ws0Before = c.paneList.count
        let moved = try XCTUnwrap(c.focusedSurface)

        c.moveFocusedPane(to: 2)
        XCTAssertEqual(c.model.activeIndex, 2, "the move follows the pane to the target workspace")
        XCTAssertEqual(c.paneList.count, 1, "the target workspace holds the moved pane")
        XCTAssertTrue(c.paneList.first === moved)

        c.switchWorkspace(0)
        XCTAssertEqual(c.paneList.count, ws0Before - 1, "the source workspace is one pane lighter")

        // Cleanup
        c.switchWorkspace(2)
        if let pane = c.paneList.first { c.closePane(pane, confirmIfNeeded: false, animated: false) }
        c.model.switchTo(0)
    }

    func testLayoutToggleRoundTripPreservesPanes() throws {
        // Cmd+L: scrolling ⇄ dwindle keeps every pane (spec §4.2-bis).
        let c = try controller
        c.model.switchTo(0)
        c.perform(.newTerminal)
        let before = c.paneList.count
        let extra = try XCTUnwrap(c.focusedSurface)

        c.perform(.toggleLayout)
        if case .dwindle = c.model.layout {} else { XCTFail("it should switch to dwindle") }
        XCTAssertEqual(c.paneList.count, before, "the switch keeps every pane")

        c.perform(.toggleLayout)
        if case .scrolling = c.model.layout {} else { XCTFail("it should switch back to scrolling") }
        XCTAssertEqual(c.paneList.count, before, "the round trip keeps every pane")

        c.closePane(extra, confirmIfNeeded: false, animated: false)
    }

    func testWorkspaceKeybindings() {
        let map = KeybindingMap()
        XCTAssertEqual(map.action(key: "1", modifiers: .command)?.action, .gotoWorkspace1)
        XCTAssertEqual(map.action(key: "5", modifiers: .command)?.action, .gotoWorkspace5)
        XCTAssertEqual(map.action(key: "3", modifiers: [.command, .shift])?.action, .moveToWorkspace3)
        XCTAssertEqual(map.action(key: "space", modifiers: [.command, .shift])?.action, .toggleBar)
        XCTAssertEqual(map.action(key: "l", modifiers: .command)?.action, .toggleLayout)
        XCTAssertNil(map.action(key: "6", modifiers: .command), "workspaces only go 1-5")
    }
}

extension WorkspaceTests {
    @MainActor
    func testToggleFloatRoundTrip() throws {
        let c = try controller
        c.model.switchTo(0)
        c.perform(.newTerminal)
        let pane = try XCTUnwrap(c.focusedSurface)
        let tiledBefore = c.model.layout.paneList.count

        c.toggleFloat(pane)
        XCTAssertEqual(c.model.floating.count, 1, "floating adds one to the floating layer")
        XCTAssertEqual(c.model.layout.paneList.count, tiledBefore - 1, "and takes one from the tiling layer")
        XCTAssertTrue(c.model.floating.first?.pane === pane)
        XCTAssertTrue(c.paneList.contains(pane), "paneList covers the floating layer")

        c.toggleFloat(pane)
        XCTAssertTrue(c.model.floating.isEmpty, "putting it back empties the floating layer")
        XCTAssertEqual(c.model.layout.paneList.count, tiledBefore, "the tiling layer is restored")

        c.closePane(pane, confirmIfNeeded: false, animated: false)
    }

    func testToggleFloatKeybinding() {
        let map = KeybindingMap()
        XCTAssertEqual(map.action(key: "t", modifiers: .command)?.action, .toggleFloat,
                       "Cmd+T toggles floating; it no longer passes through to ghostty's new_tab")
    }

    /// The default geometry when floating (Omarchy-like): width = the default column width × 0.75, height =
    /// 45% of the content area, centered.
    func testFloatDefaultRectOmarchyGeometry() {
        let r = FloatingPane.defaultRect(columnFactor: 0.49)  // The two-column default
        XCTAssertEqual(r.width, 0.3675, accuracy: 0.0001, "width = 0.49 × 0.75")
        XCTAssertEqual(r.height, 0.45, accuracy: 0.0001, "height = 45% of the content area")
        XCTAssertEqual(r.midX, 0.5, accuracy: 0.0001, "centered horizontally")
        XCTAssertEqual(r.midY, 0.5, accuracy: 0.0001, "centered vertically")
        // Four columns are narrower, and a tiny factor hits a floor so the pane stays usable.
        XCTAssertEqual(FloatingPane.defaultRect(columnFactor: 0.245).width,
                       0.18375, accuracy: 0.0001)
        XCTAssertEqual(FloatingPane.defaultRect(columnFactor: 0.05).width, 0.15)
    }

    /// Floating goes through defaultRect rather than keeping the large tiled size in place.
    @MainActor
    func testToggleFloatUsesDefaultRect() throws {
        let c = try controller
        c.model.switchTo(0)
        c.perform(.newTerminal)
        let pane = try XCTUnwrap(c.focusedSurface)
        c.toggleFloat(pane)
        defer {
            c.toggleFloat(pane)
            c.closePane(pane, confirmIfNeeded: false, animated: false)
        }
        let rect = try XCTUnwrap(c.model.floating.first?.rect)
        XCTAssertEqual(rect, FloatingPane.defaultRect(columnFactor: c.columnFactor))
    }

    /// The normalized conversion agrees with NSHostingView's flipped coordinates.
    /// (Regression: it once assumed bottom-left and flipped twice, mirroring the whole occlusion band vertically.)
    @MainActor
    func testNormalizedContentPointTopLeft() throws {
        let c = try controller
        let content = try XCTUnwrap(c.window?.contentView)
        let W = content.bounds.width
        let H = content.bounds.height
        let innerH = H - StatusBarView.height  // barVisible defaults to true
        // Window coordinates are always bottom-left: take a point 10pt below the status bar, a quarter of the
        // way in from the left.
        let loc = NSPoint(x: W / 4, y: H - StatusBarView.height - 10)
        let p = try XCTUnwrap(c.normalizedContentPoint(loc))
        XCTAssertEqual(p.x, 0.25, accuracy: 0.01)
        XCTAssertEqual(p.y, 10 / innerH, accuracy: 0.01, "top-left origin: 10pt under the bar is near the top")
        // 10pt above the bottom of the content area comes out close to 1.
        let low = try XCTUnwrap(c.normalizedContentPoint(NSPoint(x: W / 2, y: 10)))
        XCTAssertEqual(low.y, (innerH - 10) / innerH, accuracy: 0.01)
    }

    /// Hover occlusion: only a floating pane with a higher z occludes. This is model geometry and never calls
    /// hitTest, so a non-surface cover such as the Cmd drag-source overlay or an overlay scroller is never
    /// mistaken for one.
    func testHoverOcclusionGeometry() {
        let a = CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.3)   // z0
        let b = CGRect(x: 0.3, y: 0.3, width: 0.3, height: 0.3)   // z1 (topmost)
        let rects = [a, b]
        let inBoth = CGPoint(x: 0.35, y: 0.35)
        let onlyA = CGPoint(x: 0.15, y: 0.15)
        let outside = CGPoint(x: 0.9, y: 0.9)
        // A tiled pane (nil): any floating pane covering the point occludes it.
        XCTAssertTrue(HoverOcclusion.isOccluded(paneFloatIndex: nil, floatingRects: rects, at: onlyA))
        XCTAssertTrue(HoverOcclusion.isOccluded(paneFloatIndex: nil, floatingRects: rects, at: inBoth))
        XCTAssertFalse(HoverOcclusion.isOccluded(paneFloatIndex: nil, floatingRects: rects, at: outside))
        // Floating at z0: occluded only by a higher z, never by itself.
        XCTAssertTrue(HoverOcclusion.isOccluded(paneFloatIndex: 0, floatingRects: rects, at: inBoth))
        XCTAssertFalse(HoverOcclusion.isOccluded(paneFloatIndex: 0, floatingRects: rects, at: onlyA))
        // The topmost floating pane is never occluded, and with no floating panes there is no occlusion.
        XCTAssertFalse(HoverOcclusion.isOccluded(paneFloatIndex: 1, floatingRects: rects, at: inBoth))
        XCTAssertFalse(HoverOcclusion.isOccluded(paneFloatIndex: nil, floatingRects: [], at: inBoth))
    }

    @MainActor
    func testFloatingPaneClampAndPersistV3() throws {
        let c = try controller
        let wild = FloatingPane(
            pane: c.newSurface(inheritingFrom: nil),
            rect: CGRect(x: 2.0, y: -1.0, width: 0.05, height: 5.0)).clamped()
        XCTAssertGreaterThanOrEqual(wild.rect.width, 0.15)
        XCTAssertLessThanOrEqual(wild.rect.height, 1.0)
        XCTAssertGreaterThanOrEqual(wild.rect.origin.y, 0)

        // A v5 round trip includes the floating layer; v2 JSON, which has no floatings field, still decodes
        // after migration, with an empty floating layer.
        let state = PersistedState(windows: [
            WindowState(layouts: c.model.layouts, floatings: c.model.floatings, activeIndex: 0)
        ])
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(PersistedState.self, from: data)
        XCTAssertEqual(decoded.version, 5)
        XCTAssertEqual(decoded.windows.first?.floatings?.count, c.model.floatings.count)

        let legacy = LegacyPersistedState(
            layouts: c.model.layouts, floatings: c.model.floatings, activeIndex: 0)
        var v2 = try JSONSerialization.jsonObject(
            with: try JSONEncoder().encode(legacy)) as! [String: Any]
        v2["version"] = 2
        v2.removeValue(forKey: "floatings")
        let v2data = try JSONSerialization.data(withJSONObject: v2)
        let decodedV2 = try JSONDecoder().decode(LegacyPersistedState.self, from: v2data)
        XCTAssertNil(decodedV2.floatings, "v2 archive compatibility: the floating layer defaults to absent")
    }
}

extension WorkspaceTests {
    /// Quit semantics: confirm only when panes are open; closing the last pane leaves the window standing and
    /// a new terminal can be created straight away.
    @MainActor
    func testLastPaneCloseKeepsWindowAndQuitConfirmRule() throws {
        XCTAssertFalse(AppDelegate.shouldConfirmQuit(openPaneCount: 0), "no panes -> quit straight away")
        XCTAssertTrue(AppDelegate.shouldConfirmQuit(openPaneCount: 1), "panes open -> confirm")

        let c = try controller
        let home = c.model.activeIndex
        let ws = c.model.layouts.count - 1
        c.model.switchTo(ws)
        defer { c.model.switchTo(home) }
        XCTAssertTrue(c.model.layout.isEmpty, "the last workspace should be empty")
        c.perform(.newTerminal)
        let only = try XCTUnwrap(c.paneList.first)
        c.closePane(only, confirmIfNeeded: false, animated: false)
        XCTAssertTrue(c.model.layout.isEmpty, "the last pane is closed")
        XCTAssertTrue(c.window?.isVisible ?? false, "the window stays; it does not close with the last pane")
        c.perform(.newTerminal)
        XCTAssertEqual(c.paneList.count, 1, "a new terminal can be created in an empty workspace")
        c.closePane(try XCTUnwrap(c.paneList.first), confirmIfNeeded: false, animated: false)
    }

    /// The close animation: a close first marks the pane as fading (it stays in the layout, and focus has
    /// already gone to its successor), and only removes it once the animation is done.
    /// Any layout operation flushes a fading pane out first, so the timer has no side effect when it fires.
    @MainActor
    func testClosePaneAnimatedDefersRemovalAndFocusesSuccessor() throws {
        let c = try controller
        let prevAnim = c.closeAnimationEnabled
        defer { c.closeAnimationEnabled = prevAnim }
        let home = c.model.activeIndex
        let ws = c.model.layouts.count - 1
        c.model.switchTo(ws)
        defer { c.model.switchTo(home) }
        XCTAssertTrue(c.model.layout.isEmpty, "the last workspace should be empty")
        c.model.layout = .dwindle(SplitTree())
        c.closeAnimationEnabled = true   // Not subject to the system's "reduce motion" setting
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        c.perform(.newTerminal)
        let a = try XCTUnwrap(c.paneList.first)
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        c.perform(.newTerminal)
        let b = try XCTUnwrap(c.paneList.first { $0 !== a })
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        XCTAssertTrue(c.window?.firstResponder === b, "the new pane takes focus")

        c.closePane(b, confirmIfNeeded: false)   // animated defaults to true
        XCTAssertEqual(c.paneList.count, 2, "the pane stays in the layout while the animation runs")
        XCTAssertTrue(c.model.closingPanes.contains(b.id))
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertTrue(c.window?.firstResponder === a, "focus goes to the successor the moment the close starts")
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        XCTAssertEqual(c.paneList.count, 1, "it is really removed once the animation is done")
        XCTAssertTrue(c.model.closingPanes.isEmpty)
        XCTAssertTrue(c.window?.firstResponder === a)

        // flush: a layout operation during the fade removes it at once, and the timer firing later has no effect.
        c.perform(.newTerminal)
        let d = try XCTUnwrap(c.paneList.first { $0 !== a })
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        c.closePane(d, confirmIfNeeded: false)
        XCTAssertEqual(c.paneList.count, 2)
        c.perform(.focusLeft)
        XCTAssertEqual(c.paneList.count, 1, "a layout operation flushes the fading pane first")
        XCTAssertTrue(c.model.closingPanes.isEmpty)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        XCTAssertEqual(c.paneList.count, 1)
        XCTAssertTrue(c.window?.firstResponder === a)
        c.closePane(a, confirmIfNeeded: false, animated: false)
    }

    /// A three-pane dwindle fixture: split(A, split(B, C)) with C focused, in the last, empty workspace, with
    /// the animation enabled.
    @MainActor
    private func dwindleTriple(_ c: MainWindowController) throws -> (a: PaneView, b: PaneView, cc: PaneView) {
        XCTAssertTrue(c.model.layout.isEmpty, "the last workspace should be empty")
        c.model.layout = .dwindle(SplitTree())
        c.closeAnimationEnabled = true
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        func spawn() throws -> PaneView {
            let before = Set(c.paneList.map(ObjectIdentifier.init))
            c.perform(.newTerminal)
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            return try XCTUnwrap(c.paneList.first { !before.contains(ObjectIdentifier($0)) })
        }
        let a = try spawn(), b = try spawn(), cc = try spawn()
        guard case .dwindle(let tree) = c.model.layout, case .split(let root)? = tree.root,
              case .leaf(let l) = root.left, l === a, case .split = root.right else {
            // The fixture's shape is deterministic in the test host (a 1024×720 window, new panes inserted
            // relative to the focused one): a different shape means a focus-handover regression, so this has
            // to fail rather than skip.
            XCTFail("expected split(A, split(B, C)), actual \(c.model.layout)")
            throw FixtureShapeError()
        }
        return (a, b, cc)
    }

    private struct FixtureShapeError: Error {}

    /// A pane's rect in window coordinates.
    private func windowRect(_ v: PaneView) -> NSRect { v.convert(v.bounds, to: nil) }

    /// When the closed pane's sibling is a subtree, that subtree moves up into the parent split view's place
    /// and SwiftUI reuses the view, latched closing state and all. The derived geometry has to snap back to
    /// normal at once, or one child of the surviving subtree is squeezed to zero width while its content stays
    /// pinned at the old size, covering the other.
    @MainActor
    func testCloseAnimationSurvivorSubtreeKeepsGeometry() throws {
        let c = try controller
        let prevAnim = c.closeAnimationEnabled
        defer { c.closeAnimationEnabled = prevAnim }
        let home = c.model.activeIndex
        c.model.switchTo(c.model.layouts.count - 1)
        defer { c.model.switchTo(home) }
        let (a, b, cc) = try dwindleTriple(c)
        defer { for p in [b, cc] where c.paneList.contains(p) { c.closePane(p, confirmIfNeeded: false, animated: false) } }
        c.closePane(a, confirmIfNeeded: false)   // Animated close; the root becomes split(B, C) and reuses the root split view
        RunLoop.main.run(until: Date().addingTimeInterval(0.7))
        XCTAssertEqual(c.paneList.count, 2)
        let rb = windowRect(b), rc = windowRect(cc)
        XCTAssertGreaterThan(rb.width, 40, "B has a bad size \(rb)")
        XCTAssertGreaterThan(rb.height, 40, "B has a bad size \(rb)")
        XCTAssertGreaterThan(rc.width, 40, "C has a bad size \(rc)")
        XCTAssertGreaterThan(rc.height, 40, "C has a bad size \(rc)")
        let overlap = rb.intersection(rc)
        XCTAssertLessThan(overlap.width * overlap.height, 100,
                          "B and C overlap: B=\(rb) C=\(rc) (geometry left over from the closing state)")
    }

    /// Creating a pane in the middle of a fade-out: perform flushes first (root -> leaf B) and then inserts D
    /// (root -> split(B, D)), so the root split view is reused inside a single update.
    /// B must not be squeezed to zero width.
    @MainActor
    func testCloseThenNewTerminalReusesBranchWithoutStaleState() throws {
        let c = try controller
        let prevAnim = c.closeAnimationEnabled
        defer { c.closeAnimationEnabled = prevAnim }
        let home = c.model.activeIndex
        c.model.switchTo(c.model.layouts.count - 1)
        defer { c.model.switchTo(home) }
        XCTAssertTrue(c.model.layout.isEmpty)
        c.model.layout = .dwindle(SplitTree())
        c.closeAnimationEnabled = true
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        c.perform(.newTerminal)
        let a = try XCTUnwrap(c.paneList.first)
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        c.perform(.newTerminal)
        let b = try XCTUnwrap(c.paneList.first { $0 !== a })
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        c.closePane(a, confirmIfNeeded: false)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        c.perform(.newTerminal)                 // flush plus insert
        XCTAssertEqual(c.paneList.count, 2)
        let d = try XCTUnwrap(c.paneList.first { $0 !== b })
        defer { for p in [b, d] where c.paneList.contains(p) { c.closePane(p, confirmIfNeeded: false, animated: false) } }
        RunLoop.main.run(until: Date().addingTimeInterval(0.7))
        let rb = windowRect(b), rd = windowRect(d)
        XCTAssertGreaterThan(rb.width, 40, "B has a bad size \(rb)")
        XCTAssertGreaterThan(rd.width, 40, "D has a bad size \(rd)")
        let overlap = rb.intersection(rd)
        XCTAssertLessThan(overlap.width * overlap.height, 100, "B and D overlap: B=\(rb) D=\(rd)")
    }

    /// Concurrent closes (child processes exiting at once, which never goes through perform and so never
    /// flushes): the successor must not be a pane that is already fading out.
    @MainActor
    func testConcurrentCloseSuccessorSkipsFadingPane() throws {
        let c = try controller
        let prevAnim = c.closeAnimationEnabled
        defer { c.closeAnimationEnabled = prevAnim }
        let home = c.model.activeIndex
        c.model.switchTo(c.model.layouts.count - 1)
        defer { c.model.switchTo(home) }
        let (a, b, cc) = try dwindleTriple(c)
        defer { if c.paneList.contains(a) { c.closePane(a, confirmIfNeeded: false, animated: false) } }
        XCTAssertTrue(c.window?.firstResponder === cc)
        c.closePane(b, confirmIfNeeded: false)    // B fades out; it is not the focused pane
        c.closePane(cc, confirmIfNeeded: false)   // C fades out: its sibling B is already fading, so A has to take over
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        XCTAssertTrue(c.window?.firstResponder === a, "the successor has to skip B, which is fading out")
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        XCTAssertEqual(c.paneList.count, 1)
        XCTAssertTrue(c.paneList.first === a)
        XCTAssertTrue(c.window?.firstResponder === a)
    }

    /// A shell exiting in an inactive workspace: the pane is removed from the workspace it lives in (this used
    /// to handle only the active workspace, leaving dead surfaces behind).
    @MainActor
    func testChildExitInBackgroundWorkspaceRemovesPane() throws {
        let c = try controller
        let home = c.model.activeIndex
        let ws = c.model.layouts.count - 1
        c.switchWorkspace(ws)
        defer { c.switchWorkspace(home) }
        XCTAssertTrue(c.model.layout.isEmpty)
        c.model.layout = .dwindle(SplitTree())
        c.perform(.newTerminal)
        let p = try XCTUnwrap(c.paneList.first)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        c.switchWorkspace(home)
        XCTAssertFalse(c.paneList.contains(p))
        NotificationCenter.default.post(name: Ghostty.Notification.ghosttyCloseSurface, object: p,
                                        userInfo: ["process_alive": false])
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))   // The removal runs asynchronously, outside the callback stack
        XCTAssertTrue(c.model.layouts[ws].isEmpty, "a pane in a background workspace has to be removed")
    }

    /// Pane spacing is the same in both layouts: the window rects of two adjacent SurfaceViews are 2×pane-gap
    /// apart (the dwindle divider takes no layout space), and the dwindle's left edge sits the outer ring plus
    /// the gap, again 2×pane-gap, from the content area.
    @MainActor
    func testPaneGapConsistentAcrossLayouts() throws {
        let c = try controller
        let home = c.model.activeIndex
        c.model.switchTo(c.model.layouts.count - 1)
        defer { c.model.switchTo(home) }
        XCTAssertTrue(c.model.layout.isEmpty)
        let gap = c.themeManager.paneGap   // The test host reads the real config: assume no value (the default of 5 is ConfigStoreTests' job)
        XCTAssertGreaterThan(gap, 0)
        func spawn() throws -> PaneView {
            let before = Set(c.paneList.map(ObjectIdentifier.init))
            c.perform(.newTerminal)
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            return try XCTUnwrap(c.paneList.first { !before.contains(ObjectIdentifier($0)) })
        }
        func rect(_ v: PaneView) -> NSRect { v.convert(v.bounds, to: nil) }

        // dwindle: A | B
        c.model.layout = .dwindle(SplitTree())
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let a = try spawn(), b = try spawn()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        let ra = rect(a), rb = rect(b)
        XCTAssertEqual(rb.minX - ra.maxX, 2 * gap, accuracy: 0.6, "dwindle neighbour spacing A=\(ra) B=\(rb)")
        XCTAssertEqual(ra.minX, 2 * gap, accuracy: 0.6, "the dwindle's left edge is the outer ring plus the gap")
        for p in [a, b] { c.closePane(p, confirmIfNeeded: false, animated: false) }

        // scrolling: two columns, centered without overflow, with the same neighbour spacing.
        c.model.layout = .empty
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let x = try spawn(), y = try spawn()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        let rx = rect(x), ry = rect(y)
        let (left, right) = rx.minX < ry.minX ? (rx, ry) : (ry, rx)
        XCTAssertEqual(right.minX - left.maxX, 2 * gap, accuracy: 0.6, "scrolling neighbour spacing \(left) \(right)")
        for p in [x, y] { c.closePane(p, confirmIfNeeded: false, animated: false) }
        c.model.layout = .empty
    }

    /// The file-manager action: a new pane starts the configured program and takes focus (vim stands in for
    /// yazi: it takes a directory argument and stays running).
    @MainActor
    func testFileManagerActionOpensFocusedPane() throws {
        let c = try controller
        let home = c.model.activeIndex
        c.model.switchTo(c.model.layouts.count - 1)
        defer { c.model.switchTo(home) }
        XCTAssertTrue(c.model.layout.isEmpty)
        let prevCmd = c.fileManagerCommand
        defer { c.fileManagerCommand = prevCmd }
        c.fileManagerCommand = "/usr/bin/vim"
        c.perform(.fileManager)
        XCTAssertEqual(c.paneList.count, 1)
        let pane = try XCTUnwrap(c.paneList.first)
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        XCTAssertTrue(c.window?.firstResponder === pane, "the file-manager pane takes focus")
        XCTAssertTrue(c.paneList.contains(pane), "the program stays running, so the pane must not close itself")
        c.closePane(pane, confirmIfNeeded: true, animated: false)   // A file-manager pane raises no confirmation and closes right away
        XCTAssertTrue(c.paneList.isEmpty, "closing must not be blocked by a process confirmation")
    }

    /// A missing program still opens the pane, showing an install hint and dropping into a login shell, rather
    /// than failing silently.
    @MainActor
    func testFileManagerMissingProgramOpensHintPane() throws {
        let c = try controller
        let home = c.model.activeIndex
        c.model.switchTo(c.model.layouts.count - 1)
        defer { c.model.switchTo(home) }
        let prevCmd = c.fileManagerCommand
        defer { c.fileManagerCommand = prevCmd }
        c.fileManagerCommand = "quickterm-no-such-file-manager-xyz"
        c.perform(.fileManager)
        XCTAssertEqual(c.paneList.count, 1)
        RunLoop.main.run(until: Date().addingTimeInterval(1.2))
        XCTAssertEqual(c.paneList.count, 1, "the hint pane stays open; it execs an interactive login shell")
        for p in c.paneList { c.closePane(p, confirmIfNeeded: false, animated: false) }
    }

    /// The file manager exits with a changed directory: a terminal opens in its place and this pane closes (the
    /// new pane takes over and takes focus), and the temporary cwd file is cleaned up.
    @MainActor
    func testFileManagerExitOpensTerminalAtChangedDirectory() throws {
        let c = try controller
        let home = c.model.activeIndex
        c.model.switchTo(c.model.layouts.count - 1)
        defer { c.model.switchTo(home) }
        let prevCmd = c.fileManagerCommand
        defer { c.fileManagerCommand = prevCmd }
        c.fileManagerCommand = "/usr/bin/vim"
        c.perform(.fileManager)
        let fm = try XCTUnwrap(c.paneList.first)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let cwdFile = NSTemporaryDirectory() + "quickterm-test-cwd-" + UUID().uuidString
        try "/usr\n".write(toFile: cwdFile, atomically: true, encoding: .utf8)
        c.registerFileManagerSession(fm, .init(startDirectory: "/tmp", cwdFile: cwdFile))
        NotificationCenter.default.post(name: Ghostty.Notification.ghosttyCloseSurface, object: fm,
                                        userInfo: ["process_alive": true])
        RunLoop.main.run(until: Date().addingTimeInterval(0.7))   // Wait out the close animation
        XCTAssertEqual(c.paneList.count, 1, "the old pane closed and a new terminal took its place")
        let replacement = try XCTUnwrap(c.paneList.first)
        XCTAssertFalse(replacement === fm)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cwdFile), "the temporary cwd file was cleaned up")
        XCTAssertTrue(c.window?.firstResponder === replacement, "focus is on the new terminal")
        c.closePane(replacement, confirmIfNeeded: false, animated: false)
    }

    /// An executable fake file-manager script that ignores its arguments; body is the script's contents.
    private func fakeFileManager(_ body: String) throws -> (dir: String, path: String) {
        let dir = NSTemporaryDirectory() + "quickterm-fake-fm-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = dir + "/yazi"
        try ("#!/bin/sh\n" + body + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        return (dir, path)
    }

    /// The real exit path: for a surface started with a command the engine does not close itself, it only sends
    /// SHOW_CHILD_EXITED. When the program exits normally, having run for more than 250ms, the pane has to
    /// close on its own rather than showing "Process exited. Press any key".
    @MainActor
    func testFileManagerProcessExitAutoClosesPane() throws {
        let c = try controller
        let home = c.model.activeIndex
        c.model.switchTo(c.model.layouts.count - 1)
        defer { c.model.switchTo(home) }
        let prevCmd = c.fileManagerCommand
        defer { c.fileManagerCommand = prevCmd }
        let fake = try fakeFileManager("sleep 0.5")   // Runs normally, exits, writes no cwd file
        defer { try? FileManager.default.removeItem(atPath: fake.dir) }
        c.fileManagerCommand = fake.path
        c.perform(.fileManager)
        XCTAssertEqual(c.paneList.count, 1)
        RunLoop.main.run(until: Date().addingTimeInterval(2.5))
        XCTAssertTrue(c.paneList.isEmpty, "the pane closes itself once the child process exits")
    }

    /// Failing at launch, exiting within 250ms (a broken yazi config, say): the engine's diagnostics are not
    /// suppressed and the pane stays, waiting for a key.
    @MainActor
    func testFileManagerAbnormalFastExitKeepsPaneForDiagnostics() throws {
        let c = try controller
        let home = c.model.activeIndex
        c.model.switchTo(c.model.layouts.count - 1)
        defer { c.model.switchTo(home) }
        let prevCmd = c.fileManagerCommand
        defer { c.fileManagerCommand = prevCmd }
        c.fileManagerCommand = "/usr/bin/false"
        c.perform(.fileManager)
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        XCTAssertEqual(c.paneList.count, 1, "a pane that exited abnormally stays (the engine shows failed to launch)")
        for p in c.paneList { c.closePane(p, confirmIfNeeded: false, animated: false) }
    }

    /// The real cd-here path: the fake yazi writes a different directory into --cwd-file and exits, so a
    /// terminal opens in its place and takes focus
    /// (in scrolling there is already a pane A to its left, and focus has to land on the new terminal, not on A).
    @MainActor
    func testFileManagerRealExitOpensTerminalAtWrittenDirectoryAndFocusesIt() throws {
        let c = try controller
        let home = c.model.activeIndex
        c.model.switchTo(c.model.layouts.count - 1)
        defer { c.model.switchTo(home) }
        let prevCmd = c.fileManagerCommand
        defer { c.fileManagerCommand = prevCmd }
        // The fake yazi: run for a moment, write /usr into the path from --cwd-file=<path>, then exit.
        let fake = try fakeFileManager("sleep 0.4\nprintf '/usr\\n' > \"${1#--cwd-file=}\"")
        defer { try? FileManager.default.removeItem(atPath: fake.dir) }
        c.fileManagerCommand = fake.path
        c.perform(.newTerminal)                  // Pane A already exists on the left
        let a = try XCTUnwrap(c.paneList.first)
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        c.perform(.fileManager)
        let fm = try XCTUnwrap(c.paneList.first { $0 !== a })
        RunLoop.main.run(until: Date().addingTimeInterval(3.0))
        XCTAssertEqual(c.paneList.count, 2, "the file-manager pane closed and a new terminal took its place")
        XCTAssertFalse(c.paneList.contains(fm))
        let replacement = try XCTUnwrap(c.paneList.first { $0 !== a })
        XCTAssertTrue(c.window?.firstResponder === replacement, "focus is on the new terminal, not on its left neighbour A")
        XCTAssertEqual(replacement.workingDirectory, "/usr", "the new terminal's directory is the one yazi wrote")
        for p in c.paneList { c.closePane(p, confirmIfNeeded: false, animated: false) }
    }

    /// Exiting with the directory unchanged (or quitting with Q, which writes no file): only the pane closes.
    @MainActor
    func testFileManagerExitWithoutDirectoryChangeJustCloses() throws {
        let c = try controller
        let home = c.model.activeIndex
        c.model.switchTo(c.model.layouts.count - 1)
        defer { c.model.switchTo(home) }
        let prevCmd = c.fileManagerCommand
        defer { c.fileManagerCommand = prevCmd }
        c.fileManagerCommand = "/usr/bin/vim"
        c.perform(.fileManager)
        let fm = try XCTUnwrap(c.paneList.first)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let cwdFile = NSTemporaryDirectory() + "quickterm-test-cwd-" + UUID().uuidString
        try "/tmp\n".write(toFile: cwdFile, atomically: true, encoding: .utf8)
        c.registerFileManagerSession(fm, .init(startDirectory: "/tmp", cwdFile: cwdFile))
        NotificationCenter.default.post(name: Ghostty.Notification.ghosttyCloseSurface, object: fm,
                                        userInfo: ["process_alive": false])
        RunLoop.main.run(until: Date().addingTimeInterval(0.7))
        XCTAssertTrue(c.paneList.isEmpty, "directory unchanged: only the pane closes")
        XCTAssertFalse(FileManager.default.fileExists(atPath: cwdFile))
    }

    /// With three visible columns: create, merge with Cmd+J and split back out, then create again, and every
    /// column's width factor still equals the current factor (the screenshot bug: the column split back out
    /// came back as 0.485).
    @MainActor
    func testScrollingColumnsStayEqualAfterMergeSplitWithThreeVisible() throws {
        let c = try controller
        let home = c.model.activeIndex
        c.model.switchTo(c.model.layouts.count - 1)
        defer { c.model.switchTo(home) }
        XCTAssertTrue(c.model.layout.isEmpty)
        let prevVisible = c.visibleColumns
        c.setVisibleColumns(3, persist: false)
        defer { c.setVisibleColumns(prevVisible, persist: false) }
        let f = c.columnFactor
        XCTAssertEqual(f, ScrollingStrip.factor(forVisibleColumns: 3), accuracy: 1e-9)
        var created: [PaneView] = []
        defer { for p in created { c.closePane(p, confirmIfNeeded: false, animated: false) } }
        func spawn() throws -> PaneView {
            let before = Set(c.paneList.map(ObjectIdentifier.init))
            c.perform(.newTerminal)
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            let p = try XCTUnwrap(c.paneList.first { !before.contains(ObjectIdentifier($0)) })
            created.append(p)
            return p
        }
        func factors() -> [Double] {
            if case .scrolling(let strip) = c.model.layout { return strip.columns.map(\.widthFactor) }
            return []
        }
        _ = try spawn()
        let b = try spawn()
        XCTAssertEqual(factors(), [f, f])
        _ = c.window?.makeFirstResponder(b)
        c.perform(.toggleSplitDirection)   // b merges into the left column
        XCTAssertEqual(factors(), [f])
        c.perform(.toggleSplitDirection)   // b splits back out
        XCTAssertEqual(factors(), [f, f], "a column split back out must not take the two-column default width")
        _ = try spawn()
        XCTAssertEqual(factors(), [f, f, f])
    }

    /// Strip geometry: a pane view's width equals the model's column width − 2×pane-gap, and the whole column
    /// lands inside the viewport.
    @MainActor
    private func assertFillsColumnInsideViewport(
        _ c: MainWindowController, _ pane: PaneView, _ label: String,
        file: StaticString = #filePath, line: UInt = #line) throws {
        // A pane's inner padding and the outer ring share one value, and both follow the gaps switch
        // (PaneChrome / RootView).
        let gap = c.themeManager.gapsEnabled ? c.themeManager.paneGap : 0
        let outer = gap
        let content = try XCTUnwrap(c.window?.contentView, "the window's content view", file: file, line: line)
        let viewport = content.bounds.width - 2 * outer   // Strip viewport = content width − the outer ring
        guard case .scrolling(let strip) = c.model.layout else {
            return XCTFail("the layout should be scrolling", file: file, line: line)
        }
        let pos = try XCTUnwrap(strip.position(of: pane), "\(label) is not in the strip", file: file, line: line)
        let widths = strip.columnWidths(viewport: viewport, gap: 0)
        let rect = pane.convert(pane.bounds, to: nil)     // Window coordinates
        XCTAssertEqual(rect.width, widths[pos.col] - 2 * gap, accuracy: 1.0,
                       "\(label)'s width should be the column width \(widths[pos.col]) − 2×gap, actual \(rect)",
                       file: file, line: line)
        XCTAssertGreaterThanOrEqual(rect.minX, outer - 1.0,
                                    "\(label) is clipped by the viewport's left edge: \(rect)", file: file, line: line)
        XCTAssertLessThanOrEqual(rect.maxX, outer + viewport + 1.0,
                                 "\(label) is clipped by the viewport's right edge: \(rect)", file: file, line: line)
    }

    /// Regression from the user report "new browser, wrong width": the new browser pane was lit with the focus
    /// border and clipped by the right edge of the window. A pane created in scrolling, browser and terminal
    /// alike, has to
    /// (1) have a view width equal to the model's column width − 2×pane-gap (an NSViewRepresentable must not
    ///     be stretched open by its own fittingSize), and
    /// (2) sit in a column that lands entirely inside the viewport (the strip scrolls the new column in).
    /// Narrow columns are covered as well: a browser pane's fittingSize (the toolbar plus the 200pt minimum
    /// address field) is far wider than the column, and it still must not spill out of it.
    @MainActor
    func testNewPaneInScrollingFillsColumnAndIsRevealed() throws {
        let c = try controller
        let home = c.model.activeIndex
        c.model.switchTo(c.model.layouts.count - 1)
        XCTAssertTrue(c.model.layout.isEmpty)
        c.model.layout = .empty   // An earlier case may have left this workspace as an (empty) dwindle
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let prevVisible = c.visibleColumns
        let prevSettings = BrowserPaneView.settings
        BrowserPaneView.settings.home = "about:blank"   // No network
        c.setVisibleColumns(3, persist: false)
        var created: [PaneView] = []
        defer {
            for p in created { c.closePane(p, confirmIfNeeded: false, animated: false) }
            c.setVisibleColumns(prevVisible, persist: false)
            BrowserPaneView.settings = prevSettings
            c.model.switchTo(home)
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        }
        func spawn(_ action: WMAction) throws -> PaneView {
            let before = Set(c.paneList.map(ObjectIdentifier.init))
            c.perform(action)
            // 0.15s reveal animation, 0.2s pop-in, plus focus landing (a browser goes through WKWebView and is slower).
            RunLoop.main.run(until: Date().addingTimeInterval(0.8))
            let p = try XCTUnwrap(c.paneList.first { !before.contains(ObjectIdentifier($0)) })
            created.append(p)
            return p
        }

        // Three visible columns: from the fourth on it overflows, and a new column is only revealed by scrolling.
        for _ in 0..<3 { _ = try spawn(.newTerminal) }
        let browser = try spawn(.newBrowser)
        XCTAssertTrue(browser is BrowserPaneView, "Cmd+B has to create a browser pane")
        try assertFillsColumnInsideViewport(c, browser, "new browser")
        let terminal = try spawn(.newTerminal)   // Control: a new terminal in the same position
        try assertFillsColumnInsideViewport(c, terminal, "new terminal (control)")

        // Narrow columns: 5 panes spread over "6 visible columns" (fill mode, all visible), with column widths
        // far below the browser's fittingSize.
        c.setVisibleColumns(6, persist: false)
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        XCTAssertLessThan(browser.frame.width, browser.fittingSize.width,
                          "for the narrow-column assertion to mean anything, the column has to be narrower than the browser pane's fittingSize")
        for (i, p) in c.paneList.enumerated() {
            try assertFillsColumnInsideViewport(c, p, "narrow-column pane #\(i)")
        }
    }

    /// Regression: a column newly inserted into the strip has to be **revealed**, no matter when focus lands
    /// on the new pane. Focus is asynchronous (PaneView.moveFocus waits for mounting; a browser pane's first
    /// responder is its inner WKWebView, a beat later still, and hover focus or a remount can steal it), so
    /// aligning on focus alone leaves the new column parked outside the right edge of the viewport.
    /// This case deliberately withholds focus from the new pane: the strip still has to scroll it in by identity.
    @MainActor
    func testInsertedColumnIsRevealedWithoutFocusLanding() throws {
        let c = try controller
        let home = c.model.activeIndex
        c.model.switchTo(c.model.layouts.count - 1)
        XCTAssertTrue(c.model.layout.isEmpty)
        c.model.layout = .empty   // An earlier case may have left this workspace as an (empty) dwindle
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let prevVisible = c.visibleColumns
        c.setVisibleColumns(3, persist: false)
        var created: [PaneView] = []
        defer {
            for p in created { c.closePane(p, confirmIfNeeded: false, animated: false) }
            c.setVisibleColumns(prevVisible, persist: false)
            c.model.switchTo(home)
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        }
        for _ in 0..<3 {
            let before = Set(c.paneList.map(ObjectIdentifier.init))
            c.perform(.newTerminal)
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            created.append(try XCTUnwrap(c.paneList.first { !before.contains(ObjectIdentifier($0)) }))
        }
        let window = try XCTUnwrap(c.window)
        let anchor = try XCTUnwrap(c.focusedPane)
        guard case .scrolling(let strip) = c.model.layout else { return XCTFail("the layout should be scrolling") }
        let pane = BrowserPaneView(url: URL(string: "about:blank"))
        created.append(pane)
        // Change only the layout, never request focus (simulating focus arriving late or being stolen).
        c.model.layout = .scrolling(strip.insertingColumnRight(
            of: anchor, pane: pane, widthFactor: c.columnFactor))
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        XCTAssertFalse(pane.holdsFirstResponder(of: window), "precondition for this case: focus did not land on the new pane")
        try assertFillsColumnInsideViewport(c, pane, "a browser column inserted without focus")
    }

    /// Regression: **inserting a column while zoomed** (Cmd+B, or a Cmd+clicked link, after Cmd+F) has to be
    /// revealed by identity too. A structural operation clears the zoom on its way through
    /// (insertingColumnRight), so "leave zoom" and "insert a column" land in the same SwiftUI update and the
    /// strip's HStack is rebuilt whole: with the reveal logic inside the zoom branch, the rebuild only runs
    /// onAppear (which counts the freshly inserted pane as one it has already seen),
    /// and onChange does not fire for a view that was just created, so nothing scrolls the new column in.
    @MainActor
    func testInsertedColumnIsRevealedAfterZoomWithoutFocusLanding() throws {
        let c = try controller
        let home = c.model.activeIndex
        c.model.switchTo(c.model.layouts.count - 1)
        XCTAssertTrue(c.model.layout.isEmpty)
        c.model.layout = .empty   // An earlier case may have left this workspace as an (empty) dwindle
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let prevVisible = c.visibleColumns
        c.setVisibleColumns(3, persist: false)
        var created: [PaneView] = []
        defer {
            for p in created { c.closePane(p, confirmIfNeeded: false, animated: false) }
            c.setVisibleColumns(prevVisible, persist: false)
            c.model.switchTo(home)
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        }
        for _ in 0..<3 {
            let before = Set(c.paneList.map(ObjectIdentifier.init))
            c.perform(.newTerminal)
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            created.append(try XCTUnwrap(c.paneList.first { !before.contains(ObjectIdentifier($0)) }))
        }
        let window = try XCTUnwrap(c.window)
        let anchor = try XCTUnwrap(c.focusedPane)
        c.perform(.toggleZoom)   // Cmd+F: only the focused pane stays mounted, the strip's HStack is torn down
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        guard case .scrolling(let strip) = c.model.layout else { return XCTFail("the layout should be scrolling") }
        XCTAssertNotNil(strip.zoomedID, "precondition for this case: the strip is zoomed")
        let pane = BrowserPaneView(url: URL(string: "about:blank"))
        created.append(pane)
        // Change only the layout (clearing the zoom along the way), never request focus (simulating focus
        // arriving late or being stolen by hover).
        c.model.layout = .scrolling(strip.insertingColumnRight(
            of: anchor, pane: pane, widthFactor: c.columnFactor))
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        guard case .scrolling(let after) = c.model.layout else { return XCTFail("the layout should be scrolling") }
        XCTAssertNil(after.zoomedID, "inserting a column clears the zoom")
        XCTAssertFalse(pane.holdsFirstResponder(of: window), "precondition for this case: focus did not land on the new pane")
        try assertFillsColumnInsideViewport(c, pane, "a browser column inserted while zoomed")
    }

    /// Regression: resizing event by event (Cmd plus a right-drag) while the strip sits at its right end must
    /// not fling the viewport past the content. A change in column width has to trigger the clamp
    /// (layoutSignature deliberately leaves widthFactor out, so nothing else re-lays it out), and the last
    /// column stays flush with the viewport's right edge.
    /// Note: this **cannot** test whether the clamp is animated. During a SwiftUI animation an NSView's frame
    /// is already at its final value, and the smearing a per-event animation causes is only visible on screen
    /// (hard-coding animated to true was measured to leave this case green).
    /// The reason it is not animated is in ScrollingStripView.clampOffset.
    @MainActor
    func testResizeDragKeepsStripClampedAtRightEnd() throws {
        let c = try controller
        let home = c.model.activeIndex
        c.model.switchTo(c.model.layouts.count - 1)
        XCTAssertTrue(c.model.layout.isEmpty)
        c.model.layout = .empty
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let prevVisible = c.visibleColumns
        c.setVisibleColumns(3, persist: false)
        var created: [PaneView] = []
        defer {
            for p in created { c.closePane(p, confirmIfNeeded: false, animated: false) }
            c.setVisibleColumns(prevVisible, persist: false)
            c.model.switchTo(home)
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        }
        for _ in 0..<4 {   // 3 visible columns, so 4 overflow; once the last is revealed the strip sits at its right end
            let before = Set(c.paneList.map(ObjectIdentifier.init))
            c.perform(.newTerminal)
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            created.append(try XCTUnwrap(c.paneList.first { !before.contains(ObjectIdentifier($0)) }))
        }
        let last = try XCTUnwrap(created.last)
        try assertFillsColumnInsideViewport(c, last, "last column (before the resize)")
        let content = try XCTUnwrap(c.window?.contentView)
        let gap = c.themeManager.gapsEnabled ? c.themeManager.paneGap : 0
        let viewport = content.bounds.width - 2 * gap
        let rightEdge = gap + viewport
        XCTAssertEqual(last.convert(last.bounds, to: nil).maxX + gap, rightEdge,
                       accuracy: 1.5, "precondition: the last column is flush with the viewport's right edge")
        // Simulate a run of narrowing drag events (resizeByDrag writes widthFactor once per event).
        for _ in 0..<5 {
            guard case .scrolling(let strip) = c.model.layout else { return XCTFail("the layout should be scrolling") }
            c.model.layout = .scrolling(strip.resizingWidth(of: last, delta: -0.05))
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        // Wait for one layout commit, far shorter than the 0.15s animation: the clamp is already in place.
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        try assertFillsColumnInsideViewport(c, last, "last column (after the per-event resize)")
        XCTAssertEqual(last.convert(last.bounds, to: nil).maxX + gap, rightEdge,
                       accuracy: 1.5, "after narrowing, the last column is still flush right: the viewport clamps on every event, leaving no gap")
    }

    /// A Cmd+clicked link in a terminal: with no browser pane one is created; with one, a new tab opens in the
    /// most recently activated pane; with several, in the most recently focused. Anything that is not http(s),
    /// and link-opener = system, are not taken over.
    @MainActor
    func testTerminalLinkOpensInMostRecentBrowserPane() throws {
        let c = try controller
        let home = c.model.activeIndex
        c.model.switchTo(c.model.layouts.count - 1)
        defer { c.model.switchTo(home) }
        XCTAssertTrue(c.model.layout.isEmpty)
        let prevSettings = BrowserPaneView.settings
        defer { BrowserPaneView.settings = prevSettings }
        BrowserPaneView.settings.home = "about:blank"
        let prevOpener = c.linkOpener
        defer { c.linkOpener = prevOpener }
        c.linkOpener = "browser-pane"
        c.perform(.newTerminal)
        let term = try XCTUnwrap(c.paneList.first)
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        let link1 = URL(string: "http://127.0.0.1:9/one")!
        XCTAssertTrue(c.openLink(link1, from: term), "the http link is taken over")
        let b1 = try XCTUnwrap(c.paneList.first { $0 is BrowserPaneView } as? BrowserPaneView, "with no browser pane, one is created")
        XCTAssertEqual(b1.tabs.count, 1)
        XCTAssertEqual(b1.activeTab?.lastRequestedURL, link1)
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        let link2 = URL(string: "http://127.0.0.1:9/two")!
        XCTAssertTrue(c.openLink(link2, from: term))
        XCTAssertEqual(c.paneList.filter { $0 is BrowserPaneView }.count, 1, "with a browser pane already there, none is created")
        XCTAssertEqual(b1.tabs.count, 2, "a new tab opens in the existing pane")
        XCTAssertEqual(b1.activeTab?.lastRequestedURL, link2, "the new tab becomes active")
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        c.perform(.newBrowser)
        let b2 = try XCTUnwrap(c.paneList.first { $0 is BrowserPaneView && $0 !== b1 } as? BrowserPaneView)
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        XCTAssertTrue(c.mostRecentBrowserPane() === b2, "the browser pane just created and focused is the most recent")
        c.requestFocus(to: b1)
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        XCTAssertTrue(c.mostRecentBrowserPane() === b1, "refocusing b1 makes it the most recent")
        let link3 = URL(string: "http://127.0.0.1:9/three")!
        XCTAssertTrue(c.openLink(link3, from: term))
        XCTAssertEqual(b1.tabs.count, 3, "with several browser panes, the most recently activated one is used")
        XCTAssertEqual(b2.tabs.count, 1)
        XCTAssertFalse(c.openLink(URL(string: "mailto:a@b.c")!, from: term), "anything that is not http(s) goes to the system")
        c.linkOpener = "system"
        XCTAssertFalse(c.openLink(link1, from: term), "system mode does not take over")
        XCTAssertEqual(b1.tabs.count, 3)
        for p in c.paneList { c.closePane(p, confirmIfNeeded: false, animated: false) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    }

    private func mouse(_ type: NSEvent.EventType, at p: NSPoint, in window: NSWindow, flags: NSEvent.ModifierFlags = .command) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: p, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    /// While Cmd is held, a drag-source overlay covers the tiled pane: a plain click, one that never passes the
    /// drag threshold, has to be forwarded to the surface whole (the engine sees PRESS + RELEASE, which is
    /// what makes a Cmd+clicked link fire open_url). A small jitter is not a drag.
    @MainActor
    func testCommandClickPassesThroughDragSourceOverlay() throws {
        let c = try controller
        let home = c.model.activeIndex
        c.model.switchTo(c.model.layouts.count - 1)
        defer { c.model.switchTo(home) }
        XCTAssertTrue(c.model.layout.isEmpty)
        c.perform(.newTerminal)
        let pane = try XCTUnwrap(c.paneList.first as? Ghostty.SurfaceView)
        defer { c.closePane(pane, confirmIfNeeded: false, animated: false) }
        let window = try XCTUnwrap(c.window)
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        ModifierState.shared.commandHeld = true
        defer { ModifierState.shared.commandHeld = false }
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        // Match the class name exactly: SwiftUI's host view class name also contains "SurfaceDragSourceViewRepresentable".
        func findOverlay(_ v: NSView) -> NSView? {
            if String(describing: type(of: v)) == "SurfaceDragSourceView" { return v }
            for sub in v.subviews { if let hit = findOverlay(sub) { return hit } }
            return nil
        }
        let overlay = try XCTUnwrap(window.contentView.flatMap(findOverlay), "the drag-source overlay is mounted while ⌘ is held")
        let center = pane.convert(NSPoint(x: pane.bounds.midX, y: pane.bounds.midY), to: nil)
        let press0 = pane.leftPressCountForTesting, release0 = pane.leftReleaseCountForTesting
        overlay.mouseDown(with: mouse(.leftMouseDown, at: center, in: window))
        overlay.mouseDragged(with: mouse(.leftMouseDragged, at: NSPoint(x: center.x + 1, y: center.y + 1), in: window))   // Jitter below the threshold
        XCTAssertEqual(pane.leftPressCountForTesting, press0, "nothing is forwarded on the press (a drag would leave no release)")
        overlay.mouseUp(with: mouse(.leftMouseUp, at: center, in: window))
        XCTAssertEqual(pane.leftPressCountForTesting, press0 + 1, "the PRESS is sent on mouse-up")
        XCTAssertEqual(pane.leftReleaseCountForTesting, release0 + 1, "followed by the RELEASE")
        overlay.mouseUp(with: mouse(.leftMouseUp, at: center, in: window))
        XCTAssertEqual(pane.leftReleaseCountForTesting, release0 + 1, "a mouse-up with no matching press is not forwarded")
    }

    /// The Cmd drag-source overlay covers the whole pane, but it is a **sibling** subtree of it: without
    /// forwarding, the wheel follows the overlay's own responder chain into the SwiftUI container and the
    /// terminal or page never sees it. That is the user report "the grab cursor will not go away, and the
    /// terminal stopped scrolling".
    @MainActor
    func testDragSourceOverlayForwardsScrollToSurface() throws {
        let c = try controller
        let home = c.model.activeIndex
        c.model.switchTo(c.model.layouts.count - 1)
        defer { c.model.switchTo(home) }
        XCTAssertTrue(c.model.layout.isEmpty)
        c.perform(.newTerminal)
        let pane = try XCTUnwrap(c.paneList.first as? Ghostty.SurfaceView)
        defer { c.closePane(pane, confirmIfNeeded: false, animated: false) }
        let window = try XCTUnwrap(c.window)
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        ModifierState.shared.commandHeld = true
        defer { ModifierState.shared.sync(.init()) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        func findOverlay(_ v: NSView) -> NSView? {
            if String(describing: type(of: v)) == "SurfaceDragSourceView" { return v }
            for sub in v.subviews { if let hit = findOverlay(sub) { return hit } }
            return nil
        }
        let overlay = try XCTUnwrap(window.contentView.flatMap(findOverlay), "the drag-source overlay is mounted while ⌘ is held")
        let center = pane.convert(NSPoint(x: pane.bounds.midX, y: pane.bounds.midY), to: nil)
        let event = try scrollEvent(at: center, in: window)
        XCTAssertEqual(event.locationInWindow.x, center.x, accuracy: 1, "the synthesized wheel event lands in the center of the pane")
        XCTAssertEqual(event.locationInWindow.y, center.y, accuracy: 1)
        let before = pane.scrollCountForTesting
        overlay.scrollWheel(with: event)
        XCTAssertEqual(pane.scrollCountForTesting, before + 1, "the overlay forwards the wheel to the surface instead of swallowing it")
        // The moment Cmd is released the overlay has to go, and the grab cursor with it, even when the key-up
        // lands in another app and only sync heals it.
        ModifierState.shared.sync(.init())
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        XCTAssertNil(window.contentView.flatMap(findOverlay), "the overlay has to be removed once ⌘ is released")
    }

    /// `commandHeld` has exactly one writer, the local monitor, and it never sees a Cmd key-up that lands in
    /// another app (Cmd+Tab, Cmd+Space, a screenshot, Cmd+H):
    /// it has to heal itself, or the overlay stays mounted forever.
    @MainActor
    func testModifierStateSelfHealsOnDeactivationAndSync() throws {
        let previous = ModifierState.shared.commandHeld
        defer { ModifierState.shared.commandHeld = previous }
        ModifierState.shared.commandHeld = true
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertFalse(ModifierState.shared.commandHeld,
                       "deactivating the app clears it unconditionally (the ⌘ key-up lands in another app)")
        ModifierState.shared.sync(.command)
        XCTAssertTrue(ModifierState.shared.commandHeld, "rebuilt from the modifiers the event itself carries")
        ModifierState.shared.sync([.shift, .option])
        XCTAssertFalse(ModifierState.shared.commandHeld, "any mouse or wheel event makes up for a key-up that was missed")
    }

    /// A terminal pane briefly leaves its window (window == nil) while SwiftUI rebuilds the hierarchy. If the
    /// engine's open_url callback cannot resolve a controller at that moment, a Cmd+clicked http link is thrown
    /// at the system default browser: the user report
    /// "sometimes it opens the system browser instead of the pane browser".
    @MainActor
    func testDetachedPaneKeepsControllerSoLinksNeverLeakToSystem() throws {
        let c = try controller
        let home = c.model.activeIndex
        c.model.switchTo(c.model.layouts.count - 1)
        defer { c.model.switchTo(home) }
        XCTAssertTrue(c.model.layout.isEmpty)
        let prevSettings = BrowserPaneView.settings
        defer { BrowserPaneView.settings = prevSettings }
        BrowserPaneView.settings.home = "about:blank"
        let prevOpener = c.linkOpener
        defer { c.linkOpener = prevOpener }
        c.linkOpener = "browser-pane"
        var systemOpened: [URL] = []
        let prevSystemOpener = Ghostty.App.systemOpener
        defer { Ghostty.App.systemOpener = prevSystemOpener }
        Ghostty.App.systemOpener = { systemOpened.append($0) }

        // Mount a pane in the window and take it back out: exactly the state during a hierarchy rebuild, with
        // a superview but no window.
        let content = try XCTUnwrap(c.window?.contentView)
        let orphan = PaneView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        content.addSubview(orphan)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertTrue(orphan.controller === c, "mounted in the window, it resolves to that window's controller")
        orphan.removeFromSuperview()
        XCTAssertNil(orphan.window, "precondition: it is off the window")
        XCTAssertTrue(orphan.controller === c, "detached, it still knows the controller it last had")

        let link = URL(string: "http://127.0.0.1:9/detached")!
        XCTAssertTrue(Ghostty.App.routeLink(link, from: orphan), "a detached pane's link is taken over too")
        XCTAssertTrue(systemOpened.isEmpty, "an http link must never leak to the system default browser")
        let browser = try XCTUnwrap(c.paneList.first { $0 is BrowserPaneView } as? BrowserPaneView)
        XCTAssertEqual(browser.activeTab?.lastRequestedURL, link, "it lands in QuickTerm's own browser pane")
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))

        // With no source pane at all, when the target does not resolve to a surface, it falls back to the key
        // window or any terminal window, and still does not leak.
        let link2 = URL(string: "http://127.0.0.1:9/nosurface")!
        XCTAssertTrue(Ghostty.App.routeLink(link2, from: nil))
        XCTAssertTrue(systemOpened.isEmpty)
        // Non-http(s) and link-opener = system still go to the system (not taken over, so the engine calls systemOpener).
        XCTAssertFalse(Ghostty.App.routeLink(URL(string: "mailto:a@b.c")!, from: orphan), "non-http(s) is not taken over")
        c.linkOpener = "system"
        XCTAssertFalse(Ghostty.App.routeLink(link, from: orphan), "system mode does not take over")
        c.linkOpener = "browser-pane"
        for p in c.paneList { c.closePane(p, confirmIfNeeded: false, animated: false) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    }

    /// Synthesize a real scroll-wheel event (NSEvent.mouseEvent cannot produce a .scrollWheel).
    /// In an event whose windowNumber is 0, `locationInWindow` is the screen coordinate: measure the
    /// difference once and compensate,
    /// rather than depending on a particular arrangement of displays.
    private func scrollEvent(at windowPoint: NSPoint, in window: NSWindow) throws -> NSEvent {
        func make(_ location: CGPoint) throws -> NSEvent {
            let cg = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                                           wheelCount: 2, wheel1: -6, wheel2: 0, wheel3: 0))
            cg.location = location
            return try XCTUnwrap(NSEvent(cgEvent: cg))
        }
        let screenPoint = window.convertPoint(toScreen: windowPoint)
        var location = CGPoint(x: screenPoint.x,
                               y: (NSScreen.screens.first?.frame.maxY ?? 0) - screenPoint.y)
        let probe = try make(location)
        location = CGPoint(x: location.x + (windowPoint.x - probe.locationInWindow.x),
                           y: location.y - (windowPoint.y - probe.locationInWindow.y))
        return try make(location)
    }

    /// The Cmd session on a floating pane: a mouse-up before the drag threshold is a plain click and goes to
    /// the pane itself; past the threshold the pane moves and no click is delivered.
    @MainActor
    func testCommandClickOnFloatingPaneReachesSurface() throws {
        let c = try controller
        let home = c.model.activeIndex
        c.model.switchTo(c.model.layouts.count - 1)
        defer { c.model.switchTo(home) }
        XCTAssertTrue(c.model.layout.isEmpty)
        c.perform(.newTerminal)
        let pane = try XCTUnwrap(c.paneList.first as? Ghostty.SurfaceView)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        c.toggleFloat(pane)
        defer { c.closePane(pane, confirmIfNeeded: false, animated: false) }
        let window = try XCTUnwrap(c.window)
        let content = try XCTUnwrap(window.contentView)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        let fp = try XCTUnwrap(c.model.floating.first)
        let barH: CGFloat = c.model.barVisible ? StatusBarView.height : 0
        let W = content.bounds.width, H = content.bounds.height - barH
        func windowPoint(_ nx: CGFloat, _ ny: CGFloat) -> NSPoint {
            let local = NSPoint(x: nx * W, y: content.isFlipped ? ny * H + barH : content.bounds.height - (ny * H + barH))
            return content.convert(local, to: nil)
        }
        let center = windowPoint(fp.rect.midX, fp.rect.midY)
        let press0 = pane.leftPressCountForTesting, release0 = pane.leftReleaseCountForTesting
        // A plain click.
        XCTAssertTrue(c.beginFloatingDrag(with: mouse(.leftMouseDown, at: center, in: window)))
        XCTAssertEqual(c.floatingSessionEvent(mouse(.leftMouseDragged, at: NSPoint(x: center.x + 1, y: center.y), in: window)), true)
        XCTAssertEqual(c.floatingSessionEvent(mouse(.leftMouseUp, at: center, in: window)), true)
        XCTAssertEqual(pane.leftPressCountForTesting, press0 + 1, "no drag -> the click goes to the surface")
        XCTAssertEqual(pane.leftReleaseCountForTesting, release0 + 1)
        XCTAssertEqual(c.model.floating.first?.rect.midX ?? 0, fp.rect.midX, accuracy: 0.001, "without a drag it does not move")
        // A real drag: it moves once the threshold is crossed (the displacement from before the threshold is
        // applied in one go rather than lost), and the mouse-up delivers no click.
        let before = try XCTUnwrap(c.model.floating.first).rect
        XCTAssertTrue(c.beginFloatingDrag(with: mouse(.leftMouseDown, at: center, in: window)))
        XCTAssertEqual(c.floatingSessionEvent(mouse(.leftMouseDragged, at: NSPoint(x: center.x + 2, y: center.y), in: window)), true)
        XCTAssertEqual(c.model.floating.first?.rect.midX ?? 0, before.midX, accuracy: 0.0001, "nothing moves inside the threshold")
        XCTAssertEqual(c.floatingSessionEvent(mouse(.leftMouseDragged, at: NSPoint(x: center.x + 40, y: center.y), in: window)), true)
        XCTAssertEqual(((c.model.floating.first?.rect.midX ?? 0) - before.midX) * W, 40, accuracy: 0.5,
                       "the accumulated displacement is applied in full")
        XCTAssertEqual(c.floatingSessionEvent(mouse(.leftMouseUp, at: NSPoint(x: center.x + 40, y: center.y), in: window)), true)
        XCTAssertEqual(pane.leftPressCountForTesting, press0 + 1, "a drag produces no click")
        XCTAssertNil(c.floatingSessionEvent(mouse(.leftMouseUp, at: center, in: window)), "the session is over")
        // The pane leaves the floating layer while the button is held (Cmd+T puts it back in the tiling): the
        // mouse-up forwards nothing and does not crash.
        let center2 = { () -> NSPoint in let r = c.model.floating.first!.rect; return windowPoint(r.midX, r.midY) }()
        XCTAssertTrue(c.beginFloatingDrag(with: mouse(.leftMouseDown, at: center2, in: window)))
        c.toggleFloat(pane)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(c.floatingSessionEvent(mouse(.leftMouseUp, at: center2, in: window)), true)
        XCTAssertEqual(pane.leftPressCountForTesting, press0 + 1, "the pane is no longer floating: the click is not forwarded")
        c.toggleFloat(pane)   // Float it again; the defer closes everything
    }

    /// Reusing a browser pane while another pane is zoomed: the zoom has to be released first, or the tab is
    /// invisible and focus cannot be handed over. A link clicked from the Scratchpad hides the Scratchpad first.
    @MainActor
    func testTerminalLinkUnzoomsAndHidesScratchpad() throws {
        let c = try controller
        let home = c.model.activeIndex
        c.model.switchTo(c.model.layouts.count - 1)
        defer { c.model.switchTo(home) }
        XCTAssertTrue(c.model.layout.isEmpty)
        let prevSettings = BrowserPaneView.settings
        defer { BrowserPaneView.settings = prevSettings }
        BrowserPaneView.settings.home = "about:blank"
        let prevOpener = c.linkOpener
        defer { c.linkOpener = prevOpener }
        c.linkOpener = "browser-pane"
        c.perform(.newTerminal)
        let term = try XCTUnwrap(c.paneList.first)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        c.perform(.newBrowser)
        let browser = try XCTUnwrap(c.paneList.first { $0 is BrowserPaneView } as? BrowserPaneView)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        c.requestFocus(to: term)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        c.perform(.toggleZoom)   // The terminal zooms, which unmounts the browser pane
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        XCTAssertNil(browser.window, "after the zoom the browser pane is not mounted")
        XCTAssertTrue(c.openLink(URL(string: "http://127.0.0.1:9/z")!, from: term))
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        XCTAssertNotNil(browser.window, "reusing it releases the zoom and remounts the browser pane")
        XCTAssertEqual(browser.tabs.count, 2)
        XCTAssertTrue(c.window?.firstResponder === browser.webView, "focus is handed to the browser pane")
        // Click a link inside the Scratchpad.
        c.perform(.scratchpad)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        let scratch = try XCTUnwrap(c.model.scratchpadSurface)
        XCTAssertTrue(c.model.scratchpadVisible)
        XCTAssertTrue(c.openLink(URL(string: "http://127.0.0.1:9/s")!, from: scratch))
        XCTAssertFalse(c.model.scratchpadVisible, "the Scratchpad is hidden first")
        XCTAssertEqual(browser.tabs.count, 3)
        for p in c.paneList { c.closePane(p, confirmIfNeeded: false, animated: false) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    }

    /// Browser panes: Cmd+B creates one and focuses it (the first responder is the inner WKWebView, and the
    /// pane counts as holding focus), it survives a layout switch with its focus, the archive carries
    /// kind=browser, closing raises no confirmation, and focus returns to the terminal.
    @MainActor
    func testBrowserPaneLifecycle() throws {
        let c = try controller
        let home = c.model.activeIndex
        let ws = c.model.layouts.count - 1
        c.model.switchTo(ws)
        defer { c.model.switchTo(home) }
        XCTAssertTrue(c.model.layout.isEmpty)
        let prevSettings = BrowserPaneView.settings
        defer { BrowserPaneView.settings = prevSettings }
        BrowserPaneView.settings.home = "about:blank"   // No network dependency
        c.perform(.newTerminal)
        let a = try XCTUnwrap(c.paneList.first)
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        // Cmd+Shift+K clears the screen: with a terminal focused it is consumed and the engine runs
        // clear_screen (true means the action was valid and has run).
        XCTAssertTrue(MainWindowController.consumes(.clearTerminal, focusedPane: a))
        XCTAssertTrue(c.clearTarget === a, "the clear target is the focused terminal")
        XCTAssertTrue(c.clearFocusedTerminal())
        // While the Scratchpad is open the target has to be the Scratchpad: it is not in paneList, so
        // focusedPane would otherwise fall back to the first tiled pane.
        c.perform(.scratchpad)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        let scratch = try XCTUnwrap(c.model.scratchpadSurface)
        XCTAssertTrue(c.model.scratchpadVisible)
        XCTAssertTrue(c.clearTarget === scratch, "with the Scratchpad focused, the clear target is the Scratchpad")
        XCTAssertFalse(c.clearTarget === a, "the tiled terminal underneath must not be cleared")
        XCTAssertTrue(MainWindowController.consumes(.clearTerminal, focusedPane: c.clearTarget))
        XCTAssertTrue(c.clearFocusedTerminal())
        c.perform(.scratchpad)   // Hide it again
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertFalse(c.model.scratchpadVisible)
        XCTAssertTrue(c.clearTarget === a, "once hidden it goes back to the tiled terminal")
        c.perform(.newBrowser)
        let b = try XCTUnwrap(c.paneList.first { $0 is BrowserPaneView } as? BrowserPaneView)
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        XCTAssertTrue(b.holdsFirstResponder(of: try XCTUnwrap(c.window)),
                      "the first responder should be the WKWebView inside the browser pane")
        XCTAssertTrue(c.focusedPane === b)
        XCTAssertTrue(b.focused)
        XCTAssertFalse(a.focused, "the single-focus invariant")

        // The archive: a leaf with kind=browser plus a url.
        let state = PersistedState(windows: [
            WindowState(layouts: c.model.layouts, floatings: c.model.floatings, activeIndex: ws)
        ])
        let json = String(decoding: try JSONEncoder().encode(state), as: UTF8.self)
        XCTAssertTrue(json.contains("\"kind\":\"browser\""))
        XCTAssertTrue(json.contains("about:blank"))

        // Inserting a new pane rebuilds the neighbours' tracking areas and AppKit synthesizes a mouseMoved:
        // with the mouse resting over the old pane, hover must not steal back the focus just handed to the
        // new one (the controller holds a pending focus intent).
        c.perform(.newBrowser)
        let b2 = try XCTUnwrap(c.paneList.first { $0 is BrowserPaneView && $0 !== b } as? BrowserPaneView)
        a.hoverFocusIfNeeded()                    // Simulate the synthesized mouseMoved landing on the old pane
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        XCTAssertTrue(c.focusedPane === b2, "hover must not steal the focus just handed to the new pane")
        c.closePane(b2, confirmIfNeeded: false, animated: false)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        XCTAssertTrue(c.focusedPane === b, "after closing, focus returns to the neighbouring browser pane")

        // While the address bar is being edited: the field editor is a descendant of the pane, so the pane
        // still holds focus (its border stays lit, and Cmd+W hands focus on).
        b.focusAddressBar()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertTrue(b.holdsFirstResponder(of: try XCTUnwrap(c.window)))
        XCTAssertTrue(b.focused, "the focused flag must not drop while the address bar is being edited")
        XCTAssertTrue(c.focusedPane === b)
        _ = c.window?.makeFirstResponder(b.webView)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))

        // After a layout switch the browser pane is still there and still focused (it takes focus back once remounted).
        c.perform(.toggleLayout)
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        XCTAssertTrue(c.paneList.contains { $0 === b })
        XCTAssertTrue(c.focusedPane === b, "focus is still on the browser pane after the layout switch")

        // With several tabs, Cmd+W closes the active tab rather than the pane; only the last tab closes the pane.
        b.newTab()
        XCTAssertEqual(b.tabs.count, 2)
        c.perform(.closePane)
        XCTAssertEqual(b.tabs.count, 1, "Cmd+W closed the tab")
        XCTAssertTrue(c.paneList.contains { $0 === b }, "the pane is still here")
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertTrue(c.window?.firstResponder === b.webView, "after a tab closes, keyboard focus has to land on the surviving tab's page")

        // Closing: no process confirmation, and focus goes back to the terminal.
        c.closePane(b, confirmIfNeeded: true, animated: false)
        XCTAssertFalse(c.paneList.contains { $0 === b })
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        XCTAssertTrue(c.focusedPane === a)
        c.closePane(a, confirmIfNeeded: false, animated: false)
        c.model.layout = .empty
    }

    /// Cmd+drag hit testing goes by the floating pane's rect, gap band included: the middle moves it, the
    /// border band resizes, and a corner does both axes.
    @MainActor
    func testFloatingDragHitZonesInWindowCoordinates() throws {
        let c = try controller
        let home = c.model.activeIndex
        c.model.switchTo(c.model.layouts.count - 1)
        defer { c.model.switchTo(home) }
        XCTAssertTrue(c.model.layout.isEmpty)
        c.perform(.newTerminal)
        let pane = try XCTUnwrap(c.paneList.first)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        c.toggleFloat(pane)
        defer { c.closePane(pane, confirmIfNeeded: false, animated: false) }
        let fp = try XCTUnwrap(c.model.floating.first)
        let content = try XCTUnwrap(c.window?.contentView)
        let barH: CGFloat = c.model.barVisible ? StatusBarView.height : 0
        let W = content.bounds.width, H = content.bounds.height - barH
        // Normalized -> window coordinates (contentView is flipped, so y runs top to bottom).
        func windowPoint(_ nx: CGFloat, _ ny: CGFloat) -> NSPoint {
            let local = NSPoint(x: nx * W, y: content.isFlipped ? ny * H + barH : content.bounds.height - (ny * H + barH))
            return content.convert(local, to: nil)
        }
        let r = fp.rect
        XCTAssertEqual(c.floatingDragHit(atWindowPoint: windowPoint(r.midX, r.midY))?.edges, [], "the middle means move")
        XCTAssertEqual(c.floatingDragHit(atWindowPoint: windowPoint(r.minX + 3 / W, r.midY))?.edges, [.left])
        XCTAssertEqual(c.floatingDragHit(atWindowPoint: windowPoint(r.maxX - 3 / W, r.maxY - 3 / H))?.edges, [.right, .bottom])
        XCTAssertNil(c.floatingDragHit(atWindowPoint: windowPoint(r.minX - 0.05, r.midY)), "outside the rect there is no hit")
    }

    /// After a new pane is created, focus has to land on it (in dwindle the original pane grabs focus back
    /// when it is remounted from leaf to split, so it has to yield).
    @MainActor
    func testNewTerminalFocusesNewPaneInDwindle() throws {
        let c = try controller
        let home = c.model.activeIndex
        let ws = c.model.layouts.count - 1          // The empty workspace, clear of state left by earlier cases
        c.model.switchTo(ws)
        defer { c.model.switchTo(home) }
        XCTAssertTrue(c.model.layout.isEmpty)
        c.model.layout = .dwindle(SplitTree())
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        var created: [PaneView] = []
        defer { for p in created { c.closePane(p, confirmIfNeeded: false, animated: false) } }
        func frDesc() -> String {
            if let s = c.window?.firstResponder as? PaneView { return "Surface(\(s.id.uuidString.prefix(4)))" }
            return c.window?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
        }
        for round in 0..<3 {   // Root leaf -> split -> split again
            let before = Set(c.paneList.map(ObjectIdentifier.init))
            c.perform(.newTerminal)
            RunLoop.main.run(until: Date().addingTimeInterval(0.6))
            let fresh = try XCTUnwrap(c.paneList.first { !before.contains(ObjectIdentifier($0)) })
            created.append(fresh)
            XCTAssertTrue(c.window?.firstResponder === fresh,
                          "round \(round): the new pane \(fresh.id.uuidString.prefix(4)) should be the first responder, actual \(frDesc())")
            XCTAssertTrue(fresh.focused, "round \(round): the new pane's focused should be true")
            XCTAssertEqual(c.paneList.filter(\.focused).count, 1, "round \(round): exactly one pane is active")
        }
    }

    /// Regression: after Cmd+L rebuilds the view hierarchy, no two panes may be focused at once (two lit
    /// borders, and hover stops working).
    @MainActor
    func testToggleLayoutKeepsSingleFocus() throws {
        let c = try controller
        c.model.switchTo(0)
        let before = Set(c.paneList.map(ObjectIdentifier.init))
        for _ in 0..<4 { c.perform(.newTerminal) }
        let created = c.paneList.filter { !before.contains(ObjectIdentifier($0)) }
        XCTAssertEqual(created.count, 4)
        defer { for p in created { c.closePane(p, confirmIfNeeded: false, animated: false) } }
        let target = try XCTUnwrap(created.last)
        PaneView.moveFocus(to: target)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))

        for _ in 0..<2 {   // scrolling -> dwindle -> scrolling
            c.perform(.toggleLayout)
            // Reproduce the race: before SwiftUI has rebuilt the hierarchy another pane becomes first responder
            // (as if a hover moveFocus landed right then), and the rebuild then takes it out of the window.
            // AppKit sends no resign, so focused would be left behind.
            let other = try XCTUnwrap(created.first { $0 !== (c.window?.firstResponder as? PaneView) })
            _ = c.window?.makeFirstResponder(other)
            RunLoop.main.run(until: Date().addingTimeInterval(0.6))
            // Simulate one more hover after the switch.
            let another = try XCTUnwrap(created.first { $0 !== (c.window?.firstResponder as? PaneView) })
            PaneView.moveFocus(to: another)
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            let focusedPanes = c.paneList.filter(\.focused)
            XCTAssertLessThanOrEqual(focusedPanes.count, 1,
                                     "\(focusedPanes.count) panes focused at once in the \(c.model.layout.name) layout")
            if let fr = c.window?.firstResponder as? PaneView {
                XCTAssertTrue(focusedPanes.first === fr, "the focused flag has to agree with the window's first responder")
            }
        }
    }

    /// A two-finger horizontal swipe: with the **active** browser pane under the pointer the event goes to the
    /// page (horizontal scrolling, the back/forward gesture).
    /// With a terminal focused, or a browser pane merely passed over, the canvas pans as before.
    func testFocusedBrowserPaneClaimsHorizontalScroll() throws {
        let c = try controller
        let home = c.model.activeIndex
        let ws = c.model.layouts.count - 1
        c.model.switchTo(ws)
        defer { c.model.switchTo(home) }
        XCTAssertTrue(c.model.layout.isEmpty)
        let prevSettings = BrowserPaneView.settings
        defer { BrowserPaneView.settings = prevSettings }
        BrowserPaneView.settings.home = "about:blank"
        c.perform(.newTerminal)
        let a = try XCTUnwrap(c.paneList.first)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        c.perform(.newBrowser)
        let b = try XCTUnwrap(c.paneList.first { $0 is BrowserPaneView } as? BrowserPaneView)
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        let window = try XCTUnwrap(c.window)
        XCTAssertTrue(b.holdsFirstResponder(of: window))
        XCTAssertTrue(c.browserPaneClaimingScroll(under: b.webView) === b, "the active browser pane takes the horizontal swipe")
        func descendants(_ v: NSView) -> [NSView] { v.subviews.flatMap { [$0] + descendants($0) } }
        let strip = try XCTUnwrap(descendants(b).first { $0 is BrowserTabBarView })
        XCTAssertTrue(c.browserPaneClaimingScroll(under: strip) === b, "the tab bar and the address field count as inside the pane")
        XCTAssertNil(c.browserPaneClaimingScroll(under: a), "over a terminal it does not belong to a page")

        _ = window.makeFirstResponder(a.focusTarget)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertTrue(a.holdsFirstResponder(of: window))
        XCTAssertNil(c.browserPaneClaimingScroll(under: b.webView),
                     "an inactive browser pane is only being passed over: the canvas pans as before")

        c.closePane(b, confirmIfNeeded: false, animated: false)
        c.closePane(a, confirmIfNeeded: false, animated: false)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    }
}
