import XCTest
@testable import QuickTerm

/// 寻址语法（Phase 1 §1）。**纯值类型，不需要窗口**——和 ScrollingStripTests 同一层。
final class ControlTargetTests: XCTestCase {
    private func parse(_ text: String) throws -> ControlTarget {
        try ControlTarget.parse(text)
    }

    // MARK: 三段各自

    func testBareIntegerIsScreenNotPane() throws {
        // pane 句柄一律带类型前缀（t7/b3），所以裸数字永远是屏幕——这条要写死，
        // 否则 `-t 2` 一会儿是屏幕一会儿是 pane，agent 的脚本会随机打偏
        XCTAssertEqual(try parse("2"), ControlTarget(screen: .index(2), workspace: nil, pane: nil))
        XCTAssertEqual(try parse("@current"), ControlTarget(screen: .current, workspace: nil, pane: nil))
        XCTAssertEqual(try parse("@primary"), ControlTarget(screen: .primary, workspace: nil, pane: nil))
    }

    func testScreenWorkspacePane() throws {
        XCTAssertEqual(try parse("2:3.t7"),
                       ControlTarget(screen: .index(2), workspace: .index(3), pane: .handle("t7")))
        XCTAssertEqual(try parse("2:3"),
                       ControlTarget(screen: .index(2), workspace: .index(3), pane: nil))
        XCTAssertEqual(try parse("2:"), ControlTarget(screen: .index(2), workspace: nil, pane: nil))
        XCTAssertEqual(try parse("2:.t7"),
                       ControlTarget(screen: .index(2), workspace: nil, pane: .handle("t7")))
        XCTAssertEqual(try parse(":3.t7"),
                       ControlTarget(screen: nil, workspace: .index(3), pane: .handle("t7")))
        XCTAssertEqual(try parse(":3"), ControlTarget(screen: nil, workspace: .index(3), pane: nil),
                       "显式省略屏幕之后，冒号右边一定从工作区开始（不能又被解释成屏幕 3）")
    }

    func testWorkspaceIsOneBasedOnTheWire() throws {
        // 内部 activeIndex 是 0 起，CLI 永远只见 1 起（与 Cmd+1..0 一致）
        guard case .index(let n)? = try parse(":1").workspace else { return XCTFail("应解析出工作区") }
        XCTAssertEqual(n, 1)
        XCTAssertThrowsError(try parse(":0"), "0 不是合法工作区序号") { error in
            XCTAssertEqual(error as? ControlTarget.ParseError, .badPane("0"))
        }
    }

    func testPaneForms() throws {
        XCTAssertEqual(try parse("t7").pane, .handle("t7"))
        XCTAssertEqual(try parse("b12").pane, .handle("b12"))
        XCTAssertEqual(try parse("@focused").pane, .focused)
        XCTAssertEqual(try parse("@self").pane, .selfPane)
        XCTAssertEqual(try parse("@left").pane, .direction(.left))
        XCTAssertEqual(try parse("@next").pane, .cycle(next: true))
        XCTAssertEqual(try parse("#9c1b4e2f").pane, .id("9c1b4e2f"))
        XCTAssertEqual(try parse("#9C1B4E2F").pane, .id("9c1b4e2f"), "uuid 大小写不敏感")
    }

    func testBareUUIDIsPaneAndScreenNeedsColon() throws {
        let uuid = "3f2a9c1b-0000-0000-0000-000000000000"
        XCTAssertEqual(try parse("#\(uuid)").pane, .id(uuid))
        XCTAssertNil(try parse("#\(uuid)").screen)
        XCTAssertEqual(try parse("#\(uuid):").screen, .id(uuid))
        XCTAssertNil(try parse("#\(uuid):").pane)
    }

    // MARK: 谓词里的分隔符不得被切开（真实的踩坑点）

    func testPredicateColonIsNotAScreenSeparator() throws {
        XCTAssertEqual(try parse("title:~nvim").pane, .title("nvim"))
        XCTAssertNil(try parse("title:~nvim").screen)
        XCTAssertEqual(try parse("kind:browser").pane, .kind("browser"))
        XCTAssertEqual(try parse("role:file-manager").pane, .role("file-manager"))
    }

    func testPredicateDotIsNotAWorkspaceSeparator() throws {
        XCTAssertEqual(try parse("cwd:/Users/danny/a.b").pane, .cwd("/Users/danny/a.b"))
        XCTAssertEqual(try parse("title:~foo.bar").pane, .title("foo.bar"),
                       "正则里的点不能被当成 workspace.pane 的分隔符")
    }

    func testPredicateWithExplicitScreen() throws {
        let target = try parse("2:3.title:~dev")
        XCTAssertEqual(target.screen, .index(2))
        XCTAssertEqual(target.workspace, .index(3))
        XCTAssertEqual(target.pane, .title("dev"))
    }

    // MARK: 往返

    func testRoundTrip() throws {
        for text in ["2", "@current", "@primary", "2:3", "2:3.t7", "2:.t7", ":3", ":3.t7",
                     "t7", "b3", "@focused", "@self", "@left", "@next",
                     "#9c1b4e2f", "#9c1b4e2f:", "title:~nvim", "cwd:/a/b.c",
                     "kind:terminal", "role:file-manager", "2:3.title:~dev"] {
            let parsed = try parse(text)
            XCTAssertEqual(parsed.text, text, "「\(text)」往返不一致")
            XCTAssertEqual(try parse(parsed.text), parsed, "「\(text)」二次解析不一致")
        }
    }

    // MARK: 对抗性输入（agent 会幻觉参数）

    func testRejectsControlCharacters() {
        XCTAssertThrowsError(try parse("t7\u{0}"), "NUL 必须拒绝")
        XCTAssertThrowsError(try parse("title:~a\nb"), "裸换行会破坏 NDJSON 分帧")
    }

    func testRejectsGarbage() {
        for bad in ["", "   ", "@nope", "#zz", "#abc", "unknown:foo", "title:nvim", "kind:tty"] {
            XCTAssertThrowsError(try parse(bad), "「\(bad)」应该报错而不是猜")
        }
    }

    func testUUIDPrefixNeedsFourHexDigits() {
        XCTAssertThrowsError(try parse("#abc"), "少于 4 位的 uuid 前缀太容易误伤")
        XCTAssertNoThrow(try parse("#abcd"))
    }

    func testEmptyTargetIsNotEmptyStruct() throws {
        XCTAssertTrue(ControlTarget().isEmpty)
        XCTAssertFalse(try parse("t7").isEmpty)
    }
}
