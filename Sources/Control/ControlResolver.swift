import AppKit

/// 目标解析：把 `screen:workspace.pane` 落到真实的控制器 / 工作区下标 / PaneView。
///
/// 两条不可动摇的规则：
/// 1. **匹配到多个一律报错并列出候选**，绝不"取第一个"——静默改打别处是 agent 场景下最糟的失败；
/// 2. 正在淡出（`model.closingPanes`）的 pane 不可寻址。
@MainActor
struct ControlResolver {
    let screens: ScreenRegistry
    let origin: ControlRequestOrigin?
    /// 与 `ControlStateEncoder.exposesBrowser` 是同一个判定。打码生效时浏览器 pane
    /// **不进 `title:~` 的候选池**：否则谓词本身就是一个逐字符探测标题的 oracle
    /// （而且 `unique()` 连匹配个数都一起吐出来，布尔都不用猜），
    /// `expose-browser = "never"` 明明说了不给看，state 打了码，这里却照给不误
    var exposesBrowser: Bool = true

    /// `title:~` 整条命令共用的匹配预算。调用方给的正则跑在主线程上，
    /// 而 ICU 是回溯引擎且默认**既没有时限也没有回溯步数上限**：
    /// 7 字节的 `(.|.)+z` 打在一条 60 字符的普通提示符标题上就能把主线程钉死几个钟头，
    /// 整个 app（所有屏幕、终端渲染、控制 socket、连确认框本身）全部冻住，只能强制退出。
    /// 而 `title:` 走的是 read 类命令：不要 token、不要确认、也不过速率限制
    static let titleMatchBudget: TimeInterval = 0.2
    /// 正则本身的长度上限（编译期的兜底；真正的护栏是上面的预算）
    static let maxTitlePatternLength = 512

    struct Resolution {
        var controller: MainWindowController
        /// 内部 0 起（CLI 永远只见 1 起）
        var workspace: Int
        var pane: PaneView?
        var echo: ResolvedTarget
    }

    /// 定位一个 pane：它在哪块屏幕的哪个工作区（0 起）
    static func locate(_ pane: PaneView, in screens: ScreenRegistry) -> (MainWindowController, Int)? {
        for controller in screens.controllers {
            let model = controller.model
            for i in model.layouts.indices where model.layouts[i].paneList.contains(where: { $0 === pane }) {
                return (controller, i)
            }
            for i in model.floatings.indices where model.floatings[i].contains(where: { $0.pane === pane }) {
                return (controller, i)
            }
        }
        return nil
    }

    /// 全部可寻址的 pane（排除淡出中的、以及不属于任何工作区的 Scratchpad）
    static func addressablePanes(in screens: ScreenRegistry) -> [(pane: PaneView, controller: MainWindowController, workspace: Int)] {
        var out: [(PaneView, MainWindowController, Int)] = []
        for controller in screens.controllers {
            let model = controller.model
            for i in model.layouts.indices {
                for pane in model.layouts[i].paneList where !model.closingPanes.contains(pane.id) {
                    out.append((pane, controller, i))
                }
                for floating in model.floatings[i] where !model.closingPanes.contains(floating.pane.id) {
                    out.append((floating.pane, controller, i))
                }
            }
        }
        return out.map { (pane: $0.0, controller: $0.1, workspace: $0.2) }
    }

    /// 带预算的单条标题匹配。**返回 nil = 预算用尽**（调用方必须让整条命令失败）。
    ///
    /// `.reportProgress` 是 `NSRegularExpression` 唯一能中止一次长匹配的口子：
    /// `uregex_setTimeLimit` 不经它暴露，而"丢到后台线程加个超时"只是把一条烧满 CPU、
    /// 还停不下来的 ICU 线程漏出去——DoS 照旧。
    /// 静态方法是为了能在没有窗口的用例层直接钉死这条护栏
    static func titleMatches(_ title: String, regex: NSRegularExpression, deadline: Date) -> Bool? {
        var hit = false
        var timedOut = false
        regex.enumerateMatches(in: title, options: [.reportProgress],
                               range: NSRange(title.startIndex..., in: title)) { result, _, stop in
            if result != nil {
                hit = true
                stop.pointee = true
            } else if Date() > deadline {
                timedOut = true
                stop.pointee = true
            }
        }
        return timedOut ? nil : hit
    }

    func handle(_ pane: PaneView) -> String { ControlHandleRegistry.shared.handle(for: pane) }

    // MARK: 上下文

