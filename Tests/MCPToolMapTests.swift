import XCTest
@testable import QuickTerm

/// Phase 5: the MCP tool table and the stdio server.
///
/// This group guards one thing: **the tool table is generated from the command table, not written
/// by hand**. A hand-written copy drifts within two releases, and an agent pays the whole cost of
/// that drift — it calls with a stale schema, gets back an error it cannot explain, and starts
/// guessing. So every piece is pinned here: every command behind a tool resolves, the annotations
/// match the safety classification, every entry in the command table is either covered or carries a
/// written reason for staying off MCP, and the `outputSchema` of the query tools matches what the
/// commands **really** return (compared against real replies, not against a second hand-written
/// list).
@MainActor
final class MCPToolMapTests: XCTestCase {
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

    // MARK: Anti-drift: tools against the command table

    /// Every `command` behind every tool has to resolve in the command table (the foundation the
    /// whole group stands on)
    func testEveryToolMapsToLiveCommandTableEntries() {
        XCTAssertFalse(MCPToolMap.tools.isEmpty)
        XCTAssertEqual(Set(MCPToolMap.tools.map(\.name)).count, MCPToolMap.tools.count, "duplicate tool name")
        for tool in MCPToolMap.tools {
            XCTAssertTrue(tool.name.hasPrefix("quickterm_"),
                          "\(tool.name) needs the prefix: a host has a dozen servers mounted at once")
            XCTAssertFalse(tool.commandNames.isEmpty, "\(tool.name) has no command behind it at all")
            for name in tool.commandNames {
                XCTAssertNotNil(ControlCommandTable.command(name),
                                "\(tool.name) references \(name), which is not in the command table")
            }
            XCTAssertFalse(tool.description.isEmpty)
            XCTAssertTrue(tool.description.contains("Safety:"),
                          "the description of \(tool.name) has to state its safety semantics")
        }
        // A command belongs to exactly one tool: land it in two and the host ends up with two sets
        // of annotations for the same act
        let all = MCPToolMap.tools.flatMap(\.commandNames)
        XCTAssertEqual(Set(all).count, all.count, "a command was picked up by two tools at once")
    }

    /// **The annotations follow the safety classification mechanically.** They are everything the
    /// host's own gate has to go on: slip a destructive command into a tool with readOnlyHint and
    /// Claude Code / Codex waves it straight through
    func testAnnotationsMatchTheCommandClass() {
        for tool in MCPToolMap.tools {
            let classes = tool.commands.map(\.cls)
            XCTAssertEqual(tool.readOnlyHint, classes.allSatisfy { $0 == .read },
                           "the readOnlyHint of \(tool.name) disagrees with the class of the commands behind it")
            XCTAssertEqual(tool.destructiveHint,
                           classes.contains { $0 == .destructive || $0 == .sensitive },
                           "the destructiveHint of \(tool.name) disagrees with the class of the commands behind it")
            XCTAssertEqual(tool.idempotentHint, tool.commands.allSatisfy(\.idempotent),
                           "the idempotentHint of \(tool.name) disagrees with idempotent in the command table")
            XCTAssertFalse(tool.openWorldHint,
                           "the control plane drives this one QuickTerm on this machine, nothing else")
            if tool.readOnlyHint {
                XCTAssertFalse(tool.destructiveHint, "\(tool.name) cannot be read-only and destructive at the same time")
            }
            // The interactive class (actions that pop a panel open) is never exposed as a command
            // at all
            XCTAssertFalse(classes.contains(.interactive), "\(tool.name) picked up an interactive command")
        }
        // Pin the three that matter most by name, so nobody later widens a grouping "while they
        // are in there"
        XCTAssertEqual(MCPToolMap.tool(named: "quickterm_state")?.readOnlyHint, true)
        XCTAssertEqual(MCPToolMap.tool(named: "quickterm_close")?.destructiveHint, true)
        XCTAssertEqual(MCPToolMap.tool(named: "quickterm_send_text")?.destructiveHint, true)
    }

