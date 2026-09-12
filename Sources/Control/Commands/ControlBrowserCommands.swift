import AppKit

/// `browser open|goto|reload|close` —— 浏览器 pane 里**标签**这一层。
///
/// 三条贯穿始终的规矩：
///
/// 1. **`-t` 指 pane，`--tab` 指标签。** 两级分开写（而不是塞进一个 `b3.2`）是因为
///    `.` 在寻址语法里已经是"工作区.pane"的分隔符；混在一起之后，
///    "第 2 个工作区的 b3"与"b3 的第 2 个标签"长得一模一样。
/// 2. **打码规则一个字都不松。** 标签的标题与网址跟 pane 级的 url / title 走同一条线：
///    没有 token 的调用方读到的是 `<redacted>`——包括**变更信封里的 diff**
///    （`from` 是命令跑之前那个页面的网址，泄出去和直接读 `state` 没有区别）。
/// 3. **关掉最后一个标签 = 关掉整个 pane。** 这不是我们发明的语义，是 ⌘W 在
///    `MainWindowController.perform(.closePane)` 里已经有的那一条（Chrome 语义）。
///    命令行要是自作主张"最后一个标签就不给关"，同一件事在两个入口会得到两种结果。
@MainActor
extension ControlCommandRunner {
    func runBrowser(_ ctx: ControlContext) throws -> (echo: ResolvedTarget?, data: any Encodable) {
        switch ctx.spec.verb {
        case "open": return try browserOpen(ctx)
        case "goto": return try browserGoto(ctx)
        case "reload": return try browserReload(ctx)
        case "close": return try browserClose(ctx)
        default:
            throw ControlErrorBody(.unknownCommand, "browser has no verb \(ctx.spec.verb)",
                                   candidates: ControlCommandTable.commands(inGroup: "browser").map(\.verb))
        }
    }

    // MARK: 解析

    /// 落到一个浏览器 pane 上。终端 pane 要给的是**明确的**错误，而不是一句"没做什么"
    func requireBrowser(_ ctx: ControlContext) throws -> (hit: PaneHit, pane: BrowserPaneView) {
        let hit = try requirePane(ctx, ctx.target)
        guard let browser = hit.pane as? BrowserPaneView else {
            throw ControlErrorBody(
                .wrongPaneKind,
                "\(handleName(hit.pane)) is a \(hit.pane.kind.rawValue) pane, so it has no tabs",
                hint: "Browser pane handles start with b (quickterm list panes); "
                    + "to open a new one: quickterm pane new --kind browser --url <url>")
        }
        return (hit, browser)
    }

    /// `--tab` → 0 起的下标。**越界与歧义一律报错**，绝不"就近挑一个"
    func resolveTab(_ ref: ControlTabRef, in pane: BrowserPaneView, handle: String) throws -> Int {
        let count = pane.tabs.count
        guard count > 0 else {
            throw ControlErrorBody(.notFound, "\(handle) has no tabs at all", retryAfterMs: 200)
        }
        switch ref {
        case .active:
            return pane.activeTabIndex
        case .last:
            return count - 1
        case .index(let number):
            guard number <= count else {
                throw ControlErrorBody(
                    .notFound, "\(handle) has \(count) tab\(count == 1 ? "" : "s"), so --tab \(number) is out of range",
                    hint: "quickterm get -t \(handle) --json | jq '.data.pane.tabList'")
            }
            return number - 1
        case .id(let prefix):
            let matches = pane.tabs.indices.filter {
                pane.tabs[$0].id.uuidString.replacingOccurrences(of: "-", with: "")
                    .lowercased().hasPrefix(prefix)
            }
            guard !matches.isEmpty else {
                throw ControlErrorBody(
                    .notFound, "\(handle) has no tab whose id starts with \(prefix)",
                    hint: "quickterm get -t \(handle) --json | jq '.data.pane.tabList'")
            }
            guard matches.count == 1 else {
                throw ControlErrorBody(
                    .ambiguousTarget, "--tab #\(prefix) matches \(matches.count) tabs in \(handle)",
                    hint: "Write out a few more digits of the id.",
                    candidates: matches.map { "#\(pane.tabs[$0].id.uuidString.prefix(8))" })
            }
            return matches[0]
        }
    }

    func tabRef(_ ctx: ControlContext) throws -> ControlTabRef {
        try ControlTabRef.parse(ctx.string("tab") ?? "")
    }

    /// diff 里能不能写真正的网址 / 标题。**变更信封会原样回给调用方**，
    /// 所以这里必须与 `state` 用同一条打码规则；写死成"反正是日志"就是一个绕过打码的通道
    func browserVisible(_ ctx: ControlContext, _ text: String?) -> String {
        guard ctx.encoder.exposesBrowser else { return ControlStateEncoder.redacted }
        let value = text ?? ""
        return value.isEmpty ? "—" : value
    }

