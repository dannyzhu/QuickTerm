import SwiftUI

/// A single operation within the split tree.
///
/// Rather than binding the split tree (which is immutable), any mutable operations are
/// exposed via this enum to the embedder to handle.
enum TerminalSplitOperation {
    case resize(Resize)
    case drop(Drop)

    struct Resize {
        let node: SplitTree<Ghostty.SurfaceView>.Node
        let ratio: Double
    }

    struct Drop {
        /// The surface being dragged.
        let payload: Ghostty.SurfaceView

        /// The surface it was dragged onto
        let destination: Ghostty.SurfaceView

        /// The zone it was dropped to determine how to split the destination.
        let zone: TerminalSplitDropZone
    }
}

struct TerminalSplitTreeView: View {
    let tree: SplitTree<Ghostty.SurfaceView>
    let action: (TerminalSplitOperation) -> Void
    /// QuickTerm：刚分裂出的新 pane（其所在的新分裂节点播放局部收缩/渐显动效）
    var appearingPane: UUID? = nil
    /// QuickTerm：正在淡出的 pane（其父分裂节点播放收拢动效、叶子渐隐）
    var closingPanes: Set<UUID> = []

    var body: some View {
        if let node = tree.zoomed ?? tree.root {
            TerminalSplitSubtreeView(
                node: node,
                isRoot: node == tree.root,
                action: action,
                appearingPane: appearingPane,
                closingPanes: closingPanes)
            // QuickTerm：不再对整棵树做 .id(structuralIdentity)——那会让任何结构变化重建
            // 全部 pane（全应用闪屏、每个 pane 重播弹入、FR 视图脱离窗口）。上游 issue 7546
            // 担心的"同一位置换了 surface 却复用视图"由叶子的 .id(surface.id) 解决，
            // 结构变化只重建受影响的子树。
        }
    }
}

private struct TerminalSplitSubtreeView: View {
    let node: SplitTree<Ghostty.SurfaceView>.Node
    var isRoot: Bool = false
    let action: (TerminalSplitOperation) -> Void
    /// QuickTerm：刚分裂出的新 pane id（传给分裂分支视图决定是否播放进场动效）
    var appearingPane: UUID? = nil
    var closingPanes: Set<UUID> = []

    var body: some View {
        switch node {
        case .leaf(let leafView):
            TerminalSplitLeaf(surfaceView: leafView, isSplit: !isRoot, action: action,
                              closing: closingPanes.contains(leafView.id))
                .id(leafView.id)   // 同一位置换了 surface 时重建视图（见上游 issue 7546）

        case .split:
            // 分裂分支放在独立视图里：叶子原位变成分裂时它是全新 SwiftUI 身份，
            // 进场动效的 State(initialValue:) 才会生效（放在本视图上会沿用叶子时期的旧状态）
            SplitBranchView(node: node, action: action, appearingPane: appearingPane,
                            closingPanes: closingPanes)
        }
    }
}

/// QuickTerm：分裂节点渲染 + 新分裂的局部进场动效 + 关闭子叶的局部收拢动效。
/// 进场：原 pane 从占满收缩到 ratio（真实几何，随槽位缩小），新 pane 内容按**最终尺寸**布局、
/// 随槽位扩大被"揭开"并渐显（不经历中间宽度 → 新 shell 不会以 1 列 PTY 启动）。
/// 关闭（对称）：关闭方的槽位收拢到 0（内容钉在关闭前尺寸、原地被裁掉，叶子自身渐隐），
/// 幸存子树钉在**最终尺寸**（占满本节点）从近端被揭开；动效到点后控制器才真正删节点，
/// 幸存者重挂时尺寸不变、不再重排。
/// `animating` / `closingSide` 在首次出现时锁存，之后模型清除标记不会打断在途动画。
private struct SplitBranchView: View {
    @EnvironmentObject var ghostty: Ghostty.App
    // 1pt 分隔细线按 divider-opacity 半透明
    @EnvironmentObject var theme: ThemeManager

    let node: SplitTree<Ghostty.SurfaceView>.Node
    let action: (TerminalSplitOperation) -> Void
    let appearingPane: UUID?
    let closingPanes: Set<UUID>

