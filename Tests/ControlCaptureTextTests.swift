import XCTest
@testable import QuickTerm

/// `pane capture-text` —— 读一个终端 pane 屏幕上的字。
///
/// 每一道闸门一条用例，而且**每一道都单独生效**：去掉任意一道，剩下的仍然要拦得住。
/// 默认关闭 · 必须带 token · 每个调用进程确认一次 · 不认 --dry-run · 正文不留痕。
@MainActor
final class ControlCaptureTextTests: XCTestCase {
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

    /// 打开 `[control] capture-text`（默认是关的）
    private func enableCapture() {
        var config = ControlCommandRunner.Config()
        config.captureText = true
        harness.runner.config = config
    }

    private func target(_ pane: PaneView) -> String { "#\(pane.id.uuidString)" }

    // MARK: 闸门一：默认关闭，而且与 send-text 是两个开关

    func testCaptureIsRefusedWhenTheConfigKeyIsOff() throws {
        XCTAssertFalse(ControlCommandRunner.Config().captureText,
                       "[control] capture-text 默认必须是 false")
        let pane = try harness.newTerminal()
        var prompts = 0
        harness.consent.decisionStub = { _, reply in
            prompts += 1
            reply(.allow)
        }
        let reply = try harness.run("pane.capture-text", target: target(pane),
                                    token: ControlEnvironment.token)
        XCTAssertFalse(reply.ok)
        XCTAssertEqual(reply.error?.code, ControlErrorCode.denied.rawValue)
        XCTAssertTrue(reply.error?.hint?.contains("capture-text = true") ?? false,
                      "拒绝时要说清怎么打开：\(String(describing: reply.error?.hint))")
        XCTAssertEqual(prompts, 0, "关着的时候连确认框都不该弹")
    }

    /// **一条命令一个开关。** 打开 send-text 不该顺带把"读屏幕"打开，反过来也一样——
    /// 那是两件完全不同的授权
    func testTheTwoSensitiveSwitchesAreIndependent() throws {
        let pane = try harness.newTerminal()
        harness.consent.decisionStub = { _, reply in reply(.allow) }

        var onlySendText = ControlCommandRunner.Config()
        onlySendText.sendText = true
        harness.runner.config = onlySendText
        let captured = try harness.run("pane.capture-text", target: target(pane),
                                       token: ControlEnvironment.token)
        XCTAssertFalse(captured.ok, "send-text = true 不该把 capture-text 一起打开")
        XCTAssertEqual(captured.error?.code, ControlErrorCode.denied.rawValue)

        var onlyCapture = ControlCommandRunner.Config()
        onlyCapture.captureText = true
        harness.runner.config = onlyCapture
        let typed = try harness.run("input.send-text", target: target(pane),
                                    args: ["text": .string("echo hi")],
                                    token: ControlEnvironment.token)
        XCTAssertFalse(typed.ok, "capture-text = true 不该把 send-text 一起打开")
        XCTAssertEqual(typed.error?.code, ControlErrorCode.denied.rawValue)
    }

    // MARK: 闸门二：没有来源 token 一律拒

    /// 读不到浏览器 pane 标题的调用方，更不该读到一个 shell 的屏幕。
    /// 而且这一拒要发生在**确认闸门之前**：注定被拒的命令不该先把用户叫起来
    func testCaptureIsRefusedWithoutTheOriginToken() throws {
        enableCapture()
        let pane = try harness.newTerminal()
        var prompts = 0
        harness.consent.decisionStub = { _, reply in
            prompts += 1
            reply(.allow)
        }
        let reply = try harness.run("pane.capture-text", target: target(pane))   // 不带 token
        XCTAssertFalse(reply.ok)
        XCTAssertEqual(reply.error?.code, ControlErrorCode.denied.rawValue)
        XCTAssertEqual(reply.error?.exit, ControlExit.denied.rawValue)
        XCTAssertTrue(reply.error?.message.contains("QUICKTERM_TOKEN") ?? false,
                      "要说清缺的是什么：\(String(describing: reply.error?.message))")
        XCTAssertEqual(prompts, 0, "拒绝要发生在确认之前")
        XCTAssertNil(reply.data?["text"], "被拒的响应里绝不能有正文")

        // 抄错的 token 同样拒
        let wrong = try harness.run("pane.capture-text", target: target(pane), token: "not-the-token")
        XCTAssertFalse(wrong.ok)
        XCTAssertEqual(wrong.error?.code, ControlErrorCode.denied.rawValue)
    }

