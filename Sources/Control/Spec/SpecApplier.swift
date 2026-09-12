import AppKit

/// 把一份 `quickterm.workspace/1` 落到一个工作区上。
///
/// **顺序是这个类的全部内容**，因为这个代码库里有三个具体的坑：
///
/// 1. **绝不走 `applyArchive` / `restore(from:)`**。那条路是"整窗口、为一块刚建出来的
///    `restoring: true` 屏幕写的"：它把 pane 按赋值替换掉，于是
///    `BrowserPaneView.paneWillClose()`（取消下载、通知扩展窗口关了）与文件管理器会话清理
///    一个都不跑，还会顺手把 0.49 / 0.44 这类历史列宽改写掉。用它落 spec 的后果是
///    静默泄漏，而且没有任何用例会红。被顶掉的 pane 一律走**真正的关闭路径**。
/// 2. **先把整个布局值算完，再一次赋给 `model.layouts[i]`**。`layouts` 是 `@Published`，
///    每次赋值都会走一遍焦点对账、pane 存档重订阅与 1.5s 防抖存档；分五次赋值就是
///    五次重排、五次动画、五遍 sink。
/// 3. **先建、后拆**。建 pane 是唯一可能失败的一步（目录没了、网址解析不出来）；
///    把它放在拆之前，"落不下去就一个 pane 都不动"才是结构上成立的，而不是靠自觉。
///
/// 主线程独占（`MainWindowController` 没有 `@MainActor`，Swift 5.10 也不会替我们检查）。
@MainActor
final class SpecApplier {
    enum Mode: String, CaseIterable {
        /// 默认：只往**空**工作区里放东西，非空一律拒绝（退出码 4）——毁不掉任何东西
        case intoEmpty = "into-empty"
        /// 破坏性：工作区里原有的 pane 全部走真正的关闭路径（整份一模一样时是空操作）
        case replace
        /// 能对上的 pane 原地留着（跑着的 dev server 不会被重启），其余的关掉 / 新建
        case reuse
    }

    /// 落刀的几个阶段。**只给用例注入失败用**：拆过之后才失败 = 工作区已经被动过，
    /// 报告里必须如实写上 partial
    enum Stage: String {
        case creating, assembling, tearingDown
    }

    struct Outcome {
        var created: [PaneView] = []
        var reused: [PaneView] = []
        var closed: [String] = []
        var focus: PaneView?
    }

    /// spec 遍历出来的一格
    struct SlotSpec {
        /// 位置键（`c:0.1` / `p:a.b` / `f:0`）——`focus` / `zoom` 靠它落位
        var key: String
        var pane: PaneSpec
        var rect: CGRect?
    }

    struct Slot {
        var key: String
        var spec: PaneSpec
        var request: ControlPaneFactory.Request
        var rect: CGRect?
        /// 匹配到的活 pane（nil = 要新建）
        var existing: PaneView?
        var isFloating: Bool { key.hasPrefix("f:") }
    }

    let controller: MainWindowController
    let workspace: Int
    let spec: WorkspaceSpec
    let mode: Mode
    /// 调用方能不能看到浏览器 pane 的网址（与 `state` 同一条规则）：看不到就一律不匹配，
    /// 免得"匹配上了没有"本身变成一个猜网址的探测通道
    let exposesBrowser: Bool
    /// 屏幕信封里的 `visibleColumns`：那一层说过一次之后，嵌套的工作区就不再重复写
    ///（见 `SpecCodec.screen`）。省掉 `width` 的列要按**它**折算列宽，否则一份
    /// "屏幕说 4 列 + 每列不写 width" 的 spec 会落成当下那个可见列数的宽度
    var visibleColumnsHint: Int?
    /// **只给用例**：在某个阶段抛错，用来钉住"落刀之后失败要如实报 partial"。生产恒为 nil
    var fault: ((Stage) throws -> Void)?

    private(set) var slots: [Slot] = []
    /// 会被顶掉的 pane（走真正的关闭路径）
    private(set) var displaced: [PaneView] = []
    /// 活工作区已经与这份 spec 一模一样：一个 pane 都不用建、不用关
    private(set) var totalMatch = false
    private(set) var didPreflight = false

    init(controller: MainWindowController, workspace: Int, spec: WorkspaceSpec, mode: Mode,
         exposesBrowser: Bool = true) {
        self.controller = controller
        self.workspace = workspace
        self.spec = spec
        self.mode = mode
        self.exposesBrowser = exposesBrowser
    }

