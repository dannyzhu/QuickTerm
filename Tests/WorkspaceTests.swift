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
        XCTAssertEqual(c.model.trees.count, 5, "默认 5 个工作区（决策点已确认）")
        XCTAssertEqual(WorkspaceModel.workspaceCount, 5)
    }

    func testSwitchKeepsTreesIndependent() throws {
        let c = try controller
        c.model.switchTo(0)
        let ws0Count = c.paneList.count
        c.switchWorkspace(1)
        XCTAssertEqual(c.model.activeIndex, 1)
        XCTAssertTrue(c.model.tree.isEmpty, "工作区 2 初始为空")
        c.switchWorkspace(0)
        XCTAssertEqual(c.paneList.count, ws0Count, "切回后工作区 1 的树不变")
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
        // 在工作区 0 加一个 pane 再移走它
        let focused = try XCTUnwrap(c.focusedSurface)
        let extra = c.newSurface(inheritingFrom: focused)
        c.model.tree = try c.model.tree.inserting(
            view: extra, at: focused, direction: .right)
        let ws0Before = c.paneList.count

        Ghostty.moveFocus(to: extra)
        c.moveFocusedPane(to: 2)

        XCTAssertEqual(c.model.activeIndex, 2, "移动后跟随到目标工作区")
        XCTAssertEqual(c.paneList.count, 1, "目标工作区应含被移动的 pane")
        c.switchWorkspace(0)
        XCTAssertEqual(c.paneList.count, ws0Before - 1, "源工作区少一个 pane")

        // 清理：把它移回并关闭
        c.switchWorkspace(2)
        if let pane = c.paneList.first { c.closePane(pane, confirmIfNeeded: false) }
        c.model.switchTo(0)
    }

    func testWorkspaceKeybindings() {
        let map = KeybindingMap()
        XCTAssertEqual(map.action(key: "1", modifiers: .command)?.action, .gotoWorkspace1)
        XCTAssertEqual(map.action(key: "5", modifiers: .command)?.action, .gotoWorkspace5)
        XCTAssertEqual(map.action(key: "3", modifiers: [.command, .shift])?.action, .moveToWorkspace3)
        XCTAssertEqual(map.action(key: "space", modifiers: [.command, .shift])?.action, .toggleBar)
        XCTAssertNil(map.action(key: "6", modifiers: .command), "工作区仅 1–5")
    }
}