    // MARK: 闸门三：确认

    /// 每个调用进程确认一次（`(pid, 命令)` 粒度），框里说的是**读哪个 pane 的屏幕**；
    /// 用户拒绝 = 一个字都拿不到
    func testCapturePromptsPerProcessAndTheDialogNamesTheRead() throws {
        enableCapture()
        let pane = try harness.newTerminal()
        var seen: [ControlConsent.Request] = []
        harness.consent.decisionStub = { request, reply in
            seen.append(request)
            reply(.allow)
        }
        for _ in 0..<3 {
            let reply = try harness.run("pane.capture-text", target: target(pane),
                                        token: ControlEnvironment.token)
            XCTAssertTrue(reply.ok, "\(String(describing: reply.error))")
        }
        XCTAssertEqual(seen.count, 1, "同一个进程问一次就够（之后按 (pid, 命令) 缓存）")
        let request = try XCTUnwrap(seen.first)
        XCTAssertEqual(request.cls, .sensitive)
        XCTAssertEqual(request.scope, "pane.capture-text",
                       "敏感命令一条一个授权键：批准读屏幕不等于批准打字")
        XCTAssertTrue(request.summary.contains("读取"), "框里要说这是在读：\(request.summary)")
        XCTAssertNil(request.payload, "读命令没有要展示的正文（正文是读回来的东西，不能画给别处）")

        // **缓存不串味**：批准过 capture 之后，send-text 仍然要问
        var both = harness.runner.config
        both.sendText = true
        harness.runner.config = both
        seen.removeAll()
        _ = try harness.run("input.send-text", target: target(pane),
                            args: ["text": .string("echo hi")], token: ControlEnvironment.token)
        XCTAssertEqual(seen.count, 1, "capture 的授权绝不能替 send-text 开门")

        // 用户拒绝 = 拿不到内容
        harness.consent.decisionStub = { _, reply in reply(.deny) }
        harness.consent.reset()
        let denied = try harness.run("pane.capture-text", target: target(pane),
                                     token: ControlEnvironment.token)
        XCTAssertFalse(denied.ok)
        XCTAssertEqual(denied.error?.code, ControlErrorCode.denied.rawValue)
        XCTAssertNil(denied.data?["text"])
    }

    // MARK: 闸门四：不认 --dry-run（那会变成绕过确认的后门）

    /// `--dry-run` 在别处同时意味着**免确认**（预演什么都不改，所以不问）。
    /// 一条什么都不改、却会把屏幕上的字全交出去的命令要是认了它，那就是一个后门
    func testCaptureRefusesTheMutationFlagsSoTheyCannotSkipConsent() throws {
        let spec = try XCTUnwrap(ControlCommandTable.command("pane.capture-text"))
        XCTAssertEqual(spec.cls, .sensitive, "它必须落在需要确认的那一侧")
        XCTAssertTrue(spec.readOnlyEffect, "它什么都不改")
        XCTAssertFalse(spec.honorsMutationFlags, "所以它不认 --dry-run / --fail-if-noop")

        enableCapture()
        let pane = try harness.newTerminal()
        var prompts = 0
        harness.consent.decisionStub = { _, reply in
            prompts += 1
            reply(.allow)
        }
        for flag in [ControlCommandTable.Flag.dryRun, ControlCommandTable.Flag.failIfNoop] {
            let reply = try harness.run("pane.capture-text", target: target(pane),
                                        args: [flag: .bool(true)], token: ControlEnvironment.token)
            XCTAssertFalse(reply.ok, "--\(flag) 必须被拒")
            XCTAssertEqual(reply.error?.code, ControlErrorCode.badRequest.rawValue)
            XCTAssertNil(reply.data?["text"], "--\(flag) 更不能顺手把内容给出去")
        }
        XCTAssertEqual(prompts, 0)
    }

