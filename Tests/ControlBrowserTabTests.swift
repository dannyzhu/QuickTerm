import XCTest
@testable import QuickTerm

/// `browser open|goto|reload|close` —— 浏览器 pane 里标签这一层。
///
/// 用的是**真的** `BrowserPaneView`（真的 WKWebView），网址一律指向 `127.0.0.1:1`：
/// 连接会立刻被拒（不走 DNS、不出网），而"这个标签要的是哪个网址"照样是确定的
/// （`effectiveURL` 在错误页状态下回退到 `lastRequestedURL`）。
@MainActor
final class ControlBrowserTabTests: XCTestCase {
    private var harness: ControlHarness!
    private var previousSettings: BrowserPaneView.Settings!

    override func setUpWithError() throws {
        try super.setUpWithError()
        harness = try ControlHarness()
        try harness.controller.model.switchTo(0)
        previousSettings = BrowserPaneView.settings
        BrowserPaneView.settings.home = "about:blank"
    }

    override func tearDown() {
        BrowserPaneView.settings = previousSettings
        harness?.cleanup()
        harness = nil
        super.tearDown()
    }

    // MARK: 夹具

    @discardableResult
    private func newBrowser(url: String = "http://127.0.0.1:1/a") throws -> BrowserPaneView {
        let controller = try harness.controller
        let before = Set(controller.model.allPanes.map(\.id))
        _ = try harness.mutation(try harness.run("pane.new", args: [
            "kind": .string("browser"), "url": .string(url),
        ]))
        harness.spin(0.35)
        let made = try XCTUnwrap(harness.app.screens.allPanes.first { !before.contains($0.id) },
                                 "pane new --kind browser 没建出 pane")
        harness.track(made)
        return try XCTUnwrap(made as? BrowserPaneView)
    }

    private func handle(_ pane: PaneView) -> String { ControlHandleRegistry.shared.handle(for: pane) }

    /// 带着来源 token 发（浏览器的标题 / 网址默认对无 token 的调用方打码，
    /// 这几条用例读的就是那些字段）
    @discardableResult
    private func run(_ cmd: String, target: String, args: [String: JSONValue] = [:]) throws -> ControlReply {
        try harness.run(cmd, target: target, args: args, token: ControlEnvironment.token)
    }

    private func tabs(of pane: BrowserPaneView) throws -> [JSONValue] {
        let reply = try run("get", target: handle(pane))
        return try XCTUnwrap(reply.data?["pane"]?["tabList"]?.arrayValue, "get 没有回 tabList")
    }

    // MARK: 一条主路：开 → 换网址 → 刷新 → 关

