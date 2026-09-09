import SwiftUI

/// scrolling 无限画布渲染器（spec §4.2-bis）：
/// 横向列条带；列宽 = widthFactor×视口；列内纵向等分栈叠；
/// 视口以最小滚动量跟随焦点列（~0.15s easeOut），相邻列在两缘自然露出。
struct ScrollingStripView: View {
    let strip: ScrollingStrip
    let workspaceIndex: Int
    let pan: WorkspaceModel.StripPanEvent?
    let onDrop: (PaneView, PaneView, TerminalSplitDropZone) -> Void
    /// 正在淡出的 pane（渐隐；到点后控制器移除、列条带重排）
    var closingPanes: Set<UUID> = []

    @EnvironmentObject var theme: ThemeManager   // pane-gap（露边下限随之变化）
    @State private var offset: CGFloat = 0
    @State private var lastPanSerial: Int = -1
    /// 已见过的 pane 身份：结构变化时用来认出「刚插进来的列」（见 revealTarget）
    @State private var knownPaneIDs: Set<UUID>?

    private let columnGap: CGFloat = 0  // 列间隙由 PaneChrome 的 pane-gap 内边距相邻合成 2×gap（= gaps_in×2）

    var body: some View {
        GeometryReader { geo in
            // 列宽在 zoom 分支**之外**算：zoom 期间列宽照样会变（换可见列数、改窗口大小），
            // 偏移得跟着夹取，解除 zoom 时条带才不会一上来就停在内容外面
            let widths = strip.columnWidths(viewport: geo.size.width, gap: columnGap)
            ZStack(alignment: .topLeading) {
                if let zoomed = strip.zoomedPane {
                    // zoom：焦点 pane 占满内容区（同 dwindle 语义）
                    ScrollingPaneCell(surfaceView: zoomed, onDrop: onDrop,
                                      closing: closingPanes.contains(zoomed.id))
                        .id(zoomed.id)   // 换了 zoom 的 pane 要换视图身份（faded 等状态不可沿用）
                } else {
                    HStack(alignment: .top, spacing: columnGap) {
                        ForEach(Array(strip.columns.enumerated()),
                                id: \.element.id) { index, column in
                            VStack(spacing: 0) {
                                ForEach(column.panes, id: \.id) { pane in
                                    ScrollingPaneCell(surfaceView: pane, onDrop: onDrop,
                                                      closing: closingPanes.contains(pane.id))
                                }
                            }
                            .frame(width: max(widths[index], 50))
                        }
                    }
                    .frame(height: geo.size.height, alignment: .top)
                    .offset(x: -offset)
                    .onPreferenceChange(FocusedStripPaneKey.self) { focusedID in
                        scrollToFocus(id: focusedID, viewport: geo.size.width)
                    }
                    .onChange(of: pan) {
                        applyPan(viewport: geo.size.width)   // 平移只在条带铺开时有意义
                    }
                }
            }
            // ↓ 视口对齐一律挂在 zoom 分支**外面**：zoom 切换会把整条 HStack 拆掉重建，
            // 而所有结构操作都顺手清 zoom（insertingColumnRight 等），
            // 于是「Cmd+F 后 Cmd+B / ⌘点链接」的插列与解除 zoom 落在同一次更新里：
            // 挂在分支里时重建出来的 HStack 只会走 onAppear（把刚插进来的 pane 也认成「早就见过」），
            // onChange 又不对刚创建的视图触发 —— 新列就再没人揭示，退回只靠焦点的老路。
            .onAppear {
                // 首次挂载先记下现有身份：之后出现的 pane 才算「新插进来的」
                knownPaneIDs = Set(strip.paneList.map(\.id))
            }
            .onChange(of: strip.layoutSignature) {
                // 结构变化（插/删列、Cmd+Shift+方向换位、併拆）后重新对齐——
                // 新插进来的列优先，其次当前焦点；被移动/新建的 pane 始终完整可见
                scrollToFocus(id: revealTarget(), viewport: geo.size.width)
            }
            .onChange(of: widths) { old, new in
                // 列宽/视口变化（换「每屏可见列数」、Cmd+Ctrl+= 重置、拖拽调宽、改窗口大小）：
                // 只把偏移拉回合法范围，不主动跟焦点——否则会劫持手动平移。
                // 列数没变 = 纯宽度变化：**不加动画**逐事件跟手夹取（与 applyPan 进行中的处理一致）。
                // ⌘+右键拖拽调宽是逐事件写宽度，条带停在右端时每个事件都会触发一次夹取：
                // 带动画的话每帧重设 0.15s easeOut，视口拖着尾巴、右缘漏空。
                clampOffset(viewport: geo.size.width, animated: old.count != new.count)
            }
            .onChange(of: workspaceIndex) {
                knownPaneIDs = Set(strip.paneList.map(\.id))   // 换工作区 = 换一整条带，重新认身份
                offset = 0
                scrollToFocus(id: currentFocusedID(), viewport: geo.size.width)
            }
        }
        .clipped()
    }

