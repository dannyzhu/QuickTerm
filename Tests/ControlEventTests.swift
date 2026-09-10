import XCTest
@testable import QuickTerm

/// Phase 4：事件流。
///
/// 这一组用例守的是四件事，每一件都对应一种 agent 真的会踩到的坑：
/// 1. `seq` 单调且**每次变更都动**——它是"我手里的快照过期了没有"的唯一答案；
/// 2. `poll --since` 回的**正好**是错过的那一批（不多回一条已经看过的，也不少回一条）；
/// 3. 密集变更会合并成一条事件（一次重排不该产生五条 layout.changed）；
/// 4. **任何事件都不携带 pane 的输出内容**。
@MainActor
final class ControlEventTests: XCTestCase {
    private var harness: ControlHarness!

    override func setUpWithError() throws {
        try super.setUpWithError()
        harness = try ControlHarness()
    }

    override func tearDown() {
        harness?.cleanup()
        harness = nil
        super.tearDown()
    }

    private func spin(_ seconds: TimeInterval = 0.25) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    /// 只看结构类事件。用例宿主里跑着真的 shell：标题与 OSC 7 的 pwd 随时会自己变，
    /// 那不是用例做的事，混进来只会让断言时灵时不灵
    private static let structural = "pane.opened,pane.closed,layout.changed,workspace.changed,focus.changed"

    // MARK: seq

    /// `seq` 每次成功的变更都要往前走，而且**只往前**。
    /// 不动的话，agent 会一直拿着一份过期的快照做决定，而且完全不知道
    func testSeqAdvancesOnEveryMutationAndNeverGoesBackwards() throws {
        let controller = try harness.controller
        var seen = [harness.seq]

        try harness.newTerminal()
        seen.append(harness.seq)

        let target = controller.model.activeIndex == 0 ? 2 : 1
        try harness.run("workspace.goto", args: ["index": .int(target)])
        seen.append(harness.seq)

        // 不动布局的一条（进程级设置）：没有任何类型化事件覆盖它，seq 也必须动——
        // 先读当前值再翻过去，否则"本来就是这个值"会变成一次 no-op，测的就不是这件事了
        let get = try harness.run("app.get", args: ["key": .string("gaps")])
        let now = get.data?["settings"]?.arrayValue?.first?.objectValue?["value"]?.stringValue ?? "on"
        let flipped = now == "on" ? "off" : "on"
        try harness.run("app.set", args: ["key": .string("gaps"), "value": .string(flipped)])
        seen.append(harness.seq)
        try harness.run("app.set", args: ["key": .string("gaps"), "value": .string(now)])
        seen.append(harness.seq)

        for (a, b) in zip(seen, seen.dropFirst()) {
            XCTAssertLessThan(a, b, "每一条落地的变更都要推进 seq：\(seen)")
        }
    }

    /// 多屏幕下 seq 仍然是**一条**尺子：第二块屏幕上的变更也推进同一个计数器，
    /// 而且 `events poll` 一次就能拿到两块屏幕上的事件（agent 不必每块屏各轮一次）
    func testSeqIsMonotonicAcrossScreens() throws {
        let app = harness.app
        let primary = try harness.controller
        let mark = harness.seq
        let second = app.newScreen(on: NSScreen.main)
        spin(0.4)
        defer {
            if app.controllers.contains(where: { $0 === second }) { app.closeScreen(second) }
            primary.window?.makeKeyAndOrderFront(nil)
            spin(0.3)
        }

        let afterOpen = harness.seq
        XCTAssertGreaterThan(afterOpen, mark, "新建屏幕要推进 seq")

        let events = harness.events(since: mark)
        XCTAssertTrue(events.contains { $0.type == ControlEventType.screenOpened.rawValue },
                      "新建屏幕要发 screen.opened：\(events.map(\.type))")
        XCTAssertTrue(events.contains { $0.screen == second.screenIndex + 1 },
                      "第二块屏幕上的事件要出现在同一条流里")

        // 两块屏幕上的事件共用一条 seq：全局严格递增，绝不会出现两条同号
        let seqs = events.map(\.seq)
        XCTAssertEqual(seqs, seqs.sorted(), "事件按 seq 升序")
        XCTAssertEqual(Set(seqs).count, seqs.count, "seq 全局唯一（两块屏幕不是两条尺子）")
    }

