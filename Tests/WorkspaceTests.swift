import XCTest
import AppKit
@testable import QuickTerm

@MainActor
final class WorkspaceTests: XCTestCase {
    private var controller: MainWindowController {
        get throws { try XCTUnwrap((NSApp.delegate as? AppDelegate)?.controller) }
    }

    // 注意：不用 `override func setUp() async`——override 会剥离 @MainActor 隔离，
    // 在后台线程改 @Published 状态会炸掉 TEST_HOST（SwiftUI 后台发布）。
    // 需要归位的用例在（@MainActor 的）测试体内自行 switchTo(0)。

    func testDefaultFiveWorkspaces() throws {
        let c = try controller
        XCTAssertEqual(c.model.layouts.count, 5, "默认 5 个工作区（决策点已确认）")
        XCTAssertEqual(WorkspaceModel.workspaceCount, 5)
    }

    func testDefaultLayoutIsScrolling() throws {
        // spec §4.2-bis v5：新工作区默认 scrolling 无限画布
        let c = try controller
        c.switchWorkspace(1)
        if case .scrolling = c.model.layout {} else {
            XCTFail("空工作区默认应为 scrolling（实际 \(c.model.layout.name)）")
        }
        c.model.switchTo(0)
    }

    func testSwitchKeepsLayoutsIndependent() throws {
        let c = try controller
        c.model.switchTo(0)
        let ws0Count = c.paneList.count
        c.switchWorkspace(1)
        XCTAssertEqual(c.model.activeIndex, 1)
        XCTAssertTrue(c.model.layout.isEmpty, "工作区 2 初始为空")
        c.switchWorkspace(0)
        XCTAssertEqual(c.paneList.count, ws0Count, "切回后工作区 1 不变")
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
        c.perform(.newTerminal)                       // 焦点列右侧插入
        let ws0Before = c.paneList.count
        let moved = try XCTUnwrap(c.focusedSurface)

        c.moveFocusedPane(to: 2)
        XCTAssertEqual(c.model.activeIndex, 2, "移动后跟随到目标工作区")
        XCTAssertEqual(c.paneList.count, 1, "目标工作区应含被移动的 pane")
        XCTAssertTrue(c.paneList.first === moved)

        c.switchWorkspace(0)
        XCTAssertEqual(c.paneList.count, ws0Before - 1, "源工作区少一个 pane")

        // 清理
        c.switchWorkspace(2)
        if let pane = c.paneList.first { c.closePane(pane, confirmIfNeeded: false) }
        c.model.switchTo(0)
    }

    func testLayoutToggleRoundTripPreservesPanes() throws {
        // Cmd+L：scrolling ⇄ dwindle 保 pane（spec §4.2-bis）
        let c = try controller
        c.model.switchTo(0)
        c.perform(.newTerminal)
        let before = c.paneList.count
        let extra = try XCTUnwrap(c.focusedSurface)

        c.perform(.toggleLayout)
        if case .dwindle = c.model.layout {} else { XCTFail("应切到 dwindle") }
        XCTAssertEqual(c.paneList.count, before, "切换保 pane")

        c.perform(.toggleLayout)
        if case .scrolling = c.model.layout {} else { XCTFail("应切回 scrolling") }
        XCTAssertEqual(c.paneList.count, before, "往返保 pane")

        c.closePane(extra, confirmIfNeeded: false)
    }

    func testWorkspaceKeybindings() {
        let map = KeybindingMap()
        XCTAssertEqual(map.action(key: "1", modifiers: .command)?.action, .gotoWorkspace1)
        XCTAssertEqual(map.action(key: "5", modifiers: .command)?.action, .gotoWorkspace5)
        XCTAssertEqual(map.action(key: "3", modifiers: [.command, .shift])?.action, .moveToWorkspace3)
        XCTAssertEqual(map.action(key: "space", modifiers: [.command, .shift])?.action, .toggleBar)
        XCTAssertEqual(map.action(key: "l", modifiers: .command)?.action, .toggleLayout)
        XCTAssertNil(map.action(key: "6", modifiers: .command), "工作区仅 1–5")
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
        XCTAssertEqual(c.model.floating.count, 1, "浮起后浮动层 +1")
        XCTAssertEqual(c.model.layout.paneList.count, tiledBefore - 1, "平铺层 -1")
        XCTAssertTrue(c.model.floating.first?.pane === pane)
        XCTAssertTrue(c.paneList.contains(pane), "paneList 覆盖浮动层")

        c.toggleFloat(pane)
        XCTAssertTrue(c.model.floating.isEmpty, "塞回后浮动层清空")
        XCTAssertEqual(c.model.layout.paneList.count, tiledBefore, "平铺层恢复")

        c.closePane(pane, confirmIfNeeded: false)
    }