    var existingPanes: [PaneView] {
        let model = controller.model
        let closing = model.closingPanes
        return (model.layouts[workspace].paneList + model.floatings[workspace].map(\.pane))
            .filter { !closing.contains($0.id) }
    }

    /// 这份 spec 落下去之后每屏可见几列
    var wantedVisibleColumns: Int {
        spec.visibleColumns ?? visibleColumnsHint ?? controller.visibleColumns
    }

    /// 省掉 `width` 的列用多宽。**按这份 spec 要的可见列数折算**，而不是当下的那个：
    /// `setVisibleColumns` 要等布局值算完之后才落（`apply()` 步骤 4），
    /// 拿当下的因子当默认值的话，一份「visibleColumns 4 + 不写 width」的 spec 会落成
    /// 旧因子的列宽，下一次 dump 就跟这份 spec 对不上了
    var wantedColumnFactor: Double {
        ScrollingStrip.factor(forVisibleColumns: wantedVisibleColumns)
    }

    /// 新建 pane 时继承的目录：优先目标工作区的焦点 pane，其次工作区里现有的 pane，
    /// 再其次这块屏幕的焦点 pane（都没有就交给引擎的默认值）
    var anchorDirectory: String? {
        if workspace == controller.model.activeIndex,
           let cwd = controller.focusedPane?.workingDirectory { return cwd }
        return existingPanes.compactMap(\.workingDirectory).first
            ?? controller.focusedPane?.workingDirectory
    }

    /// 预检发现的、**存在但用不上**的工作目录（macOS 受保护目录且没有授权）。
    /// `spec apply` 会把它们变成响应里的 `cwd_denied` 告警（`--require-cwd` 则变成错误）
    private(set) var deniedDirectories: [String] = []

    // MARK: 预检（**一个 pane 都还没建、一个都还没关**）

    func preflight() throws {
        dispatchPrecondition(condition: .onQueue(.main))
        controller.flushPendingCloses()
        deniedDirectories.removeAll()

        var built: [Slot] = []
        for item in Self.tiledSlots(spec) + Self.floatingSlots(spec) {
            let request: ControlPaneFactory.Request
            do {
                request = try Self.request(from: item.pane)
            } catch {
                let body = (error as? ControlErrorBody) ?? ControlErrorBody(.badRequest, "\(error)")
                throw ControlErrorBody(ControlErrorCode(rawValue: body.code) ?? .badRequest,
                                       "spec \(item.key)：\(body.message)", hint: body.hint)
            }
            if let problem = ControlPaneFactory.directoryProblem(request.cwd) {
                throw ControlErrorBody(.badRequest, "spec \(item.key)：\(problem)",
                                       hint: "先建好目录，或改掉这份 spec 里的 cwd")
            }
            // 目录存在，却因为缺少 macOS 的隐私授权而交不给引擎（受保护目录）：
            // **不是错误**（这份 spec 照样铺得出来），但调用方必须被告知——
            // 否则 `spec apply` 会安安静静地把每个 pane 都落在默认目录上
            // （只问真的会用上 cwd 的 kind：浏览器 pane 从来不消费它，
            //   为它报一条 cwd_denied 是在说一件没发生过的事，`--require-cwd` 还会整份 spec 拒掉）
            if let cwd = request.cwd, ControlPaneFactory.consumesWorkingDirectory(request.kind),
               WorkingDirectoryGate.usable(cwd) == nil,
               !deniedDirectories.contains(cwd) {
                deniedDirectories.append(cwd)
            }
            built.append(Slot(key: item.key, spec: item.pane, request: request, rect: item.rect))
        }
        guard built.count <= ControlRateLimiter.maxPanesPerWorkspace else {
            throw ControlErrorBody(
                .denied,
                "这份 spec 要 \(built.count) 个 pane，超过一个工作区的上限 \(ControlRateLimiter.maxPanesPerWorkspace)")
        }
        if let columns = spec.visibleColumns, !SpecLimits.visibleColumns.contains(columns) {
            throw ControlErrorBody(.badRequest,
                                   "visibleColumns 必须在 \(SpecLimits.visibleColumns.lowerBound)–"
                                       + "\(SpecLimits.visibleColumns.upperBound) 之间，收到 \(columns)")
        }
        // 名字：与 `workspace set --title` 同一条尺子（`SpecParser` 已经拦过一遍，
        // 但 applier 也会被直接喂一份 `WorkspaceSpec`——两处都拦才叫"落不下去就不动手"）
        if let title = spec.title {
            guard title.count <= SpecLimits.maxTitleCharacters else {
                throw ControlErrorBody(.badRequest,
                                       "title 太长了（\(title.count) 个字符，上限 \(SpecLimits.maxTitleCharacters)）")
            }
            guard title.unicodeScalars.allSatisfy(WorkspaceModel.isTitleScalar) else {
                throw ControlErrorBody(.badRequest, "title 里有控制字符")
            }
        }

        // 位置引用要落得下去。**建之前**就核：zoom 指着一个不存在的格子时，
        // 半途才发现意味着工作区已经被拆了一半
        let keys = Set(built.map(\.key))
        for (name, ref) in [("focus", spec.focus), ("zoom", spec.zoom)] {
            guard let ref, let key = Self.key(for: ref) else { continue }
            guard keys.contains(key) else {
                throw ControlErrorBody(
                    .badRequest, "\(name) 指向的位置在这份 spec 里不存在（\(key)）",
                    hint: "位置引用：scrolling 用 {column,row}，dwindle 用 {path}，浮动层用 {floating}",
                    candidates: built.map(\.key))
            }
        }

        // 匹配：能对上的活 pane 留着。`--replace` 只认"整份都对得上"（那就是一次空操作）——
        // 部分对上时它的语义就是"全拆了重建"，否则一个说 replace 的调用方会莫名留下
        // 一个还在跑着 dev server 的 pane，而它以为自己刚把工作区清空了
        let live = existingPanes
        let matched = Self.match(built.map(\.spec), against: live, mode: mode, controller: controller,
                                 exposesBrowser: exposesBrowser)
        let coverage = matched.compactMap { $0 }
        totalMatch = coverage.count == built.count && coverage.count == live.count
        if mode == .reuse || totalMatch {
            for i in built.indices { built[i].existing = matched[i] }
        }
        slots = built
        let kept = Set(slots.compactMap { $0.existing.map(ObjectIdentifier.init) })
        displaced = live.filter { !kept.contains(ObjectIdentifier($0)) }
        didPreflight = true
    }

