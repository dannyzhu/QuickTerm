import Darwin
import Foundation

/// `quickterm`: QuickTerm's control-plane command line.
/// A separate target (`CLI/` + `Sources/Control/Wire` + `Sources/Config/WMAction.swift`) that pulls
/// in neither GhosttyKit nor AppKit — pure Swift, and it starts in milliseconds.
/// The app target's `sources:` is the whole of `Sources`, and `Sources/App/main.swift` is top-level
/// code, so this second `main.swift` has to live outside `Sources/`: inside it, it would be compiled
/// into the app and break the build outright.

let cliVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"

/// stdout is not a TTY -> JSON, so an agent never has to pass a flag; it is a TTY -> human-readable
let stdoutIsTTY = isatty(STDOUT_FILENO) == 1

func writeOut(_ text: String) {
    FileHandle.standardOutput.write(Data((text + "\n").utf8))
}

func writeErr(_ text: String) {
    FileHandle.standardError.write(Data((text + "\n").utf8))
}

/// Errors are always JSON on stderr, carrying a stable `code`; in human mode the plain-English
/// line goes **first**, and the envelope follows it.
///
/// Order, not content: a person at a terminal reads the top of what just scrolled past, and the
/// envelope is a dozen pretty-printed lines, so the one sentence written for them used to end up
/// below the JSON written for an agent. Both are still emitted, so anything already scraping this
/// stderr keeps working — dropping the envelope in human mode would break `2>&1 | jq`, which is a
/// perfectly reasonable thing to have in a script.
/// When stdout is not a TTY (or `--json` was passed) this is an agent's channel and stays JSON
/// only: one line of English in front of it is exactly what makes a parser fail.
func fail(_ error: ControlErrorBody, plain: Bool) -> Never {
    if plain {
        writeErr("Error: \(error.message)")
        if let hint = error.hint { writeErr("Hint: \(hint)") }
    }
    if let data = try? ControlJSON.prettyEncoder.encode(ControlReply.errorEnvelope(error)),
       let text = String(data: data, encoding: .utf8) {
        writeErr(text)
    }
    exit(error.exit)
}

extension ControlReply {
    /// Error envelope built on the client side; the shape matches the server's.
    struct Envelope: Encodable {
        var v = ControlProtocol.version
        var ok = false
        var error: ControlErrorBody
    }
    static func errorEnvelope(_ error: ControlErrorBody) -> Envelope { Envelope(error: error) }
}

