import Foundation

/// `quickterm mcp`：标准输入输出上的 MCP 服务（JSON-RPC 2.0，一行一个对象）。
///
/// 它**不是**第二套控制面：每次 `tools/call` 都会开一条到 QuickTerm 的 socket 连接、
/// 发一条与 CLI 一模一样的请求，然后把响应信封原样交回去。工具表来自 `MCPToolMap`，
/// 而那张表又来自 `ControlCommandTable` —— 三处同源，漂移不了。
///
/// 为什么值得有：MCP 的**注解**让宿主（Claude Code / Codex）在它那一层就能自动放行读、
/// 对破坏性调用弹确认。那是在 QuickTerm 自己的确认闸门之外、**独立的第二道闸**；
/// 论 token 成本，CLI 一直更省（不调用就不占上下文）。
///
/// **纯 Foundation**：本目录同时编进 app 与 `quickterm` 工具 target，
/// 因此这一层可以在用例里直接驱动（同进程或走一对管道），不必真的挂到一个宿主上。
final class MCPServer {
    /// 把一条控制请求送到 QuickTerm 并拿回响应。CLI 侧每次调用开一条新连接
    /// （与 CLI 每条命令一次连接同一条规矩）；用例侧直接接 `ControlCommandRunner`
    typealias Dispatch = (ControlRequest) throws -> ControlReply

