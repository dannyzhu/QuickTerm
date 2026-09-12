import AppKit

/// 控制命令的执行体。**永远在主线程上跑**（每个入口都有 `dispatchPrecondition`）：
/// `MainWindowController` 没有 `@MainActor` 标注、工程又是 Swift 5.10，
/// 从 socket 回调线程写 `@Published` 编译得干干净净，然后在运行时崩成
/// "publishing changes from background thread"。
///
/// 串行化用**标志位**而不是锁：`perform()` 是可重入的（引擎回调
/// `ghosttyDidEqualizeSplits → perform(.equalize)`、键盘监视器、菜单项都会调它），
/// 跨主线程 hop 持锁只会在第一个引擎回调进来时把 UI 直接锁死。
@MainActor
final class ControlCommandRunner {
    struct Config {
        /// `[control] socket`（旧名 `enabled`）
        var socket: Bool = true
        /// `[control] mcp`：只作用于 `quickterm mcp` 那个进程（见 `ControlConfigGate`）。
        /// **socket 这一侧不认它**：MCP 的每一条调用都是一条普通的控制请求，
        /// "我是 MCP"是调用方自报的，服务端一个字都验不了——把一个验不了的字段
        /// 当闸门用，只会给用户一个假的安全感
        var mcp: Bool = true
        var mode: String = "ask"
        var exposeBrowser: String = "token"
        var sendText: Bool = false
        var captureText: Bool = false

        init() {}

        init(_ settings: ConfigStore.Settings) {
            socket = settings.controlSocket
            mcp = settings.controlMCP
            mode = settings.controlMode
            exposeBrowser = settings.controlExposeBrowser
            sendText = settings.controlSendText
            captureText = settings.controlCaptureText
        }

        /// 这条 `sensitive` 命令被用户显式打开了吗。
        /// **一条命令一个开关**：早先这里只有一个 `sendText`，于是"我要 agent 能读屏幕"
        /// 会顺带把"agent 能往我的 shell 里打字"一起打开——那是两件完全不同的授权
        func allowsSensitive(_ command: String) -> Bool {
            switch command {
            case "input.send-text": sendText
            case "pane.capture-text": captureText
            default: false   // 认不得的敏感命令一律关着：默认值只能是安全的那一侧
            }
        }

        /// 该命令没被打开时，告诉用户去哪儿开
        func sensitiveHint(_ command: String) -> String {
            switch command {
            case "input.send-text": "Set send-text = true under [control] in ~/.config/quickterm/config.toml"
            case "pane.capture-text": "Set capture-text = true under [control] in ~/.config/quickterm/config.toml"
            default: "This command has no switch of its own under [control]"
            }
        }

        /// 监听与否 = 三个开关取最严：`socket = false`、旧的 `enabled = false`
        /// （解析阶段已并进 socket）、`mode = "off"`，任何一个都等于不监听
        var isListening: Bool { socket && mode != "off" }
        var allowsMutation: Bool { isListening && mode != "readonly" }
        /// **反过来写**：只要这条命令能被执行，破坏性 / 敏感命令就一定要确认。
        /// 写成 `mode == "ask"` 的话，任何别的 mode 拼法（配置里写 "on"、将来多一个档位、
        /// 甚至一个手滑的大小写）都会静默地把整个确认闸门关掉——
        /// 闸门只能被显式的 off / readonly 绕开，绝不能被拼错绕开
        var promptsForDestructive: Bool { allowsMutation }
    }

    /// 确认闸门批准的**那一个**主体。用户读到的和这一刀落下的必须是同一个：
    /// 确认框挂着的十秒里，别的 mutate 命令（`focus-right` 之类，它们不需要确认）
    /// 完全可以把焦点挪走，于是"关闭焦点 pane"关掉的就成了另一个 pane。
    ///
    /// Phase 2 起主体不一定是一个 pane：`workspace clear` 钉的是"这个工作区里的这几个 pane"
    /// （集合变了也算变），`screen close` 钉的是那一块屏幕
    struct PinnedSubject {
        var controller: MainWindowController
        var workspace: Int
        var pane: PaneView?
        var handle: String?
        /// `workspace clear` 用：确认时那个工作区里的 pane 集合
        var paneIDs: Set<UUID>?
        /// `spec apply` 用：这一刀会动到的**每一个**（屏幕，工作区）与它当时的 pane 集合。
        /// 一份 `quickterm.screen/1` 会覆盖整块屏幕的每一个工作区、`quickterm.session/1`
        /// 是每一块屏幕——只钉住 `-t` 指的那一个，用户批准的就不是即将发生的那件事
        var scopes: [PinnedScope] = []
        /// 确认框里那句话的简短版（漂移时回给调用方，让它知道当时确认的是什么）。
        /// **写英文**：它会原样进 `busy` 的错误正文，而命令行那一侧全是英文
        var description: String
        /// 同一个主体的中文版，**只给确认框用**：那段文字只在 QuickTerm 自己的窗口里出现，
        /// 从不回到 socket 上去，所以它跟着应用界面走中文，不跟着命令行走英文
        var consentText: String
    }

    /// 被钉住的一个工作区（`PinnedSubject.scopes` 的元素）
    struct PinnedScope {
        var controller: MainWindowController
        var workspace: Int
        /// 确认那一刻这个工作区里的 pane（**不含正在淡出的**：确认与落刀之间会 flush 一次）
        var paneIDs: Set<UUID>
    }

    let screens: ScreenRegistry
    let consent: ControlConsent
    var config = Config()
    /// 单调状态序号。**所有者是 `ControlEventBus`**：Phase 4 起每一条类型化事件都推进它，
    /// 于是"响应里的 seq"与"事件里的 seq"天然是同一条尺子——agent 可以拿变更响应回的 seq
    /// 直接去 `events poll --since`，中间不会漏掉自己那条命令产生的事件
    var seq: Int { ControlEventBus.shared.seq }
    /// 一次只执行一条命令。模态的嵌套 run loop 会在用户的对话框背后抽干主队列，
    /// 那时第二条命令绝不能插进来
    private var isExecuting = false
    /// 按来源的变更限流（连接级那只桶盖不住"每条命令一条新连接"的 CLI）
    var rateLimiter = ControlRateLimiter()
    /// 当前这条命令的两个全局开关（`isExecuting` 保证同一时刻只有一条命令在跑）
    private(set) var currentFlags: (dryRun: Bool, failIfNoop: Bool) = (false, false)
    /// **可注入**：主线程上是否有模态挡着。用例靠它把"任何变更类命令在模态期间都被拒"
    /// 钉成一条结构性用例（真的弹一个 NSAlert 会把测试宿主自己卡住）
    var modalBusyProbe: () -> Bool = { NSApp.modalWindow != nil }

