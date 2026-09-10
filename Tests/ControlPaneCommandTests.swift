import XCTest
@testable import QuickTerm

/// Phase 2 各条命令的**语义**：落点、跨工作区 / 跨屏幕搬家、非活动工作区设布局、
/// 配置改写。横向规则（幂等 / dry-run / 限流 / 撤销）在 `ControlMutationTests`。
@MainActor
final class ControlPaneCommandTests: XCTestCase {
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

    private func handle(_ pane: PaneView) -> String { ControlHandleRegistry.shared.handle(for: pane) }

    private func newPane(_ args: [String: JSONValue], target: String? = nil) throws -> PaneView {
        let controller = try harness.controller
        let before = Set(controller.model.allPanes.map(\.id))
        let payload = try harness.mutation(try harness.run("pane.new", target: target, args: args))
        XCTAssertEqual(payload["applied"]?.boolValue, true)
        harness.spin(0.35)
        let pane = try XCTUnwrap(harness.app.screens.allPanes.first { !before.contains($0.id) },
                                 "pane new 没建出 pane")
        harness.track(pane)
        XCTAssertEqual(payload["pane"]?["handle"]?.stringValue, handle(pane),
                       "回显的句柄要指向新建的那个 pane")
        return pane
    }

    // MARK: pane new

    /// `--cmd` 必须把 `closesOnChildExit` 打开：引擎对带 command 的 surface 强制
    /// wait-after-command、自己不会 close，不接管的话命令跑完 pane 就永远僵在那儿
    func testPaneNewWithCommandWiresChildExitBehaviour() throws {
        let withCommand = try newPane(["cmd": .string("true"), "cwd": .string(NSTemporaryDirectory())])
        let surface = try XCTUnwrap(withCommand as? Ghostty.SurfaceView)
        XCTAssertTrue(surface.closesOnChildExit, "--cmd 建出来的 pane 要在子进程退出时自己关掉")

        let held = try newPane(["cmd": .string("true"), "hold": .bool(true)])
        let heldSurface = try XCTUnwrap(held as? Ghostty.SurfaceView)
        XCTAssertFalse(heldSurface.closesOnChildExit, "--hold 明确要求命令退出后留着 pane")

        let plain = try newPane([:])
        let plainSurface = try XCTUnwrap(plain as? Ghostty.SurfaceView)
        XCTAssertFalse(plainSurface.closesOnChildExit, "普通交互 shell 不该被接管")
    }

    /// `--cwd` 落到新 surface 上（存档与"新建终端继承目录"都读它）
    func testPaneNewHonoursCwd() throws {
        let dir = NSTemporaryDirectory()
        let pane = try newPane(["cwd": .string(dir)])
        let surface = try XCTUnwrap(pane as? Ghostty.SurfaceView)
        harness.spin(0.4)
        let pwd = try XCTUnwrap(surface.workingDirectory)
        XCTAssertTrue(dir.hasPrefix(pwd) || pwd.hasPrefix(dir) || pwd.contains("/T/"),
                      "cwd 应该是 \(dir)，实得 \(pwd)")
    }

    /// `--at/--where` 落到**拖放那一套**落点语义上（scrolling：left = 锚点左边一列）
    func testPaneNewAtWhereMapsOntoTheDropPaths() throws {
        let controller = try harness.controller
        let anchor = try harness.newTerminal()
        harness.spin(0.3)
        guard case .scrolling(let strip0) = controller.model.layout,
              let anchorColumn = strip0.position(of: anchor)?.col else {
            return XCTFail("前提：活动工作区是 scrolling 并且锚点在里面")
        }

        let left = try newPane(["at": .string(handle(anchor)), "where": .string("left")])
        guard case .scrolling(let strip1) = controller.model.layout else { return XCTFail("布局变了") }
        let leftColumn = try XCTUnwrap(strip1.position(of: left)?.col)
        let anchorNow = try XCTUnwrap(strip1.position(of: anchor)?.col)
        XCTAssertEqual(leftColumn, anchorNow - 1, "--where left 要落在锚点左边一列")
        XCTAssertEqual(leftColumn, anchorColumn, "插在左边时锚点整体右移一列")

        let stacked = try newPane(["at": .string(handle(anchor)), "where": .string("stack")])
        guard case .scrolling(let strip2) = controller.model.layout else { return XCTFail("布局变了") }
        let stackedPos = try XCTUnwrap(strip2.position(of: stacked))
        let anchorPos = try XCTUnwrap(strip2.position(of: anchor))
        XCTAssertEqual(stackedPos.col, anchorPos.col, "--where stack 要併进锚点那一列")
        XCTAssertEqual(stackedPos.row, anchorPos.row + 1, "stack = 锚点下面一层")
    }

