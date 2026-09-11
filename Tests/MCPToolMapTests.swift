import XCTest
@testable import QuickTerm

/// Phase 5：MCP 工具表与 stdio 服务。
///
/// 这一组用例守的是一件事：**工具表是从命令表生成的，不是手写的**。
/// 手写的那一份两个版本之内必然漂移，而漂移的代价全部由 agent 承担——
/// 它拿着过期的 schema 发调用，收到自己解释不了的错误，然后开始瞎试。
/// 所以这里逐条钉死：每个工具背后的命令都查得到、注解与安全分级一致、
/// 命令表里的每一条要么被覆盖要么写明了不上 MCP 的理由、
/// 而查询类工具的 `outputSchema` 与命令**真的**回的东西对得上（拿真实响应比对，不是比对另一份手写清单）。
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

    // MARK: 反漂移：工具 ↔ 命令表

    /// 每个工具的每条 `command` 都必须在命令表里查得到（这是整组用例的地基）
    func testEveryToolMapsToLiveCommandTableEntries() {
        XCTAssertFalse(MCPToolMap.tools.isEmpty)
        XCTAssertEqual(Set(MCPToolMap.tools.map(\.name)).count, MCPToolMap.tools.count, "工具重名")
        for tool in MCPToolMap.tools {
            XCTAssertTrue(tool.name.hasPrefix("quickterm_"),
                          "\(tool.name) 要带前缀：宿主里同时挂着十几个 server")
            XCTAssertFalse(tool.commandNames.isEmpty, "\(tool.name) 背后一条命令都没有")
            for name in tool.commandNames {
                XCTAssertNotNil(ControlCommandTable.command(name),
                                "\(tool.name) 引用了命令表里没有的 \(name)")
            }
            XCTAssertFalse(tool.description.isEmpty)
            XCTAssertTrue(tool.description.contains("Safety:"), "\(tool.name) 的描述要写明安全语义")
        }
        // 一条命令只能落在一个工具里：落两处的话，宿主那边同一件事会有两套注解
        let all = MCPToolMap.tools.flatMap(\.commandNames)
        XCTAssertEqual(Set(all).count, all.count, "有命令被两个工具同时收了")
    }

    /// **注解必须机械地跟着安全分级走**。这是宿主那一层闸门的全部依据：
    /// 把一条破坏性命令混进一个 readOnlyHint 的工具里，Claude Code / Codex 会直接自动放行
    func testAnnotationsMatchTheCommandClass() {
        for tool in MCPToolMap.tools {
            let classes = tool.commands.map(\.cls)
            XCTAssertEqual(tool.readOnlyHint, classes.allSatisfy { $0 == .read },
                           "\(tool.name) 的 readOnlyHint 与它背后命令的分级不一致")
            XCTAssertEqual(tool.destructiveHint,
                           classes.contains { $0 == .destructive || $0 == .sensitive },
                           "\(tool.name) 的 destructiveHint 与它背后命令的分级不一致")
            XCTAssertEqual(tool.idempotentHint, tool.commands.allSatisfy(\.idempotent),
                           "\(tool.name) 的 idempotentHint 与命令表的 idempotent 不一致")
            XCTAssertFalse(tool.openWorldHint, "控制面只驱动本机这一个 QuickTerm")
            if tool.readOnlyHint {
                XCTAssertFalse(tool.destructiveHint, "\(tool.name) 不可能既只读又破坏性")
            }
            // interactive 类（会弹面板的动作）永远不该整条命令暴露出去
            XCTAssertFalse(classes.contains(.interactive), "\(tool.name) 收了一条 interactive 命令")
        }
        // 具名钉死最要紧的三个，免得将来有人"顺手"把分组改宽
        XCTAssertEqual(MCPToolMap.tool(named: "quickterm_state")?.readOnlyHint, true)
        XCTAssertEqual(MCPToolMap.tool(named: "quickterm_close")?.destructiveHint, true)
        XCTAssertEqual(MCPToolMap.tool(named: "quickterm_send_text")?.destructiveHint, true)
    }

    /// 命令表里的每一条，要么被某个工具覆盖，要么在 `excluded` 里写明理由。
    /// 加了新命令却忘了上 MCP，会在这里当场停下——而不是半年后由某个 agent 发现
    func testEveryCommandIsEitherExposedOrExplicitlyExcluded() {
        let exposed = Set(MCPToolMap.tools.flatMap(\.commandNames))
        for spec in ControlCommandTable.commands {
            if exposed.contains(spec.name) { continue }
            XCTAssertNotNil(MCPToolMap.excluded[spec.name],
                            "命令 \(spec.cli) 既没上 MCP，也没写明为什么不上")
        }
        for (name, reason) in MCPToolMap.excluded {
            XCTAssertNotNil(ControlCommandTable.command(name), "excluded 里有表外的命令 \(name)")
            XCTAssertFalse(reason.isEmpty, "\(name) 的排除理由是空的")
            XCTAssertFalse(exposed.contains(name), "\(name) 既被排除又被暴露")
        }
    }

    /// 每个命令**分组**都得有工具覆盖：漏掉一整组等于 agent 从 MCP 这一侧完全够不着它
    func testEveryCommandGroupIsCovered() {
        let exposed = Set(MCPToolMap.tools.flatMap(\.commandNames))
        for group in ControlCommandTable.groups {
            let covered = ControlCommandTable.commands(inGroup: group)
                .contains { exposed.contains($0.name) }
            XCTAssertTrue(covered, "命令组 \(group) 在 MCP 工具表里一个都没有")
        }
        // 顶层的查询类同样要够得着
        for name in ["state", "list", "get", "action", "describe"] {
            XCTAssertNotNil(MCPToolMap.tool(forCommand: name), "\(name) 没有对应的 MCP 工具")
        }
    }

    /// 输入 schema 覆盖每条命令的每个参数（`--file` 除外：读文件永远是调用方那侧的事）
    func testInputSchemaCoversEveryArgument() throws {
        for tool in MCPToolMap.tools {
            let schema = try XCTUnwrap(tool.inputSchema.objectValue)
            let properties = try XCTUnwrap(schema["properties"]?.objectValue)
            let required = Set((schema["required"]?.arrayValue ?? []).compactMap(\.stringValue))
            for spec in tool.commands {
                for arg in spec.args where !MCPToolMap.argsNotExposed.contains(arg.name) {
                    let property = try XCTUnwrap(properties[arg.name]?.objectValue,
                                                 "\(tool.name) 的 schema 里没有 \(spec.cli) 的 \(arg.name)")
                    XCTAssertNotNil(property["type"], "\(arg.name) 没写类型")
                    XCTAssertFalse((property["description"]?.stringValue ?? "").isEmpty,
                                   "\(arg.name) 没有说明")
                }
                if spec.acceptsTarget { XCTAssertNotNil(properties["target"], tool.name) }
                if spec.honorsMutationFlags {
                    XCTAssertNotNil(properties[ControlCommandTable.Flag.dryRun], tool.name)
                    XCTAssertNotNil(properties[ControlCommandTable.Flag.failIfNoop], tool.name)
                }
            }
            if tool.commands.count > 1 {
                XCTAssertTrue(required.contains("command"), "\(tool.name) 背多条命令，command 必填")
                let values = Set((properties["command"]?["enum"]?.arrayValue ?? [])
                    .compactMap(\.stringValue))
                XCTAssertEqual(values, Set(tool.commands.map(\.cli)))
            } else if let spec = tool.commands.first {
                for arg in spec.args where arg.required && !MCPToolMap.argsNotExposed.contains(arg.name) {
                    XCTAssertTrue(required.contains(arg.name),
                                  "\(tool.name)：\(spec.cli) 的 \(arg.name) 是必填的")
                }
            }
        }
    }

    /// **`required` 只能写"这个工具背的每一条命令都要"的那些参数。**
    ///
    /// 回归：`quickterm_dump_spec` 背着 `spec dump`（不读正文）与 `spec validate`（读），
    /// 曾经"只要有一条 readsFile 就把 spec 标成工具级必填"。守 schema 的宿主于是逼模型每次都带上
    /// `spec`，而服务端按解析出的那条命令校验参数——`spec dump` 一律被自己人拒掉，
    /// 也就是 dump → 改 → apply 这条主路的前半截在 MCP 上根本走不通
    func testRequiredOnlyListsArgumentsEveryBackingCommandAccepts() throws {
        for tool in MCPToolMap.tools {
            let required = Set((tool.inputSchema["required"]?.arrayValue ?? [])
                .compactMap(\.stringValue))
            for name in required where name != "command" {
                for spec in tool.commands {
                    XCTAssertTrue(spec.args.contains { $0.name == name },
                                  "\(tool.name) 把 \(name) 标成必填，但 \(spec.cli) 根本不认这个参数")
                }
            }
        }
        let dump = try XCTUnwrap(MCPToolMap.tool(named: "quickterm_dump_spec"))
        XCTAssertFalse((dump.inputSchema["required"]?.arrayValue ?? [])
            .compactMap(\.stringValue).contains("spec"),
            "spec dump 不读正文，spec 不能是这个工具的必填项")
        // apply 只背一条命令，而 MCP 这侧没有 -f，所以那里 spec 仍然必填
        let apply = try XCTUnwrap(MCPToolMap.tool(named: "quickterm_apply_spec"))
        XCTAssertTrue((apply.inputSchema["required"]?.arrayValue ?? [])
            .compactMap(\.stringValue).contains("spec"))

        // 端到端：不带 spec 调 `spec dump`，服务端必须真的放行
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
                       "spec dump 必须走得通：\(reply)")
        XCTAssertEqual(sent.last?.cmd, "spec.dump")
    }

    /// **"跑两次结果一样"这句话只能写在真的幂等的工具上。**
    /// 回归：`safetyLine` 只看 readOnly / destructive 两个分支，于是 `quickterm_new_pane`
    /// （背着 pane new / screen new，两条都 idempotent:false）的描述里写着"绝对设值，跑两次一样"，
    /// 而它自己的注解写着 idempotentHint:false——同一个工具对象里两句话打架，模型信的是正文
    func testTheSafetyLineNeverClaimsRepeatSafetyForNonIdempotentTools() {
        for tool in MCPToolMap.tools where !tool.idempotentHint {
            XCTAssertFalse(tool.safetyLine.contains("Absolute setters"),
                           "\(tool.name) 不是幂等的，描述里不能说跑两次结果一致：\(tool.safetyLine)")
            if !tool.readOnlyHint, !tool.destructiveHint {
                XCTAssertTrue(tool.safetyLine.contains("NOT idempotent"),
                              "\(tool.name) 要明说重试会再来一次：\(tool.safetyLine)")
            }
        }
        for tool in MCPToolMap.tools where tool.idempotentHint && !tool.readOnlyHint
            && !tool.destructiveHint {
            XCTAssertTrue(tool.safetyLine.contains("Absolute setters"), tool.name)
        }
        XCTAssertEqual(MCPToolMap.tool(named: "quickterm_new_pane")?.idempotentHint, false)
        XCTAssertEqual(MCPToolMap.tool(named: "quickterm_action")?.idempotentHint, false)
    }

    /// **描述里提到的参数，schema 里必须真的有。**
    /// 回归：`safetyLine` 的 destructive 分支一律写"Run with dry-run first"，
    /// 而 `quickterm_read_terminal`（背着 pane.capture-text，readOnlyEffect）
    /// 根本不收这个参数——照着描述发一次的下场是 bad_request，或者模型自己编一个 schema 里没有的键
    func testAToolNeverAdvisesAFlagItsSchemaDoesNotAccept() throws {
        for tool in MCPToolMap.tools {
            let properties = try XCTUnwrap(tool.inputSchema["properties"]?.objectValue)
            let exposed = properties[ControlCommandTable.Flag.dryRun] != nil
            if !exposed {
                XCTAssertFalse(tool.safetyLine.lowercased().contains("dry-run first"),
                               "\(tool.name) 的 schema 里没有 dry_run，就不能劝模型先跑一次："
                                   + tool.safetyLine)
            }
            XCTAssertEqual(exposed, tool.commands.contains(where: \.honorsMutationFlags),
                           "\(tool.name)：dry_run 出现在 schema 里，当且仅当背后有命令认这个参数")
        }
        let read = try XCTUnwrap(MCPToolMap.tool(named: "quickterm_read_terminal"))
        XCTAssertTrue(read.destructiveHint, "sensitive 仍然要让宿主每次确认")
        XCTAssertTrue(read.safetyLine.contains("takes no dry-run"),
                      "要明说它不收这两个参数：\(read.safetyLine)")
    }

    /// 取值集合各不相同时**不写 enum**：写一个只对其中一条命令成立的 enum 比不写更糟
    func testEnumsAreOnlyDeclaredWhenTheyHoldForEveryCommand() throws {
        let arrange = try XCTUnwrap(MCPToolMap.tool(named: "quickterm_arrange"))
        let properties = try XCTUnwrap(arrange.inputSchema["properties"]?.objectValue)
        // pane set --width 是 double，pane resize --width 是 "+0.05" 这样的字符串：两种类型都要写出来
        let width = try XCTUnwrap(properties["width"]?.objectValue)
        let types = Set((width["type"]?.arrayValue ?? []).compactMap(\.stringValue))
        XCTAssertEqual(types, ["number", "string"], "两条命令的 width 类型不同，schema 要把两种都写出来")
        XCTAssertNil(width["enum"])
        // 只有一条命令用的枚举照常写出来
        let layout = try XCTUnwrap(properties["layout"]?.objectValue)
        XCTAssertEqual(Set((layout["enum"]?.arrayValue ?? []).compactMap(\.stringValue)),
                       ["scrolling", "dwindle"])
    }

    // MARK: outputSchema 与命令**真的**回的东西对得上

    /// 拿真实响应比 schema：命令回了一个 schema 里没有的键，就是 schema 漂了。
    /// （比对另一份手写的字段清单毫无意义——那份清单本身就是要防的东西）
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
            // 变更信封也走一遍（dry-run：一个字节都不改）
            ("pane.set", handle, ["zoom": .string("on"), ControlCommandTable.Flag.dryRun: .bool(true)]),
        ]
        cases.append(("action", nil, ["list": .bool(true)]))

        for item in cases {
            let reply = try harness.run(item.command, target: item.target, args: item.args)
            XCTAssertTrue(reply.ok, "\(item.command) 没跑通：\(String(describing: reply.error))")
            let tool = try XCTUnwrap(MCPToolMap.tool(forCommand: item.command),
                                     "\(item.command) 没有对应的 MCP 工具")
            let schema = try XCTUnwrap(tool.outputSchema.objectValue)
            let envelope = try XCTUnwrap(schema["properties"]?.objectValue)
            // 信封本身
            for key in ["ok", "seq", "resolved", "data", "error"] {
                XCTAssertNotNil(envelope[key], "\(tool.name) 的 outputSchema 缺信封字段 \(key)")
            }
            // data 的键
            let declared = Set((envelope["data"]?["properties"]?.objectValue ?? [:]).keys)
            guard !declared.isEmpty else { continue }   // describe 那种"大对象"是刻意不展开的
            let actual = Set((reply.data?.objectValue ?? [:]).keys)
            let missing = actual.subtracting(declared)
            XCTAssertTrue(missing.isEmpty,
                          "\(tool.name) 的 outputSchema 没写 \(item.command) 真的会回的键：\(missing.sorted())")
        }
    }

    /// 记录数组里的记录也要展开到字段级：agent 读的是 `panes[].handle`，不是"一个数组"
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
                      "pane 记录里出现了 schema 没写的字段：\(actual.subtracting(declared).sorted())")
        XCTAssertFalse(ControlHandleRegistry.shared.handle(for: pane).isEmpty)
    }

    // MARK: stdio 服务真的会说 MCP

    /// initialize → tools/list → 一次读 → 一次被拒的破坏性调用。
    /// **不挂到真的宿主上**：协议这一层同进程驱动就够，真宿主只会把用例变成一个不确定的外部依赖
    func testInitializeListToolsAndDispatchOneReadAndOneRefusedDestructiveCall() throws {
        var sent: [ControlRequest] = []
        let server = MCPServer(cliVersion: "1.5.8", environment: [:]) { request in
            sent.append(request)
            if request.cmd == "pane.close" {
                return try Self.decode(ControlResponse.failure(
                    id: request.id, seq: 412,
                    error: ControlErrorBody(.confirmationRequired, "需要在 QuickTerm 里确认",
                                            hint: "去 QuickTerm 里批准后重试")))
            }
            return try Self.decode(ControlResponse.success(
                id: request.id, seq: 412, resolved: ResolvedTarget(screen: 1, workspace: 2),
                data: ControlListPayload(panes: [.object(["handle": .string("t7")])])))
        }

        // initialize 之前只回 ping：MCP 允许服务端这样拒绝，而这条拒绝本身要是干净的 JSON-RPC 错误
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
            .contains("quickterm_describe"), "instructions 要把 agent 指向 describe")

        // 通知没有 id：**一个字节都不能回**
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

        // 一次读：落到 list 命令上，结果原样回来
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
        // 不认 structuredContent 的宿主看 content：那一份必须是同一个信封
        let text = try XCTUnwrap(read["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue)
        XCTAssertTrue(text.contains("\"ok\""))

        // 一次被拒的破坏性调用：错误**不是** JSON-RPC 错误，而是 isError 的工具结果
        let destructive = try XCTUnwrap(Self.call(server, """
        {"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"quickterm_close",\
        "arguments":{"command":"pane close","target":"t7"}}}
        """))
        XCTAssertNil(destructive["error"], "工具执行失败要走 isError，不是协议错误")
        XCTAssertEqual(destructive["result"]?["isError"]?.boolValue, true)
        XCTAssertEqual(destructive["result"]?["structuredContent"]?["error"]?["code"]?.stringValue,
                       ControlErrorCode.confirmationRequired.rawValue)
        XCTAssertEqual(destructive["result"]?["structuredContent"]?["error"]?["exit"]?.intValue,
                       Int(ControlExit.confirmationRequired.rawValue))
        XCTAssertEqual(sent.last?.cmd, "pane.close")
        XCTAssertEqual(sent.last?.target, "t7")
    }

    /// 参数校验在 MCP 这一侧就做完：认不得的键、不在枚举里的值、缺的必填，一律当场报，
    /// **绝不悄悄丢掉**——静默丢参数是最难查的一类 agent 故障
    func testArgumentValidationRefusesRatherThanSilentlyDropping() throws {
        let server = try Self.initializedServer { _ in
            XCTFail("参数没过校验就不该发出去")
            throw ControlErrorBody(.internalError, "unreachable")
        }
        // 属于另一条命令的参数
        let stray = try XCTUnwrap(Self.call(server, """
        {"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"quickterm_arrange",\
        "arguments":{"command":"pane move","zoom":"on","to":":4"}}}
        """))
        XCTAssertEqual(stray["result"]?["isError"]?.boolValue, true)
        XCTAssertEqual(stray["result"]?["structuredContent"]?["error"]?["code"]?.stringValue,
                       ControlErrorCode.badRequest.rawValue)
        // 缺必填
        let missing = try XCTUnwrap(Self.call(server, """
        {"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"quickterm_send_text",\
        "arguments":{"target":"t7"}}}
        """))
        XCTAssertEqual(missing["result"]?["isError"]?.boolValue, true)
        // 不存在的工具：报错时把全部工具名列出来，别让 agent 靠猜
        let unknown = try XCTUnwrap(Self.call(server, """
        {"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"quickterm_nope","arguments":{}}}
        """))
        XCTAssertEqual(unknown["result"]?["isError"]?.boolValue, true)
        let candidates = unknown["result"]?["structuredContent"]?["error"]?["candidates"]?.arrayValue
        XCTAssertEqual(candidates?.count, MCPToolMap.tools.count)
    }

    /// `-t` 只在命令表说它接受目标时才送出去；`--file` 在 MCP 这一侧根本不存在
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
                         "\(tool.name) 不该暴露 --file：读文件永远是调用方那一侧的事")
        }
    }

    /// 真的走一对管道（宿主看到的就是这个）：一行进、一行出，对端关掉标准输入就干净退出
    func testServeOverAPipe() throws {
        let input = Pipe()
        let output = Pipe()
        let server = MCPServer(cliVersion: "1.5.8", environment: [:]) { _ in
            throw ControlErrorBody(.notRunning, "用例不连真的 QuickTerm")
        }
        let done = expectation(description: "serve 退出")
        DispatchQueue.global().async {
            // gate 显式传：默认参数 `.load()` 会去读开发者自己的配置文件
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
        XCTAssertEqual(lines.count, 2, "一行请求一行应答")
        // 空数组下标会把整个 test bundle 打断（不止红一条），所以先 unwrap
        let first = try ControlJSON.decoder.decode(JSONValue.self, from: try XCTUnwrap(lines.first))
        // 客户端报的老版本我们支持，就照它回（不然宿主会以为握手失败）
        XCTAssertEqual(first["result"]?["protocolVersion"]?.stringValue, "2024-11-05")
        let second = try ControlJSON.decoder.decode(JSONValue.self, from: try XCTUnwrap(lines.dropFirst().first))
        XCTAssertEqual(second["id"]?.intValue, 2)
        XCTAssertNotNil(second["result"])
    }

    // MARK: helpEN / describe

    /// 67 个动作**每一个**都要有英文说明：describe 的输出会被原样粘进中英混排的 agent 提示里
    func testEveryActionHasBothLanguages() {
        for action in WMAction.allCases {
            XCTAssertFalse(action.help.isEmpty, "\(action.rawValue) 缺中文说明")
            XCTAssertFalse(action.helpEN.isEmpty, "\(action.rawValue) 缺英文说明")
            XCTAssertNotEqual(action.help, action.helpEN, "\(action.rawValue) 的两份说明是同一句")
            XCTAssertFalse(action.helpEN.contains("？"), "\(action.rawValue) 的英文说明里混进了中文标点")
        }
        let docs = ControlCommandTable.actionDocs
        XCTAssertEqual(docs.count, WMAction.allCases.count)
        for doc in docs {
            XCTAssertFalse(doc.helpZH.isEmpty, "\(doc.name) 缺 helpZH")
            XCTAssertFalse(doc.helpEN.isEmpty, "\(doc.name) 缺 helpEN")
        }
    }

    /// describe 里要能看见 MCP 工具表（不然 agent 只能靠猜有没有 MCP 这条路）
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
        // 再走一遍 JSONEncoder：describe 是 agent 会话开始读的那一份，不能有半个手拼的字节
        let data = try ControlJSON.encoder.encode(document)
        let raw = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual((raw["mcpTools"] as? [[String: Any]])?.count, MCPToolMap.tools.count)
        let actions = try XCTUnwrap(raw["actions"] as? [[String: Any]])
        XCTAssertTrue(actions.allSatisfy { !(($0["helpEN"] as? String) ?? "").isEmpty },
                      "describe 的动作表要中英各一份")
    }

    /// `mcp` 是本地命令：经 socket 发过来要被明确拒掉，而不是掉进"本阶段还没有实现"
    func testLocalCommandsAreRefusedOverTheSocket() throws {
        for name in ["mcp", "install-cli"] {
            let spec = try XCTUnwrap(ControlCommandTable.command(name))
            XCTAssertTrue(spec.local, "\(name) 应当是本地命令")
            let reply = try harness.run(name)
            XCTAssertFalse(reply.ok)
            XCTAssertEqual(reply.error?.code, ControlErrorCode.unknownCommand.rawValue)
        }
    }

    // MARK: 工具

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

    /// 服务端写出的 `ControlResponse` → 客户端读到的 `ControlReply`（走一遍真的编解码）
    private static func decode(_ response: ControlResponse) throws -> ControlReply {
        try ControlJSON.decoder.decode(ControlReply.self, from: ControlJSON.line(response))
    }
}