    /// `--dry-run` / `--fail-if-noop` 读的那份 diff。**空 = 已经是这个样子了**
    func changes(at path: String) -> [ControlChange] {
        var out: [ControlChange] = []
        let liveLayout = controller.model.layouts[workspace].name
        let wanted = spec.layoutName
        if liveLayout != wanted {
            out.append(ControlChange("\(path).layout", from: liveLayout, to: wanted))
        }
        if let columns = spec.visibleColumns, columns != controller.visibleColumns {
            out.append(ControlChange("\(path).visibleColumns",
                                     from: String(controller.visibleColumns), to: String(columns)))
        }
        // 名字：**不写就不动它**（与 visibleColumns 同一条）。写了且不一样才算一次改动——
        // 否则一份不提名字的 spec 会把 `--fail-if-noop` 的判断搅成"总是有变化"
        if let wanted = Self.wantedTitle(spec), wanted != controller.model.title(at: workspace) {
            out.append(ControlChange("\(path).title",
                                     from: controller.model.title(at: workspace) ?? "（没起过名）",
                                     to: wanted ?? "（清掉）", sensitive: true))
        }
        let creating = slots.filter { $0.existing == nil }.count
        if creating > 0 || !displaced.isEmpty {
            out.append(ControlChange(
                "\(path).panes", from: "\(existingPanes.count) 个",
                to: "\(slots.count) 个（新建 \(creating)，关掉 \(displaced.count)，留用 \(slots.count - creating)）"))
        }
        // 一个 pane 都不用建、不用关：**剩下的全是"谁在哪一格"与几何**。
        // 这两样都要真的比一遍——`commit()` 见到空 diff 就直接不落刀了，
        // 于是"把两列并成一列"这种只动排布的 spec 会被静默丢掉，还报成 changed:false
        guard creating == 0, displaced.isEmpty else { return out }
        let live = SpecCodec.workspace(controller, index: workspace, options: .init(), nested: true)

        // 排布：列的分组 / 树的形状 + 每一格里到底是哪个 pane（几何不进这个签名，
        // 列宽与分裂比例下面各有各的比较，重复报一次只会让 diff 更难读）
        let tiledPlan = slots.filter { !$0.isFloating }
        let tiled = tiledPlan.compactMap(\.existing)
        if tiled.count == tiledPlan.count, let next = try? buildLayout(tiled: tiled) {
            let now = Self.arrangement(of: controller.model.layouts[workspace],
                                       closing: controller.model.closingPanes)
            let wantText = Self.arrangement(of: next, closing: [])
            if now != wantText {
                out.append(ControlChange("\(path).\(wanted == "dwindle" ? "tree" : "columns")",
                                         from: now, to: wantText))
            }
        }
        // 浮动层：顺序与矩形（只挪一个浮动窗口的 spec 同样不能被当成空操作）
        let floatingPlan = slots.filter { $0.isFloating }
        let wantFloating = buildFloatings(floatingPlan.compactMap(\.existing))
        let liveFloating = controller.model.floatings[workspace]
            .filter { !controller.model.closingPanes.contains($0.pane.id) }
        if floatingPlan.compactMap(\.existing).count == floatingPlan.count,
           Self.floatingSignature(liveFloating) != Self.floatingSignature(wantFloating) {
            out.append(ControlChange("\(path).floating",
                                     from: Self.floatingSignature(liveFloating),
                                     to: Self.floatingSignature(wantFloating)))
        }
        if let liveColumns = live.columns, let want = spec.columns {
            for (i, column) in want.enumerated() where i < liveColumns.count {
                let now = liveColumns[i].width ?? controller.columnFactor
                let next = column.width ?? wantedColumnFactor
                if abs(now - next) >= 0.0005 {
                    out.append(ControlChange("\(path).columns[\(i)].width",
                                             from: Self.number(now), to: Self.number(next)))
                }
            }
        }
        if wanted == "dwindle", let want = spec.tree {
            let now = Self.geometry(of: live.tree)
            let next = Self.geometry(of: want)
            if now != next {
                out.append(ControlChange("\(path).tree", from: now, to: next))
            }
        }
        if live.zoom != spec.zoom {
            out.append(ControlChange("\(path).zoom",
                                     from: Self.describe(live.zoom), to: Self.describe(spec.zoom)))
        }
        if spec.focus != nil, live.focus != spec.focus {
            out.append(ControlChange("\(path).focus",
                                     from: Self.describe(live.focus), to: Self.describe(spec.focus)))
        }
        return out
    }

