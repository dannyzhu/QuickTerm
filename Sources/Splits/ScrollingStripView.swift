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

    private let columnGap: CGFloat = 0  // 列间隙由 PaneChrome 的 pane-gap 内边距相邻合成 2×gap（= gaps_in×2）

    var body: some View {
        GeometryReader { geo in
            if let zoomed = strip.zoomedPane {
                // zoom：焦点 pane 占满内容区（同 dwindle 语义）
                ScrollingPaneCell(surfaceView: zoomed, onDrop: onDrop,
                                  closing: closingPanes.contains(zoomed.id))
                    .id(zoomed.id)   // 换了 zoom 的 pane 要换视图身份（faded 等状态不可沿用）
            } else {
                let widths = strip.columnWidths(viewport: geo.size.width, gap: columnGap)
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
                .onChange(of: strip.layoutSignature) {
                    // 结构变化（插/删列、Cmd+Shift+方向换位、併拆）后
                    // 按当前焦点重新对齐——被移动的 pane 始终完整可见
                    scrollToFocus(id: currentFocusedID(), viewport: geo.size.width)
                }
                .onChange(of: pan) {
                    applyPan(viewport: geo.size.width)
                }
                .onChange(of: workspaceIndex) {
                    offset = 0
                    scrollToFocus(id: currentFocusedID(), viewport: geo.size.width)
                }
            }
        }
        .clipped()
    }

    private func currentFocusedID() -> UUID? {
        strip.paneList.first { $0.focused }?.id
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
                    if modifierState.commandHeld {
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

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.ghosttySurfaceId])
    }

    func dropEntered(info: DropInfo) {
        zone = .calculate(at: info.location, in: viewSize)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard zone != nil else { return DropProposal(operation: .forbidden) }
        zone = .calculate(at: info.location, in: viewSize)
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) { zone = nil }

    func performDrop(info: DropInfo) -> Bool {
        let dropZone = TerminalSplitDropZone.calculate(at: info.location, in: viewSize)
        zone = nil
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
