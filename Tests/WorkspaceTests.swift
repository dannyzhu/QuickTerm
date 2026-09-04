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
        if let pane = c.paneList.first { c.closePane(pane, confirmIfNeeded: false, animated: false) }
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

        c.closePane(extra, confirmIfNeeded: false, animated: false)
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

        c.closePane(pane, confirmIfNeeded: false, animated: false)
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
            c.closePane(pane, confirmIfNeeded: false, animated: false)
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
        c.closePane(only, confirmIfNeeded: false, animated: false)
        XCTAssertTrue(c.model.layout.isEmpty, "最后一个 pane 已关")
        XCTAssertTrue(c.window?.isVisible ?? false, "窗口保留，不随最后一个 pane 关闭")
        c.perform(.newTerminal)
        XCTAssertEqual(c.paneList.count, 1, "空工作区可直接新建终端")
        c.closePane(try XCTUnwrap(c.paneList.first), confirmIfNeeded: false, animated: false)
    }

    /// 关闭动效：关闭先标记淡出（pane 仍在布局、焦点已交给接班人），动效到点后才真正移除；
    /// 任何布局操作前先把淡出中的 pane 立即移除（flush），定时器到点不再有副作用
    @MainActor
    func testClosePaneAnimatedDefersRemovalAndFocusesSuccessor() throws {
        let c = try controller
        let prevAnim = c.closeAnimationEnabled
        defer { c.closeAnimationEnabled = prevAnim }
        let home = c.model.activeIndex
        let ws = c.model.layouts.count - 1
        c.model.switchTo(ws)
        defer { c.model.switchTo(home) }
        XCTAssertTrue(c.model.layout.isEmpty, "末位工作区应为空")
        c.model.layout = .dwindle(SplitTree())
        c.closeAnimationEnabled = true   // 不受系统"减弱动态效果"影响
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        c.perform(.newTerminal)
        let a = try XCTUnwrap(c.paneList.first)
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        c.perform(.newTerminal)
        let b = try XCTUnwrap(c.paneList.first { $0 !== a })
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        XCTAssertTrue(c.window?.firstResponder === b, "新 pane 应为焦点")

        c.closePane(b, confirmIfNeeded: false)   // animated 默认开
        XCTAssertEqual(c.paneList.count, 2, "动效期间 pane 仍在布局")
        XCTAssertTrue(c.model.closingPanes.contains(b.id))
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertTrue(c.window?.firstResponder === a, "焦点在关闭开始时就交给接班人")
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        XCTAssertEqual(c.paneList.count, 1, "动效到点后真正移除")
        XCTAssertTrue(c.model.closingPanes.isEmpty)
        XCTAssertTrue(c.window?.firstResponder === a)

        // flush：淡出中再做布局操作 → 立即移除；到点的定时器不再有副作用
        c.perform(.newTerminal)
        let d = try XCTUnwrap(c.paneList.first { $0 !== a })
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        c.closePane(d, confirmIfNeeded: false)
        XCTAssertEqual(c.paneList.count, 2)
        c.perform(.focusLeft)
        XCTAssertEqual(c.paneList.count, 1, "布局操作前 flush 淡出中的 pane")
        XCTAssertTrue(c.model.closingPanes.isEmpty)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        XCTAssertEqual(c.paneList.count, 1)
        XCTAssertTrue(c.window?.firstResponder === a)
        c.closePane(a, confirmIfNeeded: false, animated: false)
    }

    /// dwindle 三 pane 夹具：split(A, split(B, C))，焦点 C（末位空工作区，动效开）
    @MainActor
    private func dwindleTriple(_ c: MainWindowController) throws -> (a: Ghostty.SurfaceView, b: Ghostty.SurfaceView, cc: Ghostty.SurfaceView) {
        XCTAssertTrue(c.model.layout.isEmpty, "末位工作区应为空")
        c.model.layout = .dwindle(SplitTree())
        c.closeAnimationEnabled = true
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        func spawn() throws -> Ghostty.SurfaceView {
            let before = Set(c.paneList.map(ObjectIdentifier.init))
            c.perform(.newTerminal)
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            return try XCTUnwrap(c.paneList.first { !before.contains(ObjectIdentifier($0)) })
        }
        let a = try spawn(), b = try spawn(), cc = try spawn()
        guard case .dwindle(let tree) = c.model.layout, case .split(let root)? = tree.root,
              case .leaf(let l) = root.left, l === a, case .split = root.right else {
            // 夹具形状在测试宿主里是确定的（1024×720 窗口，新 pane 相对焦点插入）：
            // 不成形 = 焦点交接回归，必须失败而不是跳过
            XCTFail("期望 split(A, split(B, C))，实际 \(c.model.layout)")
            throw FixtureShapeError()
        }
        return (a, b, cc)
    }

    private struct FixtureShapeError: Error {}

    /// 窗口坐标里的 pane 矩形
    private func windowRect(_ v: Ghostty.SurfaceView) -> NSRect { v.convert(v.bounds, to: nil) }

    /// 关闭的 pane 其兄弟是子树时，兄弟子树会顶到父分裂视图的位置被 SwiftUI 复用（连同锁存的关闭态）；
    /// 派生几何必须立刻回到正常——否则幸存子树的一个孩子被压成 0 宽、内容钉在旧尺寸盖住另一个
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
        c.closePane(a, confirmIfNeeded: false)   // 动效关闭；根变成 split(B, C)，复用根分裂视图
        RunLoop.main.run(until: Date().addingTimeInterval(0.7))
        XCTAssertEqual(c.paneList.count, 2)
        let rb = windowRect(b), rc = windowRect(cc)
        XCTAssertGreaterThan(rb.width, 40, "B 尺寸异常 \(rb)")
        XCTAssertGreaterThan(rb.height, 40, "B 尺寸异常 \(rb)")
        XCTAssertGreaterThan(rc.width, 40, "C 尺寸异常 \(rc)")
        XCTAssertGreaterThan(rc.height, 40, "C 尺寸异常 \(rc)")
        let overlap = rb.intersection(rc)
        XCTAssertLessThan(overlap.width * overlap.height, 100, "B/C 重叠：B=\(rb) C=\(rc)（残留的关闭态几何）")
    }

    /// 淡出中紧接着新建：perform 先 flush（根 → 叶 B）再插入 D（根 → split(B, D)），同一轮更新里
    /// 根分裂视图被复用；B 不能被压成 0 宽
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
        c.perform(.newTerminal)                 // flush + 插入
        XCTAssertEqual(c.paneList.count, 2)
        let d = try XCTUnwrap(c.paneList.first { $0 !== b })
        defer { for p in [b, d] where c.paneList.contains(p) { c.closePane(p, confirmIfNeeded: false, animated: false) } }
        RunLoop.main.run(until: Date().addingTimeInterval(0.7))
        let rb = windowRect(b), rd = windowRect(d)
        XCTAssertGreaterThan(rb.width, 40, "B 尺寸异常 \(rb)")
        XCTAssertGreaterThan(rd.width, 40, "D 尺寸异常 \(rd)")
        let overlap = rb.intersection(rd)
        XCTAssertLessThan(overlap.width * overlap.height, 100, "B/D 重叠：B=\(rb) D=\(rd)")
    }

    /// 并发关闭（子进程同时退出，不经 perform 不 flush）：接班人不能是正在淡出的 pane
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
        c.closePane(b, confirmIfNeeded: false)    // B 淡出（非焦点）
        c.closePane(cc, confirmIfNeeded: false)   // C 淡出：兄弟 B 在淡出中，接班人应为 A
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        XCTAssertTrue(c.window?.firstResponder === a, "接班人应跳过淡出中的 B")
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        XCTAssertEqual(c.paneList.count, 1)
        XCTAssertTrue(c.paneList.first === a)
        XCTAssertTrue(c.window?.firstResponder === a)
    }

    /// 非活动工作区里 shell 退出：pane 直接从所在工作区移除（原先只处理活动工作区，死 surface 会残留）
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
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))   // 移除在回调栈外异步进行
        XCTAssertTrue(c.model.layouts[ws].isEmpty, "后台工作区的 pane 应被移除")
    }

    /// pane 间隔在两种布局下一致：相邻 SurfaceView 的窗口矩形间距 = 2×pane-gap（dwindle 分隔线不占布局），
    /// dwindle 左缘到内容区边 = 外圈 + 留白 = 2×pane-gap
    @MainActor
    func testPaneGapConsistentAcrossLayouts() throws {
        let c = try controller
        let home = c.model.activeIndex
        c.model.switchTo(c.model.layouts.count - 1)
        defer { c.model.switchTo(home) }
        XCTAssertTrue(c.model.layout.isEmpty)
        let gap = c.themeManager.paneGap   // 测试宿主读真实配置：不假设具体值（默认 5 由 ConfigStoreTests 覆盖）
        XCTAssertGreaterThan(gap, 0)
        func spawn() throws -> Ghostty.SurfaceView {
            let before = Set(c.paneList.map(ObjectIdentifier.init))
            c.perform(.newTerminal)
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            return try XCTUnwrap(c.paneList.first { !before.contains(ObjectIdentifier($0)) })
        }
        func rect(_ v: Ghostty.SurfaceView) -> NSRect { v.convert(v.bounds, to: nil) }

        // dwindle：A | B
        c.model.layout = .dwindle(SplitTree())
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let a = try spawn(), b = try spawn()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        let ra = rect(a), rb = rect(b)
        XCTAssertEqual(rb.minX - ra.maxX, 2 * gap, accuracy: 0.6, "dwindle 相邻间距 A=\(ra) B=\(rb)")
        XCTAssertEqual(ra.minX, 2 * gap, accuracy: 0.6, "dwindle 左缘 = 外圈 + 留白")
        for p in [a, b] { c.closePane(p, confirmIfNeeded: false, animated: false) }

        // scrolling：两列（不溢出居中），相邻间距同值
        c.model.layout = .empty
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let x = try spawn(), y = try spawn()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        let rx = rect(x), ry = rect(y)
        let (left, right) = rx.minX < ry.minX ? (rx, ry) : (ry, rx)
        XCTAssertEqual(right.minX - left.maxX, 2 * gap, accuracy: 0.6, "scrolling 相邻间距 \(left) \(right)")
        for p in [x, y] { c.closePane(p, confirmIfNeeded: false, animated: false) }
        c.model.layout = .empty
    }

    /// file-manager 动作：新 pane 以指定程序启动并获得焦点（用 vim 代替 yazi：接受目录参数且常驻）
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
        XCTAssertTrue(c.window?.firstResponder === pane, "文件管理器 pane 应获焦点")
        XCTAssertTrue(c.paneList.contains(pane), "程序常驻，pane 不应自行关闭")
        c.closePane(pane, confirmIfNeeded: true, animated: false)   // 文件管理器 pane 不弹确认，直接关
        XCTAssertTrue(c.paneList.isEmpty, "关闭不应被进程确认拦住")
    }

    /// 程序缺失：pane 仍然打开（提示安装并进入登录 shell），不是静默失败
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
        XCTAssertEqual(c.paneList.count, 1, "提示 pane 应常驻（exec 交互登录 shell）")
        for p in c.paneList { c.closePane(p, confirmIfNeeded: false, animated: false) }
    }

    /// 文件管理器退出且目录已变：旁边开终端并关掉本 pane（新 pane 顶上、获焦点），临时 cwd 文件清理
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
        RunLoop.main.run(until: Date().addingTimeInterval(0.7))   // 关闭动效到点
        XCTAssertEqual(c.paneList.count, 1, "旧 pane 关闭、新终端顶上")
        let replacement = try XCTUnwrap(c.paneList.first)
        XCTAssertFalse(replacement === fm)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cwdFile), "临时 cwd 文件已清理")
        XCTAssertTrue(c.window?.firstResponder === replacement, "焦点在新终端")
        c.closePane(replacement, confirmIfNeeded: false, animated: false)
    }

    /// 可执行的假文件管理器脚本（忽略参数），body 为脚本正文
    private func fakeFileManager(_ body: String) throws -> (dir: String, path: String) {
        let dir = NSTemporaryDirectory() + "quickterm-fake-fm-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = dir + "/yazi"
        try ("#!/bin/sh\n" + body + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        return (dir, path)
    }

    /// 真实退出路径：引擎对带 command 的 surface 不自行 close，只发 SHOW_CHILD_EXITED；
    /// 程序正常退出（运行时长 > 250ms）pane 就该自动关闭，而不是显示 "Process exited. Press any key"
    @MainActor
    func testFileManagerProcessExitAutoClosesPane() throws {
        let c = try controller
        let home = c.model.activeIndex
        c.model.switchTo(c.model.layouts.count - 1)
        defer { c.model.switchTo(home) }
        let prevCmd = c.fileManagerCommand
        defer { c.fileManagerCommand = prevCmd }
        let fake = try fakeFileManager("sleep 0.5")   // 正常运行后退出、不写 cwd 文件
        defer { try? FileManager.default.removeItem(atPath: fake.dir) }
        c.fileManagerCommand = fake.path
        c.perform(.fileManager)
        XCTAssertEqual(c.paneList.count, 1)
        RunLoop.main.run(until: Date().addingTimeInterval(2.5))
        XCTAssertTrue(c.paneList.isEmpty, "子进程退出后 pane 应自动关闭")
    }

    /// 启动即失败（≤250ms 退出，如 yazi 配置坏了）：不抑制引擎的诊断，pane 保留等待按键
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
        XCTAssertEqual(c.paneList.count, 1, "异常退出的 pane 应保留（引擎显示 failed to launch）")
        for p in c.paneList { c.closePane(p, confirmIfNeeded: false, animated: false) }
    }

    /// 真实 cd-here 路径：假 yazi 把 --cwd-file 写成别的目录后退出 → 原位开终端并聚焦它
    /// （scrolling 下左侧已有 pane A：焦点必须落在新终端而不是 A）
    @MainActor
    func testFileManagerRealExitOpensTerminalAtWrittenDirectoryAndFocusesIt() throws {
        let c = try controller
        let home = c.model.activeIndex
        c.model.switchTo(c.model.layouts.count - 1)
        defer { c.model.switchTo(home) }
        let prevCmd = c.fileManagerCommand
        defer { c.fileManagerCommand = prevCmd }
        // 假 yazi：正常运行一会儿，把 --cwd-file=<path> 里的 path 写成 /usr 然后退出
        let fake = try fakeFileManager("sleep 0.4\nprintf '/usr\\n' > \"${1#--cwd-file=}\"")
        defer { try? FileManager.default.removeItem(atPath: fake.dir) }
        c.fileManagerCommand = fake.path
        c.perform(.newTerminal)                  // 左侧已有 pane A
        let a = try XCTUnwrap(c.paneList.first)
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        c.perform(.fileManager)
        let fm = try XCTUnwrap(c.paneList.first { $0 !== a })
        RunLoop.main.run(until: Date().addingTimeInterval(3.0))
        XCTAssertEqual(c.paneList.count, 2, "文件管理器 pane 已关、新终端顶上")
        XCTAssertFalse(c.paneList.contains(fm))
        let replacement = try XCTUnwrap(c.paneList.first { $0 !== a })
        XCTAssertTrue(c.window?.firstResponder === replacement, "焦点在新终端而不是左邻 A")
        XCTAssertEqual(replacement.pwd, "/usr", "新终端目录 = yazi 写的目录")
        for p in c.paneList { c.closePane(p, confirmIfNeeded: false, animated: false) }
    }

    /// 退出但目录未变（或 Q 不写文件）：只关 pane
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
        XCTAssertTrue(c.paneList.isEmpty, "目录未变：只关 pane")
        XCTAssertFalse(FileManager.default.fileExists(atPath: cwdFile))
    }

    /// 新建 pane 后焦点必须落在新 pane（dwindle：原 pane 在 leaf→split 重挂时会"夺回"焦点，需让位）
    @MainActor
    func testNewTerminalFocusesNewPaneInDwindle() throws {
        let c = try controller
        let home = c.model.activeIndex
        let ws = c.model.layouts.count - 1          // 用空工作区，隔离前序用例遗留状态
        c.model.switchTo(ws)
        defer { c.model.switchTo(home) }
        XCTAssertTrue(c.model.layout.isEmpty)
        c.model.layout = .dwindle(SplitTree())
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        var created: [Ghostty.SurfaceView] = []
        defer { for p in created { c.closePane(p, confirmIfNeeded: false, animated: false) } }
        func frDesc() -> String {
            if let s = c.window?.firstResponder as? Ghostty.SurfaceView { return "Surface(\(s.id.uuidString.prefix(4)))" }
            return c.window?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
        }
        for round in 0..<3 {   // 根叶 → 分裂 → 再分裂
            let before = Set(c.paneList.map(ObjectIdentifier.init))
            c.perform(.newTerminal)
            RunLoop.main.run(until: Date().addingTimeInterval(0.6))
            let fresh = try XCTUnwrap(c.paneList.first { !before.contains(ObjectIdentifier($0)) })
            created.append(fresh)
            XCTAssertTrue(c.window?.firstResponder === fresh,
                          "round \(round): 新 pane \(fresh.id.uuidString.prefix(4)) 应为 FR，实际 \(frDesc())")
            XCTAssertTrue(fresh.focused, "round \(round): 新 pane 的 focused 应为 true")
            XCTAssertEqual(c.paneList.filter(\.focused).count, 1, "round \(round): 只有一个 pane 激活")
        }
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
        defer { for p in created { c.closePane(p, confirmIfNeeded: false, animated: false) } }
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