    /// dwindle 工作区里 `--where` 走 SplitTree 的同一份 dropping
    func testPaneNewAtWhereInDwindle() throws {
        let controller = try harness.controller
        let anchor = try harness.newTerminal()
        _ = try harness.mutation(try harness.run("workspace.set-layout", args: ["layout": .string("dwindle")]))
        harness.spin(0.3)
        guard case .dwindle = controller.model.layout else { return XCTFail("前提：dwindle") }

        let pane = try newPane(["at": .string(handle(anchor)), "where": .string("down")])
        guard case .dwindle(let tree) = controller.model.layout else { return XCTFail("布局变了") }
        XCTAssertNotNil(tree.root?.node(view: pane), "新 pane 必须在树里")
        XCTAssertNotNil(tree.root?.node(view: anchor), "锚点也还在")
        _ = try harness.run("workspace.set-layout", args: ["layout": .string("scrolling")])
    }

    /// `--kind file-manager` 走的是 `perform(.fileManager)` 同一份构造：
    /// role 报 file-manager、退出即关、会话已登记（关闭不再弹进程确认）
    func testPaneNewFileManagerRegistersTheSession() throws {
        let controller = try harness.controller
        let pane = try newPane(["kind": .string("file-manager"), "cwd": .string(NSTemporaryDirectory())])
        XCTAssertEqual(controller.controlRole(of: pane), "file-manager",
                       "文件管理器 pane 的 kind 仍是 terminal，靠 role 区分")
        let surface = try XCTUnwrap(pane as? Ghostty.SurfaceView)
        XCTAssertTrue(surface.closesOnChildExit)
    }

    /// `--kind browser` 建出真正的浏览器 pane（并且没有走"插进活动布局"的老路径两次）
    func testPaneNewBrowser() throws {
        let pane = try newPane(["kind": .string("browser"), "url": .string("http://127.0.0.1:1/")])
        XCTAssertTrue(pane is BrowserPaneView)
        XCTAssertEqual(pane.kind, .browser)
        XCTAssertTrue(handle(pane).hasPrefix("b"), "浏览器 pane 的句柄前缀是 b，实得 \(handle(pane))")
    }

    /// `--url` 只对浏览器 pane 有意义：写错了要明确报错，而不是被静默忽略
    func testPaneNewRejectsMismatchedArguments() throws {
        let bad = try harness.run("pane.new", args: ["url": .string("https://example.com")])
        XCTAssertFalse(bad.ok)
        XCTAssertEqual(bad.error?.code, ControlErrorCode.badRequest.rawValue)

        let badEnv = try harness.run("pane.new", args: ["env": .array([.string("NOPE")])])
        XCTAssertFalse(badEnv.ok)
        XCTAssertEqual(badEnv.error?.code, ControlErrorCode.badRequest.rawValue)
    }

    // MARK: set-layout（非活动工作区）

    /// **这条是 Phase 2 的招牌**：`toggle-layout` 只能作用于活动工作区，
    /// 而 `set-layout` 指名道姓地设——而且不能把 pane 弄丢
    func testSetLayoutWorksOnANonActiveWorkspaceAndKeepsPanes() throws {
        let controller = try harness.controller
        try XCTSkipUnless(controller.model.layouts.count >= 3, "本用例要至少三个工作区")
        let active = controller.model.activeIndex
        let other = (active + 1) % controller.model.layouts.count

        // 在非活动工作区里放两个 pane（直接建在那儿：pane new -t :N）
        let first = try newPane([:], target: ":\(other + 1)")
        let second = try newPane(["at": .string(handle(first))], target: ":\(other + 1)")
        XCTAssertEqual(controller.model.activeIndex, active, "建在别的工作区不该把活动工作区切走")
        XCTAssertEqual(controller.model.layouts[other].paneList.count, 2)

        let payload = try harness.mutation(try harness.run("workspace.set-layout",
                                                           target: ":\(other + 1)",
                                                           args: ["layout": .string("dwindle")]))
        XCTAssertEqual(payload["applied"]?.boolValue, true)
        XCTAssertEqual(controller.model.layouts[other].name, "dwindle")
        XCTAssertEqual(controller.model.activeIndex, active,
                       "设别的工作区的布局绝不能顺手切过去（agent 会以为焦点没动）")
        XCTAssertEqual(Set(controller.model.layouts[other].paneList.map(\.id)),
                       Set([first.id, second.id]), "转换必须保 pane")
        XCTAssertEqual(controller.model.layouts[active].name, "scrolling", "活动工作区不受影响")

        // 转回去：pane 还在，而且顺序不变
        _ = try harness.run("workspace.set-layout", target: ":\(other + 1)",
                            args: ["layout": .string("scrolling")])
        XCTAssertEqual(controller.model.layouts[other].paneList.map(\.id), [first.id, second.id])
    }

