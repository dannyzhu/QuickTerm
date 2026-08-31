import XCTest
import GhosttyKit
@testable import QuickTerm

@MainActor
final class MainWindowControllerTests: XCTestCase {
    private var controller: MainWindowController {
        get throws {
            try XCTUnwrap((NSApp.delegate as? AppDelegate)?.controller)
        }
    }

    func testFocusFollowsMouseEnabled() throws {
        XCTAssertTrue(try controller.focusFollowsMouse, "悬停即焦点（spec §4.2）必须开启")
    }

    func testEngineOverlayInjectsOpacity() throws {
        // 配置链第 3 层端到端：覆盖文件存在且引擎读到了注入值
        XCTAssertTrue(FileManager.default.fileExists(atPath: EngineOverlay.url.path))
        let ghostty = try XCTUnwrap((NSApp.delegate as? AppDelegate)?.ghostty)
        // getter 语义是"遮罩不透明度" = 1 − 配置值：注入 0.96 → 读回 0.04
        XCTAssertEqual(ghostty.config.unfocusedSplitOpacity, 1 - 0.96, accuracy: 0.001,
                       "unfocused-split-opacity 应来自 QuickTerm 覆盖层（注入 0.96）")
    }

    func testNewPaneInsertAndClose() throws {
        let c = try controller
        let before = c.paneList.count
        let focused = try XCTUnwrap(c.focusedSurface)
        let newPane = c.newSurface(inheritingFrom: focused)
        c.model.tree = try c.model.tree.inserting(
            view: newPane, at: focused, direction: c.model.tree.dwindleDirection(for: focused))
        XCTAssertEqual(c.paneList.count, before + 1)
        c.closePane(newPane, confirmIfNeeded: false)
        XCTAssertEqual(c.paneList.count, before, "关闭后兄弟应回收父槽")
    }
}