    // MARK: 落地

    func apply() throws -> Outcome {
        dispatchPrecondition(condition: .onQueue(.main))
        precondition(didPreflight, "SpecApplier.apply() 之前必须先 preflight()")
        var outcome = Outcome()

        // 1) 建。**这是唯一可能失败的一步，所以它排在拆之前**：
        //    失败了就把这一批已经建出来的收掉，工作区一个字节都没动过
        var madeList: [ControlPaneFactory.Made] = []
        var panes: [PaneView] = []
        do {
            try fault?(.creating)
            for slot in slots {
                if let existing = slot.existing {
                    panes.append(existing)
                    outcome.reused.append(existing)
                    continue
                }
                let made = try ControlPaneFactory.make(slot.request, controller: controller,
                                                       inheriting: anchorDirectory)
                if let browser = made.pane as? BrowserPaneView { Self.restoreTabs(slot.spec, in: browser) }
                madeList.append(made)
                panes.append(made.pane)
                outcome.created.append(made.pane)
            }

            // 2) 把整个布局值算完（列 id 尽量沿用：`ScrollingStrip.Column.id` 一变，SwiftUI
            //    会重建整列，列里的 SurfaceView 脱离再重挂——闪一帧、first responder 被静默重置）
            try fault?(.assembling)
        } catch {
            for made in madeList { ControlPaneFactory.discard(made, controller: controller) }
            throw Self.body(error, partial: false)
        }
        let tiledCount = slots.filter { !$0.isFloating }.count
        let layout: WorkspaceLayout
        let floatings: [FloatingPane]
        do {
            layout = try buildLayout(tiled: Array(panes.prefix(tiledCount)))
            floatings = buildFloatings(Array(panes.suffix(from: tiledCount)))
        } catch {
            for made in madeList { ControlPaneFactory.discard(made, controller: controller) }
            throw Self.body(error, partial: false)
        }

        // 3) 拆：被顶掉的 pane 一律走**真正的关闭路径**（浏览器 pane 的 paneWillClose、
        //    文件管理器的会话清理都在那条路上）
        do {
            for pane in displaced {
                outcome.closed.append(ControlHandleRegistry.shared.handle(for: pane))
                if workspace == controller.model.activeIndex {
                    controller.closePane(pane, confirmIfNeeded: false, animated: false)
                } else {
                    controller.removeFromAnyWorkspace(pane)
                }
                try fault?(.tearingDown)
            }
            controller.flushPendingCloses()
        } catch {
            // 已经动过手了：把这一批新建的收掉（它们还没进任何布局），如实报 partial——
            // 绝不假装什么都没发生
            for made in madeList { ControlPaneFactory.discard(made, controller: controller) }
            controller.flushPendingCloses()
            throw Self.body(error, partial: !outcome.closed.isEmpty)
        }

        // 4) 一次赋值。可见列数要**先**落（它会把所有 scrolling 工作区按新因子重排一遍，
        //    顺序反了的话 spec 里的列宽会被它冲掉）
        if let columns = spec.visibleColumns, columns != controller.visibleColumns {
            controller.setVisibleColumns(columns, persist: true)
        }
        if let wanted = Self.wantedTitle(spec) { controller.model.setTitle(wanted, at: workspace) }
        controller.model.layouts[workspace] = layout
        if !floatings.isEmpty || !controller.model.floatings[workspace].isEmpty {
            controller.model.floatings[workspace] = floatings
        }
        for made in madeList { ControlPaneFactory.register(made, controller: controller) }

        // 5) 焦点（只对活动工作区有意义：别把焦点交给一个没挂载的工作区）
        let focus = Self.key(for: spec.focus).flatMap { key in
            slots.firstIndex { $0.key == key }.map { panes[$0] }
        } ?? panes.first
        outcome.focus = focus
        if workspace == controller.model.activeIndex, let focus {
            controller.requestFocus(to: focus)
        }
        return outcome
    }

