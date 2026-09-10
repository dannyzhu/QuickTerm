import Darwin
import XCTest
@testable import QuickTerm

/// socket 生命周期 + 端到端一次往返。
/// **绝不碰用户真在跑的那个 QuickTerm 的 socket**：每个用例都把路径注入到临时目录，
/// 而测试宿主自己的 `AppSession` 因为 `AppDelegate.isRunningTests` 根本不会去绑定
/// （与 `SessionStore.writesAllowed` 同一策略）。
@MainActor
final class ControlServerTests: XCTestCase {
    private var paths: [String] = []

    private func tempSocketPath() throws -> String {
        let path = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("qtc-\(UUID().uuidString.prefix(8)).sock")
        try XCTSkipUnless(ControlPaths.fits(path),
                          "临时目录太长，装不进 sun_path 104 字节（用例不会去抢 $TMPDIR 的默认回退路径）")
        paths.append(path)
        return path
    }

    override func tearDown() {
        for path in paths { unlink(path) }
        paths.removeAll()
        super.tearDown()
    }

    private func spin(_ seconds: TimeInterval = 0.2) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private func makeServer(at path: String, mode: String = "ask") throws -> ControlServer {
        let app = try XCTUnwrap(NSApp.delegate as? AppDelegate)
        let consent = ControlConsent(screens: app.screens)
        let server = ControlServer(screens: app.screens, consent: consent, socketPath: path)
        var config = ControlCommandRunner.Config()
        config.mode = mode
        server.apply(config)
        XCTAssertTrue(server.isListening, "服务应已在 \(path) 监听")
        return server
    }

    // MARK: 绑定与权限

    func testBindsWithTightPermissions() throws {
        let path = try tempSocketPath()
        let server = try makeServer(at: path)
        defer { server.stop() }

        var st = stat()
        XCTAssertEqual(lstat(path, &st), 0)
        XCTAssertEqual(st.st_mode & S_IFMT, S_IFSOCK)
        XCTAssertEqual(st.st_mode & 0o777, 0o600, "socket 必须是 0600")
    }

    func testDirectoryIsForcedTo0700() throws {
        let directory = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("qtc-dir-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o755])
        defer { try? FileManager.default.removeItem(atPath: directory) }
        try ControlSocket.prepareDirectory(directory)
        var st = stat()
        XCTAssertEqual(lstat(directory, &st), 0)
        XCTAssertEqual(st.st_mode & 0o777, 0o700, "父目录必须收紧到 0700")
    }

    func testRefusesToBindThroughASymlink() throws {
        let real = try tempSocketPath()
        let link = real + ".link"
        paths.append(link)
        FileManager.default.createFile(atPath: real, contents: Data())
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: real)
        XCTAssertThrowsError(try ControlSocket.reclaimStaleSocket(at: link),
                             "路径是符号链接就等于让别人指定我们往哪写")
    }

    func testRefusesToDeleteANonSocketFile() throws {
        let path = try tempSocketPath()
        FileManager.default.createFile(atPath: path, contents: Data("不是 socket".utf8))
        XCTAssertThrowsError(try ControlSocket.reclaimStaleSocket(at: path),
                             "绝不替用户删一个普通文件")
    }

