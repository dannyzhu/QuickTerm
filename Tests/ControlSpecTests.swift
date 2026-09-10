import XCTest
@testable import QuickTerm

/// Phase 3 的**格式**这一半：`quickterm.workspace/1` 的解析与校验。
/// 全是纯函数，不需要活着的屏幕——落地那一半在 `ControlSpecApplyTests`。
final class ControlSpecTests: XCTestCase {
    private func parse(_ text: String) throws -> SpecDocument {
        try SpecParser.parse(text)
    }

    private func issues(_ text: String) -> ControlErrorBody? {
        do {
            _ = try SpecParser.parse(text)
            return nil
        } catch let body as ControlErrorBody {
            return body
        } catch {
            return ControlErrorBody(.failed, "\(error)")
        }
    }

    // MARK: 取值范围与应用里那份保持一致

    /// Wire 只能 import Foundation，引用不到 `ScrollingStrip`：那就各写一份，再用这条用例钉死。
    ///
    /// 钉的是**包含**而不是相等：公开 schema 必须盖住引擎真的能持有的每一个值。
    /// `pane set --width` 的 0.25–0.90 只管手动调宽，而"每屏可见 N 列"会把列宽设成
    /// (1−2×peek)/N（N=1 是 0.97、N=6 是 0.1617）——照抄手动那一份的后果是
    /// `spec dump` 出来的文件被 `spec validate` 当场拒掉
    func testSpecLimitsCoverEveryValueTheEngineCanHold() {
        XCTAssertTrue(SpecLimits.widthRange.contains(ScrollingStrip.widthRange.lowerBound))
        XCTAssertTrue(SpecLimits.widthRange.contains(ScrollingStrip.widthRange.upperBound))
        for n in SpecLimits.visibleColumns {
            // dump 会把它定到 4 位小数，这里跟着定一次
            let factor = (ScrollingStrip.factor(forVisibleColumns: n) * 10000).rounded() / 10000
            XCTAssertTrue(SpecLimits.widthRange.contains(factor),
                          "每屏 \(n) 列的列宽 \(factor) 必须是一份合法的 spec 值")
        }
        // 分裂比例：鼠标拖分隔条只夹到 10pt，一块 1600pt 宽的 pane 拖到底就是 0.00625
        XCTAssertTrue(SpecLimits.ratioRange.contains(10.0 / 1600))
        XCTAssertEqual(SpecLimits.maxPanes, ControlRateLimiter.maxPanesPerWorkspace)
        XCTAssertEqual(SpecLimits.visibleColumns, 1...6)
    }

    // MARK: 最小可用的一份