    /// 这份 spec 要把名字设成什么。外层 nil = 这份 spec 压根没提名字（别动它）；
    /// 内层 nil（写了个空串）= 清掉名字
    nonisolated static func wantedTitle(_ spec: WorkspaceSpec) -> String?? {
        guard let title = spec.title else { return nil }
        return .some(WorkspaceModel.normalizedTitle(title))
    }

    // MARK: 组装（纯值运算）

    private func buildLayout(tiled: [PaneView]) throws -> WorkspaceLayout {
        switch spec.layoutName {
        case "dwindle":
            guard let tree = spec.tree, !tiled.isEmpty else {
                return .dwindle(SplitTree<PaneView>(root: nil, zoomed: nil))
            }
            var cursor = 0
            let root = try Self.buildNode(tree, panes: tiled, cursor: &cursor)
            let built = SplitTree<PaneView>(root: root, zoomed: nil)
            guard let zoomKey = Self.key(for: spec.zoom),
                  let index = slots.firstIndex(where: { $0.key == zoomKey }), index < tiled.count,
                  let node = built.root?.node(view: tiled[index]) else { return .dwindle(built) }
            return .dwindle(SplitTree<PaneView>(root: built.root, zoomed: node))
        default:
            var strip = ScrollingStrip()
            var cursor = 0
            var previous: [Set<UUID>: UUID] = [:]
            if case .scrolling(let live) = controller.model.layouts[workspace] {
                for column in live.columns where previous[Set(column.panes.map(\.id))] == nil {
                    previous[Set(column.panes.map(\.id))] = column.id
                }
            }
            for column in spec.columns ?? [] {
                let count = column.panes?.count ?? 1
                guard cursor + count <= tiled.count else { break }
                let panes = Array(tiled[cursor..<(cursor + count)])
                cursor += count
                var built = ScrollingStrip.Column(panes: panes,
                                                  widthFactor: column.width ?? wantedColumnFactor)
                if let id = previous[Set(panes.map(\.id))] { built.id = id }
                strip.columns.append(built)
            }
            if let zoomKey = Self.key(for: spec.zoom),
               let index = slots.firstIndex(where: { $0.key == zoomKey }), index < tiled.count {
                strip.zoomedID = tiled[index].id
            }
            return .scrolling(strip)
        }
    }

    private func buildFloatings(_ panes: [PaneView]) -> [FloatingPane] {
        let specs = spec.floating ?? []
        return panes.enumerated().map { i, pane in
            let rect = i < specs.count ? Self.rect(specs[i].rect) : nil
            return FloatingPane(pane: pane,
                                rect: rect ?? FloatingPane.defaultRect(columnFactor: controller.columnFactor))
                .clamped()
        }
    }