    /// 四条命令连起来跑一遍，每一步都用 `state` 这一侧的 `tabList` 验证，
    /// 而不是去读实现里的 `pane.tabs`——**agent 看得见的那一份才算数**
    func testOpenNavigateReloadAndCloseATab() throws {
        let browser = try newBrowser()
        XCTAssertEqual(browser.tabs.count, 1)

        // ① open：多一个标签，并且立刻成为当前标签
        let opened = try harness.mutation(try run("browser.open", target: handle(browser),
                                                  args: ["url": .string("http://127.0.0.1:1/b")]))
        XCTAssertEqual(opened["applied"]?.boolValue, true)
        XCTAssertEqual(browser.tabs.count, 2)
        XCTAssertEqual(browser.activeTabIndex, 1, "--activate 默认 on")
        XCTAssertEqual(opened["pane"]?["tabs"]?.intValue, 2)
        XCTAssertEqual(try tabs(of: browser).count, 2)

        // --activate off：开了但不切过去
        _ = try harness.mutation(try run("browser.open", target: handle(browser),
                                         args: ["url": .string("http://127.0.0.1:1/c"),
                                                "activate": .string("off")]))
        XCTAssertEqual(browser.tabs.count, 3)
        XCTAssertEqual(browser.activeTabIndex, 1, "--activate off 不该动当前标签")

        // ② goto：换当前标签的网址
        let moved = try harness.mutation(try run("browser.goto", target: handle(browser),
                                                 args: ["url": .string("http://127.0.0.1:1/d")]))
        XCTAssertEqual(moved["changed"]?.boolValue, true)
        XCTAssertEqual(browser.tabs[1].effectiveURL?.absoluteString, "http://127.0.0.1:1/d")

        // ③ goto 是**绝对设值**：同一个网址再来一次什么都不做，--fail-if-noop 退 7
        let again = try harness.mutation(try run("browser.goto", target: handle(browser),
                                                 args: ["url": .string("http://127.0.0.1:1/d")]))
        XCTAssertEqual(again["changed"]?.boolValue, false)
        XCTAssertEqual(again["applied"]?.boolValue, false)
        let noop = try run("browser.goto", target: handle(browser),
                           args: ["url": .string("http://127.0.0.1:1/d"),
                                  ControlCommandTable.Flag.failIfNoop: .bool(true)])
        XCTAssertFalse(noop.ok)
        XCTAssertEqual(noop.error?.code, ControlErrorCode.noop.rawValue)
        XCTAssertEqual(noop.error?.exit, ControlExit.noop.rawValue)

        // ④ reload：永远有事可做（"刷新"就是它的全部意义），--hard 也一样
        for hard in [false, true] {
            let reloaded = try harness.mutation(try run("browser.reload", target: handle(browser),
                                                        args: ["hard": .bool(hard)]))
            XCTAssertEqual(reloaded["changed"]?.boolValue, true, "hard=\(hard)")
            XCTAssertEqual(reloaded["applied"]?.boolValue, true, "hard=\(hard)")
        }

        // ⑤ close：只掉一个标签，pane 还在
        let closed = try harness.mutation(try run("browser.close", target: handle(browser),
                                                  args: ["tab": .string("2")]))
        XCTAssertEqual(closed["applied"]?.boolValue, true)
        XCTAssertEqual(browser.tabs.count, 2)
        XCTAssertTrue(try harness.controller.model.allPanes.contains { $0 === browser },
                      "还有别的标签时，close 绝不该把 pane 一起关掉")
    }

    /// `--dry-run`：报得出 diff，但**一个标签都不动**
    func testDryRunTouchesNothing() throws {
        let browser = try newBrowser()
        let cases: [(String, [String: JSONValue])] = [
            ("browser.open", ["url": .string("http://127.0.0.1:1/x")]),
            ("browser.close", [:]),
            ("browser.goto", ["url": .string("http://127.0.0.1:1/y")]),
        ]
        for (cmd, args) in cases {
            var withFlag = args
            withFlag[ControlCommandTable.Flag.dryRun] = .bool(true)
            let payload = try harness.mutation(try run(cmd, target: handle(browser), args: withFlag))
            XCTAssertEqual(payload["dryRun"]?.boolValue, true, cmd)
            XCTAssertEqual(payload["applied"]?.boolValue, false, cmd)
            XCTAssertFalse((payload["changes"]?.arrayValue ?? []).isEmpty, "\(cmd) 要说清会改什么")
        }
        XCTAssertEqual(browser.tabs.count, 1, "预演之后标签数一个都不能变")
        XCTAssertEqual(browser.tabs[0].effectiveURL?.absoluteString, "http://127.0.0.1:1/a")
    }

    // MARK: 寻址

