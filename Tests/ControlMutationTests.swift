import XCTest
@testable import QuickTerm

/// Phase 2 的**横向**规则：幂等、--dry-run、--fail-if-noop、模态保护、限流、撤销、可见性。
/// 这些不是某一条命令的性质，而是所有变更命令共用的一条控制流——所以尽量用
/// "遍历命令表"的写法钉死：新加一条命令而忘了守规矩，用例会直接红。
@MainActor
final class ControlMutationTests: XCTestCase {
    private var harness: ControlHarness!

    override func setUpWithError() throws {
        try super.setUpWithError()
        harness = try ControlHarness()
        try harness.controller.model.switchTo(0)
    }

    override func tearDown() {
        harness?.cleanup()
        harness = nil
        super.tearDown()
    }

    // MARK: 幂等（绝对设值的全部意义）

    /// 每一个"设值"命令都跑两次：第二次必须什么都没改，并且在 `--fail-if-noop` 下退 7。
    /// agent 看不到状态、会重试——不幂等的设值第二次就把自己撤销了
    func testEverySetterIsIdempotent() throws {
        let controller = try harness.controller
        let pane = try harness.newTerminal()
        let handle = ControlHandleRegistry.shared.handle(for: pane)
        let workspace = controller.model.activeIndex + 1

        // 可见列数会写进 UserDefaults（测试宿主与用户的 app 共用同一份）：用完必须还回去
        let originalColumns = controller.visibleColumns
        defer { controller.setVisibleColumns(originalColumns) }
        let wantedColumns = originalColumns == 3 ? 4 : 3

        let cases: [(cmd: String, target: String?, args: [String: JSONValue])] = [
            ("pane.set", handle, ["zoom": .string("on")]),
            ("pane.set", handle, ["zoom": .string("off")]),
            ("pane.set", handle, ["width": .double(0.5)]),
            ("pane.focus", handle, [:]),
            ("workspace.goto", ":\(workspace)", ["index": .int(workspace)]),
            ("workspace.set-layout", ":\(workspace)", ["layout": .string("dwindle")]),
            ("workspace.set-layout", ":\(workspace)", ["layout": .string("scrolling")]),
            ("workspace.equalize", ":\(workspace)", [:]),
            // 起名 + 清名各跑一轮：第二条的第一次执行顺带把名字还回去，不留给后面的用例
            ("workspace.set", ":\(workspace)", ["title": .string("幂等")]),
            ("workspace.set", ":\(workspace)", ["title": .string("")]),
            ("screen.set", "1", ["visible-columns": .int(wantedColumns)]),
            ("screen.set", "1", ["join-all-spaces": .string("off")]),
            ("app.set", nil, ["key": .string("gaps"), "value": .string("off")]),
            ("app.set", nil, ["key": .string("gaps"), "value": .string("on")]),
            ("screen.focus", "1", [:]),
        ]

        for (cmd, target, args) in cases {
            let first = try harness.mutation(try harness.run(cmd, target: target, args: args))
            XCTAssertEqual(first["command"]?.stringValue, cmd)
            harness.spin(0.15)

            // 第二次：同样的输入，什么都不该改
            let second = try harness.mutation(try harness.run(cmd, target: target, args: args))
            XCTAssertEqual(second["changed"]?.boolValue, false,
                           "\(cmd) \(args) 第二次仍然报告改了东西——它不是绝对设值")
            XCTAssertEqual(second["applied"]?.boolValue, false, cmd)
            XCTAssertEqual(second["changes"]?.arrayValue?.count ?? 0, 0, cmd)

            // 第三次带 --fail-if-noop：必须是退出码 7，而不是静默成功
            var strict = args
            strict[ControlCommandTable.Flag.failIfNoop] = .bool(true)
            let third = try harness.run(cmd, target: target, args: strict)
            XCTAssertFalse(third.ok, "\(cmd) --fail-if-noop 应该失败")
            XCTAssertEqual(third.error?.code, ControlErrorCode.noop.rawValue, cmd)
            XCTAssertEqual(third.error?.exit, ControlExit.noop.rawValue, cmd)
        }
    }

    /// `--fail-if-noop` 只在**真的什么都没改**时报错；第一次执行仍然是 0
    func testFailIfNoopDoesNotFireOnARealChange() throws {
        let pane = try harness.newTerminal()
        let handle = ControlHandleRegistry.shared.handle(for: pane)
        let reply = try harness.run("pane.set", target: handle,
                                    args: ["zoom": .string("on"),
                                           ControlCommandTable.Flag.failIfNoop: .bool(true)])
        XCTAssertTrue(reply.ok, "\(String(describing: reply.error))")
        _ = try harness.run("pane.set", target: handle, args: ["zoom": .string("off")])
    }

