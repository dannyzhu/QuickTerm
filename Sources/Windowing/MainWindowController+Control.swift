import AppKit

/// 控制面（`Sources/Control`）要用的**绝对设值**入口。
///
/// 这一层存在的唯一理由：应用自己的 WM 动作全是 toggle 与"焦点相对"的（`toggle-zoom`、
/// `moveFocusedPane(to:)`），而 agent 看不到状态——重试一次 toggle 就把自己撤销了。
/// 所以每个开关都补一个"设成这个值"的形式，每个相对操作都补一个"指名道姓"的形式。
///
/// 实现上**一律复用已有的值类型操作**（`ScrollingStrip` / `SplitTree` / `insertNewPane` /
/// `scrollingDrop` 的那份 dropping 语义），绝不另写一套：另写的那套迟早和拖放给出不同的落点。
///
/// 全部主线程独占（`MainWindowController` 没有 `@MainActor` 标注，Swift 5.10 也不会替我们检查，
/// 所以调用方——`ControlCommandRunner`——每个入口都有 `dispatchPrecondition`）。
extension MainWindowController {
    // MARK: 快照（撤销用）

    /// 一块屏幕的完整布局快照。layouts / floatings 是值类型，拍下来就是一份完整的旧状态——
    /// 逐操作反算撤销迟早会漏掉 zoom / 列宽这类"顺带被清掉"的东西。
    /// `controller` 是弱引用：撤销栈绝不该把一块已经关掉的屏幕吊回来
    struct ControlSnapshot {
        weak var controller: MainWindowController?
        var layouts: [WorkspaceLayout]
        var floatings: [[FloatingPane]]
        var activeIndex: Int
        var visibleColumns: Int
        /// 这块屏幕在**变更之后**该有的那一组 pane（只存 id，不强引用）。
        /// 整份盖回布局 = 替换整个 pane 集合，所以撤销的前提是"从那以后没人动过 pane 集合"：
        /// 对不上就整条作废——否则之后新建的 pane 会被无声抹掉（一个收尾都不跑），
        /// 之后关掉的 pane 会被原样吊回来
        var expectedPaneIDs: Set<UUID> = []

        /// 快照本身装着的那一组 pane（撤销之后该在的那一组）
        var snapshotPaneIDs: Set<UUID> {
            Set(layouts.flatMap { $0.paneList.map(\.id) }
                + floatings.flatMap { $0.map(\.pane.id) })
        }

        /// 撤销这一步会顺带关掉 pane（撤销 `pane new` 就是这一类）
        var closesPanesOnRestore: Bool { !expectedPaneIDs.subtracting(snapshotPaneIDs).isEmpty }

        /// 屏幕上现在正好还是这次变更留下的那一组 pane
        @MainActor
        func matchesLive() -> Bool {
            guard let controller, !controller.isClosed else { return false }
            controller.flushPendingCloses()
            return controller.controlLivePaneIDs() == expectedPaneIDs
        }

        /// 变更之后再拍一次"该有哪些 pane"。**必须在 apply() 之后调**
        @MainActor
        mutating func stampExpectedPanes() {
            expectedPaneIDs = controller?.controlLivePaneIDs() ?? []
        }

        @discardableResult
        @MainActor
        func restore() -> Bool {
            guard let controller, !controller.isClosed else { return false }
            controller.flushPendingCloses()
            // pane 集合变了就不撤销：整份盖回去会连着替换 pane 集合本身
            guard controller.controlLivePaneIDs() == expectedPaneIDs else { return false }
            // 这次变更**建**出来的 pane：撤销要把它们关掉，而"关掉"得走关闭语义
            // （浏览器 pane 要取消下载、告诉扩展窗口关了；文件管理器要删 cwd 临时文件）。
            // 直接让它们从 layouts 里消失等于泄漏一个终端
            let keep = snapshotPaneIDs
            for pane in controller.model.layouts.flatMap(\.paneList)
                + controller.model.floatings.flatMap({ $0.map(\.pane) })
            where !keep.contains(pane.id) {
                controller.removeFromAnyWorkspace(pane)
            }
            // 先恢复可见列数（它会重排所有 scrolling 列宽），再整份盖回布局——
            // 顺序反过来的话列宽会被 setVisibleColumns 冲掉
            controller.setVisibleColumns(visibleColumns, persist: false)
            controller.model.layouts = layouts
            controller.model.floatings = floatings
            controller.model.activeIndex = min(max(activeIndex, 0), max(layouts.count - 1, 0))
            if let focus = controller.model.layouts[controller.model.activeIndex].paneList.first
                ?? controller.model.floatings[controller.model.activeIndex].first?.pane {
                controller.requestFocus(to: focus)
            }
            return true
        }
    }

