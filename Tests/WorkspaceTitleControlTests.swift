import AppKit
import XCTest
@testable import QuickTerm

/// 工作区名字的**控制面**这一半：`workspace set --title`、`state` / `list` 里的回显、
/// `workspace.changed` 事件、spec 的往返，以及"名字是槽位的"这条在清空工作区时的表现。
@MainActor
final class WorkspaceTitleControlTests: XCTestCase {
    private var harness: ControlHarness!
    private var temporaries: [String] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        harness = try ControlHarness()
        let controller = try harness.controller
        try XCTSkipUnless(controller.model.layouts.count >= 3, "本组用例要三个工作区")
        clearNames()
    }

    override func tearDown() {
        // 名字是进程内共享状态：留一个给后面的用例，`spec dump → apply → dump` 的不动点就会红
        clearNames()
        harness?.cleanup()
        harness = nil
        for path in temporaries { try? FileManager.default.removeItem(atPath: path) }
        temporaries = []
        super.tearDown()
    }

    private func clearNames() {
        guard let controller = try? harness?.controller else { return }
        controller.model.titles = Array(repeating: nil, count: controller.model.layouts.count)
    }

    private func title(of workspace: Int) throws -> String? {
        try harness.controller.model.title(at: workspace - 1)
    }

    // MARK: 命令

    /// 绝对设值：设上、再设一次是空操作（`--fail-if-noop` 退 7）、空串清掉
    func testSetTitleIsAbsoluteAndIdempotent() throws {
        let first = try harness.mutation(try harness.run("workspace.set", target: ":2",
                                                         args: ["title": .string("dev")]))
        XCTAssertEqual(first["changed"]?.boolValue, true)
        XCTAssertEqual(try title(of: 2), "dev")

        let second = try harness.mutation(try harness.run("workspace.set", target: ":2",
                                                          args: ["title": .string("dev")]))
        XCTAssertEqual(second["changed"]?.boolValue, false, "同样的值第二次什么都不该改")

        let strict = try harness.run("workspace.set", target: ":2",
                                     args: ["title": .string("dev"),
                                            ControlCommandTable.Flag.failIfNoop: .bool(true)])
        XCTAssertFalse(strict.ok)
        XCTAssertEqual(strict.error?.exit, ControlExit.noop.rawValue)

        let cleared = try harness.mutation(try harness.run("workspace.set", target: ":2",
                                                           args: ["title": .string("")]))
        XCTAssertEqual(cleared["changed"]?.boolValue, true, "空串是有意义的值：清掉名字")
        XCTAssertNil(try title(of: 2))
    }

    /// 不写 `-t` = 被寻址那块屏幕的**活动**工作区
    func testDefaultTargetIsTheActiveWorkspace() throws {
        let controller = try harness.controller
        try harness.run("workspace.set", args: ["title": .string("here")]).assertOK()
        XCTAssertEqual(controller.model.title(at: controller.model.activeIndex), "here")
    }

    /// 校验与 `pane set --title` 逐条一致：控制字符拒绝、200 字上限、少了 --title 也报错
    func testValidationMatchesPaneSetTitle() throws {
        let control = try harness.run("workspace.set", target: ":2",
                                      args: ["title": .string("dev\u{7}log")])
        XCTAssertFalse(control.ok)
        XCTAssertEqual(control.error?.code, ControlErrorCode.badRequest.rawValue)

        let long = String(repeating: "a", count: ControlCommandRunner.maxTitleLength + 1)
        let tooLong = try harness.run("workspace.set", target: ":2", args: ["title": .string(long)])
        XCTAssertFalse(tooLong.ok)

        let exact = String(repeating: "a", count: ControlCommandRunner.maxTitleLength)
        try harness.run("workspace.set", target: ":2", args: ["title": .string(exact)]).assertOK()

        let nothing = try harness.run("workspace.set", target: ":2", args: [:])
        XCTAssertFalse(nothing.ok, "一个设值都没给")
        XCTAssertNil(try title(of: 3), "失败的命令一个字节都不该改")
    }

    /// 名字进 OSLog 的那一份只留路径（与 pane 标题同一条：/var/db/diagnostics 是公共的）
    func testTheValueStaysOutOfTheSystemLog() throws {
        try harness.run("workspace.set", target: ":2", args: ["title": .string("秘密项目")]).assertOK()
        let entry = try XCTUnwrap(ControlActivityLog.shared.recent(1).first)
        XCTAssertTrue(entry.line.contains("秘密项目"), "应用内那一份写全（看的人就是用户本人）")
        XCTAssertFalse(entry.logLine.contains("秘密项目"), "进 OSLog 的那一份只留路径")
    }

    // MARK: 回显与事件

    func testTitleShowsUpInStateAndList() throws {
        try harness.run("workspace.set", target: ":2", args: ["title": .string("dev")]).assertOK()

        let state = try harness.mutation(try harness.run("state"))
        let screen = try XCTUnwrap(state["screens"]?.arrayValue?.first?.objectValue)
        let workspaces = try XCTUnwrap(screen["workspaces"]?.arrayValue)
        XCTAssertEqual(workspaces[1]["title"]?.stringValue, "dev")
        XCTAssertNil(workspaces[0]["title"], "没起名的工作区整条字段都不出现")

        let list = try harness.mutation(try harness.run("list", args: ["what": .string("workspaces")]))
        XCTAssertEqual(list["workspaces"]?.arrayValue?[1]["title"]?.stringValue, "dev")
    }

    /// 改名报的是**已有的** `workspace.changed`（带 title），不新造事件类型
    func testRenameEmitsWorkspaceChanged() throws {
        let since = harness.seq
        try harness.run("workspace.set", target: ":2", args: ["title": .string("dev")]).assertOK()
        harness.spin(0.3)
        let events = harness.events(since: since)
            .filter { $0.type == ControlEventType.workspaceChanged.rawValue && $0.workspace == 2 }
        let renamed = try XCTUnwrap(events.first, "改名要报一条 workspace.changed")
        XCTAssertEqual(renamed.title, "dev")
        XCTAssertNil(renamed.redacted, "用户自己写的字，不打码")
    }

    // MARK: 名字属于槽位

    /// 清空工作区（关掉里面所有 pane）之后名字还在——这正是"名字命名的是槽位"的意思
    func testClearingAWorkspaceKeepsItsName() throws {
        let controller = try harness.controller
        controller.switchWorkspace(1)
        try harness.newTerminal()
        harness.spin(0.3)
        try harness.run("workspace.set", target: ":2", args: ["title": .string("dev")]).assertOK()

        try harness.run("workspace.clear", target: ":2").assertOK()
        harness.spin(0.4)
        XCTAssertTrue(controller.model.isEmpty(1), "pane 确实都关掉了")
        XCTAssertEqual(try title(of: 2), "dev", "名字不跟着 pane 走")
        controller.switchWorkspace(0)
    }

    /// ⌘Z 撤销一次改名要**真的**改回来：撤销是整份盖回旧布局，名字得跟着那一份一起回去
    func testUndoRestoresThePreviousName() throws {
        try harness.run("workspace.set", target: ":2", args: ["title": .string("before")]).assertOK()
        harness.app.undoManager.removeAllActions()
        let payload = try harness.mutation(try harness.run("workspace.set", target: ":2",
                                                           args: ["title": .string("after")]))
        XCTAssertEqual(payload["undo"]?.stringValue, "Control plane: workspace set")
        harness.app.undoManager.undo()
        harness.spin(0.2)
        XCTAssertEqual(try title(of: 2), "before")
    }

    // MARK: spec

    /// 用例自己的临时目录（tearDown 清掉）
    private func makeDirectory() throws -> String {
        let path = NSTemporaryDirectory() + "quickterm-wstitle-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        temporaries.append(path)
        return URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    private func dump(_ target: String) throws -> String {
        let reply = try harness.run("spec.dump", target: target)
        reply.assertOK()
        let spec = try XCTUnwrap(reply.data?["spec"])
        return String(decoding: try ControlJSON.encoder.encode(spec), as: UTF8.self)
    }

    /// `dump → apply → dump` 仍是逐字节的不动点，名字也在里面往返
    func testSpecRoundTripsTheName() throws {
        let controller = try harness.controller
        controller.switchWorkspace(1)
        // 目录写明**是必须的**：不写的话新建的 pane 要等 shell 报一次 OSC 7 才有 cwd，
        // 两次 dump 就会一份带 cwd、一份不带——那是计时问题，不是不动点的问题
        let directory = try makeDirectory()
        try harness.run("pane.new", target: ":2", args: ["cwd": .string(directory)]).assertOK()
        harness.spin(0.5)
        try harness.run("workspace.set", target: ":2", args: ["title": .string("dev")]).assertOK()

        let text = try dump(":2")
        XCTAssertTrue(text.contains("\"title\":\"dev\""), text)

        controller.switchWorkspace(2)
        harness.spin(0.2)
        try harness.run("spec.apply", target: ":3", args: ["spec": .string(text)]).assertOK()
        harness.spin(0.8)
        XCTAssertEqual(try title(of: 3), "dev", "apply 把名字也落下去了")
        XCTAssertEqual(try dump(":3"), text, "dump → apply → dump 必须是不动点")

        // 这两个 pane 不在 harness 的账上（一个是 pane.new 建的，一个是 apply 建的）：自己收
        for target in [":2", ":3"] { _ = try harness.run("workspace.clear", target: target) }
        harness.spin(0.4)
        controller.switchWorkspace(0)
    }

    /// 一份不提 `title` 的 spec **不动**目标工作区的名字（与 visibleColumns 同一条规矩）
    func testSpecWithoutTitleLeavesTheNameAlone() throws {
        let controller = try harness.controller
        try harness.run("workspace.set", target: ":3", args: ["title": .string("keep")]).assertOK()
        let spec = "{\"schema\":\"quickterm.workspace/1\",\"columns\":[{\"panes\":[{}]}]}"
        try harness.run("spec.apply", target: ":3",
                        args: ["spec": .string(spec), "replace": .bool(true)]).assertOK()
        harness.spin(0.8)
        XCTAssertFalse(controller.model.isEmpty(2), "spec 真的落下去了")
        XCTAssertEqual(try title(of: 3), "keep", "--replace 换掉全部 pane 也不碰名字")

        _ = try harness.run("workspace.clear", target: ":3")
        harness.spin(0.4)
    }

    /// spec 里写空串 = 清掉名字（"没写"与"写了个空的"是两件事）
    func testSpecCanClearTheName() throws {
        try harness.run("workspace.set", target: ":3", args: ["title": .string("gone")]).assertOK()
        let spec = "{\"schema\":\"quickterm.workspace/1\",\"title\":\"\",\"columns\":[]}"
        try harness.run("spec.apply", target: ":3",
                        args: ["spec": .string(spec), "replace": .bool(true)]).assertOK()
        harness.spin(0.4)
        XCTAssertNil(try title(of: 3))
    }

    /// spec 的校验与命令同一把尺子：控制字符当场拒掉
    func testSpecValidationRejectsControlCharacters() throws {
        let spec = "{\"schema\":\"quickterm.workspace/1\",\"title\":\"a\\u0007b\",\"columns\":[]}"
        let reply = try harness.run("spec.validate", args: ["spec": .string(spec)])
        XCTAssertFalse(reply.ok)
        XCTAssertEqual(reply.error?.code, ControlErrorCode.badRequest.rawValue)
    }

    // MARK: 存档

    /// 存盘 → 读回 → 恢复到一块真实的屏幕上：名字跟着槽位回来
    func testNamesSurviveASaveAndRestore() throws {
        let app = try XCTUnwrap(NSApp.delegate as? AppDelegate)
        let controller = try harness.controller
        let source = controller.newSurface(workingDirectory: nil)
        let saved = WindowState(
            layouts: [.scrolling(ScrollingStrip(pane: source, widthFactor: 0.5)), .empty],
            floatings: [[], []], activeIndex: 0, workspaceTitles: ["dev", "日志"],
            visibleColumns: 2)
        let data = try JSONEncoder().encode(PersistedState(windows: [saved], keyWindowID: saved.id))
        let decoded = try XCTUnwrap(SessionStore.decode(data)).windows[0]
        XCTAssertEqual(decoded.workspaceTitles?.first, "dev", "名字进了存档")

        let restored = app.newScreen(on: NSScreen.main, restoring: true, id: decoded.id)
        defer {
            if app.controllers.contains(where: { $0 === restored }) { app.closeScreen(restored) }
            controller.window?.makeKeyAndOrderFront(nil)
            harness.spin(0.3)
        }
        XCTAssertTrue(restored.restore(from: decoded))
        harness.spin(0.3)
        XCTAssertEqual(restored.model.title(at: 0), "dev")
        XCTAssertEqual(restored.model.title(at: 1), "日志")
        XCTAssertEqual(restored.windowState().workspaceTitles?.compactMap { $0 }, ["dev", "日志"],
                       "再存一次还是这两个名字")
    }

    /// 一个名字都没起过的屏幕不写这一项：绝大多数存档里它只会是一串 null
    func testArchiveOmitsTheFieldWhenNothingIsNamed() throws {
        let controller = try harness.controller
        XCTAssertNil(controller.windowState().workspaceTitles)
        controller.model.setTitle("dev", at: 0)
        XCTAssertNotNil(controller.windowState().workspaceTitles)
    }
}

private extension ControlReply {
    func assertOK(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(ok, "命令失败：\(String(describing: error))", file: file, line: line)
    }
}