    // MARK: --dry-run

    /// `--dry-run` 必须**一个字节都不改**（拿存档序列化前后逐字节比），
    /// 同时把 diff 如实报出来——这是 agent 在动真格之前唯一的验证手段
    func testDryRunReportsTheDiffAndMutatesNothing() throws {
        let controller = try harness.controller
        let pane = try harness.newTerminal()
        let handle = ControlHandleRegistry.shared.handle(for: pane)
        harness.spin(0.2)

        // 先真的把一列调宽：否则"全部等分"本来就已经成立，equalize 的 dry-run 不会有 diff
        _ = try harness.run("pane.resize", target: handle, args: ["width": .string("+0.05")])
        harness.spin(0.2)

        let cases: [(String, String?, [String: JSONValue])] = [
            ("pane.set", handle, ["zoom": .string("on"), "width": .double(0.6)]),
            ("pane.new", nil, ["kind": .string("terminal")]),
            ("workspace.set-layout", nil, ["layout": .string("dwindle")]),
            ("workspace.equalize", nil, [:]),
            ("pane.resize", handle, ["width": .string("+0.05")]),
        ]
        for (cmd, target, args) in cases {
            let before = try harness.fingerprint(controller)
            let paneCount = controller.model.allPanes.count
            var dry = args
            dry[ControlCommandTable.Flag.dryRun] = .bool(true)
            let payload = try harness.mutation(try harness.run(cmd, target: target, args: dry))
            harness.spin(0.15)

            XCTAssertEqual(payload["dryRun"]?.boolValue, true, cmd)
            XCTAssertEqual(payload["applied"]?.boolValue, false, cmd)
            XCTAssertEqual(payload["changed"]?.boolValue, true, "\(cmd) 应该报告会改什么")
            XCTAssertFalse(payload["changes"]?.arrayValue?.isEmpty ?? true, "\(cmd) 的 diff 是空的")
            XCTAssertEqual(try harness.fingerprint(controller), before,
                           "\(cmd) --dry-run 改动了模型")
            XCTAssertEqual(controller.model.allPanes.count, paneCount,
                           "\(cmd) --dry-run 建/关了 pane（pane new 的 dry-run 绝不能真的开一个 shell）")
        }
    }

    /// 读命令带 --dry-run 是调用方误解了语义：明确报错，绝不静默忽略
    func testDryRunOnAReadCommandIsAnError() throws {
        let reply = try harness.run("state", args: [ControlCommandTable.Flag.dryRun: .bool(true)])
        XCTAssertFalse(reply.ok)
        XCTAssertEqual(reply.error?.code, ControlErrorCode.badRequest.rawValue)
    }

    // MARK: 模态保护（**每一个**变更类命令）

    /// 用户正被一个对话框拦着时，**任何**变更类命令都要被拒。
    /// 遍历命令表，所以新加一条命令而忘了走同一个闸门，这条用例会直接红。
    /// （Phase 1 的评审结论：闸门当时只挡住了破坏性那一类）
    func testModalGuardRefusesEveryMutatingCommand() throws {
        let pane = try harness.newTerminal()
        let handle = ControlHandleRegistry.shared.handle(for: pane)
        // 敏感命令（send-text / capture-text）默认是关的，会先被"敏感命令默认关闭"那一道
        // 拒掉（denied），于是根本走不到模态闸门 —— 这里要测的是闸门本身，所以先把它们打开。
        // 同理，下面每一条都带上来源 token：capture-text 少了它也会在模态闸门之前就被拒
        var config = ControlCommandRunner.Config()
        config.sendText = true
        config.captureText = true
        harness.runner.config = config
        harness.runner.modalBusyProbe = { true }
        defer { harness.runner.modalBusyProbe = { false } }

        var checked = 0
        for spec in ControlCommandTable.commands where spec.cls.isMutation && !spec.local {
            let reply = try harness.run(spec.name, target: spec.acceptsTarget ? handle : nil,
                                        args: Self.minimalArgs(for: spec, handle: handle),
                                        token: ControlEnvironment.token)
            XCTAssertFalse(reply.ok, "\(spec.name) 在模态挂着时被执行了")
            XCTAssertEqual(reply.error?.code, ControlErrorCode.busy.rawValue, spec.name)
            XCTAssertEqual(reply.error?.exit, ControlExit.busy.rawValue, spec.name)
            checked += 1
        }
        XCTAssertGreaterThanOrEqual(checked, 16, "变更类命令应该有十几条，实得 \(checked)")

        // 读永远不受影响
        harness.runner.modalBusyProbe = { true }
        XCTAssertTrue(try harness.run("state").ok, "read 类命令不该被对话框挡住")
    }

