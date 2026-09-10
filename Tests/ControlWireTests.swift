import XCTest
@testable import QuickTerm

/// 线材编解码。每一条负载都**再用 JSONSerialization 解析一遍**：
/// yabai 曾在一个版本里给 `query --windows` 拼出一个尾逗号，打断了所有下游 jq 管道——
/// 这里的规矩是"一切走 JSONEncoder"，用例负责让它保持为真。
final class ControlWireTests: XCTestCase {
    private func reparse(_ data: Data, file: StaticString = #filePath, line: UInt = #line) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(object as? [String: Any], file: file, line: line)
    }

    // MARK: 请求 / 响应信封

    func testRequestRoundTrip() throws {
        let request = ControlRequest(
            id: "7", cmd: "action", target: "2:3.t7",
            args: ["name": .string("new-terminal"), "precise": .bool(true), "count": .int(3)],
            token: "deadbeef",
            origin: ControlRequestOrigin(pane: UUID().uuidString, screen: 1, workspace: 2, pid: 4821))
        let data = try ControlJSON.encoder.encode(request)
        _ = try reparse(data)
        let decoded = try ControlJSON.decoder.decode(ControlRequest.self, from: data)
        XCTAssertEqual(decoded.id, "7")
        XCTAssertEqual(decoded.cmd, "action")
        XCTAssertEqual(decoded.target, "2:3.t7")
        XCTAssertEqual(decoded.args["name"]?.stringValue, "new-terminal")
        XCTAssertEqual(decoded.args["precise"]?.boolValue, true)
        XCTAssertEqual(decoded.args["count"]?.intValue, 3)
        XCTAssertEqual(decoded.origin?.pid, 4821)
        XCTAssertEqual(decoded.v, ControlProtocol.version)
    }

    /// 服务端写的 `ControlResponse` 与客户端读的 `ControlReply` 必须是同一个线形状
    func testResponseAndReplyAreTheSameShape() throws {
        let payload = ControlActionPayload(action: "new-terminal", cls: .mutate, applied: true,
                                           confirmPending: nil, focusPending: nil, panes: nil)
        let response = ControlResponse.success(
            id: "1", seq: 412,
            resolved: ResolvedTarget(screen: 1, screenID: "S", workspace: 2, pane: "t7", paneID: "P"),
            data: payload)
        let data = try ControlJSON.encoder.encode(response)
        let raw = try reparse(data)
        XCTAssertEqual(raw["ok"] as? Bool, true)
        XCTAssertEqual(raw["seq"] as? Int, 412)

        let reply = try ControlJSON.decoder.decode(ControlReply.self, from: data)
        XCTAssertTrue(reply.ok)
        XCTAssertEqual(reply.seq, 412)
        XCTAssertEqual(reply.resolved?.pane, "t7")
        XCTAssertEqual(reply.data?["action"]?.stringValue, "new-terminal")
        XCTAssertNil(reply.error)
    }

    func testErrorEnvelopeCarriesItsOwnExitCode() throws {
        let error = ControlErrorBody(.ambiguousTarget, "3 个 pane 匹配 title:~dev",
                                     hint: "改用 -t <句柄>", candidates: ["t2", "t7", "b1"])
        XCTAssertEqual(error.exit, ControlExit.badTarget.rawValue,
                       "CLI 直接拿 error.exit 当退出码：两边不许各存一份映射表")
        let data = try ControlJSON.encoder.encode(
            ControlResponse.failure(id: "1", seq: 7, error: error))
        let raw = try reparse(data)
        let body = try XCTUnwrap(raw["error"] as? [String: Any])
        XCTAssertEqual(body["code"] as? String, "ambiguous_target")
        XCTAssertEqual((body["candidates"] as? [String])?.count, 3)
        XCTAssertEqual(body["exit"] as? Int, 3)
    }

    func testEveryErrorCodeMapsToADocumentedExit() {
        for code in ControlErrorCode.allCases {
            XCTAssertTrue(ControlExit.allCases.contains(code.exit),
                          "\(code.rawValue) 映射到了没有文档的退出码")
            XCTAssertFalse(code.summary.isEmpty)
        }
    }

    // MARK: NDJSON 分帧

    func testEncodedLineHasExactlyOneNewlineAtTheEnd() throws {
        // 标题里塞换行是 agent 幻觉出来的典型输入；JSONEncoder 会转义它，分帧才不会被撕开
        let pane = ControlStatePayload.PaneInfo(
            handle: "t1", id: UUID().uuidString, kind: "terminal", role: "shell",
            screen: 1, workspace: 1, at: .init(column: 0, row: 0, path: nil),
            title: "两\n行", cwd: "/tmp", url: nil, tabs: nil,
            focused: true, busy: false, float: false, zoom: false, redacted: nil)
        let line = try ControlJSON.line(ControlResponse.success(
            id: "1", seq: 1, resolved: nil, data: ControlPanePayload(pane: pane)))
        XCTAssertEqual(line.filter { $0 == 0x0A }.count, 1, "NDJSON 一行只能有结尾那一个换行")
        XCTAssertEqual(line.last, 0x0A)
    }

    func testSlashesAreNotEscaped() throws {
        let payload = ControlVersionPayload(cli: "1.5.8", app: "1.5.8", protocolVersion: 1,
                                            appProtocolVersion: 1,
                                            socket: "/Users/x/Library/Application Support/QuickTerm/control.sock",
                                            running: true)
        let text = try XCTUnwrap(String(data: ControlJSON.encoder.encode(payload), encoding: .utf8))
        XCTAssertFalse(text.contains("\\/"), "路径不该被转义成 \\/（人和模型都要读它）")
    }