    // MARK: move / swap

    /// 跨工作区搬家：pane 还活着、落在目标工作区里、默认**不跟随**切换
    func testMoveAcrossWorkspacesKeepsThePaneAliveAndDoesNotFollowByDefault() throws {
        let controller = try harness.controller
        try XCTSkipUnless(controller.model.layouts.count >= 2, "本用例要至少两个工作区")
        let pane = try harness.newTerminal()
        harness.spin(0.3)
        let active = controller.model.activeIndex
        let destination = (active + 1) % controller.model.layouts.count

        let payload = try harness.mutation(try harness.run("pane.move", target: handle(pane),
                                                           args: ["to": .string(":\(destination + 1)")]))
        harness.spin(0.25)
        XCTAssertEqual(payload["applied"]?.boolValue, true)
        XCTAssertEqual(controller.model.activeIndex, active, "默认不跟随")
        XCTAssertTrue(controller.model.layouts[destination].paneList.contains { $0 === pane },
                      "pane 要在目标工作区里")
        XCTAssertFalse(controller.model.layouts[active].paneList.contains { $0 === pane },
                       "源工作区里不该还留着它")
        XCTAssertFalse(pane.id.uuidString.isEmpty, "pane 还活着")
        XCTAssertNotNil(payload["note"]?.stringValue, "不跟随时要说清楚 pane 去哪了")

        // 搬回来并跟随
        _ = try harness.mutation(try harness.run("pane.move", target: handle(pane),
                                                 args: ["to": .string(":\(active + 1)"),
                                                        "follow": .bool(true)]))
        harness.spin(0.3)
        XCTAssertEqual(controller.model.activeIndex, active)
        XCTAssertTrue(controller.model.layouts[active].paneList.contains { $0 === pane })
    }

    /// 跨**屏幕**搬家：应用里原本一条这样的路径都没有
    func testMoveAcrossScreensReparentsThePane() throws {
        let app = harness.app
        let primary = try harness.controller
        let pane = try harness.newTerminal()
        harness.spin(0.3)
        let second = app.newScreen(on: NSScreen.main)
        harness.spin(0.4)
        defer {
            if app.controllers.contains(where: { $0 === second }) {
                app.closeScreen(second, confirmed: true)
            }
            primary.window?.makeKeyAndOrderFront(nil)
            harness.spin(0.3)
        }
        let screenNumber = second.screenIndex + 1

        let payload = try harness.mutation(try harness.run(
            "pane.move", target: handle(pane),
            args: ["to": .string("\(screenNumber):1"), "follow": .bool(true)]))
        harness.spin(0.4)
        XCTAssertEqual(payload["applied"]?.boolValue, true)
        XCTAssertTrue(second.model.allPanes.contains { $0 === pane }, "pane 要落在第二块屏幕上")
        XCTAssertFalse(primary.model.allPanes.contains { $0 === pane }, "源屏幕不该还留着它")
        XCTAssertEqual(payload["pane"]?["screen"]?.intValue, screenNumber, "回显要报新的屏幕号")

        // 搬回来，否则第二块屏幕一关，pane 就跟着没了
        _ = try harness.mutation(try harness.run("pane.move", target: handle(pane),
                                                 args: ["to": .string("1:1"), "follow": .bool(true)]))
        harness.spin(0.4)
        XCTAssertTrue(primary.model.allPanes.contains { $0 === pane })
    }

