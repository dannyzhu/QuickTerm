import AppKit

// QuickTerm's tiling-semantics extensions to SplitTree (dwindle / swap / flip split direction).
// SplitTree itself is ported from Ghostty (MIT); see
// Sources/GhosttyEmbed/Features/Splits/SplitTree.swift.

extension SplitTree {
    /// Omarchy dwindle semantics (force_split=2): if the focused pane is wider than it is tall the
    /// new pane splits off to the right, otherwise below it. The geometry comes first from the
    /// tree's spatial layout within `bounds` (computed from the ratios) rather than from a view's
    /// frame - during a remount a frame can be stale or zero, which picks the wrong direction.
    func dwindleDirection(for view: ViewType, in bounds: CGSize? = nil) -> NewDirection {
        if let bounds, bounds.width > 0, bounds.height > 0, let root,
           let slot = root.spatial(within: bounds).slots.first(where: { $0.node == .leaf(view: view) }) {
            return slot.bounds.width > slot.bounds.height ? .right : .down
        }
        let f = view.frame
        return f.width > f.height ? .right : .down
    }

    /// The pane to focus after closing a leaf (Hyprland dwindle semantics): the nearest leaf in the
    /// **sibling subtree** that takes over its space - if the closed leaf was the left/top child,
    /// the sibling's first leaf (the "next" one); if it was the right/bottom child, the sibling's
    /// last leaf (the "previous" one).
    /// Returns nil when the root is a lone leaf.
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

    /// Drop semantics (any of the four edges splits beside the target; the center swaps). **Pure
    /// function**: SwiftUI's drag and drop and the control plane's `pane move --where` share this
    /// one implementation, so the landing spot cannot possibly be computed two different ways.
    /// Returning nil means the drop was invalid (same pane, payload not in the tree, or the insert
    /// failed) and the caller must not touch the layout.
    func dropping(_ payload: ViewType, on destination: ViewType,
                  zone: TerminalSplitDropZone) -> Self? {
        guard payload !== destination else { return nil }
        if zone == .center { return try? swapping(payload, destination) }
        let direction: NewDirection = switch zone {
        case .top: .up
        case .bottom: .down
        case .left: .left
        case .right: .right
        case .center: .right   // returned above; here only to make the switch exhaustive
        }
        guard let sourceNode = root?.node(view: payload) else { return nil }
        return try? removing(sourceNode).inserting(view: payload, at: destination, direction: direction)
    }

    /// Swap two leaves (Cmd+Shift+direction, or dropping onto the target's center). The tree's
    /// shape is unchanged; only the leaves trade places.
    func swapping(_ a: ViewType, _ b: ViewType) throws -> Self {
        guard let root,
              let pathA = root.path(to: .leaf(view: a)),
              let pathB = root.path(to: .leaf(view: b)) else {
            throw SplitError.viewNotFound
        }
        let newRoot = try root
            .replacingNode(at: pathA, with: .leaf(view: b))
            .replacingNode(at: pathB, with: .leaf(view: a))
        // A structural change clears zoom (same semantics as inserting/removing)
        return .init(root: newRoot, zoomed: nil)
    }

    /// Flip the direction of the nearest parent split containing the given leaf (Cmd+J). A lone
    /// leaf at the root has no parent split, so this throws.
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