    /// 支持的 MCP 协议版本，新的在前。客户端报的版本在表里就照它回，不在就回我们最新的那个
    static let supportedProtocolVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]

    let cliVersion: String
    private let dispatch: Dispatch
    private let environment: [String: String]
    private var nextRequestID = 0
    /// 收到 `initialize` 之前只回 `ping` 与 `initialize`（MCP 允许服务端这样拒绝）
    private(set) var initialized = false

    init(cliVersion: String, environment: [String: String] = ProcessInfo.processInfo.environment,
         dispatch: @escaping Dispatch) {
        self.cliVersion = cliVersion
        self.environment = environment
        self.dispatch = dispatch
    }

    // MARK: 一行进，一行出

    /// 处理一行 JSON-RPC。返回要写回去的那一行；通知（没有 `id`）返回 nil
    func handle(line: Data) -> Data? {
        guard let value = try? ControlJSON.decoder.decode(JSONValue.self, from: line) else {
            return encode(Self.errorObject(id: .null, code: -32700, message: "Parse error: not JSON"))
        }
        // 2025-06-18 起 MCP 明确去掉了 JSON-RPC 批量请求
        guard let object = value.objectValue else {
            return encode(Self.errorObject(id: .null, code: -32600,
                                           message: "Invalid Request: expected a single JSON-RPC object"))
        }
        let id = object["id"]
        guard let method = object["method"]?.stringValue else {
            // 没有 method 的对象是一条响应（我们不发请求，所以不该收到）——静默丢掉
            return nil
        }
        let params = object["params"]?.objectValue ?? [:]

        // 通知：**绝不回**（回了就是协议错误）
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
            return Self.toolError(ControlErrorBody(.badRequest, "tools/call 缺少 name",
                                                   hint: "先 tools/list"))
        }
        guard let tool = MCPToolMap.tool(named: name) else {
            return Self.toolError(ControlErrorBody(
                .unknownCommand, "没有名为 \(name) 的工具",
                hint: "tools/list 里是全部工具",
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
            return Self.toolError(ControlErrorBody(.notRunning, "连不上 QuickTerm：\(error)",
                                                   hint: "open -a QuickTerm"))
        }
    }

    /// 把工具参数翻成一条控制请求。**校验在这里做完**：认不得的键、缺的必填、
    /// 不在枚举里的值，一律当场报错，绝不悄悄丢掉——静默丢参数是最难查的一类 agent 故障
    func buildRequest(tool: MCPTool, arguments: [String: JSONValue]) throws -> ControlRequest {
        let specs = tool.commands
        let spec: ControlCommandSpec
        if specs.count == 1, arguments["command"] == nil {
            spec = specs[0]
        } else {
            guard let asked = arguments["command"]?.stringValue else {
                throw ControlErrorBody(.badRequest, "\(tool.name) 需要 command 参数",
                                       hint: "可选：\(specs.map(\.cli).joined(separator: " | "))",
                                       candidates: specs.map(\.cli))
            }
            guard let found = ControlCommandTable.command(asked),
                  tool.commandNames.contains(found.name) else {
                throw ControlErrorBody(.unknownCommand, "\(tool.name) 不认得 command=\(asked)",
                                       hint: "可选：\(specs.map(\.cli).joined(separator: " | "))",
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
            throw ControlErrorBody(.badRequest, "\(spec.cli) 不认得参数 \(key)",
                                   hint: "这个工具背着好几条命令，参数各归各的：\(spec.cli) 认的是 "
                                       + allowed.sorted().joined(separator: " / "),
                                   candidates: allowed.sorted())
        }

        var args: [String: JSONValue] = [:]
        for arg in spec.args {
            guard let raw = arguments[arg.name] else {
                if arg.required {
                    throw ControlErrorBody(.badRequest, "\(spec.cli) 缺少必填参数 \(arg.name)",
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
            throw ControlErrorBody(.badRequest, "\(spec.cli) 要把 spec 正文直接给过来",
                                   hint: "MCP 这一侧没有 -f：读文件永远是调用方那边的事")
        }

        var target = arguments["target"]?.stringValue
        if let value = target, value.isEmpty { target = nil }
        if target != nil, !spec.acceptsTarget {
            throw ControlErrorBody(.badRequest, "\(spec.cli) 不接受 target")
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
            ControlErrorBody(.badRequest, "\(command) 的 \(arg.name) 需要\(want)")
        }
        if arg.repeatable {
            if let array = raw.arrayValue {
                return .array(try array.map { item in
                    guard let text = item.stringValue else { throw bad("一组字符串") }
                    return .string(text)
                })
            }
            guard let text = raw.stringValue else { throw bad("一组字符串") }
            return .array([.string(text)])
        }
        switch arg.kind {
        case .string:
            guard let text = raw.stringValue else { throw bad("字符串") }
            return .string(text)
        case .int:
            guard let value = raw.intValue else { throw bad("整数") }
            return .int(value)
        case .double:
            guard let value = raw.doubleValue else { throw bad("数值") }
            return .double(value)
        case .bool:
            guard let value = raw.boolValue else { throw bad("布尔值") }
            return .bool(value)
        case .enumeration:
            guard let text = raw.stringValue else { throw bad("字符串") }
            guard arg.values?.contains(text) ?? true else {
                throw ControlErrorBody(.badRequest,
                                       "\(command) 的 \(arg.name) 不接受 \(text)",
                                       hint: "可选：\((arg.values ?? []).joined(separator: " | "))",
                                       candidates: arg.values)
            }
            return .string(text)
        }
    }

    // MARK: 结果信封

    /// 工具结果：`structuredContent` 是控制面的响应信封本身（与 `outputSchema` 同形），
    /// `content` 里再放一份格式化的 JSON 文本给不认 structuredContent 的宿主
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

    // MARK: JSON-RPC 信封

    static func resultObject(id: JSONValue, result: JSONValue) -> JSONValue {
        .object(["jsonrpc": .string("2.0"), "id": id, "result": result])
    }

    static func errorObject(id: JSONValue, code: Int, message: String) -> JSONValue {
        .object(["jsonrpc": .string("2.0"), "id": id,
                 "error": .object(["code": .int(code), "message": .string(message)])])
    }

    // MARK: stdio 循环

    /// 读一行、处理、写一行，直到对端关掉标准输入。
    /// **绝不往标准输出写别的东西**：那条管道整条都是 JSON-RPC 的（日志只能走 stderr）
    func serve(input: FileHandle = .standardInput, output: FileHandle = .standardOutput) {
        var buffer = Data()
        while true {
            let chunk = input.availableData
            if chunk.isEmpty { return }
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