    /// 交换两个 pane 的位置（指名道姓，不用先把焦点挪过去）
    func testSwapExchangesPositions() throws {
        let controller = try harness.controller
        let a = try harness.newTerminal()
        let b = try newPane(["at": .string(handle(a))])
        harness.spin(0.3)
        guard case .scrolling(let before) = controller.model.layout,
              let posA = before.position(of: a), let posB = before.position(of: b) else {
            return XCTFail("前提：两个 pane 都在 scrolling 布局里")
        }
        _ = try harness.mutation(try harness.run("pane.swap", target: handle(a),
                                                 args: ["with": .string(handle(b))]))
        harness.spin(0.2)
        guard case .scrolling(let after) = controller.model.layout else { return XCTFail("布局变了") }
        XCTAssertEqual(after.position(of: a)?.col, posB.col, "a 应该占了 b 的位置")
        XCTAssertEqual(after.position(of: b)?.col, posA.col, "b 应该占了 a 的位置")

        let crossWorkspace = try harness.run("pane.swap", target: handle(a),
                                             args: ["with": .string("@self")])
        XCTAssertFalse(crossWorkspace.ok, "@self 在测试宿主里解析不出来，应报错而不是乱换")
    }

    // MARK: resize

    /// `--width +0.05` 是**相对**的，到边界就成了空操作（退 7），而不是假装改了
    func testResizeIsRelativeAndStopsAtTheBoundary() throws {
        let controller = try harness.controller
        let pane = try harness.newTerminal()
        _ = try newPane(["at": .string(handle(pane))])
        harness.spin(0.3)
        let workspace = controller.model.activeIndex
        let before = try XCTUnwrap(controller.controlColumnWidth(of: pane, workspace: workspace))

        let payload = try harness.mutation(try harness.run("pane.resize", target: handle(pane),
                                                           args: ["width": .string("+0.05")]))
        let after = try XCTUnwrap(controller.controlColumnWidth(of: pane, workspace: workspace))
        XCTAssertEqual(after, before + 0.05, accuracy: 0.001)
        XCTAssertEqual(payload["changes"]?.arrayValue?.count, 1)

        // 顶到上限（0.90）之后再加就是空操作
        for _ in 0..<20 { _ = try harness.run("pane.resize", target: handle(pane), args: ["width": .string("+0.05")]) }
        XCTAssertEqual(controller.controlColumnWidth(of: pane, workspace: workspace) ?? 0,
                       ScrollingStrip.widthRange.upperBound, accuracy: 0.001)
        let noop = try harness.run("pane.resize", target: handle(pane),
                                   args: ["width": .string("+0.05"),
                                          ControlCommandTable.Flag.failIfNoop: .bool(true)])
        XCTAssertEqual(noop.error?.code, ControlErrorCode.noop.rawValue, "到边界了就该老实说没改")
    }

    /// 绝对列宽越界要**报错**，绝不静默夹紧（夹紧之后 agent 读回来的值和写下去的对不上）
    func testAbsoluteWidthOutOfRangeIsAnError() throws {
        let pane = try harness.newTerminal()
        let reply = try harness.run("pane.set", target: handle(pane), args: ["width": .double(0.95)])
        XCTAssertFalse(reply.ok)
        XCTAssertEqual(reply.error?.code, ControlErrorCode.badRequest.rawValue)
        XCTAssertTrue(reply.error?.message.contains("0.9") ?? false, "错误信息里要写清合法范围")
    }

    // MARK: workspace count（改写 config.toml）

    /// `workspace count N` 改写配置文件并**交给已有的配置监听**去落地：
    /// 自己不能再落一次（双落 = 键位表重建两遍 + 与监听竞态）
    func testWorkspaceCountRewritesConfigAndDoesNotDoubleApply() throws {
        let controller = try harness.controller
        let temporary = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("qt-config-\(UUID().uuidString.prefix(8)).toml")
        try ConfigStore.template.write(to: temporary, atomically: true, encoding: .utf8)
        ConfigStore.configURLOverride = temporary
        defer {
            ConfigStore.configURLOverride = nil
            try? FileManager.default.removeItem(at: temporary)
        }
        let before = controller.model.layouts.count

        let payload = try harness.mutation(try harness.run("workspace.count", args: ["n": .int(7)]))
        XCTAssertEqual(payload["applied"]?.boolValue, true)
        let text = try String(contentsOf: temporary, encoding: .utf8)
        XCTAssertTrue(text.contains("workspaces = 7"), "配置文件里要落下新的个数：\n\(text)")
        XCTAssertFalse(text.contains("# workspaces = 5"), "原来那行注释应该被换掉")
        XCTAssertEqual(ConfigStore.parse(text).workspaces, 7, "改写出来的东西必须还能被自己解析回来")
        XCTAssertEqual(controller.model.layouts.count, before,
                       "命令自己不落值：那是配置监听的活（双落会和监听打架）")
        XCTAssertNotNil(payload["note"]?.stringValue, "要告诉调用方稍后才生效")

        // 越界与缩容保护
        let tooMany = try harness.run("workspace.count", args: ["n": .int(11)])
        XCTAssertEqual(tooMany.error?.code, ControlErrorCode.badRequest.rawValue)
    }

