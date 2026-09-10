import AppKit

/// 一条命令执行期间的全部上下文。存在的理由很实际：Phase 2 的 19 条命令都要用到
/// 同一组东西（参数、目标、解析器、编码器、对端身份、确认闸门钉住的那个主体），
/// 挨个当参数传会让每个函数签名都有七八个参数，改一处要动十九处。
@MainActor
struct ControlContext {
    let spec: ControlCommandSpec
    let request: ControlRequest
    let peer: ControlSocket.Peer
    let target: ControlTarget?
    let resolver: ControlResolver
    let encoder: ControlStateEncoder
    let pinned: ControlCommandRunner.PinnedSubject?

    // MARK: 取参数（**没写 = nil**，绝不替调用方脑补默认值——
    // "没写 --zoom"和"--zoom off"是两件完全不同的事）

    func string(_ name: String) -> String? {
        guard let raw = request.args[name]?.stringValue, !raw.isEmpty else { return nil }
        return raw
    }

    func strings(_ name: String) -> [String] {
        guard let value = request.args[name] else { return [] }
        if let list = value.arrayValue { return list.compactMap(\.stringValue) }
        return value.stringValue.map { [$0] } ?? []
    }

    func int(_ name: String) -> Int? { request.args[name]?.intValue }
    func double(_ name: String) -> Double? { request.args[name]?.doubleValue }
    func flag(_ name: String) -> Bool { request.args[name]?.boolValue ?? false }

    /// `on|off` 三态：nil = 没给这个开关
    func onOff(_ name: String) throws -> Bool? {
        guard let raw = string(name) else { return nil }
        switch raw.lowercased() {
        case "on", "true", "yes", "1": return true
        case "off", "false", "no", "0": return false
        default:
            throw ControlErrorBody(.badRequest, "--\(name) 只接受 on / off，收到 \(raw)",
                                   candidates: ["on", "off"])
        }
    }

    /// `--where` → 拖放区域。`nil` = 用应用自己的默认落点
    func zone(_ name: String = "where") throws -> TerminalSplitDropZone? {
        guard let raw = string(name) else { return nil }
        switch raw {
        case "right": return .right
        case "left": return .left
        case "up": return .top
        case "down": return .bottom
        case "stack": return .bottom   // 併入锚点所在的纵栈（scrolling 的"栈"就是列内往下加一层）
        default:
            throw ControlErrorBody(.badRequest, "--\(name) 只接受 right / left / up / down / stack",
                                   candidates: ["right", "left", "up", "down", "stack"])
        }
    }

    /// 参数里带的另一个目标（`--at` / `--with` / `--to`）
    func parseTarget(_ name: String) throws -> ControlTarget? {
        guard let raw = string(name) else { return nil }
        do {
            return try ControlTarget.parse(raw)
        } catch {
            throw ControlErrorBody(.badTarget, "--\(name) \(raw)：\(error)",
                                   hint: ControlTarget.grammarLines.joined(separator: " / "))
        }
    }
}

@MainActor
extension ControlCommandRunner {
    /// 落到一个具体 pane 上（不写 pane 段就取上下文里的焦点 pane）
    struct PaneHit {
        var controller: MainWindowController
        var workspace: Int
        var pane: PaneView
        var echo: ResolvedTarget
    }

    func requirePane(_ ctx: ControlContext, _ target: ControlTarget?) throws -> PaneHit {
        var effective = target ?? ControlTarget()
        if effective.pane == nil { effective.pane = .focused }
        let resolution = try ctx.resolver.resolve(effective)
        guard let pane = resolution.pane else {
            throw ControlErrorBody(.notFound, "没有可寻址的 pane",
                                   hint: "quickterm list panes 看现有句柄")
        }
        resolution.controller.flushPendingCloses()
        // flush 之后再核一次：淡出中的 pane 到点会被真正移除，落刀前它可能已经不在布局里了
        guard resolution.controller.model.allPanes.contains(where: { $0 === pane }) else {
            throw ControlErrorBody(.notFound, "目标 pane 已经不在布局里了（可能刚被关掉）",
                                   hint: "重新读一次 quickterm state")
        }
        return PaneHit(controller: resolution.controller, workspace: resolution.workspace,
                       pane: pane, echo: resolution.echo)
    }