    /// 命令表里每条变更命令的最小合法参数（缺必填参数会先被参数校验挡下来，
    /// 那样就测不到模态闸门了）
    static func minimalArgs(for spec: ControlCommandSpec, handle: String) -> [String: JSONValue] {
        switch spec.name {
        case "action": return ["name": .string("new-terminal")]
        case "pane.move": return ["to": .string(":2")]
        case "pane.swap": return ["with": .string(handle)]
        case "pane.set": return ["zoom": .string("on")]
        case "pane.resize": return ["width": .string("+0.05")]
        case "workspace.goto": return ["index": .int(1)]
        case "workspace.set-layout": return ["layout": .string("dwindle")]
        case "workspace.count": return ["n": .int(5)]
        case "screen.move": return ["display": .string("1")]
        case "screen.set": return ["visible-columns": .int(2)]
        case "app.set": return ["key": .string("gaps"), "value": .string("on")]
        case "input.send-text": return ["text": .string("echo hi")]
        default: return [:]
        }
    }

    // MARK: 限流

    /// 令牌桶本体（纯值类型 + 注入时钟）：会跳闸，也会自己恢复
    func testRateLimiterTripsAndRecovers() {
        var limiter = ControlRateLimiter(now: Date(timeIntervalSince1970: 0))
        let start = Date(timeIntervalSince1970: 0)
        var allowed = 0
        var limited = false
        for i in 0..<200 {
            // 同一毫秒内连发：回填可以忽略
            let verdict = limiter.admit(origin: "pane:A", now: start.addingTimeInterval(Double(i) * 0.001))
            switch verdict {
            case .allowed: allowed += 1
            case .limited(let retry, _):
                limited = true
                XCTAssertGreaterThan(retry, 0, "限流必须给出 retryAfterMs，否则 agent 只能瞎猜")
            }
        }
        XCTAssertTrue(limited, "两百条连发必须跳闸")
        XCTAssertLessThanOrEqual(allowed, Int(ControlRateLimiter.originLimit.capacity) + 2)

        // 等一会儿就该恢复
        let later = start.addingTimeInterval(10)
        XCTAssertEqual(limiter.admit(origin: "pane:A", now: later), .allowed, "十秒之后必须放行")

        // 另一个来源不受牵连
        var fresh = ControlRateLimiter(now: start)
        for _ in 0..<Int(ControlRateLimiter.originLimit.capacity) {
            _ = fresh.admit(origin: "pane:A", now: start)
        }
        XCTAssertEqual(fresh.admit(origin: "pane:B", now: start), .allowed,
                       "限的是来源，不是所有人")
    }

    /// 端到端：疯狂重试会拿到退出码 6 与 retryAfterMs，而不是把布局改成一团乱麻
    func testRunnerRateLimitsARunawayLoop() throws {
        let pane = try harness.newTerminal()
        let handle = ControlHandleRegistry.shared.handle(for: pane)
        var limitedAt: Int?
        for i in 0..<80 {
            let reply = try harness.run("pane.focus", target: handle)
            if !reply.ok, reply.error?.code == ControlErrorCode.rateLimited.rawValue {
                XCTAssertEqual(reply.error?.exit, ControlExit.busy.rawValue)
                XCTAssertNotNil(reply.error?.retryAfterMs)
                limitedAt = i
                break
            }
        }
        XCTAssertNotNil(limitedAt, "八十条连发都没跳闸：限流没生效")
        harness.runner.rateLimiter.reset()
        XCTAssertTrue(try harness.run("pane.focus", target: handle).ok, "复位之后要能继续")
    }

    // MARK: 撤销