    // MARK: 目标解析的边界

    /// 淡出中的 pane 不可寻址；命令执行前先 flush
    func testClosingPanesAreNotAddressable() throws {
        let controller = try harness.controller
        let pane = try harness.newTerminal()
        let name = handle(pane)
        controller.closeAnimationEnabled = true
        controller.closePane(pane, confirmIfNeeded: false, animated: true)
        XCTAssertTrue(controller.model.closingPanes.contains(pane.id), "前提：正在淡出")
        let reply = try harness.run("pane.set", target: name, args: ["zoom": .string("on")])
        XCTAssertFalse(reply.ok, "淡出中的 pane 不该还能被改")
        XCTAssertEqual(reply.error?.exit, ControlExit.badTarget.rawValue)
        harness.spin(0.4)
    }

    /// 破坏性命令要经过确认闸门；拒绝就什么都不做
    func testPaneCloseNeedsConsent() throws {
        let controller = try harness.controller
        let pane = try harness.newTerminal()
        harness.consent.reset()
        harness.consent.decisionStub = { _, reply in reply(.deny) }
        let denied = try harness.run("pane.close", target: handle(pane), args: ["force": .bool(true)])
        XCTAssertFalse(denied.ok)
        XCTAssertEqual(denied.error?.exit, ControlExit.denied.rawValue)
        XCTAssertTrue(controller.model.allPanes.contains { $0 === pane }, "被拒了就什么都不做")

        harness.consent.reset()
        harness.consent.decisionStub = { _, reply in reply(.allow) }
        _ = try harness.mutation(try harness.run("pane.close", target: handle(pane),
                                                 args: ["force": .bool(true)]))
        harness.spin(0.4)
        XCTAssertFalse(controller.model.allPanes.contains { $0 === pane }, "确认之后要真的关掉")
    }

    /// `action` 是直通 `perform()` 的快捷键平价车：算不出 diff，也没有"预演"这回事。
    /// 静默接受 `--dry-run` 的后果是双份的——一次"预演"真的落了刀，
    /// 而这个开关还顺手把破坏性动作的确认闸门一起关掉了
    func testDryRunOnAnActionIsRefusedAndDoesNothing() throws {
        let controller = try harness.controller
        let pane = try harness.newTerminal()
        harness.spin(0.3)
        controller.requestFocus(to: pane)
        harness.spin(0.3)
        var asked = 0
        harness.consent.reset()
        harness.consent.decisionStub = { _, reply in
            asked += 1
            reply(.allow)
        }
        for flag in [ControlCommandTable.Flag.dryRun, ControlCommandTable.Flag.failIfNoop] {
            let reply = try harness.run("action", args: ["name": .string("close-pane"), flag: .bool(true)])
            XCTAssertFalse(reply.ok, "action 不该接受 \(flag)")
            XCTAssertEqual(reply.error?.code, ControlErrorCode.badRequest.rawValue, flag)
            XCTAssertEqual(asked, 0, "被拒的命令不该去打扰用户")
            XCTAssertTrue(controller.model.allPanes.contains { $0 === pane },
                          "\(flag) 绝不能让一条破坏性动作绕过确认闸门还真的落刀")
        }
        harness.spin(0.3)
    }

    // MARK: 浮动层 × 平铺层内属性