    func testToggleFloatKeybinding() {
        let map = KeybindingMap()
        XCTAssertEqual(map.action(key: "t", modifiers: .command)?.action, .toggleFloat,
                       "Cmd+T = 浮动切换（不再穿透给 ghostty new_tab）")
    }

    /// 浮起默认几何（类 Omarchy）：宽 = 默认列宽 × 0.75，高 = 内容区 45%，居中
    func testFloatDefaultRectOmarchyGeometry() {
        let r = FloatingPane.defaultRect(columnFactor: 0.49)  // 2 列默认
        XCTAssertEqual(r.width, 0.3675, accuracy: 0.0001, "宽 = 0.49 × 0.75")
        XCTAssertEqual(r.height, 0.45, accuracy: 0.0001, "高 = 内容区 45%")
        XCTAssertEqual(r.midX, 0.5, accuracy: 0.0001, "水平居中")
        XCTAssertEqual(r.midY, 0.5, accuracy: 0.0001, "垂直居中")
        // 4 列更窄；极小因子有下限（保持可用）
        XCTAssertEqual(FloatingPane.defaultRect(columnFactor: 0.245).width,
                       0.18375, accuracy: 0.0001)
        XCTAssertEqual(FloatingPane.defaultRect(columnFactor: 0.05).width, 0.15)
    }

    /// 浮起走 defaultRect（不再原地沿用平铺大尺寸）
    @MainActor
    func testToggleFloatUsesDefaultRect() throws {
        let c = try controller
        c.model.switchTo(0)
        c.perform(.newTerminal)
        let pane = try XCTUnwrap(c.focusedSurface)
        c.toggleFloat(pane)
        defer {
            c.toggleFloat(pane)
            c.closePane(pane, confirmIfNeeded: false)
        }
        let rect = try XCTUnwrap(c.model.floating.first?.rect)
        XCTAssertEqual(rect, FloatingPane.defaultRect(columnFactor: c.columnFactor))
    }

    /// 归一化换算与 NSHostingView 的 flipped 坐标一致
    /// （回归：曾按 bottom-left 假设双重翻转，遮挡带整体垂直镜像）
    @MainActor
    func testNormalizedContentPointTopLeft() throws {
        let c = try controller
        let content = try XCTUnwrap(c.window?.contentView)
        let W = content.bounds.width
        let H = content.bounds.height
        let innerH = H - StatusBarView.height  // barVisible 默认 true
        // 窗口坐标恒为 bottom-left：取状态条正下方 10pt、左缘 1/4 处
        let loc = NSPoint(x: W / 4, y: H - StatusBarView.height - 10)
        let p = try XCTUnwrap(c.normalizedContentPoint(loc))
        XCTAssertEqual(p.x, 0.25, accuracy: 0.01)
        XCTAssertEqual(p.y, 10 / innerH, accuracy: 0.01, "top-left 基准：条下 10pt ≈ 顶部")
        // 内容区底缘上方 10pt → 接近 1
        let low = try XCTUnwrap(c.normalizedContentPoint(NSPoint(x: W / 2, y: 10)))
        XCTAssertEqual(low.y, (innerH - 10) / innerH, accuracy: 0.01)
    }

    /// hover 遮挡：只有更高 z 的浮动 pane 构成遮挡（模型几何，不依赖 hitTest——
    /// ⌘ 拖拽源浮层、overlay 滚动条等非 surface 覆盖不会误判）
    func testHoverOcclusionGeometry() {
        let a = CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.3)   // z0
        let b = CGRect(x: 0.3, y: 0.3, width: 0.3, height: 0.3)   // z1（最顶）
        let rects = [a, b]
        let inBoth = CGPoint(x: 0.35, y: 0.35)
        let onlyA = CGPoint(x: 0.15, y: 0.15)
        let outside = CGPoint(x: 0.9, y: 0.9)
        // 平铺 pane（nil）：任一浮动覆盖即遮挡
        XCTAssertTrue(HoverOcclusion.isOccluded(paneFloatIndex: nil, floatingRects: rects, at: onlyA))
        XCTAssertTrue(HoverOcclusion.isOccluded(paneFloatIndex: nil, floatingRects: rects, at: inBoth))
        XCTAssertFalse(HoverOcclusion.isOccluded(paneFloatIndex: nil, floatingRects: rects, at: outside))
        // 浮动 z0：只被更高 z 遮挡，不被自己遮挡
        XCTAssertTrue(HoverOcclusion.isOccluded(paneFloatIndex: 0, floatingRects: rects, at: inBoth))
        XCTAssertFalse(HoverOcclusion.isOccluded(paneFloatIndex: 0, floatingRects: rects, at: onlyA))
        // 最顶浮动永不被遮挡；无浮动即无遮挡
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

