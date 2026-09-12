import AppKit

/// **投影对**：活着的模型 ↔ 公开 schema `quickterm.workspace/1`。
///
/// 这是公开格式与内部存档 v5 之间唯一的接缝。两边各自演进：
/// v5 换了信封、加了字段，这里改一行投影即可，用户 dotfiles 里的 workspace 文件一个字都不用动；
/// 反过来公开 schema 加一个字段（比如将来的 `cmd` 回读），存档格式也不用跟着升版本。
///
/// **只读**：本文件一个字都不写模型（落地在 `SpecApplier`）。
@MainActor
enum SpecCodec {
    struct DumpOptions {
        /// 路径尽量写成 `~/…`（换一台机器也能用）
        var relocatable = false
        /// 附上 id / handle / title：给 diff 与 `--reuse` 用，**不参与不动点比较**
        var includeIDs = false
        /// 调用方能不能看到浏览器 pane 的 URL / 标题（与 `state` 同一条规则）
        var exposesBrowser = true

        init(relocatable: Bool = false, includeIDs: Bool = false, exposesBrowser: Bool = true) {
            self.relocatable = relocatable
            self.includeIDs = includeIDs
            self.exposesBrowser = exposesBrowser
        }
    }

    // MARK: dump（活模型 → spec）

    static func workspace(_ controller: MainWindowController, index: Int,
                          options: DumpOptions, nested: Bool = false) -> WorkspaceSpec {
        let model = controller.model
        let closing = model.closingPanes
        func live(_ panes: [PaneView]) -> [PaneView] { panes.filter { !closing.contains($0.id) } }

        var spec = WorkspaceSpec()
        spec.schema = nested ? nil : SpecSchema.workspace
        spec.index = nested ? index + 1 : nil
        spec.layout = model.layouts[index].name
        // 起过名才写这一项：没写 = apply 时不动目标工作区的名字
        spec.title = model.title(at: index)
        spec.visibleColumns = controller.visibleColumns

        let focused = index == model.activeIndex ? controller.focusedPane : nil

        switch model.layouts[index] {
        case .scrolling(let strip):
            var columns: [ColumnSpec] = []
            for column in strip.columns {
                let panes = live(column.panes)
                guard !panes.isEmpty else { continue }
                columns.append(ColumnSpec(width: rounded(column.widthFactor),
                                          panes: panes.map { pane($0, controller: controller, options: options) }))
            }
            spec.columns = columns
            if let zoomed = strip.zoomedPane, !closing.contains(zoomed.id) {
                spec.zoom = position(of: zoomed, in: model.layouts[index], closing: closing)
            }
            if let focused, model.layouts[index].paneList.contains(where: { $0 === focused }) {
                spec.focus = position(of: focused, in: model.layouts[index], closing: closing)
            }
        case .dwindle(let tree):
            spec.tree = node(tree.root, controller: controller, options: options, closing: closing)
            if let zoomed = tree.zoomed, case .leaf(let view) = zoomed, !closing.contains(view.id) {
                spec.zoom = position(of: view, in: model.layouts[index], closing: closing)
            }
            if let focused, model.layouts[index].paneList.contains(where: { $0 === focused }) {
                spec.focus = position(of: focused, in: model.layouts[index], closing: closing)
            }
        }

        let floating = live(model.floatings[index].map(\.pane))
        if !floating.isEmpty {
            spec.floating = model.floatings[index].filter { !closing.contains($0.pane.id) }.map {
                FloatingSpec(rect: [rounded($0.rect.origin.x), rounded($0.rect.origin.y),
                                    rounded($0.rect.size.width), rounded($0.rect.size.height)],
                             pane: pane($0.pane, controller: controller, options: options))
            }
            if let focused, let at = model.floatings[index].firstIndex(where: { $0.pane === focused }) {
                spec.focus = PaneRef(floating: at)
            }
        }
        return spec
    }

    static func screen(_ controller: MainWindowController, options: DumpOptions,
                       nested: Bool = false) -> ScreenSpec {
        var spec = ScreenSpec()
        spec.schema = nested ? nil : SpecSchema.screen
        spec.index = controller.screenIndex + 1
        if let display = DisplayRef(screen: controller.window?.screen) {
            spec.display = DisplaySpec(uuid: display.uuid, name: display.name)
        }
        if let frame = controller.savedFrame ?? controller.window?.frame {
            spec.frame = [rounded(frame.origin.x, 2), rounded(frame.origin.y, 2),
                          rounded(frame.size.width, 2), rounded(frame.size.height, 2)]
        }
        spec.fullscreen = controller.isSimpleFullscreen
        spec.joinAllSpaces = controller.joinsAllSpaces
        spec.visibleColumns = controller.visibleColumns
        spec.activeWorkspace = controller.model.activeIndex + 1
        spec.workspaces = controller.model.layouts.indices.map {
            var child = workspace(controller, index: $0, options: options, nested: true)
            child.visibleColumns = nil   // 屏幕这一层已经说过一次了，别在每个工作区里重复
            return child
        }
        return spec
    }