    private static func buildNode(_ node: NodeSpec, panes: [PaneView],
                                  cursor: inout Int) throws -> SplitTree<PaneView>.Node {
        switch node {
        case .leaf:
            guard cursor < panes.count else {
                throw ControlErrorBody(.internalError, "组装 dwindle 树时叶子数对不上")
            }
            defer { cursor += 1 }
            return .leaf(view: panes[cursor])
        case .split(let split):
            let left = try buildNode(split.a, panes: panes, cursor: &cursor)
            let right = try buildNode(split.b, panes: panes, cursor: &cursor)
            let direction: SplitTree<PaneView>.Direction =
                split.direction == "vertical" ? .vertical : .horizontal
            return .split(.init(direction: direction, ratio: split.ratio ?? 0.5,
                                left: left, right: right))
        }
    }

    /// 浏览器 pane 的其余标签。构造时开的是 `tabs[0]`（见 `request(from:)`），
    /// 这里把剩下的按顺序补齐，再把 `url` 指的那一个设为活动标签
    private static func restoreTabs(_ spec: PaneSpec, in pane: BrowserPaneView) {
        guard let tabs = spec.tabs, tabs.count > 1 else { return }
        // `resolveURL` 而不是 `url(forInput:)`：dump 出来的是绝对网址，
        // 扩展页那种 scheme 交给地址栏启发式会变成一次搜索（见 ControlPaneFactory.passthroughSchemes）
        let urls = tabs.compactMap { ControlPaneFactory.resolveURL($0) }
        for url in urls.dropFirst() { _ = pane.addTab(url: url, activate: false) }
        let active = spec.url.flatMap { raw in urls.firstIndex { $0.absoluteString == raw } } ?? 0
        if pane.tabs.indices.contains(active) { pane.selectTab(at: active) }
    }

    // MARK: 遍历（**建与组装必须用同一个顺序**）

    /// 平铺层的格子：scrolling 按列、列内自上而下；dwindle 按 a → b 的深度优先
    nonisolated static func tiledSlots(_ spec: WorkspaceSpec) -> [SlotSpec] {
        var out: [SlotSpec] = []
        switch spec.layoutName {
        case "dwindle":
            guard let tree = spec.tree else { return [] }
            walk(tree, path: "", into: &out)
        default:
            for (c, column) in (spec.columns ?? []).enumerated() {
                for (r, pane) in (column.panes ?? [PaneSpec()]).enumerated() {
                    out.append(SlotSpec(key: "c:\(c).\(r)", pane: pane))
                }
            }
        }
        return out
    }

    nonisolated static func floatingSlots(_ spec: WorkspaceSpec) -> [SlotSpec] {
        (spec.floating ?? []).enumerated().map { i, item in
            SlotSpec(key: "f:\(i)", pane: item.pane ?? PaneSpec(), rect: rect(item.rect))
        }
    }

    nonisolated private static func walk(_ node: NodeSpec, path: String, into out: inout [SlotSpec]) {
        switch node {
        case .leaf(let pane):
            out.append(SlotSpec(key: "p:\(path)", pane: pane))
        case .split(let split):
            walk(split.a, path: path.isEmpty ? "a" : path + ".a", into: &out)
            walk(split.b, path: path.isEmpty ? "b" : path + ".b", into: &out)
        }
    }

    nonisolated static func key(for ref: PaneRef?) -> String? {
        guard let ref else { return nil }
        if let floating = ref.floating { return "f:\(floating)" }
        if let path = ref.path { return "p:\(path)" }
        if let column = ref.column { return "c:\(column).\(ref.row ?? 0)" }
        if let row = ref.row { return "c:0.\(row)" }
        return nil
    }

