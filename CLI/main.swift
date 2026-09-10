import Darwin
import Foundation

/// `quickterm`：QuickTerm 的控制面命令行。
/// 独立 target（`CLI/` + `Sources/Control/Wire` + `Sources/Config/WMAction.swift`），
/// 不依赖 GhosttyKit / AppKit —— 纯 Swift，毫秒级启动。
/// app target 的 `sources:` 是整个 `Sources`，`Sources/App/main.swift` 又是顶层代码，
/// 所以第二个 `main.swift` 必须放在 `Sources/` 之外，否则会被编进 app 直接把构建打断。

let cliVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"

/// stdout 不是 TTY → JSON（agent 不必加任何开关）；是 TTY → 人类可读
let stdoutIsTTY = isatty(STDOUT_FILENO) == 1

func writeOut(_ text: String) {
    FileHandle.standardOutput.write(Data((text + "\n").utf8))
}

func writeErr(_ text: String) {
    FileHandle.standardError.write(Data((text + "\n").utf8))
}

/// 错误一律是 stderr 上的 JSON（带稳定 code），人类模式下再补一行人话
func fail(_ error: ControlErrorBody, plain: Bool) -> Never {
    if let data = try? ControlJSON.prettyEncoder.encode(ControlReply.errorEnvelope(error)),
       let text = String(data: data, encoding: .utf8) {
        writeErr(text)
    }
    if plain { writeErr("错误：\(error.message)" + (error.hint.map { "\n提示：\($0)" } ?? "")) }
    exit(error.exit)
}

extension ControlReply {
    /// 客户端侧构造的错误信封（形状与服务端一致）
    struct Envelope: Encodable {
        var v = ControlProtocol.version
        var ok = false
        var error: ControlErrorBody
    }
    static func errorEnvelope(_ error: ControlErrorBody) -> Envelope { Envelope(error: error) }
}

func emit(_ reply: ControlReply, plain: Bool, spec: ControlCommandSpec? = nil) -> Never {
    if let error = reply.error { fail(error, plain: plain) }
    // `spec dump` 打印的**就是那份 spec 本身**，不套响应信封：
    // `quickterm spec dump > w.json` 要能直接喂回 `quickterm spec apply -f w.json`，
    // 否则每个人都得先 jq 一遍 —— 而那正是最容易出错的一步
    if spec?.name == "spec.dump", !plain, let body = reply.data?["spec"],
       let data = try? ControlJSON.prettyEncoder.encode(body),
       let text = String(data: data, encoding: .utf8) {
        writeOut(text)
        exit(0)
    }
    if plain {
        writeOut(Render.human(reply))
    } else if let data = try? ControlJSON.prettyEncoder.encode(reply.asJSON()),
              let text = String(data: data, encoding: .utf8) {
        writeOut(text)
    }
    exit(0)
}

extension ControlReply {
    /// 原样回吐（再走一次 JSONEncoder：格式化好看，且证明它是合法 JSON）
    func asJSON() -> JSONValue {
        var object: [String: JSONValue] = ["v": .int(v), "id": .string(id), "ok": .bool(ok)]
        if let seq { object["seq"] = .int(seq) }
        if let resolved,
           let data = try? ControlJSON.encoder.encode(resolved),
           let value = try? ControlJSON.decoder.decode(JSONValue.self, from: data) {
            object["resolved"] = value
        }
        if let data { object["data"] = data }
        if let error,
           let encoded = try? ControlJSON.encoder.encode(error),
           let value = try? ControlJSON.decoder.decode(JSONValue.self, from: encoded) {
            object["error"] = value
        }
        return .object(object)
    }
}

// MARK: 解析

let argv = Array(CommandLine.arguments.dropFirst())
var plainMode = stdoutIsTTY

let outcome: Args.Outcome
do {
    outcome = try Args.parse(argv)
} catch {
    fail(ControlErrorBody(.badRequest, "\(error)", hint: "quickterm --help"), plain: plainMode)
}

switch outcome {
case .help(let spec):
    writeOut(spec.map(Help.command) ?? Help.root(cliVersion: cliVersion))
    exit(0)
case .groupHelp(let group):
    writeOut(Help.group(group))
    exit(0)
case .command(let parsed):
    plainMode = parsed.forcePlain || (stdoutIsTTY && !parsed.forceJSON)
    if parsed.wantsHelp {
        writeOut(Help.command(parsed.spec))
        exit(0)
    }
    run(parsed)
}