    // MARK: poll

    /// `poll --since` 回的正好是**错过的那一批**：
    /// 已经看过的一条都不回（否则 agent 会重复处理），漏掉的一条都不少
    func testPollSinceReturnsExactlyTheMissedBatch() throws {
        let mark = harness.seq
        try harness.newTerminal()
        harness.spin(0.1)

        let first = try poll(since: mark, timeout: "0", types: Self.structural)
        XCTAssertFalse(first.events.isEmpty, "第一次轮询要拿到刚才那一批")
        XCTAssertTrue(first.events.allSatisfy { $0.seq > mark }, "绝不回 since 之前的事件")
        let cursor = first.seq
        XCTAssertLessThanOrEqual(try XCTUnwrap(first.events.last?.seq), cursor,
                                 "回的 seq 就是下一次 --since 该给的游标")
        let firstSeqs = first.events.map(\.seq)

        // 同一个游标再轮一次：什么都不该有（重复投递是最难查的那种 agent bug）
        let empty = try poll(since: cursor, timeout: "0", types: Self.structural)
        XCTAssertTrue(empty.events.isEmpty, "已经看过的不该再回一次：\(empty.events.map(\.seq))")
        XCTAssertEqual(empty.timedOut, true, "没有新事件就是一次 timedOut，不是错误")

        // 再动一次：只回这一次的，一条旧的都不混进来
        try harness.newTerminal()
        harness.spin(0.3)
        let second = try poll(since: cursor, timeout: "0", types: Self.structural)
        XCTAssertFalse(second.events.isEmpty)
        XCTAssertTrue(second.events.allSatisfy { $0.seq > cursor },
                      "第二批里不该混进第一批的事件")
        XCTAssertTrue(Set(second.events.map(\.seq)).isDisjoint(with: Set(firstSeqs)),
                      "两批之间不得有任何重叠")
    }

    /// `--types` 只回要的那几类；`--limit` 封顶
    func testPollFiltersByTypeAndLimit() throws {
        let mark = harness.seq
        try harness.newTerminal()
        harness.spin(0.1)
        let filtered = try poll(since: mark, timeout: "0", types: "pane.opened")
        XCTAssertTrue(filtered.events.allSatisfy { $0.type == ControlEventType.paneOpened.rawValue },
                      "--types 之外的一条都不该回：\(filtered.events.map(\.type))")

        let capped = try poll(since: mark, timeout: "0", limit: 1)
        XCTAssertLessThanOrEqual(capped.events.count, 1)
    }