    /// **两行就要能用**：kind 默认 terminal、width 默认按每屏可见列数、cwd 继承锚点。
    /// 这条用例是"一个模型能不能随手写出一份 spec"的下限
    func testTwoLineSpecParsesWithDefaults() throws {
        let document = try parse(#"{"columns":[{"panes":[{}]},{"panes":[{},{}]}]}"#)
        guard case .workspace(let workspace) = document else { return XCTFail("应该认成 workspace") }
        XCTAssertEqual(workspace.layoutName, "scrolling", "不写 layout 就是 scrolling")
        XCTAssertEqual(workspace.paneCount, 3)
        let slots = SpecApplier.tiledSlots(workspace)
        XCTAssertEqual(slots.map(\.key), ["c:0.0", "c:1.0", "c:1.1"])
        XCTAssertEqual(SpecApplier.kind(of: slots[0].pane), "terminal")
        XCTAssertNil(slots[0].pane.cwd, "不写 cwd = 继承锚点，不是空串")
    }

    /// 写了 tree 而没写 layout：按 dwindle 认（而不是"scrolling 但树被忽略"这种静默错）
    func testTreeImpliesDwindle() throws {
        let document = try parse(#"{"tree":{"a":{},"b":{"a":{},"b":{}}}}"#)
        guard case .workspace(let workspace) = document else { return XCTFail("应该认成 workspace") }
        XCTAssertEqual(workspace.layoutName, "dwindle")
        XCTAssertEqual(SpecApplier.tiledSlots(workspace).map(\.key), ["p:a", "p:b.a", "p:b.b"])
    }

    // MARK: 三种作用域

    func testSchemaDecidesTheScopeAndShapeSniffingIsTheFallback() throws {
        XCTAssertEqual(try parse(#"{"schema":"quickterm.screen/1"}"#).kind, .screen)
        XCTAssertEqual(try parse(#"{"schema":"quickterm.session/1"}"#).kind, .session)
        XCTAssertEqual(try parse(#"{"workspaces":[]}"#).kind, .screen, "有 workspaces = 屏幕")
        XCTAssertEqual(try parse(#"{"screens":[]}"#).kind, .session, "有 screens = 会话")
        XCTAssertEqual(try parse(#"{"columns":[]}"#).kind, .workspace)
    }

    /// 信封形态（`spec dump --json` 的整份输出）直接喂回来也认——
    /// 否则用户得先 jq 一遍，而那正是最容易出错的一步
    func testEnvelopeShapeIsAccepted() throws {
        let text = #"{"v":1,"ok":true,"data":{"spec":{"schema":"quickterm.workspace/1","columns":[{}]}}}"#
        XCTAssertEqual(try parse(text).kind, .workspace)
    }

    // MARK: 拒绝（每一条都要给出**位置**）

    /// 写错键名是最难查的一类错：静默忽略的话，调用方拿到的是"成功了但什么都没发生"
    func testUnknownKeysAreRefusedWithTheirPath() throws {
        let body = try XCTUnwrap(issues(#"{"colums":[{}]}"#))
        XCTAssertEqual(body.code, ControlErrorCode.badRequest.rawValue)
        XCTAssertTrue(body.message.contains("colums"), "报错里要出现写错的那个键：\(body.message)")
        let nested = try XCTUnwrap(issues(#"{"columns":[{"panes":[{"kimd":"browser"}]}]}"#))
        XCTAssertTrue(nested.message.contains("columns[0].panes[0].kimd"),
                      "要给出完整路径：\(nested.message)")
    }

    /// 越界**报错并说出范围**，绝不静默夹紧：夹紧之后读回来的值和写下去的对不上
    func testOutOfRangeNumbersNameTheValidRange() throws {
        let width = try XCTUnwrap(issues(#"{"columns":[{"width":1.5}]}"#))
        XCTAssertTrue(width.message.contains("\(SpecLimits.widthRange.lowerBound)"), width.message)
        XCTAssertTrue(width.message.contains("\(SpecLimits.widthRange.upperBound)"), width.message)
        let ratio = try XCTUnwrap(issues(#"{"tree":{"ratio":1.4,"a":{},"b":{}}}"#))
        XCTAssertTrue(ratio.message.contains("\(SpecLimits.ratioRange.lowerBound)"), ratio.message)
        // 拖出来的极端比例是**合法输入**：dump 要如实写出它，绝不静默夹进 0.1–0.9
        XCTAssertNil(issues(#"{"tree":{"ratio":0.02,"a":{},"b":{}}}"#), "拖到 2% 的分隔条也要收得下")
        let columns = try XCTUnwrap(issues(#"{"visibleColumns":9}"#))
        XCTAssertTrue(columns.message.contains("1–6"), columns.message)
    }

    /// 控制字符（会一路混进子进程的环境 / 命令行）与坏路径
    func testAdversarialStringsAreRefused() throws {
        XCTAssertNotNil(issues("{\"columns\":[{\"panes\":[{\"cmd\":\"ls\\u0007\"}]}]}"), "cmd 里的控制字符")
        XCTAssertNotNil(issues("{\"columns\":[{\"panes\":[{\"cwd\":\"\\u0000/tmp\"}]}]}"), "cwd 里的 NUL")
        XCTAssertNotNil(issues(#"{"columns":[{"panes":[{"cwd":"relative/path"}]}]}"#), "相对路径")
        XCTAssertNotNil(issues("{\"columns\":[{\"panes\":[{\"env\":{\"A B\":\"1\"}}]}]}"), "环境变量名里的空格")
        XCTAssertNotNil(issues(#"{"columns":[{"panes":[{"env":{"A":1}}]}]}"#), "环境变量的值不是字符串")
    }

    /// `..` 归一化：`/tmp/a/../b` = `/tmp/b`（不是安全边界，只是让路径可比）
    func testPathTraversalIsNormalisedNotRejected() {
        XCTAssertEqual(SpecValidator.normalizedPath("/tmp/a/../b"), "/tmp/b")
        XCTAssertTrue(SpecValidator.normalizedPath("~/x").hasPrefix("/"))
    }

    /// 互斥：url 只对浏览器有意义、cmd 对浏览器没意义、一个节点不能既分裂又是叶子
    func testMutuallyExclusiveFieldsAreRefused() throws {
        XCTAssertNotNil(issues(#"{"columns":[{"panes":[{"url":"https://x"}]}]}"#))
        XCTAssertNotNil(issues(#"{"columns":[{"panes":[{"kind":"browser","cmd":"ls"}]}]}"#))
        XCTAssertNotNil(issues(#"{"tree":{"pane":{},"a":{},"b":{}}}"#))
        XCTAssertNotNil(issues(#"{"layout":"scrolling","tree":{"pane":{}}}"#))
        XCTAssertNotNil(issues(#"{"layout":"dwindle","columns":[{}]}"#))
        XCTAssertNotNil(issues(#"{"tree":{"a":{}}}"#), "分裂节点缺一侧不会被脑补")
    }

    func testUnknownSchemaListsTheOnesWeKnow() throws {
        let body = try XCTUnwrap(issues(#"{"schema":"quickterm.workspace/2"}"#))
        XCTAssertEqual(body.candidates, SpecSchema.all)
    }

    func testEmptyAndOversizedInputs() throws {
        XCTAssertNotNil(issues("   "))
        XCTAssertNotNil(issues("not json"))
        XCTAssertNotNil(issues("[]"), "最外层必须是对象")
        let huge = String(repeating: "x", count: SpecLimits.maxBytes + 1)
        XCTAssertNotNil(issues(huge))
    }

    /// 一个工作区最多 32 个 pane：agent 会很开心地写出 200 个
    func testPaneCapIsEnforcedByTheParser() throws {
        let columns = (0..<(SpecLimits.maxPanes + 1)).map { _ in #"{"panes":[{}]}"# }.joined(separator: ",")
        let body = try XCTUnwrap(issues("{\"columns\":[\(columns)]}"))
        XCTAssertTrue(body.message.contains("\(SpecLimits.maxPanes)"), body.message)
    }

    // MARK: 位置引用

    func testPositionRefsMapOntoWalkOrder() {
        XCTAssertEqual(SpecApplier.key(for: PaneRef(column: 1, row: 2)), "c:1.2")
        XCTAssertEqual(SpecApplier.key(for: PaneRef(path: "b.a")), "p:b.a")
        XCTAssertEqual(SpecApplier.key(for: PaneRef(floating: 0)), "f:0")
        XCTAssertNil(SpecApplier.key(for: PaneRef()))
        XCTAssertNotNil(issues(#"{"focus":{"path":"x.y"}}"#), "树路径只能由 a / b 组成")
    }

    // MARK: 编解码往返

    /// 类型化的 spec → JSON → 类型化的 spec，一个字段都不掉
    func testTypedRoundTrip() throws {
        let workspace = WorkspaceSpec(
            schema: SpecSchema.workspace, layout: "dwindle", visibleColumns: 3,
            tree: .split(.init(direction: "vertical", ratio: 0.6,
                               a: .leaf(PaneSpec(kind: "terminal", cwd: "/tmp", cmd: "ls", hold: true,
                                                 env: ["A": "1"])),
                               b: .leaf(PaneSpec(kind: "browser", url: "https://example.com",
                                                 tabs: ["https://example.com", "https://a.test"])))),
            zoom: PaneRef(path: "a"), focus: PaneRef(path: "b"),
            floating: [FloatingSpec(rect: [0.1, 0.2, 0.3, 0.4], pane: PaneSpec())])
        let text = try SpecDocument.workspace(workspace).canonicalJSONString()
        guard case .workspace(let back) = try parse(text) else { return XCTFail("解不回来") }
        XCTAssertEqual(back, workspace)
    }

    // MARK: 命令表 / describe

    /// 没有一条命令能被执行却不在 describe 里（Phase 1 起的不变量，spec 三条也算）
    func testSpecCommandsAreDeclaredInTheTable() throws {
        let verbs = ControlCommandTable.commands(inGroup: "spec").map(\.verb)
        XCTAssertEqual(verbs, ["dump", "validate", "apply"])
        let apply = try XCTUnwrap(ControlCommandTable.command("spec apply"))
        XCTAssertEqual(apply.cls, .destructive, "命令表里按最坏情况声明（--replace）")
        XCTAssertTrue(apply.honorsMutationFlags, "spec apply 要认 --dry-run / --fail-if-noop")
        XCTAssertTrue(apply.readsFile, "-f / 标准输入由 CLI 读，服务端不碰调用方的文件系统")
        XCTAssertTrue(try XCTUnwrap(ControlCommandTable.command("spec dump")).cls == .read)
        for spec in ControlCommandTable.commands(inGroup: "spec") {
            XCTAssertFalse(spec.examples.isEmpty, "\(spec.cli) 的帮助必须以 EXAMPLES 结尾")
        }
        // 三种模式全都在表里（漏一个就是"能执行但没人知道"）
        let modes = Set(apply.args.map(\.name))
        for mode in SpecApplier.Mode.allCases {
            XCTAssertTrue(modes.contains(mode.rawValue), "\(mode.rawValue) 没在命令表里")
        }
    }

    func testDescribeCarriesTheWorkspaceSchema() throws {
        let document = ControlDescribeDocument.make(cliVersion: "t", appVersion: "t",
                                                    socket: nil, mode: "ask")
        XCTAssertEqual(document.phase, 3)
        XCTAssertEqual(document.specSchema.workspace, SpecSchema.workspace)
        XCTAssertFalse(document.specSchema.fields.isEmpty)
        // describe 里给出的"最小可用的一份"必须真的能解析——文档与实现漂了就等于骗 agent
        XCTAssertEqual(try parse(document.specSchema.minimal).kind, .workspace)
        // 帮助 / describe 里内嵌的每一份样例都要能真的解析——
        // 文档与实现漂了就等于骗 agent，而它没有别的办法发现
        XCTAssertEqual(document.specSchema.examples.count, 2, "scrolling 与 dwindle 各一份")
        for sample in document.specSchema.examples {
            XCTAssertEqual(try parse(sample).kind, .workspace, sample)
        }
        XCTAssertEqual(try parse(ControlCommandTable.specSample).kind, .workspace)
        XCTAssertEqual(try parse(ControlCommandTable.specTreeSample).kind, .workspace)
    }

    /// 错误码只能追加：Phase 3 新增的 partial_apply 要有自己的退出码映射
    func testPartialApplyErrorCode() {
        XCTAssertEqual(ControlErrorCode.partialApply.exit, .failure)
        XCTAssertEqual(ControlErrorCode(rawValue: "partial_apply"), .partialApply)
    }
}
