import XCTest
@testable import QuickTerm

/// 活着的控制器 → `quickterm.state/1`，以及目标解析落到真实 pane 上。
@MainActor
final class ControlStateTests: XCTestCase {
    private var controller: MainWindowController {
        get throws { try XCTUnwrap((NSApp.delegate as? AppDelegate)?.controller) }
    }

    private var screens: ScreenRegistry {
        get throws { try XCTUnwrap((NSApp.delegate as? AppDelegate)?.screens) }
    }

    private func spin(_ seconds: TimeInterval = 0.15) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private func encoder(trusted: Bool = true, expose: String = "token") throws -> ControlStateEncoder {
        ControlStateEncoder(screens: try screens, trusted: trusted, exposeBrowser: expose, mode: "ask")
    }

    // MARK: 编码

    func testStateIsOneBasedEverywhere() throws {
        let controller = try controller
        controller.model.switchTo(0)
        controller.ensureStarterPane()
        spin()
        let payload = try encoder().payload()
        let screen = try XCTUnwrap(payload.screens.first)
        XCTAssertEqual(screen.index, 1, "屏幕序号 1 起（= 窗口标题）")
        XCTAssertEqual(screen.title, "QuickTerm", "第一个屏幕的标题必须恰好是 QuickTerm")
        XCTAssertEqual(screen.activeWorkspace, 1, "活动工作区 1 起（内部 0 起绝不外泄）")
        XCTAssertEqual(screen.workspaces.first?.index, 1)
        XCTAssertEqual(screen.workspaces.count, controller.model.layouts.count)
        for pane in payload.panes {
            XCTAssertGreaterThanOrEqual(pane.workspace, 1)
            XCTAssertGreaterThanOrEqual(pane.screen, 1)
        }
    }

    func testPanesGetStableTypePrefixedHandles() throws {
        let controller = try controller
        controller.model.switchTo(0)
        controller.perform(.newTerminal)
        spin()
        let pane = try XCTUnwrap(controller.focusedSurface)
        defer {
            controller.closePane(pane, confirmIfNeeded: false, animated: false)
            spin(0.05)
        }
        let handle = ControlHandleRegistry.shared.handle(for: pane)
        XCTAssertTrue(handle.hasPrefix("t"), "终端 pane 的句柄以 t 开头：\(handle)")
        XCTAssertEqual(ControlHandleRegistry.shared.handle(for: pane), handle, "句柄进程内稳定")
        XCTAssertEqual(ControlHandleRegistry.shared.paneID(forHandle: handle), pane.id)

        let payload = try encoder().payload()
        let info = try XCTUnwrap(payload.panes.first { $0.handle == handle })
        XCTAssertEqual(info.kind, "terminal")
        XCTAssertEqual(info.role, "shell")
        XCTAssertEqual(info.id, pane.id.uuidString)
        // 工作区骨架只引用句柄，不重复整条 pane 记录（否则六屏会话的 JSON 会把上下文吃光）
        let workspace = try XCTUnwrap(payload.screens.first?.workspaces.first { $0.active })
        XCTAssertTrue(workspace.panes.contains(handle))
    }

    func testClosingPanesAreNotAddressable() throws {
        let controller = try controller
        controller.model.switchTo(0)
        controller.closeAnimationEnabled = true
        controller.perform(.newTerminal)
        spin()
        let pane = try XCTUnwrap(controller.focusedSurface)
        let handle = ControlHandleRegistry.shared.handle(for: pane)
        controller.closePane(pane, confirmIfNeeded: false, animated: true)
        // 淡出中：仍在 model.layouts 里，但控制面绝不能再指到它
        XCTAssertTrue(controller.model.closingPanes.contains(pane.id), "前提：正在淡出")
        let payload = try encoder().payload()
        XCTAssertFalse(payload.panes.contains { $0.handle == handle }, "淡出中的 pane 不可寻址")
        let addressable = ControlResolver.addressablePanes(in: try screens)
        XCTAssertFalse(addressable.contains { $0.pane === pane })
        controller.flushPendingCloses()
        spin(0.05)
    }