// MARK: 执行

func run(_ parsed: ParsedCommand) -> Never {
    var parsed = parsed
    // 完全在本地完成的命令（不需要 QuickTerm 在跑）
    if parsed.spec.local {
        runLocal(parsed)
    }
    if parsed.spec.readsFile, parsed.args["spec"] == nil {
        parsed.args["spec"] = .string(readSpecInput(parsed))
    }

    var candidates = ControlPaths.clientSocketCandidates()
    if let override = parsed.socketOverride { candidates = [override] }

    let client: ControlClient
    do {
        client = try ControlClient.connect(candidates: candidates)
    } catch ControlClient.ClientError.notRunning(let tried) {
        if parsed.start, let started = ControlClient.launchAndWait(candidates: candidates) {
            send(parsed, over: started)
        }
        if parsed.spec.name == "describe" {
            // 应用没跑也要能把 schema 给出来：这是 agent 会话开始时的第一次调用，
            // 让它拿着本地命令表也能干活，而不是只收到"没在运行"
            let document = ControlDescribeDocument.make(
                cliVersion: cliVersion, appVersion: nil, socket: candidates.first, mode: nil)
            if let data = try? ControlJSON.prettyEncoder.encode(document),
               let text = String(data: data, encoding: .utf8) {
                writeOut(text)
                exit(0)
            }
        }
        if parsed.spec.name == "version" {
            let payload = ControlVersionPayload(
                cli: cliVersion, app: nil, protocolVersion: ControlProtocol.version,
                appProtocolVersion: nil, socket: nil, running: false)
            if plainMode {
                writeOut("quickterm \(cliVersion)（协议 v\(ControlProtocol.version)）；QuickTerm 没在运行")
            } else if let data = try? ControlJSON.prettyEncoder.encode(payload),
                      let text = String(data: data, encoding: .utf8) {
                writeOut(text)
            }
            exit(0)
        }
        fail(ControlErrorBody(.notRunning, "QuickTerm 没在运行（试过 \(tried.joined(separator: "、"))）",
                              hint: "open -a QuickTerm，或加 --start 让本命令自己拉起它"),
             plain: plainMode)
    } catch {
        fail(ControlErrorBody(.internalError, "\(error)"), plain: plainMode)
    }
    send(parsed, over: client)
}

func send(_ parsed: ParsedCommand, over client: ControlClient) -> Never {
    let environment = ProcessInfo.processInfo.environment
    let request = ControlRequest(
        id: "1",
        cmd: parsed.spec.name,
        target: parsed.target,
        args: parsed.args,
        token: environment[ControlProtocol.Env.token],
        origin: ControlRequestOrigin(
            pane: environment[ControlProtocol.Env.pane],
            screen: environment[ControlProtocol.Env.screen].flatMap(Int.init),
            workspace: environment[ControlProtocol.Env.workspace].flatMap(Int.init),
            pid: getpid(),
            paneToken: environment[ControlProtocol.Env.paneToken]))
    // `events follow` 是唯一一条不做"一问一答"的命令：连接保持打开，
    // 事件一批批推过来，直到 QuickTerm 停掉服务或用户 Ctrl-C
    if parsed.spec.name == "events.follow" {
        do {
            try client.stream(request) { reply in
                if let error = reply.error { fail(error, plain: plainMode) }
                if plainMode {
                    for line in Render.eventLines(reply) { writeOut(line) }
                } else if let data = try? ControlJSON.encoder.encode(reply.asJSON()),
                          let text = String(data: data, encoding: .utf8) {
                    // 流一律是 NDJSON（一行一个对象），**不美化**：下游是 `while read line`
                    writeOut(text)
                }
            }
            client.close()
            exit(0)
        } catch {
            client.close()
            fail(ControlErrorBody(.internalError, "\(error)"), plain: plainMode)
        }
    }

    do {
        let reply = try client.send(request)
        client.close()
        guard reply.v == ControlProtocol.version else {
            fail(ControlErrorBody(.protocolMismatch,
                                  "协议版本不匹配：quickterm \(cliVersion) 说 v\(ControlProtocol.version)，QuickTerm 说 v\(reply.v)",
                                  hint: "用 QuickTerm.app/Contents/MacOS/quickterm 重新 install-cli"),
                 plain: plainMode)
        }
        emit(reply, plain: plainMode, spec: parsed.spec)
    } catch {
        client.close()
        fail(ControlErrorBody(.internalError, "\(error)"), plain: plainMode)
    }
}

