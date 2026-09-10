import XCTest
@testable import QuickTerm

/// Phase 3 的**落地**这一半：`spec dump` / `spec apply` 打在活着的屏幕上。
///
/// 头牌用例是 `dump → apply → dump` 的**不动点**：一份 dump 出来的 spec 落到另一个工作区，
/// 再 dump 出来必须逐字节相同。它一条就盖住了投影对的两个方向、默认值展开、
/// 列宽 / zoom / 焦点的往返，以及"apply 不是照着 spec 猜一个差不多的布局"。
///
/// 用例一律在**空工作区**里搭场景（`:2` / `:3`），不碰 1 号工作区里那个起步 pane——
/// 否则每条用例的 pane 数都取决于前面哪条用例先跑。
@MainActor
final class ControlSpecApplyTests: XCTestCase {
    private var harness: ControlHarness!
    private var temporaries: [String] = []
    /// 用例碰过的工作区：tearDown 一律清空（spec apply 建出来的 pane 不在 harness 的账上）
    private var touched: Set<Int> = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        harness = try ControlHarness()
        let controller = try harness.controller
        try XCTSkipUnless(controller.model.layouts.count >= 3, "本组用例要三个工作区")
        // 每条用例都从"空的 scrolling 工作区"起步：上一条用例把 :2 设成 dwindle 之后，
        // 下一条的不动点会莫名其妙地对着一棵树跑（用例之间绝不共享布局状态）
        for index in [1, 2] {
            _ = controller.controlClearWorkspace(index, confirmIfNeeded: false)
            _ = controller.model.setLayout("scrolling", at: index, columnFactor: controller.columnFactor)
        }
        controller.switchWorkspace(1)
        harness.spin(0.2)
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
        let path = NSTemporaryDirectory() + "quickterm-spec-\(name)-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        temporaries.append(path)
        return URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    /// `spec dump` 的正文（就是要写进文件、再喂回 apply 的那一份）
    private func dump(_ target: String?, args: [String: JSONValue] = [:],
                      file: StaticString = #filePath, line: UInt = #line) throws -> String {
        let reply = try harness.run("spec.dump", target: target, args: args)
        XCTAssertTrue(reply.ok, "dump 失败：\(String(describing: reply.error))", file: file, line: line)
        let spec = try XCTUnwrap(reply.data?["spec"], "dump 没有给出 spec", file: file, line: line)
        return String(decoding: try ControlJSON.encoder.encode(spec), as: UTF8.self)
    }

    @discardableResult
    private func apply(_ text: String, target: String?, mode: String? = nil,
                       extra: [String: JSONValue] = [:]) throws -> ControlReply {
        var args: [String: JSONValue] = ["spec": .string(text)]
        if let mode { args[mode] = .bool(true) }
        for (key, value) in extra { args[key] = value }
        return try harness.run("spec.apply", target: target, args: args)
    }

    @discardableResult
    private func newPane(_ args: [String: JSONValue], target: String? = nil) throws -> PaneView {
        let before = Set(harness.app.screens.allPanes.map(\.id))
        let reply = try harness.run("pane.new", target: target, args: args)
        XCTAssertTrue(reply.ok, "pane new 失败：\(String(describing: reply.error))")
        harness.spin(0.35)
        let pane = try XCTUnwrap(harness.app.screens.allPanes.first { !before.contains($0.id) })
        harness.track(pane)
        return pane
    }

    private func panes(_ workspace: Int) throws -> [PaneView] {
        let controller = try harness.controller
        return controller.model.layouts[workspace].paneList
            + controller.model.floatings[workspace].map(\.pane)
    }

    private func handle(_ pane: PaneView) -> String { ControlHandleRegistry.shared.handle(for: pane) }

    // MARK: 头牌：不动点