    /// Every entry in the command table is either covered by a tool or carries a reason in
    /// `excluded`. Adding a command and forgetting to expose it over MCP stops right here — rather
    /// than being discovered by some agent six months later
    func testEveryCommandIsEitherExposedOrExplicitlyExcluded() {
        let exposed = Set(MCPToolMap.tools.flatMap(\.commandNames))
        for spec in ControlCommandTable.commands {
            if exposed.contains(spec.name) { continue }
            XCTAssertNotNil(MCPToolMap.excluded[spec.name],
                            "command \(spec.cli) is neither exposed over MCP nor given a reason for staying off")
        }
        for (name, reason) in MCPToolMap.excluded {
            XCTAssertNotNil(ControlCommandTable.command(name), "excluded lists \(name), which is not in the table")
            XCTAssertFalse(reason.isEmpty, "the exclusion reason for \(name) is empty")
            XCTAssertFalse(exposed.contains(name), "\(name) is excluded and exposed at the same time")
        }
    }

    /// Every command **group** needs tool coverage: miss a whole group and an agent cannot reach
    /// it from the MCP side at all
    func testEveryCommandGroupIsCovered() {
        let exposed = Set(MCPToolMap.tools.flatMap(\.commandNames))
        for group in ControlCommandTable.groups {
            let covered = ControlCommandTable.commands(inGroup: group)
                .contains { exposed.contains($0.name) }
            XCTAssertTrue(covered, "command group \(group) has not a single entry in the MCP tool table")
        }
        // The top-level query commands have to be reachable too
        for name in ["state", "list", "get", "action", "describe"] {
            XCTAssertNotNil(MCPToolMap.tool(forCommand: name), "\(name) has no MCP tool of its own")
        }
    }

    /// The input schema covers every argument of every command (except `--file`: reading a file is
    /// always the caller's side of the fence)
    func testInputSchemaCoversEveryArgument() throws {
        for tool in MCPToolMap.tools {
            let schema = try XCTUnwrap(tool.inputSchema.objectValue)
            let properties = try XCTUnwrap(schema["properties"]?.objectValue)
            let required = Set((schema["required"]?.arrayValue ?? []).compactMap(\.stringValue))
            for spec in tool.commands {
                for arg in spec.args where !MCPToolMap.argsNotExposed.contains(arg.name) {
                    let property = try XCTUnwrap(properties[arg.name]?.objectValue,
                                                 "the schema of \(tool.name) is missing \(arg.name) of \(spec.cli)")
                    XCTAssertNotNil(property["type"], "\(arg.name) declares no type")
                    XCTAssertFalse((property["description"]?.stringValue ?? "").isEmpty,
                                   "\(arg.name) has no description")
                }
                if spec.acceptsTarget { XCTAssertNotNil(properties["target"], tool.name) }
                if spec.honorsMutationFlags {
                    XCTAssertNotNil(properties[ControlCommandTable.Flag.dryRun], tool.name)
                    XCTAssertNotNil(properties[ControlCommandTable.Flag.failIfNoop], tool.name)
                }
            }
            if tool.commands.count > 1 {
                XCTAssertTrue(required.contains("command"), "\(tool.name) backs several commands, so command is required")
                let values = Set((properties["command"]?["enum"]?.arrayValue ?? [])
                    .compactMap(\.stringValue))
                XCTAssertEqual(values, Set(tool.commands.map(\.cli)))
            } else if let spec = tool.commands.first {
                for arg in spec.args where arg.required && !MCPToolMap.argsNotExposed.contains(arg.name) {
                    XCTAssertTrue(required.contains(arg.name),
                                  "\(tool.name): \(arg.name) of \(spec.cli) is required")
                }
            }
        }
    }