/// `-f <文件>`（`-` 或不写 = 标准输入）。**读文件的是 CLI，不是 QuickTerm**：
/// 两个进程的 cwd 与权限本来就不一样，而"服务端替你 open 一个任意路径"是个能被滥用的原语
func readSpecInput(_ parsed: ParsedCommand) -> String {
    let path = parsed.args["file"]?.stringValue
    let data: Data
    if let path, path != "-" {
        let expanded = (path as NSString).expandingTildeInPath
        guard let contents = FileManager.default.contents(atPath: expanded) else {
            fail(ControlErrorBody(.badRequest, "读不到 \(path)",
                                  hint: "quickterm spec dump > \(path) 先生成一份"), plain: plainMode)
        }
        data = contents
    } else {
        if isatty(STDIN_FILENO) == 1 {
            fail(ControlErrorBody(.badRequest, "没有给 spec：-f <文件>，或从标准输入喂进来",
                                  hint: "quickterm spec dump | quickterm spec validate"),
                 plain: plainMode)
        }
        data = FileHandle.standardInput.readDataToEndOfFile()
    }
    guard data.count <= SpecLimits.maxBytes else {
        fail(ControlErrorBody(.badRequest,
                              "spec 太大了（\(data.count) 字节，上限 \(SpecLimits.maxBytes)）"),
             plain: plainMode)
    }
    guard let text = String(data: data, encoding: .utf8) else {
        fail(ControlErrorBody(.badRequest, "spec 不是 UTF-8 文本"), plain: plainMode)
    }
    return text
}

func runLocal(_ parsed: ParsedCommand) -> Never {
    switch parsed.spec.name {
    case "install-cli":
        do {
            let result = try InstallCLI.run(alias: parsed.args["alias"]?.stringValue,
                                            directory: parsed.args["dir"]?.stringValue)
            if plainMode {
                writeOut("已安装：\(result.installed.joined(separator: "、"))")
                writeOut("来源：\(result.source)")
                if let hint = result.pathHint { writeOut(hint) }
                if let note = result.note { writeOut(note) }
            } else if let data = try? ControlJSON.prettyEncoder.encode(result),
                      let text = String(data: data, encoding: .utf8) {
                writeOut(text)
            }
            exit(0)
        } catch {
            fail(ControlErrorBody(.failed, "\(error)"), plain: plainMode)
        }
    case "mcp":
        runMCP(parsed)
    default:
        fail(ControlErrorBody(.internalError, "命令 \(parsed.spec.name) 声明为本地命令但没有实现"),
             plain: plainMode)
    }
}

/// `quickterm mcp`：在标准输入输出上跑 MCP 服务。
/// **每次 tools/call 才连一次 socket**——与 CLI 每条命令一次连接同一条规矩，
/// 于是限流、确认、活动日志全都照旧生效，MCP 这一层没有任何自己的特权。
func runMCP(_ parsed: ParsedCommand) -> Never {
    if parsed.args["list-tools"]?.boolValue == true {
        let tools = JSONValue.object(["tools": .array(MCPToolMap.tools.map(\.listEntry))])
        if let data = try? ControlJSON.prettyEncoder.encode(tools),
           let text = String(data: data, encoding: .utf8) {
            writeOut(text)
        }
        exit(0)
    }
    var candidates = ControlPaths.clientSocketCandidates()
    if let override = parsed.socketOverride { candidates = [override] }

    let server = MCPServer(cliVersion: cliVersion) { request in
        let client: ControlClient
        do {
            client = try ControlClient.connect(candidates: candidates)
        } catch ControlClient.ClientError.notRunning(let tried) {
            throw ControlErrorBody(.notRunning,
                                   "QuickTerm 没在运行（试过 \(tried.joined(separator: "、"))）",
                                   hint: "open -a QuickTerm 之后重试这次调用")
        }
        defer { client.close() }
        let reply = try client.send(request)
        guard reply.v == ControlProtocol.version else {
            throw ControlErrorBody(.protocolMismatch,
                                   "协议版本不匹配：quickterm \(cliVersion) 说 v\(ControlProtocol.version)，"
                                       + "QuickTerm 说 v\(reply.v)",
                                   hint: "用 QuickTerm.app/Contents/SharedSupport/quickterm 重新 install-cli")
        }
        return reply
    }
    // 标准输出整条管道都是 JSON-RPC：任何一句人话都会让宿主的解析器当场报错
    server.serve()
    exit(0)
}