    /// 结构变化后要揭示的列：**新插进来的 pane 优先**，没有才退回当前焦点。
    ///
    /// 焦点是异步落地的（PaneView.moveFocus 要等新 pane 挂进窗口；浏览器 pane 的 first responder
    /// 是内部 WKWebView，还要再慢一拍），本回调触发时焦点通常还在原 pane 上——只按焦点对齐会把
    /// 视口停在旧列，新列就卡在视口右缘外（用户可见为「新建浏览器宽度不对」：焦点边框已经是新
    /// 浏览器的，内容却被窗口右缘裁掉）。按身份揭示与「焦点何时落地、会不会被悬停抢走」无关。
    private func revealTarget() -> UUID? {
        let ids = strip.paneList.map(\.id)
        defer { knownPaneIDs = Set(ids) }
        // 整条带被换掉（切工作区、dwindle→scrolling）不算「插进来一列」：
        // 必须有旧 pane 留存，才把这轮新出现的 pane 当作插入目标
        guard let known = knownPaneIDs, ids.contains(where: known.contains) else {
            return currentFocusedID()
        }
        return ids.last { !known.contains($0) } ?? currentFocusedID()
    }

    private func currentFocusedID() -> UUID? {
        // 真相优先：窗口 first responder 是哪个 pane（或其后代——浏览器 pane 的 FR 是内部 WKWebView）。
        // focused 标志在 SwiftUI 重挂期间可能同时残留在两个 pane 上（见 PaneView.viewWillMove(toWindow:)），
        // 退化时取**末位**命中，与 FocusedStripPaneKey.reduce（末位胜出）一致——
        // 两条滚动路径必须挑同一个 pane，否则一条滚到旧列、另一条不再触发，视口就停在错的位置。
        let panes = strip.paneList
        if let window = panes.compactMap(\.window).first,
           let holder = panes.first(where: { $0.holdsFirstResponder(of: window) }) {
            return holder.id
        }
        return panes.last { $0.focused }?.id
    }

    private func scrollToFocus(id: UUID?, viewport: CGFloat) {
        let target: CGFloat
        let total = strip.totalWidth(viewport: viewport, gap: columnGap)
        if total <= viewport {
            // 不溢出：无条件居中（单列=全宽 offset 0；两列=左右等隙），与焦点无关
            target = (total - viewport) / 2
        } else if let id, let pane = strip.paneList.first(where: { $0.id == id }) {
            target = strip.targetOffset(for: pane, current: offset, viewport: viewport, gap: columnGap,
                                        paneGap: theme.paneGap)
        } else {
            return
        }
        guard abs(target - offset) > 0.5 else { return }
        withAnimation(.easeOut(duration: 0.15)) { offset = target }
    }

    /// 把偏移拉回合法范围：不溢出时居中，溢出时夹在 [0, 总宽 − 视口]。
    /// 列宽变了却不重排时，视口会停在内容之外（列变窄后左侧一片空、右侧的列被裁），
    /// 而 layoutSignature 刻意不含 widthFactor（见 ScrollingStrip），只能由列宽本身触发。
    /// `animated` 只在列数变化（插/删列）时为真——纯宽度变化是逐事件手势，动画会拖尾巴。
    private func clampOffset(viewport: CGFloat, animated: Bool) {
        guard viewport > 0 else { return }
        let total = strip.totalWidth(viewport: viewport, gap: columnGap)
        let target = total <= viewport
            ? (total - viewport) / 2
            : min(max(offset, 0), total - viewport)
        guard abs(target - offset) > 0.5 else { return }
        guard animated else {
            var transaction = Transaction()
            transaction.disablesAnimations = true   // 手势进行中：跟手，不要动画尾巴
            withTransaction(transaction) { offset = target }
            return
        }
        withAnimation(.easeOut(duration: 0.15)) { offset = target }
    }

    /// 双指横滑平移（附带项）：滑动跟手，结束吸附最近列左缘。
    /// 内容不溢出（单列/双列居中）时无可平移量，直接忽略。
    private func applyPan(viewport: CGFloat) {
        guard let pan, pan.serial != lastPanSerial else { return }
        lastPanSerial = pan.serial
        let total = strip.totalWidth(viewport: viewport, gap: columnGap)
        guard total > viewport else { return }
        let maxOffset = total - viewport
        if pan.ended {
            // 吸附到最近的「列左缘 − 露边」（与焦点滚动的对齐规则一致）
            let widths = strip.columnWidths(viewport: viewport, gap: columnGap)
            let peek = ScrollingStrip.peekPoints(viewport: viewport, paneGap: theme.paneGap)
            var x: CGFloat = 0
            var best: CGFloat = 0
            for width in widths {
                let candidate = x - peek
                if abs(candidate - offset) < abs(best - offset) { best = candidate }
                x += width + columnGap
            }
            withAnimation(.easeOut(duration: 0.15)) { offset = min(max(best, 0), maxOffset) }
        } else {
            offset = min(max(offset - pan.delta, 0), maxOffset)
        }
    }
}