    /// 序号 / id / `@active` / `@last` 四种写法都落到同一个标签上，
    /// 越界与认不得的写法**给出明确的错**而不是就近挑一个
    func testTabAddressingResolvesEveryFormAndRefusesTheRest() throws {
        let browser = try newBrowser()
        _ = try run("browser.open", target: handle(browser),
                    args: ["url": .string("http://127.0.0.1:1/b")])
        _ = try run("browser.open", target: handle(browser),
                    args: ["url": .string("http://127.0.0.1:1/c")])
        XCTAssertEqual(browser.tabs.count, 3)
        XCTAssertEqual(browser.activeTabIndex, 2)

        let second = browser.tabs[1]
        let prefix = String(second.id.uuidString.replacingOccurrences(of: "-", with: "").prefix(8))

        // 序号（1 起）与 id 前缀指的是同一个标签
        for (ref, path) in [("2", "by-index"), ("#\(prefix)", "by-id")] {
            _ = try harness.mutation(try run("browser.goto", target: handle(browser),
                                             args: ["tab": .string(ref),
                                                    "url": .string("http://127.0.0.1:1/\(path)")]))
            XCTAssertEqual(second.effectiveURL?.absoluteString, "http://127.0.0.1:1/\(path)",
                           "--tab \(ref) 没落到第 2 个标签上")
        }
        // @active / @last
        _ = try harness.mutation(try run("browser.goto", target: handle(browser),
                                         args: ["tab": .string("@active"),
                                                "url": .string("http://127.0.0.1:1/active")]))
        XCTAssertEqual(browser.tabs[2].effectiveURL?.absoluteString, "http://127.0.0.1:1/active")
        _ = try harness.mutation(try run("browser.goto", target: handle(browser),
                                         args: ["tab": .string("@last"),
                                                "url": .string("http://127.0.0.1:1/last")]))
        XCTAssertEqual(browser.tabs[2].effectiveURL?.absoluteString, "http://127.0.0.1:1/last")

        // 越界：说清楚"只有几个"，并指路怎么看
        let outOfRange = try run("browser.reload", target: handle(browser), args: ["tab": .string("9")])
        XCTAssertFalse(outOfRange.ok)
        XCTAssertEqual(outOfRange.error?.code, ControlErrorCode.notFound.rawValue)
        XCTAssertTrue(outOfRange.error?.message.contains("3") ?? false,
                      "越界要报出实际有几个标签：\(String(describing: outOfRange.error?.message))")
        XCTAssertTrue(outOfRange.error?.hint?.contains("tabList") ?? false)

        // 认不得的写法 / 太短的 id 前缀：bad_request（而不是悄悄当成 @active）
        for bad in ["banana", "0", "#ab"] {
            let reply = try run("browser.reload", target: handle(browser), args: ["tab": .string(bad)])
            XCTAssertFalse(reply.ok, "--tab \(bad) 不该被接受")
            XCTAssertEqual(reply.error?.code, ControlErrorCode.badRequest.rawValue, bad)
        }
        // 对不上任何标签的 id
        let missing = try run("browser.reload", target: handle(browser), args: ["tab": .string("#deadbeef")])
        XCTAssertFalse(missing.ok)
        XCTAssertEqual(missing.error?.code, ControlErrorCode.notFound.rawValue)

        // 终端 pane 上用 browser 组的命令：wrong_pane_kind，而不是一句"什么都没做"
        let terminal = try harness.newTerminal()
        let wrongKind = try run("browser.reload", target: handle(terminal))
        XCTAssertFalse(wrongKind.ok)
        XCTAssertEqual(wrongKind.error?.code, ControlErrorCode.wrongPaneKind.rawValue)
    }

    /// `tabList` 里的 `index` / `id` 与 `--tab` 认的写法是**同一套词**：
    /// agent 读到什么就能拿它去寻址，中间不需要翻译
    func testTabListIsWhatTabAddresses() throws {
        let browser = try newBrowser()
        _ = try run("browser.open", target: handle(browser),
                    args: ["url": .string("http://127.0.0.1:1/b")])
        let list = try tabs(of: browser)
        XCTAssertEqual(list.count, 2)
        XCTAssertEqual(list[0]["index"]?.intValue, 1)
        XCTAssertEqual(list[1]["index"]?.intValue, 2)
        XCTAssertEqual(list[0]["active"]?.boolValue, false)
        XCTAssertEqual(list[1]["active"]?.boolValue, true, "刚开的标签就是当前标签")
        XCTAssertEqual(list[1]["url"]?.stringValue, "http://127.0.0.1:1/b")

        let id = try XCTUnwrap(list[0]["id"]?.stringValue)
        let prefix = String(id.replacingOccurrences(of: "-", with: "").prefix(6))
        _ = try harness.mutation(try run("browser.goto", target: handle(browser),
                                         args: ["tab": .string("#\(prefix)"),
                                                "url": .string("http://127.0.0.1:1/from-list")]))
        XCTAssertEqual(browser.tabs[0].effectiveURL?.absoluteString, "http://127.0.0.1:1/from-list")

        // state 里的 pane 记录也带同一份（`tabs` 仍是那个整数，形状没变）
        let state = try harness.run("state", token: ControlEnvironment.token)
        let pane = try XCTUnwrap(state.data?["panes"]?.arrayValue?
            .first { $0["handle"]?.stringValue == handle(browser) }?.objectValue)
        XCTAssertEqual(pane["tabs"]?.intValue, 2)
        XCTAssertEqual(pane["tabList"]?.arrayValue?.count, 2)
    }

