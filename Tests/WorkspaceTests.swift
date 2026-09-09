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

        // v5 往返含浮动层；v2 JSON（无 floatings 字段）经迁移仍可解且浮动为空
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
    private func dwindleTriple(_ c: MainWindowController) throws -> (a: PaneView, b: PaneView, cc: PaneView) {
        XCTAssertTrue(c.model.layout.isEmpty, "末位工作区应为空")
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
            // 夹具形状在测试宿主里是确定的（1024×720 窗口，新 pane 相对焦点插入）：
            // 不成形 = 焦点交接回归，必须失败而不是跳过
            XCTFail("期望 split(A, split(B, C))，实际 \(c.model.layout)")
            throw FixtureShapeError()
        }
        return (a, b, cc)
    }

    private struct FixtureShapeError: Error {}

    /// 窗口坐标里的 pane 矩形
    private func windowRect(_ v: PaneView) -> NSRect { v.convert(v.bounds, to: nil) }

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
        func spawn() throws -> PaneView {
            let before = Set(c.paneList.map(ObjectIdentifier.init))
            c.perform(.newTerminal)
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            return try XCTUnwrap(c.paneList.first { !before.contains(ObjectIdentifier($0)) })
        }
        func rect(_ v: PaneView) -> NSRect { v.convert(v.bounds, to: nil) }

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
        XCTAssertEqual(replacement.workingDirectory, "/usr", "新终端目录 = yazi 写的目录")
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

    /// 每屏 3 列时：新建、Cmd+J 併入再拆出、再新建，所有列宽因子都等于当前因子（截图 bug：拆出列变 0.485）
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
        c.perform(.toggleSplitDirection)   // b 併入左列
        XCTAssertEqual(factors(), [f])
        c.perform(.toggleSplitDirection)   // b 拆出
        XCTAssertEqual(factors(), [f, f], "拆出的列不能用两列默认宽")
        _ = try spawn()
        XCTAssertEqual(factors(), [f, f, f])
    }

    /// 条带几何断言：pane 视图宽度 = 模型列宽 − 2×pane-gap，且整列完整落在视口内
    @MainActor
    private func assertFillsColumnInsideViewport(
        _ c: MainWindowController, _ pane: PaneView, _ label: String,
        file: StaticString = #filePath, line: UInt = #line) throws {
        // pane 内边距与外圈留白同值，且都跟着 gaps 开关走（PaneChrome / RootView）
        let gap = c.themeManager.gapsEnabled ? c.themeManager.paneGap : 0
        let outer = gap
        let content = try XCTUnwrap(c.window?.contentView, "窗口内容区", file: file, line: line)
        let viewport = content.bounds.width - 2 * outer   // 条带视口 = 内容区宽 − 外圈留白
        guard case .scrolling(let strip) = c.model.layout else {
            return XCTFail("布局应为 scrolling", file: file, line: line)
        }
        let pos = try XCTUnwrap(strip.position(of: pane), "\(label) 不在条带里", file: file, line: line)
        let widths = strip.columnWidths(viewport: viewport, gap: 0)
        let rect = pane.convert(pane.bounds, to: nil)     // 窗口坐标
        XCTAssertEqual(rect.width, widths[pos.col] - 2 * gap, accuracy: 1.0,
                       "\(label) 宽度应 = 列宽 \(widths[pos.col]) − 2×gap，实为 \(rect)",
                       file: file, line: line)
        XCTAssertGreaterThanOrEqual(rect.minX, outer - 1.0,
                                    "\(label) 被视口左缘裁掉：\(rect)", file: file, line: line)
        XCTAssertLessThanOrEqual(rect.maxX, outer + viewport + 1.0,
                                 "\(label) 被视口右缘裁掉：\(rect)", file: file, line: line)
    }

    /// 回归（用户报告「新建浏览器，宽度不对」：新浏览器 pane 亮着焦点边框却被窗口右缘裁掉）：
    /// scrolling 里新建的 pane —— 浏览器与终端一视同仁 —— 必须
    /// ①视图宽度 = 模型列宽 − 2×pane-gap（NSViewRepresentable 不得被内部 fittingSize 撑开），
    /// ②所在列完整落在视口内（新列由条带滚动揭示出来）。窄列一并覆盖：浏览器 pane 的 fittingSize
    /// （工具条 + 地址栏 200pt 下限）远大于列宽时也不许撑出列外。
    @MainActor
    func testNewPaneInScrollingFillsColumnAndIsRevealed() throws {
        let c = try controller
        let home = c.model.activeIndex
        c.model.switchTo(c.model.layouts.count - 1)
        XCTAssertTrue(c.model.layout.isEmpty)
        c.model.layout = .empty   // 前面的用例可能把这块工作区留成（空的）dwindle
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let prevVisible = c.visibleColumns
        let prevSettings = BrowserPaneView.settings
        BrowserPaneView.settings.home = "about:blank"   // 不联网
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
            // 揭示动画 0.15s + 弹入 0.2s + 焦点落地（浏览器经 WKWebView 更慢）
            RunLoop.main.run(until: Date().addingTimeInterval(0.8))
            let p = try XCTUnwrap(c.paneList.first { !before.contains(ObjectIdentifier($0)) })
            created.append(p)
            return p
        }

        // 每屏 3 列：第 4 列起溢出，新列只能靠滚动揭示
        for _ in 0..<3 { _ = try spawn(.newTerminal) }
        let browser = try spawn(.newBrowser)
        XCTAssertTrue(browser is BrowserPaneView, "Cmd+B 应新建浏览器 pane")
        try assertFillsColumnInsideViewport(c, browser, "新建浏览器")
        let terminal = try spawn(.newTerminal)   // 对照组：同一位置的新终端
        try assertFillsColumnInsideViewport(c, terminal, "新建终端（对照）")

        // 窄列：5 个 pane 摊在「每屏 6 列」上（填充模式，全部可见），列宽远小于浏览器 fittingSize
        c.setVisibleColumns(6, persist: false)
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        XCTAssertLessThan(browser.frame.width, browser.fittingSize.width,
                          "窄列断言要有意义：列宽必须小于浏览器 pane 的 fittingSize")
        for (i, p) in c.paneList.enumerated() {
            try assertFillsColumnInsideViewport(c, p, "窄列 pane #\(i)")
        }
    }

    /// 回归：新插进条带的列必须被**揭示**出来，与「焦点何时落到新 pane」无关。
    /// 焦点是异步的（PaneView.moveFocus 等挂载；浏览器 pane 的 FR 是内部 WKWebView，还慢一拍，
    /// 且可能被悬停焦点/重挂抢走）——只按焦点对齐时新列会停在视口右缘外。
    /// 这里刻意不给新 pane 焦点：条带仍须按身份把它滚进来。
    @MainActor
    func testInsertedColumnIsRevealedWithoutFocusLanding() throws {
        let c = try controller
        let home = c.model.activeIndex
        c.model.switchTo(c.model.layouts.count - 1)
        XCTAssertTrue(c.model.layout.isEmpty)
        c.model.layout = .empty   // 前面的用例可能把这块工作区留成（空的）dwindle
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
        guard case .scrolling(let strip) = c.model.layout else { return XCTFail("布局应为 scrolling") }
        let pane = BrowserPaneView(url: URL(string: "about:blank"))
        created.append(pane)
        // 只改布局，不请求焦点（模拟焦点迟到/被抢走）
        c.model.layout = .scrolling(strip.insertingColumnRight(
            of: anchor, pane: pane, widthFactor: c.columnFactor))
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        XCTAssertFalse(pane.holdsFirstResponder(of: window), "本例前提：焦点没落到新 pane")
        try assertFillsColumnInsideViewport(c, pane, "无焦点插入的浏览器列")
    }

    /// 回归：**zoom 中插列**（Cmd+F 之后 Cmd+B / ⌘点链接）同样要按身份揭示。
    /// 结构操作顺手清 zoom（insertingColumnRight），于是「解除 zoom」与「插进一列」落在同一次
    /// SwiftUI 更新里，条带的 HStack 被整条重建：揭示逻辑若挂在 zoom 分支内部，重建只走 onAppear
    /// （把刚插进来的 pane 也认成早就见过的），onChange 又不对刚创建的视图触发——新列没人滚进来。
    @MainActor
    func testInsertedColumnIsRevealedAfterZoomWithoutFocusLanding() throws {
        let c = try controller
        let home = c.model.activeIndex
        c.model.switchTo(c.model.layouts.count - 1)
        XCTAssertTrue(c.model.layout.isEmpty)
        c.model.layout = .empty   // 前面的用例可能把这块工作区留成（空的）dwindle
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
        c.perform(.toggleZoom)   // Cmd+F：只剩焦点 pane 挂着，条带的 HStack 被拆掉
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        guard case .scrolling(let strip) = c.model.layout else { return XCTFail("布局应为 scrolling") }
        XCTAssertNotNil(strip.zoomedID, "本例前提：条带处于 zoom")
        let pane = BrowserPaneView(url: URL(string: "about:blank"))
        created.append(pane)
        // 只改布局（顺手解除 zoom），不请求焦点（模拟焦点迟到/被悬停抢走）
        c.model.layout = .scrolling(strip.insertingColumnRight(
            of: anchor, pane: pane, widthFactor: c.columnFactor))
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        guard case .scrolling(let after) = c.model.layout else { return XCTFail("布局应为 scrolling") }
        XCTAssertNil(after.zoomedID, "插列清 zoom")
        XCTAssertFalse(pane.holdsFirstResponder(of: window), "本例前提：焦点没落到新 pane")
        try assertFillsColumnInsideViewport(c, pane, "zoom 中插入的浏览器列")
    }

    /// 回归：条带停在右端时逐事件调宽（⌘+右键拖拽）不许把视口甩到内容外——
    /// 列宽变化必须触发夹取（layoutSignature 刻意不含 widthFactor，没人替它重排），末列始终贴视口右缘。
    /// 注意：这条**测不出**"夹取有没有带动画"——SwiftUI 动画期间 NSView 的 frame 已经是终值，
    /// 逐事件动画造成的拖尾只在屏幕上看得见（实测把 animated 写死 true 本例照样绿）。
    /// 不带动画的理由见 ScrollingStripView.clampOffset。
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
        for _ in 0..<4 {   // 每屏 3 列 → 4 列溢出，末列揭示后条带贴在右端
            let before = Set(c.paneList.map(ObjectIdentifier.init))
            c.perform(.newTerminal)
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            created.append(try XCTUnwrap(c.paneList.first { !before.contains(ObjectIdentifier($0)) }))
        }
        let last = try XCTUnwrap(created.last)
        try assertFillsColumnInsideViewport(c, last, "末列（调宽前）")
        let content = try XCTUnwrap(c.window?.contentView)
        let gap = c.themeManager.gapsEnabled ? c.themeManager.paneGap : 0
        let viewport = content.bounds.width - 2 * gap
        let rightEdge = gap + viewport
        XCTAssertEqual(last.convert(last.bounds, to: nil).maxX + gap, rightEdge,
                       accuracy: 1.5, "前提：末列贴着视口右缘（条带在右端）")
        // 模拟一串收窄的拖拽事件（resizeByDrag 是逐事件写 widthFactor）
        for _ in 0..<5 {
            guard case .scrolling(let strip) = c.model.layout else { return XCTFail("布局应为 scrolling") }
            c.model.layout = .scrolling(strip.resizingWidth(of: last, delta: -0.05))
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        // 只等一次布局提交（远短于 0.15s 动画）：夹取跟手就已经到位
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        try assertFillsColumnInsideViewport(c, last, "末列（逐事件调宽后）")
        XCTAssertEqual(last.convert(last.bounds, to: nil).maxX + gap, rightEdge,
                       accuracy: 1.5, "收窄后末列仍贴右缘：视口逐事件跟手夹取，不留空档")
    }

    /// 终端 ⌘+点击链接：没有浏览器 pane → 新开；已有 → 最近激活的那个里开新标签；多个 → 最近聚焦的；
    /// 非 http(s) 与 link-opener = system 不接管
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
        XCTAssertTrue(c.openLink(link1, from: term), "http 链接被接管")
        let b1 = try XCTUnwrap(c.paneList.first { $0 is BrowserPaneView } as? BrowserPaneView, "没有浏览器 pane 时新开一个")
        XCTAssertEqual(b1.tabs.count, 1)
        XCTAssertEqual(b1.activeTab?.lastRequestedURL, link1)
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        let link2 = URL(string: "http://127.0.0.1:9/two")!
        XCTAssertTrue(c.openLink(link2, from: term))
        XCTAssertEqual(c.paneList.filter { $0 is BrowserPaneView }.count, 1, "已有浏览器 pane 时不新开")
        XCTAssertEqual(b1.tabs.count, 2, "在已有 pane 里开新标签")
        XCTAssertEqual(b1.activeTab?.lastRequestedURL, link2, "新标签激活")
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        c.perform(.newBrowser)
        let b2 = try XCTUnwrap(c.paneList.first { $0 is BrowserPaneView && $0 !== b1 } as? BrowserPaneView)
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        XCTAssertTrue(c.mostRecentBrowserPane() === b2, "刚新建并聚焦的浏览器 pane 是最近的")
        c.requestFocus(to: b1)
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        XCTAssertTrue(c.mostRecentBrowserPane() === b1, "重新聚焦 b1 后它是最近的")
        let link3 = URL(string: "http://127.0.0.1:9/three")!
        XCTAssertTrue(c.openLink(link3, from: term))
        XCTAssertEqual(b1.tabs.count, 3, "多个浏览器 pane 时用最近激活的")
        XCTAssertEqual(b2.tabs.count, 1)
        XCTAssertFalse(c.openLink(URL(string: "mailto:a@b.c")!, from: term), "非 http(s) 交给系统")
        c.linkOpener = "system"
        XCTAssertFalse(c.openLink(link1, from: term), "system 模式不接管")
        XCTAssertEqual(b1.tabs.count, 3)
        for p in c.paneList { c.closePane(p, confirmIfNeeded: false, animated: false) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    }

    private func mouse(_ type: NSEvent.EventType, at p: NSPoint, in window: NSWindow, flags: NSEvent.ModifierFlags = .command) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: p, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    /// ⌘ 按住时平铺 pane 上叠着拖拽源浮层：纯点击（没拖过阈值）必须整体转交给 surface（引擎收到 PRESS + RELEASE，
    /// ⌘+点击链接才会触发 open_url）；轻微抖动不算拖
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
        // 精确匹配类名：SwiftUI 的宿主视图类名里也含 "SurfaceDragSourceViewRepresentable"
        func findOverlay(_ v: NSView) -> NSView? {
            if String(describing: type(of: v)) == "SurfaceDragSourceView" { return v }
            for sub in v.subviews { if let hit = findOverlay(sub) { return hit } }
            return nil
        }
        let overlay = try XCTUnwrap(window.contentView.flatMap(findOverlay), "⌘ 按住时应挂上拖拽源浮层")
        let center = pane.convert(NSPoint(x: pane.bounds.midX, y: pane.bounds.midY), to: nil)
        let press0 = pane.leftPressCountForTesting, release0 = pane.leftReleaseCountForTesting
        overlay.mouseDown(with: mouse(.leftMouseDown, at: center, in: window))
        overlay.mouseDragged(with: mouse(.leftMouseDragged, at: NSPoint(x: center.x + 1, y: center.y + 1), in: window))   // 抖动 < 阈值
        XCTAssertEqual(pane.leftPressCountForTesting, press0, "按下时不转发（拖起来就没 release 了）")
        overlay.mouseUp(with: mouse(.leftMouseUp, at: center, in: window))
        XCTAssertEqual(pane.leftPressCountForTesting, press0 + 1, "抬起时补送 PRESS")
        XCTAssertEqual(pane.leftReleaseCountForTesting, release0 + 1, "再送 RELEASE")
        overlay.mouseUp(with: mouse(.leftMouseUp, at: center, in: window))
        XCTAssertEqual(pane.leftReleaseCountForTesting, release0 + 1, "没有配对按下的抬起不转发")
    }

    /// ⌘ 拖拽源浮层盖满整个 pane，但它是 pane 的**兄弟**子树：不转交的话滚轮顺着浮层自己的
    /// 响应链走进 SwiftUI 容器，终端 / 网页永远收不到——用户报的"抓手光标不消失，而且终端滚不动了"
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
        let overlay = try XCTUnwrap(window.contentView.flatMap(findOverlay), "⌘ 按住时应挂上拖拽源浮层")
        let center = pane.convert(NSPoint(x: pane.bounds.midX, y: pane.bounds.midY), to: nil)
        let event = try scrollEvent(at: center, in: window)
        XCTAssertEqual(event.locationInWindow.x, center.x, accuracy: 1, "合成滚轮事件落在 pane 中心")
        XCTAssertEqual(event.locationInWindow.y, center.y, accuracy: 1)
        let before = pane.scrollCountForTesting
        overlay.scrollWheel(with: event)
        XCTAssertEqual(pane.scrollCountForTesting, before + 1, "浮层把滚轮转交给 surface，不能吃掉")
        // ⌘ 一松（哪怕抬起落在别的 app 上，靠 sync 自愈）浮层就该消失，抓手光标随之消失
        ModifierState.shared.sync(.init())
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        XCTAssertNil(window.contentView.flatMap(findOverlay), "⌘ 释放后浮层必须摘掉")
    }

    /// `commandHeld` 只有本地监视器一个写者，看不见落在别的 app 上的 ⌘ 抬起
    /// （⌘+Tab / ⌘+Space / 截图 / ⌘+H）：必须能自愈，否则浮层永远挂着
    @MainActor
    func testModifierStateSelfHealsOnDeactivationAndSync() throws {
        let previous = ModifierState.shared.commandHeld
        defer { ModifierState.shared.commandHeld = previous }
        ModifierState.shared.commandHeld = true
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertFalse(ModifierState.shared.commandHeld, "app 失活时无条件清零（⌘ 的抬起会落在别的 app）")
        ModifierState.shared.sync(.command)
        XCTAssertTrue(ModifierState.shared.commandHeld, "按事件自带的修饰键重建")
        ModifierState.shared.sync([.shift, .option])
        XCTAssertFalse(ModifierState.shared.commandHeld, "任何鼠标 / 滚轮事件都能把漏掉的抬起补回来")
    }

    /// 终端 pane 在 SwiftUI 重建层级期间会短暂脱离窗口（window == nil）。引擎的 open_url 回调
    /// 若此刻解析不出控制器，⌘+点击的 http 链接就被甩给系统默认浏览器——用户报的
    /// "有时会打开系统默认浏览器，而不是 pane 浏览器"
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

        // 挂一个 pane 进窗口再摘掉：正是重建层级那一瞬间的状态（superview 有、window 没有）
        let content = try XCTUnwrap(c.window?.contentView)
        let orphan = PaneView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        content.addSubview(orphan)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertTrue(orphan.controller === c, "挂在窗口里时解析出本窗口的控制器")
        orphan.removeFromSuperview()
        XCTAssertNil(orphan.window, "前提：已脱离窗口")
        XCTAssertTrue(orphan.controller === c, "脱离窗口后仍认得最近一次的控制器")

        let link = URL(string: "http://127.0.0.1:9/detached")!
        XCTAssertTrue(Ghostty.App.routeLink(link, from: orphan), "脱离窗口的 pane 也要被接管")
        XCTAssertTrue(systemOpened.isEmpty, "http 链接绝不能漏给系统默认浏览器")
        let browser = try XCTUnwrap(c.paneList.first { $0 is BrowserPaneView } as? BrowserPaneView)
        XCTAssertEqual(browser.activeTab?.lastRequestedURL, link, "落在 QuickTerm 自己的浏览器 pane 里")
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))

        // 连来源 pane 都没有（target 解析不出 surface）时，退到 key / 任意终端窗口，同样不漏
        let link2 = URL(string: "http://127.0.0.1:9/nosurface")!
        XCTAssertTrue(Ghostty.App.routeLink(link2, from: nil))
        XCTAssertTrue(systemOpened.isEmpty)
        // 非 http(s) 与 link-opener = system 照旧交给系统（不接管 → 引擎调 systemOpener）
        XCTAssertFalse(Ghostty.App.routeLink(URL(string: "mailto:a@b.c")!, from: orphan), "非 http(s) 不接管")
        c.linkOpener = "system"
        XCTAssertFalse(Ghostty.App.routeLink(link, from: orphan), "system 模式不接管")
        c.linkOpener = "browser-pane"
        for p in c.paneList { c.closePane(p, confirmIfNeeded: false, animated: false) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    }

    /// 合成一个真实的滚轮事件（NSEvent.mouseEvent 造不出 .scrollWheel）。
    /// windowNumber = 0 的事件里 `locationInWindow` 就是屏幕坐标：量一次差值补偿，
    /// 免得依赖具体的显示器排布
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

    /// 浮动 pane 的 ⌘ 会话：抬起时没拖过阈值 = 纯点击交给 pane 本体；拖过阈值 = 移动且不点击
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
        // 纯点击
        XCTAssertTrue(c.beginFloatingDrag(with: mouse(.leftMouseDown, at: center, in: window)))
        XCTAssertEqual(c.floatingSessionEvent(mouse(.leftMouseDragged, at: NSPoint(x: center.x + 1, y: center.y), in: window)), true)
        XCTAssertEqual(c.floatingSessionEvent(mouse(.leftMouseUp, at: center, in: window)), true)
        XCTAssertEqual(pane.leftPressCountForTesting, press0 + 1, "没拖 → 点击交给 surface")
        XCTAssertEqual(pane.leftReleaseCountForTesting, release0 + 1)
        XCTAssertEqual(c.model.floating.first?.rect.midX ?? 0, fp.rect.midX, accuracy: 0.001, "没拖就不移动")
        // 真拖：过阈值后移动（阈值前的位移在跨过时一次补上，不丢），抬起不点击
        let before = try XCTUnwrap(c.model.floating.first).rect
        XCTAssertTrue(c.beginFloatingDrag(with: mouse(.leftMouseDown, at: center, in: window)))
        XCTAssertEqual(c.floatingSessionEvent(mouse(.leftMouseDragged, at: NSPoint(x: center.x + 2, y: center.y), in: window)), true)
        XCTAssertEqual(c.model.floating.first?.rect.midX ?? 0, before.midX, accuracy: 0.0001, "阈值内不动")
        XCTAssertEqual(c.floatingSessionEvent(mouse(.leftMouseDragged, at: NSPoint(x: center.x + 40, y: center.y), in: window)), true)
        XCTAssertEqual(((c.model.floating.first?.rect.midX ?? 0) - before.midX) * W, 40, accuracy: 0.5, "累计位移全部补上")
        XCTAssertEqual(c.floatingSessionEvent(mouse(.leftMouseUp, at: NSPoint(x: center.x + 40, y: center.y), in: window)), true)
        XCTAssertEqual(pane.leftPressCountForTesting, press0 + 1, "拖动不产生点击")
        XCTAssertNil(c.floatingSessionEvent(mouse(.leftMouseUp, at: center, in: window)), "会话已结束")
        // 按住期间 pane 离开浮动层（Cmd+T 回平铺）：抬起不转交、不崩
        let center2 = { () -> NSPoint in let r = c.model.floating.first!.rect; return windowPoint(r.midX, r.midY) }()
        XCTAssertTrue(c.beginFloatingDrag(with: mouse(.leftMouseDown, at: center2, in: window)))
        c.toggleFloat(pane)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(c.floatingSessionEvent(mouse(.leftMouseUp, at: center2, in: window)), true)
        XCTAssertEqual(pane.leftPressCountForTesting, press0 + 1, "pane 已不在浮动层：不转交点击")
        c.toggleFloat(pane)   // 还原为浮动，defer 里统一关闭
    }

    /// 别的 pane zoom 时复用浏览器 pane：先解除 zoom，标签才看得见、焦点才交得过去；从 Scratchpad 点链接先收起 Scratchpad
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
        c.perform(.toggleZoom)   // 终端 zoom，浏览器 pane 卸载
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        XCTAssertNil(browser.window, "zoom 后浏览器 pane 没挂载")
        XCTAssertTrue(c.openLink(URL(string: "http://127.0.0.1:9/z")!, from: term))
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        XCTAssertNotNil(browser.window, "复用时解除 zoom，浏览器 pane 重新挂载")
        XCTAssertEqual(browser.tabs.count, 2)
        XCTAssertTrue(c.window?.firstResponder === browser.webView, "焦点交给浏览器 pane")
        // Scratchpad 里点链接
        c.perform(.scratchpad)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        let scratch = try XCTUnwrap(c.model.scratchpadSurface)
        XCTAssertTrue(c.model.scratchpadVisible)
        XCTAssertTrue(c.openLink(URL(string: "http://127.0.0.1:9/s")!, from: scratch))
        XCTAssertFalse(c.model.scratchpadVisible, "先收起 Scratchpad")
        XCTAssertEqual(browser.tabs.count, 3)
        for p in c.paneList { c.closePane(p, confirmIfNeeded: false, animated: false) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    }

    /// 浏览器 pane：Cmd+B 新建并聚焦（FR 是内部 WKWebView，pane 视为持有焦点）、布局切换后仍在且保持焦点、
    /// 存档带 kind=browser、关闭不弹确认、焦点回到终端
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
        BrowserPaneView.settings.home = "about:blank"   // 不依赖网络
        c.perform(.newTerminal)
        let a = try XCTUnwrap(c.paneList.first)
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        // Cmd+Shift+K 清屏：焦点终端时消费并由引擎执行 clear_screen（返回 true = 动作合法且已执行）
        XCTAssertTrue(MainWindowController.consumes(.clearTerminal, focusedPane: a))
        XCTAssertTrue(c.clearTarget === a, "清屏目标 = 焦点终端")
        XCTAssertTrue(c.clearFocusedTerminal())
        // Scratchpad 打开时目标必须是 Scratchpad（它不在 paneList 里，focusedPane 会退回到第一块平铺 pane）
        c.perform(.scratchpad)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        let scratch = try XCTUnwrap(c.model.scratchpadSurface)
        XCTAssertTrue(c.model.scratchpadVisible)
        XCTAssertTrue(c.clearTarget === scratch, "Scratchpad 聚焦时清屏目标是 Scratchpad")
        XCTAssertFalse(c.clearTarget === a, "不能清掉被盖住的平铺终端")
        XCTAssertTrue(MainWindowController.consumes(.clearTerminal, focusedPane: c.clearTarget))
        XCTAssertTrue(c.clearFocusedTerminal())
        c.perform(.scratchpad)   // 收起
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertFalse(c.model.scratchpadVisible)
        XCTAssertTrue(c.clearTarget === a, "收起后回到平铺终端")
        c.perform(.newBrowser)
        let b = try XCTUnwrap(c.paneList.first { $0 is BrowserPaneView } as? BrowserPaneView)
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        XCTAssertTrue(b.holdsFirstResponder(of: try XCTUnwrap(c.window)), "FR 应是浏览器 pane 内部的 WKWebView")
        XCTAssertTrue(c.focusedPane === b)
        XCTAssertTrue(b.focused)
        XCTAssertFalse(a.focused, "单焦点不变量")

        // 存档：叶子 kind=browser + url
        let state = PersistedState(windows: [
            WindowState(layouts: c.model.layouts, floatings: c.model.floatings, activeIndex: ws)
        ])
        let json = String(decoding: try JSONEncoder().encode(state), as: UTF8.self)
        XCTAssertTrue(json.contains("\"kind\":\"browser\""))
        XCTAssertTrue(json.contains("about:blank"))

        // 新 pane 插入会让邻居的 tracking area 重建、AppKit 合成 mouseMoved：鼠标停在旧 pane 上时
        // 悬停不得把刚交给新 pane 的焦点抢回去（控制器有待聚焦意图）
        c.perform(.newBrowser)
        let b2 = try XCTUnwrap(c.paneList.first { $0 is BrowserPaneView && $0 !== b } as? BrowserPaneView)
        a.hoverFocusIfNeeded()                    // 模拟合成的 mouseMoved 命中旧 pane
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        XCTAssertTrue(c.focusedPane === b2, "悬停不能抢走刚交给新 pane 的焦点")
        c.closePane(b2, confirmIfNeeded: false, animated: false)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        XCTAssertTrue(c.focusedPane === b, "关闭后焦点回到相邻的浏览器 pane")

        // 地址栏编辑中：字段编辑器是 pane 的后代，pane 仍持焦（边框亮、Cmd+W 会交接焦点）
        b.focusAddressBar()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertTrue(b.holdsFirstResponder(of: try XCTUnwrap(c.window)))
        XCTAssertTrue(b.focused, "地址栏编辑中 focused 标志不能掉")
        XCTAssertTrue(c.focusedPane === b)
        _ = c.window?.makeFirstResponder(b.webView)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))

        // 布局切换后浏览器 pane 仍在且保持焦点（重挂后夺回）
        c.perform(.toggleLayout)
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        XCTAssertTrue(c.paneList.contains { $0 === b })
        XCTAssertTrue(c.focusedPane === b, "布局切换后焦点仍在浏览器 pane")

        // 多标签时 Cmd+W 关当前标签而不是 pane；最后一个标签才关 pane
        b.newTab()
        XCTAssertEqual(b.tabs.count, 2)
        c.perform(.closePane)
        XCTAssertEqual(b.tabs.count, 1, "Cmd+W 关掉的是标签")
        XCTAssertTrue(c.paneList.contains { $0 === b }, "pane 还在")
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertTrue(c.window?.firstResponder === b.webView, "关标签后键盘焦点必须落在幸存标签的页面上")

        // 关闭：不弹进程确认，焦点回终端
        c.closePane(b, confirmIfNeeded: true, animated: false)
        XCTAssertFalse(c.paneList.contains { $0 === b })
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        XCTAssertTrue(c.focusedPane === a)
        c.closePane(a, confirmIfNeeded: false, animated: false)
        c.model.layout = .empty
    }

    /// ⌘ 拖动命中判定按浮动 pane 的矩形（含留白带）：中间 = 移动，边框带 = 缩放，角 = 双轴
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
        // 归一化 → 窗口坐标（contentView 为 flipped：y 自顶向下）
        func windowPoint(_ nx: CGFloat, _ ny: CGFloat) -> NSPoint {
            let local = NSPoint(x: nx * W, y: content.isFlipped ? ny * H + barH : content.bounds.height - (ny * H + barH))
            return content.convert(local, to: nil)
        }
        let r = fp.rect
        XCTAssertEqual(c.floatingDragHit(atWindowPoint: windowPoint(r.midX, r.midY))?.edges, [], "中间 = 移动")
        XCTAssertEqual(c.floatingDragHit(atWindowPoint: windowPoint(r.minX + 3 / W, r.midY))?.edges, [.left])
        XCTAssertEqual(c.floatingDragHit(atWindowPoint: windowPoint(r.maxX - 3 / W, r.maxY - 3 / H))?.edges, [.right, .bottom])
        XCTAssertNil(c.floatingDragHit(atWindowPoint: windowPoint(r.minX - 0.05, r.midY)), "矩形外不命中")
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
        var created: [PaneView] = []
        defer { for p in created { c.closePane(p, confirmIfNeeded: false, animated: false) } }
        func frDesc() -> String {
            if let s = c.window?.firstResponder as? PaneView { return "Surface(\(s.id.uuidString.prefix(4)))" }
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
        PaneView.moveFocus(to: target)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))

        for _ in 0..<2 {   // scrolling → dwindle → scrolling
            c.perform(.toggleLayout)
            // 竞态复现：SwiftUI 尚未重建层级时，另一 pane 成为 FR（模拟悬停 moveFocus 恰好落地），
            // 随后它在重建中被移出窗口——AppKit 不发 resign，focused 会残留
            let other = try XCTUnwrap(created.first { $0 !== (c.window?.firstResponder as? PaneView) })
            _ = c.window?.makeFirstResponder(other)
            RunLoop.main.run(until: Date().addingTimeInterval(0.6))
            // 再模拟一次切换后的悬停
            let another = try XCTUnwrap(created.first { $0 !== (c.window?.firstResponder as? PaneView) })
            PaneView.moveFocus(to: another)
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            let focusedPanes = c.paneList.filter(\.focused)
            XCTAssertLessThanOrEqual(focusedPanes.count, 1,
                                     "\(c.model.layout.name) 布局下 \(focusedPanes.count) 个 pane 同时 focused")
            if let fr = c.window?.firstResponder as? PaneView {
                XCTAssertTrue(focusedPanes.first === fr, "focused 标志应与窗口 first responder 一致")
            }
        }
    }

    /// 双指横滑：鼠标下是**激活的**浏览器 pane → 事件交给网页（横向滚动 / 前进后退手势）；
    /// 终端持焦、或浏览器 pane 只是被路过 → 照旧平移画布
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
        XCTAssertTrue(c.browserPaneClaimingScroll(under: b.webView) === b, "激活的浏览器 pane 吃横滑")
        func descendants(_ v: NSView) -> [NSView] { v.subviews.flatMap { [$0] + descendants($0) } }
        let strip = try XCTUnwrap(descendants(b).first { $0 is BrowserTabBarView })
        XCTAssertTrue(c.browserPaneClaimingScroll(under: strip) === b, "标签条 / 地址栏也算在 pane 内")
        XCTAssertNil(c.browserPaneClaimingScroll(under: a), "终端上不归网页")

        _ = window.makeFirstResponder(a.focusTarget)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertTrue(a.holdsFirstResponder(of: window))
        XCTAssertNil(c.browserPaneClaimingScroll(under: b.webView), "没激活的浏览器 pane 只是被路过：照旧平移画布")

        c.closePane(b, confirmIfNeeded: false, animated: false)
        c.closePane(a, confirmIfNeeded: false, animated: false)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    }
}