    /// **回归：`--limit` 截断的那一批，回的游标只走到最后一条真的送出去的事件。**
    ///
    /// 曾经回的永远是全局 seq，于是"回 1 条、告诉你已经看到第 N 条"——中间那些既没送出去，
    /// 也不会被 `missed` 标出来（`missed` 只管环被挤掉，这里环一条都没丢）。
    /// 拿着回的 seq 一轮轮追下去，必须**既不漏也不重**
    func testALimitedPollNeverSkipsPastUndeliveredEvents() throws {
        let mark = harness.seq
        try harness.newTerminal()
        try harness.newTerminal()
        try harness.newTerminal()
        harness.spin(0.4)
        ControlEventBus.shared.flush()

        let all = try poll(since: mark, timeout: "0", types: Self.structural)
        XCTAssertGreaterThan(all.events.count, 2, "这条用例要有好几条事件才测得出截断")
        XCTAssertNil(all.truncated, "没截断就不该标 truncated")
        XCTAssertEqual(all.seq, harness.seq, "没截断时游标就是全局 seq")

        // 一次只取一条，照着回的游标一路追
        var collected: [Int] = []
        var cursor = mark
        var sawTruncated = false
        for _ in 0...(all.events.count + 1) {
            let one = try poll(since: cursor, timeout: "0", types: Self.structural, limit: 1)
            guard let event = one.events.first else {
                XCTAssertEqual(one.timedOut, true, "追完了就是一次 timedOut")
                break
            }
            XCTAssertEqual(one.events.count, 1)
            if one.truncated == true {
                sawTruncated = true
                XCTAssertEqual(one.seq, event.seq,
                               "截断时游标必须钉在最后一条真的送出去的事件上，而不是全局 seq")
            } else {
                // 最后一批：后面确实没有没送出去的了，游标可以直接跳到全局 seq
                XCTAssertGreaterThanOrEqual(one.seq, event.seq)
            }
            collected.append(event.seq)
            cursor = one.seq
        }
        XCTAssertTrue(sawTruncated, "一次一条追一批多条，中间必须出现过截断")
        XCTAssertEqual(collected, all.events.map(\.seq),
                       "一条一条追下来要正好等于一次取全的那一批：不漏，也不重")
    }

    /// 流也一样：`events follow --limit 1` 不该把一次扫描里的其余事件丢掉，
    /// 也不该卡在那里等下一次变化才继续推
    func testFollowWithATinyLimitStillDeliversEverything() throws {
        let connection: UInt64 = 4343
        defer { harness.runner.connectionDidClose(connection) }
        var received: [ControlEvent] = []
        let peer = ControlSocket.Peer(fd: -1, uid: getuid(), pid: getpid(),
                                      processName: "xctest", connectionID: connection)
        let request = ControlRequest(id: "f1", cmd: "events.follow",
                                     args: ["limit": .int(1),
                                            "types": .string(Self.structural)])
        harness.runner.handle(request, peer: peer) { response in
            guard let data = try? ControlJSON.line(response),
                  let reply = try? ControlJSON.decoder.decode(ControlReply.self, from: data),
                  let payload = reply.data,
                  let encoded = try? ControlJSON.encoder.encode(payload),
                  let decoded = try? ControlJSON.decoder.decode(ControlEventsPayload.self, from: encoded)
            else { return }
            XCTAssertLessThanOrEqual(decoded.events.count, 1, "--limit 1 就是一批一条")
            received += decoded.events
        }
        let mark = harness.seq
        try harness.newTerminal()
        harness.spin(0.4)
        ControlEventBus.shared.flush()

        let expected = try poll(since: mark, timeout: "0", types: Self.structural).events.map(\.seq)
        XCTAssertGreaterThan(expected.count, 1, "一次新建 pane 至少产生两条结构事件")
        XCTAssertEqual(received.filter { $0.seq > mark }.map(\.seq), expected,
                       "一批一条也要把这一次扫描出来的全部推完")
    }

    /// 认不得的写法一律报错，绝不悄悄当默认值
    func testPollRejectsBadArguments() throws {
        let bad = try harness.run("events.poll", args: ["types": .string("pane.exploded")])
        XCTAssertFalse(bad.ok)
        XCTAssertEqual(bad.error?.code, ControlErrorCode.badRequest.rawValue)
        XCTAssertNotNil(bad.error?.candidates, "要把认得的类型列出来")

        let badTimeout = try harness.run("events.poll", args: ["timeout": .string("一会儿")])
        XCTAssertFalse(badTimeout.ok)
        XCTAssertEqual(badTimeout.error?.code, ControlErrorCode.badRequest.rawValue)

        let negative = try harness.run("events.poll", args: ["since": .int(-1), "timeout": .string("0")])
        XCTAssertFalse(negative.ok)
    }

    /// 读命令不认 `--dry-run`（读本来就什么都不改）
    func testPollRefusesMutationFlags() throws {
        let reply = try harness.run("events.poll", args: [ControlCommandTable.Flag.dryRun: .bool(true)])
        XCTAssertFalse(reply.ok)
        XCTAssertEqual(reply.error?.code, ControlErrorCode.badRequest.rawValue)
    }