    /// 撤销要**真的**把状态改回去（不是登记一个名字就算数）
    func testUndoActuallyReversesAMutation() throws {
        let controller = try harness.controller
        let pane = try harness.newTerminal()
        _ = try harness.newTerminal()   // 两个 pane 才有列宽可言
        harness.spin(0.3)
        let handle = ControlHandleRegistry.shared.handle(for: pane)
        let workspace = controller.model.activeIndex
        let before = try XCTUnwrap(controller.controlColumnWidth(of: pane, workspace: workspace))

        harness.app.undoManager.removeAllActions()
        let payload = try harness.mutation(try harness.run("pane.set", target: handle,
                                                           args: ["width": .double(0.75)]))
        XCTAssertEqual(payload["undo"]?.stringValue, "Control plane: pane set",
                       "变更要登记撤销项，否则 ⌘Z 撤不了 agent 造成的损失")
        XCTAssertEqual(controller.controlColumnWidth(of: pane, workspace: workspace) ?? 0, 0.75,
                       accuracy: 0.001)
        XCTAssertTrue(harness.app.undoManager.canUndo)

        harness.app.undoManager.undo()
        harness.spin(0.2)
        XCTAssertEqual(controller.controlColumnWidth(of: pane, workspace: workspace) ?? 0, before,
                       accuracy: 0.001, "撤销之后列宽必须回到原值")
        XCTAssertTrue(harness.app.undoManager.canRedo, "撤销之后要能重做")
    }

    /// **关掉一个 pane 就让整个控制面撤销栈作废。**
    ///
    /// 快照里的 layouts / floatings 强引用着每一个 `PaneView`，而关闭全靠"放弃最后一份引用"
    /// 触发 `SurfaceView.deinit`。留着快照 = 关掉的 shell 不退出，而且 ⌘Z 还能把一个
    /// 已经跑完一次性 `paneWillClose()` 的 pane 原样塞回布局
    func testClosingAPaneInvalidatesTheUndoStack() throws {
        let controller = try harness.controller
        let keeper = try harness.newTerminal()
        let victim = try harness.newTerminal()
        harness.spin(0.3)
        harness.app.undoManager.removeAllActions()

        _ = try harness.mutation(try harness.run(
            "pane.set", target: ControlHandleRegistry.shared.handle(for: keeper),
            args: ["width": .double(0.6)]))
        XCTAssertTrue(harness.app.undoManager.canUndo, "前提：这一步本来是可撤销的")

        controller.closePane(victim, confirmIfNeeded: false, animated: false)
        controller.flushPendingCloses()
        harness.spin(0.3)
        XCTAssertFalse(harness.app.undoManager.canUndo,
                       "关掉 pane 之后，吊着它的撤销快照必须作废（否则它的 shell 一直不退）")

        harness.app.undoManager.undo()
        harness.spin(0.3)
        XCTAssertFalse(controller.model.allPanes.contains { $0 === victim },
                       "已经关掉的 pane 绝不能被 ⌘Z 放回布局里")
    }

    /// 关屏幕就该结束里面的进程：这块屏幕被控制命令改过之后照样要能被完整释放。
    /// （撤销快照吊着它全部的 SurfaceView 时，surface 不释放、shell 不退出）
    func testUndoSnapshotsDoNotPinAClosedScreensPanes() throws {
        weak var weakSecond: MainWindowController?
        weak var weakPane: PaneView?
        try autoreleasepool {
            let second = harness.app.newScreen(on: NSScreen.main)
            harness.spin(0.5)
            weakSecond = second
            let pane = try XCTUnwrap(second.paneList.first, "新屏幕里应该有一个 pane")
            weakPane = pane
            // 对这块屏幕跑一条**可撤销**的命令：撤销栈里就有一份含它全部 pane 的快照
            let payload = try harness.mutation(try harness.run(
                "pane.set", target: ControlHandleRegistry.shared.handle(for: pane),
                args: ["width": .double(0.6)]))
            XCTAssertEqual(payload["undo"]?.stringValue, "Control plane: pane set", "前提：这一步登记了撤销")
            harness.app.closeScreen(second)
        }
        harness.spin(1.0)
        XCTAssertNil(weakSecond, "被控制命令改过的屏幕照样要完整释放")
        XCTAssertNil(weakPane, "撤销快照绝不能把一块已关屏幕里的 shell 一直吊着")
        try harness.controller.window?.makeKeyAndOrderFront(nil)
        harness.spin(0.2)
    }