    /// **打码规则一个字都不松。** 没有 token 的调用方读得到 index / id / active（寻址要用），
    /// 读不到任何标题与网址——变更信封里的 diff 同样打码
    func testPerTabDetailIsRedactedForATokenlessCaller() throws {
        let browser = try newBrowser()
        _ = try run("browser.open", target: handle(browser),
                    args: ["url": .string("http://127.0.0.1:1/secret")])

        let reply = try harness.run("get", target: handle(browser))   // 不带 token
        let pane = try XCTUnwrap(reply.data?["pane"]?.objectValue)
        XCTAssertEqual(pane["redacted"]?.boolValue, true)
        XCTAssertEqual(pane["url"]?.stringValue, ControlStateEncoder.redacted)
        let list = try XCTUnwrap(pane["tabList"]?.arrayValue)
        XCTAssertEqual(list.count, 2, "标签的存在与个数本来就是公开的（`tabs` 一直都在）")
        for tab in list {
            XCTAssertEqual(tab["url"]?.stringValue, ControlStateEncoder.redacted)
            XCTAssertEqual(tab["title"]?.stringValue, ControlStateEncoder.redacted)
            XCTAssertNotNil(tab["index"]?.intValue, "序号不泄露任何东西，而寻址要用")
            XCTAssertNotNil(tab["id"]?.stringValue)
        }
        let encoded = String(decoding: try ControlJSON.encoder.encode(pane), as: UTF8.self)
        XCTAssertFalse(encoded.contains("secret"), "整份 pane 记录里都不该出现网址：\(encoded)")

        // 变更信封：`from` 是命令跑之前那个页面的网址——泄出去和直接读 state 没有区别
        let moved = try harness.mutation(try harness.run(
            "browser.goto", target: handle(browser),
            args: ["url": .string("http://127.0.0.1:1/next")]))
        let changes = try XCTUnwrap(moved["changes"]?.arrayValue)
        XCTAssertEqual(changes.first?["from"]?.stringValue, ControlStateEncoder.redacted)
        XCTAssertEqual(changes.first?["to"]?.stringValue, ControlStateEncoder.redacted,
                       "连调用方自己写的那个也照打——否则 diff 本身就成了一个探测器")
    }

    // MARK: 关到最后一个标签 = 关 pane（与 ⌘W 逐字一致）