    func testBrowserRedactionRule() throws {
        // 一条规则：没有来源 token 的调用方读不到浏览器 pane 的网址与标题。
        // `quickterm state` 本身就是一个外泄面——浏览器 pane 里装着用户已登录的会话
        XCTAssertTrue(try encoder(trusted: true, expose: "token").exposesBrowser)
        XCTAssertFalse(try encoder(trusted: false, expose: "token").exposesBrowser)
        XCTAssertTrue(try encoder(trusted: false, expose: "always").exposesBrowser)
        XCTAssertFalse(try encoder(trusted: true, expose: "never").exposesBrowser)
    }

    // MARK: 解析

    func testResolvesFocusedAndHandle() throws {
        let controller = try controller
        controller.model.switchTo(0)
        controller.perform(.newTerminal)
        spin()
        let pane = try XCTUnwrap(controller.focusedSurface)
        defer {
            controller.closePane(pane, confirmIfNeeded: false, animated: false)
            spin(0.05)
        }
        let handle = ControlHandleRegistry.shared.handle(for: pane)
        let resolver = ControlResolver(screens: try screens, origin: nil)

        let byHandle = try resolver.resolve(ControlTarget.parse(handle))
        XCTAssertTrue(byHandle.pane === pane)
        XCTAssertEqual(byHandle.echo.screen, 1)
        XCTAssertEqual(byHandle.echo.pane, handle)

        let byPrefix = try resolver.resolve(ControlTarget.parse("#" + pane.id.uuidString.prefix(8)))
        XCTAssertTrue(byPrefix.pane === pane)

        let focused = try resolver.resolve(ControlTarget.parse("@focused"))
        XCTAssertTrue(focused.pane === pane)
    }

    func testResolvesSelfFromOriginEnvironment() throws {
        let controller = try controller
        controller.model.switchTo(0)
        controller.perform(.newTerminal)
        spin()
        let pane = try XCTUnwrap(controller.focusedSurface)
        defer {
            controller.closePane(pane, confirmIfNeeded: false, animated: false)
            spin(0.05)
        }
        let resolver = ControlResolver(screens: try screens,
                                       origin: ControlRequestOrigin(pane: pane.id.uuidString,
                                                                    screen: 1, workspace: 1, pid: 1))
        XCTAssertTrue(try resolver.resolve(ControlTarget.parse("@self")).pane === pane)

        let stale = ControlResolver(screens: try screens,
                                    origin: ControlRequestOrigin(pane: UUID().uuidString,
                                                                 screen: 1, workspace: 1, pid: 1))
        XCTAssertThrowsError(try stale.resolve(ControlTarget.parse("@self")),
                             "QUICKTERM_PANE 指向一个已经不存在的 pane 时必须报错，不能退回焦点 pane")
    }

    func testAmbiguousPredicateListsCandidatesInsteadOfGuessing() throws {
        let controller = try controller
        controller.model.switchTo(0)
        controller.perform(.newTerminal)
        spin()
        let first = try XCTUnwrap(controller.focusedSurface)
        controller.perform(.newTerminal)
        spin()
        let second = try XCTUnwrap(controller.focusedSurface)
        defer {
            for pane in [first, second] {
                controller.closePane(pane, confirmIfNeeded: false, animated: false)
            }
            spin(0.1)
        }
        XCTAssertFalse(first === second)

        let resolver = ControlResolver(screens: try screens, origin: nil)
        do {
            _ = try resolver.resolve(ControlTarget.parse("kind:terminal"))
            XCTFail("两个以上终端 pane 时 kind:terminal 必须报歧义")
        } catch let error as ControlErrorBody {
            XCTAssertEqual(error.code, ControlErrorCode.ambiguousTarget.rawValue)
            XCTAssertEqual(error.exit, ControlExit.badTarget.rawValue)
            let candidates = try XCTUnwrap(error.candidates)
            XCTAssertGreaterThanOrEqual(candidates.count, 2, "报错必须列出全部候选，绝不取第一个")
            XCTAssertTrue(candidates.contains(ControlHandleRegistry.shared.handle(for: first)))
            XCTAssertTrue(candidates.contains(ControlHandleRegistry.shared.handle(for: second)))
        }
    }