    /// 这块屏幕上现在活着的 pane（不含 Scratchpad——它不进布局快照）
    func controlLivePaneIDs() -> Set<UUID> {
        Set(model.layouts.flatMap { $0.paneList.map(\.id) }
            + model.floatings.flatMap { $0.map(\.pane.id) })
    }

    func controlSnapshot() -> ControlSnapshot {
        ControlSnapshot(controller: self, layouts: model.layouts, floatings: model.floatings,
                        activeIndex: model.activeIndex, visibleColumns: visibleColumns)
    }

    // MARK: 摘下 / 插入

    /// 把 pane 从它所在的工作区摘下来，**一个收尾都不跑**（搬家语义）。
    ///
    /// 与 `removeFromAnyWorkspace` 的区别是全部的重点：那一条是"关闭"，会调
    /// `BrowserPaneView.paneWillClose()`（取消下载、通知扩展"窗口关了"）并删掉文件管理器
    /// 的 cwd 临时文件。搬一个浏览器 pane 去别的工作区却跑那些收尾，症状是
    /// "拖走之后下载没了、扩展图标点不动"——而且没有任何报错。
    @discardableResult
    func controlDetach(_ pane: PaneView) -> Bool {
        flushPendingCloses()
        for i in model.layouts.indices {
            if let index = model.floatings[i].firstIndex(where: { $0.pane === pane }) {
                model.floatings[i].remove(at: index)
                return true
            }
            switch model.layouts[i] {
            case .dwindle(let tree):
                if let node = tree.root?.node(view: pane) {
                    model.layouts[i] = .dwindle(tree.removing(node))
                    return true
                }
            case .scrolling(let strip):
                if strip.paneList.contains(where: { $0 === pane }) {
                    model.layouts[i] = .scrolling(strip.removing(pane))
                    return true
                }
            }
        }
        return false
    }

    /// 把一个 pane 插进**任意**工作区（含非活动工作区）的指定落点。
    ///
    /// - `zone == nil`：走应用自己的默认落点（`insertNewPane`：scrolling 锚点右侧新列、
    ///   dwindle 按空间几何分裂 + 局部进场动效）。
    /// - `zone != nil`：先按默认落点插进去，再用**拖放那一份**语义把它挪到位
    ///   （`ScrollingStrip.dropping` / `SplitTree.dropping`）——命令行与鼠标拖放共用一套落点算法。
    @discardableResult
    func controlInsert(_ pane: PaneView, workspace: Int, anchor: PaneView?,
                       zone: TerminalSplitDropZone?, focus: Bool) -> Bool {
        flushPendingCloses()
        guard model.layouts.indices.contains(workspace) else { return false }
        let anchorInWorkspace = anchor.flatMap { candidate in
            model.layouts[workspace].paneList.contains { $0 === candidate } ? candidate : nil
        }

        if workspace == model.activeIndex {
            guard insertNewPane(pane, anchor: anchorInWorkspace) else { return false }
        } else {
            guard insertIntoInactive(pane, workspace: workspace, anchor: anchorInWorkspace) else { return false }
        }

        // 落点微调：默认插入等价于 .right（scrolling 锚点右侧新列 / dwindle 几何分裂）
        if let zone, let anchorInWorkspace {
            switch model.layouts[workspace] {
            case .scrolling(let strip):
                model.layouts[workspace] = .scrolling(strip.dropping(pane, on: anchorInWorkspace, zone: zone))
            case .dwindle(let tree):
                if let moved = tree.dropping(pane, on: anchorInWorkspace, zone: zone) {
                    model.layouts[workspace] = .dwindle(moved)
                }
            }
        }
        if focus, workspace == model.activeIndex { requestFocus(to: pane, from: anchorInWorkspace) }
        return true
    }