    /// scrolling：一份 dump 落进另一个（空）工作区，再 dump 出来必须逐字节相同。
    /// **落进另一个工作区**是有意的：落回原处会走"整份一模一样 = 空操作"那条路，
    /// 而那条路证明不了 apply 真的能把布局从零搭出来
    func testDumpApplyDumpIsAFixedPointForScrolling() throws {
        let controller = try harness.controller
        touched.formUnion([1, 2])
        let a = try makeDirectory("a")
        let b = try makeDirectory("b")
        let first = try newPane(["cwd": .string(a)])
        _ = try newPane(["cwd": .string(b), "at": .string(handle(first)), "where": .string("stack")])
        _ = try newPane(["cwd": .string(a)])
        _ = try harness.run("pane.set", target: handle(first), args: ["width": .double(0.35)])
        harness.spin(0.5)

        let before = try dump(":2")
        XCTAssertTrue(before.contains("\"columns\""), before)
        XCTAssertTrue(before.contains("0.35"), "列宽要进 spec：\(before)")
        let sourceCount = try panes(1).count

        controller.switchWorkspace(2)
        harness.spin(0.3)
        try apply(before, target: ":3").assertOK()
        harness.spin(0.8)

        XCTAssertEqual(try panes(2).count, sourceCount, "落地的 pane 数要对上")
        XCTAssertEqual(try dump(":3"), before, "dump → apply → dump 必须是不动点")
    }

    /// dwindle：同一条不动点，换一种布局引擎（分裂方向与比例都要往返）
    func testDumpApplyDumpIsAFixedPointForDwindle() throws {
        let controller = try harness.controller
        touched.formUnion([1, 2])
        _ = try harness.run("workspace.set-layout", target: ":2", args: ["layout": .string("dwindle")])
        let a = try makeDirectory("d1")
        let b = try makeDirectory("d2")
        _ = try newPane(["cwd": .string(a)])
        let second = try newPane(["cwd": .string(b)])
        _ = try harness.run("pane.set", target: handle(second), args: ["ratio": .double(0.4)])
        harness.spin(0.5)

        let before = try dump(":2")
        XCTAssertTrue(before.contains("\"tree\""), before)
        XCTAssertTrue(before.contains("\"ratio\""), before)

        controller.switchWorkspace(2)
        harness.spin(0.3)
        try apply(before, target: ":3").assertOK()
        harness.spin(0.8)

        XCTAssertEqual(controller.model.layouts[2].name, "dwindle", "apply 要把布局也设过去")
        XCTAssertEqual(try dump(":3"), before, "dwindle 的不动点")
    }