    func testWorkspaceOutOfRangeNamesTheCurrentCount() throws {
        let controller = try controller
        let resolver = ControlResolver(screens: try screens, origin: nil)
        let count = controller.model.layouts.count
        do {
            _ = try resolver.resolve(ControlTarget.parse(":\(count + 1)"))
            XCTFail("越界工作区必须报错")
        } catch let error as ControlErrorBody {
            XCTAssertEqual(error.code, ControlErrorCode.notFound.rawValue)
            XCTAssertTrue(error.message.contains("\(count)"), "错误必须说明当前有几个工作区：\(error.message)")
        }
    }

    func testUnknownScreenListsAvailableOnes() throws {
        let resolver = ControlResolver(screens: try screens, origin: nil)
        do {
            _ = try resolver.resolve(ControlTarget.parse("99"))
            XCTFail("不存在的屏幕必须报错")
        } catch let error as ControlErrorBody {
            XCTAssertEqual(error.code, ControlErrorCode.notFound.rawValue)
            XCTAssertFalse(error.candidates?.isEmpty ?? true)
        }
    }

    // MARK: 环境注入

    func testSpawnedPaneCarriesControlEnvironment() throws {
        let injected = ControlEnvironment.inject(into: ["PATH": "/usr/bin"],
                                                 paneID: UUID(uuidString: "9C1B4E2F-0000-0000-0000-000000000000")!,
                                                 screen: 2, workspace: 3)
        XCTAssertEqual(injected["PATH"], "/usr/bin", "既有变量不能被覆盖")
        XCTAssertEqual(injected[ControlProtocol.Env.pane], "9C1B4E2F-0000-0000-0000-000000000000")
        XCTAssertEqual(injected[ControlProtocol.Env.screen], "2")
        XCTAssertEqual(injected[ControlProtocol.Env.workspace], "3")
        // 没在监听时不注入 socket / token（否则 pane 里会拿到一个连不上的路径）
        let socketPath = ControlEnvironment.socketPath
        ControlEnvironment.socketPath = nil
        XCTAssertNil(ControlEnvironment.inject(into: [:], paneID: UUID(), screen: nil,
                                               workspace: nil)[ControlProtocol.Env.socket])
        ControlEnvironment.socketPath = "/tmp/x.sock"
        let mine = UUID()
        let live = ControlEnvironment.inject(into: [:], paneID: mine, screen: nil, workspace: nil)
        XCTAssertEqual(live[ControlProtocol.Env.socket], "/tmp/x.sock")
        XCTAssertEqual(live[ControlProtocol.Env.token], ControlEnvironment.token)
        XCTAssertEqual(ControlEnvironment.token.count, 64, "32 字节随机 → 64 位 hex")

        // 每 pane 一枚的那个标记：**每个 pane 都不一样**，而且只有拿到 paneID 是推不出来的
        // （密钥只留在进程里）。它是 send-text 自写豁免唯一的依据，所以这一条是结构性的
        let paneToken = try XCTUnwrap(live[ControlProtocol.Env.paneToken])
        XCTAssertEqual(paneToken, ControlEnvironment.paneToken(for: mine))
        XCTAssertEqual(paneToken.count, 64, "HMAC-SHA256 → 64 位 hex")
        let other = ControlEnvironment.inject(into: [:], paneID: UUID(), screen: nil, workspace: nil)
        XCTAssertNotEqual(other[ControlProtocol.Env.paneToken], paneToken,
                          "两个 pane 的来源标记必须不同，否则它证明不了「哪一个」")
        XCTAssertNotEqual(paneToken, ControlEnvironment.token,
                          "别把全局 token 与每 pane 一枚的标记混成同一个值")
        ControlEnvironment.socketPath = socketPath
    }

