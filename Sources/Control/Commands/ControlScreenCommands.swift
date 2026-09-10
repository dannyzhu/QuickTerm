import AppKit

/// `screen new|close|move|focus|set`。
///
/// 「屏幕」= 一个窗口 + 一组自己的工作区。这一组命令全部落在 `AppDelegate+Screens` 已有的
/// 入口上（`newScreen` / `moveScreen` / `closeScreen`）——那里管着注册表、存档与序号复用，
/// 绕过它自己建窗口的话，新窗口不会进注册表，也不会进存档。
@MainActor
extension ControlCommandRunner {
    func runScreen(_ ctx: ControlContext) throws -> (echo: ResolvedTarget?, data: any Encodable) {
        switch ctx.spec.verb {
        case "new": return try screenNew(ctx)
        case "close": return try screenClose(ctx)
        case "move": return try screenMove(ctx)
        case "focus": return try screenFocus(ctx)
        case "set": return try screenSet(ctx)
        default: throw ControlErrorBody(.unknownCommand, "screen 没有 \(ctx.spec.verb) 这个动词")
        }
    }

    /// `--display uuid:… / name:… / <1 起序号>`。**frame 不是身份**（`DisplayRef` 自己就这么写的），
    /// 所以只认 uuid / 名字 / 序号
    static func resolveDisplay(_ raw: String) throws -> NSScreen {
        let screens = NSScreen.screens
        func fail(_ why: String) -> ControlErrorBody {
            ControlErrorBody(.notFound, why,
                             hint: "现有显示器：" + screens.enumerated()
                                .map { "\($0.offset + 1)=\($0.element.localizedName)" }
                                .joined(separator: "、"),
                             candidates: screens.map(\.localizedName))
        }
        if raw.hasPrefix("uuid:") {
            let id = String(raw.dropFirst(5)).lowercased()
            guard let screen = screens.first(where: { $0.displayUUID?.uuidString.lowercased() == id }) else {
                throw fail("没有 uuid 为 \(id) 的显示器")
            }
            return screen
        }
        if raw.hasPrefix("name:") {
            let name = String(raw.dropFirst(5))
            let matches = screens.filter { $0.localizedName == name }
            if matches.count > 1 {
                throw ControlErrorBody(.ambiguousTarget, "\(matches.count) 台显示器都叫「\(name)」",
                                       hint: "改用 uuid: 或序号",
                                       candidates: matches.compactMap { $0.displayUUID?.uuidString })
            }
            guard let screen = matches.first else { throw fail("没有叫「\(name)」的显示器") }
            return screen
        }
        if let index = Int(raw), index >= 1, index <= screens.count { return screens[index - 1] }
        throw fail("解析不出显示器：\(raw)")
    }

    private func screenNew(_ ctx: ControlContext) throws -> (ResolvedTarget?, any Encodable) {
        guard let app = NSApp.delegate as? AppDelegate else {
            throw ControlErrorBody(.internalError, "没有 AppDelegate")
        }
        let display = try ctx.string("display").map { try Self.resolveDisplay($0) }
        var inherit: PaneView?
        if let from = try ctx.parseTarget("inherit-cwd-from") {
            inherit = try requirePane(ctx, from).pane
        }
        let before = screens.controllers.count
        var created: MainWindowController?
        let mutation = ControlMutationRequest(
            command: ctx.spec.name, request: ctx.request, peer: ctx.peer,
            changes: [ControlChange("screens", from: "\(before)", to: "\(before + 1)")],
            controllers: [],
            undoName: nil,   // 撤销一块屏幕 = 关掉它连同里面的进程：那不是撤销，是第二次破坏
            target: display?.localizedName)
        var payload = try commit(mutation) {
            let controller = app.newScreen(on: display, inheritingFrom: inherit)
            controller.ensureStarterPane(inheriting: inherit?.workingDirectory)
            controller.window?.makeKeyAndOrderFront(nil)
            created = controller
        }
        guard let controller = created else { return (nil, payload) }
        payload.screen = ctx.encoder.screenInfo(controller, isKey: true)
        return (ResolvedTarget(screen: controller.screenIndex + 1,
                               screenID: controller.windowID.uuidString,
                               workspace: controller.model.activeIndex + 1,
                               pane: controller.focusedPane.map { handleName($0) },
                               paneID: controller.focusedPane?.id.uuidString), payload)
    }

    private func screenClose(_ ctx: ControlContext) throws -> (ResolvedTarget?, any Encodable) {
        guard let app = NSApp.delegate as? AppDelegate else {
            throw ControlErrorBody(.internalError, "没有 AppDelegate")
        }
        let scope = try requireScope(ctx, ctx.target)
        let controller = scope.controller
        try verifyPinned(ctx, controller: controller)
        guard screens.controllers.count > 1 else {
            throw ControlErrorBody(
                .denied, "这是最后一块屏幕：关掉它等于退出 QuickTerm，控制面不做这件事",
                hint: "要退出请用 QuickTerm 菜单里的「退出」（那条路径会问用户）")
        }
        let panes = controller.model.allPanes.count
        let mutation = ControlMutationRequest(
            command: ctx.spec.name, request: ctx.request, peer: ctx.peer,
            changes: [ControlChange(path(controller), from: "open（\(panes) panes）", to: "closed")],
            controllers: [], undoName: nil,
            target: path(controller))
        var payload = try commit(mutation) {
            // 我们自己的确认闸门已经问过一次了：`closeScreen` 里那句 `confirmCloseScreen()`
            // 会**在控制命令的调用栈里**跑一个 NSAlert.runModal 嵌套 run loop——
            // 主线程被自己卡住，socket 也就停了。`--force` 与"已经确认过"都走 confirmed: true
            app.closeScreen(controller, confirmed: true)
        }
        payload.note = "屏幕已关闭；其中的 \(panes) 个 pane 与进程都结束了"
        return (nil, payload)
    }