func emit(_ reply: ControlReply, plain: Bool, spec: ControlCommandSpec? = nil) -> Never {
    if let error = reply.error { fail(error, plain: plain) }
    // The `cli` field of `version` is filled in by **this binary**: the app has no idea who is
    // calling it and would only ever report its own version, which would make "upgraded, but an old
    // quickterm is still sitting on PATH" permanently invisible.
    if spec?.name == "version", var object = reply.data?.objectValue {
        object["cli"] = .string(cliVersion)
        let patched = ControlReply(v: reply.v, id: reply.id, ok: reply.ok, seq: reply.seq,
                                   resolved: reply.resolved, data: .object(object), error: nil)
        if plain {
            writeOut(Render.human(patched))
        } else if let encoded = try? ControlJSON.prettyEncoder.encode(patched.asJSON()),
                  let text = String(data: encoded, encoding: .utf8) {
            writeOut(text)
        }
        exit(0)
    }
    // `spec dump` prints **the spec itself**, with no response envelope wrapped around it:
    // `quickterm spec dump > w.json` has to feed straight back into
    // `quickterm spec apply -f w.json`. Otherwise everyone has to run it through jq first — and
    // that is precisely the step people get wrong.
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
    /// Echo it back as-is. Running it through JSONEncoder once more formats it nicely and proves it
    /// is valid JSON.
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

// MARK: Parsing

let argv = Array(CommandLine.arguments.dropFirst())
var plainMode = stdoutIsTTY

let outcome: Args.Outcome
do {
    outcome = try Args.parse(argv)
} catch {
    // Point at the help of the command that was actually being typed: `quickterm --help` is the
    // whole control plane, and someone who mistyped one flag of `pane set` has to find that
    // command in it before they learn anything.
    fail(ControlErrorBody(.badRequest, "\(error)",
                          hint: (error as? ArgsError)?.helpHint ?? "quickterm --help"),
         plain: plainMode)
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

// MARK: Execution

func run(_ parsed: ParsedCommand) -> Never {
    var parsed = parsed
    // Commands that complete entirely locally; QuickTerm does not have to be running.
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
            // The schema has to come out even when the app is not running: this is the very first
            // call an agent makes at the start of a session, so hand it the local command table and
            // let it get to work instead of answering "not running".
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
                writeOut("quickterm \(cliVersion) (protocol v\(ControlProtocol.version)); QuickTerm is not running")
            } else if let data = try? ControlJSON.prettyEncoder.encode(payload),
                      let text = String(data: data, encoding: .utf8) {
                writeOut(text)
            }
            exit(0)
        }
        fail(ControlErrorBody(.notRunning, "QuickTerm is not running (tried \(tried.joined(separator: ", ")))",
                              hint: "Run open -a QuickTerm, or pass --start to let this command launch it."),
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
    // `events follow` is the one command that is not request/response: the connection stays open
    // and events are pushed over in batches until QuickTerm stops the service or the user hits
    // Ctrl-C.
    if parsed.spec.name == "events.follow" {
        do {
            try client.stream(request) { reply in
                if let error = reply.error { fail(error, plain: plainMode) }
                if plainMode {
                    for line in Render.eventLines(reply) { writeOut(line) }
                } else if let data = try? ControlJSON.encoder.encode(reply.asJSON()),
                          let text = String(data: data, encoding: .utf8) {
                    // A stream is always NDJSON, one object per line, and **never** pretty-printed:
                    // downstream is a `while read line`.
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
                                  "Protocol version mismatch: quickterm \(cliVersion) speaks "
                                      + "v\(ControlProtocol.version), QuickTerm speaks v\(reply.v)",
                                  hint: "Re-run install-cli from QuickTerm.app/Contents/SharedSupport/quickterm."),
                 plain: plainMode)
        }
        emit(reply, plain: plainMode, spec: parsed.spec)
    } catch {
        client.close()
        fail(ControlErrorBody(.internalError, "\(error)"), plain: plainMode)
    }
}

/// `-f <file>` (`-`, or omitted, means stdin). **The CLI reads the file, not QuickTerm**: the two
/// processes have different working directories and different permissions to begin with, and "the
/// server opens an arbitrary path on your behalf" is a primitive that invites abuse.
func readSpecInput(_ parsed: ParsedCommand) -> String {
    let path = parsed.args["file"]?.stringValue
    let data: Data
    if let path, path != "-" {
        let expanded = (path as NSString).expandingTildeInPath
        guard let contents = FileManager.default.contents(atPath: expanded) else {
            fail(ControlErrorBody(.badRequest, "Cannot read \(path)",
                                  hint: "Generate one first: quickterm spec dump > \(path)"), plain: plainMode)
        }
        data = contents
    } else {
        if isatty(STDIN_FILENO) == 1 {
            fail(ControlErrorBody(.badRequest, "No spec given: pass -f <file>, or feed one in on stdin",
                                  hint: "quickterm spec dump | quickterm spec validate"),
                 plain: plainMode)
        }
        data = FileHandle.standardInput.readDataToEndOfFile()
    }
    guard data.count <= SpecLimits.maxBytes else {
        fail(ControlErrorBody(.badRequest,
                              "spec is too large (\(data.count) bytes, limit \(SpecLimits.maxBytes))"),
             plain: plainMode)
    }
    guard let text = String(data: data, encoding: .utf8) else {
        fail(ControlErrorBody(.badRequest, "spec is not UTF-8 text"), plain: plainMode)
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
                writeOut("Installed: \(result.installed.joined(separator: ", "))")
                writeOut("Source: \(result.source)")
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
        fail(ControlErrorBody(.internalError, "Command \(parsed.spec.name) is declared local but has no implementation"),
             plain: plainMode)
    }
}

/// `quickterm mcp`: run the MCP server over stdin/stdout.
/// **One socket connection per tools/call** — the same rule the CLI follows for every command, so
/// rate limiting, confirmation and the activity log all keep applying unchanged, and the MCP layer
/// gets no privileges of its own.
func runMCP(_ parsed: ParsedCommand) -> Never {
    // Config gate (`[control] mcp`): with it switched off, `quickterm mcp` will not even hand out
    // the tool list. This is the same check as the one inside `MCPServer.serve()` (same registry);
    // it sits here only so the user sees the plain-English message before the pipe turns into
    // JSON-RPC.
    if let refusal = MCPServer.configRefusal() { fail(refusal, plain: plainMode) }
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
                                   "QuickTerm is not running (tried \(tried.joined(separator: ", ")))",
                                   hint: "Run open -a QuickTerm, then retry this call.")
        }
        defer { client.close() }
        let reply = try client.send(request)
        guard reply.v == ControlProtocol.version else {
            throw ControlErrorBody(.protocolMismatch,
                                   "Protocol version mismatch: quickterm \(cliVersion) speaks v\(ControlProtocol.version), "
                                       + "QuickTerm speaks v\(reply.v)",
                                   hint: "Re-run install-cli from QuickTerm.app/Contents/SharedSupport/quickterm.")
        }
        return reply
    }
    // The whole stdout pipe is JSON-RPC: a single line of plain English makes the host's parser
    // error out on the spot.
    if let refusal = server.serve() { fail(refusal, plain: plainMode) }
    exit(0)
}
