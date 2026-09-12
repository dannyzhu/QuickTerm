import AppKit

/// `workspace goto|set|set-layout|equalize|clear|count`。
///
/// `set-layout` 是整套"绝对设值"规则的招牌例子：应用里只有 `toggle-layout`，
/// 而且它**只作用于活动工作区**——想把 4 号工作区设成 dwindle，快捷键做不到，
/// agent 更做不到（它得先切过去、读一遍状态、决定要不要翻、再切回来，中间任何一步失败都会留下烂摊子）。
@MainActor
extension ControlCommandRunner {
    func runWorkspace(_ ctx: ControlContext) throws -> (echo: ResolvedTarget?, data: any Encodable) {
        switch ctx.spec.verb {
        case "goto": return try workspaceGoto(ctx)
        case "set": return try workspaceSet(ctx)
        case "set-layout": return try workspaceSetLayout(ctx)
        case "equalize": return try workspaceEqualize(ctx)
        case "clear": return try workspaceClear(ctx)
        case "count": return try workspaceCount(ctx)
        default: throw ControlErrorBody(.unknownCommand, "workspace 没有 \(ctx.spec.verb) 这个动词")
        }
    }

    private func workspaceGoto(_ ctx: ControlContext) throws -> (ResolvedTarget?, any Encodable) {
        let scope = try requireScope(ctx, ctx.target)
        let controller = scope.controller
        guard let wanted = ctx.int("index") else {
            throw ControlErrorBody(.badRequest, "workspace goto 需要一个工作区序号（1 起）")
        }
        let count = controller.model.layouts.count
        guard wanted >= 1, wanted <= count else {
            throw ControlErrorBody(
                .notFound, "工作区 \(wanted) 不存在：屏幕 \(controller.screenIndex + 1) 当前有 \(count) 个（1–\(count)）",
                hint: "quickterm workspace count \(wanted) 可以加到那么多（1–10）")
        }
        let index = wanted - 1
        let now = controller.model.activeIndex
        let changes = now == index ? [] : [ControlChange(path(controller),
                                                         from: "workspace \(now + 1)",
                                                         to: "workspace \(index + 1)")]
        let mutation = ControlMutationRequest(
            command: ctx.spec.name, request: ctx.request, peer: ctx.peer, changes: changes,
            controllers: [controller], undoName: "控制面：\(ctx.spec.cli)",
            target: path(controller, index))
        var payload = try commit(mutation) { controller.switchWorkspace(index) }
        payload.workspace = ctx.encoder.workspaceInfo(controller, index: index)
        payload.screen = ctx.encoder.screenInfo(controller, isKey: controller === screens.controlCurrent)
        return (ResolvedTarget(screen: controller.screenIndex + 1,
                               screenID: controller.windowID.uuidString,
                               workspace: index + 1, pane: nil, paneID: nil), payload)
    }

    /// `workspace set --title`：给**槽位**起名。与 `pane set --title` 一条一条对齐——
    /// 空串是有意义的值（清掉名字）、200 字上限、控制字符一律拒绝、变更按敏感处理。
    /// 名字**不描述内容**：`workspace clear` 与 `spec apply --replace` 都不碰它，
    /// 所以这条命令是（连同右键改名）唯一改得动它的入口
    private func workspaceSet(_ ctx: ControlContext) throws -> (ResolvedTarget?, any Encodable) {
        let scope = try requireScope(ctx, ctx.target)
        let controller = scope.controller
        let index = scope.workspace
        // 空串 ≠ 没写（`ctx.string` 把空串当没写），与 pane set --title 同一条
        guard let title = ctx.rawString("title") else {
            throw ControlErrorBody(.badRequest, "workspace set 至少要给一个设值（--title）",
                                   hint: "quickterm workspace set --help")
        }
        guard title.count <= ControlCommandRunner.maxTitleLength else {
            throw ControlErrorBody(
                .badRequest,
                "--title 太长了（\(title.count) 个字符，上限 \(ControlCommandRunner.maxTitleLength)）")
        }
        guard title.unicodeScalars.allSatisfy(WorkspaceModel.isTitleScalar) else {
            throw ControlErrorBody(.badRequest, "--title 里有控制字符",
                                   hint: "名字会原样画进状态条的工作区胶囊与 state 的 title 字段")
        }
        let wanted = WorkspaceModel.normalizedTitle(title)
        let now = controller.model.title(at: index)
        // 值本身是用户写的字，按敏感处理：与 pane 标题同一条规矩，不进 OSLog
        let changes = now == wanted ? [] : [ControlChange("\(path(controller, index)).title",
                                                          from: now ?? "（没起过名）",
                                                          to: wanted ?? "（清掉）", sensitive: true)]
        let mutation = ControlMutationRequest(
            command: ctx.spec.name, request: ctx.request, peer: ctx.peer, changes: changes,
            controllers: [controller], undoName: "控制面：\(ctx.spec.cli)",
            target: path(controller, index))
        var payload = try commit(mutation) { controller.model.setTitle(wanted, at: index) }
        payload.workspace = ctx.encoder.workspaceInfo(controller, index: index)
        return (ResolvedTarget(screen: controller.screenIndex + 1,
                               screenID: controller.windowID.uuidString,
                               workspace: index + 1, pane: nil, paneID: nil), payload)
    }