    /// 非活动工作区的默认插入（`insertNewPane` 只认活动工作区）：
    /// scrolling = 锚点右侧新列 / 末尾新列；dwindle = 锚点按空间几何分裂 / 首叶
    private func insertIntoInactive(_ pane: PaneView, workspace: Int, anchor: PaneView?) -> Bool {
        switch model.layouts[workspace] {
        case .scrolling(let strip):
            model.layouts[workspace] = .scrolling(
                strip.insertingColumnRight(of: anchor ?? strip.paneList.last, pane: pane,
                                           widthFactor: columnFactor))
            return true
        case .dwindle(let tree):
            if tree.isEmpty {
                model.layouts[workspace] = .dwindle(SplitTree(view: pane))
                return true
            }
            guard let target = anchor ?? tree.root?.leaves().first,
                  let next = try? tree.inserting(
                    view: pane, at: target,
                    direction: tree.dwindleDirection(for: target, in: dwindleLayoutSize)) else { return false }
            model.layouts[workspace] = .dwindle(next)
            return true
        }
    }

    // MARK: 绝对设值

    func controlIsZoomed(_ pane: PaneView, workspace: Int) -> Bool {
        guard model.layouts.indices.contains(workspace) else { return false }
        switch model.layouts[workspace] {
        // 与渲染侧（`ScrollingStripView` 读的是 `zoomedPane`）和 `ControlStateEncoder` 用**同一份**判定：
        // 只比 id 的话，一个指向非成员（如浮动 pane）的悬空 zoomedID 会让两条读路径给出相反答案
        case .scrolling(let strip): return strip.zoomedPane === pane
        case .dwindle(let tree):
            guard let zoomed = tree.zoomed, case .leaf(let view) = zoomed else { return false }
            return view === pane
        }
    }

    /// `--zoom on|off`。`off` 只清掉**这个 pane** 的 zoom：别的 pane 正 zoom 着时，
    /// "把 t7 设成不 zoom"本来就已经成立，不该顺手把别人的 zoom 也解开
    func controlSetZoom(_ pane: PaneView, workspace: Int, on: Bool) {
        guard model.layouts.indices.contains(workspace) else { return }
        switch model.layouts[workspace] {
        case .scrolling(var strip):
            if on {
                // 不在这条 strip 里（浮动 pane）就不写：写下去是一个悬空 id，
                // 渲染侧看不见它，读回来却是 true，而且会把别人真正的 zoom 顶掉
                guard strip.position(of: pane) != nil else { return }
                strip.zoomedID = pane.id
            } else if strip.zoomedID == pane.id {
                strip.zoomedID = nil
            }
            model.layouts[workspace] = .scrolling(strip)
        case .dwindle(let tree):
            guard let node = tree.root?.node(view: pane) else { return }
            if on {
                model.layouts[workspace] = .dwindle(SplitTree(root: tree.root, zoomed: node))
            } else if tree.zoomed == node {
                model.layouts[workspace] = .dwindle(SplitTree(root: tree.root, zoomed: nil))
            }
        }
    }

    func controlIsFloating(_ pane: PaneView, workspace: Int) -> Bool {
        guard model.floatings.indices.contains(workspace) else { return false }
        return model.floatings[workspace].contains { $0.pane === pane }
    }

    /// scrolling：这个 pane 所在列的宽度因子（dwindle 下为 nil）
    func controlColumnWidth(of pane: PaneView, workspace: Int) -> Double? {
        guard model.layouts.indices.contains(workspace),
              case .scrolling(let strip) = model.layouts[workspace],
              let (column, _) = strip.position(of: pane) else { return nil }
        return strip.columns[column].widthFactor
    }

    /// `--width 0.33`（绝对）。范围校验在调用方：**越界要报错，不能静默夹紧**——
    /// 夹紧之后 agent 读回来的值和它写下去的不一样，却没有任何提示
    func controlSetColumnWidth(_ pane: PaneView, workspace: Int, to width: Double) {
        guard model.layouts.indices.contains(workspace),
              case .scrolling(var strip) = model.layouts[workspace],
              let (column, _) = strip.position(of: pane) else { return }
        strip.columns[column].widthFactor = width
        model.layouts[workspace] = .scrolling(strip)
    }

    /// dwindle：这个 pane 最近一个父 split 的比例（`handleSplitOperation(.resize)` 调的是同一个东西）
    func controlSplitRatio(of pane: PaneView, workspace: Int) -> Double? {
        guard let (_, split) = controlParentSplit(of: pane, workspace: workspace) else { return nil }
        guard case .split(let s) = split else { return nil }
        return s.ratio
    }

