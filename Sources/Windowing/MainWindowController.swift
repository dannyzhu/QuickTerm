import AppKit
import GhosttyKit
import SwiftUI

/// QuickTerm 主窗口控制器：SplitTree 状态的唯一拥有者（spec §3）。
/// 继承 GhosttyEmbed 的 BaseTerminalController shim，使嵌入层的
/// focus-follows-mouse / 分屏判定等路径直接生效。
final class MainWindowController: BaseTerminalController {
    let model = WorkspaceModel()
    let ghostty: Ghostty.App
    let keybindings = KeybindingMap()
    private var keyMonitor: Any?
    private var mouseMonitor: Any?
    private var resizeTarget: Ghostty.SurfaceView?

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

        // WM 级组合键：在事件分发前拦截；未命中一律放行给 surface（终端级键不受影响）
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let window = self.window, event.window === window,
                  let hit = self.keybindings.action(for: event) else { return event }
            self.perform(hit.action, precise: hit.precise)
            return nil
        }

        // ⌘ 状态跟踪（拖拽源浮层）+ ⌘+右键拖拽调整 pane 大小（spec §4.2）
        mouseMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.flagsChanged, .rightMouseDown, .rightMouseDragged, .rightMouseUp]
        ) { [weak self] event in
            guard let self else { return event }
            if event.type == .flagsChanged {
                ModifierState.shared.commandHeld = event.modifierFlags.contains(.command)
                return event
            }
            guard event.window === self.window,
                  event.modifierFlags.contains(.command) else { return event }
            switch event.type {
            case .rightMouseDown:
                self.resizeTarget = self.paneUnderPointer(event)
                return self.resizeTarget == nil ? event : nil
            case .rightMouseDragged:
                guard let pane = self.resizeTarget else { return event }
                self.resizeByDrag(pane: pane, dx: event.deltaX, dy: event.deltaY)
                return nil
            case .rightMouseUp:
                let hadTarget = self.resizeTarget != nil
                self.resizeTarget = nil
                return hadTarget ? nil : event
            default:
                return event
            }
        }
    }

    private func paneUnderPointer(_ event: NSEvent) -> Ghostty.SurfaceView? {
        guard let content = window?.contentView else { return nil }
        var v = content.hitTest(content.convert(event.locationInWindow, from: nil))
        while let cur = v {
            if let s = cur as? Ghostty.SurfaceView { return s }
            v = cur.superview
        }
        // 命中覆盖层等兄弟视图时按几何位置回退查找
        return paneList.first {
            $0.window === window && $0.convert($0.bounds, to: nil).contains(event.locationInWindow)
        }
    }

    private func resizeByDrag(pane: Ghostty.SurfaceView, dx: CGFloat, dy: CGFloat) {
        guard let node = model.tree.root?.node(view: pane),
              let bounds = window?.contentLayoutRect else { return }
        let amount = UInt16(min(max(abs(dx) >= abs(dy) ? abs(dx) : abs(dy), 1), 200))
        let direction: SplitTree<Ghostty.SurfaceView>.Spatial.Direction =
            abs(dx) >= abs(dy) ? (dx > 0 ? .right : .left) : (dy > 0 ? .down : .up)
        model.tree = (try? model.tree.resizing(
            node: node, by: amount, in: direction, with: bounds)) ?? model.tree
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    deinit {
        NotificationCenter.default.removeObserver(self)
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
    }

    // MARK: WM 动作（spec §5.1 全表）

    func perform(_ action: WMAction, precise: Bool = false) {
        switch action {
        case .newTerminal:
            let pane = newSurface(inheritingFrom: focusedSurface)
            if model.tree.isEmpty {
                model.tree = SplitTree(view: pane)
            } else if let focused = focusedSurface,
                      let t = try? model.tree.inserting(
                        view: pane, at: focused,
                        direction: model.tree.dwindleDirection(for: focused)) {
                model.tree = t
            }
            Ghostty.moveFocus(to: pane)

        case .closePane:
            if let focused = focusedSurface { closePane(focused) }

        case .focusLeft: moveFocus(.left)
        case .focusRight: moveFocus(.right)
        case .focusUp: moveFocus(.up)
        case .focusDown: moveFocus(.down)

        case .swapLeft: swapFocused(.left)
        case .swapRight: swapFocused(.right)
        case .swapUp: swapFocused(.up)
        case .swapDown: swapFocused(.down)

        case .toggleSplitDirection:
            guard let focused = focusedSurface else { return }
            model.tree = (try? model.tree.togglingSplitDirection(around: focused)) ?? model.tree

        case .toggleZoom:
            guard let focused = focusedSurface,
                  let node = model.tree.root?.node(view: focused) else { return }
            // zoom = 只渲染该子树；再按取消（spec §3.2）
            model.tree = SplitTree(
                root: model.tree.root,
                zoomed: model.tree.zoomed == node ? nil : node)

        case .equalize:
            model.tree = model.tree.equalized()

        case .resizeLeft: resizeFocused(.left, precise: precise)
        case .resizeRight: resizeFocused(.right, precise: precise)
        case .resizeUp: resizeFocused(.up, precise: precise)
        case .resizeDown: resizeFocused(.down, precise: precise)

        case .cyclePaneNext: cycleFocus(.next)
        case .cyclePanePrev: cycleFocus(.previous)

        case .gotoWorkspace1, .gotoWorkspace2, .gotoWorkspace3, .gotoWorkspace4, .gotoWorkspace5:
            if let i = action.workspaceIndex { switchWorkspace(i) }
        case .moveToWorkspace1, .moveToWorkspace2, .moveToWorkspace3, .moveToWorkspace4, .moveToWorkspace5:
            if let i = action.workspaceIndex { moveFocusedPane(to: i) }
        case .toggleBar:
            model.barVisible.toggle()
        }
    }

    // MARK: 工作区（spec §5.2）

    func switchWorkspace(_ index: Int) {
        guard index != model.activeIndex else { return }
        model.switchTo(index)  // 值语义切换：瞬时、无动画（忠实 Omarchy）
        if let focused = focusedSurface {
            Ghostty.moveFocus(to: focused)
        }
    }

    /// 把焦点 pane 移到目标工作区并跟随（Cmd+Shift+数字）
    func moveFocusedPane(to index: Int) {
        guard model.trees.indices.contains(index), index != model.activeIndex,
              let focused = focusedSurface,
              let node = model.tree.root?.node(view: focused) else { return }

        // 先算目标树（失败则不动源树）
        let newTarget: SplitTree<Ghostty.SurfaceView>
        if model.trees[index].isEmpty {
            newTarget = SplitTree(view: focused)
        } else if let anchor = model.trees[index].root?.leaves().first,
                  let t = try? model.trees[index].inserting(
                    view: focused, at: anchor,
                    direction: model.trees[index].dwindleDirection(for: anchor)) {
            newTarget = t
        } else {
            return
        }

        model.tree = model.tree.removing(node)
        model.trees[index] = newTarget
        model.switchTo(index)
        Ghostty.moveFocus(to: focused)
    }

    private func moveFocus(_ direction: SplitTree<Ghostty.SurfaceView>.Spatial.Direction) {
        guard let focused = focusedSurface,
              let node = model.tree.root?.node(view: focused),
              let target = model.tree.focusTarget(for: .spatial(direction), from: node) else { return }
        Ghostty.moveFocus(to: target, from: focused)
    }

    private func swapFocused(_ direction: SplitTree<Ghostty.SurfaceView>.Spatial.Direction) {
        guard let focused = focusedSurface,
              let node = model.tree.root?.node(view: focused),
              let target = model.tree.focusTarget(for: .spatial(direction), from: node),
              let swapped = try? model.tree.swapping(focused, target) else { return }
        model.tree = swapped
        Ghostty.moveFocus(to: focused)
    }

    private func resizeFocused(_ direction: SplitTree<Ghostty.SurfaceView>.Spatial.Direction, precise: Bool) {
        guard let focused = focusedSurface,
              let node = model.tree.root?.node(view: focused),
              let bounds = window?.contentLayoutRect else { return }
        model.tree = (try? model.tree.resizing(
            node: node, by: precise ? 10 : 100, in: direction, with: bounds)) ?? model.tree
    }

    private func cycleFocus(_ direction: SplitTree<Ghostty.SurfaceView>.FocusDirection) {
        guard let focused = focusedSurface,
              let node = model.tree.root?.node(view: focused),
              let target = model.tree.focusTarget(for: direction, from: node) else { return }
        Ghostty.moveFocus(to: target, from: focused)
    }

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
            // 仅当所有工作区皆空才关窗口；否则停留在空工作区（可 Cmd+Return 重开）
            if model.trees.allSatisfy(\.isEmpty) { window?.close() }
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
        // 中心 = 交换位置（spec §4.2）
        if drop.zone == .center {
            if let swapped = try? model.tree.swapping(drop.payload, drop.destination) {
                model.tree = swapped
                Ghostty.moveFocus(to: drop.payload)
            }
            return
        }
        let direction: SplitTree<Ghostty.SurfaceView>.NewDirection = switch drop.zone {
        case .top: .up
        case .bottom: .down
        case .left: .left
        case .right: .right
        case .center: .right  // 已在上方返回；穷尽 switch
        }
        guard let sourceNode = model.tree.root?.node(view: drop.payload) else { return }
        let without = model.tree.removing(sourceNode)
        if let newTree = try? without.inserting(view: drop.payload, at: drop.destination, direction: direction) {
            model.tree = newTree
            Ghostty.moveFocus(to: drop.payload)
        }
    }
}