        // v3 往返含浮动层；v2 JSON（无 floatings 字段）可解且浮动为空
        let state = MainWindowController.PersistedState(
            layouts: c.model.layouts, floatings: c.model.floatings, activeIndex: 0)
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(MainWindowController.PersistedState.self, from: data)
        XCTAssertEqual(decoded.version, 3)
        XCTAssertEqual(decoded.floatings?.count, c.model.floatings.count)

        var v2 = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        v2["version"] = 2
        v2.removeValue(forKey: "floatings")
        let v2data = try JSONSerialization.data(withJSONObject: v2)
        let decodedV2 = try JSONDecoder().decode(MainWindowController.PersistedState.self, from: v2data)
        XCTAssertNil(decodedV2.floatings, "v2 存档兼容：浮动层缺省")
    }
}

extension WorkspaceTests {
    /// 退出语义：有 pane 才确认；关掉最后一个 pane 窗口仍在且能直接新建
    @MainActor
    func testLastPaneCloseKeepsWindowAndQuitConfirmRule() throws {
        XCTAssertFalse(AppDelegate.shouldConfirmQuit(openPaneCount: 0), "没有 pane → 直接退出")
        XCTAssertTrue(AppDelegate.shouldConfirmQuit(openPaneCount: 1), "有 pane → 确认")

        let c = try controller
        let home = c.model.activeIndex
        let ws = c.model.layouts.count - 1
        c.model.switchTo(ws)
        defer { c.model.switchTo(home) }
        XCTAssertTrue(c.model.layout.isEmpty, "末位工作区应为空")
        c.perform(.newTerminal)
        let only = try XCTUnwrap(c.paneList.first)
        c.closePane(only, confirmIfNeeded: false)
        XCTAssertTrue(c.model.layout.isEmpty, "最后一个 pane 已关")
        XCTAssertTrue(c.window?.isVisible ?? false, "窗口保留，不随最后一个 pane 关闭")
        c.perform(.newTerminal)
        XCTAssertEqual(c.paneList.count, 1, "空工作区可直接新建终端")
        c.closePane(try XCTUnwrap(c.paneList.first), confirmIfNeeded: false)
    }

    /// 回归：Cmd+L 重建视图层级后不得出现多个 pane 同时 focused（多激活边框 + 悬停失效）
    @MainActor
    func testToggleLayoutKeepsSingleFocus() throws {
        let c = try controller
        c.model.switchTo(0)
        let before = Set(c.paneList.map(ObjectIdentifier.init))
        for _ in 0..<4 { c.perform(.newTerminal) }
        let created = c.paneList.filter { !before.contains(ObjectIdentifier($0)) }
        XCTAssertEqual(created.count, 4)
        defer { for p in created { c.closePane(p, confirmIfNeeded: false) } }
        let target = try XCTUnwrap(created.last)
        Ghostty.moveFocus(to: target)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))

        for _ in 0..<2 {   // scrolling → dwindle → scrolling
            c.perform(.toggleLayout)
            // 竞态复现：SwiftUI 尚未重建层级时，另一 pane 成为 FR（模拟悬停 moveFocus 恰好落地），
            // 随后它在重建中被移出窗口——AppKit 不发 resign，focused 会残留
            let other = try XCTUnwrap(created.first { $0 !== (c.window?.firstResponder as? Ghostty.SurfaceView) })
            _ = c.window?.makeFirstResponder(other)
            RunLoop.main.run(until: Date().addingTimeInterval(0.6))
            // 再模拟一次切换后的悬停
            let another = try XCTUnwrap(created.first { $0 !== (c.window?.firstResponder as? Ghostty.SurfaceView) })
            Ghostty.moveFocus(to: another)
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            let focusedPanes = c.paneList.filter(\.focused)
            XCTAssertLessThanOrEqual(focusedPanes.count, 1,
                                     "\(c.model.layout.name) 布局下 \(focusedPanes.count) 个 pane 同时 focused")
            if let fr = c.window?.firstResponder as? Ghostty.SurfaceView {
                XCTAssertTrue(focusedPanes.first === fr, "focused 标志应与窗口 first responder 一致")
            }
        }
    }
}