    /// **同一件事在两个入口必须得到同一个结果。**
    /// 先用 UI 那条路（`perform(.closePane)`）确认语义：多标签时关标签、最后一个标签时关 pane；
    /// 再用命令行走一遍，结果必须一模一样
    func testClosingTheLastTabClosesThePaneExactlyLikeTheUI() throws {
        let controller = try harness.controller

        // ① UI 那条路：两个标签 → ⌘W 只关标签
        let viaUI = try newBrowser()
        _ = try run("browser.open", target: handle(viaUI), args: ["url": .string("http://127.0.0.1:1/b")])
        XCTAssertEqual(viaUI.tabs.count, 2)
        controller.requestFocus(to: viaUI)
        harness.spin(0.2)
        controller.perform(.closePane)
        harness.spin(0.2)
        XCTAssertEqual(viaUI.tabs.count, 1, "前提：多标签时 ⌘W 关的是标签")
        XCTAssertTrue(controller.model.allPanes.contains { $0 === viaUI })
        // 最后一个标签 → ⌘W 关整个 pane
        controller.perform(.closePane)
        harness.spin(0.4)
        controller.flushPendingCloses()
        XCTAssertFalse(controller.model.allPanes.contains { $0 === viaUI },
                       "前提：最后一个标签上 ⌘W 关的是整个 pane")

        // ② 命令行那条路：同样的两步，同样的结果
        let viaCLI = try newBrowser()
        _ = try run("browser.open", target: handle(viaCLI), args: ["url": .string("http://127.0.0.1:1/b")])
        XCTAssertEqual(viaCLI.tabs.count, 2)
        _ = try harness.mutation(try run("browser.close", target: handle(viaCLI)))
        XCTAssertEqual(viaCLI.tabs.count, 1)
        XCTAssertTrue(controller.model.allPanes.contains { $0 === viaCLI })

        let last = try harness.mutation(try run("browser.close", target: handle(viaCLI),
                                                args: ["force": .bool(true)]))
        harness.spin(0.4)
        controller.flushPendingCloses()
        XCTAssertEqual(last["applied"]?.boolValue, true)
        XCTAssertFalse(controller.model.allPanes.contains { $0 === viaCLI },
                       "最后一个标签：命令行也必须把整个 pane 关掉")
        XCTAssertTrue(last["note"]?.stringValue?.contains("last tab") ?? false,
                      "要明说 pane 一起关了：\(String(describing: last["note"]))")
    }

    /// `--others` 永远留下 `--tab` 指的那一个，因此**自己不会关 pane**；
    /// 只剩一个标签时它是空操作
    func testCloseOthersKeepsExactlyTheAddressedTab() throws {
        let browser = try newBrowser()
        for path in ["b", "c", "d"] {
            _ = try run("browser.open", target: handle(browser),
                        args: ["url": .string("http://127.0.0.1:1/\(path)")])
        }
        XCTAssertEqual(browser.tabs.count, 4)
        let keep = browser.tabs[1]

        let payload = try harness.mutation(try run("browser.close", target: handle(browser),
                                                   args: ["tab": .string("2"), "others": .bool(true)]))
        XCTAssertEqual(payload["applied"]?.boolValue, true)
        XCTAssertEqual(browser.tabs.count, 1)
        XCTAssertTrue(browser.tabs[0] === keep, "留下的必须是 --tab 指的那一个")
        XCTAssertTrue(try harness.controller.model.allPanes.contains { $0 === browser },
                      "--others 永远留一个标签，所以绝不会关掉 pane")

        // 只剩一个：空操作（不是"把它也关了"）
        let again = try harness.mutation(try run("browser.close", target: handle(browser),
                                                 args: ["others": .bool(true)]))
        XCTAssertEqual(again["changed"]?.boolValue, false)
        XCTAssertEqual(browser.tabs.count, 1)
    }