    /// `--ratio 0.5`（绝对）：等价于把分隔条拖到某个位置，走的正是拖分隔条那条路径
    @discardableResult
    func controlSetSplitRatio(_ pane: PaneView, workspace: Int, to ratio: Double) -> Bool {
        guard model.layouts.indices.contains(workspace),
              case .dwindle(let tree) = model.layouts[workspace],
              let (_, split) = controlParentSplit(of: pane, workspace: workspace),
              let next = try? tree.replacing(node: split, with: split.resizing(to: ratio)) else { return false }
        model.layouts[workspace] = .dwindle(next)
        return true
    }

    private func controlParentSplit(of pane: PaneView, workspace: Int)
        -> (path: SplitTree<PaneView>.Path, node: SplitTree<PaneView>.Node)? {
        guard model.layouts.indices.contains(workspace),
              case .dwindle(let tree) = model.layouts[workspace],
              let root = tree.root,
              let node = root.node(view: pane),
              let path = root.path(to: node), !path.path.isEmpty else { return nil }
        let parentPath = SplitTree<PaneView>.Path(path: Array(path.path.dropLast()))
        guard let parent = root.node(at: parentPath), case .split = parent else { return nil }
        return (parentPath, parent)
    }

    /// 工作区里全部可比较的几何量（列宽 / split 比例），用来判断 equalize 是不是空操作。
    /// **不比较 PaneView 身份**：diff 只关心几何
    func controlGeometry(workspace: Int) -> [Double] {
        guard model.layouts.indices.contains(workspace) else { return [] }
        switch model.layouts[workspace] {
        case .scrolling(let strip): return strip.columns.map(\.widthFactor)
        case .dwindle(let tree): return Self.ratios(of: tree.root)
        }
    }

    private static func ratios(of node: SplitTree<PaneView>.Node?) -> [Double] {
        guard let node else { return [] }
        switch node {
        case .leaf: return []
        case .split(let s): return [s.ratio] + ratios(of: s.left) + ratios(of: s.right)
        }
    }

    /// 等分（任意工作区）。返回是否真的改了
    @discardableResult
    func controlEqualize(workspace: Int) -> Bool {
        guard model.layouts.indices.contains(workspace) else { return false }
        let before = controlGeometry(workspace: workspace)
        switch model.layouts[workspace] {
        case .scrolling(let strip):
            model.layouts[workspace] = .scrolling(strip.equalized(to: columnFactor))
        case .dwindle(let tree):
            model.layouts[workspace] = .dwindle(tree.equalized())
        }
        let after = controlGeometry(workspace: workspace)
        return !Self.geometryMatches(before, after)
    }

    static func geometryMatches(_ a: [Double], _ b: [Double]) -> Bool {
        guard a.count == b.count else { return false }
        return zip(a, b).allSatisfy { abs($0 - $1) < 0.0005 }
    }

    /// 浏览器 pane 的构造（**还没插进布局**）。`openBrowserPane(url:from:)` 建完就往
    /// **活动**布局里插，非活动工作区 / 自定义落点用不了它；主题那一下不能漏——
    /// 漏了的话新开的浏览器 pane 底色是白的，与主题对不上
    func controlMakeBrowserPane(url: URL) -> BrowserPaneView {
        let pane = BrowserPaneView(url: url)
        applyBrowserTheme(pane)
        return pane
    }

    /// 同一个工作区内换个落点（`pane move --at/--where` 打在自己所在的工作区上时）。
    /// 走的就是拖放那一份语义
    @discardableResult
    func controlReplace(_ pane: PaneView, workspace: Int, anchor: PaneView,
                        zone: TerminalSplitDropZone) -> Bool {
        guard model.layouts.indices.contains(workspace), pane !== anchor else { return false }
        switch model.layouts[workspace] {
        case .scrolling(let strip):
            model.layouts[workspace] = .scrolling(strip.dropping(pane, on: anchor, zone: zone))
        case .dwindle(let tree):
            guard let moved = tree.dropping(pane, on: anchor, zone: zone) else { return false }
            model.layouts[workspace] = .dwindle(moved)
        }
        if workspace == model.activeIndex { requestFocus(to: pane) }
        return true
    }