    /// 撤销是"整份盖回布局"，也就是连 pane 集合一起换掉。所以从那以后 pane 集合变过
    /// （用户自己开了新 pane）就必须**整条作废**——否则那些新 pane 会被无声抹掉，
    /// 一个收尾都不跑（浏览器 pane 的下载没取消、文件管理器的临时文件没删）
    func testUndoIsRefusedWhenThePaneSetChangedSince() throws {
        let controller = try harness.controller
        let pane = try harness.newTerminal()
        harness.spin(0.3)
        harness.app.undoManager.removeAllActions()
        let handle = ControlHandleRegistry.shared.handle(for: pane)
        let before = try XCTUnwrap(controller.controlColumnWidth(of: pane,
                                                                workspace: controller.model.activeIndex))
        _ = try harness.mutation(try harness.run("pane.set", target: handle,
                                                 args: ["width": .double(0.75)]))
        XCTAssertTrue(harness.app.undoManager.canUndo)

        // 用户自己又开了一个 pane
        let fresh = try harness.newTerminal()
        harness.spin(0.3)

        harness.app.undoManager.undo()
        harness.spin(0.3)
        XCTAssertTrue(controller.model.allPanes.contains { $0 === fresh },
                      "撤销绝不能把变更之后新建的 pane 一起抹掉")
        XCTAssertNotEqual(controller.controlColumnWidth(of: pane,
                                                        workspace: controller.model.activeIndex) ?? 0,
                          before, accuracy: 0.0001,
                          "布局集合已经变了：这一步撤销应该整条作废，而不是回滚一半")
    }

    /// 撤销 `pane new` 就是"把刚建出来的 pane 关掉"——那必须走**关闭**语义
    /// （`removeFromAnyWorkspace`：浏览器 pane 取消下载、文件管理器删临时文件），
    /// 不能让它直接从 layouts 里消失，那等于泄漏一个终端
    func testUndoOfPaneNewClosesTheCreatedPane() throws {
        let controller = try harness.controller
        _ = try harness.newTerminal()
        harness.spin(0.3)
        harness.app.undoManager.removeAllActions()
        let existing = Set(controller.model.allPanes.map(\.id))

        let payload = try harness.mutation(try harness.run("pane.new", args: ["kind": .string("terminal")]))
        XCTAssertEqual(payload["undo"]?.stringValue, "Control plane: pane new")
        harness.spin(0.4)
        let created = try XCTUnwrap(controller.model.allPanes.first { !existing.contains($0.id) })
        harness.track(created)

        harness.app.undoManager.undo()
        harness.spin(0.4)
        XCTAssertFalse(controller.model.allPanes.contains { $0 === created },
                       "撤销 pane new 之后那个 pane 应该真的没了")
        XCTAssertEqual(Set(controller.model.allPanes.map(\.id)), existing,
                       "而且只该少那一个：其余 pane 一个都不能丢")
        XCTAssertFalse(harness.app.undoManager.canRedo,
                       "撤销顺带关掉了 pane，就不该再留一个能把它塞回来的重做项")
    }

    // MARK: apply 失败 ≠ 变更

    /// `apply` 里失败的命令**什么都不算**：seq 不动、不进撤销栈、活动日志不能记成 applied。
    /// （浮动 pane 不在平铺层里，`pane swap` 一定失败，是这条路最短的复现）
    func testFailedApplyIsNotCountedAsAMutation() throws {
        let a = try harness.newTerminal()
        let b = try harness.newTerminal()
        harness.spin(0.3)
        _ = try harness.mutation(try harness.run(
            "pane.set", target: ControlHandleRegistry.shared.handle(for: b),
            args: ["float": .string("on")]))
        harness.spin(0.3)

        harness.app.undoManager.removeAllActions()
        ControlActivityLog.shared.clear()
        try harness.controller.model.controlFlash = nil
        let seqBefore = harness.runner.seq

        let reply = try harness.run("pane.swap",
                                    target: ControlHandleRegistry.shared.handle(for: a),
                                    args: ["with": .string(ControlHandleRegistry.shared.handle(for: b))])
        XCTAssertFalse(reply.ok, "浮动 pane 换不了位置")
        XCTAssertEqual(reply.error?.code, ControlErrorCode.failed.rawValue)
        XCTAssertEqual(harness.runner.seq, seqBefore, "没落地的命令不能推进 seq（agent 拿它判断快照是否过期）")
        XCTAssertFalse(harness.app.undoManager.canUndo, "没落地的命令不能往撤销栈里塞东西")
        XCTAssertNil(try harness.controller.model.controlFlash, "没落地的命令不该闪状态栏")
        let entry = try XCTUnwrap(ControlActivityLog.shared.recent(1).first)
        XCTAssertEqual(entry.command, "pane.swap")
        XCTAssertNotEqual(entry.outcome, "applied", "活动日志把一次失败记成了 applied")

        _ = try harness.run("pane.set", target: ControlHandleRegistry.shared.handle(for: b),
                            args: ["float": .string("off")])
        harness.spin(0.3)
    }

