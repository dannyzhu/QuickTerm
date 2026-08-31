import AppKit

// QuickTerm 对 SplitTree 的平铺语义扩展（dwindle / 交换 / 切分裂方向）。
// SplitTree 本体为 Ghostty 移植（MIT），见 Sources/GhosttyEmbed/Features/Splits/SplitTree.swift。

extension SplitTree {
    /// Omarchy dwindle（force_split=2）语义：焦点 pane 宽 > 高 → 新 pane 分裂到右侧，
    /// 否则分裂到下方。
    func dwindleDirection(for view: ViewType) -> NewDirection {
        let f = view.frame
        return f.width > f.height ? .right : .down
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