    /// 两行 spec：默认值全部补齐（kind=terminal、宽度按每屏可见列数、cwd 继承锚点）
    func testMinimalSpecAppliesWithEveryDefaultFilledIn() throws {
        let controller = try harness.controller
        touched.insert(1)
        try apply(#"{"columns":[{"panes":[{}]},{"panes":[{},{}]}]}"#, target: ":2").assertOK()
        harness.spin(0.6)

        guard case .scrolling(let strip) = controller.model.layouts[1] else {
            return XCTFail("默认布局应该是 scrolling")
        }
        XCTAssertEqual(strip.columns.map(\.panes.count), [1, 2])
        for column in strip.columns {
            XCTAssertEqual(column.widthFactor, controller.columnFactor, accuracy: 0.0005,
                           "不写 width 就用当前的每屏可见列数")
        }
        XCTAssertTrue(strip.paneList.allSatisfy { $0 is Ghostty.SurfaceView }, "不写 kind 就是终端")
    }

    // MARK: --dry-run

    /// `--dry-run` **一个字节都不改**：拿存档路径的字节级指纹做基准
    func testDryRunMutatesNothing() throws {
        let controller = try harness.controller
        touched.insert(1)
        let before = try harness.fingerprint(controller)
        let reply = try apply(#"{"columns":[{"panes":[{}]},{"panes":[{}]}]}"#, target: ":2",
                              extra: [ControlCommandTable.Flag.dryRun: .bool(true)])
        let payload = try harness.mutation(reply)
        XCTAssertEqual(payload["applied"]?.boolValue, false)
        XCTAssertEqual(payload["changed"]?.boolValue, true)
        XCTAssertFalse((payload["changes"]?.arrayValue ?? []).isEmpty, "预演要给出可读的 diff")
        harness.spin(0.3)
        XCTAssertEqual(try harness.fingerprint(controller), before, "--dry-run 之后模型必须一模一样")
        XCTAssertTrue(try panes(1).isEmpty, "预演不许建 pane")
    }

    // MARK: 三种模式

    /// `--into-empty` 是默认模式，它**毁不掉任何东西**：非空目标一律拒绝（退出码 4）
    func testIntoEmptyRefusesANonEmptyWorkspace() throws {
        touched.insert(1)
        _ = try newPane([:])
        harness.spin(0.3)
        let reply = try apply(#"{"columns":[{"panes":[{}]}]}"#, target: ":2")
        XCTAssertFalse(reply.ok)
        let error = try XCTUnwrap(reply.error)
        XCTAssertEqual(error.code, ControlErrorCode.confirmationRequired.rawValue)
        XCTAssertEqual(error.exit, ControlExit.confirmationRequired.rawValue)
        XCTAssertTrue((error.hint ?? "").contains("--replace"), "要告诉调用方去哪儿：\(error.hint ?? "")")
        XCTAssertEqual(try panes(1).count, 1, "被拒的那一次什么都不许动")
    }

    /// `--replace` 顶掉的 pane 必须走**真正的关闭路径**。
    /// 浏览器 pane 是这条规则的试金石：按赋值替换掉它的话 `paneWillClose()` 不会跑，
    /// 下载不取消、扩展也收不到「窗口关了」——而且没有任何别的用例会红
    func testReplaceRoutesDisplacedPanesThroughTheRealClosePath() throws {
        touched.insert(1)
        let browser = try XCTUnwrap(try newPane(["kind": .string("browser"),
                                                 "url": .string("about:blank")]) as? BrowserPaneView)
        harness.spin(0.5)
        XCTAssertFalse(browser.reportedWindowClose, "前提：还没跑过收尾")

        let directory = try makeDirectory("replace")
        try apply("{\"columns\":[{\"panes\":[{\"cwd\":\"\(directory)\"}]}]}", target: ":2",
                  mode: "replace").assertOK()
        harness.spin(0.6)

        XCTAssertTrue(browser.reportedWindowClose,
                      "被顶掉的浏览器 pane 必须跑过 paneWillClose（否则下载与扩展窗口事件就此泄漏）")
        XCTAssertFalse(try panes(1).contains { $0 === browser }, "它不该还在布局里")
        XCTAssertEqual(try panes(1).count, 1)
    }

    /// `--reuse` 认得出"还是那个东西"：跑着的 pane 原地留着，不重建
    func testReuseKeepsMatchingPanesAndOnlyRebuildsTheRest() throws {
        touched.insert(1)
        let keepDirectory = try makeDirectory("keep")
        let dropDirectory = try makeDirectory("drop")
        let freshDirectory = try makeDirectory("fresh")
        let keeper = try newPane(["cwd": .string(keepDirectory)])
        let victim = try newPane(["cwd": .string(dropDirectory)])
        harness.spin(0.5)

        let text = """
        {"columns":[{"panes":[{"cwd":"\(keepDirectory)"}]},{"panes":[{"cwd":"\(freshDirectory)"}]}]}
        """
        let payload = try harness.mutation(try apply(text, target: ":2", mode: "reuse"))
        harness.spin(0.6)

        let report = try XCTUnwrap(payload["spec"]?.objectValue, "apply 要给出落地报告")
        XCTAssertEqual(report["mode"]?.stringValue, "reuse")
        let live = try panes(1)
        XCTAssertTrue(live.contains { $0 === keeper }, "对得上的 pane 必须原地留着，不能被重建")
        XCTAssertFalse(live.contains { $0 === victim }, "对不上的那个要被关掉")
        XCTAssertEqual((report["reused"]?.arrayValue ?? []).count, 1)
        XCTAssertEqual((report["created"]?.arrayValue ?? []).count, 1)
        XCTAssertEqual((report["closed"]?.arrayValue ?? []).count, 1)
    }

    /// 同一份 spec 落两次，第二次在布局上就是空操作（`--fail-if-noop` 下退 7），
    /// 而且**一个 pane 都不许重建**——否则 agent 每重试一次就把 dev server 重启一次
    func testApplyingTheSameSpecTwiceIsALayoutNoop() throws {
        touched.insert(1)
        let directory = try makeDirectory("twice")
        _ = try newPane(["cwd": .string(directory)])
        harness.spin(0.5)
        let text = try dump(":2")
        let identities = try panes(1).map(ObjectIdentifier.init)

        try apply(text, target: ":2", mode: "replace").assertOK()
        harness.spin(0.5)
        XCTAssertEqual(try panes(1).map(ObjectIdentifier.init), identities,
                       "整份一模一样时 --replace 不许拆了重建")

        let again = try apply(text, target: ":2", mode: "replace",
                              extra: [ControlCommandTable.Flag.failIfNoop: .bool(true)])
        XCTAssertFalse(again.ok)
        XCTAssertEqual(again.error?.code, ControlErrorCode.noop.rawValue)
        XCTAssertEqual(again.error?.exit, ControlExit.noop.rawValue)
    }

    // MARK: 失败的形状

    /// 校验不过 = **一个 pane 都不建**。第二格的目录不存在，
    /// 而它是在建任何东西之前就被查出来的
    func testASpecThatFailsPreflightCreatesNothing() throws {
        touched.insert(1)
        let good = try makeDirectory("good")
        let reply = try apply(
            "{\"columns\":[{\"panes\":[{\"cwd\":\"\(good)\"}]},{\"panes\":[{\"cwd\":\"/no/such/dir\"}]}]}",
            target: ":2")
        XCTAssertFalse(reply.ok)
        XCTAssertEqual(reply.error?.code, ControlErrorCode.badRequest.rawValue)
        XCTAssertTrue((reply.error?.message ?? "").contains("/no/such/dir"), reply.error?.message ?? "")
        harness.spin(0.3)
        XCTAssertTrue(try panes(1).isEmpty, "预检失败绝不能留下半个工作区")
    }

    /// 落刀**之后**才失败：状态是自洽的（布局里没有幽灵 pane），而且如实报 partial_apply。
    /// 注入点是 `SpecApplier.fault`（生产恒为 nil）——这条路没有别的办法走到
    func testMidApplyFailureLeavesACoherentStateAndReportsPartial() throws {
        let controller = try harness.controller
        touched.insert(1)
        _ = try newPane([:])
        _ = try newPane([:])
        harness.spin(0.5)
        XCTAssertEqual(try panes(1).count, 2, "前提：工作区里正好两个 pane")
        let directory = try makeDirectory("partial")
        guard case .workspace(let spec) = try SpecParser.parse(
            "{\"columns\":[{\"panes\":[{\"cwd\":\"\(directory)\"}]}]}") else {
            return XCTFail("spec 解析失败")
        }

        let applier = SpecApplier(controller: controller, workspace: 1, spec: spec, mode: .replace)
        applier.fault = { stage in
            guard stage == .tearingDown else { return }
            throw ControlErrorBody(.failed, "注入的失败")
        }
        try applier.preflight()
        XCTAssertEqual(applier.displaced.count, 2, "前提：两个 pane 都要被顶掉")

        XCTAssertThrowsError(try applier.apply()) { error in
            let body = error as? ControlErrorBody
            XCTAssertEqual(body?.code, ControlErrorCode.partialApply.rawValue,
                           "落刀之后失败要有自己的错误码，绝不能报成「什么都没发生」")
            XCTAssertTrue((body?.message ?? "").contains("一半"), body?.message ?? "")
        }
        harness.spin(0.5)

        // 自洽：布局里剩下的每一个 pane 都还活着、还能被寻址；建了一半的那个没有混进来
        let live = try panes(1)
        XCTAssertEqual(live.count, 1, "被关掉的那一个真的走了，剩下的原样还在")
        XCTAssertTrue(live.allSatisfy { !controller.model.closingPanes.contains($0.id) })
        XCTAssertFalse(live.contains { $0.workingDirectory == directory },
                       "新建到一半的 pane 已经被收掉，绝不能留在布局里")
        XCTAssertEqual(Set(controller.model.allPanes.map(\.id)).count,
                       controller.model.allPanes.count, "不能有重复引用")
    }

    // MARK: 结构

    /// **一次赋值**：一次 apply 只排一次防抖存档。分五次赋值就是五次重排、五次动画、
    /// 五遍 Combine sink——用户看到的是新建三个 pane 时布局抖三下
    func testASingleApplyAssignsTheLayoutExactlyOnce() throws {
        let store = try XCTUnwrap(harness.app.session).sessionStore
        touched.insert(1)
        harness.spin(0.4)
        let before = store.scheduleCount
        try apply(#"{"columns":[{"panes":[{}]},{"panes":[{}]},{"panes":[{}]}]}"#, target: ":2").assertOK()
        XCTAssertEqual(store.scheduleCount - before, 1,
                       "三个 pane、一次赋值：先把整个布局值算完再赋给 model.layouts[i]")
        harness.spin(0.6)
    }

    /// 列的身份要沿用：`ScrollingStrip.Column.id` 一变，SwiftUI 会重建整列，
    /// 列里的 SurfaceView 脱离再重挂（闪一帧、first responder 被静默重置）
    func testColumnIdentitiesSurviveAReapply() throws {
        let controller = try harness.controller
        touched.insert(1)
        let directory = try makeDirectory("ids")
        _ = try newPane(["cwd": .string(directory)])
        harness.spin(0.5)
        guard case .scrolling(let before) = controller.model.layouts[1] else {
            return XCTFail("前提：scrolling")
        }
        let text = try dump(":2")
        try apply(text, target: ":2", mode: "reuse").assertOK()
        harness.spin(0.5)
        guard case .scrolling(let after) = controller.model.layouts[1] else {
            return XCTFail("布局变了")
        }
        XCTAssertEqual(before.columns.map(\.id), after.columns.map(\.id),
                       "pane 集合没变的列必须保住原来的 id")
    }

    // MARK: 两个信封

    /// `quickterm.screen/1` / `quickterm.session/1` 原样复用工作区那一份词汇：
    /// 两者都要能 dump → apply → dump 回到原样
    func testScreenAndSessionWrappersRoundTrip() throws {
        touched.insert(1)
        let directory = try makeDirectory("wrap")
        _ = try newPane(["cwd": .string(directory)])
        harness.spin(0.5)

        let screen = try dump("1")
        XCTAssertTrue(screen.contains(SpecSchema.screen), screen)
        try apply(screen, target: "1", mode: "replace").assertOK()
        harness.spin(0.6)
        XCTAssertEqual(try dump("1"), screen, "屏幕信封的往返")

        let session = try dump(nil, args: ["all": .bool(true)])
        XCTAssertTrue(session.contains(SpecSchema.session), session)
        try apply(session, target: nil, mode: "replace").assertOK()
        harness.spin(0.6)
        XCTAssertEqual(try dump(nil, args: ["all": .bool(true)]), session, "会话信封的往返")
    }

    /// `spec validate` 什么都不改，而且认得出"这台机器上没有那么多工作区"
    func testValidateChecksWorkspaceCountsAndChangesNothing() throws {
        let controller = try harness.controller
        let before = try harness.fingerprint(controller)
        let ok = try harness.run("spec.validate", args: ["spec": .string(#"{"columns":[{}]}"#)])
        XCTAssertTrue(ok.ok, String(describing: ok.error))
        XCTAssertEqual(ok.data?["valid"]?.boolValue, true)

        let count = controller.model.layouts.count
        let tooMany = try harness.run("spec.validate", args: ["spec": .string(
            "{\"schema\":\"quickterm.screen/1\",\"workspaces\":[{\"index\":\(count + 3)}]}")])
        XCTAssertFalse(tooMany.ok)
        XCTAssertTrue((tooMany.error?.message ?? "").contains("\(count)"),
                      "越界要说出这台机器上到底有几个：\(tooMany.error?.message ?? "")")
        XCTAssertEqual(try harness.fingerprint(controller), before, "validate 什么都不许改")
    }

    /// `cmd` / `env` / `hold` 是只进不出的：dump 回吐不了一个正在跑的命令，
    /// validate 要把这件事明说，免得 agent 以为自己 dump 到了一份能重跑的东西
    func testValidateNotesThatCommandsAreInputOnly() throws {
        let reply = try harness.run("spec.validate", args: ["spec": .string(
            #"{"columns":[{"panes":[{"cmd":"npm run dev"}]}]}"#)])
        XCTAssertTrue(reply.ok)
        let notes = (reply.data?["notes"]?.arrayValue ?? []).compactMap(\.stringValue)
        XCTAssertTrue(notes.contains { $0.contains("cmd") }, "\(notes)")
    }

    // MARK: 回归：这一批都曾经是"报成功、其实什么都没做"

    /// 不动点在**每一个可见列数**上都要成立。`setVisibleColumns` 把所有列等分成
    /// (1−2×peek)/N：N=4 是 0.2425、N=1 是 0.97，两个都在手动调宽的 0.25–0.90 之外——
    /// 公开 schema 照抄那一份的话，QuickTerm 会拒读 QuickTerm 刚 dump 出来的文件
    func testFixedPointHoldsAtEveryVisibleColumnCount() throws {
        let controller = try harness.controller
        touched.formUnion([1, 2])
        let restore = controller.visibleColumns
        defer { controller.setVisibleColumns(restore, persist: false) }
        let directory = try makeDirectory("cols")
        _ = try newPane(["cwd": .string(directory)])
        _ = try newPane(["cwd": .string(directory)])
        harness.spin(0.5)

        for count in [4, 1] {
            // 焦点只有**活动**工作区才进 spec：两次 dump 要在各自活动的时候取，
            // 否则差的是"谁拿焦点"，与列宽无关
            controller.switchWorkspace(1)
            controller.setVisibleColumns(count, persist: false)
            harness.spin(0.4)
            let text = try dump(":2")
            // 自己 dump 出来的东西，自己必须收得下
            let check = try harness.run("spec.validate", args: ["spec": .string(text)])
            XCTAssertTrue(check.ok,
                          "每屏 \(count) 列的 dump 被自己的校验拒了：\(String(describing: check.error))")

            _ = try harness.run("workspace.clear", target: ":3")
            controller.switchWorkspace(2)
            harness.spin(0.4)
            try apply(text, target: ":3").assertOK()
            harness.spin(0.8)
            XCTAssertEqual(try dump(":3"), text, "每屏 \(count) 列时的不动点")
        }
    }

    /// **只动排布**的 spec（pane 一个不多一个不少，只是重新分组）必须真的落下去。
    /// diff 空掉的话 `commit()` 根本不会调 apply：工作区原样不动，回给调用方的却是
    /// "已经是这个样子了"——agent 手里那份"我摆好了"的认知从此是错的
    func testRearrangingTheSamePanesIsNotANoop() throws {
        let controller = try harness.controller
        touched.insert(1)
        let a = try makeDirectory("arr-a")
        let b = try makeDirectory("arr-b")
        _ = try newPane(["cwd": .string(a)])
        _ = try newPane(["cwd": .string(b)])
        harness.spin(0.5)
        guard case .scrolling(let before) = controller.model.layouts[1] else {
            return XCTFail("前提：两列各一个 pane")
        }
        XCTAssertEqual(before.columns.map(\.panes.count), [1, 1])
        let identities = Set(try panes(1).map(ObjectIdentifier.init))

        // 两列并成一列：pane 集合一模一样，只是分组变了
        let text = "{\"columns\":[{\"panes\":[{\"cwd\":\"\(a)\"},{\"cwd\":\"\(b)\"}]}]}"
        let payload = try harness.mutation(try apply(text, target: ":2", mode: "reuse"))
        XCTAssertEqual(payload["changed"]?.boolValue, true, "排布变了就是变了")
        harness.spin(0.6)

        guard case .scrolling(let after) = controller.model.layouts[1] else { return XCTFail("布局没了") }
        XCTAssertEqual(after.columns.map(\.panes.count), [2], "两列真的并成了一列")
        XCTAssertEqual(Set(try panes(1).map(ObjectIdentifier.init)), identities,
                       "并列不许重建 pane（跑着的进程要原地留着）")

        // 再落一次才是真的空操作
        let again = try apply(text, target: ":2", mode: "reuse",
                              extra: [ControlCommandTable.Flag.failIfNoop: .bool(true)])
        XCTAssertFalse(again.ok)
        XCTAssertEqual(again.error?.code, ControlErrorCode.noop.rawValue)
    }

    /// `dump --include-ids` → 改一个 cwd → `apply --replace`：id 是"就要这一个 pane"的
    /// 指名道姓，只有 `--reuse` 认它。别的模式下认 id 的后果是每一格都靠 id 对上、
    /// 改动被整份丢掉，还报成"已经是这个样子了"
    func testEditingADumpWithIDsIsNotSwallowedByIDMatching() throws {
        touched.insert(1)
        let from = try makeDirectory("ids-from")
        let to = try makeDirectory("ids-to")
        let original = try newPane(["cwd": .string(from)])
        harness.spin(0.5)
        let text = try dump(":2", args: ["include-ids": .bool(true)])
        XCTAssertTrue(text.contains(original.id.uuidString), "前提：dump 里带着 id")
        let edited = text.replacingOccurrences(of: from, with: to)

        let payload = try harness.mutation(try apply(edited, target: ":2", mode: "replace"))
        XCTAssertEqual(payload["changed"]?.boolValue, true, "改过的 spec 不是空操作")
        harness.spin(0.8)
        let live = try panes(1)
        XCTAssertEqual(live.count, 1)
        XCTAssertFalse(live.contains { $0 === original }, "旧 pane 该被顶掉")
        XCTAssertEqual(live.first?.workingDirectory, to, "新 pane 落在改过的目录里")
        for pane in live { harness.track(pane) }
    }

    /// 同一个工作区在一份 spec 里写两次：**在建任何东西之前**就拒掉。
    /// 放行的话第二份的 `model.layouts[i] = …` 会按赋值盖掉第一份，
    /// 第一份建出来的 pane 既不在任何布局里、也没走过关闭路径（下载、扩展、文件管理器会话全泄漏）
    func testDuplicateWorkspaceIndicesAreRefusedBeforeAnythingIsCreated() throws {
        touched.insert(1)
        let directory = try makeDirectory("dup")
        let text = """
        {"schema":"quickterm.screen/1","workspaces":[
          {"index":2,"columns":[{"panes":[{"cwd":"\(directory)"}]}]},
          {"index":2,"columns":[{"panes":[{"cwd":"\(directory)"}]}]}]}
        """
        let reply = try apply(text, target: "1", mode: "replace")
        XCTAssertFalse(reply.ok)
        XCTAssertEqual(reply.error?.code, ControlErrorCode.badRequest.rawValue)
        XCTAssertTrue((reply.error?.message ?? "").contains("只能写一次"), reply.error?.message ?? "")
        harness.spin(0.4)
        XCTAssertTrue(try panes(1).isEmpty, "被拒的那一次一个 pane 都不许建")
    }

    /// 破坏性确认框上写的必须是**这一刀真的会动到的东西**。一份屏幕 spec 覆盖整块屏幕的
    /// 每一个工作区，确认框却只说 `-t` 指的那一个的话，用户批准的是一件小得多的事
    func testConsentNamesEveryWorkspaceAScreenSpecWillOverwrite() throws {
        let controller = try harness.controller
        touched.insert(1)
        _ = try newPane([:])
        harness.spin(0.4)
        var summaries: [String] = []
        harness.consent.decisionStub = { request, reply in
            summaries.append(request.summary)
            reply(.allow)
        }
        let screen = try dump("1")
        try apply(screen, target: "1", mode: "replace").assertOK()
        harness.spin(0.6)
        let summary = try XCTUnwrap(summaries.first, "破坏性命令没有走确认闸门")
        XCTAssertTrue(summary.contains("\(controller.model.layouts.count) 个工作区"),
                      "确认框要说清这一刀横跨几个工作区：\(summary)")
    }

    /// 拖出来的极端分裂比例要**如实**进 spec：夹进 0.1–0.9 的话这份 dump 描述的
    /// 就不是这个工作区，apply 回去分隔条还会自己跳一下（而 diff 看不见）
    func testExtremeSplitRatiosRoundTripWithoutClamping() throws {
        let controller = try harness.controller
        touched.formUnion([1, 2])
        _ = try harness.run("workspace.set-layout", target: ":2", args: ["layout": .string("dwindle")])
        // 两片叶子都写死 cwd：不写的话新 pane 继承的是**锚点**目录，而两个工作区的锚点不是同一个
        let directory = try makeDirectory("ratio")
        let leaf = "{\"pane\":{\"cwd\":\"\(directory)\"}}"
        try apply("{\"layout\":\"dwindle\",\"tree\":{\"split\":\"horizontal\",\"ratio\":0.05,"
                  + "\"a\":\(leaf),\"b\":\(leaf)}}", target: ":2").assertOK()
        harness.spin(0.7)
        let text = try dump(":2")
        XCTAssertTrue(text.contains("0.05"), "0.05 要原样写出来：\(text)")
        controller.switchWorkspace(2)
        harness.spin(0.3)
        try apply(text, target: ":3").assertOK()
        harness.spin(0.8)
        XCTAssertEqual(try dump(":3"), text, "极端比例的不动点")
    }

    /// 扩展页面（`webkit-extension://`）是 1.5.7 起的一等状态：地址栏那套启发式认不得它，
    /// 交给它的话 dump → apply 会把一个开着的扩展面板换成一次网页搜索
    func testExtensionURLsAreNotReinterpretedAsSearchTerms() {
        let raw = "webkit-extension://abcdef12-3456/options.html"
        XCTAssertEqual(ControlPaneFactory.resolveURL(raw)?.absoluteString, raw)
        XCTAssertEqual(ControlPaneFactory.resolveURL("webkit-extension://abcdef12-3456/popup")?
            .absoluteString, "webkit-extension://abcdef12-3456/popup")
        // 人手打进地址栏的那条路一个字都没变
        XCTAssertEqual(ControlPaneFactory.resolveURL("https://example.com")?.absoluteString,
                       "https://example.com")
        XCTAssertTrue(ControlPaneFactory.resolveURL("quickterm 是什么")?.absoluteString
            .contains("google") ?? false, "没有 scheme 的词还是该去搜索")
    }

    /// 带命令的 pane 走的是 Phase 2 那一份 `pane new` 机制（引擎对带 command 的 surface
    /// 强制 wait-after-command，不接管 `closesOnChildExit` 的话命令跑完 pane 就永远僵着）
    func testSpecPanesWithCommandsReuseThePaneNewMachinery() throws {
        touched.insert(1)
        let directory = try makeDirectory("cmd")
        try apply("""
        {"columns":[{"panes":[{"cwd":"\(directory)","cmd":"true"}]},
                    {"panes":[{"cwd":"\(directory)","cmd":"true","hold":true,"env":{"QT_SPEC":"1"}}]}]}
        """, target: ":2").assertOK()
        harness.spin(0.6)
        let live = try panes(1).compactMap { $0 as? Ghostty.SurfaceView }
        XCTAssertEqual(live.count, 2)
        XCTAssertTrue(live[0].closesOnChildExit, "--cmd 建出来的 pane 要在子进程退出时自己关掉")
        XCTAssertFalse(live[1].closesOnChildExit, "hold 明确要求命令退出后留着 pane")
    }
}

private extension ControlReply {
    func assertOK(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(ok, "命令失败：\(String(describing: error))", file: file, line: line)
    }
}
