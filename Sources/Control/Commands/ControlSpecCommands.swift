import AppKit

/// `spec dump|validate|apply` —— 一次性组合。
///
/// 这是整套控制面里 agent 最该用的一条路：**一次调用摆好整个工作区**，
/// 而不是发 N 条 `pane new` 再逐条调宽度（N 条命令 = N 次重排、N 次动画、N 个失败点，
/// 而且中途失败会留下一个谁也说不清的半成品）。
@MainActor
extension ControlCommandRunner {
    func runSpec(_ ctx: ControlContext) throws -> (echo: ResolvedTarget?, data: any Encodable) {
        switch ctx.spec.verb {
        case "dump": return try specDump(ctx)
        case "validate": return try specValidate(ctx)
        case "apply": return try specApply(ctx)
        default: throw ControlErrorBody(.unknownCommand, "spec 没有 \(ctx.spec.verb) 这个动词")
        }
    }

    // MARK: dump

    private func specDump(_ ctx: ControlContext) throws -> (ResolvedTarget?, any Encodable) {
        let scope = try requireScope(ctx, ctx.target)
        let options = SpecCodec.DumpOptions(relocatable: ctx.flag("relocatable"),
                                            includeIDs: ctx.flag("include-ids"),
                                            exposesBrowser: ctx.encoder.exposesBrowser)
        let document: SpecDocument
        if ctx.flag("all") {
            document = .session(SpecCodec.session(screens, options: options))
        } else if let target = ctx.target, target.screen != nil,
                  target.workspace == nil, target.pane == nil {
            // `-t 1` = 整块屏幕；`-t 1:2` / 不写 = 一个工作区。作用域跟着目标的写法走，
            // 不再另发明一个 --scope 开关
            document = .screen(SpecCodec.screen(scope.controller, options: options))
        } else {
            document = .workspace(SpecCodec.workspace(scope.controller, index: scope.workspace,
                                                      options: options))
        }
        let payload = ControlSpecDumpPayload(
            scope: document.kind.rawValue,
            schema: Self.schema(of: document),
            panes: document.paneCount,
            spec: try document.json())
        return (ResolvedTarget(screen: scope.controller.screenIndex + 1,
                               screenID: scope.controller.windowID.uuidString,
                               workspace: document.kind == .workspace ? scope.workspace + 1 : nil,
                               pane: nil, paneID: nil), payload)
    }

    static func schema(of document: SpecDocument) -> String {
        switch document.kind {
        case .workspace: SpecSchema.workspace
        case .screen: SpecSchema.screen
        case .session: SpecSchema.session
        }
    }

    // MARK: validate

    private func specValidate(_ ctx: ControlContext) throws -> (ResolvedTarget?, any Encodable) {
        let document = try Self.parseSpecArgument(ctx)
        let scope = try requireScope(ctx, ctx.target)
        var notes: [String] = []
        // 作用域相关的检查（纯格式检查在 `SpecParser`，它不知道这台机器上有几个工作区 / 几块屏幕）
        switch document {
        case .workspace:
            break
        case .screen(let screen):
            try Self.checkWorkspaceIndices(screen, controller: scope.controller)
            if screen.frame != nil || screen.display != nil {
                notes.append("display / frame 只在 dump 里回显：spec apply 不搬窗口（用 quickterm screen move）")
            }
        case .session(let session):
            for (controller, screen) in try Self.screenPlan(session, screens: screens) {
                try Self.checkWorkspaceIndices(screen, controller: controller)
            }
        }
        if Self.mentionsCommands(document) {
            notes.append("cmd / env / hold 只进不出：spec dump 回吐不了一个正在跑的命令。"
                         + "--reuse 会把对得上的 pane 原地留着（不重跑），"
                         + "--replace 则是拆了重建（那条命令会重新跑起来）")
        }
        let payload = ControlSpecValidatePayload(
            valid: true, scope: document.kind.rawValue, schema: Self.schema(of: document),
            panes: document.paneCount, notes: notes)
        return (nil, payload)
    }