    @State private var animating: Bool       // 锁存：本节点是否播放进场动效
    @State private var progress: CGFloat     // 0 = 原 pane 占满、新 pane 不可见；1 = 到位
    @State private var settled: Bool         // 动画结束：解除新 pane 的尺寸钉住
    @State private var closingSide: ClosingSide?      // 锁存：哪一侧直接子叶在关闭
    @State private var closingLeaf: UUID?             // 锁存：关闭中的那片叶（判定锁存是否仍有效）
    @State private var closeProgress: CGFloat = 0     // 0 = 正常几何；1 = 关闭方槽位收拢完毕
    @State private var closingStartSize: CGSize?      // 关闭方在关闭前的尺寸（钉住用）

    enum ClosingSide { case left, right }

    /// 已播过（或已直接到位）收拢的关闭叶：某分裂视图接手一片叶时据此决定是重播 0.28s 还是直接到位。
    /// 只看"上一轮 closingPanes 里有没有"不够——一个分裂节点同时有两片叶在关闭时只锁存一片，
    /// 另一片只渐隐、未收拢，晋升到父节点时才是它第一次收拢。
    private static var collapsed = Set<UUID>()

    /// 直接子叶身份 + 关闭集合：任一变化都要重新评估锁存（节点被兄弟子树顶替 / 新的关闭开始）
    private struct CloseKey: Equatable {
        let leftLeaf: UUID?
        let rightLeaf: UUID?
        let closing: Set<UUID>

        init(node: SplitTree<Ghostty.SurfaceView>.Node, closing: Set<UUID>) {
            if case .split(let split) = node {
                leftLeaf = { if case .leaf(let v) = split.left { return v.id } else { return nil } }()
                rightLeaf = { if case .leaf(let v) = split.right { return v.id } else { return nil } }()
            } else {
                leftLeaf = nil
                rightLeaf = nil
            }
            self.closing = closing
        }

        /// 哪一侧直接子叶在关闭（右/下优先）
        var pending: (side: ClosingSide, leaf: UUID)? {
            if let r = rightLeaf, closing.contains(r) { return (.right, r) }
            if let l = leftLeaf, closing.contains(l) { return (.left, l) }
            return nil
        }

        func isDirectChild(_ leaf: UUID) -> Bool { leaf == leftLeaf || leaf == rightLeaf }
    }

    init(node: SplitTree<Ghostty.SurfaceView>.Node,
         action: @escaping (TerminalSplitOperation) -> Void,
         appearingPane: UUID?,
         closingPanes: Set<UUID> = []) {
        self.node = node
        self.action = action
        self.appearingPane = appearingPane
        self.closingPanes = closingPanes
        let anim = Self.isAppearingSplit(node, appearingPane)
        _animating = State(initialValue: anim)
        _progress = State(initialValue: anim ? 0 : 1)
        _settled = State(initialValue: !anim)
    }

    private static func isAppearingSplit(_ node: SplitTree<Ghostty.SurfaceView>.Node, _ id: UUID?) -> Bool {
        guard let id, case .split(let split) = node, case .leaf(let v) = split.right else { return false }
        return v.id == id
    }