/// 焦点 pane id 上报（驱动视口滚动跟随，含悬停焦点）
private struct FocusedStripPaneKey: PreferenceKey {
    static var defaultValue: UUID?
    static func reduce(value: inout UUID?, nextValue: () -> UUID?) {
        value = nextValue() ?? value
    }
}

/// scrolling 布局的 pane 单元：SurfaceWrapper + 视觉 + 拖放目标 + ⌘拖拽源
/// （行为对齐 dwindle 的 TerminalSplitLeaf，见 porting-notes）
struct ScrollingPaneCell: View {
    @ObservedObject var surfaceView: PaneView
    let onDrop: (PaneView, PaneView, TerminalSplitDropZone) -> Void
    /// 浮动层渲染（RootView）：透传给 PaneChrome 关掉非激活磨砂
    var floating: Bool = false
    /// 关闭中 → 渐隐并停止响应鼠标（悬停不再夺焦点）
    var closing: Bool = false
    /// 渐隐由状态驱动（一出生就 closing 的单元也能淡出），见 TerminalSplitLeaf
    @State private var faded = false

    @ObservedObject private var modifierState = ModifierState.shared
    @State private var dropZone: TerminalSplitDropZone?
    @State private var dragSourceDragging = false
    @State private var dragSourceHovering = false

    var body: some View {
        GeometryReader { geo in
            PaneContentView(pane: surfaceView, isSplit: true)   // 按 pane 种类分发内容
                .background {
                    // 浮动 pane 不是拖放目标（塞回平铺走 Cmd+T）：
                    // 不注册 delegate，避免亮出无效的落区色块
                    if !floating {
                        Color.clear.onDrop(
                            of: [.ghosttySurfaceId],
                            delegate: StripDropDelegate(
                                zone: $dropZone,
                                viewSize: geo.size,
                                destination: surfaceView,
                                onDrop: onDrop))
                    }
                }
                .overlay {
                    if let dropZone {
                        dropZone.overlay(in: geo).allowsHitTesting(false)
                    }
                }
                .overlay {
                    // 拖拽进行中也保持挂载：先松 ⌘ 再松左键时不能把活着的 NSDraggingSource 拆掉，
                    // 否则 draggingSession(endedAt:) 落不到在窗口里的视图，PaneDragState 收不了尾
                    if modifierState.commandHeld || dragSourceDragging {
                        Ghostty.SurfaceDragSource(
                            surfaceView: surfaceView,
                            isDragging: $dragSourceDragging,
                            isHovering: $dragSourceHovering)
                    }
                }
                .modifier(PaneChrome(surfaceView: surfaceView, floating: floating))
                .opacity(faded ? 0 : 1)
                .allowsHitTesting(!closing)
                .onChange(of: closing, initial: true) { _, closing in
                    if !closing { faded = false; return }   // 身份复用兜底：不在关闭中就必须可见
                    guard !faded else { return }
                    withAnimation(.easeOut(duration: 0.28)) { faded = true }
                }
                .preference(key: FocusedStripPaneKey.self,
                            value: surfaceView.focused ? surfaceView.id : nil)
        }
    }
}

/// 拖放目标（镜像 dwindle 的 SplitDropDelegate 行为；zone 计算复用 TerminalSplitDropZone）
private struct StripDropDelegate: DropDelegate {
    @Binding var zone: TerminalSplitDropZone?
    let viewSize: CGSize
    let destination: PaneView
    let onDrop: (PaneView, PaneView, TerminalSplitDropZone) -> Void

    /// 跨窗口拖放明确拒绝：一个 pane 只能挂在一个窗口里（PaneHostView 返回同一个 NSView 实例），
    /// 源与目标不同窗口时不认领——落区不亮、光标带禁止标记，不做静默失败
    func validateDrop(info: DropInfo) -> Bool {
        guard PaneDragState.shared.allowsDrop(on: destination) else { return false }
        return info.hasItemsConforming(to: [.ghosttySurfaceId])
    }

    func dropEntered(info: DropInfo) {
        guard PaneDragState.shared.allowsDrop(on: destination) else { return }
        zone = .calculate(at: info.location, in: viewSize)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard PaneDragState.shared.allowsDrop(on: destination) else { return DropProposal(operation: .forbidden) }
        guard zone != nil else { return DropProposal(operation: .forbidden) }
        zone = .calculate(at: info.location, in: viewSize)
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) { zone = nil }

    func performDrop(info: DropInfo) -> Bool {
        let dropZone = TerminalSplitDropZone.calculate(at: info.location, in: viewSize)
        zone = nil
        guard PaneDragState.shared.allowsDrop(on: destination) else { return false }
        guard let provider = info.itemProviders(for: [.ghosttySurfaceId]).first else { return false }
        _ = provider.loadTransferable(type: PaneView.self) { [weak destination] result in
            if case .success(let source) = result {
                DispatchQueue.main.async {
                    guard let destination, source !== destination else { return }
                    onDrop(source, destination, dropZone)
                }
            }
        }
        return true
    }
}
