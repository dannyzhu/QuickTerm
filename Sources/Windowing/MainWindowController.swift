import AppKit
import GhosttyKit
import SwiftUI

/// QuickTerm 主窗口控制器：SplitTree 状态的唯一拥有者（spec §3）。
/// 继承 GhosttyEmbed 的 BaseTerminalController shim，使嵌入层的
/// focus-follows-mouse / 分屏判定等路径直接生效。
final class MainWindowController: BaseTerminalController {
    let model = WorkspaceModel()
    let ghostty: Ghostty.App
    private(set) var keybindings = KeybindingMap()
    let stats = SystemStatsService()
    let themeManager: ThemeManager
    private var keyMonitor: Any?
    private var mouseMonitor: Any?
    private var scrollMonitor: Any?
    private var resizeTarget: Ghostty.SurfaceView?
    private var configWatcher: ConfigWatcher?
    private var lastConfigContent: String?

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

    init(ghostty: Ghostty.App, themeManager: ThemeManager) {
        self.ghostty = ghostty
        self.themeManager = themeManager
        let window = HiddenTitlebarWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1024, height: 720),
            styleMask: [],  // HiddenTitlebarWindow 内部固定样式
            backing: .buffered, defer: false)
        window.title = "QuickTerm"
        super.init(window: window)
        window.windowController = self

        window.contentView = NSHostingView(rootView: RootView(
            model: model, ghostty: ghostty, stats: stats,
            action: { [weak self] op in self?.handleSplitOperation(op) },
            onSelectWorkspace: { [weak self] i in self?.switchWorkspace(i) },
            onPanelChoose: { [weak self] i in self?.choosePanelItem(i) })
            .environmentObject(themeManager))

        // 主题热切换：overlay 变更 → 引擎 app 级 + 全部 surface 热重载（spec §3.2，< 200ms）
        themeManager.onOverlayChanged = { [weak self] in
            guard let self else { return }
            self.ghostty.reloadConfig(soft: false)
            for tree in self.model.trees {
                for pane in tree.root?.leaves() ?? [] {
                    if let surface = pane.surface {
                        self.ghostty.reloadConfig(surface: surface, soft: false)
                    }
                }
            }
            self.applyAppearance()
        }
        applyAppearance()

        // 配置链第 4 层：config.toml（键位/工作区数/主题/[ghostty] 透传）+ 热重载
        lastConfigContent = (try? String(contentsOf: ConfigStore.configURL, encoding: .utf8)) ?? ""
        applyConfig(ConfigStore.load())
        configWatcher = ConfigWatcher(
            directory: ConfigStore.configURL.deletingLastPathComponent()
        ) { [weak self] in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self?.reloadConfigFile() }
        }

        // 状态恢复（spec §4.8）：树布局 + 各 pane cwd + 活动工作区；失败则全新开始
        if !AppDelegate.isRunningTests, restoreState() {
            if let focused = focusedSurface {
                window.makeFirstResponder(focused)
            }
        } else {
            let first = newSurface(inheritingFrom: nil)
            model.tree = SplitTree(view: first)
            window.makeFirstResponder(first)
        }
        window.center()
        window.makeKeyAndOrderFront(nil)

        // 进程退出 / close 动作 → 移除 pane
        NotificationCenter.default.addObserver(
            self, selector: #selector(ghosttyDidCloseSurface(_:)),
            name: Ghostty.Notification.ghosttyCloseSurface, object: nil)

        // WM 级组合键：在事件分发前拦截；未命中一律放行给 surface（终端级键不受影响）。
        // 浮动面板打开时优先接管 ↑↓/回车/Esc 导航。
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let window = self.window, event.window === window else { return event }
            if self.model.activePanel != nil, self.handlePanelKey(event) { return nil }
            guard let hit = self.keybindings.action(for: event) else { return event }
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

        // 顶栏区域滚轮 → 循环工作区（spec §4.4）
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, let window = self.window, event.window === window,
                  self.model.barVisible, let content = window.contentView else { return event }
            // 顶栏占内容区最顶部 26pt（fullSizeContentView：内容区 = 整个窗口）
            let y = content.convert(event.locationInWindow, from: nil).y
            guard y > content.bounds.maxY - 26 else { return event }
            let delta = event.scrollingDeltaY + event.scrollingDeltaX
            guard abs(delta) > 0.5 else { return nil }
            let count = self.model.trees.count
            let next = (self.model.activeIndex + (delta < 0 ? 1 : count - 1)) % count
            self.switchWorkspace(next)
            return nil
        }
    }

    // MARK: config.toml（配置链第 4 层，spec §4.7）

    private func reloadConfigFile() {
        let content = (try? String(contentsOf: ConfigStore.configURL, encoding: .utf8)) ?? ""
        guard content != lastConfigContent else { return }
        lastConfigContent = content
        applyConfig(ConfigStore.parse(content))
    }

    func applyConfig(_ settings: ConfigStore.Settings) {
        keybindings = KeybindingMap(
            workspaceCount: settings.workspaces,
            overrides: settings.overrides,
            unbound: settings.unbound)
        model.setWorkspaceCount(settings.workspaces)
        themeManager.updateFromConfig(
            passthrough: settings.ghosttyPassthrough,
            followEngine: settings.themeName == "ghostty")
        if let name = settings.themeName, name != "ghostty",
           let theme = themeManager.themes.first(where: { $0.name == name }),
           theme != themeManager.current {
            themeManager.apply(theme)
        }
    }

    // MARK: 状态恢复（spec §4.8）

    private static var stateURL: URL {
        EngineOverlay.url.deletingLastPathComponent().appendingPathComponent("state.json")
    }

    struct PersistedState: Codable {
        var version = 1
        var trees: [SplitTree<Ghostty.SurfaceView>]
        var activeIndex: Int
    }

    func saveState() {
        let state = PersistedState(trees: model.trees, activeIndex: model.activeIndex)
        if let data = try? JSONEncoder().encode(state) {
            try? data.write(to: Self.stateURL, options: .atomic)
        }
    }

    /// 恢复上次的树布局（每叶按存档 cwd 重开 shell）；成功返回 true
    private func restoreState() -> Bool {
        guard let data = try? Data(contentsOf: Self.stateURL),
              let state = try? JSONDecoder().decode(PersistedState.self, from: data),
              state.version == 1,
              !state.trees.allSatisfy(\.isEmpty) else { return false }
        model.trees = state.trees
        model.setWorkspaceCount(max(model.trees.count, 1))
        model.activeIndex = min(max(state.activeIndex, 0), model.trees.count - 1)
        return true
    }

    /// 浅色主题联动（spec §4.5）：窗口外观 + 引擎 color scheme
    private func applyAppearance() {
        let light = themeManager.current.isLight
        window?.appearance = NSAppearance(named: light ? .aqua : .darkAqua)
        if let app = ghostty.app {
            ghostty_app_set_color_scheme(
                app, light ? GHOSTTY_COLOR_SCHEME_LIGHT : GHOSTTY_COLOR_SCHEME_DARK)
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
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
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

        case .gotoWorkspace1, .gotoWorkspace2, .gotoWorkspace3, .gotoWorkspace4, .gotoWorkspace5,
             .gotoWorkspace6, .gotoWorkspace7, .gotoWorkspace8, .gotoWorkspace9, .gotoWorkspace10:
            if let i = action.workspaceIndex { switchWorkspace(i) }
        case .moveToWorkspace1, .moveToWorkspace2, .moveToWorkspace3, .moveToWorkspace4, .moveToWorkspace5,
             .moveToWorkspace6, .moveToWorkspace7, .moveToWorkspace8, .moveToWorkspace9, .moveToWorkspace10:
            if let i = action.workspaceIndex { moveFocusedPane(to: i) }
        case .toggleBar:
            model.barVisible.toggle()

        case .themePicker:
            openPanel(.themes, selection: themeManager.themes.firstIndex(of: themeManager.current) ?? 0)
        case .backgroundMenu:
            // 面板已开 → 直接循环下一张（带回绕）；否则打开背景选择器
            if model.activePanel == .backgrounds {
                themeManager.nextBackground()
                model.panelSelection = themeManager.backgroundIndex
            } else {
                openPanel(.backgrounds, selection: themeManager.backgroundIndex)
            }
        case .toggleOpacity:
            themeManager.toggleOpacity()
        case .toggleGaps:
            themeManager.toggleGaps()

        case .keybindingHelp:
            openPanel(.keybindings)
        case .mainMenu:
            openPanel(.menu)
        case .scratchpad:
            toggleScratchpad()
        case .toggleFullscreen:
            toggleSimpleFullscreen()
        }
    }

    // MARK: Scratchpad（spec §4.1）

    private func toggleScratchpad() {
        if model.scratchpadVisible {
            model.scratchpadVisible = false
            if let focused = focusedSurface { Ghostty.moveFocus(to: focused) }
            return
        }
        if model.scratchpadSurface == nil {
            model.scratchpadSurface = newSurface(inheritingFrom: focusedSurface)
        }
        model.scratchpadVisible = true
        if let scratch = model.scratchpadSurface {
            Ghostty.moveFocus(to: scratch)
        }
    }

    // MARK: 非原生全屏（精简版，spec §5.1 Ctrl+Cmd+F；简化决定见 M4 计划）

    private var savedFrame: NSRect?

    private func toggleSimpleFullscreen() {
        guard let window, let screen = window.screen ?? NSScreen.main else { return }
        if let frame = savedFrame {
            NSApp.presentationOptions = []
            window.setFrame(frame, display: true, animate: false)
            savedFrame = nil
        } else {
            savedFrame = window.frame
            NSApp.presentationOptions = [.autoHideDock, .autoHideMenuBar]
            window.setFrame(screen.frame, display: true, animate: false)
        }
    }

    // MARK: 浮动面板（Walker 风格）

    func openPanel(_ panel: OverlayPanel, selection: Int = 0) {
        if panel == .keybindings {
            model.keybindingRows = keybindings.displayBindings()
        }
        model.activePanel = panel
        model.panelSelection = selection
    }

    private var panelItemCount: Int {
        switch model.activePanel {
        case .themes: themeManager.themes.count
        case .backgrounds: themeManager.current.backgroundURLs.count
        case .menu: MenuEntry.allCases.count
        case .keybindings, nil: 0
        }
    }

    /// 面板键盘导航；返回 true = 已消费
    private func handlePanelKey(_ event: NSEvent) -> Bool {
        switch KeybindingMap.normalizedKey(for: event) {
        case "escape":
            model.activePanel = nil
            return true
        case "up":
            model.panelSelection = max(0, model.panelSelection - 1)
            return true
        case "down":
            model.panelSelection = min(max(0, panelItemCount - 1), model.panelSelection + 1)
            return true
        case "return":
            choosePanelItem(model.panelSelection)
            return true
        default:
            return false  // 其余键（含 WM 组合键）继续走正常链
        }
    }

    func choosePanelItem(_ index: Int) {
        switch model.activePanel {
        case .themes:
            if themeManager.themes.indices.contains(index) {
                themeManager.apply(themeManager.themes[index])
            }
            model.activePanel = nil
        case .backgrounds:
            themeManager.selectBackground(index)
            model.activePanel = nil
        case .menu:
            model.activePanel = nil
            switch MenuEntry(rawValue: index) {
            case .newTerminal: perform(.newTerminal)
            case .themes: perform(.themePicker)
            case .backgrounds: perform(.backgroundMenu)
            case .toggleBar: perform(.toggleBar)
            case .toggleGaps: perform(.toggleGaps)
            case .toggleOpacity: perform(.toggleOpacity)
            case .keybindings: perform(.keybindingHelp)
            case .settings: openSettingsFile()
            case .about: NSApp.orderFrontStandardAboutPanel(nil)
            case nil: break
            }
        case .keybindings, nil:
            model.activePanel = nil
        }
    }

    /// 设置 = 打开 config.toml（不存在则先写模板，spec §4.6 简化决定）
    private func openSettingsFile() {
        let url = ConfigStore.configURL
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? ConfigStore.template.write(to: url, atomically: true, encoding: .utf8)
        }
        NSWorkspace.shared.open(url)
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
            // 仅当所有工作区皆空才关窗口；否则停留在空工作区（可 Cmd+Return 重开）。
            // 测试宿主中不关窗（后续测试仍需窗口）。
            if model.trees.allSatisfy(\.isEmpty), !AppDelegate.isRunningTests {
                window?.close()
            }
        } else if wasFocused, let next = paneList.first {
            Ghostty.moveFocus(to: next)
        }
    }

    @objc private func ghosttyDidCloseSurface(_ notification: Foundation.Notification) {
        guard let view = notification.object as? Ghostty.SurfaceView else { return }
        if view === model.scratchpadSurface {
            // Scratchpad 进程退出：销毁，下次 Cmd+S 重建
            model.scratchpadVisible = false
            model.scratchpadSurface = nil
            return
        }
        guard paneList.contains(view) else { return }
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