    private func workspaceSetLayout(_ ctx: ControlContext) throws -> (ResolvedTarget?, any Encodable) {
        let scope = try requireScope(ctx, ctx.target)
        let controller = scope.controller
        guard let wanted = ctx.string("layout"), ["scrolling", "dwindle"].contains(wanted) else {
            throw ControlErrorBody(.badRequest, "workspace set-layout 只接受 scrolling / dwindle",
                                   candidates: ["scrolling", "dwindle"])
        }
        let index = scope.workspace
        let now = controller.model.layouts[index].name
        let before = controller.model.layouts[index].paneList.map(\.id)
        let changes = now == wanted ? [] : [ControlChange("\(path(controller, index)).layout",
                                                          from: now, to: wanted)]
        let mutation = ControlMutationRequest(
            command: ctx.spec.name, request: ctx.request, peer: ctx.peer, changes: changes,
            controllers: [controller], undoName: "控制面：\(ctx.spec.cli)",
            target: path(controller, index))
        var payload = try commit(mutation) {
            // 非活动工作区一样能设：这正是 toggle-layout 做不到的那件事
            let previous = controller.model.layouts[index]
            guard controller.model.setLayout(wanted, at: index, columnFactor: controller.columnFactor) else {
                throw ControlErrorBody(.failed, "布局转换没能给出 \(wanted)")
            }
            // 转换必须保 pane 保序（有损的是列宽 / 叠栈结构，不是 pane 本身）
            let after = controller.model.layouts[index].paneList.map(\.id)
            if Set(after) != Set(before) {
                // 已经动过手了：整份放回去（布局是值类型），保住"抛出 = 什么都没变"这条不变量——
                // 否则丢了的那个 pane 既不在布局里、也没跑过任何收尾，就是泄漏一个终端
                controller.model.layouts[index] = previous
                throw ControlErrorBody(.internalError, "布局转换丢了 pane（\(before.count) → \(after.count)）")
            }
            if index == controller.model.activeIndex, let focused = controller.focusedPane {
                controller.requestFocus(to: focused)
            }
        }
        payload.workspace = ctx.encoder.workspaceInfo(controller, index: index)
        return (ResolvedTarget(screen: controller.screenIndex + 1,
                               screenID: controller.windowID.uuidString,
                               workspace: index + 1, pane: nil, paneID: nil), payload)
    }

    private func workspaceEqualize(_ ctx: ControlContext) throws -> (ResolvedTarget?, any Encodable) {
        let scope = try requireScope(ctx, ctx.target)
        let controller = scope.controller
        let index = scope.workspace
        let before = controller.controlGeometry(workspace: index)
        // 先在一份**副本**上算等分之后长什么样：真等分之前就得知道它是不是空操作
        let after = Self.equalizedGeometry(controller: controller, workspace: index)
        let changes = MainWindowController.geometryMatches(before, after)
            ? []
            : [ControlChange("\(path(controller, index)).geometry",
                             from: Self.describe(before), to: Self.describe(after))]
        let mutation = ControlMutationRequest(
            command: ctx.spec.name, request: ctx.request, peer: ctx.peer, changes: changes,
            controllers: [controller], undoName: "控制面：\(ctx.spec.cli)",
            target: path(controller, index))
        var payload = try commit(mutation) { controller.controlEqualize(workspace: index) }
        payload.workspace = ctx.encoder.workspaceInfo(controller, index: index)
        return (ResolvedTarget(screen: controller.screenIndex + 1,
                               screenID: controller.windowID.uuidString,
                               workspace: index + 1, pane: nil, paneID: nil), payload)
    }

    /// 等分之后的几何——**纯计算**，不碰模型（`--dry-run` 靠它做到"一个字节都不改"）
    private static func equalizedGeometry(controller: MainWindowController, workspace: Int) -> [Double] {
        switch controller.model.layouts[workspace] {
        case .scrolling(let strip):
            return Array(repeating: controller.columnFactor, count: strip.columns.count)
        case .dwindle(let tree):
            let equalized = tree.equalized()
            var out: [Double] = []
            func walk(_ node: SplitTree<PaneView>.Node?) {
                guard let node else { return }
                if case .split(let s) = node {
                    out.append(s.ratio)
                    walk(s.left)
                    walk(s.right)
                }
            }
            walk(equalized.root)
            return out
        }
    }

    private static func describe(_ geometry: [Double]) -> String {
        geometry.isEmpty ? "—" : geometry.map { String(format: "%.3f", $0) }.joined(separator: " ")
    }

