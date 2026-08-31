import AppKit
import GhosttyKit
import SwiftUI

/// QuickTerm 主窗口控制器：SplitTree 状态的唯一拥有者（spec §3）。
/// 继承 GhosttyEmbed 的 BaseTerminalController shim，使嵌入层的
/// focus-follows-mouse / 分屏判定等路径直接生效。
final class MainWindowController: BaseTerminalController {
    let model = WorkspaceModel()
    let ghostty: Ghostty.App

    /// 悬停即焦点（spec §4.2，忠实 Hyprland focus_follows_mouse）。
    /// 嵌入层 SurfaceView.mouseMoved 会查此标志并调用 Ghostty.moveFocus。
    override var focusFollowsMouse: Bool { true }

    override var surfaceTree: SplitTree<Ghostty.SurfaceView> {
        get { model.tree }
        set { model.tree = newValue }
    }

    /// 树中全部 pane（先序叶遍历）
    var paneList: [Ghostty.SurfaceView] { model.tree.root?.leaves() ?? [] }

    override var focusedSurface: Ghostty.SurfaceView? {
        paneList.first { $0.focused } ?? paneList.first
    }

    init(ghostty: Ghostty.App) {
        self.ghostty = ghostty
        let window = HiddenTitlebarWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1024, height: 720),
            styleMask: [],  // HiddenTitlebarWindow 内部固定样式
            backing: .buffered, defer: false)
        window.title = "QuickTerm"
        super.init(window: window)
        window.windowController = self

        window.contentView = NSHostingView(rootView: RootView(
            model: model, ghostty: ghostty,
            action: { [weak self] op in self?.handleSplitOperation(op) }))

        // 首个 pane
        let first = newSurface(inheritingFrom: nil)
        model.tree = SplitTree(view: first)
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(first)

        // 进程退出 / close 动作 → 移除 pane
        NotificationCenter.default.addObserver(
            self, selector: #selector(ghosttyDidCloseSurface(_:)),
            name: Ghostty.Notification.ghosttyCloseSurface, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    deinit { NotificationCenter.default.removeObserver(self) }

    // MARK: Surface 生命周期

    /// 新建 surface；继承来源 pane 的当前目录（spec §4.1）
    func newSurface(inheritingFrom source: Ghostty.SurfaceView?) -> Ghostty.SurfaceView {
        var config = Ghostty.SurfaceConfiguration()
        config.workingDirectory = source?.pwd
        return Ghostty.SurfaceView(ghostty.app!, baseConfig: config)
    }

    /// 关闭一个 pane：兄弟回收父槽；最后一个 pane 时关窗口。
    func closePane(_ view: Ghostty.SurfaceView, confirmIfNeeded: Bool = true) {
        guard paneList.contains(view) else { return }
        if confirmIfNeeded, view.needsConfirmQuit {
            let alert = NSAlert()
            alert.messageText = "关闭这个终端？"
            alert.informativeText = "其中仍有进程在运行。"
            alert.addButton(withTitle: "关闭")
            alert.addButton(withTitle: "取消")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        removePane(view)
    }

    private func removePane(_ view: Ghostty.SurfaceView) {
        guard let node = model.tree.root?.node(view: view) else { return }
        let wasFocused = view.focused
        model.tree = model.tree.removing(node)  // 放弃引用 → SurfaceView.deinit 释放 surface
        if model.tree.isEmpty {
            window?.close()
        } else if wasFocused, let next = paneList.first {
            Ghostty.moveFocus(to: next)
        }
    }

    @objc private func ghosttyDidCloseSurface(_ notification: Foundation.Notification) {
        guard let view = notification.object as? Ghostty.SurfaceView,
              paneList.contains(view) else { return }
        let processAlive = (notification.userInfo?["process_alive"] as? Bool) ?? false
        closePane(view, confirmIfNeeded: processAlive)
    }

    // MARK: SwiftUI 回调（分隔条拖拽 / 拖放）

    func handleSplitOperation(_ op: TerminalSplitOperation) {
        switch op {
        case .resize(let resize):
            // 分隔条拖拽：以新 ratio 重建该 split（照 Ghostty splitDidResize）
            let resized = resize.node.resizing(to: resize.ratio)
            model.tree = (try? model.tree.replacing(node: resize.node, with: resized)) ?? model.tree
        case .drop(let drop):
            handleDrop(drop)
        }
    }

    private func handleDrop(_ drop: TerminalSplitOperation.Drop) {
        guard drop.payload !== drop.destination else { return }
        let direction: SplitTree<Ghostty.SurfaceView>.NewDirection = switch drop.zone {
        case .top: .up
        case .bottom: .down
        case .left: .left
        case .right: .right
        }
        guard let sourceNode = model.tree.root?.node(view: drop.payload) else { return }
        let without = model.tree.removing(sourceNode)
        if let newTree = try? without.inserting(view: drop.payload, at: drop.destination, direction: direction) {
            model.tree = newTree
            Ghostty.moveFocus(to: drop.payload)
        }
    }
}