    /// 破坏性分级 + 确认框里说的是**具体那件事**（关标签还是连 pane 一起关）
    func testCloseIsDestructiveAndTheDialogSaysWhatWillHappen() throws {
        let spec = try XCTUnwrap(ControlCommandTable.command("browser.close"))
        XCTAssertEqual(spec.cls, .destructive, "关标签会毁掉用户的东西（页面状态、未提交的表单）")
        for other in ControlCommandTable.commands(inGroup: "browser") where other.verb != "close" {
            XCTAssertEqual(other.cls, .mutate, "\(other.cli) 不该是破坏性的")
        }

        let browser = try newBrowser()
        _ = try run("browser.open", target: handle(browser), args: ["url": .string("http://127.0.0.1:1/b")])
        var seen: [ControlConsent.Request] = []
        harness.consent.decisionStub = { request, reply in
            seen.append(request)
            reply(.allow)
        }
        _ = try run("browser.close", target: handle(browser))
        XCTAssertTrue(seen.first?.summary.contains("还剩 1 个") ?? false,
                      "多标签：框里要说这只关一个标签 —— \(String(describing: seen.first?.summary))")

        // **每一次都重来一遍**：破坏性命令按 (pid, 类) 缓存一次授权，
        // 不清掉的话第二条就直接放行了，这条用例也就测不到框里写的是什么
        seen.removeAll()
        harness.consent.reset()
        _ = try run("browser.close", target: handle(browser), args: ["force": .bool(true)])
        harness.spin(0.3)
        XCTAssertTrue(seen.first?.summary.contains("整个 pane") ?? false,
                      "最后一个标签：框里必须说清 pane 会一起关 —— \(String(describing: seen.first?.summary))")

        // 用户拒绝 = 什么都不发生
        let browser2 = try newBrowser()
        harness.consent.reset()
        harness.consent.decisionStub = { _, reply in reply(.deny) }
        let denied = try run("browser.close", target: handle(browser2))
        XCTAssertFalse(denied.ok)
        XCTAssertEqual(denied.error?.code, ControlErrorCode.denied.rawValue)
        XCTAssertEqual(browser2.tabs.count, 1)
        XCTAssertTrue(try harness.controller.model.allPanes.contains { $0 === browser2 })
    }

    // MARK: 网址与标题不进系统日志

    /// **打码不能被一份长期留存的日志绕过去。**
    /// `ControlActivityLog` 把每条变更镜像一份进 OSLog（privacy: .public），
    /// 那份日志落在 /var/db/diagnostics：应用退出之后还在，sysdiagnose 会打包带走。
    /// 带 token 的调用方（也就是用户自己那条日常路径）看得到真网址，于是正是那条路径
    /// 会把网址写上去。应用内那一份照旧写全（看的人就是这台机器前的用户）
    func testBrowserURLsAndTitlesNeverReachTheSystemLog() throws {
        let browser = try newBrowser()
        let secret = "http://127.0.0.1:1/leaky-\(UUID().uuidString.prefix(6))"
        ControlActivityLog.shared.clear()
        _ = try run("browser.goto", target: handle(browser), args: ["url": .string(secret)])
        let entry = try XCTUnwrap(ControlActivityLog.shared.recent(1).first)
        XCTAssertTrue(entry.line.contains(secret), "面板里照旧写全：\(entry.line)")
        XCTAssertFalse(entry.logLine.contains(secret), "OSLog 那一份不能有网址：\(entry.logLine)")
        XCTAssertTrue(entry.logLine.contains(".url"), "路径还是要留着，否则日志白记了")

        // 预演也一样（`--dry-run` 照样记一笔：一条什么都不改的命令不该成为写日志的口子）
        ControlActivityLog.shared.clear()
        _ = try run("browser.goto", target: handle(browser),
                    args: ["url": .string(secret + "/dry"),
                           ControlCommandTable.Flag.dryRun: .bool(true)])
        let dry = try XCTUnwrap(ControlActivityLog.shared.recent(1).first)
        XCTAssertFalse(dry.logLine.contains(secret), "预演更不能：\(dry.logLine)")

        // reload 的 from 也是当前网址；close 的 from 是标签标题（空标题时回退成主机名）
        ControlActivityLog.shared.clear()
        _ = try run("browser.reload", target: handle(browser))
        XCTAssertFalse(try XCTUnwrap(ControlActivityLog.shared.recent(1).first).logLine.contains(secret))

        _ = try run("browser.open", target: handle(browser), args: ["url": .string(secret + "/2")])
        ControlActivityLog.shared.clear()
        harness.consent.decisionStub = { _, reply in reply(.allow) }
        _ = try run("browser.close", target: handle(browser), args: ["tab": .string("2")])
        let closed = try XCTUnwrap(ControlActivityLog.shared.recent(1).first)
        XCTAssertFalse(closed.logLine.contains("127.0.0.1"),
                       "标题/主机名同样不进系统日志：\(closed.logLine)")
    }

    // MARK: goto 不能变成一个问网址的探测器