    /// 调用方所在的 pane（`QUICKTERM_PANE`），必须是当下真活着的 PaneView 才算数
    private func originPane() -> (PaneView, MainWindowController, Int)? {
        guard let raw = origin?.pane, let uuid = UUID(uuidString: raw) else { return nil }
        for entry in Self.addressablePanes(in: screens) where entry.pane.id == uuid {
            return (entry.pane, entry.controller, entry.workspace)
        }
        return nil
    }

    /// 上下文屏幕：显式 -t → 调用方所在 pane → controlCurrent（NSApp.isActive 才认 key 窗口）→ primary
    private func contextController() throws -> MainWindowController {
        if let (_, controller, _) = originPane() { return controller }
        guard let controller = screens.controlCurrent else {
            throw ControlErrorBody(.notFound, "No screens at all", hint: "QuickTerm needs at least one window.")
        }
        return controller
    }

    // MARK: 主入口

    func resolve(_ target: ControlTarget?) throws -> Resolution {
        let target = target ?? ControlTarget()

        // 1) 屏幕
        var controller: MainWindowController?
        if let screenRef = target.screen {
            controller = try resolveScreen(screenRef)
        }

        // 2) pane 优先决定落点：句柄 / uuid / 谓词是全局唯一的，不需要上下文
        var pane: PaneView?
        var paneWorkspace: Int?
        if let paneRef = target.pane, Self.isGlobalRef(paneRef) {
            let found = try resolveGlobalPane(paneRef, scopedTo: controller,
                                              workspace: target.workspace, screenGiven: target.screen != nil)
            pane = found.pane
            paneWorkspace = found.workspace
            if let existing = controller, existing !== found.controller {
                throw ControlErrorBody(
                    .badTarget,
                    "pane \(handle(found.pane)) is on screen \(found.controller.screenIndex + 1), which does not match screen \(existing.screenIndex + 1) in the target",
                    hint: "Drop the screen prefix, or address it as \(found.controller.screenIndex + 1):…")
            }
            controller = found.controller
        }

        let host = try controller ?? contextController()

        // 3) 工作区
        let workspaceIndex: Int
        if let workspaceRef = target.workspace {
            workspaceIndex = try resolveWorkspace(workspaceRef, in: host)
            if let paneWorkspace, paneWorkspace != workspaceIndex {
                throw ControlErrorBody(
                    .badTarget,
                    "pane \(pane.map { handle($0) } ?? "?") is in workspace \(paneWorkspace + 1), which does not match workspace \(workspaceIndex + 1) in the target",
                    hint: "Drop the workspace prefix.")
            }
        } else if let paneWorkspace {
            workspaceIndex = paneWorkspace
        } else if let (_, originController, originWorkspace) = originPane(), originController === host {
            workspaceIndex = originWorkspace
        } else {
            workspaceIndex = host.model.activeIndex
        }

        // 4) 关系式 / @focused / @self（要有上下文才能算）
        if pane == nil, let paneRef = target.pane {
            pane = try resolveContextualPane(paneRef, in: host, workspace: workspaceIndex)
        }

        return Resolution(
            controller: host,
            workspace: workspaceIndex,
            pane: pane,
            echo: ResolvedTarget(
                screen: host.screenIndex + 1,
                screenID: host.windowID.uuidString,
                workspace: workspaceIndex + 1,
                pane: pane.map { handle($0) },
                paneID: pane?.id.uuidString))
    }

    static func isGlobalRef(_ ref: ControlTarget.PaneRef) -> Bool {
        switch ref {
        case .handle, .id, .title, .cwd, .kind, .role: true
        case .focused, .selfPane, .direction, .cycle: false
        }
    }

    // MARK: 各段

    func resolveScreen(_ ref: ControlTarget.ScreenRef) throws -> MainWindowController {
        switch ref {
        case .index(let n):
            guard let controller = screens.controller(screenNumber: n) else {
                let available = screens.controllers.map { String($0.screenIndex + 1) }.sorted()
                throw ControlErrorBody(.notFound, "No screen numbered \(n)",
                                       hint: "Screens available: \(available.joined(separator: ", "))",
                                       candidates: available)
            }
            return controller
        case .id(let raw):
            let matches = screens.controllers.filter {
                $0.windowID.uuidString.lowercased().hasPrefix(raw.lowercased())
            }
            if matches.count > 1 {
                throw ControlErrorBody(.ambiguousTarget, "#\(raw) matches \(matches.count) screens",
                                       hint: "Give more of the uuid.",
                                       candidates: matches.map { $0.windowID.uuidString })
            }
            guard let controller = matches.first else {
                throw ControlErrorBody(.notFound, "No screen whose id starts with \(raw)")
            }
            return controller
        case .current:
            guard let controller = screens.controlCurrent else {
                throw ControlErrorBody(.notFound, "No screens at all")
            }
            return controller
        case .primary:
            guard let controller = screens.primary else {
                throw ControlErrorBody(.notFound, "No screens at all")
            }
            return controller
        }
    }