    // MARK: 合并

    /// 一次重排里的 N 次布局赋值只该产生**一条** layout.changed。
    /// 不合并的话，一条 `spec apply` 就能把 agent 的上下文塞满同一件事的五个副本
    func testRapidLayoutChangesCoalesce() throws {
        let controller = try harness.controller
        try harness.newTerminal()
        try harness.newTerminal()
        harness.spin(0.3)

        let index = controller.model.activeIndex
        guard case .scrolling(var strip) = controller.model.layouts[index], !strip.columns.isEmpty else {
            throw XCTSkip("当前工作区不是 scrolling，或者没有列")
        }
        let mark = harness.seq
        // 同一轮 run loop 里连着改五次：合并的实现方式就是"一轮只扫一遍"
        for width in [0.30, 0.32, 0.34, 0.36, 0.38] {
            strip.columns[0].widthFactor = width
            controller.model.layouts[index] = .scrolling(strip)
        }
        harness.spin(0.3)

        let layoutEvents = harness.events(since: mark)
            .filter { $0.type == ControlEventType.layoutChanged.rawValue
                && $0.workspace == index + 1 && $0.screen == controller.screenIndex + 1 }
        XCTAssertEqual(layoutEvents.count, 1,
                       "五次赋值只该合并成一条 layout.changed，实际 \(layoutEvents.count) 条")
    }

    /// 什么都没变就一条事件都不该有（一次 no-op 的绝对设值不该污染事件流）
    func testNoChangeProducesNoEvents() throws {
        let controller = try harness.controller
        let index = controller.model.activeIndex
        try harness.run("workspace.goto", args: ["index": .int(index + 1)])
        let mark = harness.seq
        ControlEventBus.shared.flush()
        let structural = harness.events(since: mark).filter {
            $0.type != ControlEventType.paneTitleChanged.rawValue
                && $0.type != ControlEventType.paneCwdChanged.rawValue
        }
        XCTAssertEqual(structural.count, 0, "没有变化就没有事件：\(structural.map(\.type))")
    }

    // MARK: 绝不携带输出

    /// **一条事件能带的字段就这么几个，里面没有、也绝不能有 pane 的输出内容。**
    /// 这条用例是结构性的：谁往 `ControlEvent` 上加一个 `output` / `text` / `scrollback`，
    /// 这里立刻红。把 shell 的输出推到 socket 上等于把密码、token、ssh 会话内容原样交出去
    func testNoEventEverCarriesPaneOutput() throws {
        let populated = ControlEvent(
            seq: 1, ts: "t", type: .paneTitleChanged, screen: 1, screenID: "S", workspace: 2,
            pane: "t7", paneID: "P", kind: "terminal", layout: "scrolling",
            title: "title", cwd: "/tmp", redacted: true)
        let data = try ControlJSON.encoder.encode(populated)
        let object = try XCTUnwrap(
            try ControlJSON.decoder.decode(JSONValue.self, from: data).objectValue)
        XCTAssertEqual(Set(object.keys),
                       ["seq", "ts", "type", "screen", "screenID", "workspace",
                        "pane", "paneID", "kind", "layout", "title", "cwd", "redacted"],
                       "事件的字段表是封闭的：不得出现任何承载 pane 输出的字段")

        // 类型表也是封闭的：没有 output / scrollback / bell 这一类
        XCTAssertEqual(Set(ControlEventType.allCases.map(\.rawValue)),
                       ["pane.opened", "pane.closed", "focus.changed", "workspace.changed",
                        "layout.changed", "screen.opened", "screen.closed",
                        "pane.title.changed", "pane.cwd.changed"])

        // 真跑一遍：建 pane、改布局、切工作区，一条事件里也不该出现任何长文本
        let mark = harness.seq
        try harness.newTerminal()
        harness.spin(0.3)
        for event in harness.events(since: mark) {
            let encoded = String(decoding: try ControlJSON.encoder.encode(event), as: UTF8.self)
            XCTAssertFalse(encoded.contains("\\u001B"), "事件里不该出现转义序列：\(encoded)")
            XCTAssertLessThan(encoded.count, 2048, "事件是结构性的，不该有大块文本：\(encoded)")
        }
    }