    func testReclaimsAStaleSocket() throws {
        let path = try tempSocketPath()
        // 绑一个然后直接关掉 fd：文件还在，但没人在听
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = try ControlSocket.sockaddrUn(path)
        _ = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        Darwin.close(fd)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path), "前提：陈旧 socket 文件还在")

        let server = try makeServer(at: path)   // 能起来 = 陈旧文件被清掉了
        defer { server.stop() }
    }

    func testRefusesToStealALiveSocket() throws {
        let path = try tempSocketPath()
        let server = try makeServer(at: path)
        defer { server.stop() }
        XCTAssertThrowsError(try ControlSocket.reclaimStaleSocket(at: path),
                             "真有实例在听就不抢") { error in
            guard case ControlSocket.SocketError.alreadyListening = error else {
                return XCTFail("应报 alreadyListening，实得 \(error)")
            }
        }
    }

    func testExplicitPathNeverFallsBackToTheSharedTmpSocket() {
        // 显式路径过长时必须报错，绝不能悄悄改用 $TMPDIR/quickterm.sock
        // ——那是用户正在跑的那个 QuickTerm 可能占着的位置
        let tooLong = "/tmp/" + String(repeating: "x", count: 120) + ".sock"
        XCTAssertThrowsError(try ControlSocket.prepare(preferred: tooLong, allowFallback: false))
        XCTAssertNoThrow(try ControlSocket.prepare(preferred: tooLong, allowFallback: true))
    }

    func testStopUnlinksTheSocket() throws {
        let path = try tempSocketPath()
        let server = try makeServer(at: path)
        server.stop()
        XCTAssertFalse(server.isListening)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path), "停掉之后不留陈旧 socket")
    }

    // MARK: 对端身份

    func testOnlySameUIDIsAccepted() {
        let mine = ControlSocket.Peer(fd: -1, uid: getuid(), pid: 1, processName: "self")
        let other = ControlSocket.Peer(fd: -1, uid: getuid() &+ 1, pid: 2, processName: "someone")
        XCTAssertTrue(ControlSocket.accepts(mine))
        XCTAssertFalse(ControlSocket.accepts(other), "不同 uid 必须硬拒——这是唯一不可绕过的身份检查")
    }

    func testPeerIdentityReportsTheRealProcess() throws {
        let path = try tempSocketPath()
        let server = try makeServer(at: path)
        defer { server.stop() }
        let client = try ControlClient.connect(candidates: [path])
        defer { client.close() }
        spin(0.2)
        XCTAssertEqual(ControlSocket.processName(for: getpid()).isEmpty, false)
    }

    /// 确认框的**默认按钮必须是"拒绝"**。
    /// 这条是实测事故的回归：默认按钮原本是"允许"，冒烟时一次落在窗口上的回车
    /// 直接把一条破坏性命令批准了（日志里留下 `控制面确认结果：allow`，用户根本没读那个框）。
    /// 安全闸门的默认答案只能是"不"
    func testConsentAlertDefaultsToDeny() {
        let alert = ControlConsent.makeAlert(.init(peerName: "node", peerPID: 4821, cls: .destructive,
                                                   summary: "关闭 pane t7", originPane: "t3",
                                                   tokenPresent: true))
        XCTAssertEqual(alert.buttons.first?.title, "拒绝", "第一个按钮 = 默认按钮，必须是拒绝")
        XCTAssertEqual(alert.buttons.first?.keyEquivalent, "\r", "回车必须落在拒绝上")
        XCTAssertEqual(alert.buttons.last?.title, "允许")
        XCTAssertEqual(alert.buttons.last?.keyEquivalent, "", "允许绝不能有键等价：它必须被点")
        XCTAssertEqual(ControlConsent.allowResponse, .alertSecondButtonReturn,
                       "映射要跟着按钮顺序走，否则回车会变成允许")
        XCTAssertTrue(alert.informativeText.contains("pid 4821"), "框里要写内核给的真实身份")
        XCTAssertTrue(alert.informativeText.contains("自称来自 pane t3"), "来源是自报的，措辞必须写明")
    }

    // MARK: 端到端（同时也是"主线程 hop"的用例）

    /// socket 回调在 io 队列上；命令必须被送回主线程执行。
    /// 送错线程的话 `ControlCommandRunner` 里的 `dispatchPrecondition(.onQueue(.main))` 会直接把用例打断，
    /// 而不是留下一个"偶尔崩在 SwiftUI publish from background"的幽灵。
    func testRequestFromBackgroundThreadIsExecutedOnMain() throws {
        let path = try tempSocketPath()
        let server = try makeServer(at: path)
        defer { server.stop() }

        let box = Box<ControlReply>()
        let done = expectation(description: "state 返回")
        DispatchQueue.global().async {
            defer { done.fulfill() }
            guard let client = try? ControlClient.connect(candidates: [path]) else { return }
            defer { client.close() }
            box.value = try? client.send(ControlRequest(id: "1", cmd: "state"))
        }
        // 主线程必须继续转：命令就是排在这条 run loop 上执行的
        let deadline = Date().addingTimeInterval(5)
        while box.value == nil, Date() < deadline { spin(0.05) }
        wait(for: [done], timeout: 5)

        let got = try XCTUnwrap(box.value, "没有收到响应")
        XCTAssertTrue(got.ok, "\(String(describing: got.error))")
        XCTAssertEqual(got.data?["schema"]?.stringValue, "quickterm.state/1")
        XCTAssertNotNil(got.resolved?.screen)
    }

    func testProtocolMismatchIsExitEight() throws {
        let path = try tempSocketPath()
        let server = try makeServer(at: path)
        defer { server.stop() }
        var request = ControlRequest(id: "1", cmd: "state")
        request.v = ControlProtocol.version + 99
        let reply = try roundTrip(request, at: path)
        XCTAssertFalse(reply.ok)
        XCTAssertEqual(reply.error?.code, ControlErrorCode.protocolMismatch.rawValue)
        XCTAssertEqual(reply.error?.exit, ControlExit.protocolMismatch.rawValue)
        XCTAssertTrue(reply.error?.message.contains("v\(ControlProtocol.version)") ?? false,
                      "版本不匹配必须同时报出两边的版本")
    }

    func testInteractiveActionIsRefusedOverTheSocket() throws {
        let path = try tempSocketPath()
        let server = try makeServer(at: path)
        defer { server.stop() }
        for action in ControlCommandTable.interactiveActions {
            let reply = try roundTrip(ControlRequest(id: "1", cmd: "action",
                                                     args: ["name": .string(action.rawValue)]), at: path)
            XCTAssertFalse(reply.ok, "\(action.rawValue) 不该被执行")
            XCTAssertEqual(reply.error?.code, ControlErrorCode.interactiveAction.rawValue, action.rawValue)
            XCTAssertNotNil(reply.error?.hint, "拒绝时要给出具体去处")
        }
    }

    func testDestructiveActionNeedsConsentAndIsRefusedWhenDenied() throws {
        let path = try tempSocketPath()
        let app = try XCTUnwrap(NSApp.delegate as? AppDelegate)
        let consent = ControlConsent(screens: app.screens)
        consent.decisionStub = { _, reply in reply(.deny) }
        let server = ControlServer(screens: app.screens, consent: consent, socketPath: path)
        server.apply(ControlCommandRunner.Config())
        defer { server.stop() }

        let reply = try roundTrip(ControlRequest(id: "1", cmd: "action",
                                                 args: ["name": .string("close-pane")]), at: path)
        XCTAssertFalse(reply.ok)
        XCTAssertEqual(reply.error?.code, ControlErrorCode.denied.rawValue)
        XCTAssertEqual(reply.error?.exit, ControlExit.denied.rawValue)
    }

    func testConsentIsCachedPerPeerAndClass() throws {
        let app = try XCTUnwrap(NSApp.delegate as? AppDelegate)
        let consent = ControlConsent(screens: app.screens)
        var asked = 0
        consent.decisionStub = { _, reply in
            asked += 1
            reply(.allow)
        }
        let request = ControlConsent.Request(peerName: "node", peerPID: 4821, cls: .destructive,
                                             summary: "关闭 pane", originPane: "t3", tokenPresent: true)
        for _ in 0..<3 {
            consent.evaluate(request) { XCTAssertEqual($0, .allow) }
        }
        XCTAssertEqual(asked, 1, "按 (pid, 类) 只问一次——agent 是成批发命令的，每条都问等于没问")
        consent.evaluate(ControlConsent.Request(peerName: "node", peerPID: 9999, cls: .destructive,
                                                summary: "关闭 pane", originPane: nil,
                                                tokenPresent: false)) { _ in }
        XCTAssertEqual(asked, 2, "换一个进程要重新问")
    }

    func testTokenNeverSkipsConsent() throws {
        // token 是来源证明，不是权限边界：带着正确的 token 也照样要问
        let app = try XCTUnwrap(NSApp.delegate as? AppDelegate)
        let consent = ControlConsent(screens: app.screens)
        var asked = 0
        consent.decisionStub = { request, reply in
            asked += 1
            XCTAssertTrue(request.tokenPresent)
            reply(.allow)
        }
        consent.evaluate(.init(peerName: "codex", peerPID: 12, cls: .destructive,
                               summary: "关闭 pane", originPane: "t1", tokenPresent: true)) { _ in }
        XCTAssertEqual(asked, 1)
    }

    func testReadOnlyModeRefusesMutations() throws {
        let path = try tempSocketPath()
        let server = try makeServer(at: path, mode: "readonly")
        defer { server.stop() }
        let read = try roundTrip(ControlRequest(id: "1", cmd: "state"), at: path)
        XCTAssertTrue(read.ok, "只读模式下读仍然放行")
        let write = try roundTrip(ControlRequest(id: "2", cmd: "action",
                                                 args: ["name": .string("new-terminal")]), at: path)
        XCTAssertFalse(write.ok)
        XCTAssertEqual(write.error?.code, ControlErrorCode.denied.rawValue)
    }

    func testUnknownCommandAndActionListCandidates() throws {
        let path = try tempSocketPath()
        let server = try makeServer(at: path)
        defer { server.stop() }
        let unknown = try roundTrip(ControlRequest(id: "1", cmd: "frobnicate"), at: path)
        XCTAssertEqual(unknown.error?.code, ControlErrorCode.unknownCommand.rawValue)
        XCTAssertFalse(unknown.error?.candidates?.isEmpty ?? true)

        let badAction = try roundTrip(ControlRequest(id: "2", cmd: "action",
                                                     args: ["name": .string("close_pane")]), at: path)
        XCTAssertEqual(badAction.error?.code, ControlErrorCode.unknownAction.rawValue)
        XCTAssertTrue(badAction.error?.candidates?.contains("close-pane") ?? false)
    }

    func testMalformedLineGetsAStructuredError() throws {
        let path = try tempSocketPath()
        let server = try makeServer(at: path)
        defer { server.stop() }

        let box = Box<String>()
        let done = expectation(description: "坏行也要有结构化响应")
        DispatchQueue.global().async {
            defer { done.fulfill() }
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            var addr = try? ControlSocket.sockaddrUn(path)
            guard addr != nil else { return }
            _ = withUnsafePointer(to: &addr!) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            _ = "{ 这不是 JSON\n".withCString { write(fd, $0, strlen($0)) }
            var buffer = [UInt8](repeating: 0, count: 4096)
            let n = read(fd, &buffer, buffer.count)
            if n > 0 { box.value = String(bytes: buffer[0..<n], encoding: .utf8) }
            Darwin.close(fd)
        }
        let deadline = Date().addingTimeInterval(5)
        while box.value == nil, Date() < deadline { spin(0.05) }
        wait(for: [done], timeout: 5)
        let got = try XCTUnwrap(box.value)
        XCTAssertTrue(got.contains("bad_request"), "得到的是：\(got)")
    }

    // MARK: 对抗评审后补的回归用例

    /// 超过 1 MiB 的单行**必须**收到结构化错误，而不是只有一个 EOF。
    /// 原来那行 `send()` 是死代码：它把写排到 io 队列上，而紧接着的 `close()`
    /// 同步跑在前面把 closed 置了位，写到点被 `guard !closed` 吞掉，
    /// 对端只看到"QuickTerm 在应答之前关闭了连接"
    func testOversizedLineGetsAStructuredErrorNotJustEOF() throws {
        let path = try tempSocketPath()
        let server = try makeServer(at: path)
        defer { server.stop() }

        let box = Box<String>()
        let done = expectation(description: "超长行也要有结构化响应")
        DispatchQueue.global().async {
            defer { done.fulfill() }
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard var addr = try? ControlSocket.sockaddrUn(path) else { return }
            _ = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            // 一行到底不带换行：分帧器永远等不到行尾，只能撞上单行上限
            var payload = Data("{\"v\":1,\"id\":\"1\",\"cmd\":\"state\",\"target\":\"".utf8)
            payload.append(Data(repeating: UInt8(ascii: "x"), count: ControlServer.maxLineBytes + 16))
            payload.withUnsafeBytes { raw in
                var offset = 0
                guard let base = raw.baseAddress else { return }
                while offset < raw.count {
                    let n = Darwin.write(fd, base.advanced(by: offset), raw.count - offset)
                    if n > 0 { offset += n; continue }
                    if errno == EINTR { continue }
                    break   // 服务端已经关了连接：写不完也没关系，读回应答才是重点
                }
            }
            var buffer = [UInt8](repeating: 0, count: 8192)
            let n = read(fd, &buffer, buffer.count)
            if n > 0 { box.value = String(bytes: buffer[0..<n], encoding: .utf8) }
            Darwin.close(fd)
        }
        let deadline = Date().addingTimeInterval(10)
        while box.value == nil, Date() < deadline { spin(0.05) }
        wait(for: [done], timeout: 10)
        let got = try XCTUnwrap(box.value, "对端只收到了 EOF —— 承诺的结构化 bad_request 丢了")
        XCTAssertTrue(got.contains("bad_request"), "得到的是：\(got)")
    }

    /// 确认闸门批准的是**具体的那一个 pane**：确认期间目标变了就整条 busy 掉。
    /// 原来是拿调用方的写法（`@focused`，或者干脆没写）去问，用户答完之后才解析——
    /// 用户读到"关闭焦点 pane"，点允许，挨刀的却是别的 pane
    func testConsentPinsTheResolvedPaneSoADriftingFocusCannotRedirectIt() throws {
        let path = try tempSocketPath()
        let app = try XCTUnwrap(NSApp.delegate as? AppDelegate)
        let controller = try XCTUnwrap(app.controller)
        try XCTSkipUnless(controller.model.layouts.count >= 2, "本用例要至少两个工作区")
        controller.model.switchTo(0)
        controller.perform(.newTerminal)
        spin(0.3)
        let victim = try XCTUnwrap(controller.focusedPane)
        defer {
            controller.model.switchTo(0)
            controller.closePane(victim, confirmIfNeeded: false, animated: false)
            spin(0.2)
        }

        let consent = ControlConsent(screens: app.screens)
        var summary = ""
        consent.decisionStub = { request, reply in
            summary = request.summary
            // 用户读确认框的这十秒里，焦点被别的东西挪走了（⌘2、另一条不需确认的 mutate 命令……）
            controller.model.switchTo(1)
            reply(.allow)
        }
        let server = ControlServer(screens: app.screens, consent: consent, socketPath: path)
        server.apply(ControlCommandRunner.Config())
        defer { server.stop() }

        let reply = try roundTrip(ControlRequest(id: "1", cmd: "action",
                                                 args: ["name": .string("close-pane")]), at: path)
        XCTAssertFalse(reply.ok, "目标已经不是确认时那个 pane 了，绝不能照关")
        XCTAssertEqual(reply.error?.code, ControlErrorCode.busy.rawValue)
        XCTAssertTrue(controller.model.allPanes.contains { $0 === victim }, "本次必须什么都没做")

        // 确认框的正文里必须点名那个具体的 pane，而不是只回显调用方的写法
        let handle = ControlHandleRegistry.shared.handle(for: victim)
        XCTAssertTrue(summary.contains(handle), "确认框要点名 \(handle)，实得：\(summary)")
    }

    /// 确认框挂着的时候，**所有**变更命令都得等着。
    /// `isExecuting` 盖不住这一段：它在 `handle()` 把问题问出去之前就已经复位了
    func testMutationsAreRefusedWhileAConfirmationIsPending() throws {
        let path = try tempSocketPath()
        let app = try XCTUnwrap(NSApp.delegate as? AppDelegate)
        let consent = ControlConsent(screens: app.screens)
        let pending = Box<(ControlConsent.Decision) -> Void>()
        consent.decisionStub = { _, reply in pending.value = reply }   // 一直挂着不答
        let server = ControlServer(screens: app.screens, consent: consent, socketPath: path)
        server.apply(ControlCommandRunner.Config())
        defer { server.stop() }

        let first = Box<ControlReply>()
        let firstDone = expectation(description: "破坏性命令最终返回")
        DispatchQueue.global().async {
            defer { firstDone.fulfill() }
            guard let client = try? ControlClient.connect(candidates: [path]) else { return }
            defer { client.close() }
            first.value = try? client.send(ControlRequest(id: "1", cmd: "action",
                                                          args: ["name": .string("close-pane")]))
        }
        let armed = Date().addingTimeInterval(5)
        while pending.value == nil, Date() < armed { spin(0.05) }
        XCTAssertNotNil(pending.value, "前提：确认框已经挂上了")
        XCTAssertTrue(consent.isPrompting)

        let blocked = try roundTrip(ControlRequest(id: "2", cmd: "action",
                                                   args: ["name": .string("new-terminal")]), at: path)
        XCTAssertFalse(blocked.ok, "用户正被一个对话框拦着，绝不能在他背后建 pane")
        XCTAssertEqual(blocked.error?.code, ControlErrorCode.busy.rawValue)
        XCTAssertEqual(blocked.error?.exit, ControlExit.busy.rawValue)

        // 读永远不受影响
        let read = try roundTrip(ControlRequest(id: "3", cmd: "state"), at: path)
        XCTAssertTrue(read.ok, "read 类命令不该被对话框挡住")

        try XCTUnwrap(pending.value)(.deny)
        wait(for: [firstDone], timeout: 10)
        XCTAssertEqual(first.value?.error?.code, ControlErrorCode.denied.rawValue)
    }

    /// 确认框里那句"来自 pane t3"是调用方自报的（CLI 直接抄 `$QUICKTERM_PANE`），
    /// 服务端一个字都验不了。没有本次启动的 token 就一个字都不显示——
    /// 绝不在用户做信任判断的那块屏上，把自报当成事实讲
    func testOriginPaneClaimIsSuppressedWithoutAValidToken() throws {
        let path = try tempSocketPath()
        let app = try XCTUnwrap(NSApp.delegate as? AppDelegate)
        let controller = try XCTUnwrap(app.controller)
        controller.model.switchTo(0)
        controller.perform(.newTerminal)
        spin(0.3)
        let pane = try XCTUnwrap(controller.focusedPane)
        defer {
            controller.closePane(pane, confirmIfNeeded: false, animated: false)
            spin(0.2)
        }
        let handle = ControlHandleRegistry.shared.handle(for: pane)

        let consent = ControlConsent(screens: app.screens)
        let seen = Box<String?>()
        var asked = 0
        consent.decisionStub = { request, reply in
            asked += 1
            seen.value = .some(request.originPane)
            reply(.deny)
        }
        let server = ControlServer(screens: app.screens, consent: consent, socketPath: path)
        server.apply(ControlCommandRunner.Config())
        defer { server.stop() }

        func ask(token: String?) throws -> String? {
            seen.value = nil
            var request = ControlRequest(id: "\(asked + 1)", cmd: "action",
                                         args: ["name": .string("close-pane")])
            request.token = token
            request.origin = ControlRequestOrigin(pane: pane.id.uuidString, screen: 1,
                                                  workspace: 1, pid: 4821)
            _ = try roundTrip(request, at: path)
            return seen.value ?? nil
        }

        XCTAssertNil(try ask(token: nil), "没有 token = 连\"我来自某个 pane\"都没有证据")
        XCTAssertNil(try ask(token: "抄错的 token"), "token 不对也一样，不能显示自报的来源")
        consent.reset()   // 上一次是 deny，没有留下授权；这里只是把 isPrompting 清干净
        XCTAssertEqual(try ask(token: ControlEnvironment.token), handle,
                       "带着本次启动的 token 才显示来源 pane（文案里仍写\"自称\"）")
    }

    // MARK: 工具

    private func roundTrip(_ request: ControlRequest, at path: String) throws -> ControlReply {
        let box = Box<ControlReply>()
        let errorBox = Box<Error>()
        let done = expectation(description: "往返 \(request.cmd)")
        DispatchQueue.global().async {
            defer { done.fulfill() }
            do {
                let client = try ControlClient.connect(candidates: [path])
                defer { client.close() }
                box.value = try client.send(request)
            } catch { errorBox.value = error }
        }
        let deadline = Date().addingTimeInterval(5)
        while box.value == nil, errorBox.value == nil, Date() < deadline { spin(0.05) }
        wait(for: [done], timeout: 5)
        if let failure = errorBox.value { throw failure }
        return try XCTUnwrap(box.value)
    }
}

/// 跨线程传一个值的最小容器（用例里主线程转 run loop、后台线程写结果）
final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: T?
    var value: T? {
        get { lock.lock(); defer { lock.unlock() }; return storage }
        set { lock.lock(); defer { lock.unlock() }; storage = newValue }
    }
}
