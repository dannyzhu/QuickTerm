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
        var enabled: Bool = true
        var mode: String = "ask"
        var exposeBrowser: String = "token"
        var sendText: Bool = false

        init() {}

        init(_ settings: ConfigStore.Settings) {
            enabled = settings.controlEnabled
            mode = settings.controlMode
            exposeBrowser = settings.controlExposeBrowser
            sendText = settings.controlSendText
        }

        var isListening: Bool { enabled && mode != "off" }
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
        /// 确认框里那句话的简短版（漂移时回给调用方，让它知道当时确认的是什么）
        var description: String
    }

    let screens: ScreenRegistry
    let consent: ControlConsent
    var config = Config()
    /// 单调状态序号：每条成功的变更 +1，`state` 里回给 agent 判断快照是否过期
    private(set) var seq = 0
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

    /// 每条成功的变更 +1
    func seqDidMutate() { seq += 1 }

    func dryRun(_ request: ControlRequest) -> Bool {
        request.args[ControlCommandTable.Flag.dryRun]?.boolValue ?? false
    }

    init(screens: ScreenRegistry, consent: ControlConsent) {
        self.screens = screens
        self.consent = consent
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
                                  "协议版本不匹配：调用方 v\(request.v)，QuickTerm \(appVersion) 说 v\(ControlProtocol.version)",
                                  hint: "更新 quickterm 命令行（QuickTerm.app/Contents/MacOS/quickterm），或重新 install-cli"))
            return
        }
        guard let spec = ControlCommandTable.command(request.cmd) else {
            fail(ControlErrorBody(.unknownCommand, "未知命令 \(request.cmd)",
                                  hint: "quickterm describe --json 里有全部命令",
                                  candidates: ControlCommandTable.commands.map(\.name)))
            return
        }
        guard config.isListening else {
            fail(ControlErrorBody(.denied, "控制面已关闭（[control] mode = \(config.mode)）"))
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
                fail(ControlErrorBody(.badRequest, "action 需要一个动作名",
                                      hint: "quickterm action --list"))
                return
            }
            guard let parsed = WMAction(rawValue: raw) else {
                fail(ControlErrorBody(.unknownAction, "未知动作 \(raw)",
                                      hint: "quickterm action --list",
                                      candidates: Self.suggestions(for: raw)))
                return
            }
            action = parsed
            cls = ControlCommandTable.actionClass(parsed)
        } else if spec.name == "action" {
            cls = .read   // --list 只是打印表
        }

        if cls == .interactive, let action {
            fail(ControlErrorBody(.interactiveAction,
                                  "\(action.rawValue) 会打开需要键盘交互的面板 / 弹出菜单，不能经 socket 执行",
                                  hint: ControlCommandTable.interactiveHint(action)))
            return
        }
        if cls == .sensitive, !config.sendText {
            fail(ControlErrorBody(.denied, "敏感命令默认关闭",
                                  hint: "在 ~/.config/quickterm/config.toml 的 [control] 里写 send-text = true"))
            return
        }
        if cls.isMutation, !config.allowsMutation {
            fail(ControlErrorBody(.denied, "控制面是只读模式（[control] mode = \(config.mode)）",
                                  hint: "改成 mode = \"ask\" 才能执行变更"))
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
                "--dry-run / --fail-if-noop 只对名词-动词层的变更命令有意义（\(spec.cli) 没有可预演的 diff）",
                hint: spec.name == "action"
                    ? "action 是快捷键直通车；要预演请用 quickterm pane close / workspace clear 这类命令"
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
            fail(ControlErrorBody(.busy, "QuickTerm 正有一个对话框挂着，变更命令暂不执行",
                                  hint: "先处理掉 QuickTerm 里的对话框", retryAfterMs: 2000))
            return
        }

        // 限流：变更命令按**来源**再限一次。CLI 每条命令开一条新连接，
        // 连接级那只桶对 `for i in {1..200}; do quickterm pane new; done` 完全无效
        if cls.isMutation, !(dryRun(request) && spec.honorsMutationFlags) {
            let origin = request.origin?.pane.map { "pane:\($0)" } ?? "pid:\(peer.pid)"
            if case .limited(let retry, let scope) = rateLimiter.admit(origin: origin) {
                logRefusal(request.cmd, peer: peer, request: request, code: .rateLimited,
                           message: "限流（\(scope)）")
                fail(ControlErrorBody(.rateLimited, "变更太密集了（\(scope) 限流）",
                                      hint: "把批量操作合并，或放慢重试", retryAfterMs: retry))
                return
            }
        }

        // `--dry-run` 什么都不改，因此**不问**：确认框问的是"要不要动手"，
        // 而这次根本不会动手。它能读到的东西 `state` 本来就给（同一套打码规则）
        // 豁免绑在"这条命令真的实现了预演"上，而不是"带了这个开关"：
        // 将来再加一条不算 diff 的直通命令时，忘了实现 dry-run 最坏是接受了一个没用的开关
        // （下面 execute() 里那道闸门会直接拒），而不是悄悄拆掉确认闸门
        let needsConsent = cls.requiresConsent && config.promptsForDestructive
            && !(dryRun(request) && spec.honorsMutationFlags)

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
        if consent.isModalBusy, !consent.hasGrant(pid: peer.pid, cls: cls) {
            fail(ControlErrorBody(.busy, "QuickTerm 正有一个对话框挂着，破坏性命令暂不执行",
                                  hint: "先处理掉 QuickTerm 里的对话框", retryAfterMs: 2000))
            return
        }
        consent.evaluate(.init(peerName: peer.processName, peerPID: peer.pid, cls: cls,
                               summary: Self.consentSummary(request, spec: spec, action: action,
                                                            target: target, subject: pinned),
                               originPane: originHandle(for: request),
                               tokenPresent: request.token == ControlEnvironment.token)) { decision in
            switch decision {
            case .allow:
                execute()
            case .deny:
                fail(ControlErrorBody(.denied, "用户拒绝了这条命令"))
            case .timeout:
                fail(ControlErrorBody(.confirmationRequired,
                                      "需要在 QuickTerm 里确认（\(Int(ControlConsent.timeout)) 秒内没有回应）",
                                      hint: "切到 QuickTerm 批准，然后重试"))
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
                description: "屏幕 \(controller.screenIndex + 1) 工作区 \(resolution.workspace + 1)"
                    + "（\(panes.count) 个 pane：\(handles.joined(separator: " "))）")
        case "screen.close":
            let resolution = try resolver.resolve(target)
            let controller = resolution.controller
            return PinnedSubject(
                controller: controller, workspace: resolution.workspace, pane: nil, handle: nil,
                paneIDs: nil,
                description: "屏幕 \(controller.screenIndex + 1)「\(controller.window?.title ?? "")」"
                    + "（\(controller.model.allPanes.count) 个 pane）")
        default:
            var effective = target ?? ControlTarget()
            if effective.pane == nil { effective.pane = .focused }
            let resolution = try resolver.resolve(effective)
            guard let subject = resolution.pane ?? resolution.controller.focusedPane else { return nil }
            let handle = ControlHandleRegistry.shared.handle(for: subject)
            return PinnedSubject(
                controller: resolution.controller, workspace: resolution.workspace,
                pane: subject, handle: handle, paneIDs: nil,
                description: "\(handle)「\(subject.paneTitle)」")
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
                text += "\n清空 \(subject.description) —— 其中的进程会被结束"
            case "screen.close":
                text += "\n关闭 \(subject.description) —— 其中的进程会被结束"
            default:
                // 浏览器 pane 还有别的标签时，close-pane 关的是当前标签而不是整个 pane（Chrome 语义）
                let tabOnly = (subject.pane as? BrowserPaneView).map { $0.tabs.count > 1 } ?? false
                text += "\n作用于 \(subject.description)"
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
                                error: ControlErrorBody(.busy, "已经有一条控制命令在执行",
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
                                    "--dry-run / --fail-if-noop 只对名词-动词层的变更命令有意义（\(spec.cli) 没有可预演的 diff）")))
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
                    throw ControlErrorBody(.badRequest, "list 只接受 screens / workspaces / panes",
                                           candidates: ["screens", "workspaces", "panes"])
                }
                completion(.success(id: request.id, seq: seq, resolved: resolution.echo, data: out))

            case "get":
                var effective = target ?? ControlTarget()
                if effective.pane == nil { effective.pane = .focused }
                let resolution = try resolver.resolve(effective)
                guard let pane = resolution.pane else {
                    throw ControlErrorBody(.notFound, "没有可寻址的 pane")
                }
                let positions = ControlStateEncoder.positions(
                    in: resolution.controller.model.layouts[resolution.workspace])
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
                guard let action else { throw ControlErrorBody(.badRequest, "action 需要一个动作名") }
                let payload = try runAction(action, target: target, resolver: resolver,
                                            precise: request.args["precise"]?.boolValue ?? false,
                                            encoder: encoder, pinned: pinned)
                seq += 1
                completion(.success(id: request.id, seq: seq, resolved: payload.echo, data: payload.data))

            case "describe":
                let document = ControlDescribeDocument.make(
                    cliVersion: appVersion, appVersion: appVersion,
                    socket: ControlEnvironment.socketPath, mode: config.mode)
                completion(.success(id: request.id, seq: seq, resolved: nil, data: document))

            case "version":
                completion(.success(id: request.id, seq: seq, resolved: nil,
                                    data: ControlVersionPayload(
                                        cli: appVersion, app: appVersion,
                                        protocolVersion: ControlProtocol.version,
                                        appProtocolVersion: ControlProtocol.version,
                                        socket: ControlEnvironment.socketPath, running: true)))

            default:
                // Phase 2 的名词-动词层：统一的 (echo, 变更信封) 形状
                guard let group = spec.group else {
                    throw ControlErrorBody(.unknownCommand, "命令 \(spec.name) 在本阶段还没有实现")
                }
                let ctx = ControlContext(spec: spec, request: request, peer: peer, target: target,
                                         resolver: resolver, encoder: encoder, pinned: pinned)
                let result: (echo: ResolvedTarget?, data: any Encodable)
                switch group {
                case "pane": result = try runPane(ctx)
                case "workspace": result = try runWorkspace(ctx)
                case "screen": result = try runScreen(ctx)
                case "app": result = try runApp(ctx)
                default:
                    throw ControlErrorBody(.unknownCommand, "未知命令组 \(group)",
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
                    "\(action.rawValue) 指向工作区 \(index + 1)，但屏幕 \(controller.screenIndex + 1) 只有 \(count) 个",
                    hint: "改 ~/.config/quickterm/config.toml 的 workspaces（1–10）")
            }
        }

        // `action` 直通 `perform()`，而 `perform()` 只作用于**活动**工作区。
        // 目标指了另一个工作区却照做，就是那种"agent 以为动了、其实动在别处"的静默错误
        if target?.workspace != nil, resolution.workspace != controller.model.activeIndex,
           action.workspaceIndex == nil {
            throw ControlErrorBody(
                .badTarget,
                "action 作用于活动工作区（当前是 \(controller.model.activeIndex + 1)），目标却是 \(resolution.workspace + 1)",
                hint: "先 quickterm action goto-workspace-\(resolution.workspace + 1)")
        }

        // 目标显式指了 pane：先把焦点交过去，**并且校验交成功了**才执行。
        // 交接是异步重试的（最长 0.75s），校验失败一律返回 busy——绝不对着错的 pane 动手
        if target?.pane != nil, let pane = resolution.pane {
            guard resolution.workspace == controller.model.activeIndex else {
                throw ControlErrorBody(
                    .badTarget,
                    "pane \(ControlHandleRegistry.shared.handle(for: pane)) 在工作区 \(resolution.workspace + 1)，不是活动工作区",
                    hint: "先 quickterm action goto-workspace-\(resolution.workspace + 1)")
            }
            if controller.focusedPane !== pane {
                controller.requestFocus(to: pane)
                guard controller.focusedPane === pane else {
                    throw ControlErrorBody(
                        .busy,
                        "焦点没能在同一轮里交给 \(ControlHandleRegistry.shared.handle(for: pane))（SwiftUI 还没挂载它）",
                        hint: "稍后重试；本次什么都没做", retryAfterMs: 200)
                }
            }
        }

        if action.browserOnly, !(controller.focusedPane is BrowserPaneView) {
            throw ControlErrorBody(
                .wrongPaneKind, "\(action.rawValue) 只对浏览器 pane 生效，当前焦点不是浏览器 pane",
                hint: "用 -t <浏览器 pane 句柄>（quickterm list panes 里 kind=browser 的那些）")
        }
        if action.terminalOnly, !(controller.focusedPane is Ghostty.SurfaceView) {
            throw ControlErrorBody(
                .wrongPaneKind, "\(action.rawValue) 只对终端 pane 生效，当前焦点不是终端 pane",
                hint: "用 -t <终端 pane 句柄>")
        }

        // 确认闸门批准的是**这一个** pane：落刀前再核一次身份。
        // 用户读确认框的那十秒里，不需要确认的 mutate 命令（`focus-right`、`goto-workspace-N`…）
        // 完全可以插进来把焦点挪走；那时宁可整条命令 busy 掉，也绝不把批准过的一刀落到别处
        if let pinned, let pinnedPane = pinned.pane {
            guard controller === pinned.controller, controller.focusedPane === pinnedPane,
                  !controller.model.closingPanes.contains(pinnedPane.id) else {
                throw ControlErrorBody(
                    .busy,
                    "确认期间目标变了（当时确认的是 \(pinned.handle ?? pinned.description)，现在的焦点已不是它）：本次什么都没做",
                    hint: "重新发一次，或用 -t \(pinned.handle ?? "<句柄>") 精确指定", retryAfterMs: 200)
            }
        }

        let before = Set(controller.model.allPanes.map(\.id))
        let confirmPending = action == .closePane && (controller.focusedPane?.wantsConfirmClose ?? false)
        controller.perform(action, precise: precise)   // perform() 自己先 flushPendingCloses()

        let after = controller.model.allPanes.filter { !before.contains($0.id) }
        let positions = ControlStateEncoder.positions(in: controller.model.layout)
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

extension ControlErrorBody: Error {}