    nonisolated static func rect(_ numbers: [Double]?) -> CGRect? {
        guard let numbers, numbers.count == 4 else { return nil }
        return CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3])
    }

    /// 布局的**排布**签名（列的分组 / 树的形状 + 每一格里是哪个 pane，**不含几何**）。
    /// `changes()` 靠它看出"pane 一个没变、只是重新摆了一下"——
    /// 没有它的话那种 spec 会被 `commit()` 当成空操作直接丢掉
    static func arrangement(of layout: WorkspaceLayout, closing: Set<UUID>) -> String {
        switch layout {
        case .scrolling(let strip):
            return strip.columns
                .map { column in
                    column.panes.filter { !closing.contains($0.id) }
                        .map { ControlHandleRegistry.shared.handle(for: $0) }
                        .joined(separator: ",")
                }
                .filter { !$0.isEmpty }
                .joined(separator: " | ")
        case .dwindle(let tree):
            return arrangement(of: tree.root, closing: closing)
        }
    }

    private static func arrangement(of node: SplitTree<PaneView>.Node?, closing: Set<UUID>) -> String {
        guard let node else { return "空" }
        switch node {
        case .leaf(let view):
            // 淡出中的那一片叶子当作已经不在（与 `SpecCodec.node` 同一条塌缩规则）
            return closing.contains(view.id) ? "" : ControlHandleRegistry.shared.handle(for: view)
        case .split(let split):
            let a = arrangement(of: split.left, closing: closing)
            let b = arrangement(of: split.right, closing: closing)
            if a.isEmpty { return b }
            if b.isEmpty { return a }
            return "(\(a),\(b))"
        }
    }

    /// 浮动层的签名：顺序 + 每一个的矩形（定到 3 位小数，与 diff 里的数字同精度）
    static func floatingSignature(_ items: [FloatingPane]) -> String {
        items.map { item in
            let rect = item.rect
            return ControlHandleRegistry.shared.handle(for: item.pane)
                + "@" + [rect.origin.x, rect.origin.y, rect.size.width, rect.size.height]
                    .map { number(Double($0)) }.joined(separator: ",")
        }.joined(separator: " ")
    }

    /// 树的**几何**签名（形状 + 方向 + 比例，不含 pane 内容）：diff 用它判断"只是比例变了"
    nonisolated static func geometry(of node: NodeSpec?) -> String {
        guard let node else { return "空" }
        switch node {
        case .leaf: return "·"
        case .split(let split):
            let direction = split.direction == "vertical" ? "上下" : "左右"
            return "\(direction)\(number(split.ratio ?? 0.5))(\(geometry(of: split.a)),\(geometry(of: split.b)))"
        }
    }

    // MARK: 匹配（`--reuse` 与"整份一模一样"的判定）

    /// spec 的每一格 → 活 pane（或 nil = 要新建）。三轮，一轮比一轮松：
    /// ① `id` 精确命中（`dump --include-ids` 出来的 spec）——**只在 `--reuse` 里**，且种类要对上；
    /// ② 同种类 + 同 cwd / 同网址；
    /// ③ 同种类、这一格**没写命令也没写 cwd/网址**（"随便给我一个终端"）。
    /// 写了命令的格子是"要跑起来的东西"：`--reuse` 之外一律不拿现成的壳去顶它
    /// （顶了的话那条命令一次都没跑，调用方却收到"成功、无变化"）。
    /// 每个活 pane 最多被用掉一次
    static func match(_ specs: [PaneSpec], against live: [PaneView], mode: Mode,
                      controller: MainWindowController, exposesBrowser: Bool) -> [PaneView?] {
        var out = [PaneView?](repeating: nil, count: specs.count)
        var used = Set<ObjectIdentifier>()

        func take(_ index: Int, _ pane: PaneView) {
            out[index] = pane
            used.insert(ObjectIdentifier(pane))
        }
        func available() -> [PaneView] { live.filter { !used.contains(ObjectIdentifier($0)) } }

        // 写了命令的格子是"要跑起来的东西"。`--replace` 的语义是拆了重建：拿一个现成的壳去顶它，
        // 那条命令就一次都没跑过，而调用方收到的是"成功、无变化"。
        // `--reuse` 反过来——"能对上的原地留着"正是"重试不要重启 dev server"的那条路
        func wantsFreshProcess(_ spec: PaneSpec) -> Bool { spec.cmd != nil && mode != .reuse }

        // ① id：**只在 `--reuse` 里**。id 是"就要这一个 pane"的指名道姓，只有 reuse 认这种指名；
        // 别的模式下认它的后果是 `dump --include-ids` → 改一个 cwd → `apply --replace`
        // 每一格都靠 id 对上，于是改动被整份丢掉，还报成"已经是这个样子了"
        if mode == .reuse {
            for (i, spec) in specs.enumerated() {
                guard let raw = spec.id, let id = UUID(uuidString: raw) else { continue }
                if let hit = available().first(where: {
                    $0.id == id && kind(of: spec) == liveKind($0, controller: controller)
                }) { take(i, hit) }
            }
        }
        for (i, spec) in specs.enumerated() where out[i] == nil && !wantsFreshProcess(spec) {
            if let hit = available().first(where: {
                identityMatches(spec, $0, controller: controller, exposesBrowser: exposesBrowser)
            }) { take(i, hit) }
        }
        for (i, spec) in specs.enumerated() where out[i] == nil && spec.cmd == nil {
            if let hit = available().first(where: {
                kind(of: spec) == liveKind($0, controller: controller) && looseMatch(spec, $0)
            }) { take(i, hit) }
        }
        return out
    }

    nonisolated static func kind(of spec: PaneSpec) -> String { spec.kind ?? "terminal" }

    /// 文件管理器 pane 就是一个跑着 yazi 的终端：spec 里它是独立的一种，
    /// 拿它去顶一个普通终端会让"退出即在原位开终端"的语义跟着搬家
    static func liveKind(_ pane: PaneView, controller: MainWindowController) -> String {
        controller.controlRole(of: pane) == "file-manager" ? "file-manager" : pane.kind.rawValue
    }

    /// 同一个东西：种类相同，且终端的 cwd / 浏览器的网址对得上
    static func identityMatches(_ spec: PaneSpec, _ pane: PaneView,
                                controller: MainWindowController, exposesBrowser: Bool) -> Bool {
        guard kind(of: spec) == liveKind(pane, controller: controller) else { return false }
        if let browser = pane as? BrowserPaneView {
            // 没有 token 的调用方读不到活 pane 的网址：那就一律不匹配（宁可重建，
            // 也不要让"匹配上了没有"变成一个猜网址的探测通道）
            guard exposesBrowser, let wanted = spec.url else { return false }
            // 规范化之后再比：手写的 spec 里是 `http://localhost:3000`，
            // 活着的那个 pane 报的是 `http://localhost:3000/`。照字面比就永远匹配不上，
            // 于是每 apply 一次都把一个正停在目标页上的 pane 拆了重建
            return ControlPaneFactory.sameURL(browser.currentURL,
                                              ControlPaneFactory.resolveURL(wanted))
        }
        guard let cwd = spec.cwd, let live = pane.workingDirectory else { return false }
        return samePath(cwd, live)
    }

    /// 第三轮：spec 那一格没写 cwd / 网址
    nonisolated static func looseMatch(_ spec: PaneSpec, _ pane: PaneView) -> Bool {
        pane is BrowserPaneView ? spec.url == nil : spec.cwd == nil
    }

    /// 路径比较一律解到物理路径：`/tmp` 与 `/private/tmp` 是同一个目录，
    /// 而 shell 的 OSC 7 报的是后者——不解的话每次 apply 都会把 pane 重建一遍
    nonisolated static func samePath(_ a: String, _ b: String) -> Bool {
        resolved(a) == resolved(b)
    }

    nonisolated static func resolved(_ path: String) -> String {
        URL(fileURLWithPath: SpecValidator.normalizedPath(path)).resolvingSymlinksInPath().path
    }

    // MARK: 零件

    static func request(from spec: PaneSpec) throws -> ControlPaneFactory.Request {
        var request = ControlPaneFactory.Request()
        request.kind = kind(of: spec)
        request.cwd = spec.cwd.map { SpecValidator.normalizedPath($0) }
        request.cmd = spec.cmd
        request.hold = spec.hold ?? false
        request.env = spec.env ?? [:]
        // 多标签的浏览器 pane 从 tabs[0] 开起（其余的 restoreTabs 补齐），这样标签顺序与 dump 出来的一致。
        // 种类不对（终端写了 url）交给工厂去报错——那份互斥规则只有一处
        request.url = spec.tabs?.first ?? spec.url
        try ControlPaneFactory.validate(request)
        return request
    }

    nonisolated static func describe(_ ref: PaneRef?) -> String {
        guard let ref, let key = key(for: ref) else { return "无" }
        return key
    }

    nonisolated static func number(_ value: Double) -> String { String(format: "%.3f", value) }

    /// 抛出来的东西统一成 `ControlErrorBody`；落刀之后的失败换一个**独立的错误码**，
    /// 这样 agent 能按 `code` 分辨"什么都没发生"与"改了一半"，而不必去读文案
    nonisolated static func body(_ error: any Error, partial: Bool) -> ControlErrorBody {
        let base = (error as? ControlErrorBody) ?? ControlErrorBody(.failed, "\(error)")
        // 里层已经报过 partial 了就原样往外传：套两层前缀只会让文案更难读，码是一样的
        guard partial, base.code != ControlErrorCode.partialApply.rawValue else { return base }
        return ControlErrorBody(
            .partialApply, "spec 只落了一半：\(base.message)",
            hint: "工作区已经被改过了（旧 pane 已关，新布局没落下去）——"
                + "先 quickterm spec dump 看看现状，再决定重发还是收拾")
    }
}
