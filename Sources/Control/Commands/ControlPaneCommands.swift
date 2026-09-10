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
        if let ratio, !(0.1...0.9).contains(ratio) {
            throw ControlErrorBody(.badRequest, "--ratio 必须在 0.1–0.9 之间，收到 \(ratio)")
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

    // MARK: resize（相对；到边界就是空操作）

    private func paneResize(_ ctx: ControlContext) throws -> (ResolvedTarget?, any Encodable) {
        let hit = try requirePane(ctx, ctx.target)
        let controller = hit.controller
        let base = path(controller, hit.workspace, hit.pane)
        var changes: [ControlChange] = []
        var newWidth: Double?
        var newRatio: Double?

        if let raw = ctx.string("width") {
            guard let widthNow = controller.controlColumnWidth(of: hit.pane, workspace: hit.workspace) else {
                throw ControlErrorBody(.badRequest, "--width 只对 scrolling 工作区有意义", hint: "dwindle 用 --ratio")
            }
            let wanted = try Self.applyDelta(raw, to: widthNow, flag: "--width")
            let clamped = min(max(wanted, ScrollingStrip.widthRange.lowerBound),
                              ScrollingStrip.widthRange.upperBound)
            if abs(clamped - widthNow) >= 0.0005 {
                newWidth = clamped
                changes.append(ControlChange("\(base).width", from: Self.number(widthNow), to: Self.number(clamped)))
            }
        }
        if let raw = ctx.string("ratio") {
            guard let ratioNow = controller.controlSplitRatio(of: hit.pane, workspace: hit.workspace) else {
                throw ControlErrorBody(.badRequest, "--ratio 只对 dwindle 工作区里有父 split 的 pane 有意义")
            }
            let wanted = try Self.applyDelta(raw, to: ratioNow, flag: "--ratio")
            let clamped = min(max(wanted, 0.1), 0.9)
            if abs(clamped - ratioNow) >= 0.0005 {
                newRatio = clamped
                changes.append(ControlChange("\(base).ratio", from: Self.number(ratioNow), to: Self.number(clamped)))
            }
        }
        guard ctx.string("width") != nil || ctx.string("ratio") != nil else {
            throw ControlErrorBody(.badRequest, "pane resize 需要 --width 或 --ratio（可以是 +0.05 这样的增量）")
        }

        let mutation = ControlMutationRequest(
            command: ctx.spec.name, request: ctx.request, peer: ctx.peer, changes: changes,
            controllers: [controller], undoName: "控制面：\(ctx.spec.cli)", target: base)
        var payload = try commit(mutation) {
            if let newWidth { controller.controlSetColumnWidth(hit.pane, workspace: hit.workspace, to: newWidth) }
            if let newRatio { controller.controlSetSplitRatio(hit.pane, workspace: hit.workspace, to: newRatio) }
        }
        payload.pane = paneInfo(hit, encoder: ctx.encoder)
        payload.workspace = ctx.encoder.workspaceInfo(controller, index: hit.workspace)
        return (hit.echo, payload)
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