    func testConfigParsesControlSection() {
        let settings = ConfigStore.parse("""
        [control]
        enabled = true
        mode = "readonly"
        expose-browser = "never"
        send-text = true
        """)
        XCTAssertTrue(settings.controlEnabled)
        XCTAssertEqual(settings.controlMode, "readonly")
        XCTAssertEqual(settings.controlExposeBrowser, "never")
        XCTAssertTrue(settings.controlSendText)

        let defaults = ConfigStore.parse("")
        XCTAssertTrue(defaults.controlEnabled, "默认开")
        XCTAssertEqual(defaults.controlMode, "ask", "默认 ask")
        XCTAssertEqual(defaults.controlExposeBrowser, "token")
        XCTAssertFalse(defaults.controlSendText, "send-text 默认关")

        let off = ConfigStore.parse("[control]\nenabled = false\n")
        XCTAssertFalse(off.controlEnabled)
        XCTAssertFalse(ControlCommandRunner.Config(off).isListening)
        XCTAssertFalse(ControlCommandRunner.Config(ConfigStore.parse("[control]\nmode = \"off\"\n")).isListening)
        XCTAssertFalse(ControlCommandRunner.Config(ConfigStore.parse("[control]\nmode = \"readonly\"\n")).allowsMutation)

        // 模板里必须能看到这一段（"所有配置项都要写在配置文件里"）
        XCTAssertTrue(ConfigStore.template.contains("[control]"))
        XCTAssertTrue(ConfigStore.template.contains("expose-browser"))
    }

    func testTestHostNeverBindsTheRealSocket() throws {
        let session = try XCTUnwrap((NSApp.delegate as? AppDelegate)?.session)
        XCTAssertFalse(session.controlServer.isListening,
                       "测试宿主绝不能占用用户那个 QuickTerm 的控制 socket")
        XCTAssertFalse(FileManager.default.fileExists(atPath: ControlPaths.preferredSocketPath)
                       && session.controlServer.socketPath == ControlPaths.preferredSocketPath)
    }
}

/// 对抗评审后补的回归用例：每一条都钉死一个**当时真的存在**的洞。
@MainActor
final class ControlSecurityTests: XCTestCase {
    private var controller: MainWindowController {
        get throws { try XCTUnwrap((NSApp.delegate as? AppDelegate)?.controller) }
    }

    private var screens: ScreenRegistry {
        get throws { try XCTUnwrap((NSApp.delegate as? AppDelegate)?.screens) }
    }

    private func spin(_ seconds: TimeInterval = 0.15) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    // MARK: mode = "on" 曾经是一个"静默关掉确认闸门"的开关

    func testModeOnIsJustAskAndNeverDisablesTheConsentGate() {
        // 模板里把 mode 的取值列成 `off | readonly | ask | on`，而 "on" 从来没被定义过。
        // 用户完全会把它读成 "off 的反义词"（"就打开呗"），一写下去就把整个破坏性确认闸门关了
        XCTAssertEqual(ConfigStore.parse("[control]\nmode = \"on\"\n").controlMode, "ask",
                       "\"on\" 只能是 ask 的别名")

        // 确认闸门只能被显式的 off / readonly 绕开，绝不能被"别的拼法"绕开
        for mode in ["off", "readonly", "ask", "on", "yolo", "ASK", ""] {
            var config = ControlCommandRunner.Config()
            config.mode = mode
            XCTAssertEqual(config.promptsForDestructive, config.allowsMutation,
                           "mode = \"\(mode)\"：只要还能执行变更，破坏性命令就必须确认")
            if config.allowsMutation {
                XCTAssertTrue(config.promptsForDestructive, "mode = \"\(mode)\" 不该成为免确认档")
            }
        }

        // 模板不能再把一个未定义的档位摆在 off 旁边
        let modeLine = ConfigStore.template.split(separator: "\n").first { $0.contains("mode = ") }
        XCTAssertNotNil(modeLine)
        XCTAssertFalse(modeLine?.contains("| on") ?? false, "模板不能再宣传一个 ask 之外的第四档")

        // describe 里那句策略也不能在 readonly 下继续说"会弹确认"
        XCTAssertTrue(ControlDescribeDocument.destructivePolicy(mode: "ask").contains("确认"))
        XCTAssertTrue(ControlDescribeDocument.destructivePolicy(mode: "readonly").contains("拒绝"))
        XCTAssertFalse(ControlDescribeDocument.destructivePolicy(mode: "readonly").contains("确认一次"))
    }

