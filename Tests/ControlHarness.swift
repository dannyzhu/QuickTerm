import XCTest
@testable import QuickTerm

/// Phase 2 用例的公共夹具：**直接驱动 `ControlCommandRunner`**，不经 socket。
///
/// 为什么不走 socket：Phase 1 已经把"socket → 主线程 hop → runner"这一段钉死了
/// （`ControlServerTests`），再走一遍只是把每个用例都变成异步的。命令语义本身
/// （幂等、dry-run、限流、模态保护、撤销）全在 runner 这一层，同步跑一遍又快又稳。
///
/// 每条响应都会**经 JSONEncoder 编码再解码回来**：顺带把"所有 JSON 走 JSONEncoder"
/// 这条不变量钉在每一个用例上（yabai 的尾逗号事故就发生在手拼 JSON 上）。
@MainActor
final class ControlHarness {
    let app: AppDelegate
    let runner: ControlCommandRunner
    let consent: ControlConsent
    private var nextID = 0
    /// 用例里创建出来的 pane：tearDown 时一律关掉，绝不污染后面的用例
    private(set) var created: [PaneView] = []

    init(allowDestructive: Bool = true) throws {
        app = try XCTUnwrap(NSApp.delegate as? AppDelegate)
        consent = ControlConsent(screens: app.screens)
        if allowDestructive { consent.decisionStub = { _, reply in reply(.allow) } }
        runner = ControlCommandRunner(screens: app.screens, consent: consent)
        runner.config = ControlCommandRunner.Config()
    }

    var controller: MainWindowController {
        get throws { try XCTUnwrap(app.controller) }
    }

    func spin(_ seconds: TimeInterval = 0.25) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    /// 发一条命令，同步拿到解码回来的响应
    @discardableResult
    func run(_ cmd: String, target: String? = nil, args: [String: JSONValue] = [:],
             token: String? = nil, origin: ControlRequestOrigin? = nil,
             file: StaticString = #filePath, line: UInt = #line) throws -> ControlReply {
        nextID += 1
        let request = ControlRequest(id: String(nextID), cmd: cmd, target: target, args: args,
                                     token: token, origin: origin)
        let peer = ControlSocket.Peer(fd: -1, uid: getuid(), pid: getpid(), processName: "xctest")
        var response: ControlResponse?
        runner.handle(request, peer: peer) { response = $0 }
        let got = try XCTUnwrap(response, "命令没有同步返回（确认闸门挂住了？）", file: file, line: line)
        let data = try ControlJSON.line(got)
        return try ControlJSON.decoder.decode(ControlReply.self, from: data)
    }

    /// 变更信封（失败时把 error 打出来，省得对着 nil 猜）
    func mutation(_ reply: ControlReply, file: StaticString = #filePath, line: UInt = #line) throws
        -> [String: JSONValue] {
        XCTAssertTrue(reply.ok, "命令失败：\(String(describing: reply.error))", file: file, line: line)
        return try XCTUnwrap(reply.data?.objectValue, "响应没有 data", file: file, line: line)
    }

    /// 新建一个终端 pane 并记账（用例结束时统一关掉）
    @discardableResult
    func newTerminal(in workspace: Int? = nil) throws -> PaneView {
        let controller = try self.controller
        if let workspace { controller.switchWorkspace(workspace) }
        let before = Set(controller.model.allPanes.map(\.id))
        controller.perform(.newTerminal)
        spin(0.3)
        let pane = try XCTUnwrap(controller.model.allPanes.first { !before.contains($0.id) },
                                 "没能建出新 pane")
        created.append(pane)
        return pane
    }

    func track(_ pane: PaneView) { created.append(pane) }

    /// 一块屏幕的**字节级**结构状态：`--dry-run` 用例靠它证明"一个字节都没改"。
    /// `windowState()` 本身就是纯读（存档路径），Codable，正好当基准——
    /// 但要先把**会自己变**的叶子字段抹掉：里面跑着真的 shell，
    /// OSC 7 的 pwd 与终端标题随时会更新，那不是控制命令改的
    func fingerprint(_ controller: MainWindowController) throws -> String {
        let data = try ControlJSON.encoder.encode(controller.windowState())
        let value = try ControlJSON.decoder.decode(JSONValue.self, from: data)
        let scrubbed = Self.scrub(value)
        return String(decoding: try ControlJSON.encoder.encode(scrubbed), as: UTF8.self)
    }

    /// 抹掉随 shell 自行变化的字段（标题 / cwd）——结构、id、列宽、zoom、焦点一律保留
    static let volatileKeys: Set<String> = ["title", "pwd", "isUserSetTitle"]

    static func scrub(_ value: JSONValue) -> JSONValue {
        switch value {
        case .object(let object):
            var out: [String: JSONValue] = [:]
            for (key, child) in object where !volatileKeys.contains(key) { out[key] = scrub(child) }
            return .object(out)
        case .array(let array):
            return .array(array.map(scrub))
        default:
            return value
        }
    }

    func cleanup() {
        for controller in app.screens.controllers {
            for pane in created where controller.model.allPanes.contains(where: { $0 === pane }) {
                controller.closePane(pane, confirmIfNeeded: false, animated: false)
                controller.removeFromAnyWorkspace(pane)
            }
            controller.flushPendingCloses()
        }
        created.removeAll()
        spin(0.2)
    }
}