    // MARK: open（新标签）

    private func browserOpen(_ ctx: ControlContext) throws -> (ResolvedTarget?, any Encodable) {
        let (hit, browser) = try requireBrowser(ctx)
        let raw = ctx.string("url") ?? BrowserPaneView.settings.home
        guard let url = ControlPaneFactory.resolveURL(raw) else {
            throw ControlErrorBody(.badRequest, "Could not resolve \(raw) to a URL")
        }
        let activate = try ctx.onOff("activate") ?? true
        let before = browser.tabs.count
        guard before < ControlBrowserLimits.maxTabs else {
            throw ControlErrorBody(
                .denied, "\(handleName(hit.pane)) already holds \(before) tabs (limit \(ControlBrowserLimits.maxTabs))",
                hint: "Close a few first: quickterm browser close -t \(handleName(hit.pane)) --others")
        }
        let base = path(hit.controller, hit.workspace, hit.pane)

        let mutation = ControlMutationRequest(
            command: ctx.spec.name, request: ctx.request, peer: ctx.peer,
            changes: [ControlChange("\(base).tabs", from: ControlChange.count(before, "tab"),
                                    to: ControlChange.count(before + 1, "tab"))],
            controllers: [hit.controller],
            // 布局没动，撤销栈里放一条"关掉那个标签"的假动作只会更乱
            undoCommand: nil, target: base)
        var payload = try commit(mutation) {
            browser.addTab(url: url, activate: activate)
        }
        payload.pane = paneInfo(hit, encoder: ctx.encoder)
        return (hit.echo, payload)
    }

    // MARK: goto（绝对设值：已经在那儿就什么都不做）

    private func browserGoto(_ ctx: ControlContext) throws -> (ResolvedTarget?, any Encodable) {
        let (hit, browser) = try requireBrowser(ctx)
        guard let raw = ctx.string("url") else {
            throw ControlErrorBody(.badRequest, "browser goto needs --url")
        }
        guard let url = ControlPaneFactory.resolveURL(raw) else {
            throw ControlErrorBody(.badRequest, "Could not resolve \(raw) to a URL")
        }
        let handle = handleName(hit.pane)
        let index = try resolveTab(try tabRef(ctx), in: browser, handle: handle)
        let tab = browser.tabs[index]
        let base = "\(path(hit.controller, hit.workspace, hit.pane)).tab\(index + 1)"

        // 已经在这个网址上 = 空操作（`--fail-if-noop` 会退 7）。
        // 想强制重新取一次就用 browser reload —— "设值"与"刷新"是两个不同的意图，
        // 混成一条命令之后，一次无意的重放会把一个填了一半的表单冲掉。
        //
        // **但这条幂等只对读得到网址的调用方成立。** 对读不到的（没 token / expose-browser=never）：
        // "改了没有"本身就是一个答案——一条 `--dry-run --fail-if-noop` 的 goto 能问出
        // "这个标签现在是不是正停在 <某网址> 上"，而同一个调用方读 `state` 拿到的是 `<redacted>`。
        // `SpecApplier.identityMatches` 关的正是这个通道（"宁可重建，也不要让『匹配上了没有』
        // 变成一个猜网址的探测通道"）。所以这类调用方一律当成一次改动：无条件加载，
        // `changed` 恒真，不携带任何关于当前网址的信息
        var changes: [ControlChange] = []
        //
        // 比的是**规范化之后**的两个网址（`ControlPaneFactory.sameURL`）：WebKit 落地的是
        // `http://localhost:3000/`，而没有人会那样写。照字面比的话，这条命令对最常见的那种
        // 写法永远报"变了"——绝对设值的承诺当场作废，页面还被白重载一次
        if !ctx.encoder.exposesBrowser
            || !ControlPaneFactory.sameURL(tab.effectiveURL, url) {
            changes.append(ControlChange(
                "\(base).url",
                from: browserVisible(ctx, tab.effectiveURL?.absoluteString),
                to: browserVisible(ctx, url.absoluteString),
                sensitive: true))
        }
        let mutation = ControlMutationRequest(
            command: ctx.spec.name, request: ctx.request, peer: ctx.peer, changes: changes,
            controllers: [hit.controller], undoCommand: nil, target: base)
        var payload = try commit(mutation) {
            browser.load(url, in: tab)
        }
        payload.pane = paneInfo(hit, encoder: ctx.encoder)
        return (hit.echo, payload)
    }

    // MARK: reload

