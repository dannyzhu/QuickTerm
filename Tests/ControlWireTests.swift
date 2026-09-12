import XCTest
@testable import QuickTerm

/// Wire encoding and decoding. Every payload is **parsed a second time with JSONSerialization**:
/// one yabai release hand-assembled a trailing comma into `query --windows` and broke every jq
/// pipeline downstream. The rule here is "everything goes through JSONEncoder", and these cases
/// are what keeps that true.
final class ControlWireTests: XCTestCase {
    private func reparse(_ data: Data, file: StaticString = #filePath, line: UInt = #line) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(object as? [String: Any], file: file, line: line)
    }

    // MARK: Request / response envelopes

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

    /// The `ControlResponse` the server writes and the `ControlReply` the client reads have to be
    /// the same wire shape
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
        let error = ControlErrorBody(.ambiguousTarget, "3 panes match title:~dev",
                                     hint: "use -t <handle> instead", candidates: ["t2", "t7", "b1"])
        XCTAssertEqual(error.exit, ControlExit.badTarget.rawValue,
                       "the CLI uses error.exit directly as its exit code: neither side keeps its own copy of the mapping")
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
                          "\(code.rawValue) maps to an undocumented exit code")
            XCTAssertFalse(code.summary.isEmpty)
        }
    }

    // MARK: NDJSON framing

    func testEncodedLineHasExactlyOneNewlineAtTheEnd() throws {
        // A newline stuffed into a title is the classic agent-hallucinated input; JSONEncoder
        // escapes it, which is the only reason the framing does not get torn apart
        let pane = ControlStatePayload.PaneInfo(
            handle: "t1", id: UUID().uuidString, kind: "terminal", role: "shell",
            screen: 1, workspace: 1, at: .init(column: 0, row: 0, path: nil),
            title: "两\n行", cwd: "/tmp", url: nil, tabs: nil,
            focused: true, busy: false, float: false, zoom: false, redacted: nil)
        let line = try ControlJSON.line(ControlResponse.success(
            id: "1", seq: 1, resolved: nil, data: ControlPanePayload(pane: pane)))
        XCTAssertEqual(line.filter { $0 == 0x0A }.count, 1,
                       "an NDJSON line may contain exactly one newline, the terminating one")
        XCTAssertEqual(line.last, 0x0A)
    }

    func testSlashesAreNotEscaped() throws {
        let payload = ControlVersionPayload(cli: "1.5.8", app: "1.5.8", protocolVersion: 1,
                                            appProtocolVersion: 1,
                                            socket: "/Users/x/Library/Application Support/QuickTerm/control.sock",
                                            running: true)
        let text = try XCTUnwrap(String(data: ControlJSON.encoder.encode(payload), encoding: .utf8))
        XCTAssertFalse(text.contains("\\/"), "a path must not be escaped as \\/ (both humans and models have to read it)")
    }

    // MARK: The output samples embedded in the help must be real JSON

    func testEmbeddedHelpSamplesAreValidJSON() throws {
        for spec in ControlCommandTable.commands {
            guard let sample = spec.outputSample else { continue }
            let data = Data(sample.utf8)
            XCTAssertNoThrow(try JSONSerialization.jsonObject(with: data),
                             "the --help output sample for \(spec.name) is not valid JSON")
        }
    }

    // MARK: describe --json matches the shape it documents for itself

    func testDescribeDocumentShape() throws {
        let document = ControlDescribeDocument.make(cliVersion: "1.5.8", appVersion: "1.5.8",
                                                    socket: "/tmp/x.sock", mode: "ask")
        let data = try ControlJSON.encoder.encode(document)
        let raw = try reparse(data)

        XCTAssertEqual(raw["schema"] as? String, "quickterm.describe/1")
        XCTAssertEqual(raw["protocolVersion"] as? Int, ControlProtocol.version)
        XCTAssertEqual(raw["appRunning"] as? Bool, true)
        XCTAssertEqual(raw["phase"] as? Int, 5)

        // Commands: one-to-one with the command table, each carrying summary / cls / examples
        let commands = try XCTUnwrap(raw["commands"] as? [[String: Any]])
        XCTAssertEqual(commands.count, ControlCommandTable.commands.count)
        for command in commands {
            let name = try XCTUnwrap(command["name"] as? String)
            XCTAssertNotNil(ControlCommandTable.command(name), "describe lists command \(name), which is not in the table")
            XCTAssertFalse((command["summary"] as? String ?? "").isEmpty, "\(name) has no summary")
            XCTAssertTrue(ControlCommandClass.allCases.map(\.rawValue)
                .contains(try XCTUnwrap(command["cls"] as? String)), "the cls of \(name) is not one of the enum values")
            XCTAssertFalse((command["examples"] as? [String] ?? []).isEmpty,
                           "\(name) has no examples -- a model copying an example is far more "
                           + "reliable than one reading prose")
            XCTAssertNotNil(command["args"] as? [[String: Any]], "\(name) has no args array")
        }

        // Target grammar / exit codes / error codes / env vars: every one of those tables has to be present
        let grammar = try XCTUnwrap(raw["targetGrammar"] as? [String: Any])
        XCTAssertEqual(grammar["syntax"] as? String, "screen:workspace.pane")
        XCTAssertFalse((grammar["lines"] as? [String] ?? []).isEmpty)
        XCTAssertEqual((raw["exitCodes"] as? [[String: Any]])?.count, ControlExit.allCases.count)
        XCTAssertEqual((raw["errorCodes"] as? [[String: Any]])?.count, ControlErrorCode.allCases.count)
        let env = try XCTUnwrap(raw["envVars"] as? [[String: Any]])
        XCTAssertEqual(Set(env.compactMap { $0["name"] as? String }),
                       [ControlProtocol.Env.socket, ControlProtocol.Env.pane,
                        ControlProtocol.Env.screen, ControlProtocol.Env.workspace,
                        ControlProtocol.Env.token, ControlProtocol.Env.paneToken])

        // Actions: all 67 of them, not one missing
        let actions = try XCTUnwrap(raw["actions"] as? [[String: Any]])
        XCTAssertEqual(actions.count, WMAction.allCases.count)
    }

    func testDescribeWorksWithoutTheAppRunning() throws {
        let document = ControlDescribeDocument.make(cliVersion: "1.5.8", appVersion: nil,
                                                    socket: nil, mode: nil)
        XCTAssertFalse(document.appRunning)
        XCTAssertEqual(document.commands.count, ControlCommandTable.commands.count,
                       "the schema has to come out even with the app not running -- it is the "
                       + "first call an agent makes in a session")
    }

    // MARK: The state payload

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
                       "handle must always survive, otherwise the projected result cannot be addressed any more")
        XCTAssertNil(projected["kind"])
    }
}