    static func session(_ screens: ScreenRegistry, options: DumpOptions) -> SessionSpec {
        var spec = SessionSpec()
        spec.schema = SpecSchema.session
        let controllers = screens.controllers.filter { !$0.isClosed }
        spec.screens = controllers.map { screen($0, options: options, nested: true) }
        spec.keyScreen = screens.controlCurrent.map { $0.screenIndex + 1 }
        return spec
    }

    // MARK: pane

    static func pane(_ view: PaneView, controller: MainWindowController,
                     options: DumpOptions) -> PaneSpec {
        var spec = PaneSpec()
        let role = controller.controlRole(of: view)
        spec.kind = role == "file-manager" ? "file-manager" : view.kind.rawValue
        if let cwd = view.workingDirectory, !cwd.isEmpty {
            spec.cwd = options.relocatable ? relocatable(cwd) : cwd
        }
        if let browser = view as? BrowserPaneView {
            if options.exposesBrowser {
                spec.url = browser.currentURL?.absoluteString
                // 还没导航过的标签（`effectiveURL` 是 nil）**整条丢掉**：写一个空串进去的话，
                // apply 那边 `url(forInput:)` 解不出东西，轻则少一个标签、重则整份 spec 被拒
                let tabs = browser.tabs.compactMap { $0.effectiveURL?.absoluteString }
                if tabs.count > 1 { spec.tabs = tabs }
            } else {
                // 与 `state` 同一条规则：没有 token 的调用方读不到浏览器 pane 的网址。
                // 这里**整字段省掉**而不是写 "<redacted>"——写进去的话这份 spec 再 apply 回来
                // 就会真的去打开一个叫 <redacted> 的网址
                spec.redacted = true
            }
        }
        if options.includeIDs {
            spec.id = view.id.uuidString
            spec.handle = ControlHandleRegistry.shared.handle(for: view)
            // 标题是易变的（跑一条命令就变）：只在 --include-ids 这个"给人看 / 给 diff 看"的模式里给，
            // 绝不进参与不动点比较的那一份
            spec.title = (view as? BrowserPaneView) != nil && !options.exposesBrowser
                ? ControlStateEncoder.redacted : view.paneTitle
        }
        return spec
    }

    private static func node(_ node: SplitTree<PaneView>.Node?, controller: MainWindowController,
                             options: DumpOptions, closing: Set<UUID>) -> NodeSpec? {
        guard let node else { return nil }
        switch node {
        case .leaf(let view):
            guard !closing.contains(view.id) else { return nil }
            return .leaf(pane(view, controller: controller, options: options))
        case .split(let split):
            let a = self.node(split.left, controller: controller, options: options, closing: closing)
            let b = self.node(split.right, controller: controller, options: options, closing: closing)
            // 淡出中的那一侧当作已经不在：树塌成另一侧（与 `SplitTree.removing` 同结果）
            guard let a else { return b }
            guard let b else { return a }
            let direction: String = switch split.direction {
            case .horizontal: "horizontal"
            case .vertical: "vertical"
            }
            // 比例**原样写出来**：拖分隔条能拖到 10pt（一块 1600pt 宽的 pane 就是 0.006），
            // 夹进 0.1–0.9 的话这份 dump 描述的就不是这个工作区，而且 apply 回去分隔条会自己跳一下
            return .split(.init(direction: direction, ratio: rounded(split.ratio), a: a, b: b))
        }
    }

    /// 布局里某个 pane 的位置引用（`focus` / `zoom` 用的就是它）
    static func position(of pane: PaneView, in layout: WorkspaceLayout,
                         closing: Set<UUID>) -> PaneRef? {
        switch layout {
        case .scrolling(let strip):
            var column = 0
            for candidate in strip.columns {
                let panes = candidate.panes.filter { !closing.contains($0.id) }
                if panes.isEmpty { continue }
                if let row = panes.firstIndex(where: { $0 === pane }) {
                    return PaneRef(column: column, row: row)
                }
                column += 1
            }
            return nil
        case .dwindle(let tree):
            guard let root = tree.root, let node = root.node(view: pane),
                  let path = root.path(to: node) else { return nil }
            return PaneRef(path: ControlStateEncoder.pathString(path))
        }
    }

    // MARK: 零件

    /// 数值一律定到 4 位小数：dump 出来的东西要能被人读、被 diff 工具比，
    /// 而 apply 写回去的就是这个定过点的值，于是 `dump → apply → dump` 逐字节稳定
    static func rounded(_ value: Double, _ digits: Int = 4) -> Double {
        let scale = pow(10.0, Double(digits))
        return (value * scale).rounded() / scale
    }

    static func rounded(_ value: CGFloat, _ digits: Int = 4) -> Double {
        rounded(Double(value), digits)
    }

    /// `/Users/danny/proj` → `~/proj`（`--relocatable`）
    static func relocatable(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard path == home || path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }
}