    // MARK: 真的读得到屏幕上的字

    /// 往一个真实的 surface 里打一串标记，再读回来。
    /// 顺带钉死三件事：网格尺寸、行数，以及**正文一个字都不进活动日志**
    func testCaptureReturnsWhatTheTerminalShows() throws {
        enableCapture()
        harness.consent.decisionStub = { _, reply in reply(.allow) }
        let pane = try harness.newTerminal()
        let surface = try XCTUnwrap(pane as? Ghostty.SurfaceView)
        harness.spin(0.6)   // 等 shell 起来、第一个提示符画出来

        let marker = "QT-CAPTURE-\(UUID().uuidString.prefix(8))"
        let model = try XCTUnwrap(surface.surfaceModel, "引擎 surface 没建出来")
        model.sendText(marker)

        // 引擎渲染是异步的：轮询到出现为止（**不是** sleep 一个定死的时长）
        var payload: [String: JSONValue] = [:]
        var text = ""
        for _ in 0..<40 {
            harness.spin(0.1)
            let reply = try harness.run("pane.capture-text", target: target(pane),
                                        token: ControlEnvironment.token)
            XCTAssertTrue(reply.ok, "\(String(describing: reply.error))")
            payload = reply.data?.objectValue ?? [:]
            text = payload["text"]?.stringValue ?? ""
            if text.contains(marker) { break }
        }
        XCTAssertTrue(text.contains(marker),
                      "打进 shell 的那串字必须出现在抓回来的屏幕里，实得：\(text.suffix(200))")

        XCTAssertEqual(payload["command"]?.stringValue, "pane.capture-text")
        XCTAssertEqual(payload["scrollback"]?.intValue, 0, "默认只要可视区")
        XCTAssertEqual(payload["lines"]?.intValue, text.components(separatedBy: "\n").count)
        XCTAssertEqual(payload["cols"]?.intValue, surface.surfaceSize.map { Int($0.columns) },
                       "网格尺寸要如实回：调用方由此知道这份文本折行折在哪儿")
        XCTAssertEqual(payload["rows"]?.intValue, surface.surfaceSize.map { Int($0.rows) })
        XCTAssertEqual(payload["pane"]?["handle"]?.stringValue,
                       ControlHandleRegistry.shared.handle(for: pane))

        // **正文不留痕**：不进活动日志、不进事件流
        for entry in ControlActivityLog.shared.recent(50) {
            XCTAssertFalse(entry.line.contains(marker), "正文绝不能进活动日志：\(entry.line)")
        }
        for event in harness.events(since: 0) {
            let encoded = String(decoding: try ControlJSON.encoder.encode(event), as: UTF8.self)
            XCTAssertFalse(encoded.contains(marker), "事件绝不携带 pane 的输出：\(encoded)")
        }

        // --scrollback 也能跑通（历史多少行取决于 shell，这里只钉"不比可视区少"）
        let withHistory = try harness.run("pane.capture-text", target: target(pane),
                                          args: ["scrollback": .int(50)],
                                          token: ControlEnvironment.token)
        XCTAssertTrue(withHistory.ok, "\(String(describing: withHistory.error))")
        XCTAssertGreaterThanOrEqual(withHistory.data?["lines"]?.intValue ?? 0,
                                    payload["lines"]?.intValue ?? 0)
        XCTAssertTrue(withHistory.data?["text"]?.stringValue?.contains(marker) ?? false,
                      "带历史时，可视区那一段仍然要在里面")
    }

    // MARK: 参数与 pane 种类