    /// `workspaces[]` 落不落得下去（工作区个数是配置驱动的，1–10）
    static func checkWorkspaceIndices(_ screen: ScreenSpec, controller: MainWindowController) throws {
        let count = controller.model.layouts.count
        if let active = screen.activeWorkspace, active < 1 || active > count {
            throw ControlErrorBody(
                .badRequest, "activeWorkspace \(active) 越界：屏幕 \(controller.screenIndex + 1) 有 \(count) 个工作区（1–\(count)）",
                hint: "quickterm workspace count N 可以改（1–10）")
        }
        var seen = Set<Int>()
        for (i, workspace) in (screen.workspaces ?? []).enumerated() {
            let index = workspace.index ?? (i + 1)
            guard index >= 1, index <= count else {
                throw ControlErrorBody(
                    .badRequest,
                    "workspaces[\(i)] 落到工作区 \(index)，而屏幕 \(controller.screenIndex + 1) 只有 \(count) 个（1–\(count)）",
                    hint: "quickterm workspace count N 可以改（1–10）")
            }
            // 同一个工作区在一份 spec 里只能出现一次。两份都落下去的话，后一份的
            // `model.layouts[i] = …` 会把前一份**按赋值**盖掉：前一份建出来的 pane
            // 既不在任何布局里、也没走过关闭路径（浏览器的 paneWillClose、文件管理器的会话清理
            // 一个都不跑），而报告还说它建成了
            guard seen.insert(index).inserted else {
                throw ControlErrorBody(
                    .badRequest,
                    "workspaces[\(i)] 又落到工作区 \(index)：同一个工作区在一份 spec 里只能写一次",
                    hint: "不写 index 就是按数组下标算的——显式 index 与位置默认值混着写最容易撞车")
            }
        }
    }

    /// `screens[]` 落到哪几块屏幕上。**个数、越界、重复**都在这里一次查完，
    /// 而且 `spec validate` / `spec apply` / 确认闸门读的是同一份计划
    static func screenPlan(_ session: SessionSpec, screens: ScreenRegistry) throws
        -> [(controller: MainWindowController, spec: ScreenSpec)] {
        let live = screens.controllers.filter { !$0.isClosed }
        let wanted = (session.screens ?? []).count
        guard wanted <= live.count else {
            throw ControlErrorBody(
                .badRequest, "这份会话写了 \(wanted) 块屏幕，现在只有 \(live.count) 块",
                hint: "先 quickterm screen new 把屏幕开够——spec apply 不会替你开窗口")
        }
        var out: [(controller: MainWindowController, spec: ScreenSpec)] = []
        var seen = Set<Int>()
        for (i, screen) in (session.screens ?? []).enumerated() {
            let index = (screen.index ?? (i + 1)) - 1
            guard live.indices.contains(index) else {
                throw ControlErrorBody(.badRequest,
                                       "screens[\(i)] 指向屏幕 \(index + 1)，现在只有 \(live.count) 块")
            }
            guard seen.insert(index).inserted else {
                throw ControlErrorBody(
                    .badRequest, "screens[\(i)] 又落到屏幕 \(index + 1)：同一块屏幕只能写一次",
                    hint: "不写 index 就是按数组下标算的")
            }
            out.append((live[index], screen))
        }
        if let key = session.keyScreen, !live.indices.contains(key - 1) {
            throw ControlErrorBody(.badRequest, "keyScreen \(key) 指向一块不存在的屏幕")
        }
        return out
    }

    /// 一份 spec 到底会动到哪些（屏幕，工作区）。**确认框与落刀读的是同一份**——
    /// 确认框里只说一个工作区、实际却清掉整块屏幕的话，用户批准的就不是发生的那件事
    static func specTargets(_ document: SpecDocument, controller: MainWindowController,
                            workspace: Int, screens: ScreenRegistry) throws
        -> [(controller: MainWindowController, workspace: Int)] {
        func workspaces(_ screen: ScreenSpec, on controller: MainWindowController) throws
            -> [(controller: MainWindowController, workspace: Int)] {
            try checkWorkspaceIndices(screen, controller: controller)
            return (screen.workspaces ?? []).enumerated().map { i, spec in
                (controller, (spec.index ?? (i + 1)) - 1)
            }
        }
        switch document {
        case .workspace:
            return [(controller, workspace)]
        case .screen(let screen):
            return try workspaces(screen, on: controller)
        case .session(let session):
            var out: [(controller: MainWindowController, workspace: Int)] = []
            for (target, screen) in try screenPlan(session, screens: screens) {
                out += try workspaces(screen, on: target)
            }
            return out
        }
    }