    /// 两个 pane 互换位置（`pane swap`）。dwindle 用树的 swapping，scrolling 用拖放的 .center 语义——
    /// 与 `swap-left/right/up/down` 那四个动作是同一套结果，只是这里可以指名道姓
    @discardableResult
    func controlSwap(_ a: PaneView, _ b: PaneView, workspace: Int) -> Bool {
        guard model.layouts.indices.contains(workspace), a !== b else { return false }
        switch model.layouts[workspace] {
        case .scrolling(let strip):
            guard strip.position(of: a) != nil, strip.position(of: b) != nil else { return false }
            model.layouts[workspace] = .scrolling(strip.dropping(a, on: b, zone: .center))
        case .dwindle(let tree):
            guard let swapped = try? tree.swapping(a, b) else { return false }
            model.layouts[workspace] = .dwindle(swapped)
        }
        if workspace == model.activeIndex { requestFocus(to: a) }
        return true
    }

    /// 把一个 pane 交给**另一个工作区，或者另一块屏幕**。
    ///
    /// 跨屏幕这条路径应用里原本一条都没有（两个拖放处理器都假定源与目标在同一个布局里）。
    /// 顺序是有讲究的：
    /// 1. 先在源头**摘下**（`controlDetach`，一个收尾都不跑——搬家不是关闭）；
    /// 2. 文件管理器会话跟着走，否则新东家不认识它（关闭确认会回来、退出不再原位开终端）；
    /// 3. 再插进目标；
    /// 4. 焦点：跟随就交给目标屏幕（并把窗口置前），不跟随就在源头补一个接班人——
    ///    否则源屏幕的焦点会悬在一个已经不在它那儿的 pane 上。
    /// 引擎回调的归属（`owns(_:)` 读的是 `model.allPanes`）与 pane 存档订阅（layouts sink）
    /// 都会自动跟着走，不需要额外登记
    @discardableResult
    func controlHandOff(_ pane: PaneView, to target: MainWindowController, workspace: Int,
                        anchor: PaneView?, zone: TerminalSplitDropZone?, follow: Bool) -> Bool {
        guard target.model.layouts.indices.contains(workspace) else { return false }
        flushPendingCloses()
        target.flushPendingCloses()
        let wasFocused = focusedPane === pane
        // 源工作区要在**摘下之前**记住：回滚时得放回它原来待的那一个，
        // 而不是"当下的活动工作区"——从非活动工作区搬走再回滚会把它挪到别处去
        let sourceWorkspace = model.layouts.indices.first { index in
            model.layouts[index].paneList.contains { $0 === pane }
                || model.floatings[index].contains { $0.pane === pane }
        } ?? model.activeIndex
        let successor = model.layouts[sourceWorkspace].paneList.first { $0 !== pane }
            ?? model.floatings[sourceWorkspace].map(\.pane).first { $0 !== pane }
        let session = controlTakeFileManagerSession(pane)
        guard controlDetach(pane) else { return false }
        guard target.controlInsert(pane, workspace: workspace, anchor: anchor, zone: zone,
                                   focus: follow) else {
            // 放不进去就放回原处：绝不把一个 pane 丢在没有任何工作区引用它的地方（那等于泄漏一个终端）
            controlInsert(pane, workspace: sourceWorkspace, anchor: nil, zone: nil, focus: wasFocused)
            if let session { registerFileManagerSession(pane, session) }
            return false
        }
        if let session { target.registerFileManagerSession(pane, session) }
        if follow {
            if target.model.activeIndex != workspace { target.switchWorkspace(workspace) }
            target.window?.makeKeyAndOrderFront(nil)
            target.requestFocus(to: pane)
        } else if wasFocused, let successor {
            requestFocus(to: successor)
        }
        return true
    }

    /// 关掉一个工作区里的所有 pane（`workspace clear`）。活动工作区走真正的关闭路径
    /// （带焦点接班与动效），非活动工作区走 `removeFromAnyWorkspace`——两条都会跑 pane 级收尾
    func controlClearWorkspace(_ index: Int, confirmIfNeeded: Bool) -> [PaneView] {
        flushPendingCloses()
        guard model.layouts.indices.contains(index) else { return [] }
        let victims = model.layouts[index].paneList + model.floatings[index].map(\.pane)
        for pane in victims {
            if index == model.activeIndex {
                closePane(pane, confirmIfNeeded: confirmIfNeeded, animated: false)
            } else {
                removeFromAnyWorkspace(pane)
            }
        }
        flushPendingCloses()
        return victims
    }
}