    func testScrollbackIsBoundedAndTheWrongPaneKindIsNamed() throws {
        enableCapture()
        harness.consent.decisionStub = { _, reply in reply(.allow) }
        let pane = try harness.newTerminal()

        for bad in [-1, ControlCaptureLimits.maxScrollback + 1] {
            let reply = try harness.run("pane.capture-text", target: target(pane),
                                        args: ["scrollback": .int(bad)],
                                        token: ControlEnvironment.token)
            XCTAssertFalse(reply.ok, "--scrollback \(bad) 该被拒")
            XCTAssertEqual(reply.error?.code, ControlErrorCode.badRequest.rawValue)
            XCTAssertTrue(reply.error?.message.contains("\(ControlCaptureLimits.maxScrollback)") ?? false,
                          "越界要给出范围：\(String(describing: reply.error?.message))")
        }

        // 浏览器 pane：wrong_pane_kind，而不是一句空洞的失败
        let controller = try harness.controller
        let before = Set(controller.model.allPanes.map(\.id))
        _ = try harness.mutation(try harness.run("pane.new", args: [
            "kind": .string("browser"), "url": .string("http://127.0.0.1:1/"),
        ]))
        harness.spin(0.35)
        let browser = try XCTUnwrap(harness.app.screens.allPanes.first { !before.contains($0.id) })
        harness.track(browser)
        let reply = try harness.run("pane.capture-text", target: target(browser),
                                    token: ControlEnvironment.token)
        XCTAssertFalse(reply.ok)
        XCTAssertEqual(reply.error?.code, ControlErrorCode.wrongPaneKind.rawValue)
    }

    /// 长度上限：**从头部截**，屏幕上最新的那几行永远留着
    func testTruncationKeepsTheNewestLines() {
        let lines = (1...200).map { "line-\($0) " + String(repeating: "x", count: 2000) }
        let capture = ControlCommandRunner.Capture(text: lines.joined(separator: "\n"),
                                                   lines: lines.count, scrollbackLines: 0,
                                                   truncated: false)
        XCTAssertGreaterThan(capture.text.utf8.count, ControlCaptureLimits.maxBytes,
                             "前提：这份样本确实超了上限")
        // 与实现同一条规则（`capture` 里那段）：留末尾
        var kept: [String] = []
        var bytes = 0
        for line in lines.reversed() {
            bytes += line.utf8.count + 1
            if bytes > ControlCaptureLimits.maxBytes { break }
            kept.append(line)
        }
        XCTAssertEqual(kept.first, lines.last, "截断之后最后一行必须还在")
        XCTAssertLessThan(kept.count, lines.count)
    }

    /// **截断之后那两个计数还得对得上。**
    /// 回归：截断后 `scrollback` 取的是 `min(原历史行数, 留下的行数)`，
    /// 而留下的是最后那几行——里面有整整一屏可视区。极端情况直接报出 scrollback == lines，
    /// 于是按 `lines - scrollback` 去切"可视区那一段"的调用方切出 0 行
    func testTruncationKeepsTheScrollbackCountHonest() {
        let viewportRows = 24
        let viewport = (1...viewportRows).map { "view-\($0)" }.joined(separator: "\n")
        // screen = 历史 + 可视区（引擎给的就是这个形状），大到必然触发字节上限
        let history = (1...4000).map { "hist-\($0) " + String(repeating: "x", count: 200) }
        let screen = (history + (1...viewportRows).map { "view-\($0)" }).joined(separator: "\n")

        let capture = ControlCommandRunner.assemble(viewport: viewport, screen: screen,
                                                    scrollback: ControlCaptureLimits.maxScrollback)
        XCTAssertTrue(capture.truncated, "前提：这份样本确实撞上了字节上限")
        XCTAssertEqual(capture.lines - capture.scrollbackLines, viewportRows,
                       "lines - scrollback 必须还是可视区的行数")
        XCTAssertLessThan(capture.scrollbackLines, capture.lines)
        XCTAssertTrue(capture.text.hasSuffix("view-\(viewportRows)"), "最新的那几行永远留着")

        // 不截断时这条等式本来就成立，截断前后要一致
        let small = ControlCommandRunner.assemble(
            viewport: viewport,
            screen: ((1...5).map { "hist-\($0)" } + (1...viewportRows).map { "view-\($0)" })
                .joined(separator: "\n"),
            scrollback: 5)
        XCTAssertFalse(small.truncated)
        XCTAssertEqual(small.scrollbackLines, 5)
        XCTAssertEqual(small.lines - small.scrollbackLines, viewportRows)
    }
}
