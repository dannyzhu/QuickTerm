import Foundation

/// `quickterm mcp`: an MCP server over stdio (JSON-RPC 2.0, one object per line).
///
/// It is **not** a second control plane: every `tools/call` opens a socket connection to QuickTerm,
/// sends exactly the request the CLI would send, and hands the response envelope straight back. The
/// tool table comes from `MCPToolMap`, which in turn comes from `ControlCommandTable` — three
/// places, one source, no room for drift.
///
/// Why it is worth having: MCP's **annotations** let the host (Claude Code / Codex) auto-approve
/// reads and prompt on destructive calls at its own layer. That is an **independent second gate**,
/// outside QuickTerm's own confirmation gate; on token cost the CLI still wins (a tool you do not
/// call costs no context).
///
/// **Pure Foundation**: this directory is compiled into both the app and the `quickterm` tool
/// target, so this layer can be driven directly from the tests (in-process, or through a pair of
/// pipes) without attaching it to a real host.
final class MCPServer {
    /// Sends one control request to QuickTerm and brings back the response. On the CLI side each
    /// call opens a fresh connection (the same rule as one connection per CLI command); in tests it
    /// is wired straight to `ControlCommandRunner`.
    typealias Dispatch = (ControlRequest) throws -> ControlReply

    /// The MCP protocol versions we support, newest first. If the client names one that is in the
    /// list we echo it back; otherwise we answer with our newest.
    static let supportedProtocolVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]

    let cliVersion: String
    private let dispatch: Dispatch
    private let environment: [String: String]
    private var nextRequestID = 0
    /// Before `initialize` arrives we answer only `ping` and `initialize` (MCP allows a server to
    /// refuse this way).
    private(set) var initialized = false

    init(cliVersion: String, environment: [String: String] = ProcessInfo.processInfo.environment,
         dispatch: @escaping Dispatch) {
        self.cliVersion = cliVersion
        self.environment = environment
        self.dispatch = dispatch
    }

    // MARK: One line in, one line out

    /// Handles one line of JSON-RPC. Returns the line to write back; a notification (no `id`)
    /// returns nil.
    func handle(line: Data) -> Data? {
        guard let value = try? ControlJSON.decoder.decode(JSONValue.self, from: line) else {
            return encode(Self.errorObject(id: .null, code: -32700, message: "Parse error: not JSON"))
        }
        // As of 2025-06-18 MCP explicitly dropped JSON-RPC batch requests
        guard let object = value.objectValue else {
            return encode(Self.errorObject(id: .null, code: -32600,
                                           message: "Invalid Request: expected a single JSON-RPC object"))
        }
        let id = object["id"]
        guard let method = object["method"]?.stringValue else {
            // An object with no method is a response (we never send requests, so we should never
            // receive one) — drop it silently
            return nil
        }
        let params = object["params"]?.objectValue ?? [:]

        // Notifications: **never answer** (answering one is a protocol error)
        guard let id else {
            return nil
        }

        switch method {
        case "initialize":
            initialized = true
            return encode(Self.resultObject(id: id, result: initializeResult(params: params)))
        case "ping":
            return encode(Self.resultObject(id: id, result: .object([:])))
        case "tools/list":
            guard initialized else { return encode(Self.notInitialized(id: id)) }
            return encode(Self.resultObject(id: id, result: .object([
                "tools": .array(MCPToolMap.tools.map(\.listEntry)),
            ])))
        case "tools/call":
            guard initialized else { return encode(Self.notInitialized(id: id)) }
            return encode(Self.resultObject(id: id, result: callTool(params: params)))
        default:
            return encode(Self.errorObject(id: id, code: -32601, message: "Method not found: \(method)"))
        }
    }

    private func encode(_ value: JSONValue) -> Data? {
        try? ControlJSON.line(value)
    }

    // MARK: initialize

    private func initializeResult(params: [String: JSONValue]) -> JSONValue {
        let asked = params["protocolVersion"]?.stringValue
        let version = Self.supportedProtocolVersions.contains(asked ?? "")
            ? (asked ?? Self.supportedProtocolVersions[0])
            : Self.supportedProtocolVersions[0]
        return .object([
            "protocolVersion": .string(version),
            "capabilities": .object(["tools": .object(["listChanged": .bool(false)])]),
            "serverInfo": .object([
                "name": .string(MCPToolMap.serverName),
                "title": .string("QuickTerm"),
                "version": .string(cliVersion),
            ]),
            "instructions": .string(Self.instructions),
        ])
    }

    static let instructions = """
    Drives a running QuickTerm (screens, workspaces, panes) on this machine.

    Call quickterm_describe once per session — it returns the whole surface as machine schema.
    Prefer the absolute setters in quickterm_arrange over quickterm_action: you cannot see state \
    cheaply, and a retried toggle silently undoes itself.
    To lay out a whole workspace, use quickterm_apply_spec once instead of a loop of \
    quickterm_new_pane calls: one relayout, one animation, one failure point. Dry-run first.
    Ambiguous targets are an error that lists every candidate; never guess, re-address by handle.
    Reads never prompt, but browser pane URLs and titles come back redacted unless this process \
    inherited QUICKTERM_TOKEN from a QuickTerm pane. Destructive calls ask the user inside \
    QuickTerm and fail with confirmation_required if nobody answers.
    """

    private static func notInitialized(id: JSONValue) -> JSONValue {
        errorObject(id: id, code: -32002,
                    message: "Server not initialized: send `initialize` first")
    }

    // MARK: tools/call

    private func callTool(params: [String: JSONValue]) -> JSONValue {
        guard let name = params["name"]?.stringValue else {
            return Self.toolError(ControlErrorBody(.badRequest, "tools/call is missing `name`",
                                                   hint: "Call tools/list first."))
        }
        guard let tool = MCPToolMap.tool(named: name) else {
            return Self.toolError(ControlErrorBody(
                .unknownCommand, "There is no tool named \(name)",
                hint: "tools/list returns the full set of tools.",
                candidates: MCPToolMap.tools.map(\.name)))
        }
        let arguments = params["arguments"]?.objectValue ?? [:]
        let request: ControlRequest
        do {
            request = try buildRequest(tool: tool, arguments: arguments)
        } catch let error as ControlErrorBody {
            return Self.toolError(error)
        } catch {
            return Self.toolError(ControlErrorBody(.internalError, "\(error)"))
        }
        do {
            let reply = try dispatch(request)
            return Self.toolResult(reply)
        } catch let error as ControlErrorBody {
            return Self.toolError(error)
        } catch {
            return Self.toolError(ControlErrorBody(.notRunning, "Cannot reach QuickTerm: \(error)",
                                                   hint: "open -a QuickTerm"))
        }
    }

    /// Turns tool arguments into a control request. **All validation happens here**: an
    /// unrecognized key, a missing required argument, a value outside the enum — each one is an
    /// error on the spot and never silently dropped, because a silently dropped argument is the
    /// hardest class of agent failure to track down.
    func buildRequest(tool: MCPTool, arguments: [String: JSONValue]) throws -> ControlRequest {
        let specs = tool.commands
        let spec: ControlCommandSpec
        if specs.count == 1, arguments["command"] == nil {
            spec = specs[0]
        } else {
            guard let asked = arguments["command"]?.stringValue else {
                throw ControlErrorBody(.badRequest, "\(tool.name) needs a `command` argument",
                                       hint: "One of: \(specs.map(\.cli).joined(separator: " | "))",
                                       candidates: specs.map(\.cli))
            }
            guard let found = ControlCommandTable.command(asked),
                  tool.commandNames.contains(found.name) else {
                throw ControlErrorBody(.unknownCommand, "\(tool.name) does not know command=\(asked)",
                                       hint: "One of: \(specs.map(\.cli).joined(separator: " | "))",
                                       candidates: specs.map(\.cli))
            }
            spec = found
        }

        var allowed = Set(spec.args.map(\.name)).subtracting(MCPToolMap.argsNotExposed)
        allowed.insert("command")
        if spec.acceptsTarget { allowed.insert("target") }
        if spec.honorsMutationFlags {
            allowed.insert(ControlCommandTable.Flag.dryRun)
            allowed.insert(ControlCommandTable.Flag.failIfNoop)
        }
        for key in arguments.keys where !allowed.contains(key) {
            throw ControlErrorBody(.badRequest, "\(spec.cli) does not take the argument \(key)",
                                   hint: "This tool carries several commands and each has its own "
                                       + "arguments: \(spec.cli) takes "
                                       + allowed.sorted().joined(separator: " / "),
                                   candidates: allowed.sorted())
        }

        var args: [String: JSONValue] = [:]
        for arg in spec.args {
            guard let raw = arguments[arg.name] else {
                if arg.required {
                    throw ControlErrorBody(.badRequest,
                                           "\(spec.cli) is missing the required argument \(arg.name)",
                                           hint: arg.help)
                }
                continue
            }
            args[arg.name] = try Self.coerce(raw, to: arg, command: spec.cli)
        }
        if spec.honorsMutationFlags {
            for flag in [ControlCommandTable.Flag.dryRun, ControlCommandTable.Flag.failIfNoop] {
                if let value = arguments[flag]?.boolValue, value { args[flag] = .bool(true) }
            }
        }
        if spec.readsFile, args["spec"] == nil {
            throw ControlErrorBody(.badRequest, "\(spec.cli) needs the spec body passed inline",
                                   hint: "There is no -f on the MCP side: reading a file is always "
                                       + "the caller's job.")
        }

        var target = arguments["target"]?.stringValue
        if let value = target, value.isEmpty { target = nil }
        if target != nil, !spec.acceptsTarget {
            throw ControlErrorBody(.badRequest, "\(spec.cli) does not accept a target")
        }

        nextRequestID += 1
        return ControlRequest(
            id: "mcp-\(nextRequestID)",
            cmd: spec.name,
            target: target,
            args: args,
            token: environment[ControlProtocol.Env.token],
            origin: ControlRequestOrigin(
                pane: environment[ControlProtocol.Env.pane],
                screen: environment[ControlProtocol.Env.screen].flatMap(Int.init),
                workspace: environment[ControlProtocol.Env.workspace].flatMap(Int.init),
                pid: getpid(),
                paneToken: environment[ControlProtocol.Env.paneToken]))
    }

    static func coerce(_ raw: JSONValue, to arg: ControlArgSpec,
                       command: String) throws -> JSONValue {
        func bad(_ want: String) -> ControlErrorBody {
            ControlErrorBody(.badRequest, "\(command): \(arg.name) must be \(want)")
        }
        if arg.repeatable {
            if let array = raw.arrayValue {
                return .array(try array.map { item in
                    guard let text = item.stringValue else { throw bad("an array of strings") }
                    return .string(text)
                })
            }
            guard let text = raw.stringValue else { throw bad("an array of strings") }
            return .array([.string(text)])
        }
        switch arg.kind {
        case .string:
            guard let text = raw.stringValue else { throw bad("a string") }
            return .string(text)
        case .int:
            guard let value = raw.intValue else { throw bad("an integer") }
            return .int(value)
        case .double:
            guard let value = raw.doubleValue else { throw bad("a number") }
            return .double(value)
        case .bool:
            guard let value = raw.boolValue else { throw bad("a boolean") }
            return .bool(value)
        case .enumeration:
            guard let text = raw.stringValue else { throw bad("a string") }
            guard arg.values?.contains(text) ?? true else {
                throw ControlErrorBody(.badRequest,
                                       "\(command): \(arg.name) does not accept \(text)",
                                       hint: "One of: \((arg.values ?? []).joined(separator: " | "))",
                                       candidates: arg.values)
            }
            return .string(text)
        }
    }

    // MARK: Result envelope

    /// The tool result: `structuredContent` is the control plane's response envelope itself (the
    /// same shape as `outputSchema`), and `content` carries a second, pretty-printed copy as JSON
    /// text for hosts that do not understand structuredContent.
    static func toolResult(_ reply: ControlReply) -> JSONValue {
        var envelope: [String: JSONValue] = ["ok": .bool(reply.ok)]
        if let seq = reply.seq { envelope["seq"] = .int(seq) }
        if let resolved = reply.resolved, let value = try? reencode(resolved) {
            envelope["resolved"] = value
        }
        if let data = reply.data { envelope["data"] = data }
        if let error = reply.error, let value = try? reencode(error) {
            envelope["error"] = value
        }
        return result(.object(envelope), isError: !reply.ok)
    }

    static func toolError(_ error: ControlErrorBody) -> JSONValue {
        var envelope: [String: JSONValue] = ["ok": .bool(false)]
        if let value = try? reencode(error) { envelope["error"] = value }
        return result(.object(envelope), isError: true)
    }

    private static func result(_ envelope: JSONValue, isError: Bool) -> JSONValue {
        let text = (try? ControlJSON.prettyEncoder.encode(envelope))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return .object([
            "content": .array([.object(["type": .string("text"), "text": .string(text)])]),
            "structuredContent": envelope,
            "isError": .bool(isError),
        ])
    }

    private static func reencode(_ value: some Encodable) throws -> JSONValue {
        try ControlJSON.decoder.decode(JSONValue.self, from: ControlJSON.encoder.encode(value))
    }

    // MARK: JSON-RPC envelope

    static func resultObject(id: JSONValue, result: JSONValue) -> JSONValue {
        .object(["jsonrpc": .string("2.0"), "id": id, "result": result])
    }

    static func errorObject(id: JSONValue, code: Int, message: String) -> JSONValue {
        .object(["jsonrpc": .string("2.0"), "id": id,
                 "error": .object(["code": .int(code), "message": .string(message)])])
    }

    // MARK: stdio loop

    /// Read a line, handle it, write a line, until the peer closes stdin.
    /// **Never write anything else to stdout**: that pipe is JSON-RPC end to end (logs go to
    /// stderr). The config gate: with `[control] mcp = false` in `~/.config/quickterm/config.toml`
    /// we serve not one byte.
    ///
    /// The gate is pinned to `serve()` rather than only to the `quickterm mcp` command handler —
    /// `serve()` is the single exit through which we actually start speaking MCP, and any future
    /// entry point still has to pass through it.
    /// The error **names the config key**: the host will only show the failure as "the server would
    /// not start", so the user has to be able to get from that sentence straight to the switch they
    /// turned off.
    static func configRefusal(gate: ControlConfigGate = .load(),
                              path: String = ConfigPaths.configURL().path) -> ControlErrorBody? {
        guard !gate.mcp else { return nil }
        return ControlErrorBody(.denied, ControlConfigGate.mcpDisabledMessage(path: path),
                                hint: ControlConfigGate.mcpDisabledHint)
    }

    /// Returns nil on a normal read to end of stream; when the config refuses, returns that error
    /// as-is (the caller turns it into an exit code).
    @discardableResult
    func serve(input: FileHandle = .standardInput, output: FileHandle = .standardOutput,
               gate: ControlConfigGate = .load()) -> ControlErrorBody? {
        if let refusal = Self.configRefusal(gate: gate) { return refusal }
        var buffer = Data()
        while true {
            let chunk = input.availableData
            if chunk.isEmpty { return nil }
            buffer.append(chunk)
            while let index = buffer.firstIndex(of: 0x0A) {
                let line = buffer.subdata(in: buffer.startIndex..<index)
                buffer.removeSubrange(buffer.startIndex...index)
                guard !line.isEmpty else { continue }
                if let reply = handle(line: line) { output.write(reply) }
            }
        }
    }
}
