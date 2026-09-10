import AppKit

// QuickTerm 对 SplitTree 的平铺语义扩展（dwindle / 交换 / 切分裂方向）。
// SplitTree 本体为 Ghostty 移植（MIT），见 Sources/GhosttyEmbed/Features/Splits/SplitTree.swift。

extension SplitTree {
    /// Omarchy dwindle（force_split=2）语义：焦点 pane 宽 > 高 → 新 pane 分裂到右侧，
    /// 否则分裂到下方。几何优先取自树在 bounds 内的空间布局（按 ratio 计算），
    /// 不依赖视图 frame——重挂载期间 frame 可能过期或为零，会选错方向。
    func dwindleDirection(for view: ViewType, in bounds: CGSize? = nil) -> NewDirection {
        if let bounds, bounds.width > 0, bounds.height > 0, let root,
           let slot = root.spatial(within: bounds).slots.first(where: { $0.node == .leaf(view: view) }) {
            return slot.bounds.width > slot.bounds.height ? .right : .down
        }
        let f = view.frame
        return f.width > f.height ? .right : .down
    }

    /// 关闭某叶后应聚焦的 pane（Hyprland dwindle 语义）：接管其空间的**兄弟子树**中最近的叶子——
    /// 自己是左/上孩子 → 兄弟的第一个叶（"下一个"）；是右/下孩子 → 兄弟的最后一个叶（"上一个"）。
    /// 根为单叶时返回 nil。
    func closeSuccessor(of view: ViewType) -> ViewType? {
        guard let root, let found = Self.parentSplit(of: .leaf(view: view), in: root) else { return nil }
        let sibling = found.isLeft ? found.split.right : found.split.left
        let leaves = sibling.leaves()
        return found.isLeft ? leaves.first : leaves.last
    }

    private static func parentSplit(of target: Node, in node: Node) -> (split: Node.Split, isLeft: Bool)? {
        guard case .split(let s) = node else { return nil }
        if s.left == target { return (s, true) }
        if s.right == target { return (s, false) }
        return parentSplit(of: target, in: s.left) ?? parentSplit(of: target, in: s.right)
    }

    /// 拖放语义（左右上下缘 = 在目标旁分裂；中心 = 交换）。**纯函数**：
    /// SwiftUI 的拖放与控制面的 `pane move --where` 共用这一份，落点不可能各算各的。
    /// 返回 nil = 这次拖放无效（同一个 pane / 载荷不在树里 / 插入失败），调用方不得改动布局
    func dropping(_ payload: ViewType, on destination: ViewType,
                  zone: TerminalSplitDropZone) -> Self? {
        guard payload !== destination else { return nil }
        if zone == .center { return try? swapping(payload, destination) }
        let direction: NewDirection = switch zone {
        case .top: .up
        case .bottom: .down
        case .left: .left
        case .right: .right
        case .center: .right   // 已在上方返回；穷尽 switch
        }
        guard let sourceNode = root?.node(view: payload) else { return nil }
        return try? removing(sourceNode).inserting(view: payload, at: destination, direction: direction)
    }

    /// 交换两个叶子的位置（Cmd+Shift+方向 / 拖拽到目标中心）。树形结构不变，仅叶互换。
    func swapping(_ a: ViewType, _ b: ViewType) throws -> Self {
        guard let root,
              let pathA = root.path(to: .leaf(view: a)),
              let pathB = root.path(to: .leaf(view: b)) else {
            throw SplitError.viewNotFound
        }
        let newRoot = try root
            .replacingNode(at: pathA, with: .leaf(view: b))
            .replacingNode(at: pathB, with: .leaf(view: a))
        // 结构性变更清空 zoom（与 inserting/removing 语义一致）
        return .init(root: newRoot, zoomed: nil)
    }

    /// 切换包含指定叶子的最近父 split 的方向（Cmd+J）。根上的孤叶无父 split，抛错。
    func togglingSplitDirection(around view: ViewType) throws -> Self {
        guard let root,
              let leafPath = root.path(to: .leaf(view: view)),
              !leafPath.path.isEmpty else {
            throw SplitError.viewNotFound
        }
        let parentPath = Path(path: Array(leafPath.path.dropLast()))
        guard case .split(let s) = root.node(at: parentPath) else {
            throw SplitError.viewNotFound
        }
        let flipped = Node.Split(
            direction: s.direction == .horizontal ? .vertical : .horizontal,
            ratio: s.ratio,
            left: s.left,
            right: s.right)
        return .init(root: try root.replacingNode(at: parentPath, with: .split(flipped)), zoomed: nil)
    }
}