    /// 读不到网址的调用方（无 token）不该从"改了没有"反推出这个标签停在哪儿。
    /// 回归：`goto` 原本拿调用方给的网址去比 tab 的实时网址，
    /// 于是一条 `--dry-run --fail-if-noop` 的 goto 就是一个"是/否"神谕——
    /// 而同一个调用方读 `state` 拿到的是 `<redacted>`
    func testGotoNeverConfirmsACurrentURLToACallerThatCannotReadIt() throws {
        let browser = try newBrowser(url: "http://127.0.0.1:1/private")
        harness.spin(0.3)
        let current = try XCTUnwrap(browser.tabs[0].effectiveURL?.absoluteString)

        // 不带 token：猜中了也不能被告知"猜中了"
        let probe = try harness.run("browser.goto", target: handle(browser),
                                    args: ["url": .string(current),
                                           ControlCommandTable.Flag.dryRun: .bool(true),
                                           ControlCommandTable.Flag.failIfNoop: .bool(true)])
        XCTAssertTrue(probe.ok, "猜中当前网址不能变成退出码 7：\(String(describing: probe.error))")
        let payload = try harness.mutation(probe)
        XCTAssertEqual(payload["changed"]?.boolValue, true, "对读不到网址的调用方，goto 恒为一次改动")
        let changes = try XCTUnwrap(payload["changes"]?.arrayValue)
        XCTAssertEqual(changes.first?["from"]?.stringValue, ControlStateEncoder.redacted)
        XCTAssertEqual(changes.first?["to"]?.stringValue, ControlStateEncoder.redacted)

        // 猜不中的那一条长得一模一样（两者不可区分才算真的关上了这个通道）
        let miss = try harness.mutation(try harness.run(
            "browser.goto", target: handle(browser),
            args: ["url": .string("http://127.0.0.1:1/nope"),
                   ControlCommandTable.Flag.dryRun: .bool(true),
                   ControlCommandTable.Flag.failIfNoop: .bool(true)]))
        XCTAssertEqual(miss["changed"]?.boolValue, true)
        XCTAssertEqual(miss["changes"]?.arrayValue?.count, changes.count)

        // 带 token 的调用方照旧是绝对设值：已经在那儿就是空操作
        let noop = try run("browser.goto", target: handle(browser),
                           args: ["url": .string(current),
                                  ControlCommandTable.Flag.failIfNoop: .bool(true)])
        XCTAssertFalse(noop.ok, "读得到网址的调用方仍然享有幂等")
        XCTAssertEqual(noop.error?.code, ControlErrorCode.noop.rawValue)
    }

    // MARK: 省略掉的那个斜杠

    /// `browser goto --url http://127.0.0.1:1` 打到一个**已经停在那儿**的标签上：
    /// 是空操作。WebKit 落地的网址带着规范化的路径（`…:1/`），而没有人会那样写——
    /// 照字面比的话，最常见的那种写法（`http://localhost:3000`）永远报"变了"，
    /// 绝对设值的承诺当场作废，页面还被白重载一次
    func testGotoIsIdempotentAcrossAnOmittedTrailingSlash() throws {
        let browser = try newBrowser(url: "http://127.0.0.1:1/")
        harness.spin(0.3)
        XCTAssertEqual(browser.tabs[0].effectiveURL?.absoluteString, "http://127.0.0.1:1/",
                       "前提：标签停在带斜杠的那一个")

        let noop = try run("browser.goto", target: handle(browser),
                           args: ["url": .string("http://127.0.0.1:1"),
                                  ControlCommandTable.Flag.failIfNoop: .bool(true)])
        XCTAssertFalse(noop.ok, "省略斜杠是同一个网址，不该算一次改动")
        XCTAssertEqual(noop.error?.code, ControlErrorCode.noop.rawValue)

        // 真的换了页面那一条照样报"变了"（别把规范化做过头）
        let changed = try harness.mutation(try run("browser.goto", target: handle(browser),
                                                   args: ["url": .string("http://127.0.0.1:1/b")]))
        XCTAssertEqual(changed["changed"]?.boolValue, true)
    }
}
