import AppKit

/// `pane new|close|focus|move|swap|set|resize`。
///
/// 每条命令的形状都一样：**先只读地算出 diff，再交给 `commit`**。
/// 这不是风格问题——`--dry-run`（什么都不改）与 `--fail-if-noop`（已经是目标状态 → 退 7）
/// 是从这个形状里长出来的，不是各自加一个 if 判断。
@MainActor
extension ControlCommandRunner {
    func runPane(_ ctx: ControlContext) throws -> (echo: ResolvedTarget?, data: any Encodable) {
        switch ctx.spec.verb {
        case "new": return try paneNew(ctx)
        case "close": return try paneClose(ctx)
        case "focus": return try paneFocus(ctx)
        case "move": return try paneMove(ctx)
        case "swap": return try paneSwap(ctx)
        case "set": return try paneSet(ctx)
        case "resize": return try paneResize(ctx)
        default: throw ControlErrorBody(.unknownCommand, "pane 没有 \(ctx.spec.verb) 这个动词")
        }
    }

    // MARK: new

    private func paneNew(_ ctx: ControlContext) throws -> (ResolvedTarget?, any Encodable) {
        // 落点：--at 锚点优先（它自带屏幕 / 工作区），否则用 -t 给的范围
        var anchor: PaneView?
        var controller: MainWindowController
        var workspace: Int
        if let at = try ctx.parseTarget("at") {
            let hit = try requirePane(ctx, at)
            anchor = hit.pane
            controller = hit.controller
            workspace = hit.workspace
            if let scope = ctx.target, scope.screen != nil || scope.workspace != nil {
                let wanted = try requireScope(ctx, scope)
                guard wanted.controller === controller, wanted.workspace == workspace else {
                    throw ControlErrorBody(
                        .badTarget,
                        "--at \(handleName(hit.pane)) 在 \(path(controller, workspace))，与 -t 给的 \(path(wanted.controller, wanted.workspace)) 不符",
                        hint: "去掉 -t，或换一个锚点")
                }
            }
        } else {
            let scope = try requireScope(ctx, ctx.target)
            controller = scope.controller
            workspace = scope.workspace
            anchor = scope.pane ?? (workspace == controller.model.activeIndex
                                    ? controller.focusedPane
                                    : controller.model.layouts[workspace].paneList.last)
        }

        let live = controller.model.layouts[workspace].paneList.count
            + controller.model.floatings[workspace].count
        guard live < ControlRateLimiter.maxPanesPerWorkspace else {
            throw ControlErrorBody(
                .denied,
                "工作区 \(path(controller, workspace)) 已经有 \(live) 个 pane（上限 \(ControlRateLimiter.maxPanesPerWorkspace)）",
                hint: "先关掉一些，或换一个工作区")
        }

        let kind = ctx.string("kind") ?? "terminal"
        let zone = try ctx.zone()
        let cwd = ctx.string("cwd").map { ($0 as NSString).expandingTildeInPath }
        if let cwd, cwd.hasPrefix("~") || cwd.contains("\0") {
            throw ControlErrorBody(.badRequest, "--cwd 不是一个可用的路径：\(cwd)")
        }
        // 造 pane 的那一份实现是共用的（`spec apply` 走同一条）：参数互斥与网址解析都在它那儿
        let recipe = ControlPaneFactory.Request(
            kind: kind, cwd: cwd, cmd: ctx.string("cmd"), hold: ctx.flag("hold"),
            env: try Self.parseEnvironment(ctx.strings("env")), url: ctx.string("url"))
        try ControlPaneFactory.validate(recipe)

        var created: PaneView?
        let mutation = ControlMutationRequest(
            command: ctx.spec.name, request: ctx.request, peer: ctx.peer,
            changes: [ControlChange(path(controller, workspace),
                                    from: "\(live) panes", to: "\(live + 1) panes")],
            controllers: [controller], undoName: "控制面：\(ctx.spec.cli)",
            target: path(controller, workspace, anchor))

        var payload = try commit(mutation) {
            let made = try ControlPaneFactory.make(recipe, controller: controller,
                                                   inheriting: anchor?.workingDirectory)
            guard controller.controlInsert(made.pane, workspace: workspace, anchor: anchor,
                                           zone: zone, focus: true) else {
                ControlPaneFactory.discard(made, controller: controller)
                throw ControlErrorBody(.failed, "没能把新 pane 插进 \(path(controller, workspace))")
            }
            ControlPaneFactory.register(made, controller: controller)
            created = made.pane
        }

        guard let pane = created else {
            // dry-run：什么都没建，如实回报会建在哪
            return (ResolvedTarget(screen: controller.screenIndex + 1,
                                   screenID: controller.windowID.uuidString,
                                   workspace: workspace + 1,
                                   pane: anchor.map { handleName($0) },
                                   paneID: anchor?.id.uuidString), payload)
        }
        payload.pane = paneInfo(pane, controller: controller, workspace: workspace, encoder: ctx.encoder)
        payload.focusPending = controller.focusedPane !== pane ? true : nil
        payload.workspace = ctx.encoder.workspaceInfo(controller, index: workspace)
        return (ResolvedTarget(screen: controller.screenIndex + 1,
                               screenID: controller.windowID.uuidString,
                               workspace: workspace + 1,
                               pane: handleName(pane), paneID: pane.id.uuidString), payload)
    }