    /// 一条变更真的落地了：先把它产生的类型化事件扫出来，一条都没有再补一次 seq
    func seqDidMutate() { ControlEventBus.shared.settleMutation() }

    func dryRun(_ request: ControlRequest) -> Bool {
        request.args[ControlCommandTable.Flag.dryRun]?.boolValue ?? false
    }

    init(screens: ScreenRegistry, consent: ControlConsent) {
        self.screens = screens
        self.consent = consent
    }

    /// 一条连接走了。`events follow` 是唯一活得比一次请求还长的东西，
    /// 对端消失就是它**唯一**的终止条件——没有这一步，一条流会一直往一个已经关掉的 fd 上写
    func connectionDidClose(_ connection: UInt64) {
        dispatchPrecondition(condition: .onQueue(.main))
        ControlEventBus.shared.connectionDidClose(connection)
    }

    var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
    }

    // MARK: 入口

    func handle(_ request: ControlRequest, peer: ControlSocket.Peer,
                completion: @escaping (ControlResponse) -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))

        func fail(_ error: ControlErrorBody, resolved: ResolvedTarget? = nil) {
            completion(.failure(id: request.id, seq: seq, resolved: resolved, error: error))
        }

        guard request.v == ControlProtocol.version else {
            fail(ControlErrorBody(.protocolMismatch,
                                  "Protocol version mismatch: the caller speaks v\(request.v), QuickTerm \(appVersion) speaks v\(ControlProtocol.version)",
                                  hint: "Update the quickterm CLI (QuickTerm.app/Contents/MacOS/quickterm), or run install-cli again."))
            return
        }
        guard let spec = ControlCommandTable.command(request.cmd) else {
            fail(ControlErrorBody(.unknownCommand, "Unknown command \(request.cmd)",
                                  hint: "quickterm describe --json lists every command.",
                                  candidates: ControlCommandTable.commands.map(\.name)))
            return
        }
        guard config.isListening else {
            fail(ControlErrorBody(.denied, "The control plane is off ([control] mode = \(config.mode))"))
            return
        }

        var target: ControlTarget?
        if let raw = request.target, !raw.isEmpty {
            do {
                target = try ControlTarget.parse(raw)
            } catch {
                fail(ControlErrorBody(.badTarget, "\(error)",
                                      hint: ControlTarget.grammarLines.joined(separator: " / ")))
                return
            }
        }

        // 命令类：`action` 的类由具体动作决定，其余直接读表
        var cls = spec.cls
        var action: WMAction?
        if spec.name == "action", request.args["list"]?.boolValue != true {
            guard let raw = request.args["name"]?.stringValue, !raw.isEmpty else {
                fail(ControlErrorBody(.badRequest, "action needs an action name",
                                      hint: "quickterm action --list"))
                return
            }
            guard let parsed = WMAction(rawValue: raw) else {
                fail(ControlErrorBody(.unknownAction, "Unknown action \(raw)",
                                      hint: "quickterm action --list",
                                      candidates: Self.suggestions(for: raw)))
                return
            }
            action = parsed
            cls = ControlCommandTable.actionClass(parsed)
        } else if spec.name == "action" {
            cls = .read   // --list 只是打印表
        }
        // `spec apply` 的破坏性取决于模式：默认的 --into-empty **毁不掉任何东西**
        // （非空工作区一律拒绝，退出码 4），而 --replace / --reuse 会关掉现有的 pane。
        // 命令表里声明成 destructive（describe 与 MCP 的 hint 按最坏情况给），
        // 只有确实不会关任何东西的那个模式在这里降一级——反过来写（默认 mutate、
        // 见到 --replace 才升级）的话，将来多一个会关 pane 的模式就会静默绕开确认闸门
        if spec.name == "spec.apply",
           request.args["replace"]?.boolValue != true, request.args["reuse"]?.boolValue != true {
            cls = .mutate
        }

        if cls == .interactive, let action {
            fail(ControlErrorBody(.interactiveAction,
                                  "\(action.rawValue) opens a panel or pop-up menu that needs keyboard interaction, so it cannot run over the socket",
                                  hint: ControlCommandTable.interactiveHint(action)))
            return
        }
        if cls == .sensitive, !config.allowsSensitive(spec.name) {
            fail(ControlErrorBody(.denied, "Sensitive commands are off by default (\(spec.cli))",
                                  hint: config.sensitiveHint(spec.name)))
            return
        }
        // **读别人屏幕上的字，至少要拿得到浏览器网址那一枚 token。**
        // 没有 `QUICKTERM_TOKEN` 的调用方连一个浏览器 pane 的标题都读不到（默认打码），
        // 那它更没有道理读到一个 shell 的可视区——那里可能停着刚 export 的凭据。
        // 这道闸在确认闸门**之前**：一条注定要被拒的命令不该先把用户叫起来点一次"允许"
        if spec.name == "pane.capture-text", request.token != ControlEnvironment.token {
            logRefusal(request.cmd, peer: peer, request: request, code: .denied, message: "无 token")
            fail(ControlErrorBody(
                .denied, "capture-text requires the caller to carry this launch's origin token (QUICKTERM_TOKEN)",
                hint: "Run this command inside a QuickTerm pane, where the environment variable is injected for you; "
                    + "an external process has to inherit QUICKTERM_TOKEN from a pane."))
            return
        }
        if cls.isMutation, !config.allowsMutation {
            fail(ControlErrorBody(.denied, "The control plane is read-only ([control] mode = \(config.mode))",
                                  hint: "Set mode = \"ask\" to allow mutations."))
            return
        }

        // 带这两个开关而**没有实现**它们的命令一律先拒掉，位置在限流与确认闸门**之前**：
        // 读命令是调用方误解了语义（读本来就什么都不改）；`action` 更糟——它直通 `perform()`，
        // 静默接受等于"预演"真的落了刀，而 `--dry-run` 还会顺手把确认闸门一起关掉
        if !spec.honorsMutationFlags,
           request.args[ControlCommandTable.Flag.dryRun]?.boolValue == true
               || request.args[ControlCommandTable.Flag.failIfNoop]?.boolValue == true {
            fail(ControlErrorBody(
                .badRequest,
                "--dry-run / --fail-if-noop only mean something for the noun-verb mutation commands (\(spec.cli) has no diff to preview)",
                hint: spec.name == "action"
                    ? "action is a direct line to the keybindings. To dry-run a change, use a command "
                        + "like quickterm pane close or workspace clear."
                    : nil))
            return
        }

        // 变更类命令：用户正被一个挡住他的对话框拦着时，绝不能在他背后动布局。
        // 有两种情况 `isExecuting` 根本盖不住：
        // (1) `NSAlert.runModal` 的嵌套 run loop 仍在抽干主队列——`closePane` 的
        //     "仍有进程在运行"确认是 `DispatchQueue.main.async` 出去的，等它真弹出来时
        //     `perform()` 早已返回、`isExecuting` 早已复位；
        // (2) 我们自己的确认 sheet 还挂着——这时插进来的 `focus-*` 会改掉焦点，
        //     用户盯着"关闭焦点 pane？"点了允许，挨刀的却是另一个 pane。
        // 刻意**不用** `consent.isModalBusy`：它含任意窗口的 attachedSheet，
        // 网页里一个不关的 JS `confirm()` 就能把整个控制面永久顶成 busy（网页内容 DoS 掉 agent）
        if cls.isMutation, modalBusyProbe() || consent.isPrompting {
            fail(ControlErrorBody(.busy, "A dialog is open in QuickTerm, so mutation commands are held back",
                                  hint: "Dismiss the dialog in QuickTerm first.", retryAfterMs: 2000))
            return
        }

        // 限流：变更命令按**来源**再限一次。CLI 每条命令开一条新连接，
        // 连接级那只桶对 `for i in {1..200}; do quickterm pane new; done` 完全无效
        if cls.isMutation, !(dryRun(request) && spec.honorsMutationFlags) {
            let origin = request.origin?.pane.map { "pane:\($0)" } ?? "pid:\(peer.pid)"
            if case .limited(let retry, let scope) = rateLimiter.admit(origin: origin) {
                logRefusal(request.cmd, peer: peer, request: request, code: .rateLimited,
                           message: "限流（\(scope)）")
                fail(ControlErrorBody(.rateLimited, "Mutations are coming in too fast (\(scope) rate limit)",
                                      hint: "Batch the operations, or retry more slowly.", retryAfterMs: retry))
                return
            }
        }

        // `--dry-run` 什么都不改，因此**不问**：确认框问的是"要不要动手"，
        // 而这次根本不会动手。它能读到的东西 `state` 本来就给（同一套打码规则）
        // 豁免绑在"这条命令真的实现了预演"上，而不是"带了这个开关"：
        // 将来再加一条不算 diff 的直通命令时，忘了实现 dry-run 最坏是接受了一个没用的开关
        // （下面 execute() 里那道闸门会直接拒），而不是悄悄拆掉确认闸门
        var needsConsent = cls.requiresConsent && config.promptsForDestructive
            && !(dryRun(request) && spec.honorsMutationFlags)

        // send-text 的正文**在问用户之前**就校验：一条根本送不出去的文本
        // （控制字符、超长）不该先把用户叫起来点一次"允许"。
        // 顺手拿到给确认框看的那份预览——它只画在屏幕上，一个字都不进日志
        var sendTextPreview: String?
        if spec.name == "input.send-text" {
            let raw = request.args["text"]?.stringValue ?? ""
            do {
                _ = try Self.validateSendText(raw)
            } catch let error as ControlErrorBody {
                fail(error)
                return
            } catch {
                fail(ControlErrorBody(.internalError, "\(error)"))
                return
            }
            sendTextPreview = Self.sendTextPreview(raw)
        }

        // **唯一的免确认豁免，范围窄到只有一句话：调用方往它自己那个 pane 里打字。**
        //
        // 这不是"带了 token 就放行"——那种写法在 ControlEnvironment 的注释里被明确禁止，
        // 而且真的写成那样就是个洞：`QUICKTERM_TOKEN` 每次启动只有**一枚**、注入**每一个** pane，
        // 于是它只能证明"来自某个 pane"，永远证明不了"来自这个 pane"。曾经的实现把
        // `origin.pane`（调用方自报的一串 UUID，服务端一个字都验不了）当成身份，
        // 于是 `QUICKTERM_PANE=<别人的 uuid> quickterm input send-text … -t <别人>` 就能免确认地
        // 往别人的 shell 里打字。
        //
        // 现在的判定只认**可验证的**那一枚：`QUICKTERM_PANE_TOKEN` 是每 pane 一枚的
        // `HMAC(每次启动的密钥, paneID)`，服务端拿 `-t` **真正解析到的那个 pane** 的 id 现算一遍去比。
        // 比中了才说明调用进程确实跑在那个 pane（或它的子进程）里——而那个 tty 本来就是它自己的，
        // 它不经过 QuickTerm 也能往上写。比不中就走每次都问的那条路
        // （send-text 的授权还不进缓存，见下面 cacheable）
        if needsConsent, spec.name == "input.send-text", writesIntoOwnPane(request, target: target) {
            needsConsent = false
        }

        // **先解析目标再问**。拿调用方的原始写法（`@focused`，或者干脆什么都没写）去问，
        // 等用户答完再解析，中间那 10 秒是真的会变的：
        // 用户读到的必须是一个具体的 pane，而且批准之后落刀前还要再核一次身份
        var pinned: PinnedSubject?
        if needsConsent {
            do {
                pinned = try pin(spec, action: action, target: target, request: request)
            } catch let error as ControlErrorBody {
                fail(error)          // 目标本来就不合法：不必去打扰用户
                return
            } catch {
                fail(ControlErrorBody(.internalError, "\(error)"))
                return
            }
        }

        let execute = { [weak self] in
            guard let self else { return }
            self.execute(request, spec: spec, action: action, cls: cls, target: target,
                         pinned: pinned, peer: peer, completion: completion)
        }

        guard needsConsent else {
            execute()
            return
        }
        // 敏感命令一条一个授权键：批准过"读屏幕"不等于批准"往 shell 里打字"
        let grantScope: String? = cls == .sensitive ? spec.name : nil
        if consent.isModalBusy, !consent.hasGrant(pid: peer.pid, cls: cls, scope: grantScope) {
            fail(ControlErrorBody(.busy, "A dialog is open in QuickTerm, so destructive commands are held back",
                                  hint: "Dismiss the dialog in QuickTerm first.", retryAfterMs: 2000))
            return
        }
        consent.evaluate(.init(peerName: peer.processName, peerPID: peer.pid, cls: cls,
                               summary: Self.consentSummary(request, spec: spec, action: action,
                                                            target: target, subject: pinned),
                               originPane: originHandle(for: request),
                               originVerified: originIsProven(request),
                               tokenPresent: request.token == ControlEnvironment.token,
                               // send-text 的授权**绝不缓存**：往别人的 tty 里打字每一次都要问。
                               // 破坏性命令按 (pid, 类) 缓存一次是因为"关 pane"这件事用户看得见，
                               // 而注入的文本会在那个 shell 里执行任意东西，两次之间可以完全不同
                               cacheable: spec.name != "input.send-text",
                               scope: grantScope,
                               // 正文只画给用户看：它是这次确认与上一次唯一的区别，
                               // 不给出来的话 `echo hi` 和 `curl … | sh` 在框里长得一模一样
                               payload: sendTextPreview,
                               payloadLength: sendTextPreview == nil
                                   ? nil : (request.args["text"]?.stringValue ?? "").count,
                               payloadEnter: request.args["enter"]?.boolValue == true)) { decision in
            switch decision {
            case .allow:
                execute()
            case .deny:
                fail(ControlErrorBody(.denied, "The user denied this command"))
            case .timeout:
                fail(ControlErrorBody(.confirmationRequired,
                                      "This needs confirming in QuickTerm (no answer within \(Int(ControlConsent.timeout)) seconds)",
                                      hint: "Switch to QuickTerm, approve it, then retry."))
            }
        }
    }

    /// 确认框里那句"来自 pane t3"。**只有带着本次启动的 token 才显示**：
    /// `origin.pane` 是调用方自报的（CLI 直接抄自己的 `$QUICKTERM_PANE`），
    /// 服务端一个字都没法验。没有 token 就等于连"我来自某个 pane"都没证据，
    /// 那就一个字都不写——绝不在用户做信任判断的那块屏上把自报当事实讲。
    /// 就算有 token，措辞也仍是"自称"：token 只证明来自**某个** pane，不证明是**这个**
    func originHandle(for request: ControlRequest) -> String? {
        guard request.token == ControlEnvironment.token else { return nil }
        guard let raw = request.origin?.pane, let uuid = UUID(uuidString: raw) else { return nil }
        // 必须是当下真活着的 pane：句柄注册表从不清理，否则会报出一个十分钟前就关掉的 pane
        guard ControlResolver.addressablePanes(in: screens).contains(where: { $0.pane.id == uuid }) else {
            return nil
        }
        return ControlHandleRegistry.shared.existingHandle(for: uuid)
    }

    /// 自报的来源 pane **被证明了吗**（`QUICKTERM_PANE_TOKEN` 与 `origin.pane` 对得上）。
    /// 只影响确认框的措辞——"来自 pane t3"与"自称来自 pane t3"是两句不同的话，
    /// 而用户正拿这一句做信任判断
    func originIsProven(_ request: ControlRequest) -> Bool {
        guard let raw = request.origin?.pane, let uuid = UUID(uuidString: raw) else { return false }
        return ControlEnvironment.constantTimeEquals(request.origin?.paneToken,
                                                     ControlEnvironment.paneToken(for: uuid))
    }

    /// `input send-text` 的免确认判定：**这条命令写的就是调用方自己那个 pane 吗**。
    ///
    /// 判定只有一条，而且两边都不是调用方能随便写的：
    /// 拿 `-t` **真正解析到的那个 pane** 的 id 现算一遍 `HMAC(每次启动的密钥, paneID)`，
    /// 与请求带来的 `QUICKTERM_PANE_TOKEN` 定长比较。
    ///
    /// 刻意**不**看 `origin.pane`：那是自报的。旧实现拿它当身份，于是
    /// `QUICKTERM_PANE=<别人的 uuid>` 就能把任意 pane 伪装成"自己"。现在就算把 origin
    /// 写成别人的 uuid（连 `-t @self` 也会因此解析到别人那儿），HMAC 也对不上，照样要确认。
    ///
    /// 解析失败、没带这枚标记、写的是别人的 pane —— 一律返回 false（false = 走确认，安全的那一侧）
    func writesIntoOwnPane(_ request: ControlRequest, target: ControlTarget?) -> Bool {
        guard let claim = request.origin?.paneToken, !claim.isEmpty else { return false }
        var effective = target ?? ControlTarget()
        if effective.pane == nil { effective.pane = .focused }
        guard let resolved = try? makeResolver(request).resolve(effective).pane else { return false }
        return ControlEnvironment.constantTimeEquals(claim,
                                                     ControlEnvironment.paneToken(for: resolved.id))
    }

    /// 确认框里那一行正文预览。**净化 + 截断，绝不原样画**：
    /// `validateSendText` 拦掉的是 C0 / DEL / C1，而 U+2028 / U+2029（AppKit 真的会在这里断行）、
    /// 双向控制符 U+202E、零宽字符全都还能过——原样画出去，调用方就能在对话框里
    /// 伪造出几行看着像对话框自己说的话。上限 4096 字符也不可能塞进一个 NSAlert
    static func sendTextPreview(_ raw: String, limit: Int = 120) -> String {
        var out = ""
        var shown = 0
        for scalar in raw.unicodeScalars {
            if shown >= limit { out += "…"; break }
            let v = scalar.value
            let dangerous = v < 0x20 || v == 0x7F || (0x80...0x9F).contains(v)
                || v == 0x2028 || v == 0x2029
                || (0x200B...0x200F).contains(v) || (0x202A...0x202E).contains(v)
                || (0x2066...0x2069).contains(v) || v == 0xFEFF
            out += dangerous ? String(format: "<U+%04X>", v) : String(Character(scalar))
            shown += 1
        }
        return out
    }

    /// **先解析目标再问**，并把解析结果钉住。破坏性命令的主体各不相同：
    /// `pane close` 是一个 pane，`workspace clear` 是一个工作区里的那一组 pane，
    /// `screen close` 是一整块屏幕——每一种都要在确认框里说清楚，也都要在落刀前再核一次
    private func pin(_ spec: ControlCommandSpec, action: WMAction?, target: ControlTarget?,
                     request: ControlRequest) throws -> PinnedSubject? {
        let resolver = makeResolver(request)
        switch spec.name {
        case "workspace.clear":
            let resolution = try resolver.resolve(target)
            let controller = resolution.controller
            let panes = controller.model.layouts[resolution.workspace].paneList
                + controller.model.floatings[resolution.workspace].map(\.pane)
            let handles = panes.map { ControlHandleRegistry.shared.handle(for: $0) }
            return PinnedSubject(
                controller: controller, workspace: resolution.workspace, pane: nil, handle: nil,
                paneIDs: Set(panes.map(\.id)),
                description: "screen \(controller.screenIndex + 1) workspace \(resolution.workspace + 1)"
                    + " (\(panes.count) pane\(panes.count == 1 ? "" : "s"): \(handles.joined(separator: " ")))",
                consentText: "屏幕 \(controller.screenIndex + 1) 工作区 \(resolution.workspace + 1)"
                    + "（\(panes.count) 个 pane：\(handles.joined(separator: " "))）")
        case "spec.apply":
            // 钉住的是"这一批工作区里的这些 pane"：**作用域由 spec 正文说了算**，不是 `-t`。
            // 一份屏幕 spec 覆盖整块屏幕的每一个工作区、一份会话 spec 覆盖每一块屏幕；
            // 确认框里只写 `-t` 指的那一个的话，用户批准的是一件比实际小得多的事
            let resolution = try resolver.resolve(target)
            guard let text = request.args["spec"]?.stringValue, !text.isEmpty else {
                throw ControlErrorBody(.badRequest, "No spec content was provided",
                                       hint: "quickterm spec apply -f <file>, or pipe the spec in on stdin")
            }
            // 解析不了 / 落不下去的 spec 在这里就失败：不必先把用户叫起来确认一件做不成的事
            let document = try SpecParser.parse(text)
            let targets = try Self.specTargets(document, controller: resolution.controller,
                                               workspace: resolution.workspace, screens: screens)
            var scopes: [PinnedScope] = []
            var handles: [String] = []
            var places: [String] = []
            var placesZH: [String] = []
            for target in targets {
                let closing = target.controller.model.closingPanes
                let panes = (target.controller.model.layouts[target.workspace].paneList
                    + target.controller.model.floatings[target.workspace].map(\.pane))
                    .filter { !closing.contains($0.id) }
                handles += panes.map { ControlHandleRegistry.shared.handle(for: $0) }
                if places.count < 6 {
                    places.append("screen \(target.controller.screenIndex + 1) workspace \(target.workspace + 1)")
                    placesZH.append("屏幕 \(target.controller.screenIndex + 1) 工作区 \(target.workspace + 1)")
                }
                scopes.append(PinnedScope(controller: target.controller, workspace: target.workspace,
                                          paneIDs: Set(panes.map(\.id))))
            }
            let listed = handles.prefix(12).joined(separator: " ")
                + (handles.count > 12 ? " …" : "")
            let where_ = places.joined(separator: ", ") + (targets.count > places.count ? " …" : "")
            let whereZH = placesZH.joined(separator: "、") + (targets.count > placesZH.count ? " …" : "")
            let description = targets.count == 1
                ? "\(where_) (\(handles.count) pane\(handles.count == 1 ? "" : "s"): \(listed))"
                : "\(targets.count) workspaces (\(where_)), "
                    + "\(ControlChange.count(handles.count, "pane")) in all: \(listed)"
            let consentText = targets.count == 1
                ? "\(whereZH)（\(handles.count) 个 pane：\(listed)）"
                : "\(targets.count) 个工作区（\(whereZH)），共 \(handles.count) 个 pane：\(listed)"
            return PinnedSubject(
                controller: resolution.controller, workspace: resolution.workspace,
                pane: nil, handle: nil, paneIDs: nil, scopes: scopes, description: description,
                consentText: consentText)
        case "screen.close":
            let resolution = try resolver.resolve(target)
            let controller = resolution.controller
            let count = controller.model.allPanes.count
            return PinnedSubject(
                controller: controller, workspace: resolution.workspace, pane: nil, handle: nil,
                paneIDs: nil,
                description: "screen \(controller.screenIndex + 1) \"\(controller.window?.title ?? "")\""
                    + " (\(count) pane\(count == 1 ? "" : "s"))",
                consentText: "屏幕 \(controller.screenIndex + 1)「\(controller.window?.title ?? "")」"
                    + "（\(count) 个 pane）")
        default:
            var effective = target ?? ControlTarget()
            if effective.pane == nil { effective.pane = .focused }
            let resolution = try resolver.resolve(effective)
            guard let subject = resolution.pane ?? resolution.controller.focusedPane else { return nil }
            let handle = ControlHandleRegistry.shared.handle(for: subject)
            return PinnedSubject(
                controller: resolution.controller, workspace: resolution.workspace,
                pane: subject, handle: handle, paneIDs: nil,
                description: "\(handle) \"\(subject.paneTitle)\"",
                consentText: "\(handle)「\(subject.paneTitle)」")
        }
    }

    /// 确认框的正文。名字里必须出现**具体的那个主体**（句柄 + 标题 + 屏幕/工作区），
    /// 不能只回显调用方的写法——"关闭焦点 pane"这句话本身不构成同意。
    /// 这里给出的标题是未打码的真标题：打码防的是调用方，而这段文字只给用户自己看，
    /// 从不回到 socket 上去
    static func consentSummary(_ request: ControlRequest, spec: ControlCommandSpec, action: WMAction?,
                               target: ControlTarget?, subject: PinnedSubject?) -> String {
        var text = action.map { "执行动作 \($0.rawValue)（\($0.help)）" }
            ?? "执行 \(spec.cli)（\(spec.summary)）"
        if let subject {
            let controller = subject.controller
            switch spec.name {
            case "workspace.clear":
                text += "\n清空 \(subject.consentText) —— 其中的进程会被结束"
            case "screen.close":
                text += "\n关闭 \(subject.consentText) —— 其中的进程会被结束"
            case "spec.apply":
                text += "\n用一份 spec 覆盖 \(subject.consentText) —— 对不上的那些 pane 会被关掉，其中的进程会被结束"
            case "browser.close":
                let tabs = (subject.pane as? BrowserPaneView)?.tabs.count ?? 0
                let which = request.args["tab"]?.stringValue ?? "@active"
                if request.args["others"]?.boolValue == true {
                    text += "\n关掉 \(subject.consentText) 里除 \(which) 之外的 \(max(tabs - 1, 0)) 个标签"
                } else if tabs <= 1 {
                    text += "\n关掉 \(subject.consentText) 的最后一个标签 —— **整个 pane 会一起关掉**"
                } else {
                    text += "\n关掉 \(subject.consentText) 的标签 \(which)（还剩 \(tabs - 1) 个）"
                }
                text += "· 屏幕 \(controller.screenIndex + 1) · 工作区 \(subject.workspace + 1)"
            case "pane.capture-text":
                // 读屏幕这件事必须在框里说成"读"：用户批准的是"把那个 pane 屏幕上的字交出去"，
                // 而不是一句抽象的"执行敏感操作"
                text += "\n**读取 \(subject.consentText) 屏幕上的全部文字**并交给这个调用方"
                    + "（其中可能有密码、token、私有代码）"
                    + "· 屏幕 \(controller.screenIndex + 1) · 工作区 \(subject.workspace + 1)"
            default:
                // 浏览器 pane 还有别的标签时，close-pane 关的是当前标签而不是整个 pane（Chrome 语义）
                let tabOnly = (subject.pane as? BrowserPaneView).map { $0.tabs.count > 1 } ?? false
                text += "\n作用于 \(subject.consentText)"
                    + "· 屏幕 \(controller.screenIndex + 1) · 工作区 \(subject.workspace + 1)"
                if action == .closePane || spec.name == "pane.close", tabOnly { text += "（只关当前标签）" }
            }
        } else if let target, !target.isEmpty {
            text += "，目标 \(target.text)"
        }
        return text
    }

    /// 打错的动作名给出最接近的几个（agent 会幻觉出 `close_pane` / `focus-l`）
    static func suggestions(for raw: String) -> [String] {
        let needle = raw.lowercased()
        let all = WMAction.allCases.map(\.rawValue)
        let prefixed = all.filter { $0.hasPrefix(String(needle.prefix(3))) }
        let contains = all.filter { $0.contains(needle) || needle.contains($0) }
        let merged = Array(Set(prefixed + contains)).sorted()
        return Array(merged.prefix(8))
    }

    // MARK: 执行

    /// 本次请求的编码器（决定浏览器 pane 的 URL / 标题是否打码）
    private func makeEncoder(_ request: ControlRequest) -> ControlStateEncoder {
        ControlStateEncoder(screens: screens, trusted: request.token == ControlEnvironment.token,
                            exposeBrowser: config.exposeBrowser, mode: config.mode)
    }

    /// 本次请求的解析器。**打码的判定要一路带进解析器**：
    /// 否则 `title:~` 谓词会拿未打码的真标题去匹配，成了一个绕过打码的探测通道
    private func makeResolver(_ request: ControlRequest) -> ControlResolver {
        ControlResolver(screens: screens, origin: request.origin,
                        exposesBrowser: makeEncoder(request).exposesBrowser)
    }

    private func execute(_ request: ControlRequest, spec: ControlCommandSpec, action: WMAction?,
                         cls: ControlCommandClass, target: ControlTarget?,
                         pinned: PinnedSubject?,
                         peer: ControlSocket.Peer, completion: @escaping (ControlResponse) -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !isExecuting else {
            completion(.failure(id: request.id, seq: seq,
                                error: ControlErrorBody(.busy, "Another control command is already running",
                                                        retryAfterMs: 50)))
            return
        }
        isExecuting = true
        currentFlags = (dryRun: request.args[ControlCommandTable.Flag.dryRun]?.boolValue ?? false,
                        failIfNoop: request.args[ControlCommandTable.Flag.failIfNoop]?.boolValue ?? false)
        defer {
            isExecuting = false
            currentFlags = (false, false)
        }
        // 兜底：`handle()` 已经在限流与确认闸门之前拒过一次了（那才是正确的位置——
        // 绝不能先把用户叫起来确认，再告诉他这条命令根本不认这个开关）
        if !spec.honorsMutationFlags, currentFlags.dryRun || currentFlags.failIfNoop {
            completion(.failure(id: request.id, seq: seq,
                                error: ControlErrorBody(
                                    .badRequest,
                                    "--dry-run / --fail-if-noop only mean something for the noun-verb mutation commands (\(spec.cli) has no diff to preview)")))
            return
        }

        // 本地命令（`install-cli`、`mcp`）根本不该出现在这条 socket 上：它们整个在调用方那一侧完成。
        // 不明说的话，它们会掉进下面的 default 分支，收到一句"本阶段还没有实现"——
        // 那是句假话，而 agent 会照着它去等一个永远不会来的版本
        if spec.local {
            completion(.failure(id: request.id, seq: seq,
                                error: ControlErrorBody(
                                    .unknownCommand,
                                    "\(spec.cli) runs entirely on the quickterm side and never goes over the socket",
                                    hint: "Run quickterm \(spec.cli) directly in a terminal.")))
            return
        }

        let encoder = makeEncoder(request)
        let resolver = makeResolver(request)
        do {
            switch spec.name {
            case "state":
                let resolution = try resolver.resolve(target)
                let scope = target?.screen != nil ? resolution.controller : nil
                let payload = encoder.payload(scope: scope)
                let data: any Encodable = try project(payload, fields: request.args["fields"]?.stringValue)
                completion(.success(id: request.id, seq: seq, resolved: resolution.echo, data: data))

            case "list":
                let resolution = try resolver.resolve(target)
                let what = request.args["what"]?.stringValue ?? "panes"
                let payload = encoder.payload(scope: target?.screen != nil ? resolution.controller : nil)
                let fields = request.args["fields"]?.stringValue
                var out = ControlListPayload()
                switch what {
                case "screens":
                    out.screens = payload.screens
                case "workspaces":
                    out.workspaces = encoder.screenInfo(
                        resolution.controller,
                        isKey: resolution.controller === screens.controlCurrent).workspaces
                case "panes":
                    var panes = payload.panes
                    if target?.workspace != nil {
                        panes = panes.filter {
                            $0.screen == resolution.controller.screenIndex + 1
                                && $0.workspace == resolution.workspace + 1
                        }
                    }
                    out.panes = try panes.map { try projectPane($0, fields: fields) }
                default:
                    throw ControlErrorBody(.badRequest, "list only accepts screens / workspaces / panes",
                                           candidates: ["screens", "workspaces", "panes"])
                }
                completion(.success(id: request.id, seq: seq, resolved: resolution.echo, data: out))

            case "get":
                var effective = target ?? ControlTarget()
                if effective.pane == nil { effective.pane = .focused }
                let resolution = try resolver.resolve(effective)
                guard let pane = resolution.pane else {
                    throw ControlErrorBody(.notFound, "No addressable pane")
                }
                let positions = ControlStateEncoder.positions(
                    in: resolution.controller.model.layouts[resolution.workspace],
                    closing: resolution.controller.model.closingPanes)
                let workspace = encoder.workspaceInfo(resolution.controller, index: resolution.workspace)
                let handle = ControlHandleRegistry.shared.handle(for: pane)
                let info = encoder.paneInfo(pane, controller: resolution.controller,
                                            workspace: resolution.workspace,
                                            at: positions[pane.id],
                                            float: workspace.floating.contains(handle),
                                            zoomed: workspace.zoom == handle)
                completion(.success(id: request.id, seq: seq, resolved: resolution.echo,
                                    data: ControlPanePayload(pane: info)))

            case "action":
                if request.args["list"]?.boolValue == true {
                    completion(.success(id: request.id, seq: seq, resolved: nil,
                                        data: ControlActionListPayload(actions: ControlCommandTable.actionDocs)))
                    return
                }
                guard let action else { throw ControlErrorBody(.badRequest, "action needs an action name") }
                let payload = try runAction(action, target: target, resolver: resolver,
                                            precise: request.args["precise"]?.boolValue ?? false,
                                            encoder: encoder, pinned: pinned)
                seqDidMutate()
                completion(.success(id: request.id, seq: seq, resolved: payload.echo, data: payload.data))

            case "describe":
                let document = ControlDescribeDocument.make(
                    cliVersion: appVersion, appVersion: appVersion,
                    socket: ControlEnvironment.socketPath, mode: config.mode)
                completion(.success(id: request.id, seq: seq, resolved: nil, data: document))

            case "version":
                completion(.success(id: request.id, seq: seq, resolved: nil,
                                    // cli 留空：应用无从得知调用方二进制的版本，
                                    // 由 CLI 用自己的 cliVersion 填上（见 CLI/main.swift）。
                                    // 编成 appVersion 会让「CLI 与应用版本不一致」这个诊断永远显示一致，
                                    // 而升级后 PATH 上留着旧二进制正是设计里点名要发现的情况
                                    data: ControlVersionPayload(
                                        cli: nil, app: appVersion,
                                        protocolVersion: ControlProtocol.version,
                                        appProtocolVersion: ControlProtocol.version,
                                        socket: ControlEnvironment.socketPath, running: true)))

            case "events.poll", "events.follow":
                // **唯一一条可以不同步应答的命令**：长轮询挂在那里等，流则一直推。
                // `isExecuting` 在本函数返回时就复位了（defer），所以挂着的 poll
                // 不会把别的命令一起堵死——那正是"事件流是那条长命的连接"的代价与前提
                let ctx = ControlContext(spec: spec, request: request, peer: peer, target: target,
                                         resolver: resolver, encoder: encoder, pinned: pinned)
                try runEvents(ctx, completion: completion)

            default:
                // Phase 2 的名词-动词层：统一的 (echo, 变更信封) 形状
                guard let group = spec.group else {
                    throw ControlErrorBody(.unknownCommand, "Command \(spec.name) is not implemented in this phase")
                }
                let ctx = ControlContext(spec: spec, request: request, peer: peer, target: target,
                                         resolver: resolver, encoder: encoder, pinned: pinned)
                let result: (echo: ResolvedTarget?, data: any Encodable)
                switch group {
                case "pane": result = try runPane(ctx)
                case "workspace": result = try runWorkspace(ctx)
                case "screen": result = try runScreen(ctx)
                case "app": result = try runApp(ctx)
                case "spec": result = try runSpec(ctx)
                case "input": result = try runInput(ctx)
                case "browser": result = try runBrowser(ctx)
                default:
                    throw ControlErrorBody(.unknownCommand, "Unknown command group \(group)",
                                           candidates: ControlCommandTable.groups)
                }
                completion(.success(id: request.id, seq: seq, resolved: result.echo, data: result.data))
            }
        } catch let error as ControlErrorBody {
            completion(.failure(id: request.id, seq: seq, error: error))
        } catch {
            completion(.failure(id: request.id, seq: seq,
                                error: ControlErrorBody(.internalError, "\(error)")))
        }
    }

    // MARK: action

    private func runAction(_ action: WMAction, target: ControlTarget?, resolver: ControlResolver,
                           precise: Bool, encoder: ControlStateEncoder, pinned: PinnedSubject?)
        throws -> (echo: ResolvedTarget, data: ControlActionPayload) {
        let resolution = try resolver.resolve(target)
        let controller = resolution.controller

        // 工作区序号型动作：越界要给出明确范围，绝不静默无操作
        if let index = action.workspaceIndex {
            let count = controller.model.layouts.count
            guard index < count else {
                throw ControlErrorBody(
                    .notFound,
                    "\(action.rawValue) points at workspace \(index + 1), but screen \(controller.screenIndex + 1) only has \(count)",
                    hint: "Raise workspaces (1–10) in ~/.config/quickterm/config.toml")
            }
        }

        // `action` 直通 `perform()`，而 `perform()` 只作用于**活动**工作区。
        // 目标指了另一个工作区却照做，就是那种"agent 以为动了、其实动在别处"的静默错误
        if target?.workspace != nil, resolution.workspace != controller.model.activeIndex,
           action.workspaceIndex == nil {
            throw ControlErrorBody(
                .badTarget,
                "action applies to the active workspace (currently \(controller.model.activeIndex + 1)), but the target is \(resolution.workspace + 1)",
                hint: "Run quickterm action goto-workspace-\(resolution.workspace + 1) first.")
        }

        // 目标显式指了 pane：先把焦点交过去，**并且校验交成功了**才执行。
        // 交接是异步重试的（最长 0.75s），校验失败一律返回 busy——绝不对着错的 pane 动手
        if target?.pane != nil, let pane = resolution.pane {
            guard resolution.workspace == controller.model.activeIndex else {
                throw ControlErrorBody(
                    .badTarget,
                    "pane \(ControlHandleRegistry.shared.handle(for: pane)) is in workspace \(resolution.workspace + 1), which is not the active workspace",
                    hint: "Run quickterm action goto-workspace-\(resolution.workspace + 1) first.")
            }
            if controller.focusedPane !== pane {
                controller.requestFocus(to: pane)
                guard controller.focusedPane === pane else {
                    throw ControlErrorBody(
                        .busy,
                        "Focus could not be handed to \(ControlHandleRegistry.shared.handle(for: pane)) in the same turn (SwiftUI has not mounted it yet)",
                        hint: "Retry shortly; nothing was done this time.", retryAfterMs: 200)
                }
            }
        }

        if action.browserOnly, !(controller.focusedPane is BrowserPaneView) {
            throw ControlErrorBody(
                .wrongPaneKind, "\(action.rawValue) only works on a browser pane, and the focused pane is not one",
                hint: "Pass -t <browser pane handle> (the ones with kind=browser in quickterm list panes)")
        }
        if action.terminalOnly, !(controller.focusedPane is Ghostty.SurfaceView) {
            throw ControlErrorBody(
                .wrongPaneKind, "\(action.rawValue) only works on a terminal pane, and the focused pane is not one",
                hint: "Pass -t <terminal pane handle>")
        }

        // 确认闸门批准的是**这一个** pane：落刀前再核一次身份。
        // 用户读确认框的那十秒里，不需要确认的 mutate 命令（`focus-right`、`goto-workspace-N`…）
        // 完全可以插进来把焦点挪走；那时宁可整条命令 busy 掉，也绝不把批准过的一刀落到别处
        if let pinned, let pinnedPane = pinned.pane {
            guard controller === pinned.controller, controller.focusedPane === pinnedPane,
                  !controller.model.closingPanes.contains(pinnedPane.id) else {
                throw ControlErrorBody(
                    .busy,
                    "The target changed while the confirmation prompt was up (what was confirmed: "
                        + "\(pinned.handle ?? pinned.description), which is no longer focused): nothing was done",
                    hint: "Send it again, or name the target exactly with -t \(pinned.handle ?? "<handle>")",
                    retryAfterMs: 200)
            }
        }

        let before = Set(controller.model.allPanes.map(\.id))
        let confirmPending = action == .closePane && (controller.focusedPane?.wantsConfirmClose ?? false)
        controller.perform(action, precise: precise)   // perform() 自己先 flushPendingCloses()

        let after = controller.model.allPanes.filter { !before.contains($0.id) }
        let positions = ControlStateEncoder.positions(in: controller.model.layout,
                                                     closing: controller.model.closingPanes)
        let created = after.map { pane in
            encoder.paneInfo(pane, controller: controller, workspace: controller.model.activeIndex,
                             at: positions[pane.id], float: false, zoomed: false)
        }
        // 回显落点：新建了 pane 就报新建的那个（不是"此刻的焦点 pane"）。
        // `requestFocus` 是带退避重试的异步交接（最长 0.75s），命令返回时焦点常常还没真正过去——
        // 与其回一个当下碰巧是焦点的旧 pane，不如诚实地报出新 pane 并标 focusPending
        let subject = after.first ?? (target?.pane != nil ? resolution.pane : nil) ?? controller.focusedPane
        let focusPending = subject.map { controller.focusedPane !== $0 } ?? false
        let echo = ResolvedTarget(
            screen: controller.screenIndex + 1,
            screenID: controller.windowID.uuidString,
            workspace: controller.model.activeIndex + 1,
            pane: subject.map { ControlHandleRegistry.shared.handle(for: $0) },
            paneID: subject?.id.uuidString)
        return (echo, ControlActionPayload(
            action: action.rawValue,
            cls: ControlCommandTable.actionClass(action),
            applied: !confirmPending,
            confirmPending: confirmPending ? true : nil,
            focusPending: focusPending ? true : nil,
            panes: created.isEmpty ? nil : created))
    }

    // MARK: --fields 投影

    private func project(_ payload: ControlStatePayload, fields: String?) throws -> any Encodable {
        guard let list = Self.fieldList(fields) else { return payload }
        return ControlStateProjected(
            schema: payload.schema, app: payload.app, screens: payload.screens,
            panes: try payload.panes.map { try $0.projected(to: list) })
    }

    private func projectPane(_ pane: ControlStatePayload.PaneInfo, fields: String?) throws -> JSONValue {
        guard let list = Self.fieldList(fields) else {
            let data = try ControlJSON.encoder.encode(pane)
            return try ControlJSON.decoder.decode(JSONValue.self, from: data)
        }
        return try pane.projected(to: list)
    }

    static func fieldList(_ raw: String?) -> [String]? {
        guard let raw, !raw.isEmpty else { return nil }
        let list = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return list.isEmpty ? nil : list
    }
}

/// `--fields` 之后的 state 负载（pane 变成投影过的对象）
struct ControlStateProjected: Encodable {
    var schema: String
    var app: ControlStatePayload.AppInfo
    var screens: [ControlStatePayload.ScreenInfo]
    var panes: [JSONValue]
}