    /// 浏览器 pane 的标题 / cwd 要按 `state` 的同一条规则打码。
    /// 漏掉这一条，`pane.title.changed` 就成了绕过 `expose-browser` 的旁路
    func testBrowserMetadataIsRedactedForTokenlessCallers() {
        let event = ControlEvent(seq: 9, ts: "t", type: .paneTitleChanged, screen: 1, workspace: 1,
                                 pane: "b3", kind: "browser",
                                 title: "私密银行 - 账户总览", cwd: "/Users/danny")
        let redacted = ControlEventBus.redact(event)
        XCTAssertEqual(redacted.title, ControlEvent.redactedPlaceholder)
        XCTAssertEqual(redacted.cwd, ControlEvent.redactedPlaceholder)
        XCTAssertEqual(redacted.redacted, true, "打过码要说出来，否则调用方以为标题真的叫 <redacted>")
        XCTAssertEqual(redacted.pane, "b3", "句柄不是秘密：打码只针对内容")
    }

    // MARK: follow

    /// 流要真的推，而且**对端一走就停**。
    /// 停不下来的话，服务端会一直往一个已经关掉的 fd 上写，直到应用退出
    func testFollowStreamsAndStopsWhenTheClientGoesAway() throws {
        let connection: UInt64 = 4242
        var batches: [ControlEventsPayload] = []
        let peer = ControlSocket.Peer(fd: -1, uid: getuid(), pid: getpid(),
                                      processName: "xctest", connectionID: connection)
        let request = ControlRequest(id: "f1", cmd: "events.follow")
        harness.runner.handle(request, peer: peer) { response in
            guard let data = try? ControlJSON.line(response),
                  let reply = try? ControlJSON.decoder.decode(ControlReply.self, from: data),
                  let payload = reply.data,
                  let encoded = try? ControlJSON.encoder.encode(payload),
                  let decoded = try? ControlJSON.decoder.decode(ControlEventsPayload.self, from: encoded)
            else { return }
            batches.append(decoded)
        }
        XCTAssertEqual(batches.count, 1, "注册那一刻先回一批（哪怕是空的），调用方才知道从哪个 seq 开始")
        XCTAssertEqual(batches[0].follow, true)
        XCTAssertEqual(ControlEventBus.shared.followerCount, 1)

        try harness.newTerminal()
        harness.spin(0.3)
        XCTAssertGreaterThan(batches.count, 1, "新事件要被推过来")
        XCTAssertFalse(batches.dropFirst().flatMap(\.events).isEmpty)

        // 对端走了
        harness.runner.connectionDidClose(connection)
        XCTAssertEqual(ControlEventBus.shared.followerCount, 0, "连接一关，流就要被摘掉")
        let after = batches.count
        try harness.newTerminal()
        harness.spin(0.3)
        XCTAssertEqual(batches.count, after, "摘掉之后一条都不该再推")
    }

    /// 同时挂太多条流要被拒（每条占住一条连接），并且指路到 poll
    func testTooManyFollowersIsRefused() throws {
        var ids: [UInt64] = []
        defer { for id in ids { harness.runner.connectionDidClose(id) } }
        for index in 0..<ControlEventLimits.maxFollowers {
            let id = UInt64(9000 + index)
            ids.append(id)
            let peer = ControlSocket.Peer(fd: -1, uid: getuid(), pid: getpid(),
                                          processName: "xctest", connectionID: id)
            harness.runner.handle(ControlRequest(id: "f", cmd: "events.follow"), peer: peer) { _ in }
        }
        let peer = ControlSocket.Peer(fd: -1, uid: getuid(), pid: getpid(),
                                      processName: "xctest", connectionID: 9999)
        var response: ControlResponse?
        harness.runner.handle(ControlRequest(id: "f", cmd: "events.follow"), peer: peer) { response = $0 }
        let reply = try ControlJSON.decoder.decode(
            ControlReply.self, from: try ControlJSON.line(try XCTUnwrap(response)))
        XCTAssertFalse(reply.ok)
        XCTAssertEqual(reply.error?.code, ControlErrorCode.busy.rawValue)
        XCTAssertTrue(reply.error?.hint?.contains("poll") ?? false, "要指路到 agent 该用的那一种")
    }