    // MARK: title:~ 曾经能用 7 个字节把整个 app 冻死

    func testTitlePredicateAbortsCatastrophicBacktrackingInsteadOfFreezingTheApp() throws {
        // 调用方给的正则跑在主线程上，而 ICU 是回溯引擎、默认没有时限：
        // 下面这几个模式打在一条普通提示符长度的标题上是指数级的（实测能跑几个钟头）。
        // 而 title: 走 read 类命令——不要 token、不要确认、也不过速率限制
        let title = String(repeating: "a", count: 60) + "!"
        for pattern in ["(a|aa)+$", "(.|.)+z", "(a+)+$"] {
            let regex = try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
            let started = Date()
            let result = ControlResolver.titleMatches(
                title, regex: regex,
                deadline: started.addingTimeInterval(ControlResolver.titleMatchBudget))
            XCTAssertNil(result, "\(pattern) 必须在预算内被掐掉，而不是跑到天荒地老")
            XCTAssertLessThan(Date().timeIntervalSince(started), 2.0,
                              "\(pattern) 超出预算太多：护栏没生效")
        }

        // 正常模式仍然照跑（护栏不能把好用的谓词一起废掉）
        let ok = try NSRegularExpression(pattern: "nvim", options: [.caseInsensitive])
        XCTAssertEqual(ControlResolver.titleMatches("nvim foo.txt", regex: ok,
                                                    deadline: Date().addingTimeInterval(5)), true)
        XCTAssertEqual(ControlResolver.titleMatches("zsh", regex: ok,
                                                    deadline: Date().addingTimeInterval(5)), false)

        // 超时是**整条命令失败**：拿只跑完一半的池子去算歧义 / not_found 就是静默给错答案
        let resolver = ControlResolver(screens: try screens, origin: nil)
        let huge = String(repeating: "x", count: ControlResolver.maxTitlePatternLength + 1)
        do {
            _ = try resolver.resolve(ControlTarget.parse("title:~\(huge)"))
            XCTFail("超长正则必须报错")
        } catch let error as ControlErrorBody {
            XCTAssertEqual(error.code, ControlErrorCode.badTarget.rawValue)
        }
    }

    // MARK: title:~ 曾经是绕过浏览器打码的探测通道

