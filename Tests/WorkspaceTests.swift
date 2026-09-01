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
