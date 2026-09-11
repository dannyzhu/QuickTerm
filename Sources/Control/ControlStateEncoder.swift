import AppKit

/// 把活着的注册表编码成 `quickterm.state/1`。
/// **全部经 JSONEncoder**（`ControlStatePayload` 是 Codable）——绝不手拼 JSON：
/// yabai 曾在一个版本里给 `query --windows` 拼出一个尾逗号，打断了所有下游 jq 管道。
@MainActor
struct ControlStateEncoder {
    let screens: ScreenRegistry
    /// 请求带了有效的来源 token（决定浏览器 pane 的 URL / 标题是否打码）
    let trusted: Bool
    /// `[control] expose-browser`：token | always | never
    let exposeBrowser: String
    let mode: String

    static let redacted = "<redacted>"

    var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
    }

    /// 浏览器 pane 的网址 / 标题是否可见。
    /// 一条规则，正面回答"浏览器 pane 里装着用户已登录的会话"：
    /// 没有 token 的调用方读不到——`quickterm state` 本身就是一个外泄面
    var exposesBrowser: Bool {
        switch exposeBrowser {
        case "always": true
        case "never": false
        default: trusted
        }
    }

    func payload(scope: MainWindowController? = nil) -> ControlStatePayload {
        let controllers = scope.map { [$0] } ?? screens.controllers
        // **不能用 `screens.key`**：那是 `NSApp.keyWindow`，应用不在前台时是 nil，
        // 于是每块屏幕都 `key: false`，而每块屏幕又各报一个 `focused: true` 的 pane——
        // describe 里"全局唯一的那个在 key: true 的屏幕上"这条消歧规则直接无解。
        // 而 agent 从 Terminal.app / 后台任务驱动时应用**正好**就不在前台，
        // 本地测的时候（QuickTerm 总在最前）永远复现不出来。
        // 用与目标解析同一条阶梯（controlCurrent），保证恒有且只有一块 key
        let keyController = screens.controlCurrent
        return ControlStatePayload(
            app: .init(version: appVersion,
                       protocolVersion: ControlProtocol.version,
                       workspaceCount: screens.primary?.model.layouts.count ?? 0,
                       mode: mode,
                       trusted: trusted),
            screens: controllers.map { screenInfo($0, isKey: $0 === keyController) },
            panes: controllers.flatMap { paneInfos(of: $0) })
    }

    func screenInfo(_ controller: MainWindowController, isKey: Bool) -> ControlStatePayload.ScreenInfo {
        let model = controller.model
        let display = DisplayRef(screen: controller.window?.screen)
        let frame = controller.savedFrame ?? controller.window?.frame
        return .init(
            index: controller.screenIndex + 1,
            id: controller.windowID.uuidString,
            title: controller.window?.title ?? ScreenRegistry.title(forIndex: controller.screenIndex),
            key: isKey,
            activeWorkspace: model.activeIndex + 1,
            visibleColumns: controller.visibleColumns,
            fullscreen: controller.isSimpleFullscreen,
            joinAllSpaces: controller.joinsAllSpaces,
            display: display.map { .init(uuid: $0.uuid, name: $0.name) },
            frame: frame.map { [$0.origin.x, $0.origin.y, $0.size.width, $0.size.height] },
            workspaces: model.layouts.indices.map { workspaceInfo(controller, index: $0) })
    }

    /// 去掉正在淡出的那几片叶子之后的布局。
    /// **树 / 列 / 几何三处共用这一份**：早先只有树塌了、矩形还按没塌的树算，
    /// 于是关 pane 的那 0.28 秒里 `state` 会一边说"t1 就是整个工作区"、
    /// 一边给 t1 一个半宽的矩形和一条树里根本不存在的分隔条。控制面别处
    /// （寻址、事件快照）早就当淡出中的 pane 已经不在了，这里跟上同一条规矩
    static func pruned(_ layout: WorkspaceLayout, closing: Set<UUID>) -> WorkspaceLayout {
        guard !closing.isEmpty else { return layout }
        switch layout {
        case .dwindle(let tree):
            var next = tree
            for pane in tree.root?.leaves() ?? [] where closing.contains(pane.id) {
                guard let node = next.root?.node(view: pane) else { continue }
                next = next.removing(node)
            }
            return .dwindle(next)
        case .scrolling(let strip):
            guard strip.paneList.contains(where: { closing.contains($0.id) }) else { return layout }
            var next = strip
            // 空列保留：列还在屏幕上（列宽也还在），少的只是那一片淡出中的 pane
            for index in next.columns.indices {
                next.columns[index].panes.removeAll { closing.contains($0.id) }
            }
            return .scrolling(next)
        }
    }

    /// 这个工作区里被 zoom 的那个 pane（zoom 的那一刻，其余平铺 pane 一片都不渲染）
    static func zoomedPaneID(in layout: WorkspaceLayout) -> UUID? {
        switch layout {
        case .scrolling(let strip):
            return strip.zoomedPane?.id
        case .dwindle(let tree):
            guard let zoomed = tree.zoomed, case .leaf(let view) = zoomed else { return nil }
            return view.id
        }
    }

    func workspaceInfo(_ controller: MainWindowController, index: Int) -> ControlStatePayload.WorkspaceInfo {
        let model = controller.model
        let closing = model.closingPanes
        // 一份形状：树、列、以及每个 pane 的矩形全部从这一份算
        let layout = Self.pruned(model.layouts[index], closing: closing)
        let handles = layout.paneList.map { ControlHandleRegistry.shared.handle(for: $0) }
        let floating = model.floatings[index].map(\.pane).filter { !closing.contains($0.id) }
            .map { ControlHandleRegistry.shared.handle(for: $0) }

        var columns: [ControlStatePayload.ColumnInfo]?
        var tree: ControlStatePayload.TreeNode?
        var zoom: String?
        switch layout {
        case .scrolling(let strip):
            columns = strip.columns.map { column in
                .init(width: column.widthFactor,
                      panes: column.panes.map { ControlHandleRegistry.shared.handle(for: $0) })
            }
        case .dwindle(let splitTree):
            tree = Self.treeNode(splitTree.root, closing: [])
        }
        if let id = Self.zoomedPaneID(in: layout),
           let pane = layout.paneList.first(where: { $0.id == id }) {
            zoom = ControlHandleRegistry.shared.handle(for: pane)
        }

        return .init(
            index: index + 1,
            layout: layout.name,
            empty: handles.isEmpty && floating.isEmpty,
            active: index == model.activeIndex,
            panes: handles,
            zoom: zoom,
            columns: columns,
            tree: tree,
            floating: floating)
    }

    /// dwindle 骨架：`{split,ratio,a,b}`，叶子 `{pane:"t1"}`——
    /// **与 `spec dump` 逐字同一套词**（那边的叶子装的是整份 pane 记录，这边只装句柄）。
    /// 淡出中的那一片叶子当作已经不在，树塌成另一侧（与 `SpecCodec.node` / `SplitTree.removing` 同规则）
    static func treeNode(_ node: SplitTree<PaneView>.Node?,
                         closing: Set<UUID>) -> ControlStatePayload.TreeNode? {
        guard let node else { return nil }
        switch node {
        case .leaf(let view):
            guard !closing.contains(view.id) else { return nil }
            return .leaf(ControlHandleRegistry.shared.handle(for: view))
        case .split(let split):
            let a = treeNode(split.left, closing: closing)
            let b = treeNode(split.right, closing: closing)
            guard let a else { return b }
            guard let b else { return a }
            let direction = split.direction == .horizontal ? "horizontal" : "vertical"
            return .split(.init(split: direction, ratio: ControlGeometry.rounded(split.ratio),
                                a: a, b: b))
        }
    }

    /// dwindle 树里的位置：左 = `a`、右 = `b`，点号连接（根是空串）
    static func pathString(_ path: SplitTree<PaneView>.Path) -> String {
        path.path.map { component in
            switch component {
            case .left: "a"
            case .right: "b"
            }
        }.joined(separator: ".")
    }

    /// 一个 pane 的几何（见 `PaneSize`）。**全部由模型算出来**，不读 frame。
    /// 尺寸读不出来（pane 已经不在这个工作区里）时返回 nil——宁可没有这一段，
    /// 也不能给出一个"上一帧的"数字
    static func paneSize(_ pane: PaneView, controller: MainWindowController,
                         workspace: Int, float: Bool) -> ControlStatePayload.PaneInfo.PaneSize? {
        guard controller.model.layouts.indices.contains(workspace) else { return nil }
        let content = ControlGeometry.contentSize(controller)
        // 与 `workspaceInfo` 的树 / 列同一份形状（淡出中的叶子已经塌掉）
        let layout = pruned(controller.model.layouts[workspace], closing: controller.model.closingPanes)
        let zoomedID = zoomedPaneID(in: layout)
        var size = ControlStatePayload.PaneInfo.PaneSize(rect: [])

        if float {
            guard let item = controller.model.floatings[workspace].first(where: { $0.pane === pane })
            else { return nil }
            size.rect = ControlGeometry.rect(item.rect)
        } else {
            guard let normalized = ControlGeometry.paneRects(in: layout, size: ControlGeometry.unit)[pane.id]
            else { return nil }
            size.rect = ControlGeometry.rect(normalized)
            switch layout {
            case .dwindle(let tree):
                // 最近父 split = 自己的路径去掉最后一节；根上的孤叶没有父 split
                if let root = tree.root, let node = root.node(view: pane),
                   let path = root.path(to: node), !path.path.isEmpty {
                    let parent = pathString(SplitTree<PaneView>.Path(path: Array(path.path.dropLast())))
                    if let slot = ControlGeometry.splits(in: tree, size: ControlGeometry.unit)
                        .first(where: { $0.path == parent }) {
                        size.split = slot.direction
                        size.ratio = ControlGeometry.rounded(slot.ratio)
                    }
                }
            case .scrolling(let strip):
                if let (column, _) = strip.position(of: pane) {
                    // **名义列宽因子**（模型持有的那个数，= `pane set --width` 写的那个），
                    // 而不是填充模式下放大过的有效宽度：后者在 rect 里
                    size.width = ControlGeometry.rounded(strip.columns[column].widthFactor)
                    size.share = ControlGeometry.rounded(1.0 / Double(max(strip.columns[column].panes.count, 1)))
                }
            }
        }

        // zoom：被放大的那一片独占整块内容区，**其余平铺 pane 一片都不渲染**。
        // rect / ratio / width 照旧报底下那层平铺（`pane resize` 调的正是它，
        // 取消 zoom 也回到它），但"当前在屏幕上有多大"这件事必须说实话：
        // 看不见的那几片不给 points，改打一个 hidden 标记——
        // `get -t <某个兄弟>` 拿不到工作区上下文，没有这个标记就只能被一个 0×0 的
        // pane 的点尺寸骗过去
        let hidden = !float && zoomedID != nil && pane.id != zoomedID
        if hidden { size.hidden = true }
        if let content, !hidden {
            if zoomedID == pane.id {
                size.points = [ControlGeometry.rounded(content.width, 1),
                               ControlGeometry.rounded(content.height, 1)]
            } else {
                size.points = [ControlGeometry.rounded(size.rect[2] * content.width, 1),
                               ControlGeometry.rounded(size.rect[3] * content.height, 1)]
            }
        }
        if let surface = (pane as? Ghostty.SurfaceView)?.surfaceSize {
            size.cols = Int(surface.columns)
            size.rows = Int(surface.rows)
        }
        return size
    }

    func paneInfos(of controller: MainWindowController) -> [ControlStatePayload.PaneInfo] {
        let model = controller.model
        var out: [ControlStatePayload.PaneInfo] = []
        for index in model.layouts.indices {
            let workspaceInfo = self.workspaceInfo(controller, index: index)
            let positions = Self.positions(in: model.layouts[index], closing: model.closingPanes)
            for pane in model.layouts[index].paneList where !model.closingPanes.contains(pane.id) {
                out.append(paneInfo(pane, controller: controller, workspace: index,
                                    at: positions[pane.id], float: false,
                                    zoomed: workspaceInfo.zoom == ControlHandleRegistry.shared.handle(for: pane)))
            }
            for floating in model.floatings[index] where !model.closingPanes.contains(floating.pane.id) {
                out.append(paneInfo(floating.pane, controller: controller, workspace: index,
                                    at: nil, float: true, zoomed: false))
            }
        }
        return out
    }

    /// 每个 pane 在布局里的位置（`at`）。`closing` 传进来就先把淡出中的叶子塌掉——
    /// `at.path` 必须与 `tree` 报的那棵树同形，否则 agent 照着 `at.path` 去
    /// `pane resize --split` 会指到另一条分隔条上
    static func positions(in layout: WorkspaceLayout,
                          closing: Set<UUID> = []) -> [UUID: ControlStatePayload.PaneInfo.Position] {
        var out: [UUID: ControlStatePayload.PaneInfo.Position] = [:]
        switch pruned(layout, closing: closing) {
        case .scrolling(let strip):
            for (c, column) in strip.columns.enumerated() {
                for (r, pane) in column.panes.enumerated() {
                    out[pane.id] = .init(column: c, row: r, path: nil)
                }
            }
        case .dwindle(let tree):
            for pane in tree.root?.leaves() ?? [] {
                guard let node = tree.root?.node(view: pane),
                      let path = tree.root?.path(to: node) else { continue }
                out[pane.id] = .init(column: nil, row: nil, path: pathString(path))
            }
        }
        return out
    }

    func paneInfo(_ pane: PaneView, controller: MainWindowController, workspace: Int,
                  at position: ControlStatePayload.PaneInfo.Position?,
                  float: Bool, zoomed: Bool) -> ControlStatePayload.PaneInfo {
        let browser = pane as? BrowserPaneView
        let hide = browser != nil && !exposesBrowser
        return .init(
            handle: ControlHandleRegistry.shared.handle(for: pane),
            id: pane.id.uuidString,
            kind: pane.kind.rawValue,
            role: controller.controlRole(of: pane),
            screen: controller.screenIndex + 1,
            workspace: workspace + 1,
            at: position,
            size: Self.paneSize(pane, controller: controller, workspace: workspace, float: float),
            title: hide ? Self.redacted : pane.paneTitle,
            cwd: pane.workingDirectory,
            url: browser.map { hide ? Self.redacted : ($0.currentURL?.absoluteString ?? "") },
            tabs: browser?.tabs.count,
            focused: controller.focusedPane === pane && controller.model.activeIndex == workspace,
            busy: pane.wantsConfirmClose,
            float: float,
            zoom: zoomed,
            redacted: hide ? true : nil)
    }
}