    /// `--env KEY=VALUE`。控制字符一律拒绝：它们会一路混进子进程的环境
    static func parseEnvironment(_ raw: [String]) throws -> [String: String] {
        var out: [String: String] = [:]
        for entry in raw {
            guard let eq = entry.firstIndex(of: "="), eq != entry.startIndex else {
                throw ControlErrorBody(.badRequest, "--env 要写成 KEY=VALUE，收到 \(entry)")
            }
            let key = String(entry[entry.startIndex..<eq])
            let value = String(entry[entry.index(after: eq)...])
            guard !key.contains(" "), (key + value).unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7F }) else {
                throw ControlErrorBody(.badRequest, "--env \(key) 含有非法字符")
            }
            out[key] = value
        }
        return out
    }

    // MARK: close

    private func paneClose(_ ctx: ControlContext) throws -> (ResolvedTarget?, any Encodable) {
        let hit = try requirePane(ctx, ctx.target)
        try verifyPinned(ctx, controller: hit.controller, pane: hit.pane)
        let handle = handleName(hit.pane)
        // 浏览器 pane 还有别的标签时 Cmd+W 关的是当前标签（Chrome 语义）；
        // 命令行是"关掉这个 pane"，语义更硬：整块关掉，标签一起没
        let title = hit.pane.paneTitle
        let force = ctx.flag(ControlCommandTable.Flag.force)

        let mutation = ControlMutationRequest(
            command: ctx.spec.name, request: ctx.request, peer: ctx.peer,
            changes: [ControlChange(path(hit.controller, hit.workspace, hit.pane),
                                    from: "open「\(title)」", to: "closed")],
            controllers: [hit.controller],
            // **不登记撤销**：进程已经被结束了，把布局放回去只会造出一个"好像还在"的假象
            undoName: nil,
            target: path(hit.controller, hit.workspace, hit.pane))

        // 会不会弹确认只有 `closePane` 自己知道（文件管理器 pane 有子进程也不弹；
        // 非活动工作区走 `removeFromAnyWorkspace`，根本不问）。事前猜一定会猜错，
        // 所以**落刀之后按事实判定**：pane 还在 = 确认框挂着，不在 = 真关了
        var stillOpen = false
        var payload = try commit(mutation) {
            if hit.workspace == hit.controller.model.activeIndex {
                hit.controller.closePane(hit.pane, confirmIfNeeded: !force, animated: false)
            } else {
                hit.controller.removeFromAnyWorkspace(hit.pane)   // 非活动工作区：直接摘（含收尾）
            }
            hit.controller.flushPendingCloses()
            stillOpen = hit.controller.model.allPanes.contains { $0 === hit.pane }
        }
        if payload.applied, stillOpen {
            payload.confirmPending = true
            payload.applied = false
            payload.note = "QuickTerm 弹了一句「仍有进程在运行」的确认，pane 还没关；--force 可跳过"
        }
        payload.workspace = ctx.encoder.workspaceInfo(hit.controller, index: hit.workspace)
        return (ResolvedTarget(screen: hit.controller.screenIndex + 1,
                               screenID: hit.controller.windowID.uuidString,
                               workspace: hit.workspace + 1,
                               pane: handle, paneID: hit.pane.id.uuidString), payload)
    }

    // MARK: focus

    private func paneFocus(_ ctx: ControlContext) throws -> (ResolvedTarget?, any Encodable) {
        var target = ctx.target
        // `quickterm pane focus right` —— 位置参数是相对方向的糖，落到同一套目标语法上
        if let direction = ctx.string("where") {
            var relative = target ?? ControlTarget()
            relative.pane = switch direction {
            case "left": .direction(.left)
            case "right": .direction(.right)
            case "up": .direction(.up)
            case "down": .direction(.down)
            case "next": .cycle(next: true)
            case "prev": .cycle(next: false)
            default: throw ControlErrorBody(.badRequest, "pane focus 的方向只接受 left/right/up/down/next/prev")
            }
            target = relative
        }
        let hit = try requirePane(ctx, target)
        let controller = hit.controller
        let already = controller.focusedPane === hit.pane && controller.model.activeIndex == hit.workspace
        var changes: [ControlChange] = []
        if !already {
            changes.append(ControlChange(path(controller, hit.workspace),
                                         from: controller.focusedPane.map { handleName($0) } ?? "—",
                                         to: handleName(hit.pane)))
        }
        let mutation = ControlMutationRequest(
            command: ctx.spec.name, request: ctx.request, peer: ctx.peer, changes: changes,
            controllers: [controller], undoName: nil,   // 焦点不进撤销栈（⌘Z 撤销焦点只会更乱）
            target: path(controller, hit.workspace, hit.pane))
        var payload = try commit(mutation) {
            if controller.model.activeIndex != hit.workspace { controller.switchWorkspace(hit.workspace) }
            controller.requestFocus(to: hit.pane)
        }
        payload.pane = paneInfo(hit, encoder: ctx.encoder)
        payload.focusPending = controller.focusedPane !== hit.pane ? true : nil
        return (hit.echo, payload)
    }

    // MARK: move

    private func paneMove(_ ctx: ControlContext) throws -> (ResolvedTarget?, any Encodable) {
        let hit = try requirePane(ctx, ctx.target)
        guard let toRaw = ctx.string("to") else {
            throw ControlErrorBody(.badRequest, "pane move 需要 --to <screen:workspace>")
        }
        guard let to = try ctx.parseTarget("to") else {
            throw ControlErrorBody(.badRequest, "--to \(toRaw) 解析失败")
        }
        guard to.pane == nil else {
            throw ControlErrorBody(.badRequest, "--to 只接受 screen:workspace（落点用 --at / --where）")
        }
        let destination = try requireScope(ctx, to)
        let follow = ctx.flag("follow") && !ctx.flag("no-follow")

        var anchor: PaneView?
        if let at = try ctx.parseTarget("at") {
            let anchorHit = try requirePane(ctx, at)
            guard anchorHit.controller === destination.controller,
                  anchorHit.workspace == destination.workspace else {
                throw ControlErrorBody(
                    .badTarget,
                    "--at \(handleName(anchorHit.pane)) 不在目标 \(path(destination.controller, destination.workspace)) 里")
            }
            anchor = anchorHit.pane
        }
        let zone = try ctx.zone()

        guard hit.controller !== destination.controller || hit.workspace != destination.workspace else {
            // 已经在目标工作区：这是一次落点调整（有锚点才有意义），否则就是空操作
            guard let anchor, let zone else {
                let mutation = ControlMutationRequest(
                    command: ctx.spec.name, request: ctx.request, peer: ctx.peer, changes: [],
                    controllers: [hit.controller], undoName: nil,
                    target: path(hit.controller, hit.workspace, hit.pane))
                var payload = try commit(mutation) {}
                payload.pane = paneInfo(hit, encoder: ctx.encoder)
                return (hit.echo, payload)
            }
            let mutation = ControlMutationRequest(
                command: ctx.spec.name, request: ctx.request, peer: ctx.peer,
                changes: [ControlChange(path(hit.controller, hit.workspace, hit.pane),
                                        from: "原位", to: "\(handleName(anchor)) 的 \(ctx.string("where") ?? "right")")],
                controllers: [hit.controller], undoName: "控制面：\(ctx.spec.cli)",
                target: path(hit.controller, hit.workspace, hit.pane))
            var payload = try commit(mutation) {
                hit.controller.controlReplace(hit.pane, workspace: hit.workspace,
                                              anchor: anchor, zone: zone)
            }
            payload.pane = paneInfo(hit, encoder: ctx.encoder)
            payload.workspace = ctx.encoder.workspaceInfo(hit.controller, index: hit.workspace)
            return (hit.echo, payload)
        }

        let source = hit.controller
        let target = destination.controller
        let mutation = ControlMutationRequest(
            command: ctx.spec.name, request: ctx.request, peer: ctx.peer,
            changes: [ControlChange(handleName(hit.pane),
                                    from: path(source, hit.workspace),
                                    to: path(target, destination.workspace))],
            controllers: source === target ? [source] : [source, target],
            undoName: "控制面：\(ctx.spec.cli)",
            target: path(target, destination.workspace))

        var moved = false
        var payload = try commit(mutation) {
            guard source.controlHandOff(hit.pane, to: target, workspace: destination.workspace,
                                        anchor: anchor, zone: zone, follow: follow) else {
                // controlHandOff 放不进去时已经把 pane 放回原处了：抛出 = 什么都没变
                throw ControlErrorBody(.failed, "没能把 \(handleName(hit.pane)) 放进 \(path(target, destination.workspace))")
            }
            moved = true
        }
        let landedWorkspace = moved ? destination.workspace : hit.workspace
        let landedController = moved ? target : source
        payload.pane = paneInfo(hit.pane, controller: landedController, workspace: landedWorkspace,
                                encoder: ctx.encoder)
        payload.workspace = ctx.encoder.workspaceInfo(landedController, index: landedWorkspace)
        payload.focusPending = follow && landedController.focusedPane !== hit.pane ? true : nil
        if moved, !follow {
            payload.note = "pane 已经在 \(path(landedController, landedWorkspace))，但没有跟随切过去（--follow 才切）"
        }
        return (ResolvedTarget(screen: landedController.screenIndex + 1,
                               screenID: landedController.windowID.uuidString,
                               workspace: landedWorkspace + 1,
                               pane: handleName(hit.pane), paneID: hit.pane.id.uuidString), payload)
    }

    // MARK: swap

    private func paneSwap(_ ctx: ControlContext) throws -> (ResolvedTarget?, any Encodable) {
        let hit = try requirePane(ctx, ctx.target)
        guard let withTarget = try ctx.parseTarget("with") else {
            throw ControlErrorBody(.badRequest, "pane swap 需要 --with <pane>")
        }
        let other = try requirePane(ctx, withTarget)
        guard hit.pane !== other.pane else {
            throw ControlErrorBody(.badRequest, "不能和自己交换（\(handleName(hit.pane))）")
        }
        guard hit.controller === other.controller, hit.workspace == other.workspace else {
            throw ControlErrorBody(
                .badTarget,
                "两个 pane 不在同一个工作区（\(path(hit.controller, hit.workspace)) ↔ \(path(other.controller, other.workspace))）",
                hint: "跨工作区请用 quickterm pane move")
        }
        let controller = hit.controller
        let mutation = ControlMutationRequest(
            command: ctx.spec.name, request: ctx.request, peer: ctx.peer,
            changes: [ControlChange(path(controller, hit.workspace),
                                    from: "\(handleName(hit.pane)) ↔ \(handleName(other.pane))",
                                    to: "\(handleName(other.pane)) ↔ \(handleName(hit.pane))")],
            controllers: [controller], undoName: "控制面：\(ctx.spec.cli)",
            target: path(controller, hit.workspace, hit.pane))
        var payload = try commit(mutation) {
            guard controller.controlSwap(hit.pane, other.pane, workspace: hit.workspace) else {
                throw ControlErrorBody(.failed, "交换失败（两个 pane 必须都在平铺层里）",
                                       hint: "浮动 pane 先 quickterm pane set --float off")
            }
        }
        payload.pane = paneInfo(hit, encoder: ctx.encoder)
        payload.workspace = ctx.encoder.workspaceInfo(controller, index: hit.workspace)
        return (hit.echo, payload)
    }

    // MARK: set（绝对设值）

    private func paneSet(_ ctx: ControlContext) throws -> (ResolvedTarget?, any Encodable) {
        let hit = try requirePane(ctx, ctx.target)
        let controller = hit.controller
        let zoom = try ctx.onOff("zoom")
        let float = try ctx.onOff("float")
        let width = ctx.double("width")
        let ratio = ctx.double("ratio")
        guard zoom != nil || float != nil || width != nil || ratio != nil else {
            throw ControlErrorBody(.badRequest, "pane set 至少要给一个设值（--zoom / --float / --width / --ratio）",
                                   hint: "quickterm pane set --help")
        }
        let layoutName = controller.model.layouts[hit.workspace].name
        if width != nil, layoutName != "scrolling" {
            throw ControlErrorBody(.badRequest, "--width 只对 scrolling 工作区有意义（当前是 \(layoutName)）",
                                   hint: "dwindle 用 --ratio")
        }
        if ratio != nil, layoutName != "dwindle" {
            throw ControlErrorBody(.badRequest, "--ratio 只对 dwindle 工作区有意义（当前是 \(layoutName)）",
                                   hint: "scrolling 用 --width")
        }
        if let width, !ScrollingStrip.widthRange.contains(width) {
            throw ControlErrorBody(
                .badRequest,
                "--width 必须在 \(ScrollingStrip.widthRange.lowerBound)–\(ScrollingStrip.widthRange.upperBound) 之间，收到 \(width)",
                hint: "越界不会被静默夹紧：那样 agent 读回来的值和写下去的对不上")
        }
        // 收的是**引擎真的能持有的**那一段（= spec 的 ratioRange），不是手打舒服的 0.1–0.9：
        // 鼠标拖分隔条只夹到 10pt，一块 1600pt 宽的 pane 拖到底就是 0.006，
        // 而 `spec apply` 落得下这个数——绝对设值这一条却收不了的话，
        // dump 出来的工作区没法用 `pane set` 复现（越界照旧报错，绝不静默夹紧）
        if let ratio, !SpecLimits.ratioRange.contains(ratio) {
            throw ControlErrorBody(
                .badRequest,
                "--ratio 必须在 \(SpecLimits.ratioRange.lowerBound)–\(SpecLimits.ratioRange.upperBound) 之间，收到 \(ratio)",
                hint: "想按鼠标那条最小尺寸规则夹一下就用 pane resize --ratio")
        }

        let base = path(controller, hit.workspace, hit.pane)
        var changes: [ControlChange] = []
        let floatingNow = controller.controlIsFloating(hit.pane, workspace: hit.workspace)
        if let float, float != floatingNow {
            guard hit.workspace == controller.model.activeIndex else {
                throw ControlErrorBody(
                    .badTarget, "--float 只能作用于活动工作区里的 pane（浮动层的几何要按当前窗口算）",
                    hint: "先 quickterm workspace goto \(hit.workspace + 1)")
            }
            changes.append(ControlChange("\(base).float", from: floatingNow ? "on" : "off", to: float ? "on" : "off"))
        }
        // zoom / 列宽 / split 比例都是**平铺层内**的属性：浮动 pane 一个都没有。
        // 判定要按"这条命令做完之后它在哪一层"，因为同一条命令里的 `--float off`
        // 会先把它塞回平铺层（apply 里 float 排在最前）
        let willFloat = float ?? floatingNow
        if willFloat, zoom == true || width != nil || ratio != nil {
            throw ControlErrorBody(
                .badRequest,
                "\(handleName(hit.pane)) 设完仍在浮动层，而 --zoom / --width / --ratio 都是平铺层内的属性",
                hint: "同一条命令里加 --float off，就会先落回平铺层再设这些值")
        }

        let zoomedNow = controller.controlIsZoomed(hit.pane, workspace: hit.workspace)
        if let zoom, zoom != zoomedNow {
            changes.append(ControlChange("\(base).zoom", from: zoomedNow ? "on" : "off", to: zoom ? "on" : "off"))
        }
        let widthNow = controller.controlColumnWidth(of: hit.pane, workspace: hit.workspace)
        if let width {
            if let widthNow {
                if abs(widthNow - width) >= 0.0005 {
                    changes.append(ControlChange("\(base).width", from: Self.number(widthNow), to: Self.number(width)))
                }
            } else {
                // 正要从浮动层落回平铺列（--float off）：此刻还没有列宽，
                // 不记的话 --dry-run 会漏报一个真会发生的改动，而且这一条会被当成空操作退 7
                changes.append(ControlChange("\(base).width", from: "浮动（无列宽）", to: Self.number(width)))
            }
        }
        let ratioNow = controller.controlSplitRatio(of: hit.pane, workspace: hit.workspace)
        if let ratio {
            if let ratioNow {
                if abs(ratioNow - ratio) >= 0.0005 {
                    changes.append(ControlChange("\(base).ratio", from: Self.number(ratioNow), to: Self.number(ratio)))
                }
            } else if floatingNow, !controller.model.layouts[hit.workspace].paneList.isEmpty {
                // 正要落回平铺层，而树里已经有别的 pane：插进去之后一定有父 split
                changes.append(ControlChange("\(base).ratio", from: "浮动（无父 split）", to: Self.number(ratio)))
            } else {
                throw ControlErrorBody(.badRequest, "\(handleName(hit.pane)) 没有父 split（树里只有它一个），--ratio 无从设起")
            }
        }

        let mutation = ControlMutationRequest(
            command: ctx.spec.name, request: ctx.request, peer: ctx.peer, changes: changes,
            controllers: [controller], undoName: "控制面：\(ctx.spec.cli)", target: base)
        var payload = try commit(mutation) {
            // **层先定下来**：float 决定 pane 在哪一层，zoom / width / ratio 都是层内属性。
            // 反过来写的话 `--float off --zoom on` 会先在浮动层写一个孤儿 zoom，
            // 再被回塞路径（insertingColumnRight / tree.inserting，两条都清 zoom）抹掉
            if let float, float != floatingNow { controller.toggleFloat(hit.pane) }
            if let zoom { controller.controlSetZoom(hit.pane, workspace: hit.workspace, on: zoom) }
            if let width { controller.controlSetColumnWidth(hit.pane, workspace: hit.workspace, to: width) }
            if let ratio { controller.controlSetSplitRatio(hit.pane, workspace: hit.workspace, to: ratio) }
        }
        payload.pane = paneInfo(hit, encoder: ctx.encoder)
        payload.workspace = ctx.encoder.workspaceInfo(controller, index: hit.workspace)
        return (hit.echo, payload)
    }

    // MARK: resize（= 鼠标能做的那几件事；到边界就是空操作）

    /// **与鼠标同权**。鼠标一共三条调尺寸的路子，命令行每条都要能表达：
    /// ① 拖一条分隔条 → `--ratio`（或 `--points`）+ 可选的 `--split <path>` 指名哪一条；
    /// ② ⌘右键拖 pane / `resize-*` 快捷键（就近同向父 split，按点数） → `--dir` + `--points`；
    /// ③ scrolling 拖列宽 → `--width`（因子）或 `--points`（点数）。
    /// 夹取规则也一并对齐：①走 `SplitViewMetrics.ratio`（两侧各留 10pt，正是拖拽手势那条），
    /// ②走 `SplitTree.resizing`（0.1–0.9，正是快捷键那条），③走 `ScrollingStrip.widthRange`
    private func paneResize(_ ctx: ControlContext) throws -> (ResolvedTarget?, any Encodable) {
        let hit = try requirePane(ctx, ctx.target)
        let controller = hit.controller
        let base = path(controller, hit.workspace, hit.pane)
        let workspacePath = path(controller, hit.workspace)
        let dwindle = controller.model.layouts[hit.workspace].name == "dwindle"
        let widthRaw = ctx.string("width")
        let ratioRaw = ctx.string("ratio")
        let pointsRaw = ctx.string("points")
        let dirRaw = ctx.string("dir")
        let splitPath = ctx.string("split")

        let given = [widthRaw, ratioRaw, pointsRaw].compactMap { $0 }
        guard given.count <= 1 else {
            throw ControlErrorBody(.badRequest, "--width / --ratio / --points 一次只能给一个",
                                   hint: "点数用 --points，比例用 --ratio，列宽因子用 --width")
        }
        guard !given.isEmpty || dirRaw != nil else {
            throw ControlErrorBody(
                .badRequest,
                "pane resize 需要 --width / --ratio / --points（可以是 +0.05 这样的增量），或者 --dir",
                hint: "quickterm pane resize -t t7 --dir right 就等于按一次 ⌘⌃→")
        }
        if splitPath != nil, !dwindle {
            throw ControlErrorBody(.badRequest, "--split 只对 dwindle 工作区有意义（当前是 scrolling）",
                                   hint: "scrolling 调的是列宽：--width / --points")
        }

        var changes: [ControlChange] = []
        var apply: () -> Void = {}

        if let dirRaw {
            // ② 快捷键 / ⌘右键拖拽那条：方向决定符号，点数是位移量
            guard widthRaw == nil, ratioRaw == nil else {
                throw ControlErrorBody(.badRequest, "--dir 是按点数调的那一条，配 --points 用",
                                       hint: "要直接设比例就别给 --dir：--ratio 0.62 [--split a]")
            }
            // `--dir` 调的是**就近的同向**分隔条（哪一条由方向和树形决定），
            // 指名道姓的 `--split` 在这条路上无处安放。悄悄丢掉它就成了"agent 以为
            // 调了根那条、实际调了别的一条"——这正是控制面最不能犯的那种错
            guard splitPath == nil else {
                throw ControlErrorBody(
                    .badRequest, "--dir 走的是就近同向分隔条那条路，不能同时用 --split 指名哪一条",
                    hint: "指名就别给 --dir：--split root --points +100，或 --split a.b --ratio 0.62")
            }
            guard let direction = Self.direction(dirRaw) else {
                throw ControlErrorBody(.badRequest, "--dir 只接受 left / right / up / down",
                                       candidates: ["left", "right", "up", "down"])
            }
            let points = try Self.magnitude(pointsRaw ?? "100", flag: "--points")
            (changes, apply) = try previewDirectionalResize(
                hit: hit, direction: direction, points: points, base: base,
                workspacePath: workspacePath)
        } else if dwindle {
            // ① 拖一条分隔条：默认是自己的父 split，--split 指名祖先那条
            (changes, apply) = try previewSplitResize(
                hit: hit, splitPath: splitPath, ratioRaw: ratioRaw, pointsRaw: pointsRaw,
                widthRaw: widthRaw, workspacePath: workspacePath)
        } else {
            // ③ 列宽：因子或点数
            (changes, apply) = try previewColumnResize(
                hit: hit, widthRaw: widthRaw, pointsRaw: pointsRaw, ratioRaw: ratioRaw, base: base)
        }

        let mutation = ControlMutationRequest(
            command: ctx.spec.name, request: ctx.request, peer: ctx.peer, changes: changes,
            controllers: [controller], undoName: "控制面：\(ctx.spec.cli)", target: base)
        var payload = try commit(mutation) { apply() }
        payload.pane = paneInfo(hit, encoder: ctx.encoder)
        payload.workspace = ctx.encoder.workspaceInfo(controller, index: hit.workspace)
        return (hit.echo, payload)
    }

    /// ② `--dir`：**不自己算比例**，把同一次调用交给鼠标 / 快捷键用的那两个函数，
    /// 先在一份副本上跑一遍拿 diff（`--dry-run` 因此一个字节都不改）
    private func previewDirectionalResize(
        hit: PaneHit, direction: ScrollingStrip.Direction, points: Double,
        base: String, workspacePath: String) throws -> ([ControlChange], () -> Void) {
        let controller = hit.controller
        switch controller.model.layouts[hit.workspace] {
        case .dwindle(let tree):
            guard let node = tree.root?.node(view: hit.pane),
                  let size = ControlGeometry.contentSize(controller) else {
                throw ControlErrorBody(.failed, "这个工作区现在算不出几何（窗口还没挂上）",
                                       hint: "稍后重试，或改用 --ratio")
            }
            let bounds = CGRect(origin: .zero, size: size)
            guard let next = try? tree.resizing(node: node, by: UInt16(min(max(points, 1), 30000)),
                                                in: direction.spatial, with: bounds) else {
                throw ControlErrorBody(
                    .badRequest,
                    "\(handleName(hit.pane)) 往 \(Self.name(direction)) 这边没有可调的分隔条",
                    hint: "换一个方向，或用 --split 指名一条")
            }
            return (Self.splitChanges(before: tree, after: next, workspacePath: workspacePath),
                    { controller.controlResizeSplit(hit.pane, workspace: hit.workspace,
                                                    points: points, direction: direction.spatial) })
        case .scrolling(let strip):
            guard direction == .left || direction == .right else {
                throw ControlErrorBody(.badRequest,
                                       "scrolling 的列宽只有左右可调（↑/↓ 与快捷键一样没有效果）",
                                       hint: "要调列内高度请换 dwindle 布局")
            }
            let delta = (direction == .left ? -points : points)
            return previewColumnDelta(hit: hit, strip: strip, deltaPoints: delta, base: base)
        }
    }

    /// ① dwindle：设某一条分隔条的比例（`--ratio`）或位置（`--points`）
    private func previewSplitResize(
        hit: PaneHit, splitPath: String?, ratioRaw: String?, pointsRaw: String?,
        widthRaw: String?, workspacePath: String) throws -> ([ControlChange], () -> Void) {
        let controller = hit.controller
        if widthRaw != nil {
            throw ControlErrorBody(.badRequest, "--width 只对 scrolling 工作区有意义",
                                   hint: "dwindle 用 --ratio / --points")
        }
        // 根那条分隔条的路径是空串，而空串在命令行上传不过来（`--split ""` = 没给）：
        // 给它一个名字 `root`
        let wanted = splitPath.map { $0 == "root" ? "" : $0 }
            ?? controller.controlParentSplitPath(of: hit.pane, workspace: hit.workspace)
        guard let wanted else {
            throw ControlErrorBody(.badRequest,
                                   "\(handleName(hit.pane)) 没有父 split（树里只有它一个），没有分隔条可调")
        }
        guard let slot = controller.controlSplitSlot(workspace: hit.workspace, path: wanted) else {
            let available = Self.splitPaths(of: controller, workspace: hit.workspace)
            throw ControlErrorBody(.notFound, "这个工作区里没有 \(Self.quoted(wanted)) 这条分裂",
                                   hint: "`a` = 左 / 上，`b` = 右 / 下，点号连接；根那条写 `root`",
                                   candidates: available.map(Self.quoted))
        }
        // 这条分裂在分隔方向上的长度（pt）：点数与比例之间就是除以它。
        // 窗口没挂上（SwiftUI 重建期 / 无头）时量不出来，那就只剩比例这一条路
        let span = ControlGeometry.contentSize(controller)
            .flatMap { controller.controlSplitSlot(workspace: hit.workspace, path: wanted, size: $0) }
            .map { Double(ControlGeometry.span(of: $0)) }
        let now = slot.ratio
        var target: Double
        if let ratioRaw {
            target = try Self.applyDelta(ratioRaw, to: now, flag: "--ratio")
        } else if let pointsRaw {
            guard let span, span > 0 else {
                throw ControlErrorBody(.failed, "窗口还没挂上，点数换算不了",
                                       hint: "改用 --ratio，或稍后重试")
            }
            let text = pointsRaw.trimmingCharacters(in: .whitespaces)
            let value = try Self.number(text, flag: "--points")
            // 带符号 = 把这条分隔条**挪** N 点（正 = 往右 / 往下），裸数字 = 把 a 那一侧设成 N 点
            target = (text.hasPrefix("+") || text.hasPrefix("-")) ? now + value / span : value / span
        } else {
            throw ControlErrorBody(.badRequest, "dwindle 的 resize 要给 --ratio 或 --points")
        }
        // 夹取：**和拖拽手势同一个函数**（两侧各留 10pt）；量不出长度时退回 0.1–0.9
        let clamped: Double
        if let span, span > 2 * Double(SplitViewMetrics.minSize) {
            clamped = Double(SplitViewMetrics.ratio(dividerAt: CGFloat(target * span), in: CGFloat(span)))
        } else {
            clamped = min(max(target, 0.1), 0.9)
        }
        let rounded = ControlGeometry.rounded(CGFloat(clamped))
        var changes: [ControlChange] = []
        if abs(rounded - now) >= 0.0005 {
            changes.append(ControlChange(Self.splitChangePath(workspacePath, wanted),
                                         from: Self.number(now), to: Self.number(rounded)))
        }
        return (changes, {
            controller.controlSetSplitRatio(workspace: hit.workspace, path: wanted, to: rounded)
        })
    }

    /// ③ scrolling：列宽（因子或点数）
    private func previewColumnResize(
        hit: PaneHit, widthRaw: String?, pointsRaw: String?, ratioRaw: String?,
        base: String) throws -> ([ControlChange], () -> Void) {
        let controller = hit.controller
        if ratioRaw != nil {
            throw ControlErrorBody(.badRequest, "--ratio 只对 dwindle 工作区有意义",
                                   hint: "scrolling 用 --width / --points")
        }
        guard let now = controller.controlColumnWidth(of: hit.pane, workspace: hit.workspace) else {
            throw ControlErrorBody(.badRequest,
                                   "\(handleName(hit.pane)) 不在任何一列里（浮动 pane 没有列宽）")
        }
        let viewport = ControlGeometry.contentSize(controller)?.width
        var target: Double
        if let widthRaw {
            target = try Self.applyDelta(widthRaw, to: now, flag: "--width")
        } else if let pointsRaw {
            guard let viewport, viewport > 0 else {
                throw ControlErrorBody(.failed, "窗口还没挂上，点数换算不了", hint: "改用 --width")
            }
            let text = pointsRaw.trimmingCharacters(in: .whitespaces)
            let value = try Self.number(text, flag: "--points")
            target = (text.hasPrefix("+") || text.hasPrefix("-"))
                ? now + value / Double(viewport) : value / Double(viewport)
        } else {
            throw ControlErrorBody(.badRequest, "scrolling 的 resize 要给 --width 或 --points")
        }
        let clamped = min(max(target, ScrollingStrip.widthRange.lowerBound),
                          ScrollingStrip.widthRange.upperBound)
        let rounded = ControlGeometry.rounded(CGFloat(clamped))
        var changes: [ControlChange] = []
        if abs(rounded - now) >= 0.0005 {
            changes.append(ControlChange("\(base).width", from: Self.number(now), to: Self.number(rounded)))
        }
        return (changes, {
            controller.controlSetColumnWidth(hit.pane, workspace: hit.workspace, to: rounded)
        })
    }

    /// `--dir left|right --points N` 落到 scrolling 上：与 ⌘右键横向拖拽同一个函数
    private func previewColumnDelta(hit: PaneHit, strip: ScrollingStrip, deltaPoints: Double,
                                    base: String) -> ([ControlChange], () -> Void) {
        let controller = hit.controller
        // 换算与夹取全由 `ScrollingStrip.resizingWidth` 做（⌘右键拖拽调的是同一个）：
        // 这里只是先在副本上跑一遍拿 diff
        // 与 `controlResizeColumn` 同底：条带铺开的那块地，不是窗口内容区
        let viewport = Double(ControlGeometry.contentSize(controller)?.width ?? 1000)
        let now = controller.controlColumnWidth(of: hit.pane, workspace: hit.workspace) ?? 0
        let after = strip.resizingWidth(of: hit.pane, delta: deltaPoints / max(viewport, 1))
        let next = after.position(of: hit.pane).map { after.columns[$0.col].widthFactor } ?? now
        var changes: [ControlChange] = []
        if abs(next - now) >= 0.0005 {
            changes.append(ControlChange("\(base).width", from: Self.number(now), to: Self.number(next)))
        }
        return (changes, {
            controller.controlResizeColumn(hit.pane, workspace: hit.workspace,
                                           deltaPoints: CGFloat(deltaPoints))
        })
    }

    // MARK: resize 的零件

    /// 两棵树逐条分裂比比例（结构不变，前序一一对应）
    static func splitChanges(before: SplitTree<PaneView>, after: SplitTree<PaneView>,
                             workspacePath: String) -> [ControlChange] {
        let old = ControlGeometry.splits(in: before, size: ControlGeometry.unit)
        let new = ControlGeometry.splits(in: after, size: ControlGeometry.unit)
        guard old.count == new.count else { return [] }
        var out: [ControlChange] = []
        for (a, b) in zip(old, new) where abs(a.ratio - b.ratio) >= 0.0005 {
            out.append(ControlChange(splitChangePath(workspacePath, a.path),
                                     from: number(a.ratio), to: number(b.ratio)))
        }
        return out
    }

    /// diff 里的写法与 `state` 的 JSON 同形：`1:2.tree.a.b.ratio`
    static func splitChangePath(_ workspacePath: String, _ path: String) -> String {
        path.isEmpty ? "\(workspacePath).tree.ratio" : "\(workspacePath).tree.\(path).ratio"
    }

    static func splitPaths(of controller: MainWindowController, workspace: Int) -> [String] {
        guard case .dwindle(let tree) = controller.model.layouts[workspace] else { return [] }
        return ControlGeometry.splits(in: tree, size: ControlGeometry.unit).map(\.path)
    }

    /// 根那条分隔条在命令行上叫 `root`（它的路径是空串，打不出来）
    static func quoted(_ path: String) -> String { path.isEmpty ? "root" : path }

    static func direction(_ raw: String) -> ScrollingStrip.Direction? {
        switch raw {
        case "left": .left
        case "right": .right
        case "up": .up
        case "down": .down
        default: nil
        }
    }

    static func name(_ direction: ScrollingStrip.Direction) -> String {
        switch direction {
        case .left: "左"
        case .right: "右"
        case .up: "上"
        case .down: "下"
        }
    }

    /// 只认正数（方向由 `--dir` 决定，再带一个符号只会互相打架）
    static func magnitude(_ raw: String, flag: String) throws -> Double {
        let value = try number(raw, flag: flag)
        guard value > 0 else {
            throw ControlErrorBody(.badRequest, "\(flag) 要是一个正数（方向由 --dir 决定），收到 \(raw)")
        }
        return value
    }

    static func number(_ raw: String, flag: String) throws -> Double {
        guard let value = Double(raw.trimmingCharacters(in: .whitespaces)) else {
            throw ControlErrorBody(.badRequest, "\(flag) 不是一个数字：\(raw)")
        }
        return value
    }

    /// `+0.05` / `-0.05`（增量）或 `0.33`（绝对）。**带符号才是增量**——
    /// 让裸数字也当增量的话，`--width 0.5` 会把列宽越加越大，而调用方以为自己在设值
    static func applyDelta(_ raw: String, to current: Double, flag: String) throws -> Double {
        let text = raw.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("+") || text.hasPrefix("-") {
            guard let delta = Double(text) else {
                throw ControlErrorBody(.badRequest, "\(flag) 不是一个数字：\(raw)")
            }
            return current + delta
        }
        guard let absolute = Double(text) else {
            throw ControlErrorBody(.badRequest, "\(flag) 不是一个数字：\(raw)")
        }
        return absolute
    }

    static func number(_ value: Double) -> String { String(format: "%.3f", value) }
}