    /// **`required` may only list arguments that every command behind this tool takes.**
    ///
    /// Regression: `quickterm_dump_spec` backs `spec dump` (which reads no body) and `spec validate`
    /// (which does), and it used to mark `spec` required at the tool level as soon as one of them
    /// was readsFile. A schema-enforcing host then forced the model to pass `spec` every time, while
    /// the server validated the arguments against the command it had parsed — so `spec dump` was
    /// refused by our own side, which means the first half of the dump -> edit -> apply path did not
    /// work over MCP at all
    func testRequiredOnlyListsArgumentsEveryBackingCommandAccepts() throws {
        for tool in MCPToolMap.tools {
            let required = Set((tool.inputSchema["required"]?.arrayValue ?? [])
                .compactMap(\.stringValue))
            for name in required where name != "command" {
                for spec in tool.commands {
                    XCTAssertTrue(spec.args.contains { $0.name == name },
                                  "\(tool.name) marks \(name) required, but \(spec.cli) does not "
                                      + "accept that argument at all")
                }
            }
        }
        let dump = try XCTUnwrap(MCPToolMap.tool(named: "quickterm_dump_spec"))
        XCTAssertFalse((dump.inputSchema["required"]?.arrayValue ?? [])
            .compactMap(\.stringValue).contains("spec"),
            "spec dump reads no body, so spec cannot be required on this tool")
        // apply backs one command and there is no -f on the MCP side, so spec stays required
        // there
        let apply = try XCTUnwrap(MCPToolMap.tool(named: "quickterm_apply_spec"))
        XCTAssertTrue((apply.inputSchema["required"]?.arrayValue ?? [])
            .compactMap(\.stringValue).contains("spec"))

        // End to end: calling `spec dump` without a spec really has to go through
        var sent: [ControlRequest] = []
        let server = try Self.initializedServer { request in
            sent.append(request)
            return try Self.decode(ControlResponse.success(
                id: request.id, seq: 1, resolved: nil,
                data: ControlSpecDumpPayload(scope: "workspace", schema: SpecSchema.workspace,
                                             panes: 1, spec: .object([:]))))
        }
        let reply = try XCTUnwrap(Self.call(server, """
        {"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"quickterm_dump_spec",\
        "arguments":{"command":"spec dump"}}}
        """))
        XCTAssertEqual(reply["result"]?["isError"]?.boolValue, false,
                       "spec dump has to work: \(reply)")
        XCTAssertEqual(sent.last?.cmd, "spec.dump")
    }

    /// **"running it twice gives the same result" may only be written on a tool that really is
    /// idempotent.**
    /// Regression: `safetyLine` only branched on readOnly / destructive, so the description of
    /// `quickterm_new_pane` (backing pane new / screen new, both idempotent:false) claimed
    /// "absolute setters, safe to repeat" while its own annotation said idempotentHint:false — two
    /// contradicting sentences inside one tool object, and the model believes the prose
    func testTheSafetyLineNeverClaimsRepeatSafetyForNonIdempotentTools() {
        for tool in MCPToolMap.tools where !tool.idempotentHint {
            XCTAssertFalse(tool.safetyLine.contains("Absolute setters"),
                           "\(tool.name) is not idempotent, so the description must not claim "
                               + "repeats are safe: \(tool.safetyLine)")
            if !tool.readOnlyHint, !tool.destructiveHint {
                XCTAssertTrue(tool.safetyLine.contains("NOT idempotent"),
                              "\(tool.name) has to say outright that a retry does it again: \(tool.safetyLine)")
            }
        }
        for tool in MCPToolMap.tools where tool.idempotentHint && !tool.readOnlyHint
            && !tool.destructiveHint {
            XCTAssertTrue(tool.safetyLine.contains("Absolute setters"), tool.name)
        }
        XCTAssertEqual(MCPToolMap.tool(named: "quickterm_new_pane")?.idempotentHint, false)
        XCTAssertEqual(MCPToolMap.tool(named: "quickterm_action")?.idempotentHint, false)
    }

    /// **An argument the description mentions has to actually exist in the schema.**
    /// Regression: the destructive branch of `safetyLine` always wrote "Run with dry-run first",
    /// while `quickterm_read_terminal` (backing pane.capture-text, readOnlyEffect) does not accept
    /// that argument at all — following the description gets you a bad_request, or a model
    /// inventing a key the schema never had
    func testAToolNeverAdvisesAFlagItsSchemaDoesNotAccept() throws {
        for tool in MCPToolMap.tools {
            let properties = try XCTUnwrap(tool.inputSchema["properties"]?.objectValue)
            let exposed = properties[ControlCommandTable.Flag.dryRun] != nil
            if !exposed {
                XCTAssertFalse(tool.safetyLine.lowercased().contains("dry-run first"),
                               "\(tool.name) has no dry_run in its schema, so it must not advise a trial run first: "
                                   + tool.safetyLine)
            }
            XCTAssertEqual(exposed, tool.commands.contains(where: \.honorsMutationFlags),
                           "\(tool.name): dry_run appears in the schema if and only if a command behind it accepts it")
        }
        let read = try XCTUnwrap(MCPToolMap.tool(named: "quickterm_read_terminal"))
        XCTAssertTrue(read.destructiveHint, "sensitive still makes the host confirm every time")
        XCTAssertTrue(read.safetyLine.contains("takes no dry-run"),
                      "it has to say outright that it takes neither of those two arguments: \(read.safetyLine)")
    }

