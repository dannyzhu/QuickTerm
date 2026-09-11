import XCTest
@testable import QuickTerm

/// 「dwindle 的 pane 可以调尺寸」这件事在控制面上的两半：
/// **读得到**（每条状态输出都带尺寸，dwindle 的骨架带上每条分隔条的比例）
/// 与**调得动**（命令行能做出鼠标能做的每一种调整，夹取规则也一样）。
///
/// 期望值一律在用例里**独立算一遍**（照着模型里的 ratio / widthFactor 手推），
/// 绝不拿编码器自己的输出当期望——那样只能证明它跟自己一致。
@MainActor
final class ControlSizeTests: XCTestCase {
    private var harness: ControlHarness!
    private var temporaries: [String] = []
    private var touched: Set<Int> = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        harness = try ControlHarness()
        let controller = try harness.controller
        try XCTSkipUnless(controller.model.layouts.count >= 3, "本组用例要三个工作区")
        try XCTSkipUnless(ControlGeometry.contentSize(controller) != nil,
                          "测试宿主没有可量的窗口内容区")
        for index in [1, 2] {
            _ = controller.controlClearWorkspace(index, confirmIfNeeded: false)
            _ = controller.model.setLayout("scrolling", at: index, columnFactor: controller.columnFactor)
        }
        controller.switchWorkspace(1)
        harness.spin(0.25)
    }

    override func tearDown() {
        let controller = try? harness?.controller
        for index in touched.sorted() {
            _ = controller?.controlClearWorkspace(index, confirmIfNeeded: false)
        }
        harness?.cleanup()
        if let controller {
            controller.switchWorkspace(0)
            if controller.model.allPanes.isEmpty { controller.ensureStarterPane() }
            harness?.spin(0.3)
        }
        for path in temporaries { try? FileManager.default.removeItem(atPath: path) }
        temporaries = []
        touched = []
        harness = nil
        super.tearDown()
    }

    // MARK: 夹具

    private func makeDirectory(_ name: String) throws -> String {
        let path = NSTemporaryDirectory() + "quickterm-size-\(name)-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        temporaries.append(path)
        return URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    @discardableResult
    private func apply(_ text: String, target: String,
                       file: StaticString = #filePath, line: UInt = #line) throws -> ControlReply {
        let reply = try harness.run("spec.apply", target: target, args: ["spec": .string(text)])
        XCTAssertTrue(reply.ok, "apply 失败：\(String(describing: reply.error))", file: file, line: line)
        harness.spin(0.8)
        return reply
    }

    private func dump(_ target: String) throws -> String {
        let reply = try harness.run("spec.dump", target: target)
        XCTAssertTrue(reply.ok, "dump 失败：\(String(describing: reply.error))")
        let spec = try XCTUnwrap(reply.data?["spec"])
        return String(decoding: try ControlJSON.encoder.encode(spec), as: UTF8.self)
    }

    /// `:2`（下标 1）那个工作区的 state
    private func state() throws -> JSONValue {
        let reply = try harness.run("state", target: ":2")
        XCTAssertTrue(reply.ok, "state 失败：\(String(describing: reply.error))")
        return try XCTUnwrap(reply.data)
    }

    private func panes(in state: JSONValue) -> [[String: JSONValue]] {
        (state["panes"]?.arrayValue ?? []).compactMap(\.objectValue)
            .filter { $0["workspace"]?.intValue == 2 }
    }

    private func pane(at path: String, in state: JSONValue) throws -> [String: JSONValue] {
        try XCTUnwrap(panes(in: state).first { $0["at"]?["path"]?.stringValue == path },
                      "state 里没有 at.path = \(path) 的 pane")
    }

    private func workspace(in state: JSONValue) throws -> [String: JSONValue] {
        let screens = try XCTUnwrap(state["screens"]?.arrayValue)
        let workspaces = try XCTUnwrap(screens.first?["workspaces"]?.arrayValue)
        return try XCTUnwrap(workspaces.first { $0["index"]?.intValue == 2 }?.objectValue)
    }

    private func rect(_ pane: [String: JSONValue]) throws -> [Double] {
        let raw = try XCTUnwrap(pane["size"]?["rect"]?.arrayValue, "pane 记录里没有 size.rect")
        return raw.compactMap(\.doubleValue)
    }

    private func assertRect(_ got: [Double], _ want: [Double], _ what: String,
                            file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(got.count, 4, what, file: file, line: line)
        guard got.count == 4 else { return }
        for i in 0..<4 {
            XCTAssertEqual(got[i], want[i], accuracy: 0.0002,
                           "\(what) 的第 \(i) 个分量：\(got) ≠ \(want)", file: file, line: line)
        }
    }

    /// 三片叶子、两条比例都不是 0.5 的 dwindle 工作区：
    /// 根是左右 0.3，右子树是上下 0.7
    @discardableResult
    private func buildDeepTree(target: String = ":2") throws -> String {
        touched.formUnion([1, 2])
        let directory = try makeDirectory("tree")
        let leaf = "{\"pane\":{\"cwd\":\"\(directory)\"}}"
        let text = "{\"layout\":\"dwindle\",\"tree\":{\"split\":\"horizontal\",\"ratio\":0.3,"
            + "\"a\":\(leaf),\"b\":{\"split\":\"vertical\",\"ratio\":0.7,"
            + "\"a\":\(leaf),\"b\":\(leaf)}}}"
        try apply(text, target: target)
        return text
    }

    // MARK: 读得到

    /// dwindle：每个 pane 的归一化矩形、点尺寸、父分裂比例都要与模型对得上。
    /// 期望矩形是按 0.3 / 0.7 手推的，不是再调一次编码器
    func testDwindlePaneSizesMatchTheModel() throws {
        try buildDeepTree()
        let controller = try harness.controller
        let content = try XCTUnwrap(ControlGeometry.contentSize(controller))
        let state = try state()

        let a = try pane(at: "a", in: state)
        let ba = try pane(at: "b.a", in: state)
        let bb = try pane(at: "b.b", in: state)

        assertRect(try rect(a), [0, 0, 0.3, 1], "a")
        assertRect(try rect(ba), [0.3, 0, 0.7, 0.7], "b.a")
        assertRect(try rect(bb), [0.3, 0.7, 0.7, 0.3], "b.b")

        // 父分裂：a 挂在根那条左右分隔条上，b.* 挂在右子树那条上下分隔条上
        XCTAssertEqual(a["size"]?["split"]?.stringValue, "horizontal")
        XCTAssertEqual(a["size"]?["ratio"]?.doubleValue, 0.3)
        XCTAssertEqual(ba["size"]?["split"]?.stringValue, "vertical")
        XCTAssertEqual(ba["size"]?["ratio"]?.doubleValue, 0.7)
        XCTAssertEqual(bb["size"]?["ratio"]?.doubleValue, 0.7)

        // 点尺寸 = 归一化矩形 × 内容区（独立算一遍）
        let points = try XCTUnwrap(ba["size"]?["points"]?.arrayValue).compactMap(\.doubleValue)
        XCTAssertEqual(points[0], 0.7 * Double(content.width), accuracy: 0.2)
        XCTAssertEqual(points[1], 0.7 * Double(content.height), accuracy: 0.2)

        // 终端网格：引擎量过了就要报出来（还没量到就整段没有，不能报个假数）
        if let cols = ba["size"]?["cols"]?.intValue {
            XCTAssertGreaterThan(cols, 0)
            XCTAssertGreaterThan(try XCTUnwrap(ba["size"]?["rows"]?.intValue), 0)
        }
    }

    /// **报出来的点数踩的是 pane 真正铺开的那块地。**
    /// 期望值直接从渲染出来的 NSView 量（`measuredLayoutBox`），与编码器的公式无关。
    /// 曾经拿的是 `window.contentLayoutRect`：横向永远多算一圈外留白，纵向的误差
    /// 还会随 `app set bar off` **变号**——所以这里把状态条关掉再量一遍
    func testReportedPointsStandOnTheAreaThePanesActuallyOccupy() throws {
        try buildDeepTree()
        let controller = try harness.controller
        harness.spin(0.4)

        let measured = try measuredLayoutBox()
        let reported = try XCTUnwrap(ControlGeometry.contentSize(controller))
        XCTAssertEqual(Double(reported.width), Double(measured.width), accuracy: 1.5,
                       "报的宽度不是分裂树铺开的那块地")
        XCTAssertEqual(Double(reported.height), Double(measured.height), accuracy: 1.5,
                       "报的高度不是分裂树铺开的那块地")

        // 单个 pane：槽位 = 它的视图各边外扩一个 pane-gap
        let gap = controller.themeManager.gapsEnabled ? controller.themeManager.paneGap : 0
        let content = try XCTUnwrap(controller.window?.contentView)
        let state = try state()
        let ba = try pane(at: "b.a", in: state)
        let handle = try XCTUnwrap(ba["handle"]?.stringValue)
        let view = try XCTUnwrap(controller.model.layouts[1].paneList.first {
            ControlHandleRegistry.shared.handle(for: $0) == handle
        })
        let slot = view.convert(view.bounds, to: content).insetBy(dx: -gap, dy: -gap)
        let points = try XCTUnwrap(ba["size"]?["points"]?.arrayValue).compactMap(\.doubleValue)
        XCTAssertEqual(points[0], Double(slot.width), accuracy: 1.5, "b.a 的槽位宽")
        XCTAssertEqual(points[1], Double(slot.height), accuracy: 1.5, "b.a 的槽位高")

        // 关掉状态条：布局区正好长高一条状态条的高度（早先这里是反向的）
        controller.model.barVisible = false
        harness.spin(0.5)
        defer { controller.model.barVisible = true }
        let grown = try XCTUnwrap(ControlGeometry.contentSize(controller))
        XCTAssertEqual(Double(grown.height), Double(measured.height) + Double(StatusBarView.height),
                       accuracy: 1.5, "关掉状态条应该正好多出 26pt")
        XCTAssertEqual(Double(grown.height), Double(try measuredLayoutBox().height), accuracy: 1.5,
                       "关掉状态条后报的高度还是要等于量到的高度")
    }

    /// zoom 的时候屏幕上**只有那一片**：其余平铺 pane 一片都不渲染。
    /// 被放大的那片报满整块布局区，看不见的那几片不给 `points`、打 `hidden`。
    /// `rect` / `ratio` 照旧是底下那层平铺——`pane resize` 调的正是它
    func testZoomedWorkspaceDoesNotHandOutPointsForPanesThatAreNotOnScreen() throws {
        try buildDeepTree()
        let controller = try harness.controller
        let zoomedHandle = try handleOfPane(at: "b.a")

        let set = try harness.run("pane.set", target: zoomedHandle, args: ["zoom": .string("on")])
        XCTAssertTrue(set.ok, "zoom 开不起来：\(String(describing: set.error))")
        harness.spin(0.5)

        let state = try state()
        let zoomed = try pane(at: "b.a", in: state)
        let sibling = try pane(at: "b.b", in: state)
        let far = try pane(at: "a", in: state)

        // 被放大的那片：满屏
        let content = try XCTUnwrap(ControlGeometry.contentSize(controller))
        let points = try XCTUnwrap(zoomed["size"]?["points"]?.arrayValue).compactMap(\.doubleValue)
        XCTAssertEqual(points[0], Double(content.width), accuracy: 0.2, "zoom 的那片占满宽")
        XCTAssertEqual(points[1], Double(content.height), accuracy: 0.2, "zoom 的那片占满高")
        XCTAssertNil(zoomed["size"]?["hidden"], "被放大的那片不是被遮住的那一类")

        // 其余的：屏幕上一点位置都没有，不能给点数
        for (name, record) in [("b.b", sibling), ("a", far)] {
            XCTAssertEqual(record["size"]?["hidden"]?.boolValue, true, "\(name) 应该标 hidden")
            XCTAssertNil(record["size"]?["points"], "\(name) 现在 0×0，不该有 points")
        }

        // rect / ratio 仍是底下那层平铺（取消 zoom 就回到它，resize 调的也是它）
        assertRect(try rect(sibling), [0.3, 0.7, 0.7, 0.3], "b.b 的平铺矩形（按 0.3/0.7 手推）")
        XCTAssertEqual(sibling["size"]?["ratio"]?.doubleValue, 0.7, "ratio 照旧是树里那条")
        assertRect(try rect(far), [0, 0, 0.3, 1], "a 的平铺矩形不受 zoom 影响")

        // `get` 单独问某个兄弟时（拿不到工作区上下文）也要看得见这个标记
        let got = try harness.run("get", target: try XCTUnwrap(sibling["handle"]?.stringValue))
        XCTAssertEqual(got.data?["pane"]?["size"]?["hidden"]?.boolValue, true)
        XCTAssertNil(got.data?["pane"]?["size"]?["points"])
    }

    /// 关 pane 的那 0.28 秒里，**树、`at.path` 与每个 pane 的矩形必须是同一个形状**。
    /// 早先树塌了而矩形没塌：`state` 一边说"t1 就是整个工作区"，
    /// 一边给 t1 一个半宽的矩形和一条树里根本不存在的分隔条
    func testGeometryAgreesWithTheReportedTreeWhileAPaneIsFadingOut() throws {
        let pane = try twoPaneTree()
        let controller = try harness.controller
        let survivor = try XCTUnwrap(controller.model.layouts[1].paneList.first { $0 !== pane })

        // 带动画地关（`action close-pane` / shell 退出 / Cmd+W 走的就是这条），不 flush
        controller.closePane(pane, confirmIfNeeded: false, animated: true)
        XCTAssertTrue(controller.model.closingPanes.contains(pane.id), "这时候应该正在淡出")

        let state = try state()
        let workspace = try workspace(in: state)
        // 树塌成幸存者那一片
        XCTAssertEqual(workspace["tree"]?["pane"]?.stringValue,
                       ControlHandleRegistry.shared.handle(for: survivor),
                       "树应该只剩幸存者：\(String(describing: workspace["tree"]))")
        XCTAssertNil(workspace["tree"]?["ratio"], "塌了的树没有分隔条")

        let record = try XCTUnwrap(panes(in: state).first {
            $0["handle"]?.stringValue == ControlHandleRegistry.shared.handle(for: survivor)
        })
        XCTAssertEqual(record["at"]?["path"]?.stringValue, "", "只剩一片叶子，路径就是根")
        assertRect(try rect(record), [0, 0, 1, 1], "只剩一片叶子就该占满工作区")
        XCTAssertNil(record["size"]?["ratio"], "树里已经没有分隔条了，size 也不该报一条")
        XCTAssertNil(record["size"]?["split"])

        controller.flushPendingCloses()
        harness.spin(0.4)
    }

    /// dwindle 的工作区骨架带着**每一条**分隔条的比例，且用的是与 `spec dump` 一模一样的词
    func testStateTreeCarriesEveryRatioInTheSameVocabularyAsSpecDump() throws {
        try buildDeepTree()
        let tree = try XCTUnwrap(try workspace(in: try state())["tree"]?.objectValue,
                                 "dwindle 工作区要给出 tree")
        XCTAssertEqual(tree["split"]?.stringValue, "horizontal")
        XCTAssertEqual(tree["ratio"]?.doubleValue, 0.3)
        XCTAssertEqual(tree["a"]?["pane"]?.stringValue?.isEmpty, false, "叶子装的是句柄")
        let b = try XCTUnwrap(tree["b"]?.objectValue)
        XCTAssertEqual(b["split"]?.stringValue, "vertical")
        XCTAssertEqual(b["ratio"]?.doubleValue, 0.7)

        // 与 spec dump 同一套词：两边的 tree 用同样的键，比例也一致
        let dumped = try dump(":2")
        XCTAssertTrue(dumped.contains("\"split\":\"horizontal\""), dumped)
        XCTAssertTrue(dumped.contains("\"ratio\":0.3"), dumped)
        XCTAssertTrue(dumped.contains("\"ratio\":0.7"), dumped)
    }

    /// scrolling：列宽因子、列内份额、以及横向累加出来的矩形
    func testScrollingSizesReportColumnWidthAndShareWithinTheColumn() throws {
        touched.formUnion([1, 2])
        let directory = try makeDirectory("cols")
        let leaf = "{\"cwd\":\"\(directory)\"}"
        try apply("{\"layout\":\"scrolling\",\"columns\":["
                  + "{\"width\":0.3,\"panes\":[\(leaf)]},"
                  + "{\"width\":0.45,\"panes\":[\(leaf),\(leaf)]}]}", target: ":2")
        let controller = try harness.controller
        guard case .scrolling(let strip) = controller.model.layouts[1] else {
            return XCTFail("这个工作区应该是 scrolling")
        }
        // 有效列宽独立算一遍（装得下时按比例放大填满，与渲染同一套）
        let widths = strip.columnWidths(viewport: 1, gap: 0).map(Double.init)
        XCTAssertEqual(widths.count, 2)

        let state = try state()
        let first = try XCTUnwrap(panes(in: state).first { $0["at"]?["column"]?.intValue == 0 })
        let stackedTop = try XCTUnwrap(panes(in: state).first {
            $0["at"]?["column"]?.intValue == 1 && $0["at"]?["row"]?.intValue == 0
        })
        let stackedBottom = try XCTUnwrap(panes(in: state).first {
            $0["at"]?["column"]?.intValue == 1 && $0["at"]?["row"]?.intValue == 1
        })

        assertRect(try rect(first), [0, 0, widths[0], 1], "第一列")
        assertRect(try rect(stackedTop), [widths[0], 0, widths[1], 0.5], "第二列上")
        assertRect(try rect(stackedBottom), [widths[0], 0.5, widths[1], 0.5], "第二列下")

        // 列宽因子是**模型持有的那个名义值**；份额是列内等分
        XCTAssertEqual(first["size"]?["width"]?.doubleValue, 0.3)
        XCTAssertEqual(first["size"]?["share"]?.doubleValue, 1)
        XCTAssertEqual(stackedTop["size"]?["width"]?.doubleValue, 0.45)
        XCTAssertEqual(stackedTop["size"]?["share"]?.doubleValue, 0.5)
        XCTAssertEqual(stackedBottom["size"]?["share"]?.doubleValue, 0.5)

        // 工作区骨架里的列宽照旧
        let columns = try XCTUnwrap(try workspace(in: state)["columns"]?.arrayValue)
        XCTAssertEqual(columns.first?["width"]?.doubleValue, 0.3)
        XCTAssertEqual(columns.last?["width"]?.doubleValue, 0.45)
    }

    /// `get` 与 `list panes` 与 `state` 报的是同一份尺寸（三条读命令不能各说各的）
    func testGetAndListReportTheSameSizeAsState() throws {
        try buildDeepTree()
        let state = try state()
        let target = try pane(at: "b.a", in: state)
        let handle = try XCTUnwrap(target["handle"]?.stringValue)

        let got = try harness.run("get", target: handle)
        XCTAssertEqual(got.data?["pane"]?["size"], target["size"])

        let listed = try harness.run("list", args: ["what": .string("panes")])
        let row = try XCTUnwrap((listed.data?["panes"]?.arrayValue ?? [])
            .first { $0["handle"]?.stringValue == handle })
        XCTAssertEqual(row["size"], target["size"])
    }

    /// `--fields` 投影：写了 size 才有 size，没写就没有（handle 永远保留）
    func testFieldsProjectionIncludesAndExcludesSize() throws {
        try buildDeepTree()
        let withSize = try harness.run("state", target: ":2",
                                       args: ["fields": .string("handle,size")])
        let one = try XCTUnwrap((withSize.data?["panes"]?.arrayValue ?? []).first?.objectValue)
        XCTAssertNotNil(one["size"], "写了 size 就要给出来")
        XCTAssertNotNil(one["handle"])
        XCTAssertNil(one["title"])
        XCTAssertNil(one["workspace"], "投影只留写下的那几个字段")

        let without = try harness.run("state", target: ":2",
                                      args: ["fields": .string("handle,title")])
        let plain = try XCTUnwrap((without.data?["panes"]?.arrayValue ?? []).first?.objectValue)
        XCTAssertNil(plain["size"], "没写 size 就不该出现")
        XCTAssertNotNil(plain["handle"])
    }

    // MARK: 组合的时候写得下

    /// 深树 + 各不相同的比例：apply 要一条不落地落到模型上
    func testSpecApplyHonoursADeepTreeOfDistinctRatios() throws {
        try buildDeepTree()
        let controller = try harness.controller
        guard case .dwindle(let tree) = controller.model.layouts[1] else {
            return XCTFail("这个工作区应该是 dwindle")
        }
        let splits = ControlGeometry.splits(in: tree, size: ControlGeometry.unit)
        XCTAssertEqual(splits.map(\.path), ["", "b"])
        XCTAssertEqual(splits[0].direction, "horizontal")
        XCTAssertEqual(splits[0].ratio, 0.3, accuracy: 0.0001)
        XCTAssertEqual(splits[1].direction, "vertical")
        XCTAssertEqual(splits[1].ratio, 0.7, accuracy: 0.0001)
    }

    /// 头牌：**非默认**比例的深树 dump → apply → dump 逐字节相同
    func testDumpApplyDumpIsAFixedPointWithNonDefaultNestedRatios() throws {
        try buildDeepTree()
        let controller = try harness.controller
        // 再拖动一条分隔条，让比例带上四位小数（定点规则也一起钉住）
        _ = try harness.run("pane.resize", target: try handleOfPane(at: "a"),
                            args: ["ratio": .string("0.2345")])
        harness.spin(0.3)

        let before = try dump(":2")
        XCTAssertTrue(before.contains("0.2345"), "拖出来的比例要原样进 dump：\(before)")
        XCTAssertTrue(before.contains("0.7"), before)

        touched.insert(2)
        controller.switchWorkspace(2)
        harness.spin(0.3)
        let reply = try harness.run("spec.apply", target: ":3", args: ["spec": .string(before)])
        XCTAssertTrue(reply.ok, "apply 失败：\(String(describing: reply.error))")
        harness.spin(0.9)
        XCTAssertEqual(try dump(":3"), before, "带尺寸的不动点")
    }

    // MARK: 调得动（与鼠标同权）

    /// `--ratio` = 把这条分隔条拖到那个位置：与拖拽手势落在**同一个数**上，
    /// 越界时也夹在同一处（两侧各留 10pt，不是 0.1–0.9）
    func testResizeByRatioLandsWhereTheDividerDragWould() throws {
        let pane = try twoPaneTree()
        let controller = try harness.controller
        let span = try XCTUnwrap(ControlGeometry.contentSize(controller)?.width)

        _ = try harness.run("pane.resize", target: handle(pane), args: ["ratio": .string("0.25")])
        XCTAssertEqual(try rootRatio(), 0.25, accuracy: 0.0005)

        // 同一个位置，改走拖拽那条路（SwiftUI 的分隔条绑定调的就是 handleSplitOperation）
        try drag(dividerAt: 0.4 * span)
        let dragged = try rootRatio()
        _ = try harness.run("pane.resize", target: handle(pane), args: ["ratio": .string("0.4")])
        XCTAssertEqual(try rootRatio(), dragged, accuracy: 0.0005, "同一个目标位置必须落在同一个比例")

        // 夹取：命令行要一个够不到的比例，落点 = 把分隔条拖出左边界的落点
        try drag(dividerAt: -80)
        let clampedByMouse = try rootRatio()
        _ = try harness.run("pane.resize", target: handle(pane), args: ["ratio": .string("0.001")])
        XCTAssertEqual(try rootRatio(), clampedByMouse, accuracy: 0.0005,
                       "命令行不能把分隔条设到鼠标拖不到的位置")
        XCTAssertGreaterThan(try rootRatio(), 0, "夹到的是 10pt，不是 0")
    }

    /// `--points` 就是"把分隔条挪这么多点"：+N 与拖到 (当前位置 + N) 等价
    func testResizeByPointsIsTheSameDragExpressedInPoints() throws {
        let pane = try twoPaneTree()
        let controller = try harness.controller
        let span = try XCTUnwrap(ControlGeometry.contentSize(controller)?.width)

        _ = try harness.run("pane.resize", target: handle(pane), args: ["ratio": .string("0.5")])
        let start = try rootRatio()
        _ = try harness.run("pane.resize", target: handle(pane), args: ["points": .string("+120")])
        let byPoints = try rootRatio()
        XCTAssertEqual(byPoints, start + 120 / Double(span), accuracy: 0.001)

        try drag(dividerAt: CGFloat(start) * span + 120)
        XCTAssertEqual(try rootRatio(), byPoints, accuracy: 0.0005, "点数与拖拽必须同落点")

        // 裸数字 = 把 a 那一侧设成这么多点
        _ = try harness.run("pane.resize", target: handle(pane), args: ["points": .string("400")])
        XCTAssertEqual(try rootRatio(), 400 / Double(span), accuracy: 0.001)
    }

    /// `--dir` = 按一次 ⌘⌃方向键 / ⌘右键拖拽：与 `perform(.resize*)` 落在同一个比例
    func testResizeByDirectionMatchesTheKeyboardAndMouseDragPath() throws {
        let pane = try twoPaneTree()
        let controller = try harness.controller
        _ = try harness.run("pane.resize", target: handle(pane), args: ["ratio": .string("0.5")])
        let start = try rootRatio()

        _ = try harness.run("pane.resize", target: handle(pane),
                            args: ["dir": .string("right"), "points": .string("100")])
        let byCommand = try rootRatio()
        XCTAssertGreaterThan(byCommand, start)

        // 回到起点，改按快捷键（步长同样是 100pt）
        _ = try harness.run("pane.resize", target: handle(pane),
                            args: ["ratio": .string(String(start))])
        controller.requestFocus(to: pane)
        harness.spin(0.3)
        controller.perform(.resizeRight)
        XCTAssertEqual(try rootRatio(), byCommand, accuracy: 0.0005,
                       "命令行的 --dir 与快捷键必须调出同一个比例")
    }

    /// `--split` 够得到祖先那条分隔条（鼠标可以直接拖任意一条）
    func testSplitPathAddressesAnAncestorDivider() throws {
        try buildDeepTree()
        let deep = try handleOfPane(at: "b.b")
        let before = try splits()

        _ = try harness.run("pane.resize", target: deep,
                            args: ["split": .string("root"), "ratio": .string("0.42")])
        let after = try splits()
        XCTAssertEqual(after[0].ratio, 0.42, accuracy: 0.0005, "调的是根那条")
        XCTAssertEqual(after[1].ratio, before[1].ratio, accuracy: 0.0001, "自己的父分裂不该被动")

        let unknown = try harness.run("pane.resize", target: deep,
                                      args: ["split": .string("a.a"), "ratio": .string("0.5")])
        XCTAssertFalse(unknown.ok)
        XCTAssertEqual(unknown.error?.code, ControlErrorCode.notFound.rawValue)
        XCTAssertEqual(Set(unknown.error?.candidates ?? []), ["root", "b"],
                       "报不出来的时候要把有哪几条列出来")
    }

    /// `--dir` 与 `--split` 一起给 = 报错，**不是**悄悄按 `--dir` 去调另一条分隔条。
    /// 悄悄改道是控制面最不能犯的那种错：agent 以为自己调了根那条，实际调的是别的一条
    func testDirectionAndSplitTogetherIsRejectedInsteadOfRetargeting() throws {
        try buildDeepTree()
        let deep = try handleOfPane(at: "b.b")
        let before = try splits().map(\.ratio)

        let reply = try harness.run("pane.resize", target: deep,
                                    args: ["split": .string("root"), "dir": .string("right"),
                                           "points": .string("100")])
        XCTAssertFalse(reply.ok, "--split 配 --dir 应该报错")
        XCTAssertEqual(reply.error?.code, ControlErrorCode.badRequest.rawValue)
        XCTAssertEqual(try splits().map(\.ratio), before, "报错了就一条分隔条都不许动")
    }

    /// 绝对形式幂等（第二次是空操作，--fail-if-noop 退 7），`--dry-run` 一个字节都不改
    func testAbsoluteResizeIsIdempotentAndDryRunChangesNothing() throws {
        let pane = try twoPaneTree()
        let controller = try harness.controller

        _ = try harness.run("pane.resize", target: handle(pane), args: ["ratio": .string("0.4")])
        XCTAssertEqual(try rootRatio(), 0.4, accuracy: 0.0005)
        let again = try harness.run("pane.resize", target: handle(pane),
                                    args: ["ratio": .string("0.4"),
                                           ControlCommandTable.Flag.failIfNoop: .bool(true)])
        XCTAssertEqual(again.error?.code, ControlErrorCode.noop.rawValue, "同样的绝对值再来一次什么都不该改")

        let fingerprint = try harness.fingerprint(controller)
        let dry = try harness.run("pane.resize", target: handle(pane),
                                  args: ["ratio": .string("0.8"),
                                         ControlCommandTable.Flag.dryRun: .bool(true)])
        XCTAssertTrue(dry.ok)
        XCTAssertEqual(dry.data?["changed"]?.boolValue, true, "预演也要如实说它会改什么")
        XCTAssertEqual(dry.data?["applied"]?.boolValue, false)
        XCTAssertEqual(try harness.fingerprint(controller), fingerprint, "--dry-run 不许动一个字节")
        XCTAssertEqual(try rootRatio(), 0.4, accuracy: 0.0005)
    }

    /// 变更回声里带着新的尺寸（省掉 agent 调完再读一次）
    func testResizeEchoesTheNewSize() throws {
        let pane = try twoPaneTree()
        let payload = try harness.mutation(try harness.run(
            "pane.resize", target: handle(pane), args: ["ratio": .string("0.35")]))
        XCTAssertEqual(payload["pane"]?["size"]?["ratio"]?.doubleValue, 0.35)
        let change = try XCTUnwrap(payload["changes"]?.arrayValue?.first)
        XCTAssertEqual(change["path"]?.stringValue, "1:2.tree.ratio",
                       "diff 的路径要和 state 里的 JSON 同形")
        let workspace = try XCTUnwrap(payload["workspace"]?["tree"]?["ratio"]?.doubleValue)
        XCTAssertEqual(workspace, 0.35, accuracy: 0.0005)
    }

    // MARK: 零件

    private func handle(_ pane: PaneView) -> String { ControlHandleRegistry.shared.handle(for: pane) }

    private func handleOfPane(at path: String) throws -> String {
        try XCTUnwrap(pane(at: path, in: try state())["handle"]?.stringValue)
    }

    private func splits() throws -> [ControlGeometry.SplitSlot] {
        let controller = try harness.controller
        guard case .dwindle(let tree) = controller.model.layouts[1] else { return [] }
        return ControlGeometry.splits(in: tree, size: ControlGeometry.unit)
    }

    private func rootRatio() throws -> Double {
        try XCTUnwrap(try splits().first(where: { $0.path == "" })?.ratio)
    }

    /// 两片叶子的 dwindle（根上一条左右分隔条），返回其中一片
    private func twoPaneTree() throws -> PaneView {
        touched.formUnion([1, 2])
        let directory = try makeDirectory("two")
        let leaf = "{\"pane\":{\"cwd\":\"\(directory)\"}}"
        try apply("{\"layout\":\"dwindle\",\"tree\":{\"split\":\"horizontal\",\"ratio\":0.5,"
                  + "\"a\":\(leaf),\"b\":\(leaf)}}", target: ":2")
        let controller = try harness.controller
        return try XCTUnwrap(controller.model.layouts[1].paneList.first)
    }

    /// 走**真正的**拖分隔条那条路：SwiftUI 的绑定把落点换算成比例（`SplitViewMetrics.ratio`），
    /// 再交给 `handleSplitOperation(.resize)`。
    /// 换算的底取自**量出来的**布局区（`measuredLayoutBox`），不是 `ControlGeometry`——
    /// 拿被测者自己的数当拖拽的底，"命令行与鼠标同落点"就退化成了它跟自己一致
    private func drag(dividerAt points: CGFloat) throws {
        let controller = try harness.controller
        guard case .dwindle(let tree) = controller.model.layouts[1], let root = tree.root else {
            return XCTFail("这个工作区应该是 dwindle")
        }
        let span = try measuredLayoutBox().width
        controller.switchWorkspace(1)
        controller.handleSplitOperation(.resize(.init(
            node: root, ratio: Double(SplitViewMetrics.ratio(dividerAt: points, in: span)))))
        harness.spin(0.2)
    }

    /// 直接量**渲染出来的那几个 pane 的 NSView**，反推分裂树真正铺开的那块地：
    /// 每个 pane 的视图 = 它的槽位各边缩进一个 pane-gap（`PaneChrome` 的 padding），
    /// 把它们并起来再外扩一个 gap 就是布局区。
    /// 期望值绝不能再走 `ControlGeometry`——那只是拿编码器和它自己比
    private func measuredLayoutBox(file: StaticString = #filePath,
                                   line: UInt = #line) throws -> CGRect {
        let controller = try harness.controller
        let content = try XCTUnwrap(controller.window?.contentView, file: file, line: line)
        let gap = controller.themeManager.gapsEnabled ? controller.themeManager.paneGap : 0
        var union: CGRect?
        for pane in controller.model.layouts[1].paneList {
            guard pane.window != nil, pane.superview != nil else { continue }
            let frame = pane.convert(pane.bounds, to: content)
            guard frame.width > 1, frame.height > 1 else { continue }
            union = union.map { $0.union(frame) } ?? frame
        }
        let box = try XCTUnwrap(union, "一个 pane 都没挂在窗口上，量不到真实布局",
                                file: file, line: line)
        return box.insetBy(dx: -gap, dy: -gap)
    }
}