    private func workspaceClear(_ ctx: ControlContext) throws -> (ResolvedTarget?, any Encodable) {
        let scope = try requireScope(ctx, ctx.target)
        let controller = scope.controller
        let index = scope.workspace
        try verifyPinned(ctx, controller: controller, workspace: index)
        let victims = controller.model.layouts[index].paneList
            + controller.model.floatings[index].map(\.pane)
        let infos = victims.map { paneInfo($0, controller: controller, workspace: index, encoder: ctx.encoder) }
        let changes = victims.isEmpty ? [] : [ControlChange(path(controller, index),
                                                            from: "\(victims.count) panes", to: "0 panes")]
        let mutation = ControlMutationRequest(
            command: ctx.spec.name, request: ctx.request, peer: ctx.peer, changes: changes,
            controllers: [controller],
            undoName: nil,   // 进程已经被结束了：撤销只会造出一个"好像还在"的假象
            target: path(controller, index))
        var payload = try commit(mutation) {
            // **不逐 pane 弹 QuickTerm 自己那句「仍有进程在运行」**：`closePane` 的那句确认是
            // `DispatchQueue.main.async` 出去的，逐个问的结果是这一趟一个 pane 都没关
            // （payload 却会报 applied），而 N 个 `NSAlert.runModal` 会在命令返回之后
            // 接连开嵌套 run loop 把主线程连同 socket 一起顶住。
            // 控制面自己的确认闸门已经把这一整组 pane 按句柄列出来问过一次、落刀前 verifyPinned
            // 又核过一遍身份——与 `screen close` 同一条路：确认过了就一次落干净
            _ = controller.controlClearWorkspace(index, confirmIfNeeded: false)
        }
        if payload.applied {
            // 按事实回报：真的关掉了哪些（非活动工作区走 removeFromAnyWorkspace，同样是同步的）
            let remaining = Set((controller.model.layouts[index].paneList
                                 + controller.model.floatings[index].map(\.pane)).map(\.id))
            let closed = zip(victims, infos).filter { !remaining.contains($0.0.id) }.map(\.1)
            payload.panes = closed.isEmpty ? nil : closed
        } else {
            payload.panes = infos    // dry-run：这就是"会关掉哪些"的预览
        }
        payload.workspace = ctx.encoder.workspaceInfo(controller, index: index)
        return (ResolvedTarget(screen: controller.screenIndex + 1,
                               screenID: controller.windowID.uuidString,
                               workspace: index + 1, pane: nil, paneID: nil), payload)
    }

    /// `workspace count N`：**改写 config.toml，然后交给已有的配置监听去落地**。
    /// 自己再 `setWorkspaceCount` 一次的话，监听 0.2s 后还会再落一次——
    /// 中间那一段里键位表被重建两遍，而工作区数是键位表的输入（`goto-workspace-N`）。
    /// 一次写盘、一条生效路径，永远只有一个真相。
    private func workspaceCount(_ ctx: ControlContext) throws -> (ResolvedTarget?, any Encodable) {
        guard let wanted = ctx.int("n") else {
            throw ControlErrorBody(.badRequest, "workspace count 需要一个数字（1–10）")
        }
        guard (1...10).contains(wanted) else {
            throw ControlErrorBody(.badRequest, "工作区数只能是 1–10，收到 \(wanted)",
                                   hint: "这是 WorkspaceModel.setWorkspaceCount 的硬上限（⌘1..0 就十个键）")
        }
        guard let session = (NSApp.delegate as? AppDelegate)?.session else {
            throw ControlErrorBody(.internalError, "没有会话")
        }
        let now = session.settings.workspaces
        // 缩容保护：配置层本来就"不裁掉非空工作区"，但那是**静默**保留——
        // agent 会以为自己设成了 3，读回来却是 6，而且没有任何解释
        if wanted < now {
            let highest = screens.controllers.compactMap { controller -> Int? in
                (0..<controller.model.layouts.count).last { !controller.model.isEmpty($0) }.map { $0 + 1 }
            }.max() ?? 0
            if wanted < highest {
                throw ControlErrorBody(
                    .denied, "不能缩到 \(wanted)：第 \(highest) 号工作区里还有 pane",
                    hint: "先 quickterm workspace clear -t :\(highest)（会结束其中的进程）")
            }
        }
        let changes = now == wanted ? [] : [ControlChange("config.workspaces",
                                                          from: String(now), to: String(wanted))]
        let mutation = ControlMutationRequest(
            command: ctx.spec.name, request: ctx.request, peer: ctx.peer, changes: changes,
            controllers: screens.controllers,
            undoName: nil,   // 撤销要连着改回配置文件——那是用户的文件，⌘Z 不该去动它
            target: ConfigStore.activeConfigURL.lastPathComponent)
        var payload = try commit(mutation) {
            do {
                try ConfigStore.rewrite(key: "workspaces", value: String(wanted))
            } catch {
                throw ControlErrorBody(.failed, "改写 config.toml 失败：\(error)")
            }
        }
        if payload.applied {
            payload.note = "已写入 \(ConfigStore.activeConfigURL.path) 的 workspaces = \(wanted)；"
                + "由配置监听热重载落地（约 0.2s 后 quickterm state 才会显示新的个数）"
        }
        return (nil, payload)
    }
}