    /// When the value sets differ, **declare no enum**: an enum that holds for only one of the
    /// commands is worse than none at all
    func testEnumsAreOnlyDeclaredWhenTheyHoldForEveryCommand() throws {
        let arrange = try XCTUnwrap(MCPToolMap.tool(named: "quickterm_arrange"))
        let properties = try XCTUnwrap(arrange.inputSchema["properties"]?.objectValue)
        // pane set --width is a double while pane resize --width is a string like "+0.05": both
        // types have to be declared
        let width = try XCTUnwrap(properties["width"]?.objectValue)
        let types = Set((width["type"]?.arrayValue ?? []).compactMap(\.stringValue))
        XCTAssertEqual(types, ["number", "string"],
                       "the two commands type width differently, so the schema has to declare both")
        XCTAssertNil(width["enum"])
        // An enum used by only one command is declared as usual
        let layout = try XCTUnwrap(properties["layout"]?.objectValue)
        XCTAssertEqual(Set((layout["enum"]?.arrayValue ?? []).compactMap(\.stringValue)),
                       ["scrolling", "dwindle"])
    }

    // MARK: outputSchema against what the commands **really** return

    /// Compare the schema against real replies: a command returning a key the schema does not have
    /// means the schema has drifted. (Comparing it against a second hand-written field list would be
    /// pointless — that list is the very thing being guarded against.)
    func testOutputSchemaMatchesWhatQueryCommandsActuallyReturn() throws {
        let pane = try harness.newTerminal()
        let handle = ControlHandleRegistry.shared.handle(for: pane)

        var cases: [(command: String, target: String?, args: [String: JSONValue])] = [
            ("state", nil, [:]),
            ("list", nil, ["what": .string("panes")]),
            ("list", nil, ["what": .string("screens")]),
            ("list", nil, ["what": .string("workspaces")]),
            ("get", handle, [:]),
            ("app.get", nil, [:]),
            ("version", nil, [:]),
            ("spec.dump", nil, [:]),
            ("events.poll", nil, ["since": .int(harness.seq), "timeout": .string("0")]),
            // Walk the mutation envelope too (dry-run: not a byte changes)
            ("pane.set", handle, ["zoom": .string("on"), ControlCommandTable.Flag.dryRun: .bool(true)]),
        ]
        cases.append(("action", nil, ["list": .bool(true)]))

        for item in cases {
            let reply = try harness.run(item.command, target: item.target, args: item.args)
            XCTAssertTrue(reply.ok, "\(item.command) did not go through: \(String(describing: reply.error))")
            let tool = try XCTUnwrap(MCPToolMap.tool(forCommand: item.command),
                                     "\(item.command) has no MCP tool of its own")
            let schema = try XCTUnwrap(tool.outputSchema.objectValue)
            let envelope = try XCTUnwrap(schema["properties"]?.objectValue)
            // The envelope itself
            for key in ["ok", "seq", "resolved", "data", "error"] {
                XCTAssertNotNil(envelope[key], "the outputSchema of \(tool.name) is missing envelope field \(key)")
            }
            // The keys inside data
            let declared = Set((envelope["data"]?["properties"]?.objectValue ?? [:]).keys)
            guard !declared.isEmpty else { continue }   // The "big object" of describe is deliberately not expanded
            let actual = Set((reply.data?.objectValue ?? [:]).keys)
            let missing = actual.subtracting(declared)
            XCTAssertTrue(missing.isEmpty,
                          "the outputSchema of \(tool.name) omits keys \(item.command) really returns: \(missing.sorted())")
        }
    }

    /// Records inside an array are described field by field as well: an agent reads
    /// `panes[].handle`, not "an array"
    func testPaneRecordsAreDescribedFieldByField() throws {
        let pane = try harness.newTerminal()
        let reply = try harness.run("list", args: ["what": .string("panes")])
        let tool = try XCTUnwrap(MCPToolMap.tool(forCommand: "list"))
        let panes = try XCTUnwrap(tool.outputSchema["properties"]?["data"]?["properties"]?["panes"]?
            .objectValue)
        let declared = Set((panes["items"]?["properties"]?.objectValue ?? [:]).keys)
        XCTAssertTrue(declared.contains("handle"))
        XCTAssertTrue(declared.contains("kind"))
        let actual = Set((reply.data?["panes"]?.arrayValue?.first?.objectValue ?? [:]).keys)
        XCTAssertTrue(actual.subtracting(declared).isEmpty,
                      "the pane record carries fields the schema never declared: \(actual.subtracting(declared).sorted())")
        XCTAssertFalse(ControlHandleRegistry.shared.handle(for: pane).isEmpty)
    }

