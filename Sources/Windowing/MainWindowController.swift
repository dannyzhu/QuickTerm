import AppKit
import GhosttyKit
import SwiftUI

/// QuickTerm 主窗口控制器：工作区布局状态的唯一拥有者（spec §3 + §4.2-bis）。
/// 继承 GhosttyEmbed 的 BaseTerminalController shim，使嵌入层的
/// focus-follows-mouse / 分屏判定等路径直接生效。
/// 每个 WM 动作按活动工作区布局（scrolling 默认 / dwindle）分派。
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
    private var stripPanSerial = 0

    /// 悬停即焦点（spec §4.2，忠实 Hyprland focus_follows_mouse）。
    override var focusFollowsMouse: Bool { true }

    /// 嵌入层要求的树视图（仅 dwindle 布局有意义；scrolling 返回空树）
    override var surfaceTree: SplitTree<Ghostty.SurfaceView> {
        get {
            if case .dwindle(let tree) = model.layout { return tree }
            return SplitTree()
        }
        set {
            if case .dwindle = model.layout { model.layout = .dwindle(newValue) }
        }
    }

    /// 活动工作区全部 pane
    var paneList: [Ghostty.SurfaceView] { model.layout.paneList }
    /// 全部工作区（含 scratchpad）所有 pane
    var allPanes: [Ghostty.SurfaceView] { model.allPanes }

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
            onScrollingDrop: { [weak self] payload, dest, zone in
                self?.scrollingDrop(payload: payload, destination: dest, zone: zone)
            },
            onSelectWorkspace: { [weak self] i in self?.switchWorkspace(i) },
            onPanelChoose: { [weak self] i in self?.choosePanelItem(i) })
            .environmentObject(themeManager))

        // 主题热切换：overlay 变更 → 引擎 app 级 + 全部 surface 热重载（spec §3.2，< 200ms）
        themeManager.onOverlayChanged = { [weak self] in
            guard let self else { return }
            self.ghostty.reloadConfig(soft: false)
            for pane in self.allPanes {
                if let surface = pane.surface {
                    self.ghostty.reloadConfig(surface: surface, soft: false)
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

        // 状态恢复（spec §4.8）：布局 + 各 pane cwd + 活动工作区；失败则全新开始
        if !AppDelegate.isRunningTests, restoreState() {
            if let focused = focusedSurface {
                window.makeFirstResponder(focused)
            }
        } else {
            let first = newSurface(inheritingFrom: nil)
            model.layout = .scrolling(ScrollingStrip(pane: first))
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

        // ⌘ 状态跟踪（拖拽源浮层）+ ⌘+右键拖拽调整大小（spec §4.2）
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

        // 滚轮：顶栏区域 → 循环工作区（spec §4.4）；
        // 内容区 + scrolling 布局 + 横向为主 → 平移画布（spec §4.2-bis 附带项）
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, let window = self.window, event.window === window,
                  let content = window.contentView else { return event }
            let y = content.convert(event.locationInWindow, from: nil).y
            if self.model.barVisible, y > content.bounds.maxY - 26 {
                let delta = event.scrollingDeltaY + event.scrollingDeltaX
                guard abs(delta) > 0.5 else { return nil }
                let count = self.model.layouts.count
                let next = (self.model.activeIndex + (delta < 0 ? 1 : count - 1)) % count
                self.switchWorkspace(next)
                return nil
            }
            if case .scrolling = self.model.layout,
               abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY),
               abs(event.scrollingDeltaX) > 0.5 || event.phase == .ended || event.momentumPhase == .ended {
                self.stripPanSerial += 1
                self.model.stripPan = .init(
                    delta: event.scrollingDeltaX,
                    ended: event.phase == .ended || event.momentumPhase == .ended,
                    serial: self.stripPanSerial)
                return nil
            }
            return event
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
            followEngine: settings.themeName == "ghostty",
            panePadding: settings.panePadding)
        if let name = settings.themeName, name != "ghostty",
           let theme = themeManager.themes.first(where: { $0.name == name }),
           theme != themeManager.current {
            themeManager.apply(theme)
        }
    }

    // MARK: 状态恢复（spec §4.8；v2 起含每工作区布局类型）

    private static var stateURL: URL {
        EngineOverlay.url.deletingLastPathComponent().appendingPathComponent("state.json")
    }

    struct PersistedState: Codable {
        var version = 2
        var layouts: [WorkspaceLayout]
        var activeIndex: Int
    }

    func saveState() {
        let state = PersistedState(layouts: model.layouts, activeIndex: model.activeIndex)
        if let data = try? JSONEncoder().encode(state) {
            try? data.write(to: Self.stateURL, options: .atomic)
        }
    }

    /// 恢复上次布局（每 pane 按存档 cwd 重开 shell）；旧版本/损坏存档 → false 全新开始
    private func restoreState() -> Bool {
        guard let data = try? Data(contentsOf: Self.stateURL),
              let state = try? JSONDecoder().decode(PersistedState.self, from: data),
              state.version == 2,
              !state.layouts.allSatisfy(\.isEmpty) else { return false }
        model.layouts = state.layouts
        model.setWorkspaceCount(max(model.layouts.count, 1))
        model.activeIndex = min(max(state.activeIndex, 0), model.layouts.count - 1)
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

    /// ⌘+右键拖拽：dwindle 调就近分隔条；scrolling 按横向位移调列宽
    private func resizeByDrag(pane: Ghostty.SurfaceView, dx: CGFloat, dy: CGFloat) {
        switch model.layout {
        case .dwindle(let tree):
            guard let node = tree.root?.node(view: pane),
                  let bounds = window?.contentLayoutRect else { return }
            let amount = UInt16(min(max(abs(dx) >= abs(dy) ? abs(dx) : abs(dy), 1), 200))
            let direction: SplitTree<Ghostty.SurfaceView>.Spatial.Direction =
                abs(dx) >= abs(dy) ? (dx > 0 ? .right : .left) : (dy > 0 ? .down : .up)
            model.layout = .dwindle((try? tree.resizing(
                node: node, by: amount, in: direction, with: bounds)) ?? tree)
        case .scrolling(let strip):
            let viewport = max(window?.contentLayoutRect.width ?? 1000, 1)
            model.layout = .scrolling(strip.resizingWidth(of: pane, delta: dx / viewport))
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    deinit {
        NotificationCenter.default.removeObserver(self)
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
    }

    // MARK: WM 动作（spec §5.1 + §4.2-bis；按活动布局分派）

    func perform(_ action: WMAction, precise: Bool = false) {
        switch action {
        case .newTerminal:
            let pane = newSurface(inheritingFrom: focusedSurface)
            switch model.layout {
            case .scrolling(let strip):
                // 焦点列右侧插入新列（截图 3 语义）
                model.layout = .scrolling(strip.insertingColumnRight(of: focusedSurface, pane: pane))
            case .dwindle(let tree):
                if tree.isEmpty {
                    model.layout = .dwindle(SplitTree(view: pane))
                } else if let focused = focusedSurface,
                          let t = try? tree.inserting(
                            view: pane, at: focused,
                            direction: tree.dwindleDirection(for: focused)) {
                    model.layout = .dwindle(t)
                }
            }
            Ghostty.moveFocus(to: pane, from: focusedSurface)

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
            switch model.layout {
            case .dwindle(let tree):
                model.layout = .dwindle((try? tree.togglingSplitDirection(around: focused)) ?? tree)
            case .scrolling(let strip):
                // Cmd+J：併入左列纵栈 ⇄ 拆出独立列（spec §4.2-bis）
                model.layout = .scrolling(strip.mergingOrSplitting(focused))
                Ghostty.moveFocus(to: focused)
            }

        case .toggleZoom:
            guard let focused = focusedSurface else { return }
            switch model.layout {
            case .dwindle(let tree):
                guard let node = tree.root?.node(view: focused) else { return }
                model.layout = .dwindle(SplitTree(
                    root: tree.root, zoomed: tree.zoomed == node ? nil : node))
            case .scrolling(let strip):
                model.layout = .scrolling(strip.togglingZoom(focused))
            }

        case .equalize:
            switch model.layout {
            case .dwindle(let tree): model.layout = .dwindle(tree.equalized())
            case .scrolling(let strip): model.layout = .scrolling(strip.equalized())
            }

        case .resizeLeft: resizeFocused(.left, precise: precise)
        case .resizeRight: resizeFocused(.right, precise: precise)
        case .resizeUp: resizeFocused(.up, precise: precise)
        case .resizeDown: resizeFocused(.down, precise: precise)

        case .cyclePaneNext: cycleFocus(next: true)
        case .cyclePanePrev: cycleFocus(next: false)

        case .toggleLayout:
            // Cmd+L：dwindle ⇄ scrolling，保 pane 保序（spec §4.2-bis）
            model.layout = model.layout.toggled()
            if let focused = focusedSurface { Ghostty.moveFocus(to: focused) }

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
        case .openSettings:
            openSettingsFile()
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

    // MARK: 非原生全屏（精简版，spec §5.1 Ctrl+Cmd+F）

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
            return false
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

    /// 设置（Cmd+, / 菜单）：打开 QuickTerm config.toml（不存在则先写模板），
    /// 若存在 ~/.config/ghostty/config 一并打开（配置链第 2 层，用户常改）
    private func openSettingsFile() {
        let url = ConfigStore.configURL
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? ConfigStore.template.write(to: url, atomically: true, encoding: .utf8)
        }
        NSWorkspace.shared.open(url)
        let ghosttyConfig = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/ghostty/config")
        if FileManager.default.fileExists(atPath: ghosttyConfig.path) {
            NSWorkspace.shared.open(ghosttyConfig)
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

    /// 把焦点 pane 移到目标工作区并跟随（Cmd+Shift+数字）；插入遵循目标工作区布局
    func moveFocusedPane(to index: Int) {
        guard model.layouts.indices.contains(index), index != model.activeIndex,
              let focused = focusedSurface else { return }

        // 先算目标（失败不动源）
        let newTarget: WorkspaceLayout
        switch model.layouts[index] {
        case .scrolling(let strip):
            newTarget = .scrolling(strip.isEmpty
                ? ScrollingStrip(pane: focused)
                : strip.insertingColumnRight(of: strip.paneList.last, pane: focused))
        case .dwindle(let tree):
            if tree.isEmpty {
                newTarget = .dwindle(SplitTree(view: focused))
            } else if let anchor = tree.root?.leaves().first,
                      let t = try? tree.inserting(
                        view: focused, at: anchor,
                        direction: tree.dwindleDirection(for: anchor)) {
                newTarget = .dwindle(t)
            } else {
                return
            }
        }

        removeFromActiveLayout(focused)
        model.layouts[index] = newTarget
        model.switchTo(index)
        Ghostty.moveFocus(to: focused)
    }

    // MARK: 布局分派的焦点/换位/调整

    private func moveFocus(_ direction: ScrollingStrip.Direction) {
        guard let focused = focusedSurface else { return }
        let target: Ghostty.SurfaceView?
        switch model.layout {
        case .dwindle(let tree):
            guard let node = tree.root?.node(view: focused) else { return }
            target = tree.focusTarget(for: .spatial(direction.spatial), from: node)
        case .scrolling(let strip):
            target = strip.focusTarget(from: focused, direction: direction)
        }
        if let target { Ghostty.moveFocus(to: target, from: focused) }
    }

    private func swapFocused(_ direction: ScrollingStrip.Direction) {
        guard let focused = focusedSurface else { return }
        switch model.layout {
        case .dwindle(let tree):
            guard let node = tree.root?.node(view: focused),
                  let target = tree.focusTarget(for: .spatial(direction.spatial), from: node),
                  let swapped = try? tree.swapping(focused, target) else { return }
            model.layout = .dwindle(swapped)
        case .scrolling(let strip):
            model.layout = .scrolling(strip.swapping(focused, direction: direction))
        }
        Ghostty.moveFocus(to: focused)
    }

    private func resizeFocused(_ direction: ScrollingStrip.Direction, precise: Bool) {
        guard let focused = focusedSurface else { return }
        switch model.layout {
        case .dwindle(let tree):
            guard let node = tree.root?.node(view: focused),
                  let bounds = window?.contentLayoutRect else { return }
            model.layout = .dwindle((try? tree.resizing(
                node: node, by: precise ? 10 : 100, in: direction.spatial, with: bounds)) ?? tree)
        case .scrolling(let strip):
            // 列宽仅横向可调（spec §4.2-bis：↑/↓ 无操作）
            switch direction {
            case .left:
                model.layout = .scrolling(strip.resizingWidth(of: focused, delta: -ScrollingStrip.widthStep))
            case .right:
                model.layout = .scrolling(strip.resizingWidth(of: focused, delta: ScrollingStrip.widthStep))
            case .up, .down:
                break
            }
        }
    }

    private func cycleFocus(next: Bool) {
        guard let focused = focusedSurface else { return }
        let target: Ghostty.SurfaceView?
        switch model.layout {
        case .dwindle(let tree):
            guard let node = tree.root?.node(view: focused) else { return }
            target = tree.focusTarget(for: next ? .next : .previous, from: node)
        case .scrolling(let strip):
            target = strip.linearTarget(from: focused, next: next)
        }
        if let target { Ghostty.moveFocus(to: target, from: focused) }
    }

    // MARK: Surface 生命周期

    /// 新建 surface；继承来源 pane 的当前目录（spec §4.1）
    func newSurface(inheritingFrom source: Ghostty.SurfaceView?) -> Ghostty.SurfaceView {
        var config = Ghostty.SurfaceConfiguration()
        config.workingDirectory = source?.pwd
        return Ghostty.SurfaceView(ghostty.app!, baseConfig: config)
    }

    /// 关闭一个 pane（scrolling 空列删除；dwindle 兄弟回收）；全部工作区皆空才关窗。
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
        let wasFocused = view.focused
        // scrolling：删除前记下左邻（spec：焦点左移）
        var successor: Ghostty.SurfaceView?
        if case .scrolling(let strip) = model.layout {
            successor = strip.focusTarget(from: view, direction: .left)
                ?? strip.focusTarget(from: view, direction: .right)
                ?? strip.focusTarget(from: view, direction: .up)
                ?? strip.focusTarget(from: view, direction: .down)
        }
        removeFromActiveLayout(view)  // 放弃引用 → SurfaceView.deinit 释放 surface
        if model.layout.isEmpty {
            if model.allEmpty, !AppDelegate.isRunningTests {
                window?.close()
            }
        } else if wasFocused, let next = successor ?? paneList.first {
            Ghostty.moveFocus(to: next)
        }
    }

    private func removeFromActiveLayout(_ view: Ghostty.SurfaceView) {
        switch model.layout {
        case .dwindle(let tree):
            guard let node = tree.root?.node(view: view) else { return }
            model.layout = .dwindle(tree.removing(node))
        case .scrolling(let strip):
            model.layout = .scrolling(strip.removing(view))
        }
    }

    @objc private func ghosttyDidCloseSurface(_ notification: Foundation.Notification) {
        guard let view = notification.object as? Ghostty.SurfaceView else { return }
        if view === model.scratchpadSurface {
            model.scratchpadVisible = false
            model.scratchpadSurface = nil
            return
        }
        guard paneList.contains(view) else { return }
        let processAlive = (notification.userInfo?["process_alive"] as? Bool) ?? false
        closePane(view, confirmIfNeeded: processAlive)
    }

    // MARK: SwiftUI 回调（dwindle 分隔条 / 双布局拖放）

    func handleSplitOperation(_ op: TerminalSplitOperation) {
        guard case .dwindle(let tree) = model.layout else { return }
        switch op {
        case .resize(let resize):
            let resized = resize.node.resizing(to: resize.ratio)
            model.layout = .dwindle((try? tree.replacing(node: resize.node, with: resized)) ?? tree)
        case .drop(let drop):
            handleDwindleDrop(drop, tree: tree)
        }
    }

    private func handleDwindleDrop(_ drop: TerminalSplitOperation.Drop,
                                   tree: SplitTree<Ghostty.SurfaceView>) {
        guard drop.payload !== drop.destination else { return }
        if drop.zone == .center {
            if let swapped = try? tree.swapping(drop.payload, drop.destination) {
                model.layout = .dwindle(swapped)
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
        guard let sourceNode = tree.root?.node(view: drop.payload) else { return }
        let without = tree.removing(sourceNode)
        if let newTree = try? without.inserting(
            view: drop.payload, at: drop.destination, direction: direction) {
            model.layout = .dwindle(newTree)
            Ghostty.moveFocus(to: drop.payload)
        }
    }

    /// scrolling 布局拖放（spec §4.2-bis：左右缘=插新列、上下缘=併栈、中心=交换）
    func scrollingDrop(payload: Ghostty.SurfaceView,
                       destination: Ghostty.SurfaceView,
                       zone: TerminalSplitDropZone) {
        guard case .scrolling(let strip) = model.layout else { return }
        model.layout = .scrolling(strip.dropping(payload, on: destination, zone: zone))
        Ghostty.moveFocus(to: payload)
    }
}

private extension ScrollingStrip.Direction {
    var spatial: SplitTree<Ghostty.SurfaceView>.Spatial.Direction {
        switch self {
        case .left: .left
        case .right: .right
        case .up: .up
        case .down: .down
        }
    }
}