    // MARK: 长轮询

    /// 长轮询挂着的时候来了事件 → 立刻回，不必等到点
    func testLongPollWakesUpOnTheNextEvent() throws {
        var payload: ControlEventsPayload?
        ControlEventBus.shared.poll(since: harness.seq, limit: ControlEventLimits.maxBatch,
                                    types: [ControlEventType.paneOpened.rawValue],
                                    exposesBrowser: true, timeout: 5) { payload = $0 }
        XCTAssertNil(payload, "还没有事件，应该挂着")
        try harness.newTerminal()
        harness.spin(0.3)
        let got = try XCTUnwrap(payload, "有新事件就该立刻醒过来，而不是等满 5 秒")
        XCTAssertFalse(got.events.isEmpty)
        XCTAssertNil(got.timedOut)
    }

    /// 到点了就回一批空的并标 `timedOut`（**不是错误**：agent 拿同一个 seq 再轮一次即可）
    func testLongPollTimesOutWithAnEmptyBatch() throws {
        var payload: ControlEventsPayload?
        ControlEventBus.shared.poll(since: harness.seq, limit: 10,
                                    types: [ControlEventType.screenClosed.rawValue],
                                    exposesBrowser: true, timeout: 0.2) { payload = $0 }
        harness.spin(0.6)
        let got = try XCTUnwrap(payload)
        XCTAssertTrue(got.events.isEmpty)
        XCTAssertEqual(got.timedOut, true)
    }

    // MARK: 命令表

    /// events 组的两条都必须是 `read` 类（它们什么都不改），而且都在命令表里
    func testEventCommandsAreDeclaredAsReads() {
        let verbs = ControlCommandTable.commands(inGroup: "events")
        XCTAssertEqual(verbs.map(\.verb).sorted(), ["follow", "poll"])
        for spec in verbs {
            XCTAssertEqual(spec.cls, .read, "\(spec.cli) 什么都不改，必须是 read 类")
            XCTAssertFalse(spec.honorsMutationFlags, "读命令不该接受 --dry-run")
            XCTAssertFalse(spec.examples.isEmpty, "每条命令的帮助都要以 EXAMPLES 结尾")
        }
        // describe 要把事件类型表交出来：agent 会话开始读一次就够
        let document = ControlDescribeDocument.make(cliVersion: "t", appVersion: "t",
                                                    socket: nil, mode: "ask")
        XCTAssertEqual(Set(document.events.map(\.type)),
                       Set(ControlEventType.allCases.map(\.rawValue)))
        XCTAssertEqual(document.phase, 5)
    }

    // MARK: 工具

    private func poll(since: Int, timeout: String, types: String? = nil,
                      limit: Int? = nil) throws -> ControlEventsPayload {
        var args: [String: JSONValue] = ["since": .int(since), "timeout": .string(timeout)]
        if let types { args["types"] = .string(types) }
        if let limit { args["limit"] = .int(limit) }
        let reply = try harness.run("events.poll", args: args)
        XCTAssertTrue(reply.ok, "轮询失败：\(String(describing: reply.error))")
        let data = try XCTUnwrap(reply.data)
        let encoded = try ControlJSON.encoder.encode(data)
        return try ControlJSON.decoder.decode(ControlEventsPayload.self, from: encoded)
    }
}