    static func mentionsCommands(_ document: SpecDocument) -> Bool {
        func any(_ workspace: WorkspaceSpec) -> Bool {
            (SpecApplier.tiledSlots(workspace) + SpecApplier.floatingSlots(workspace))
                .contains { $0.pane.cmd != nil || $0.pane.env != nil || $0.pane.hold != nil }
        }
        switch document {
        case .workspace(let w): return any(w)
        case .screen(let s): return (s.workspaces ?? []).contains(where: any)
        case .session(let s): return (s.screens ?? []).contains { screen in
            (screen.workspaces ?? []).contains(where: any) }
        }
    }

    // MARK: apply

    private func specApply(_ ctx: ControlContext) throws -> (ResolvedTarget?, any Encodable) {
        let document = try Self.parseSpecArgument(ctx)
        let mode = try Self.mode(ctx)
        let scope = try requireScope(ctx, ctx.target)

        // 1) 先把整份计划算出来（**一个 pane 都还没建、一个都还没关**）
        var appliers: [SpecApplier] = []
        var screenSettings: [(controller: MainWindowController, spec: ScreenSpec)] = []
        var controllers: [MainWindowController] = []
        var skipped: [String] = []

        func addScreen(_ spec: ScreenSpec, controller: MainWindowController) throws {
            try Self.checkWorkspaceIndices(spec, controller: controller)
            controller.flushPendingCloses()
            if !controllers.contains(where: { $0 === controller }) { controllers.append(controller) }
            screenSettings.append((controller, spec))
            if spec.frame != nil || spec.display != nil {
                skipped.append("屏幕 \(controller.screenIndex + 1) 的 display / frame（spec apply 不搬窗口）")
            }
            for (i, workspace) in (spec.workspaces ?? []).enumerated() {
                let index = (workspace.index ?? (i + 1)) - 1
                let applier = SpecApplier(controller: controller, workspace: index,
                                          spec: workspace, mode: mode,
                                          exposesBrowser: ctx.encoder.exposesBrowser)
                // 可见列数写在屏幕这一层（`SpecCodec.screen` 不在每个工作区里重复写一遍）：
                // 省掉 width 的列要按它折算，否则一份"屏幕说 4 列"的 spec 会落成旧因子的列宽
                applier.visibleColumnsHint = spec.visibleColumns
                appliers.append(applier)
            }
        }

        switch document {
        case .workspace(let workspace):
            controllers.append(scope.controller)
            appliers.append(SpecApplier(controller: scope.controller, workspace: scope.workspace,
                                        spec: workspace, mode: mode,
                                        exposesBrowser: ctx.encoder.exposesBrowser))
        case .screen(let screen):
            try addScreen(screen, controller: scope.controller)
        case .session(let session):
            for (controller, screen) in try Self.screenPlan(session, screens: screens) {
                try addScreen(screen, controller: controller)
            }
        }

        var changes: [ControlChange] = []
        for applier in appliers {
            try applier.preflight()
            // `--into-empty` 是默认模式：它**毁不掉任何东西**——非空一律拒绝，
            // 而不是"顺手清一下"。想覆盖就明说 --replace（那一条会先要求确认）
            if mode == .intoEmpty, !applier.existingPanes.isEmpty {
                throw ControlErrorBody(
                    .confirmationRequired,
                    "\(path(applier.controller, applier.workspace)) 里已经有 \(applier.existingPanes.count) 个 pane，"
                        + "--into-empty 不动非空工作区",
                    hint: "--replace 覆盖（会先确认，其中的进程会被结束）；--reuse 保留能对上的 pane")
            }
            changes += applier.changes(at: path(applier.controller, applier.workspace))
        }
        // 存在但用不上的工作目录（受保护目录 + 缺授权）：默认照铺，但**必须说出来**；
        // `--require-cwd` 的脚本要的是宁可失败也不要一个目录全落错的工作区，
        // 而这一步还在"一个 pane 都没建、一个都没关"的阶段
        let deniedDirectories = appliers.flatMap(\.deniedDirectories).reduce(into: [String]()) {
            if !$0.contains($1) { $0.append($1) }
        }
        if !deniedDirectories.isEmpty, ctx.flag("require-cwd") {
            throw ControlErrorBody(
                .denied,
                "这份 spec 里有 \(deniedDirectories.count) 个目录用不上（macOS 受保护目录，缺少「文件与文件夹」授权）："
                    + deniedDirectories.joined(separator: "、")
                    + "。--require-cwd 要求宁可失败也不落在别处，所以这次什么都没动",
                hint: "在系统设置 ▸ 隐私与安全性 ▸ 文件与文件夹里给 QuickTerm 授权并重启它；"
                    + "或者去掉 --require-cwd（照常铺，响应里带 cwd_denied 告警）")
        }
        for (controller, spec) in screenSettings {
            changes += Self.screenChanges(spec, controller: controller, path: path(controller))
        }
        if case .session(let session) = document, let key = session.keyScreen,
           screens.controlCurrent?.screenIndex != key - 1 {
            changes.append(ControlChange("session.keyScreen",
                                         from: screens.controlCurrent.map { String($0.screenIndex + 1) } ?? "—",
                                         to: String(key)))
        }

        // 确认闸门批准的是**这一批**工作区（屏幕 / 会话作用域下不止一个）：落刀前逐个再核一次。
        // 用户读确认框的那十秒里布局是会变的，而这一刀可能横跨整块屏幕
        try verifyPinnedScopes(ctx, targets: appliers.map { ($0.controller, $0.workspace) })

        var report = ControlSpecApplyReport(mode: mode.rawValue, scope: document.kind.rawValue,
                                            created: [], reused: [], closed: [],
                                            skipped: skipped.isEmpty ? nil : skipped)
        var createdPanes: [(pane: PaneView, controller: MainWindowController, workspace: Int)] = []
        var focus: (pane: PaneView, controller: MainWindowController, workspace: Int)?

        let mutation = ControlMutationRequest(
            command: ctx.spec.name, request: ctx.request, peer: ctx.peer, changes: changes,
            controllers: controllers, undoName: "控制面：\(ctx.spec.cli)",
            target: path(scope.controller, scope.workspace))

        var payload = try commit(mutation) {
            var done = 0
            for applier in appliers {
                do {
                    let outcome = try applier.apply()
                    report.created += outcome.created.map { handleName($0) }
                    report.reused += outcome.reused.map { handleName($0) }
                    report.closed += outcome.closed
                    createdPanes += outcome.created.map {
                        ($0, applier.controller, applier.workspace)
                    }
                    if let target = outcome.focus, focus == nil || applier.controller === scope.controller {
                        focus = (target, applier.controller, applier.workspace)
                    }
                    done += 1
                } catch {
                    // 前面已经落了几个工作区：这一条**必须**报成 partial，
                    // 让 agent 知道它手里的状态已经过期了
                    throw SpecApplier.body(error, partial: done > 0)
                }
            }
            for (controller, spec) in screenSettings {
                Self.applyScreenSettings(spec, controller: controller)
            }
            if case .session(let session) = document, let key = session.keyScreen {
                let live = screens.controllers.filter { !$0.isClosed }
                if live.indices.contains(key - 1), screens.controlCurrent !== live[key - 1] {
                    live[key - 1].window?.makeKeyAndOrderFront(nil)
                }
            }
        }
        payload.spec = payload.applied ? report : nil
        if !deniedDirectories.isEmpty {
            payload.warnings = deniedDirectories.map { .cwdDenied($0, used: nil) }
        }
        if payload.applied {
            payload.panes = createdPanes.map {
                paneInfo($0.pane, controller: $0.controller, workspace: $0.workspace, encoder: ctx.encoder)
            }
            payload.workspace = ctx.encoder.workspaceInfo(scope.controller, index: scope.workspace)
            if let focus, focus.controller.focusedPane !== focus.pane { payload.focusPending = true }
        }
        return (ResolvedTarget(screen: scope.controller.screenIndex + 1,
                               screenID: scope.controller.windowID.uuidString,
                               workspace: scope.workspace + 1,
                               pane: focus.map { handleName($0.pane) },
                               paneID: focus?.pane.id.uuidString), payload)
    }