    var body: some View {
        if case .split(let split) = node {
            let splitViewDirection: SplitViewDirection = switch split.direction {
            case .horizontal: .horizontal
            case .vertical: .vertical
            }
            let key = CloseKey(node: node, closing: closingPanes)
            // 锁存只在"锁存的叶仍是本节点的直接子叶"时生效：关闭结束、兄弟子树顶到本视图位置
            // （SwiftUI 复用同位置的 .split 视图与其 @State）时，派生值立刻回到正常几何，不等复位。
            let latchedValid = closingLeaf.map(key.isDirectChild) ?? false
            let side: ClosingSide? = latchedValid ? closingSide : nil
            GeometryReader { geo in
                SplitView(
                    splitViewDirection,
                    .init(get: {
                        let ratio = CGFloat(split.ratio)
                        // 进场动效期：从"原 pane 占满"(1) 收缩到 ratio
                        var r = animating ? ratio * progress + (1 - progress) : ratio
                        // 关闭动效期：关闭方槽位收拢到 0，幸存方长满
                        switch side {
                        case .right: r += (1 - r) * closeProgress
                        case .left: r *= (1 - closeProgress)
                        case nil: break
                        }
                        return r
                    }, set: {
                        action(.resize(.init(node: node, ratio: $0)))
                    }),
                    dividerColor: ghostty.config.splitDividerColor.opacity(theme.effectiveDividerOpacity),
                    resizeIncrements: .init(width: 1, height: 1),
                    left: {
                        // 关闭右/下孩子：左/上孩子是幸存者，钉在最终尺寸（占满本节点）、左上对齐，
                        // 槽位扩大时从近端揭开；一直钉到本节点被删（重挂时尺寸不变）。
                        // 关闭左/上孩子：它自己是关闭方，钉在关闭前尺寸、左上对齐，槽位收拢时被裁掉。
                        // 修饰链保持同型（frame(nil) = 不约束），避免切换时重建子视图。
                        let size: CGSize? = switch side {
                        case .right: geo.size
                        case .left: closingStartSize
                        case nil: nil
                        }
                        TerminalSplitSubtreeView(node: split.left, action: action,
                                                 appearingPane: appearingPane, closingPanes: closingPanes)
                            .frame(width: size?.width, height: size?.height, alignment: .topLeading)
                            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity,
                                   alignment: .topLeading)
                            .clipped()
                            // 动效期不响应鼠标：clipped 只裁视觉，钉在最终尺寸的幸存者
                            // 溢出到关闭方槽位的部分仍可被点中/悬停而抢焦点
                            .allowsHitTesting(side == nil)
                    },
                    right: {
                        // 进场动效期把新 pane 钉在最终尺寸（左上对齐、按槽位裁剪）= 揭开效果；结束后解除钉住。
                        // 关闭左/上孩子：右/下孩子是幸存者，钉在最终尺寸、右下对齐（内容留在最终位置，
                        // 槽位向左/上扩大时从近端揭开）。关闭自己：钉在关闭前尺寸、右下对齐（原地被盖住）。
                        let pin = animating && !settled
                        let final = finalRightSize(total: geo.size, split: split)
                        let size: CGSize? = switch side {
                        case .left: geo.size
                        case .right: closingStartSize
                        case nil: pin ? final : nil
                        }
                        let align: Alignment = side == nil ? .topLeading : .bottomTrailing
                        TerminalSplitSubtreeView(node: split.right, action: action,
                                                 appearingPane: appearingPane, closingPanes: closingPanes)
                            .frame(width: size?.width, height: size?.height, alignment: align)
                            // min+max 同给：frame 无条件采用槽位提议尺寸，clipped 才裁到槽位、
                            // 对齐才生效（只给 max 时子视图大于提议会撑开并居中溢出）
                            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity,
                                   alignment: align)
                            .clipped()
                            .opacity(animating ? progress : 1)
                            .allowsHitTesting(side == nil)
                    },
                    onEqualize: {
                        guard let surface = node.leftmostLeaf().surface else { return }
                        ghostty.splitEqualize(surface: surface)
                    }
                )
                .onChange(of: key, initial: true) { _, key in
                    // 1) 锁存的叶已不是直接子叶（关闭结束/本视图被兄弟子树顶替复用）→ 复位，
                    //    让本视图能播放下一次关闭
                    if let leaf = closingLeaf, !key.isDirectChild(leaf) {
                        closingLeaf = nil
                        closingSide = nil
                        closingStartSize = nil
                        closeProgress = 0
                    }
                    // 2) 新的关闭 → 锁存一次并启动动画；之后模型清掉 closingPanes（flush/到点）
                    //    不回退在途动画
                    guard closingLeaf == nil, let pending = key.pending else { return }
                    closingLeaf = pending.leaf
                    closingSide = pending.side
                    closingStartSize = childSize(pending.side, total: geo.size, split: split)
                    // 这片叶的收拢若早已在（被顶替掉的）子分裂视图里播放过（本视图复位后接手），
                    // 直接到位，不把幸存者弹回去重播一遍
                    let alreadyCollapsed = Self.collapsed.contains(pending.leaf)
                    Self.collapsed.insert(pending.leaf)
                    if alreadyCollapsed {
                        closeProgress = 1
                    } else {
                        withAnimation(.easeOut(duration: 0.28)) { closeProgress = 1 }
                    }
                }
            }
            .onAppear {
                guard animating, progress < 1 else { return }
                DispatchQueue.main.async {
                    withAnimation(.easeOut(duration: 0.28), completionCriteria: .logicallyComplete) {
                        progress = 1
                    } completion: {
                        settled = true
                    }
                }
            }
        }
    }

    /// 新 pane（右/下孩子）的最终尺寸——与 SplitView.rightRect 同算法（可视线宽 1、增量 1）
    private func finalRightSize(total: CGSize, split: SplitTree<Ghostty.SurfaceView>.Node.Split) -> CGSize {
        let ratio = CGFloat(split.ratio)
        switch split.direction {
        case .horizontal:
            var lw = total.width * ratio - 0.5
            lw -= lw.truncatingRemainder(dividingBy: 1)
            return CGSize(width: max(total.width - (lw + 0.5), 1), height: total.height)
        case .vertical:
            var lh = total.height * ratio - 0.5
            lh -= lh.truncatingRemainder(dividingBy: 1)
            return CGSize(width: total.width, height: max(total.height - (lh + 0.5), 1))
        }
    }

    /// 某一侧孩子当前（按 ratio）的尺寸——与 SplitView.leftRect/rightRect 同算法
    /// （分隔线 1pt 居中于边界：左/上取整后即其尺寸，右/下 = 总量 − (左 + 0.5)），
    /// 钉住时才不会比现有槽位差 0.5pt 触发一次无谓的 PTY 重排
    private func childSize(_ side: ClosingSide, total: CGSize,
                           split: SplitTree<Ghostty.SurfaceView>.Node.Split) -> CGSize {
        let ratio = CGFloat(split.ratio)
        switch (side, split.direction) {
        case (.right, _):
            return finalRightSize(total: total, split: split)
        case (.left, .horizontal):
            var lw = total.width * ratio - 0.5
            lw -= lw.truncatingRemainder(dividingBy: 1)
            return CGSize(width: max(lw, 1), height: total.height)
        case (.left, .vertical):
            var lh = total.height * ratio - 0.5
            lh -= lh.truncatingRemainder(dividingBy: 1)
            return CGSize(width: total.width, height: max(lh, 1))
        }
    }
}