    private func screenMove(_ ctx: ControlContext) throws -> (ResolvedTarget?, any Encodable) {
        guard let app = NSApp.delegate as? AppDelegate else {
            throw ControlErrorBody(.internalError, "没有 AppDelegate")
        }
        let scope = try requireScope(ctx, ctx.target)
        let controller = scope.controller
        guard let raw = ctx.string("display") else {
            throw ControlErrorBody(.badRequest, "screen move 需要 --display")
        }
        let display = try Self.resolveDisplay(raw)
        let now = controller.window?.screen
        let changes = now === display
            ? []
            : [ControlChange("\(path(controller)).display",
                             from: now?.localizedName ?? "—", to: display.localizedName)]
        let mutation = ControlMutationRequest(
            command: ctx.spec.name, request: ctx.request, peer: ctx.peer, changes: changes,
            controllers: [controller], undoName: nil,   // 窗口几何不进撤销栈（快照里没有它）
            target: path(controller))
        var payload = try commit(mutation) { app.moveScreen(controller, to: display) }
        payload.screen = ctx.encoder.screenInfo(controller, isKey: controller === screens.controlCurrent)
        return (ResolvedTarget(screen: controller.screenIndex + 1,
                               screenID: controller.windowID.uuidString,
                               workspace: controller.model.activeIndex + 1,
                               pane: nil, paneID: nil), payload)
    }

    private func screenFocus(_ ctx: ControlContext) throws -> (ResolvedTarget?, any Encodable) {
        let scope = try requireScope(ctx, ctx.target)
        let controller = scope.controller
        let now = screens.controlCurrent
        let changes = now === controller
            ? []
            : [ControlChange("key screen", from: now.map { String($0.screenIndex + 1) } ?? "—",
                             to: String(controller.screenIndex + 1))]
        let mutation = ControlMutationRequest(
            command: ctx.spec.name, request: ctx.request, peer: ctx.peer, changes: changes,
            controllers: [controller], undoName: nil, target: path(controller))
        var payload = try commit(mutation) {
            controller.window?.makeKeyAndOrderFront(nil)
            if let focused = controller.focusedPane { controller.requestFocus(to: focused) }
        }
        payload.screen = ctx.encoder.screenInfo(controller, isKey: true)
        return (ResolvedTarget(screen: controller.screenIndex + 1,
                               screenID: controller.windowID.uuidString,
                               workspace: controller.model.activeIndex + 1,
                               pane: controller.focusedPane.map { handleName($0) },
                               paneID: controller.focusedPane?.id.uuidString), payload)
    }

    private func screenSet(_ ctx: ControlContext) throws -> (ResolvedTarget?, any Encodable) {
        let scope = try requireScope(ctx, ctx.target)
        let controller = scope.controller
        let fullscreen = try ctx.onOff("fullscreen")
        let joinAll = try ctx.onOff("join-all-spaces")
        let columns = ctx.int("visible-columns")
        guard fullscreen != nil || joinAll != nil || columns != nil else {
            throw ControlErrorBody(.badRequest,
                                   "screen set 至少要给一个设值（--fullscreen / --join-all-spaces / --visible-columns）")
        }
        if let columns, !(1...6).contains(columns) {
            throw ControlErrorBody(.badRequest, "--visible-columns 只能是 1–6，收到 \(columns)")
        }
        let base = path(controller)
        var changes: [ControlChange] = []
        if let fullscreen, fullscreen != controller.isSimpleFullscreen {
            changes.append(ControlChange("\(base).fullscreen",
                                         from: controller.isSimpleFullscreen ? "on" : "off",
                                         to: fullscreen ? "on" : "off"))
        }
        if let joinAll, joinAll != controller.joinsAllSpaces {
            changes.append(ControlChange("\(base).joinAllSpaces",
                                         from: controller.joinsAllSpaces ? "on" : "off",
                                         to: joinAll ? "on" : "off"))
        }
        if let columns, columns != controller.visibleColumns {
            changes.append(ControlChange("\(base).visibleColumns",
                                         from: String(controller.visibleColumns), to: String(columns)))
        }
        let mutation = ControlMutationRequest(
            command: ctx.spec.name, request: ctx.request, peer: ctx.peer, changes: changes,
            controllers: [controller], undoName: "控制面：\(ctx.spec.cli)", target: base)
        var payload = try commit(mutation) {
            // 全部都是"设成这个值"：toggleSimpleFullscreen 是 toggle，所以先比对再决定翻不翻
            if let fullscreen, fullscreen != controller.isSimpleFullscreen {
                controller.toggleSimpleFullscreen()
            }
            if let joinAll { controller.joinsAllSpaces = joinAll }
            if let columns { controller.setVisibleColumns(columns) }
        }
        payload.screen = ctx.encoder.screenInfo(controller, isKey: controller === screens.controlCurrent)
        return (ResolvedTarget(screen: controller.screenIndex + 1,
                               screenID: controller.windowID.uuidString,
                               workspace: controller.model.activeIndex + 1,
                               pane: nil, paneID: nil), payload)
    }
}