    private func browserReload(_ ctx: ControlContext) throws -> (ResolvedTarget?, any Encodable) {
        let (hit, browser) = try requireBrowser(ctx)
        let handle = handleName(hit.pane)
        let index = try resolveTab(try tabRef(ctx), in: browser, handle: handle)
        let tab = browser.tabs[index]
        let hard = ctx.flag("hard")
        let base = "\(path(hit.controller, hit.workspace, hit.pane)).tab\(index + 1)"

        // 刷新**永远有事可做**（那就是它的全部意义）：`changes` 恒非空，
        // 于是 `--fail-if-noop` 对它永远不触发，而 `--dry-run` 如实说"会重新加载谁"
        let mutation = ControlMutationRequest(
            command: ctx.spec.name, request: ctx.request, peer: ctx.peer,
            changes: [ControlChange("\(base).load",
                                    from: browserVisible(ctx, tab.effectiveURL?.absoluteString),
                                    to: hard ? "reload (bypassing the cache)" : "reload",
                                    sensitive: true)],
            controllers: [hit.controller], undoCommand: nil, target: base)
        var payload = try commit(mutation) {
            browser.reload(tab, fromOrigin: hard)
        }
        payload.pane = paneInfo(hit, encoder: ctx.encoder)
        return (hit.echo, payload)
    }

    // MARK: close（破坏性：最后一个标签连 pane 一起关）

    private func browserClose(_ ctx: ControlContext) throws -> (ResolvedTarget?, any Encodable) {
        let (hit, browser) = try requireBrowser(ctx)
        try verifyPinned(ctx, controller: hit.controller, pane: hit.pane)
        let handle = handleName(hit.pane)
        let index = try resolveTab(try tabRef(ctx), in: browser, handle: handle)
        let others = ctx.flag("others")
        let force = ctx.flag(ControlCommandTable.Flag.force)
        let count = browser.tabs.count
        let panePath = path(hit.controller, hit.workspace, hit.pane)

        // 关到最后一个标签时**整个 pane 一起关**（= ⌘W 的语义，见文件头）。
        // `--others` 永远留下一个标签，所以它自己不会走到关 pane 那条路上
        let closesPane = !others && count == 1
        var changes: [ControlChange] = []
        if others {
            for (i, tab) in browser.tabs.enumerated() where i != index {
                changes.append(ControlChange("\(panePath).tab\(i + 1)",
                                             from: browserVisible(ctx, tab.displayTitle), to: "closed",
                                             sensitive: true))
            }
        } else {
            changes.append(ControlChange(
                closesPane ? panePath : "\(panePath).tab\(index + 1)",
                from: browserVisible(ctx, browser.tabs[index].displayTitle),
                to: closesPane ? "closed (last tab: the whole pane goes with it)" : "closed",
                sensitive: true))
        }

        let mutation = ControlMutationRequest(
            command: ctx.spec.name, request: ctx.request, peer: ctx.peer, changes: changes,
            controllers: [hit.controller],
            // 关掉的页面放不回来（进程 / 会话都没了），登记撤销只会造一个假象
            undoCommand: nil, target: panePath)

        var stillOpen = false
        var payload = try commit(mutation) {
            if others {
                // **从后往前关**：从前往后的话，每关一个后面的下标都要往前挪一格
                for i in stride(from: browser.tabs.count - 1, through: 0, by: -1) where i != index {
                    browser.closeTab(at: i)
                }
            } else if closesPane {
                if hit.workspace == hit.controller.model.activeIndex {
                    hit.controller.closePane(hit.pane, confirmIfNeeded: !force, animated: false)
                } else {
                    hit.controller.removeFromAnyWorkspace(hit.pane)
                }
                hit.controller.flushPendingCloses()
                stillOpen = hit.controller.model.allPanes.contains { $0 === hit.pane }
            } else {
                browser.closeTab(at: index)
            }
        }
        // 关 pane 那条路可能撞上"仍有进程在运行"的确认框：**按事实判定**，不去猜（同 pane close）
        if payload.applied, closesPane, stillOpen {
            payload.confirmPending = true
            payload.applied = false
            payload.note = "QuickTerm put up a confirmation prompt, so the pane is not closed yet; --force skips it."
        }
        if payload.applied, closesPane, !stillOpen {
            payload.note = "That was the last tab, so the whole pane closed with it (same as ⌘W)."
        }
        // pane 还在（没关它、只关了标签，或者是一次预演）才回它的记录：
        // 关掉之后再编码一次等于回报一个已经不存在的东西
        if hit.controller.model.allPanes.contains(where: { $0 === hit.pane }) {
            payload.pane = paneInfo(hit, encoder: ctx.encoder)
        }
        payload.workspace = ctx.encoder.workspaceInfo(hit.controller, index: hit.workspace)
        return (ResolvedTarget(screen: hit.controller.screenIndex + 1,
                               screenID: hit.controller.windowID.uuidString,
                               workspace: hit.workspace + 1,
                               pane: handle, paneID: hit.pane.id.uuidString), payload)
    }
}

/// 标签这一层的上限。上限本身就是策略：没有它，一个跑飞的 agent 能在一个 pane 里
/// 开出几百个 WKWebView（每个都是一条 WebContent 进程），机器会先于用户发现这件事
enum ControlBrowserLimits {
    static let maxTabs = 50
}