    // MARK: The stdio server really does speak MCP

    /// initialize -> tools/list -> one read -> one refused destructive call.
    /// **Not hooked up to a real host**: driving the protocol layer in-process is enough, and a real
    /// host would only turn the case into a nondeterministic external dependency
    func testInitializeListToolsAndDispatchOneReadAndOneRefusedDestructiveCall() throws {
        var sent: [ControlRequest] = []
        let server = MCPServer(cliVersion: "1.5.8", environment: [:]) { request in
            sent.append(request)
            if request.cmd == "pane.close" {
                return try Self.decode(ControlResponse.failure(
                    id: request.id, seq: 412,
                    error: ControlErrorBody(.confirmationRequired, "needs confirmation in QuickTerm",
                                            hint: "approve it in QuickTerm, then retry")))
            }
            return try Self.decode(ControlResponse.success(
                id: request.id, seq: 412, resolved: ResolvedTarget(screen: 1, workspace: 2),
                data: ControlListPayload(panes: [.object(["handle": .string("t7")])])))
        }

        // Before initialize only ping is answered: MCP allows a server to refuse like this, and the
        // refusal itself has to be a clean JSON-RPC error
        let early = try XCTUnwrap(Self.call(server, #"{"jsonrpc":"2.0","id":0,"method":"tools/list"}"#))
        XCTAssertEqual(early["error"]?["code"]?.intValue, -32002)
        XCTAssertNil(early["result"])

        let initialize = try XCTUnwrap(Self.call(server, """
        {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18",\
        "capabilities":{},"clientInfo":{"name":"xctest","version":"1"}}}
        """))
        XCTAssertEqual(initialize["result"]?["protocolVersion"]?.stringValue, "2025-06-18")
        XCTAssertEqual(initialize["result"]?["serverInfo"]?["name"]?.stringValue, "quickterm")
        XCTAssertNotNil(initialize["result"]?["capabilities"]?["tools"])
        XCTAssertTrue((initialize["result"]?["instructions"]?.stringValue ?? "")
            .contains("quickterm_describe"), "instructions have to point an agent at describe")

        // A notification has no id: **not one byte may be written back**
        XCTAssertNil(Self.call(server, #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#))

        let list = try XCTUnwrap(Self.call(server, #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#))
        let tools = try XCTUnwrap(list["result"]?["tools"]?.arrayValue)
        XCTAssertEqual(tools.count, MCPToolMap.tools.count)
        for tool in tools {
            XCTAssertNotNil(tool["name"]?.stringValue)
            XCTAssertNotNil(tool["inputSchema"]?["properties"])
            XCTAssertNotNil(tool["outputSchema"]?["properties"])
            XCTAssertNotNil(tool["annotations"]?["readOnlyHint"]?.boolValue)
        }

        // One read: it lands on the list command and the result comes back unchanged
        let read = try XCTUnwrap(Self.call(server, """
        {"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"quickterm_state",\
        "arguments":{"command":"list","what":"panes"}}}
        """))
        XCTAssertEqual(read["result"]?["isError"]?.boolValue, false)
        XCTAssertEqual(read["result"]?["structuredContent"]?["ok"]?.boolValue, true)
        XCTAssertEqual(read["result"]?["structuredContent"]?["data"]?["panes"]?
            .arrayValue?.first?["handle"]?.stringValue, "t7")
        XCTAssertEqual(sent.last?.cmd, "list")
        XCTAssertEqual(sent.last?.args["what"]?.stringValue, "panes")
        // A host that does not understand structuredContent reads content: that copy has to be the
        // very same envelope
        let text = try XCTUnwrap(read["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue)
        XCTAssertTrue(text.contains("\"ok\""))

        // One refused destructive call: the error is **not** a JSON-RPC error but a tool result
        // with isError
        let destructive = try XCTUnwrap(Self.call(server, """
        {"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"quickterm_close",\
        "arguments":{"command":"pane close","target":"t7"}}}
        """))
        XCTAssertNil(destructive["error"], "a tool that fails goes through isError, not through a protocol error")
        XCTAssertEqual(destructive["result"]?["isError"]?.boolValue, true)
        XCTAssertEqual(destructive["result"]?["structuredContent"]?["error"]?["code"]?.stringValue,
                       ControlErrorCode.confirmationRequired.rawValue)
        XCTAssertEqual(destructive["result"]?["structuredContent"]?["error"]?["exit"]?.intValue,
                       Int(ControlExit.confirmationRequired.rawValue))
        XCTAssertEqual(sent.last?.cmd, "pane.close")
        XCTAssertEqual(sent.last?.target, "t7")
    }

    /// Argument validation happens on the MCP side: an unrecognized key, a value outside the enum,
    /// a missing required argument — every one of them is reported on the spot and **never silently
    /// dropped**, because a silently dropped argument is the hardest class of agent failure to track
    /// down
    func testArgumentValidationRefusesRatherThanSilentlyDropping() throws {
        let server = try Self.initializedServer { _ in
            XCTFail("arguments that failed validation must never be sent")
            throw ControlErrorBody(.internalError, "unreachable")
        }
        // An argument that belongs to a different command
        let stray = try XCTUnwrap(Self.call(server, """
        {"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"quickterm_arrange",\
        "arguments":{"command":"pane move","zoom":"on","to":":4"}}}
        """))
        XCTAssertEqual(stray["result"]?["isError"]?.boolValue, true)
        XCTAssertEqual(stray["result"]?["structuredContent"]?["error"]?["code"]?.stringValue,
                       ControlErrorCode.badRequest.rawValue)
        // A missing required argument
        let missing = try XCTUnwrap(Self.call(server, """
        {"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"quickterm_send_text",\
        "arguments":{"target":"t7"}}}
        """))
        XCTAssertEqual(missing["result"]?["isError"]?.boolValue, true)
        // A tool that does not exist: the error lists every tool name, so an agent never has to
        // guess
        let unknown = try XCTUnwrap(Self.call(server, """
        {"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"quickterm_nope","arguments":{}}}
        """))
        XCTAssertEqual(unknown["result"]?["isError"]?.boolValue, true)
        let candidates = unknown["result"]?["structuredContent"]?["error"]?["candidates"]?.arrayValue
        XCTAssertEqual(candidates?.count, MCPToolMap.tools.count)
    }

    /// `-t` is only sent when the command table says the command accepts a target; `--file` does
    /// not exist on the MCP side at all
    func testTargetAndFileFollowTheCommandTable() throws {
        var sent: [ControlRequest] = []
        let server = try Self.initializedServer { request in
            sent.append(request)
            return try Self.decode(ControlResponse.success(id: request.id, seq: 1, resolved: nil,
                                                           data: ControlSpecValidatePayload(
                                                               valid: true, scope: "workspace",
                                                               schema: SpecSchema.workspace,
                                                               panes: 1, notes: [])))
        }
        let reply = try XCTUnwrap(Self.call(server, """
        {"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"quickterm_dump_spec",\
        "arguments":{"command":"spec validate","spec":"{\\"columns\\":[{\\"panes\\":[{}]}]}"}}}
        """))
        XCTAssertEqual(reply["result"]?["isError"]?.boolValue, false)
        XCTAssertEqual(sent.last?.cmd, "spec.validate")
        XCTAssertNotNil(sent.last?.args["spec"])
        for tool in MCPToolMap.tools {
            XCTAssertNil(tool.inputSchema["properties"]?["file"],
                         "\(tool.name) must not expose --file: reading a file is always the caller's side of the fence")
        }
    }

    /// Through a real pair of pipes, which is exactly what a host sees: one line in, one line out,
    /// and a clean exit as soon as the peer closes stdin
    func testServeOverAPipe() throws {
        let input = Pipe()
        let output = Pipe()
        let server = MCPServer(cliVersion: "1.5.8", environment: [:]) { _ in
            throw ControlErrorBody(.notRunning, "this case does not connect to a real QuickTerm")
        }
        let done = expectation(description: "serve returned")
        DispatchQueue.global().async {
            // Pass the gate explicitly: the default argument `.load()` would read the developer's
            // own config file
            server.serve(input: input.fileHandleForReading, output: output.fileHandleForWriting,
                         gate: ControlConfigGate())
            try? output.fileHandleForWriting.close()
            done.fulfill()
        }
        let request = """
        {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{}}}

        """
        input.fileHandleForWriting.write(Data(request.utf8))
        input.fileHandleForWriting.write(Data("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"ping\"}\n".utf8))
        try input.fileHandleForWriting.close()
        wait(for: [done], timeout: 5)

        var rest = output.fileHandleForReading.readDataToEndOfFile()
        var lines: [Data] = []
        while let index = rest.firstIndex(of: 0x0A) {
            lines.append(rest.subdata(in: rest.startIndex..<index))
            rest.removeSubrange(rest.startIndex...index)
        }
        XCTAssertEqual(lines.count, 2, "one line of request, one line of reply")
        // Subscripting an empty array takes the whole test bundle down (not just this one case),
        // so unwrap first
        let first = try ControlJSON.decoder.decode(JSONValue.self, from: try XCTUnwrap(lines.first))
        // When the client names an older version we support, answer with that version (otherwise
        // the host thinks the handshake failed)
        XCTAssertEqual(first["result"]?["protocolVersion"]?.stringValue, "2024-11-05")
        let second = try ControlJSON.decoder.decode(JSONValue.self, from: try XCTUnwrap(lines.dropFirst().first))
        XCTAssertEqual(second["id"]?.intValue, 2)
        XCTAssertNotNil(second["result"])
    }

    // MARK: helpEN / describe

    /// **Every one** of the 67 actions needs English help: the output of describe gets pasted
    /// verbatim into agent prompts that mix Chinese and English
    func testEveryActionHasBothLanguages() {
        for action in WMAction.allCases {
            XCTAssertFalse(action.help.isEmpty, "\(action.rawValue) has no Chinese help")
            XCTAssertFalse(action.helpEN.isEmpty, "\(action.rawValue) has no English help")
            XCTAssertNotEqual(action.help, action.helpEN, "both help strings of \(action.rawValue) are the same sentence")
            XCTAssertFalse(action.helpEN.contains("？"),
                           "the English help of \(action.rawValue) has Chinese punctuation in it")
        }
        let docs = ControlCommandTable.actionDocs
        XCTAssertEqual(docs.count, WMAction.allCases.count)
        for doc in docs {
            XCTAssertFalse(doc.helpZH.isEmpty, "\(doc.name) has no helpZH")
            XCTAssertFalse(doc.helpEN.isEmpty, "\(doc.name) has no helpEN")
        }
    }

    /// The MCP tool table has to be visible in describe (otherwise an agent can only guess whether
    /// the MCP path exists)
    func testDescribeDocumentsTheToolMap() throws {
        let document = ControlDescribeDocument.make(cliVersion: "1.5.8", appVersion: "1.5.8",
                                                    socket: "/tmp/x.sock", mode: "ask")
        XCTAssertEqual(document.phase, 5)
        XCTAssertEqual(document.mcpTools.count, MCPToolMap.tools.count)
        for doc in document.mcpTools {
            let tool = try XCTUnwrap(MCPToolMap.tool(named: doc.name))
            XCTAssertEqual(doc.commands, tool.commands.map(\.cli))
            XCTAssertEqual(doc.readOnlyHint, tool.readOnlyHint)
            XCTAssertEqual(doc.destructiveHint, tool.destructiveHint)
        }
        // Through JSONEncoder once more: describe is what an agent reads at the start of a session
        // and may not contain half a hand-assembled byte
        let data = try ControlJSON.encoder.encode(document)
        let raw = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual((raw["mcpTools"] as? [[String: Any]])?.count, MCPToolMap.tools.count)
        let actions = try XCTUnwrap(raw["actions"] as? [[String: Any]])
        XCTAssertTrue(actions.allSatisfy { !(($0["helpEN"] as? String) ?? "").isEmpty },
                      "the action table in describe carries both the Chinese and the English help")
    }

    /// **What an agent has to be able to branch on after reading describe once.**
    ///
    /// `ok: true` reads as "everything you asked for happened", and `cwd_denied` is the case where
    /// it did not: the pane opened somewhere other than the directory that was asked for. Same for
    /// `confirmPending` — the call succeeded and the pane is still open, because a human has not
    /// answered yet. Neither is discoverable from `commands[]`, so describe has to say it outright
    /// or the agent only learns it by being wrong once.
    func testDescribeCarriesTheWarningsAndEnvelopeAnAgentBranchesOn() throws {
        let document = ControlDescribeDocument.make(cliVersion: "1.5.9", appVersion: "1.5.9",
                                                    socket: "/tmp/x.sock", mode: "ask")
        XCTAssertEqual(document.warnings.codes.map(\.code), [ControlWarning.cwdDenied],
                       "cwd_denied is the only warning code today; a new one has to be described here too")
        XCTAssertTrue(document.warnings.summary.contains("SUCCESSFUL"),
                      "the point of the section is that a warning rides on a reply that succeeded: "
                          + document.warnings.summary)
        XCTAssertEqual(Set(document.mutationEnvelope.map(\.field)),
                       ["applied", "changed", "confirmPending", "note"])
        XCTAssertTrue(document.mutationEnvelope.allSatisfy { !$0.summary.isEmpty })
        // `--start` used to be appended by hand to the text help only, which left the one flag
        // that makes a command work when QuickTerm is not running out of the machine-readable side
        XCTAssertTrue(document.globalFlags.contains { $0.name == "start" },
                      "--start has to be a row of globalFlags, not a line hand-written into --help")

        // Through the encoder: describe is read as JSON, and a section that only exists in the
        // Swift type is of no use to the caller it was written for
        let data = try ControlJSON.encoder.encode(document)
        let raw = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let warnings = try XCTUnwrap(raw["warnings"] as? [String: Any])
        let codes = try XCTUnwrap(warnings["codes"] as? [[String: Any]])
        XCTAssertEqual(codes.first?["code"] as? String, ControlWarning.cwdDenied)
        XCTAssertEqual((raw["mutationEnvelope"] as? [[String: Any]])?.count, 4)
    }

    /// A tool whose `idempotentHint` is false must not promise repeat safety **in its own summary**
    /// either. `safetyLine` is already pinned, but the summary is the half a model reads first, the
    /// two sit inside one tool object, and when they contradict each other the prose wins.
    /// Regression: `quickterm_arrange` ended with "Running the same call twice leaves the same
    /// state" while backing `pane resize` (a relative step), `pane move` and `pane swap`.
    func testNoToolSummaryPromisesRepeatSafetyItsAnnotationDenies() throws {
        for tool in MCPToolMap.tools where !tool.idempotentHint {
            XCTAssertFalse(tool.summary.contains("Running the same call twice leaves the same state"),
                           "\(tool.name) is annotated idempotentHint=false, so its summary must not tell "
                               + "the model a resend is free: \(tool.summary)")
        }
        let arrange = try XCTUnwrap(MCPToolMap.tool(named: "quickterm_arrange"))
        XCTAssertFalse(arrange.idempotentHint)
        for spec in arrange.commands where !spec.idempotent {
            XCTAssertTrue(arrange.summary.contains(spec.cli),
                          "\(spec.cli) is not replayable, so the summary that groups it with the absolute "
                              + "setters has to name it: \(arrange.summary)")
        }
    }

    /// `mcp` is a local command: sent over the socket it has to be refused explicitly, not fall
    /// into "not implemented in this phase yet"
    func testLocalCommandsAreRefusedOverTheSocket() throws {
        for name in ["mcp", "install-cli"] {
            let spec = try XCTUnwrap(ControlCommandTable.command(name))
            XCTAssertTrue(spec.local, "\(name) should be a local command")
            let reply = try harness.run(name)
            XCTAssertFalse(reply.ok)
            XCTAssertEqual(reply.error?.code, ControlErrorCode.unknownCommand.rawValue)
        }
    }

    // MARK: Helpers

    private static func call(_ server: MCPServer, _ line: String) -> JSONValue? {
        guard let data = server.handle(line: Data(line.utf8)) else { return nil }
        return try? ControlJSON.decoder.decode(JSONValue.self, from: data)
    }

    private static func initializedServer(
        _ dispatch: @escaping MCPServer.Dispatch) throws -> MCPServer {
        let server = MCPServer(cliVersion: "1.5.8", environment: [:], dispatch: dispatch)
        _ = call(server, """
        {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{}}}
        """)
        return server
    }

    /// The `ControlResponse` the server writes -> the `ControlReply` the client reads (through the
    /// real encode/decode)
    private static func decode(_ response: ControlResponse) throws -> ControlReply {
        try ControlJSON.decoder.decode(ControlReply.self, from: ControlJSON.line(response))
    }
}