    func resolveWorkspace(_ ref: ControlTarget.WorkspaceRef, in controller: MainWindowController) throws -> Int {
        let count = controller.model.layouts.count
        switch ref {
        case .index(let n):
            guard n >= 1, n <= count else {
                throw ControlErrorBody(
                    .notFound, "Workspace \(n) does not exist: screen \(controller.screenIndex + 1) "
                        + "currently has \(count) (1–\(count))",
                    hint: "Raise workspaces (1–10) in ~/.config/quickterm/config.toml to get more")
            }
            return n - 1
        case .active:
            return controller.model.activeIndex
        case .next:
            return (controller.model.activeIndex + 1) % count
        case .prev:
            return (controller.model.activeIndex + count - 1) % count
        }
    }

    /// 全局引用（句柄 / uuid / 谓词）
    private func resolveGlobalPane(_ ref: ControlTarget.PaneRef, scopedTo controller: MainWindowController?,
                                   workspace: ControlTarget.WorkspaceRef?, screenGiven: Bool)
        throws -> (pane: PaneView, controller: MainWindowController, workspace: Int) {
        var pool = Self.addressablePanes(in: screens)
        if let controller { pool = pool.filter { $0.controller === controller } }
        if let controller, let workspace, let index = try? resolveWorkspace(workspace, in: controller) {
            pool = pool.filter { $0.workspace == index }
        }

        func fail(_ description: String) -> ControlErrorBody {
            ControlErrorBody(.notFound, "No pane matches \(description)",
                             hint: "quickterm list panes shows the handles that exist.")
        }

        switch ref {
        case .handle(let h):
            guard let id = ControlHandleRegistry.shared.paneID(forHandle: h) else { throw fail(h) }
            guard let entry = pool.first(where: { $0.pane.id == id }) else { throw fail(h) }
            return (entry.pane, entry.controller, entry.workspace)

        case .id(let raw):
            let needle = raw.lowercased()
            let matches = pool.filter { $0.pane.id.uuidString.lowercased().hasPrefix(needle) }
            if matches.count > 1 {
                throw ControlErrorBody(.ambiguousTarget, "#\(raw) matches \(matches.count) panes",
                                       hint: "Give more of the uuid, or use the short handle instead.",
                                       candidates: matches.map { handle($0.pane) })
            }
            guard let entry = matches.first else { throw fail("#\(raw)") }
            return (entry.pane, entry.controller, entry.workspace)

        case .title(let pattern):
            guard pattern.utf16.count <= Self.maxTitlePatternLength else {
                throw ControlErrorBody(.badTarget,
                                       "The title:~ pattern is too long (limit \(Self.maxTitlePatternLength) characters)",
                                       hint: "Use -t <handle> instead.")
            }
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                throw ControlErrorBody(.badTarget, "title:~\(pattern) is not a valid regular expression")
            }
            // 打码生效时把浏览器 pane 整体挪出候选池——匹配数与 not_found 都要在安全池上算，
            // 否则光看"匹配到几个"就能把打掉的标题一位一位问出来
            let searchable = exposesBrowser ? pool : pool.filter { !($0.pane is BrowserPaneView) }
            // 一份预算给整条命令，N 个 pane 不会把它乘上 N 倍
            let deadline = Date().addingTimeInterval(Self.titleMatchBudget)
            var matches: [(pane: PaneView, controller: MainWindowController, workspace: Int)] = []
            for entry in searchable {
                // 超时后**整条命令失败**：拿一个只跑完一半的池子去算歧义 / not_found，
                // 正是这份设计明令禁止的"静默给错答案"
                guard let hit = Self.titleMatches(entry.pane.paneTitle, regex: regex, deadline: deadline) else {
                    throw ControlErrorBody(.badTarget, "title:~\(pattern) timed out while matching (runaway regex backtracking)",
                                           hint: "Drop the nested quantifiers such as (a|aa)+ or (.|.)+, or just use -t <handle>")
                }
                if hit { matches.append(entry) }
            }
            return try unique(matches, description: "title:~\(pattern)")

        case .cwd(let prefix):
            let expanded = (prefix as NSString).expandingTildeInPath
            return try unique(pool.filter { ($0.pane.workingDirectory ?? "").hasPrefix(expanded) },
                              description: "cwd:\(prefix)")

        case .kind(let kind):
            return try unique(pool.filter { $0.pane.kind.rawValue == kind }, description: "kind:\(kind)")

        case .role(let role):
            return try unique(pool.filter { $0.controller.controlRole(of: $0.pane) == role },
                              description: "role:\(role)")

        case .focused, .selfPane, .direction, .cycle:
            throw ControlErrorBody(.internalError, "A relational target must not go through global resolution")
        }
    }

    private func unique(_ matches: [(pane: PaneView, controller: MainWindowController, workspace: Int)],
                        description: String)
        throws -> (pane: PaneView, controller: MainWindowController, workspace: Int) {
        if matches.count > 1 {
            throw ControlErrorBody(.ambiguousTarget, "\(matches.count) panes match \(description)",
                                   hint: "Name one exactly with -t <handle>",
                                   candidates: matches.map { handle($0.pane) })
        }
        guard let only = matches.first else {
            throw ControlErrorBody(.notFound, "No pane matches \(description)",
                                   hint: "quickterm list panes shows the handles that exist.")
        }
        return only
    }

    /// 关系式（要上下文）
    private func resolveContextualPane(_ ref: ControlTarget.PaneRef, in controller: MainWindowController,
                                       workspace: Int) throws -> PaneView {
        switch ref {
        case .selfPane:
            guard let (pane, _, _) = originPane() else {
                throw ControlErrorBody(.notFound, "@self could not be resolved: no usable QUICKTERM_PANE",
                                       hint: "Run this inside a QuickTerm pane, or use -t <handle> instead.")
            }
            return pane

        case .focused:
            guard let pane = focusedAddressablePane(in: controller, workspace: workspace) else {
                throw ControlErrorBody(.notFound, "Workspace \(workspace + 1) has no addressable pane")
            }
            return pane

        case .direction(let direction):
            guard let from = focusedAddressablePane(in: controller, workspace: workspace) else {
                throw ControlErrorBody(.notFound, "No focused pane, so @\(direction.rawValue) cannot be resolved")
            }
            guard let target = Self.neighbour(of: from, direction: direction,
                                              layout: controller.model.layouts[workspace]) else {
                throw ControlErrorBody(.notFound, "There is no pane @\(direction.rawValue) of \(handle(from))")
            }
            return target

        case .cycle(let next):
            guard let from = focusedAddressablePane(in: controller, workspace: workspace) else {
                throw ControlErrorBody(.notFound, "No focused pane, so @\(next ? "next" : "prev") cannot be resolved")
            }
            guard let target = Self.cycled(from: from, next: next,
                                           layout: controller.model.layouts[workspace]) else {
                throw ControlErrorBody(.notFound, "The workspace has only one pane, so there is nothing to cycle to")
            }
            return target

        default:
            throw ControlErrorBody(.internalError, "A global reference must not go through contextual resolution")
        }
    }

    /// 焦点 pane（排除淡出中的）；工作区不是活动工作区时退回该工作区的第一个 pane
    private func focusedAddressablePane(in controller: MainWindowController, workspace: Int) -> PaneView? {
        let model = controller.model
        let panes = model.layouts[workspace].paneList + model.floatings[workspace].map(\.pane)
        let live = panes.filter { !model.closingPanes.contains($0.id) }
        if workspace == model.activeIndex, let focused = controller.focusedPane,
           live.contains(where: { $0 === focused }) {
            return focused
        }
        return live.first
    }

    static func neighbour(of pane: PaneView, direction: ControlTarget.Direction,
                          layout: WorkspaceLayout) -> PaneView? {
        let strip: ScrollingStrip.Direction = switch direction {
        case .left: .left
        case .right: .right
        case .up: .up
        case .down: .down
        }
        // MainWindowController 里那份 Direction → Spatial.Direction 的映射是 fileprivate，
        // 这里自带一份而不是去放宽它的可见性（映射本身是恒等的，没有可漂移的余地）
        let spatial: SplitTree<PaneView>.Spatial.Direction = switch direction {
        case .left: .left
        case .right: .right
        case .up: .up
        case .down: .down
        }
        switch layout {
        case .scrolling(let s):
            return s.focusTarget(from: pane, direction: strip)
        case .dwindle(let tree):
            guard let node = tree.root?.node(view: pane) else { return nil }
            return tree.focusTarget(for: .spatial(spatial), from: node)
        }
    }

    static func cycled(from pane: PaneView, next: Bool, layout: WorkspaceLayout) -> PaneView? {
        switch layout {
        case .scrolling(let s):
            return s.linearTarget(from: pane, next: next)
        case .dwindle(let tree):
            guard let node = tree.root?.node(view: pane) else { return nil }
            return tree.focusTarget(for: next ? .next : .previous, from: node)
        }
    }
}