    // MARK: 屏幕这一层

    static func screenChanges(_ spec: ScreenSpec, controller: MainWindowController,
                              path: String) -> [ControlChange] {
        var out: [ControlChange] = []
        if let columns = spec.visibleColumns, columns != controller.visibleColumns {
            out.append(ControlChange("\(path).visibleColumns",
                                     from: String(controller.visibleColumns), to: String(columns)))
        }
        if let fullscreen = spec.fullscreen, fullscreen != controller.isSimpleFullscreen {
            out.append(ControlChange("\(path).fullscreen",
                                     from: controller.isSimpleFullscreen ? "on" : "off",
                                     to: fullscreen ? "on" : "off"))
        }
        if let join = spec.joinAllSpaces, join != controller.joinsAllSpaces {
            out.append(ControlChange("\(path).joinAllSpaces",
                                     from: controller.joinsAllSpaces ? "on" : "off",
                                     to: join ? "on" : "off"))
        }
        if let active = spec.activeWorkspace, active - 1 != controller.model.activeIndex {
            out.append(ControlChange("\(path).activeWorkspace",
                                     from: String(controller.model.activeIndex + 1), to: String(active)))
        }
        return out
    }

    /// **在工作区落完之后**才动屏幕这一层：切工作区之前得先让目标工作区有东西
    static func applyScreenSettings(_ spec: ScreenSpec, controller: MainWindowController) {
        if let columns = spec.visibleColumns, columns != controller.visibleColumns {
            controller.setVisibleColumns(columns, persist: true)
        }
        if let join = spec.joinAllSpaces, join != controller.joinsAllSpaces {
            controller.joinsAllSpaces = join
        }
        if let fullscreen = spec.fullscreen, fullscreen != controller.isSimpleFullscreen {
            controller.toggleSimpleFullscreen()
        }
        if let active = spec.activeWorkspace, active - 1 != controller.model.activeIndex,
           controller.model.layouts.indices.contains(active - 1) {
            controller.switchWorkspace(active - 1)
        }
    }

    // MARK: 参数

    /// `-f <文件>` 的内容由 CLI 读好之后放在 `spec` 参数里（服务端绝不去读调用方的文件系统：
    /// 两个进程的 cwd 与权限本来就不一样，而"服务端替你 open 一个路径"是个能被滥用的原语）
    static func parseSpecArgument(_ ctx: ControlContext) throws -> SpecDocument {
        guard let text = ctx.string("spec"), !text.isEmpty else {
            throw ControlErrorBody(.badRequest, "没有拿到 spec 内容",
                                   hint: "quickterm spec \(ctx.spec.verb) -f <文件>，或从标准输入喂进来")
        }
        return try SpecParser.parse(text)
    }

    static func mode(_ ctx: ControlContext) throws -> SpecApplier.Mode {
        let flags = SpecApplier.Mode.allCases.filter { ctx.flag($0.rawValue) }
        guard flags.count <= 1 else {
            throw ControlErrorBody(.badRequest,
                                   "--into-empty / --replace / --reuse 只能选一个，收到 "
                                       + flags.map { "--\($0.rawValue)" }.joined(separator: " "),
                                   candidates: SpecApplier.Mode.allCases.map(\.rawValue))
        }
        return flags.first ?? .intoEmpty
    }
}