    func testRedactedBrowserPanesLeaveTheTitlePredicatePool() throws {
        let controller = try controller
        controller.model.switchTo(0)
        let previous = BrowserPaneView.settings
        BrowserPaneView.settings.home = "about:blank"        // 不联网
        controller.perform(.newTerminal)
        spin(0.3)
        let terminal = try XCTUnwrap(controller.focusedPane)
        controller.perform(.newBrowser)
        spin(0.5)
        let browser = try XCTUnwrap(controller.paneList.compactMap { $0 as? BrowserPaneView }.last)
        defer {
            for pane in [browser as PaneView, terminal] {
                controller.closePane(pane, confirmIfNeeded: false, animated: false)
            }
            BrowserPaneView.settings = previous
            spin(0.3)
        }
        XCTAssertFalse(browser.paneTitle.isEmpty, "前提：浏览器 pane 有标题可供匹配")
        let browserHandle = ControlHandleRegistry.shared.handle(for: browser)
        let terminalHandle = ControlHandleRegistry.shared.handle(for: terminal)

        // `title:~.` 命中所有非空标题：看谁进了候选池就知道谓词能看到谁
        func visibleHandles(exposesBrowser: Bool) throws -> [String] {
            let resolver = ControlResolver(screens: try screens, origin: nil,
                                           exposesBrowser: exposesBrowser)
            do {
                let resolution = try resolver.resolve(ControlTarget.parse("title:~."))
                return resolution.pane.map { [ControlHandleRegistry.shared.handle(for: $0)] } ?? []
            } catch let error as ControlErrorBody {
                XCTAssertNotEqual(error.code, ControlErrorCode.badTarget.rawValue, error.message)
                return error.candidates ?? []
            }
        }

        XCTAssertTrue(try visibleHandles(exposesBrowser: true).contains(browserHandle),
                      "前提：不打码时浏览器 pane 本来就在候选池里")
        let redacted = try visibleHandles(exposesBrowser: false)
        XCTAssertFalse(redacted.contains(browserHandle),
                       "打码生效时浏览器 pane 不能进 title:~ 的候选池——"
                           + "否则匹配数本身就是一个逐字符问出被打码标题的 oracle")
        XCTAssertTrue(redacted.contains(terminalHandle), "只该拿掉浏览器 pane，不是把谓词整个废掉")
    }

    // MARK: 应用不在前台时曾经"没有任何一块屏幕是 key"

    func testExactlyOneScreenIsKeyEvenWithNoKeyWindow() throws {
        // agent 从 Terminal.app / 后台任务驱动时 NSApp.keyWindow 是 nil，
        // 用它算出来的 payload 每块屏幕都 key:false，而每块屏幕又各报一个 focused:true 的 pane——
        // describe 里"全局唯一的那个在 key:true 的屏幕上"这条消歧规则直接无解
        if NSApp.keyWindow == nil {
            XCTAssertNil(try screens.key, "前提：本用例正跑在\"没有 key 窗口\"那一支上")
        }
        let payload = try ControlStateEncoder(screens: try screens, trusted: true,
                                              exposeBrowser: "token", mode: "ask").payload()
        let keys = payload.screens.filter(\.key)
        XCTAssertEqual(keys.count, 1, "恒有且只有一块屏幕是 key")
        XCTAssertEqual(keys.first?.id, try screens.controlCurrent?.windowID.uuidString,
                       "key 必须和目标解析用的是同一条阶梯（controlCurrent），否则回显与状态互相打架")
    }
}

extension ControlSecurityTests {
    /// 超时与 sheet 的回调会互相追尾：`endSheet` 会**同步**触发 `beginSheetModal` 的
    /// completion，于是排在超时之后的那次 `.deny` 抢先跑掉，agent 收到的是
    /// "用户拒绝了这条命令"（退出码 5）——而用户其实一个字都没说，
    /// 和 describe / 文档里写死的"超时 → 退出码 4"也直接对不上。
    /// 先落定的那个决定必须赢，而且只能回一次
    func testALateAnswerCannotOverwriteTheFirstDecision() {
        let consent = ControlConsent(screens: nil)
        var decisions: [ControlConsent.Decision] = []
        consent.decisionStub = { _, reply in
            reply(.timeout)
            reply(.deny)      // 追尾的第二次回调必须被整个吞掉
        }
        consent.evaluate(.init(peerName: "node", peerPID: 4821, cls: .destructive,
                               summary: "关闭 t7", originPane: nil, tokenPresent: false)) {
            decisions.append($0)
        }
        XCTAssertEqual(decisions, [.timeout], "第二次回调既不能改结论，也不能再回一次")
        XCTAssertFalse(consent.isPrompting, "答复落定后确认状态必须清干净")
        XCTAssertFalse(consent.hasGrant(pid: 4821, cls: .destructive), "超时绝不能留下授权")
        XCTAssertEqual(ControlErrorCode.confirmationRequired.exit, .confirmationRequired,
                       "超时对应退出码 4，不是 denied 的 5")
    }
}