    /// 关 pane **不登记**撤销：进程已经被结束了，把布局放回去只会造出一个"好像还在"的假象
    func testClosingDoesNotRegisterUndo() throws {
        let pane = try harness.newTerminal()
        let handle = ControlHandleRegistry.shared.handle(for: pane)
        harness.app.undoManager.removeAllActions()
        let payload = try harness.mutation(try harness.run("pane.close", target: handle,
                                                           args: ["force": .bool(true)]))
        XCTAssertNil(payload["undo"], "关 pane 绝不能假装可以撤销")
        XCTAssertFalse(harness.app.undoManager.canUndo)
    }

    // MARK: 可见性（状态栏闪烁 + 活动日志）

    /// `mutate` 类命令静默执行的**前提**是事后可见
    func testMutationFlashesTheStatusBarAndIsLogged() throws {
        let controller = try harness.controller
        let pane = try harness.newTerminal()
        let handle = ControlHandleRegistry.shared.handle(for: pane)
        controller.model.controlFlash = nil
        ControlActivityLog.shared.clear()

        _ = try harness.mutation(try harness.run("pane.set", target: handle,
                                                 args: ["zoom": .string("on")]))
        let flash = try XCTUnwrap(controller.model.controlFlash, "状态栏没有闪：变更就成了完全静默的")
        XCTAssertTrue(flash.text.contains("pane.set"), "闪烁文案要点名是哪条命令，实得 \(flash.text)")

        let entry = try XCTUnwrap(ControlActivityLog.shared.recent(1).first)
        XCTAssertEqual(entry.command, "pane.set")
        XCTAssertEqual(entry.outcome, "applied")
        XCTAssertTrue(entry.peer.contains("xctest"), "日志要记内核给的对端身份，实得 \(entry.peer)")
        XCTAssertFalse(entry.changes.isEmpty, "日志里要有 diff")

        _ = try harness.run("pane.set", target: handle, args: ["zoom": .string("off")])
    }

    /// 空操作也进日志（agent 的"我以为我改了"要有据可查），但**不闪状态栏**——
    /// 什么都没发生的事不该占用户的注意力
    func testNoopIsLoggedButNotFlashed() throws {
        let controller = try harness.controller
        let pane = try harness.newTerminal()
        let handle = ControlHandleRegistry.shared.handle(for: pane)
        _ = try harness.run("pane.set", target: handle, args: ["zoom": .string("off")])
        harness.spin(0.1)
        controller.model.controlFlash = nil
        ControlActivityLog.shared.clear()

        _ = try harness.mutation(try harness.run("pane.set", target: handle,
                                                 args: ["zoom": .string("off")]))
        XCTAssertNil(controller.model.controlFlash)
        XCTAssertEqual(ControlActivityLog.shared.recent(1).first?.outcome, "noop")
    }

    // MARK: 命令表的自洽（Phase 5 的 MCP 工具表也要靠它）

    /// 每条命令的 `idempotent` 标注必须与"它是不是绝对设值"一致，
    /// 而且线名 / CLI 写法 / 分组三者同源
    func testCommandTableIsSelfConsistent() {
        for spec in ControlCommandTable.commands {
            if let group = spec.group {
                XCTAssertEqual(spec.name, "\(group).\(spec.verb)")
                XCTAssertEqual(spec.cli, "\(group) \(spec.verb)")
            } else {
                XCTAssertEqual(spec.name, spec.verb)
                XCTAssertEqual(spec.cli, spec.verb)
            }
            XCTAssertNotNil(ControlCommandTable.command(spec.cli),
                            "命令行写法 \(spec.cli) 必须查得到同一条")
            XCTAssertFalse(spec.examples.isEmpty, "\(spec.name) 没有示例：模型抄例子远比读散文可靠")
        }
        // "set" 类动词一律是幂等的绝对设值
        for spec in ControlCommandTable.commands where ["set", "set-layout", "goto", "equalize", "focus"].contains(spec.verb) {
            XCTAssertTrue(spec.idempotent, "\(spec.name) 是设值命令，必须标为幂等")
        }
    }
}