    /// zoom / 列宽 / split 比例都是**平铺层内**的属性。对浮动 pane 设它们要明确报错：
    /// 静默写下去的结果是两条读路径互相矛盾（写的一侧说 on，`state` 说 off），agent 永远收敛不了
    func testTiledOnlySettersRefuseAFloatingPane() throws {
        let controller = try harness.controller
        let anchor = try harness.newTerminal()
        let pane = try harness.newTerminal()
        harness.spin(0.3)
        let name = handle(pane)
        _ = try harness.mutation(try harness.run("pane.set", target: name, args: ["float": .string("on")]))
        harness.spin(0.3)
        XCTAssertTrue(controller.controlIsFloating(pane, workspace: controller.model.activeIndex),
                      "前提：它现在是浮动的")

        for args in [["zoom": JSONValue.string("on")], ["width": JSONValue.double(0.4)]] {
            let reply = try harness.run("pane.set", target: name, args: args)
            XCTAssertFalse(reply.ok, "\(args) 对浮动 pane 应该明确报错，而不是静默空操作")
            XCTAssertEqual(reply.error?.code, ControlErrorCode.badRequest.rawValue, "\(args)")
        }
        XCTAssertFalse(controller.controlIsZoomed(pane, workspace: controller.model.activeIndex),
                       "被拒的 --zoom 不能留下一个悬空的 zoomedID")
        XCTAssertFalse(controller.controlIsZoomed(anchor, workspace: controller.model.activeIndex),
                       "更不能把别人真正的 zoom 顶掉")

        // 同一条命令里先落回平铺层，再设层内属性：顺序必须是 float → zoom / width
        let payload = try harness.mutation(try harness.run(
            "pane.set", target: name,
            args: ["float": .string("off"), "zoom": .string("on"), "width": .double(0.4)]))
        XCTAssertEqual(payload["applied"]?.boolValue, true)
        harness.spin(0.3)
        XCTAssertFalse(controller.controlIsFloating(pane, workspace: controller.model.activeIndex))
        XCTAssertTrue(controller.controlIsZoomed(pane, workspace: controller.model.activeIndex),
                      "zoom 在回塞平铺之前设，会被插入操作清掉——顺序错了")
        XCTAssertEqual(controller.controlColumnWidth(of: pane, workspace: controller.model.activeIndex) ?? 0,
                       0.4, accuracy: 0.001, "列宽同理")
        _ = try harness.run("pane.set", target: name, args: ["zoom": .string("off")])
        harness.spin(0.2)
    }

    /// `workspace clear` 要真的清干净，并且只把**真关掉了的**那些 pane 报出来。
    /// （逐 pane 弹 QuickTerm 自己那句确认的话，这一趟一个都关不掉，payload 却会报 applied）
    func testWorkspaceClearReallyClearsAndReportsWhatItClosed() throws {
        let controller = try harness.controller
        // 在**空**的 2 号工作区里做：清空 1 号会连着关掉应用自带的那个 pane，
        // 后面的用例就没有可寻址的焦点 pane 了
        let index = 1
        defer { controller.switchWorkspace(0) }
        let a = try harness.newTerminal(in: index)
        let b = try harness.newTerminal(in: index)
        harness.spin(0.3)
        XCTAssertEqual(controller.model.activeIndex, index, "前提：清的是**活动**工作区（会走 closePane 那条路）")
        let live = controller.model.layouts[index].paneList.count
        XCTAssertGreaterThanOrEqual(live, 2, "前提：这个工作区里有东西可清")

        let payload = try harness.mutation(try harness.run("workspace.clear", target: ":\(index + 1)"))
        harness.spin(0.4)
        XCTAssertEqual(payload["applied"]?.boolValue, true)
        XCTAssertNil(payload["confirmPending"], "已经一次落干净了，不该报还挂着确认框")
        XCTAssertEqual(payload["panes"]?.arrayValue?.count, live, "报出来的就是真关掉的那些")
        XCTAssertTrue(controller.model.layouts[index].paneList.isEmpty, "工作区必须真的空了")
        XCTAssertTrue(controller.model.floatings[index].isEmpty)
        XCTAssertFalse(controller.model.allPanes.contains { $0 === a || $0 === b })
    }

    /// `--dry-run` 的破坏性命令**不问用户**（它什么都不会做），但也绝不能真的关掉
    func testDestructiveDryRunNeitherPromptsNorCloses() throws {
        let controller = try harness.controller
        let pane = try harness.newTerminal()
        var asked = 0
        harness.consent.reset()
        harness.consent.decisionStub = { _, reply in
            asked += 1
            reply(.allow)
        }
        let payload = try harness.mutation(try harness.run(
            "pane.close", target: handle(pane),
            args: [ControlCommandTable.Flag.dryRun: .bool(true)]))
        XCTAssertEqual(asked, 0, "预演不该打扰用户")
        XCTAssertEqual(payload["applied"]?.boolValue, false)
        XCTAssertTrue(controller.model.allPanes.contains { $0 === pane }, "预演绝不能真关")
    }
}