private struct TerminalSplitLeaf: View {
    @EnvironmentObject var theme: ThemeManager   // QuickTerm：dwindle 留白（dwindle-gap）
    let surfaceView: Ghostty.SurfaceView
    let isSplit: Bool
    let action: (TerminalSplitOperation) -> Void
    /// QuickTerm：关闭中 → 渐隐并停止响应鼠标（悬停不再夺焦点）
    var closing: Bool = false
    /// 渐隐由状态驱动而非直接绑 closing：一出生就 closing 的叶（flush 后同轮换了结构身份）
    /// 没有值变化可动画，会直接不可见
    @State private var faded = false

    @State private var dropState: DropState = .idle
    @State private var isSelfDragging: Bool = false
    // QuickTerm：⌘ 按住状态（浮出拖拽源）
    @ObservedObject private var modifierState = ModifierState.shared
    @State private var dragSourceDragging: Bool = false
    @State private var dragSourceHovering: Bool = false

    var body: some View {
        GeometryReader { geometry in
            // QuickTerm 裁剪：InspectableSurface（inspector 分屏包装）→ 纯 SurfaceWrapper
            Ghostty.SurfaceWrapper(
                surfaceView: surfaceView,
                isSplit: isSplit)
            .background {
                // If we're dragging ourself, we hide the entire drop zone. This makes
                // it so that a released drop animates back to its source properly
                // so it is a proper invalid drop zone.
                if !isSelfDragging {
                    Color.clear
                        .onDrop(of: [.ghosttySurfaceId], delegate: SplitDropDelegate(
                            dropState: $dropState,
                            viewSize: geometry.size,
                            destinationSurface: surfaceView,
                            action: action
                        ))
                }
            }
            .overlay {
                if !isSelfDragging, case .dropping(let zone) = dropState {
                    zone.overlay(in: geometry)
                        .allowsHitTesting(false)
                }
            }
            .overlay {
                // QuickTerm（spec §4.2）：按住 ⌘ 时整个 pane 成为拖拽源——
                // 拖到目标中心=交换、边缘=分裂插入；松开 ⌘ 即消失，不影响正常鼠标操作
                if modifierState.commandHeld {
                    Ghostty.SurfaceDragSource(
                        surfaceView: surfaceView,
                        isDragging: $dragSourceDragging,
                        isHovering: $dragSourceHovering)
                }
            }
            .onPreferenceChange(Ghostty.DraggingSurfaceKey.self) { value in
                isSelfDragging = value == surfaceView.id
                if isSelfDragging {
                    dropState = .idle
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Terminal pane")
            // QuickTerm：pane 视觉（焦点边框 / gaps_in / 弹入动画），见 PaneChrome.swift
            .modifier(PaneChrome(surfaceView: surfaceView, inset: theme.dwindleGap))
            // 关闭动效：渐隐（几何收拢由父 SplitBranchView 负责；根单叶只渐隐）
            .opacity(faded ? 0 : 1)
            .allowsHitTesting(!closing)
            .onChange(of: closing, initial: true) { _, closing in
                if !closing { faded = false; return }   // 身份复用兜底：不在关闭中就必须可见
                guard !faded else { return }
                withAnimation(.easeOut(duration: 0.28)) { faded = true }
            }
        }
    }

    private enum DropState: Equatable {
        case idle
        case dropping(TerminalSplitDropZone)
    }

    private struct SplitDropDelegate: DropDelegate {
        @Binding var dropState: DropState
        let viewSize: CGSize
        let destinationSurface: Ghostty.SurfaceView
        let action: (TerminalSplitOperation) -> Void

        func validateDrop(info: DropInfo) -> Bool {
            info.hasItemsConforming(to: [.ghosttySurfaceId])
        }

        func dropEntered(info: DropInfo) {
            dropState = .dropping(.calculate(at: info.location, in: viewSize))
        }

        func dropUpdated(info: DropInfo) -> DropProposal? {
            // For some reason dropUpdated is sent after performDrop is called
            // and we don't want to reset our drop zone to show it so we have
            // to guard on the state here.
            guard case .dropping = dropState else { return DropProposal(operation: .forbidden) }
            dropState = .dropping(.calculate(at: info.location, in: viewSize))
            return DropProposal(operation: .move)
        }

        func dropExited(info: DropInfo) {
            dropState = .idle
        }

        func performDrop(info: DropInfo) -> Bool {
            let zone = TerminalSplitDropZone.calculate(at: info.location, in: viewSize)
            dropState = .idle

            // Load the dropped surface asynchronously using Transferable
            let providers = info.itemProviders(for: [.ghosttySurfaceId])
            guard let provider = providers.first else { return false }

            // Capture action before the async closure
            _ = provider.loadTransferable(type: Ghostty.SurfaceView.self) { [weak destinationSurface] result in
                switch result {
                case .success(let sourceSurface):
                    DispatchQueue.main.async {
                        // Don't allow dropping on self
                        guard let destinationSurface else { return }
                        guard sourceSurface !== destinationSurface else { return }
                        action(.drop(.init(payload: sourceSurface, destination: destinationSurface, zone: zone)))
                    }

                case .failure:
                    break
                }
            }

            return true
        }
    }
}

enum TerminalSplitDropZone: String, Equatable {
    case top
    case bottom
    case left
    case right
    // QuickTerm 扩展（spec §4.2）：拖到目标中心 = 交换位置
    case center

    /// Determines which drop zone the cursor is in based on proximity to edges.
    ///
    /// Divides the view into four triangular regions by drawing diagonals from
    /// corner to corner. The drop zone is determined by which edge the cursor
    /// is closest to, creating natural triangular hit regions for each side.
    /// QuickTerm：中央 40%×40% 区域为 .center（交换）。
    static func calculate(at point: CGPoint, in size: CGSize) -> TerminalSplitDropZone {
        let relX = point.x / size.width
        let relY = point.y / size.height

        if (0.3...0.7).contains(relX), (0.3...0.7).contains(relY) {
            return .center
        }

        let distToLeft = relX
        let distToRight = 1 - relX
        let distToTop = relY
        let distToBottom = 1 - relY

        let minDist = min(distToLeft, distToRight, distToTop, distToBottom)

        if minDist == distToLeft { return .left }
        if minDist == distToRight { return .right }
        if minDist == distToTop { return .top }
        return .bottom
    }

    @ViewBuilder
    func overlay(in geometry: GeometryProxy) -> some View {
        let overlayColor = Color.accentColor.opacity(0.3)

        switch self {
        case .top:
            VStack(spacing: 0) {
                Rectangle()
                    .fill(overlayColor)
                    .frame(height: geometry.size.height / 2)
                Spacer()
            }
        case .bottom:
            VStack(spacing: 0) {
                Spacer()
                Rectangle()
                    .fill(overlayColor)
                    .frame(height: geometry.size.height / 2)
            }
        case .left:
            HStack(spacing: 0) {
                Rectangle()
                    .fill(overlayColor)
                    .frame(width: geometry.size.width / 2)
                Spacer()
            }
        case .right:
            HStack(spacing: 0) {
                Spacer()
                Rectangle()
                    .fill(overlayColor)
                    .frame(width: geometry.size.width / 2)
            }
        case .center:
            Rectangle()
                .fill(overlayColor)
                .padding(geometry.size.width * 0.15)
        }
    }
}