    // MARK: 帮助里内嵌的输出样例必须是真 JSON

    func testEmbeddedHelpSamplesAreValidJSON() throws {
        for spec in ControlCommandTable.commands {
            guard let sample = spec.outputSample else { continue }
            let data = Data(sample.utf8)
            XCTAssertNoThrow(try JSONSerialization.jsonObject(with: data),
                             "\(spec.name) 的 --help 输出样例不是合法 JSON")
        }
    }

    // MARK: describe --json 符合它自己文档的形状

    func testDescribeDocumentShape() throws {
        let document = ControlDescribeDocument.make(cliVersion: "1.5.8", appVersion: "1.5.8",
                                                    socket: "/tmp/x.sock", mode: "ask")
        let data = try ControlJSON.encoder.encode(document)
        let raw = try reparse(data)

        XCTAssertEqual(raw["schema"] as? String, "quickterm.describe/1")
        XCTAssertEqual(raw["protocolVersion"] as? Int, ControlProtocol.version)
        XCTAssertEqual(raw["appRunning"] as? Bool, true)
        XCTAssertEqual(raw["phase"] as? Int, 1)

        // 命令：与命令表一一对应，且每条都有 summary / cls / examples
        let commands = try XCTUnwrap(raw["commands"] as? [[String: Any]])
        XCTAssertEqual(commands.count, ControlCommandTable.commands.count)
        for command in commands {
            let name = try XCTUnwrap(command["name"] as? String)
            XCTAssertNotNil(ControlCommandTable.command(name), "describe 里出现了表外的命令 \(name)")
            XCTAssertFalse((command["summary"] as? String ?? "").isEmpty, "\(name) 缺 summary")
            XCTAssertTrue(ControlCommandClass.allCases.map(\.rawValue)
                .contains(try XCTUnwrap(command["cls"] as? String)), "\(name) 的 cls 不在枚举里")
            XCTAssertFalse((command["examples"] as? [String] ?? []).isEmpty,
                           "\(name) 没有例子——模型抄例子远比读散文可靠")
            XCTAssertNotNil(command["args"] as? [[String: Any]], "\(name) 缺 args 数组")
        }

        // 目标语法 / 退出码 / 错误码 / 环境变量：三张表都得在
        let grammar = try XCTUnwrap(raw["targetGrammar"] as? [String: Any])
        XCTAssertEqual(grammar["syntax"] as? String, "screen:workspace.pane")
        XCTAssertFalse((grammar["lines"] as? [String] ?? []).isEmpty)
        XCTAssertEqual((raw["exitCodes"] as? [[String: Any]])?.count, ControlExit.allCases.count)
        XCTAssertEqual((raw["errorCodes"] as? [[String: Any]])?.count, ControlErrorCode.allCases.count)
        let env = try XCTUnwrap(raw["envVars"] as? [[String: Any]])
        XCTAssertEqual(Set(env.compactMap { $0["name"] as? String }),
                       [ControlProtocol.Env.socket, ControlProtocol.Env.pane,
                        ControlProtocol.Env.screen, ControlProtocol.Env.workspace,
                        ControlProtocol.Env.token])

        // 动作：67 个一个不少
        let actions = try XCTUnwrap(raw["actions"] as? [[String: Any]])
        XCTAssertEqual(actions.count, WMAction.allCases.count)
    }

    func testDescribeWorksWithoutTheAppRunning() throws {
        let document = ControlDescribeDocument.make(cliVersion: "1.5.8", appVersion: nil,
                                                    socket: nil, mode: nil)
        XCTAssertFalse(document.appRunning)
        XCTAssertEqual(document.commands.count, ControlCommandTable.commands.count,
                       "应用没跑也要能把 schema 给出来——这是 agent 会话开始时的第一次调用")
    }

    // MARK: state 负载

    func testStatePayloadReparses() throws {
        let payload = ControlStatePayload(
            app: .init(version: "1.5.8", protocolVersion: 1, workspaceCount: 5,
                       mode: "ask", trusted: false),
            screens: [.init(index: 1, id: UUID().uuidString, title: "QuickTerm", key: true,
                            activeWorkspace: 2, visibleColumns: 2, fullscreen: false,
                            joinAllSpaces: false, display: .init(uuid: "U", name: "Studio Display"),
                            frame: [0, 0, 2560, 1440],
                            workspaces: [.init(index: 1, layout: "scrolling", empty: true, active: false,
                                               panes: [], zoom: nil, columns: [], tree: nil, floating: [])])],
            panes: [])
        let raw = try reparse(try ControlJSON.encoder.encode(payload))
        XCTAssertEqual(raw["schema"] as? String, "quickterm.state/1")
    }

    func testFieldProjectionKeepsHandle() throws {
        let pane = ControlStatePayload.PaneInfo(
            handle: "t1", id: UUID().uuidString, kind: "terminal", role: "shell",
            screen: 1, workspace: 1, at: nil, title: "zsh", cwd: "/tmp", url: nil, tabs: nil,
            focused: true, busy: false, float: false, zoom: false, redacted: nil)
        let projected = try pane.projected(to: ["cwd", "title"])
        XCTAssertEqual(projected["cwd"]?.stringValue, "/tmp")
        XCTAssertEqual(projected["title"]?.stringValue, "zsh")
        XCTAssertEqual(projected["handle"]?.stringValue, "t1",
                       "handle 必须永远保留，否则投影出来的结果没法再被寻址")
        XCTAssertNil(projected["kind"])
    }
}