    /// 落到一块屏幕 + 一个工作区（可以没有 pane）
    func requireScope(_ ctx: ControlContext, _ target: ControlTarget?) throws -> ControlResolver.Resolution {
        let resolution = try ctx.resolver.resolve(target)
        resolution.controller.flushPendingCloses()
        return resolution
    }

    func handleName(_ pane: PaneView) -> String { ControlHandleRegistry.shared.handle(for: pane) }

    /// diff 里的路径写法：与寻址语法同形（`1:2.t7`），
    /// 这样 agent 读到的 diff 与它下一条命令要敲的目标是同一套词汇
    func path(_ controller: MainWindowController, _ workspace: Int? = nil, _ pane: PaneView? = nil) -> String {
        var out = String(controller.screenIndex + 1)
        if let workspace { out += ":\(workspace + 1)" }
        if let pane { out += ".\(handleName(pane))" }
        return out
    }

    func paneInfo(_ hit: PaneHit, encoder: ControlStateEncoder) -> ControlStatePayload.PaneInfo {
        paneInfo(hit.pane, controller: hit.controller, workspace: hit.workspace, encoder: encoder)
    }

    func paneInfo(_ pane: PaneView, controller: MainWindowController, workspace: Int,
                  encoder: ControlStateEncoder) -> ControlStatePayload.PaneInfo {
        let positions = ControlStateEncoder.positions(in: controller.model.layouts[workspace])
        return encoder.paneInfo(pane, controller: controller, workspace: workspace,
                                at: positions[pane.id],
                                float: controller.controlIsFloating(pane, workspace: workspace),
                                zoomed: controller.controlIsZoomed(pane, workspace: workspace))
    }

    /// 确认闸门批准的是**这一个**主体：落刀前再核一次身份。
    /// 用户读确认框的十秒里，不需要确认的 mutate 命令完全可以把焦点 / 布局挪走
    func verifyPinned(_ ctx: ControlContext, controller: MainWindowController,
                      workspace: Int? = nil, pane: PaneView? = nil) throws {
        guard let pinned = ctx.pinned else { return }
        var drifted = pinned.controller !== controller
        if let workspace, pinned.workspace != workspace { drifted = true }
        if let pane {
            if pinned.pane !== pane { drifted = true }
            if controller.model.closingPanes.contains(pane.id) { drifted = true }
        }
        if let pinnedPaneIDs = pinned.paneIDs, let workspace, !drifted {
            let now = Set((controller.model.layouts[workspace].paneList
                           + controller.model.floatings[workspace].map(\.pane)).map(\.id))
            if now != pinnedPaneIDs { drifted = true }
        }
        guard !drifted else {
            throw ControlErrorBody(
                .busy, "确认期间目标变了（当时确认的是 \(pinned.description)）：本次什么都没做",
                hint: "重新发一次，或用 -t 精确指定", retryAfterMs: 200)
        }
    }

    /// `spec apply` 版的同一件事：确认框上写的是**一批**工作区（屏幕 / 会话作用域下不止一个），
    /// 落刀前逐个再核一次——这一批里任何一个漂了，整条命令都不落
    func verifyPinnedScopes(_ ctx: ControlContext,
                            targets: [(controller: MainWindowController, workspace: Int)]) throws {
        guard let pinned = ctx.pinned else { return }
        var drifted = pinned.scopes.count != targets.count
        for (scope, target) in zip(pinned.scopes, targets) where !drifted {
            guard scope.controller === target.controller, scope.workspace == target.workspace else {
                drifted = true
                break
            }
            let closing = target.controller.model.closingPanes
            let now = Set((target.controller.model.layouts[target.workspace].paneList
                           + target.controller.model.floatings[target.workspace].map(\.pane))
                .filter { !closing.contains($0.id) }.map(\.id))
            if now != scope.paneIDs { drifted = true }
        }
        guard !drifted else {
            throw ControlErrorBody(
                .busy, "确认期间目标变了（当时确认的是 \(pinned.description)）：本次什么都没做",
                hint: "重新发一次，或用 -t 精确指定", retryAfterMs: 200)
        }
    }
}
