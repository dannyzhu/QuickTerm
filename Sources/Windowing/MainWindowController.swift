import AppKit
import Combine
import GhosttyKit
import SwiftUI
import UniformTypeIdentifiers

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
    private var cancellables = Set<AnyCancellable>()
    private var lastSplitAnimationAt: Date?
    /// 关闭动效时长（与创建动效同源）；到点后才真正从布局移除、释放 surface
    static let closeAnimationDuration: TimeInterval = 0.28
    /// 关闭动效开关（系统"减弱动态效果"时关；测试可显式打开）
    var closeAnimationEnabled: Bool = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    /// 淡出中的 pane 及其预先算好的焦点接班人（关闭开始时树还完整，接班关系才算得出）
    private var pendingCloses: [ObjectIdentifier: PendingClose] = [:]
    /// 文件管理器程序（config `file-manager-command`，默认 yazi）
    var fileManagerCommand = FileManagerLaunch.defaultProgram
    /// 终端里 ⌘+点击的链接开在哪（config link-opener）：browser-pane = 浏览器 pane；system = 系统默认浏览器
    var linkOpener = "browser-pane"
    /// 运行中的文件管理器 pane → 会话（退出时读 cwd 文件决定是否原位开终端；关闭不弹进程确认）
    private var fileManagerSessions: [ObjectIdentifier: FileManagerLaunch.Session] = [:]
    private struct PendingClose {
        let view: PaneView
        let successor: PaneView?
    }
    private var scrollMonitor: Any?
    private var resizeTarget: PaneView?
    /// ⌘+左键在浮动 pane 上的拖动会话：edges 空 = 移动（置顶），否则按边/角缩放
    /// ⌘+左键在浮动 pane 上的拖动会话：按下即开始（置顶 / 光标），拖过阈值才算真拖；抬起时没拖过 = 纯点击，
    /// 把按下 + 抬起一并交给 pane 本体（⌘+点击链接靠引擎在 release 时 open_url）
    struct FloatingDragSession {
        /// 会话跟着 pane 走，不存下标：按住期间 Cmd+T / 切工作区 / 移动 pane 会改 floating 数组
        weak var pane: PaneView?
        let edges: FloatingPane.DragEdges
        let down: NSEvent
        var moved = false
        static let threshold: CGFloat = 3
    }
    private var floatingDrag: FloatingDragSession?
    /// ⌘ 悬停在浮动 pane 上时由我们设置了光标（离开 / 松 ⌘ / 拖完时复位）
    private var floatingCursorActive = false
    /// 浮动 pane 四周可拖动缩放的边框带宽（pt）
    static let floatingEdgeBand: CGFloat = 14
    private var configWatcher: ConfigWatcher?
    private var lastConfigContent: String?
    private var stripPanSerial = 0

    /// scrolling 每屏可见列数（2 默认；菜单循环 2→3→4；config `visible-columns` 优先）
    private(set) var visibleColumns =
        UserDefaults.standard.object(forKey: "quickterm.visibleColumns") as? Int ?? 2
    var columnFactor: Double { ScrollingStrip.factor(forVisibleColumns: visibleColumns) }

    /// 悬停即焦点（spec §4.2，忠实 Hyprland focus_follows_mouse）。
    override var focusFollowsMouse: Bool { true }

    /// 嵌入层要求的树视图（仅 dwindle 布局有意义；scrolling 返回空树）
    override var surfaceTree: SplitTree<PaneView> {
        get {
            if case .dwindle(let tree) = model.layout { return tree }
            return SplitTree()
        }
        set {
            if case .dwindle = model.layout { model.layout = .dwindle(newValue) }
        }
    }

    /// 活动工作区全部 pane（平铺 + 浮动；线性循环与焦点扫描覆盖两层）
    var paneList: [PaneView] {
        model.layout.paneList + model.floating.map(\.pane)
    }
    /// WM 键是否由本控制器消费：浏览器专属动作只在焦点是浏览器 pane 时消费
    static func consumes(_ action: WMAction, focusedPane: PaneView?) -> Bool {
        if action.browserOnly { return focusedPane is BrowserPaneView }
        if action.terminalOnly { return focusedPane is Ghostty.SurfaceView }
        return true
    }

    /// 菜单项的固定快捷键触发时是否执行动作：以 [keybinds] 与 pane 消费规则为准——解绑 / 改键后的组合、
    /// 焦点 pane 不消费的动作（清屏时焦点在浏览器）都不执行（按键交还焦点终端）；鼠标点菜单项（非 keyDown）始终执行
    static func menuShortcutAllowed(_ action: WMAction, event: NSEvent?, keybindings: KeybindingMap,
                                   focusedPane: PaneView?) -> Bool {
        guard let event, event.type == .keyDown else { return true }
        guard keybindings.action(for: event)?.action == action else { return false }
        return consumes(action, focusedPane: focusedPane)
    }

    /// 清屏目标：以窗口真 FR 为准。Scratchpad 不在 paneList 里，focusedPane 会退回到第一块平铺 pane——
    /// 用它选目标会清掉用户看不见的终端的回滚
    var clearTarget: Ghostty.SurfaceView? {
        if let window, let fr = window.firstResponder as? Ghostty.SurfaceView { return fr }
        if model.scratchpadVisible, let scratch = model.scratchpadSurface { return scratch }
        return focusedSurface
    }

    /// 对清屏目标执行引擎 clear_screen（清屏 + 清回滚）。false = 没有终端目标，或引擎没执行
    /// （ghostty 把 clear_screen 标为 performable：alt screen 上（vim / less）不清、按键该交给程序）
    @discardableResult
    func clearFocusedTerminal() -> Bool {
        clearTarget?.surfaceModel?.perform(action: "clear_screen") == true
    }

    /// 焦点 pane 是否在浮动层
    var focusedIsFloating: Bool {
        guard let f = focusedPane else { return false }
        return model.floating.contains { $0.pane === f }
    }
    /// 全部工作区（含 scratchpad）所有 pane
    var allPanes: [PaneView] { model.allPanes }

    override var focusedPane: PaneView? {
        // 真相优先（focused 标志在视图重挂时可能短暂残留）：FR 是某 pane 或其后代（浏览器 pane 的 WKWebView）
        if let window, let holder = paneList.first(where: { $0.holdsFirstResponder(of: window) }) {
            return holder
        }
        return paneList.first { $0.focused } ?? paneList.first
    }

    /// 单焦点不变量：任一 pane 成为 FR 时，清掉其他 pane 残留的 focused
    /// （AppKit 在 FR 视图脱离窗口时不发 resign，见 SurfaceView.viewWillMove(toWindow:)）
    override func paneDidBecomeFirstResponder(_ pane: PaneView) {
        if pendingFocusTarget === pane { pendingFocusTarget = nil }   // 意图达成
        for other in model.allPanes where other !== pane && other.focused {
            other.focusDidChange(false)
        }
    }

    /// 控制器明确要聚焦的 pane（意图）。存在时，重挂载的其他 surface 不得夺回焦点——
    /// dwindle 新建：原 pane 在 leaf→split 重挂时会触发夺回，把刚交给新 pane 的焦点抢走。
    private var pendingFocusTarget: PaneView?

    override func paneMayReclaimFocus(_ pane: PaneView) -> Bool {
        pendingFocusTarget == nil || pendingFocusTarget === pane
    }

    /// 所有控制器发起的聚焦走这里：登记意图 → moveFocus（等挂载）→ 布局动效结束后再校验一次
    func requestFocus(to pane: PaneView, from: PaneView? = nil) {
        pendingFocusTarget = pane
        PaneView.moveFocus(to: pane, from: from)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self, weak pane] in
            guard let self, let pane, self.pendingFocusTarget === pane else { return }
            if pane.window != nil, let window = self.window, !pane.holdsFirstResponder(of: window) {
                PaneView.moveFocus(to: pane)   // 被重挂/动效期间的事件挤掉了，再交一次
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self, weak pane] in
                if let self, let pane, self.pendingFocusTarget === pane { self.pendingFocusTarget = nil }
            }
        }
    }

    /// 焦点对账：focused 标志必须与窗口 first responder 一致（重挂后的定时兜底）
    func reconcileFocus() {
        guard let window else { return }
        let holder = model.allPanes.first { $0.holdsFirstResponder(of: window) }
        for pane in model.allPanes where pane.focused && pane !== holder {
            pane.focusDidChange(false)
        }
        if let holder, !holder.focused {
            holder.focusDidChange(true)
        }
    }

    private func scheduleFocusReconcile() {
        for delay in [0.15, 0.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.reconcileFocus() }
        }
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

        // 焦点对账兜底：布局/工作区/浮动层任何变化都会让 SwiftUI 重挂 SurfaceView，
        // 重挂后 focused 标志可能与窗口 FR 脱节（见 SurfaceView.viewWillMove(toWindow:)）
        for publisher in [model.$layouts.map { _ in () }.eraseToAnyPublisher(),
                          model.$floatings.map { _ in () }.eraseToAnyPublisher(),
                          model.$activeIndex.map { _ in () }.eraseToAnyPublisher()] {
            publisher.dropFirst().sink { [weak self] in self?.scheduleFocusReconcile() }
                .store(in: &cancellables)
        }

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
                if let surface = (pane as? Ghostty.SurfaceView)?.surface {
                    self.ghostty.reloadConfig(surface: surface, soft: false)
                } else if let browser = pane as? BrowserPaneView {
                    self.applyBrowserTheme(browser)
                }
            }
            self.applyAppearance()
        }
        applyAppearance()

        // 浏览器扩展：pane 就是扩展眼里的"窗口"，管理器要能找到它们
        BrowserExtensionManager.shared.host = self

        // 配置链第 4 层：config.toml（键位/工作区数/主题/[ghostty] 透传）+ 热重载
        ConfigStore.ensureTemplateKeys()  // 已有配置文件补全新增键（注释形式，幂等）
        lastConfigContent = (try? String(contentsOf: ConfigStore.configURL, encoding: .utf8)) ?? ""
        applyConfig(ConfigStore.load())
        configWatcher = ConfigWatcher(
            directory: ConfigStore.configURL.deletingLastPathComponent()
        ) { [weak self] in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self?.reloadConfigFile() }
        }

        // 状态恢复（spec §4.8）：布局 + 各 pane cwd + 活动工作区；失败则全新开始
        // 视图尚未被 SwiftUI 挂载：直接 makeFirstResponder 返回 true 却什么都不做（AppKit 报
        // "different window ((null))"），用 Ghostty.moveFocus（等待挂载后再设）
        if !AppDelegate.isRunningTests, restoreState() {
            for case let browser as BrowserPaneView in allPanes { applyBrowserTheme(browser) }   // 恢复的浏览器 pane 也套主题
            if let focused = focusedPane { requestFocus(to: focused) }
        } else {
            let first = newSurface(inheritingFrom: nil)
            model.layout = .scrolling(ScrollingStrip(pane: first, widthFactor: columnFactor))
            requestFocus(to: first)
        }
        window.center()
        window.makeKeyAndOrderFront(nil)

        // 进程退出 / close 动作 → 移除 pane
        NotificationCenter.default.addObserver(
            self, selector: #selector(ghosttyDidCloseSurface(_:)),
            name: Ghostty.Notification.ghosttyCloseSurface, object: nil)
        // 文件管理器 pane 子进程退出（引擎不会自行 close）→ 原位开终端 / 关 pane
        NotificationCenter.default.addObserver(
            self, selector: #selector(ghosttyChildExited(_:)),
            name: Ghostty.Notification.ghosttyChildExited, object: nil)
        // dwindle 分隔条双击 → 引擎回发 didEqualizeSplits → 全树等分
        NotificationCenter.default.addObserver(
            self, selector: #selector(ghosttyDidEqualizeSplits(_:)),
            name: Ghostty.Notification.didEqualizeSplits, object: nil)

        // WM 级组合键：在事件分发前拦截；未命中一律放行给 surface（终端级键不受影响）。
        // 浮动面板打开时优先接管 ↑↓/回车/Esc 导航。
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let window = self.window, event.window === window else { return event }
            if self.model.activePanel != nil, self.handlePanelKey(event) { return nil }
            guard let hit = self.keybindings.action(for: event) else { return event }
            // pane 专属动作：浏览器专属的焦点不在浏览器 pane 时不消费（Cmd+R / Cmd+= 等仍归终端），
            // 终端专属的（清屏）焦点不在终端时放行；清屏按真 FR 选目标（Scratchpad 不在 paneList 里）
            let target = hit.action.terminalOnly ? self.clearTarget : self.focusedPane
            guard Self.consumes(hit.action, focusedPane: target) else { return event }
            if hit.action == .clearTerminal {
                // 引擎没执行（alt screen）→ 按 ghostty performable 语义把按键交给程序；
                // 不能 return event：Shell 菜单的 ⇧⌘K 键等价会再把它吞掉
                if !self.clearFocusedTerminal(), let surface = self.clearTarget { surface.keyDown(with: event) }
                return nil
            }
            self.perform(hit.action, precise: hit.precise)
            return nil
        }

        // ⌘ 状态跟踪（拖拽源浮层）+ ⌘+右键拖拽调整大小（spec §4.2）
        mouseMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.flagsChanged, .rightMouseDown, .rightMouseDragged, .rightMouseUp,
                       .leftMouseDown, .leftMouseDragged, .leftMouseUp, .mouseMoved]
        ) { [weak self] event in
            guard let self else { return event }
            if event.type == .flagsChanged {
                let held = event.modifierFlags.contains(.command)
                ModifierState.shared.commandHeld = held
                if !held, self.floatingDrag == nil { self.resetFloatingCursor() }
                return event
            }
            // 拖动会话按鼠标键收尾，不按修饰键：先松 ⌘ 再松左键也必须正常结束，否则残留会话会劫持
            // 下一次 ⌘ 拖动（平铺 pane 的 DnD 拖不动、光标挂死）
            if self.floatingDrag != nil, let handled = self.floatingSessionEvent(event) {
                return handled ? nil : event
            }
            if let pane = self.resizeTarget {
                switch event.type {
                case .rightMouseDragged:
                    if let idx = self.floatingIndex(of: pane) {
                        self.resizeFloating(at: idx, dx: event.deltaX, dy: event.deltaY)
                    } else {
                        self.resizeByDrag(pane: pane, dx: event.deltaX, dy: event.deltaY)
                    }
                    return nil
                case .rightMouseUp:
                    self.resizeTarget = nil
                    return nil
                default: break
                }
            }
            guard event.window === self.window,
                  event.modifierFlags.contains(.command) else {
                if event.type == .mouseMoved { self.resetFloatingCursor() }
                return event
            }
            switch event.type {
            case .mouseMoved:
                // ⌘ 悬停：浮动 pane 中间 = 抓手（指着链接时 = 链接指针），四边/四角 = 对应方向的缩放光标
                let hit = self.floatingDragHit(event)
                self.updateFloatingCursor(for: hit?.edges, pane: hit.map { self.model.floating[$0.index].pane })
                return event
            case .leftMouseDown:
                // ⌘+左键：浮动 pane 中间 = 自由移动（置顶）、四边/四角 = 缩放（对边不动）；
                // 平铺 pane 放行给 DnD 拖拽源
                return self.beginFloatingDrag(with: event) ? nil : event
            case .leftMouseDragged, .leftMouseUp:
                return event   // 无会话：放行（会话内的拖动/松开在上面已处理）
            case .rightMouseDown:
                self.resizeTarget = self.paneUnderPointer(event)
                    .flatMap { self.model.closingPanes.contains($0.id) ? nil : $0 }   // 淡出中不缩放
                return self.resizeTarget == nil ? event : nil
            case .rightMouseDragged, .rightMouseUp:
                return event   // 无会话：放行
            default:
                return event
            }
        }

        // 滚轮：顶栏区域 → 循环工作区（spec §4.4）；
        // 内容区 + scrolling 布局 + 横向为主 → 平移画布（spec §4.2-bis 附带项）
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, let window = self.window, event.window === window,
                  let content = window.contentView else { return event }
            let p = content.convert(event.locationInWindow, from: nil)
            let yTop = content.isFlipped ? p.y : content.bounds.height - p.y
            if self.model.barVisible, yTop < StatusBarView.height {
                let delta = event.scrollingDeltaY + event.scrollingDeltaX
                guard abs(delta) > 0.5 else { return nil }
                let count = self.model.layouts.count
                let next = (self.model.activeIndex + (delta < 0 ? 1 : count - 1)) % count
                self.switchWorkspace(next)
                return nil
            }
            // 溢出的浏览器标签条自己吃横向滚轮（监视器跑在视图派发之前，否则永远轮不到它）
            if let hit = content.hitTest(p),
               let bar = sequence(first: hit, next: { $0.superview })
                   .compactMap({ $0 as? BrowserTabBarView }).first,
               bar.isOverflowing {
                return event
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
        // 空工作区提示用当前实际绑定
        model.newTerminalCombo = keybindings.displayBindings()
            .first { $0.action == .newTerminal }?.combo ?? "Cmd+Return"
        fileManagerCommand = settings.fileManagerCommand
        linkOpener = settings.linkOpener
        BrowserPaneView.settings = .init(home: settings.browserHome, search: settings.browserSearch,
                                         userAgent: settings.browserUserAgent, inspectable: settings.browserInspectable,
                                         tabBar: settings.browserTabBar,
                                         tabWidth: settings.browserTabWidth, tabMinWidth: settings.browserTabMinWidth,
                                         downloadDirectory: settings.browserDownloadDir)
        BrowserExtensionManager.shared.isEnabled = settings.browserExtensions
        for case let browser as BrowserPaneView in allPanes { browser.applySettings() }   // UA / Inspector 热重载
        model.setWorkspaceCount(settings.workspaces)
        if let n = settings.visibleColumns { setVisibleColumns(n, persist: false) }
        themeManager.updateFromConfig(
            passthrough: settings.ghosttyPassthrough,
            followEngine: settings.themeName == "ghostty",
            panePadding: settings.panePadding,
            paneOpacity: settings.paneOpacity,
            inactiveBlur: settings.inactiveBlur,
            activeOpacity: settings.activeOpacity,
            barOpacity: settings.barOpacity,
            dividerOpacity: settings.dividerOpacity,
            paneGap: settings.paneGap)
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
        var version = 4   // v4：叶子带 kind（terminal/browser）；v2/v3 无 kind = 终端
        var layouts: [WorkspaceLayout]
        /// v3 起；v2 存档缺省为空浮动层
        var floatings: [[FloatingPane]]?
        var activeIndex: Int
    }

    func saveState() {
        flushPendingCloses()   // 淡出中的 pane 不进存档
        let state = PersistedState(
            layouts: model.layouts, floatings: model.floatings, activeIndex: model.activeIndex)
        if let data = try? JSONEncoder().encode(state) {
            try? data.write(to: Self.stateURL, options: .atomic)
        }
    }

    /// 恢复上次布局（每 pane 按存档 cwd 重开 shell）；旧版本/损坏存档 → false 全新开始
    private func restoreState() -> Bool {
        guard let data = try? Data(contentsOf: Self.stateURL),
              let state = try? JSONDecoder().decode(PersistedState.self, from: data),
              (2...4).contains(state.version) else { return false }
        let floatings = state.floatings ?? Array(repeating: [], count: state.layouts.count)
        guard !(state.layouts.allSatisfy(\.isEmpty) && floatings.allSatisfy(\.isEmpty)) else { return false }
        // 旧状态归一：0.49（露边 2% 时代）/ 0.44（露边 6% 时代）是历史默认列宽，
        // 归到当前列因子；用户手动调过的宽度原样保留
        let legacyDefaults = [0.49, 0.44]
        model.layouts = state.layouts.map { layout in
            guard case .scrolling(var strip) = layout else { return layout }
            for i in strip.columns.indices
            where legacyDefaults.contains(where: { abs(strip.columns[i].widthFactor - $0) < 0.001 }) {
                strip.columns[i].widthFactor = columnFactor
            }
            return .scrolling(strip)
        }
        model.floatings = floatings
        if model.floatings.count < model.layouts.count {
            model.floatings.append(contentsOf: Array(
                repeating: [], count: model.layouts.count - model.floatings.count))
        }
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

    private func paneUnderPointer(_ event: NSEvent) -> PaneView? {
        guard let content = window?.contentView else { return nil }
        var v = content.hitTest(content.convert(event.locationInWindow, from: nil))
        while let cur = v {
            if let s = cur as? PaneView { return s }
            v = cur.superview
        }
        // 命中覆盖层等兄弟视图时按几何位置回退查找——
        // 必须按 z 序自顶向下：浮动层（数组末位最顶）优先于平铺层，
        // 否则浮动 pane 叠在平铺上时 ⌘ 拖动/调大小会抓到下层平铺 pane
        let byZ = model.floating.reversed().map(\.pane) + model.layout.paneList
        return byZ.first {
            $0.window === window && $0.convert($0.bounds, to: nil).contains(event.locationInWindow)
        }
    }

    /// ⌘+右键拖拽：dwindle 调就近分隔条；scrolling 按横向位移调列宽
    private func resizeByDrag(pane: PaneView, dx: CGFloat, dy: CGFloat) {
        switch model.layout {
        case .dwindle(let tree):
            guard let node = tree.root?.node(view: pane),
                  let bounds = window?.contentLayoutRect else { return }
            let amount = UInt16(min(max(abs(dx) >= abs(dy) ? abs(dx) : abs(dy), 1), 200))
            let direction: SplitTree<PaneView>.Spatial.Direction =
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
        flushPendingCloses()   // 布局操作先在真实布局上做（淡出中的 pane 立即移除）
        if ![.newTerminal, .fileManager, .newBrowser].contains(action) { model.appearingPane = nil }  // 非插入类变更不重播进场动效
        switch action {
        case .newTerminal:
            insertNewPane(newSurface(inheritingFrom: focusedPane))

        case .clearTerminal:
            // 同 ghostty 的 clear_screen（Terminal.app Cmd+K 语义：清屏 + 清回滚）；只作用于真 FR 终端
            clearFocusedTerminal()

        case .fileManager:
            // Omarchy Super+Shift+F：新 pane 里以焦点 pane 的目录启动 TUI 文件管理器
            let start = focusedPane?.workingDirectory ?? FileManager.default.homeDirectoryForCurrentUser.path
            let cwdFile = NSTemporaryDirectory() + "quickterm-fm-" + UUID().uuidString
            let launch = FileManagerLaunch.plan(program: fileManagerCommand, startDirectory: start, cwdFile: cwdFile)
            let pane = newSurface(workingDirectory: start, command: launch.command, environment: launch.environment)
            pane.pwd = start               // yazi 不发 OSC 7：种入起始目录，Cmd+Return / 再开文件管理器都能继承
            pane.closesOnChildExit = true  // 退出即关（引擎对带 command 的 surface 不自行 close）
            // 只有真的跑起文件管理器才登记会话（免关闭确认 + 退出读目录）；
            // 程序缺失开出的提示 pane 是普通交互 shell，按普通 pane 处理
            if insertNewPane(pane), launch.found {
                fileManagerSessions[ObjectIdentifier(pane)] = launch.session
            } else {
                FileManagerLaunch.cleanup(launch.session)
            }

        case .newBrowser:
            openBrowserPane(url: BrowserPaneView.settings.homeURL, from: focusedPane)
        case .webBack: browserPane?.goBack()
        case .webForward: browserPane?.goForward()
        case .webReload: browserPane?.reload()
        case .webFocusAddress: browserPane?.focusAddressBar()
        case .webOpenExternal: browserPane?.openExternally()
        case .webZoomIn: browserPane?.zoom(by: 1.1)
        case .webZoomOut: browserPane?.zoom(by: 1 / 1.1)
        case .webZoomReset: browserPane?.resetZoom()
        case .webNewTab: browserPane?.newTab()
        case .webNextTab: browserPane?.selectTab(offset: 1)
        case .webPrevTab: browserPane?.selectTab(offset: -1)
        case .webExtensions: browserPane?.showExtensionsMenu()

        case .closePane:
            // 浏览器 pane 多标签时 Cmd+W 关当前标签，最后一个标签才关 pane（Chrome 语义）
            if let browser = browserPane, browser.tabs.count > 1 {
                browser.closeActiveTab()
            } else if let focused = focusedPane {
                closePane(focused)
            }

        case .focusLeft: moveFocus(.left)
        case .focusRight: moveFocus(.right)
        case .focusUp: moveFocus(.up)
        case .focusDown: moveFocus(.down)

        case .swapLeft: swapFocused(.left)
        case .swapRight: swapFocused(.right)
        case .swapUp: swapFocused(.up)
        case .swapDown: swapFocused(.down)

        case .toggleSplitDirection:
            guard let focused = focusedPane else { return }
            switch model.layout {
            case .dwindle(let tree):
                model.layout = .dwindle((try? tree.togglingSplitDirection(around: focused)) ?? tree)
            case .scrolling(let strip):
                // Cmd+J：併入左列纵栈 ⇄ 拆出独立列（spec §4.2-bis）
                model.layout = .scrolling(strip.mergingOrSplitting(focused))
                requestFocus(to: focused)
            }

        case .toggleZoom:
            guard let focused = focusedPane else { return }
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
            case .scrolling(let strip): model.layout = .scrolling(strip.equalized(to: columnFactor))
            }

        case .resizeLeft: resizeFocused(.left, precise: precise)
        case .resizeRight: resizeFocused(.right, precise: precise)
        case .resizeUp: resizeFocused(.up, precise: precise)
        case .resizeDown: resizeFocused(.down, precise: precise)

        case .cyclePaneNext: cycleFocus(next: true)
        case .cyclePanePrev: cycleFocus(next: false)

        case .toggleLayout:
            // Cmd+L：dwindle ⇄ scrolling——pane 集合未变时恢复上次布局，否则保 pane 保序转换
            model.toggleLayout(columnFactor: columnFactor)
            if let focused = focusedPane { requestFocus(to: focused) }

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
        case .exitFullscreen:
            // 仅全屏时退出（Ctrl+Cmd+F 本身即开关；Cmd+Esc 为专用退出）
            if savedFrame != nil { toggleSimpleFullscreen() }
        case .toggleFloat:
            toggleFloat()
        }
    }

    // MARK: 每屏可见列数（超宽屏支持）

    /// 设置可见列数并把全部 scrolling 工作区统一重排为新因子
    func setVisibleColumns(_ n: Int, persist: Bool = true) {
        let clamped = min(max(n, 1), 6)
        guard clamped != visibleColumns || !model.layoutsMatch(factor: columnFactor) else {
            visibleColumns = clamped
            return
        }
        visibleColumns = clamped
        if persist {
            UserDefaults.standard.set(clamped, forKey: "quickterm.visibleColumns")
        }
        model.visibleColumnsDisplay = clamped
        let factor = columnFactor
        for i in model.layouts.indices {
            if case .scrolling(let strip) = model.layouts[i] {
                model.layouts[i] = .scrolling(strip.equalized(to: factor))
            }
        }
    }

    /// 主菜单循环：2 → 3 → 4 → 2
    func cycleVisibleColumns() {
        let next = visibleColumns >= 4 ? 2 : visibleColumns + 1
        setVisibleColumns(next)
    }

    // MARK: 浮动 pane（spec v7：Cmd+T / ⌘拖移动 / ⌘右拖调大小）

    func toggleFloat(_ target: PaneView? = nil) {
        flushPendingCloses()
        guard let focused = target ?? focusedPane,
              paneList.contains(focused) else { return }   // 显式目标可能刚被 flush 移除
        if let idx = model.floating.firstIndex(where: { $0.pane === focused }) {
            // 塞回平铺：scrolling = 尾列右侧新列；dwindle = 规则插入
            let fp = model.floating.remove(at: idx)
            switch model.layout {
            case .scrolling(let strip):
                model.layout = .scrolling(strip.insertingColumnRight(
                    of: strip.paneList.last, pane: fp.pane, widthFactor: columnFactor))
            case .dwindle(let tree):
                if tree.isEmpty {
                    model.layout = .dwindle(SplitTree(view: fp.pane))
                } else if let anchor = tree.root?.leaves().first,
                          let t = try? tree.inserting(
                            view: fp.pane, at: anchor,
                            direction: tree.dwindleDirection(for: anchor, in: dwindleLayoutSize)) {
                    model.layout = .dwindle(t)
                }
            }
            requestFocus(to: fp.pane)
        } else {
            // 浮起：类 Omarchy togglefloating——固定尺寸居中
            // （宽 = 默认列宽 × 0.75，高 = 内容区 45%）
            let rect = FloatingPane.defaultRect(columnFactor: columnFactor)
            removeFromActiveLayout(focused)
            model.floating.append(FloatingPane(pane: focused, rect: rect).clamped())
            requestFocus(to: focused)
        }
    }

    /// dwindle 布局区尺寸（contentView 去掉顶部状态条；决定分裂方向的宽高比）
    private var dwindleLayoutSize: CGSize? {
        guard let content = window?.contentView else { return nil }
        let barH: CGFloat = model.barVisible ? StatusBarView.height : 0
        return CGSize(width: content.bounds.width, height: content.bounds.height - barH)
    }

    /// hover 遮挡判定（SurfaceView mouseEntered/mouseMoved 回调；spec v7 修订）：
    /// 模型几何——更高 z 的浮动 pane、Scratchpad、面板遮罩构成遮挡。
    override func surfaceIsOccluded(_ pane: PaneView,
                                    at locationInWindow: NSPoint) -> Bool {
        if model.activePanel != nil { return true }  // 面板遮罩在最顶层
        if model.closingPanes.contains(pane.id) { return true }  // 淡出中：悬停不再夺焦点
        if model.scratchpadVisible { return model.scratchpadSurface !== pane }
        guard !model.floating.isEmpty,
              let point = normalizedContentPoint(locationInWindow) else { return false }
        return HoverOcclusion.isOccluded(
            paneFloatIndex: model.floating.firstIndex { $0.pane === pane },
            floatingRects: model.floating.map(\.rect),
            at: point)
    }

    /// 窗口坐标 → 内容区归一化 top-left（内容区 = contentView 去掉顶部状态条；
    /// 与 RootView 浮动层 GeometryReader 的坐标系一致）。
    /// 注意 contentView 是 NSHostingView（flipped），convert 结果已是 top-left 基准；
    /// isFlipped 分支为防御（宿主视图更换时不静默镜像）。
    func normalizedContentPoint(_ locationInWindow: NSPoint) -> CGPoint? {
        guard let content = window?.contentView else { return nil }
        let barH: CGFloat = model.barVisible ? StatusBarView.height : 0
        let W = content.bounds.width
        let H = content.bounds.height - barH
        guard W > 0, H > 0 else { return nil }
        let p = content.convert(locationInWindow, from: nil)
        let yTop = content.isFlipped ? p.y : content.bounds.height - p.y
        return CGPoint(x: p.x / W, y: (yTop - barH) / H)
    }

    private func floatingIndex(of pane: PaneView?) -> Int? {
        guard let pane else { return nil }
        return model.floating.firstIndex { $0.pane === pane }
    }

    /// ⌘ 拖动 / 悬停命中判定：按浮动 pane 的矩形（含留白与边框带，自顶向下）而非 NSView 命中——
    /// 边框带落在 PaneChrome 的留白里，NSView 命中测试到不了那里
    /// ⌘+左键按下：命中浮动 pane 就开会话（中间 = 移动并置顶，四边/四角 = 缩放）。true = 已接管
    @discardableResult
    func beginFloatingDrag(with event: NSEvent) -> Bool {
        guard let hit = floatingDragHit(event) else { return false }
        let idx = hit.edges.isMove ? raiseFloating(at: hit.index) : hit.index
        floatingDrag = FloatingDragSession(pane: model.floating[idx].pane, edges: hit.edges, down: event)
        if hit.edges.isMove { NSCursor.closedHand.set(); floatingCursorActive = true }
        return true
    }

    /// 会话内的拖动 / 抬起。返回 true = 事件已消费，false = 放行，nil = 与会话无关。
    /// 抬起时没拖过阈值 = 纯点击：按下 + 抬起一并交给 pane 的键盘焦点视图（终端 → 引擎 PRESS/RELEASE，
    /// ⌘+点击链接才能触发 open_url；浏览器 → WKWebView）
    func floatingSessionEvent(_ event: NSEvent) -> Bool? {
        guard let drag = floatingDrag else { return nil }
        switch event.type {
        case .leftMouseDragged:
            // pane 已不在浮动层（按住期间 Cmd+T / 切工作区 / 移走）：会话作废
            guard let pane = drag.pane, let index = model.floating.firstIndex(where: { $0.pane === pane }),
                  !model.closingPanes.contains(pane.id) else {
                floatingDrag = nil
                resetFloatingCursor()
                return true
            }
            // 过阈值前的位移不能丢：跨过阈值的那一下把从按下点起的累计位移一次补上（deltaY 向下为正，窗口坐标向上为正）
            var dx = event.deltaX, dy = event.deltaY
            if !drag.moved {
                dx = event.locationInWindow.x - drag.down.locationInWindow.x
                dy = drag.down.locationInWindow.y - event.locationInWindow.y
                guard hypot(dx, dy) >= FloatingDragSession.threshold else { return true }
                floatingDrag?.moved = true
            }
            if drag.edges.isMove {
                moveFloating(at: index, dx: dx, dy: dy)
            } else {
                resizeFloating(at: index, edges: drag.edges, dx: dx, dy: dy)
            }
            return true
        case .leftMouseUp:
            floatingDrag = nil
            if !drag.moved, let pane = drag.pane, model.floating.contains(where: { $0.pane === pane }),
               !model.closingPanes.contains(pane.id),
               let target = pane.clickTarget(atWindowPoint: drag.down.locationInWindow) {
                target.mouseDown(with: drag.down)
                target.mouseUp(with: event)
            }
            if event.modifierFlags.contains(.command) {
                let hit = floatingDragHit(event)
                updateFloatingCursor(for: hit?.edges, pane: hit.map { model.floating[$0.index].pane })
            } else {
                resetFloatingCursor()
            }
            return true
        default:
            return nil
        }
    }

    func floatingDragHit(_ event: NSEvent) -> (index: Int, edges: FloatingPane.DragEdges)? {
        floatingDragHit(atWindowPoint: event.locationInWindow)
    }

    func floatingDragHit(atWindowPoint point: NSPoint) -> (index: Int, edges: FloatingPane.DragEdges)? {
        // 面板遮罩 / scratchpad 在浮动层之上（与 surfaceIsOccluded 的遮挡顺序一致）
        guard model.activePanel == nil, !model.scratchpadVisible else { return nil }
        guard let p = normalizedContentPoint(point), let content = window?.contentView else { return nil }
        let barH: CGFloat = model.barVisible ? StatusBarView.height : 0
        let W = max(content.bounds.width, 1), H = max(content.bounds.height - barH, 1)
        for idx in model.floating.indices.reversed() {   // 数组末位最顶
            let fp = model.floating[idx]
            guard !model.closingPanes.contains(fp.pane.id) else { continue }   // 淡出中的不再拖
            if let edges = FloatingPane.dragEdges(at: p, in: fp.rect,
                                                  bandX: Self.floatingEdgeBand / W,
                                                  bandY: Self.floatingEdgeBand / H) {
                return (idx, edges)
            }
        }
        return nil
    }

    /// ⌘ 悬停光标：nil = 不在浮动 pane 上（复位）；空 = 中间（抓手）；否则对应边/角的缩放光标
    private func updateFloatingCursor(for edges: FloatingPane.DragEdges?, pane: PaneView? = nil) {
        guard let edges else { resetFloatingCursor(); return }
        let cursor: NSCursor
        if edges.isMove {
            // 终端报告指着链接：⌘+点击会开链接，光标给链接指针而不是抓手
            cursor = (pane as? Ghostty.SurfaceView)?.pointerStyle == .link ? .pointingHand : .openHand
        } else {
            let position: NSCursor.FrameResizePosition = switch (edges.contains(.left), edges.contains(.right),
                                                                edges.contains(.top), edges.contains(.bottom)) {
            case (true, _, true, _): .topLeft
            case (_, true, true, _): .topRight
            case (true, _, _, true): .bottomLeft
            case (_, true, _, true): .bottomRight
            case (true, _, _, _): .left
            case (_, true, _, _): .right
            case (_, _, true, _): .top
            default: .bottom
            }
            cursor = .frameResize(position: position, directions: .all)
        }
        cursor.set()
        floatingCursorActive = true
    }

    private func resetFloatingCursor() {
        guard floatingCursorActive else { return }
        floatingCursorActive = false
        NSCursor.arrow.set()
        window?.resetCursorRects()   // 让终端 / 网页视图按自己的规则重设光标
    }

    /// ⌘+左键拖动浮动 pane（deltaY 向下为正 = SwiftUI y 正方向）
    private func moveFloating(at index: Int, dx: CGFloat, dy: CGFloat) {
        guard let content = window?.contentView, model.floating.indices.contains(index) else { return }
        let barH: CGFloat = model.barVisible ? StatusBarView.height : 0   // 纵向分母与浮动层几何/缩放一致
        var fp = model.floating[index]
        fp.rect.origin.x += dx / max(content.bounds.width, 1)
        fp.rect.origin.y += dy / max(content.bounds.height - barH, 1)
        model.floating[index] = fp.clamped()
    }

    /// ⌘+右键拖动：从右下角缩放（Hyprland 语义，任意位置按下）
    private func resizeFloating(at index: Int, dx: CGFloat, dy: CGFloat) {
        resizeFloating(at: index, edges: [.right, .bottom], dx: dx, dy: dy)
    }

    /// ⌘+左键在边框带 / 角上拖动：被拖的边跟随指针，对边不动
    private func resizeFloating(at index: Int, edges: FloatingPane.DragEdges, dx: CGFloat, dy: CGFloat) {
        guard let content = window?.contentView, model.floating.indices.contains(index) else { return }
        let barH: CGFloat = model.barVisible ? StatusBarView.height : 0
        model.floating[index] = model.floating[index].resized(
            edges: edges,
            dx: dx / max(content.bounds.width, 1),
            dy: dy / max(content.bounds.height - barH, 1))
    }

    /// 置顶（数组末位 = 最顶）
    private func raiseFloating(at index: Int) -> Int {
        guard index != model.floating.count - 1 else { return index }
        let fp = model.floating.remove(at: index)
        model.floating.append(fp)
        return model.floating.count - 1
    }

    // MARK: Scratchpad（spec §4.1）

    private func toggleScratchpad() {
        if model.scratchpadVisible {
            model.scratchpadVisible = false
            if let focused = focusedPane { requestFocus(to: focused) }
            return
        }
        if model.scratchpadSurface == nil {
            model.scratchpadSurface = newSurface(inheritingFrom: focusedPane)
        }
        model.scratchpadVisible = true
        if let scratch = model.scratchpadSurface {
            requestFocus(to: scratch)
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
        case .backgrounds: themeManager.backgroundChoices.count + 1  // 末位 = 选择图片…
        case .menu: MenuEntry.allCases.count
        case .keybindings, nil: 0
        }
    }

    /// 上下键步长：背景面板是网格（3 列）——上下按行移动，其余面板按 1
    private var panelRowStep: Int {
        model.activePanel == .backgrounds ? OverlayPanelView.backgroundsColumns : 1
    }

    /// 面板键盘导航；返回 true = 已消费
    private func handlePanelKey(_ event: NSEvent) -> Bool {
        switch KeybindingMap.normalizedKey(for: event) {
        case "escape":
            model.activePanel = nil
            return true
        case "up":
            model.panelSelection = max(0, model.panelSelection - panelRowStep)
            return true
        case "down":
            model.panelSelection = min(max(0, panelItemCount - 1),
                                       model.panelSelection + panelRowStep)
            return true
        case "left" where model.activePanel == .backgrounds:
            model.panelSelection = max(0, model.panelSelection - 1)
            return true
        case "right" where model.activePanel == .backgrounds:
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
            model.activePanel = nil
            if index < themeManager.backgroundChoices.count {
                themeManager.selectBackground(index)
            } else {
                pickUserBackground()  // 末位入口：系统文件选择器
            }
        case .menu:
            // 每屏列数：循环并保持菜单打开（便于连按）
            if MenuEntry(rawValue: index) == .visibleColumns {
                cycleVisibleColumns()
                return
            }
            model.activePanel = nil
            switch MenuEntry(rawValue: index) {
            case .newTerminal: perform(.newTerminal)
            case .fileManager: perform(.fileManager)
            case .browser: perform(.newBrowser)
            case .themes: perform(.themePicker)
            case .backgrounds: perform(.backgroundMenu)
            case .toggleBar: perform(.toggleBar)
            case .toggleGaps: perform(.toggleGaps)
            case .toggleOpacity: perform(.toggleOpacity)
            case .keybindings: perform(.keybindingHelp)
            case .settings: openSettingsFile()
            case .about: NSApp.orderFrontStandardAboutPanel(nil)
            case .visibleColumns, nil: break  // visibleColumns 已在上方处理
            }
        case .keybindings, nil:
            model.activePanel = nil
        }
    }

    /// 设置（Cmd+, / 菜单）：打开 QuickTerm config.toml（不存在则先写模板），
    /// 若存在 ~/.config/ghostty/config 一并打开（配置链第 2 层，用户常改）
    /// 自选背景：NSOpenPanel 选图 → 拷入 ~/.config/quickterm/backgrounds 并选中
    private func pickUserBackground() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.message = "选择背景图片（将拷入 ~/.config/quickterm/backgrounds）"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.themeManager.addUserBackground(from: url)
        }
    }

    private func openSettingsFile() {
        let url = ConfigStore.configURL
        ConfigStore.ensureTemplateKeys()  // 打开前补全缺失键，用户看到的是完整清单
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
        flushPendingCloses()
        model.appearingPane = nil
        guard index != model.activeIndex else { return }
        model.switchTo(index)  // 值语义切换：瞬时、无动画（忠实 Omarchy）
        if let focused = focusedPane {
            requestFocus(to: focused)
        }
    }

    /// 把焦点 pane 移到目标工作区并跟随（Cmd+Shift+数字）；插入遵循目标工作区布局
    func moveFocusedPane(to index: Int) {
        guard model.layouts.indices.contains(index), index != model.activeIndex,
              let focused = focusedPane else { return }

        // 浮动 pane：连浮动状态一起搬去目标工作区
        if let idx = model.floating.firstIndex(where: { $0.pane === focused }) {
            let fp = model.floating.remove(at: idx)
            model.floatings[index].append(fp)
            model.switchTo(index)
            requestFocus(to: focused)
            return
        }

        // 先算目标（失败不动源）
        let newTarget: WorkspaceLayout
        switch model.layouts[index] {
        case .scrolling(let strip):
            newTarget = .scrolling(strip.isEmpty
                ? ScrollingStrip(pane: focused, widthFactor: columnFactor)
                : strip.insertingColumnRight(of: strip.paneList.last, pane: focused,
                                             widthFactor: columnFactor))
        case .dwindle(let tree):
            if tree.isEmpty {
                newTarget = .dwindle(SplitTree(view: focused))
            } else if let anchor = tree.root?.leaves().first,
                      let t = try? tree.inserting(
                        view: focused, at: anchor,
                        direction: tree.dwindleDirection(for: anchor, in: dwindleLayoutSize)) {
                newTarget = .dwindle(t)
            } else {
                return
            }
        }

        removeFromActiveLayout(focused)
        model.layouts[index] = newTarget
        model.switchTo(index)
        requestFocus(to: focused)
    }

    // MARK: 布局分派的焦点/换位/调整

    private func moveFocus(_ direction: ScrollingStrip.Direction) {
        guard let focused = focusedPane else { return }
        let target: PaneView?
        switch model.layout {
        case .dwindle(let tree):
            guard let node = tree.root?.node(view: focused) else { return }
            target = tree.focusTarget(for: .spatial(direction.spatial), from: node)
        case .scrolling(let strip):
            target = strip.focusTarget(from: focused, direction: direction)
        }
        if let target { requestFocus(to: target, from: focused) }
    }

    private func swapFocused(_ direction: ScrollingStrip.Direction) {
        guard let focused = focusedPane else { return }
        switch model.layout {
        case .dwindle(let tree):
            guard let node = tree.root?.node(view: focused),
                  let target = tree.focusTarget(for: .spatial(direction.spatial), from: node),
                  let swapped = try? tree.swapping(focused, target) else { return }
            model.layout = .dwindle(swapped)
        case .scrolling(let strip):
            model.layout = .scrolling(strip.swapping(focused, direction: direction))
        }
        requestFocus(to: focused)
    }

    private func resizeFocused(_ direction: ScrollingStrip.Direction, precise: Bool) {
        guard let focused = focusedPane else { return }
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
        guard let focused = focusedPane else { return }
        let target: PaneView?
        switch model.layout {
        case .dwindle(let tree):
            guard let node = tree.root?.node(view: focused) else { return }
            target = tree.focusTarget(for: next ? .next : .previous, from: node)
        case .scrolling(let strip):
            target = strip.linearTarget(from: focused, next: next)
        }
        if let target { requestFocus(to: target, from: focused) }
    }

    // MARK: Surface 生命周期

    /// 新建 surface；继承来源 pane 的当前目录（spec §4.1）
    func newSurface(inheritingFrom source: PaneView?) -> Ghostty.SurfaceView {
        newSurface(workingDirectory: source?.workingDirectory)
    }

    /// 焦点是浏览器 pane 时的快捷引用（web-* 动作）
    private var browserPane: BrowserPaneView? { focusedPane as? BrowserPaneView }

    /// 新建浏览器 pane：插进活动布局并聚焦（页面里 target=_blank / window.open 也走这里）
    @discardableResult
    override func openBrowserPane(url: URL, from: PaneView?) -> BrowserPaneView? {
        let pane = BrowserPaneView(url: url)
        applyBrowserTheme(pane)
        insertNewPane(pane, anchor: from)
        return pane
    }

    override func requestClosePane(_ pane: PaneView) {
        closePane(pane, confirmIfNeeded: false)
    }

    /// 终端 ⌘+点击的 http(s) 链接：当前工作区已有浏览器 pane → 最近激活的那个里开新标签；没有 → 在终端旁新开一个。
    /// 其它 scheme（mailto / ssh / 文件…）与 link-opener = system 时不接管，引擎走系统默认应用
    override func openLink(_ url: URL, from: PaneView?) -> Bool {
        guard linkOpener.lowercased() != "system",
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) else { return false }
        // 从 Scratchpad 点的链接：先收起 Scratchpad，否则浏览器 pane 在遮罩下面、焦点也被它挡着
        if let from, from === model.scratchpadSurface, model.scratchpadVisible { model.scratchpadVisible = false }
        if let browser = mostRecentBrowserPane() {
            // 别的 pane zoom 时浏览器 pane 没挂载（window == nil），标签会加在看不见的地方、焦点也交不过去
            if browser.window == nil { clearZoom() }
            browser.openLink(url)
            requestFocus(to: browser, from: from)
        } else {
            openBrowserPane(url: url, from: from)   // insertNewPane 自己会解除 zoom
        }
        return true
    }

    /// 解除当前布局的 zoom（有的话）
    private func clearZoom() {
        switch model.layout {
        case .dwindle(let tree):
            if tree.zoomed != nil { model.layout = .dwindle(SplitTree(root: tree.root, zoomed: nil)) }
        case .scrolling(let strip):
            if strip.zoomedID != nil {
                var next = strip
                next.zoomedID = nil
                model.layout = .scrolling(next)
            }
        }
    }

    /// 最近激活的浏览器 pane（全部工作区，含浮动；淡出中的不算）——扩展宿主用
    private func mostRecentBrowserPaneAnywhere() -> BrowserPaneView? {
        browserPanes.filter { !model.closingPanes.contains($0.id) }
            .max { $0.lastActivatedAt < $1.lastActivatedAt }
    }

    /// 当前工作区（平铺 + 浮动）里最近激活过的浏览器 pane；淡出中的不算
    func mostRecentBrowserPane() -> BrowserPaneView? {
        paneList.compactMap { $0 as? BrowserPaneView }
            .filter { !model.closingPanes.contains($0.id) }
            .max { $0.lastActivatedAt < $1.lastActivatedAt }
    }

    private func applyBrowserTheme(_ pane: BrowserPaneView) {
        pane.applyTheme(background: NSColor(themeManager.background), foreground: NSColor(themeManager.foreground))
    }

    /// 指定目录（与可选命令 / 额外环境）新建 surface。带 command 时引擎强制 wait-after-command，
    /// 调用方需自行处理退出（见 SurfaceView.closesOnChildExit）
    func newSurface(workingDirectory: String?, command: String? = nil,
                    environment: [String: String] = [:]) -> Ghostty.SurfaceView {
        var config = Ghostty.SurfaceConfiguration()
        config.workingDirectory = workingDirectory
        config.command = command
        config.environmentVariables = environment
        return Ghostty.SurfaceView(ghostty.app!, baseConfig: config)
    }

    /// 把新 pane 插进活动布局（scrolling：锚点右侧新列；dwindle：按锚点空间几何分裂 + 局部进场动效）并聚焦。
    /// 锚点默认为焦点 pane；文件管理器退出"原位开终端"时锚点是即将关闭的那个 pane。
    /// 返回是否真的插进了布局（dwindle 树非空却找不到可用锚点时为 false，调用方不得再引用该 pane）
    @discardableResult
    private func insertNewPane(_ pane: PaneView, anchor: PaneView? = nil) -> Bool {
        let anchor = anchor ?? focusedPane ?? paneList.first
        switch model.layout {
        case .scrolling(let strip):
            // 焦点列右侧插入新列（截图 3 语义），宽度按"每屏可见列数"
            model.layout = .scrolling(strip.insertingColumnRight(
                of: anchor, pane: pane, widthFactor: columnFactor))
        case .dwindle(let tree):
            // 锚点不在树里（如焦点是浮动 pane）→ 退回树的首叶
            let target = anchor.flatMap { tree.root?.node(view: $0) != nil ? $0 : nil } ?? tree.root?.leaves().first
            if tree.isEmpty {
                model.layout = .dwindle(SplitTree(view: pane))
            } else if let focused = target,
                      let t = try? tree.inserting(
                        view: pane, at: focused,
                        direction: tree.dwindleDirection(for: focused, in: dwindleLayoutSize)) {
                // 局部动效（TerminalSplitTreeView 读 appearingPane）：原 pane 从占满收缩到
                // ratio、新 pane 渐显；不整树重建。连按（<0.35s）第二次不播——父级在途动画
                // 会因子树换身份被丢弃而跳变。动画结束后清标记。
                let now = Date()
                let animate = lastSplitAnimationAt.map { now.timeIntervalSince($0) > 0.35 } ?? true
                model.appearingPane = animate ? pane.id : nil
                if animate { lastSplitAnimationAt = now }
                model.layout = .dwindle(t)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    if self?.model.appearingPane == pane.id { self?.model.appearingPane = nil }
                }
            } else {
                return false
            }
        }
        requestFocus(to: pane, from: anchor)
        return true
    }

    /// 文件管理器 pane 结束（子进程退出或引擎 close）：目录有变 → 先在旁边开终端并作为焦点接班人，
    /// 再关本 pane（关闭动效把空间交给新终端）。未登记的 pane 返回 false。
    private func finishFileManager(_ view: PaneView) -> Bool {
        guard let session = fileManagerSessions.removeValue(forKey: ObjectIdentifier(view)) else { return false }
        var replacement: PaneView?
        if paneList.contains(view), let dir = FileManagerLaunch.nextDirectory(session: session) {
            let pane = newSurface(workingDirectory: dir)
            pane.pwd = dir
            if insertNewPane(pane, anchor: view) { replacement = pane }
        }
        FileManagerLaunch.cleanup(session)
        closePane(view, confirmIfNeeded: false, successor: replacement)
        return true
    }

    @objc private func ghosttyChildExited(_ notification: Foundation.Notification) {
        guard let view = notification.object as? PaneView else { return }
        guard paneList.contains(view) else {
            // 非活动工作区里退出（切走后 pkill / 崩溃）：直接从所在工作区移除（本通知已在引擎回调栈外）
            removeFromAnyWorkspace(view)   // 内部清会话与临时文件
            return
        }
        if !finishFileManager(view) {
            closePane(view, confirmIfNeeded: false)
        }
    }

    /// 测试/扩展用：登记一个文件管理器会话（退出时按会话决定是否原位开终端）
    func registerFileManagerSession(_ view: PaneView, _ session: FileManagerLaunch.Session) {
        fileManagerSessions[ObjectIdentifier(view)] = session
    }

    private func forgetFileManagerSession(_ view: PaneView) {
        if let session = fileManagerSessions.removeValue(forKey: ObjectIdentifier(view)) {
            FileManagerLaunch.cleanup(session)
        }
    }

    /// 关闭一个 pane（scrolling 空列删除；dwindle 兄弟回收）；全部工作区皆空才关窗。
    /// successor：调用方指定的焦点接班人（如"原位开终端"的新 pane），nil 则按布局规则算
    func closePane(_ view: PaneView, confirmIfNeeded: Bool = true, animated: Bool = true,
                   successor: PaneView? = nil) {
        guard paneList.contains(view), !model.closingPanes.contains(view.id) else { return }
        // 文件管理器 pane 只是个查看器：有子进程也不弹"仍有进程在运行"的确认
        if confirmIfNeeded, view.wantsConfirmClose, fileManagerSessions[ObjectIdentifier(view)] == nil {
            // 确认对话框异步弹出：本方法可能正处在引擎 close_surface 回调栈内（键绑定 → Zig keyCallback），
            // 模态嵌套 run loop 期间若子进程退出会二次回调并同步释放 surface，返回后引擎栈仍触碰它（UAF）。
            // 先让引擎栈退出，再进模态；弹出时 pane 可能已被别的路径关掉，重新校验。
            DispatchQueue.main.async { [weak self, weak view] in
                guard let self, let view, self.paneList.contains(view) else { return }
                let alert = NSAlert()
                alert.messageText = "关闭这个终端？"
                alert.informativeText = "其中仍有进程在运行。"
                alert.addButton(withTitle: "关闭")
                alert.addButton(withTitle: "取消")
                guard alert.runModal() == .alertFirstButtonReturn else { return }
                guard self.paneList.contains(view), !self.model.closingPanes.contains(view.id) else { return }
                self.beginClose(view, animated: animated, successor: successor)
            }
            return
        }
        beginClose(view, animated: animated, successor: successor)
    }

    /// 关闭分两段（与创建动效对称）：先把焦点交给接班人并标记淡出——视图层播放收拢/渐隐——
    /// 动效到点后 finishClose 才真正移除并释放 surface。窗口不可见或动效关闭时直接移除。
    private func beginClose(_ view: PaneView, animated: Bool, successor explicit: PaneView? = nil) {
        guard animated, closeAnimationEnabled, window?.isVisible == true else {
            removePane(view, successor: explicit)
            return
        }
        let successor = explicit ?? closeSuccessor(of: view)
        // 焦点交接是异步的：同一轮里前一个关闭刚把焦点意图指向本 pane（pendingFocusTarget）
        // 时 focused 还是 false，也要把焦点接着往下传，别让意图落在一个淡出中的 pane 上
        if paneHoldsFocus(view) || pendingFocusTarget === view, let next = successor ?? firstLivePane(excluding: view) {
            requestFocus(to: next, from: view)
        }
        pendingCloses[ObjectIdentifier(view)] = PendingClose(view: view, successor: successor)
        model.closingPanes.insert(view.id)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.closeAnimationDuration + 0.02) {
            [weak self, weak view] in
            guard let self, let view else { return }
            self.finishClose(view)
        }
    }

    private func finishClose(_ view: PaneView) {
        guard let pending = pendingCloses.removeValue(forKey: ObjectIdentifier(view)) else { return }
        model.closingPanes.remove(view.id)
        guard paneList.contains(view) else { return }   // 已被别的路径移除
        let wasFocused = paneHoldsFocus(view)
        removeFromActiveLayout(view)  // 放弃引用 → SurfaceView.deinit 释放 surface
        // 焦点通常在 beginClose 已交出；仍在关闭方（如接班人期间被关掉）时再兜一次
        if wasFocused, let next = pending.successor.flatMap({ paneList.contains($0) ? $0 : nil })
            ?? firstLivePane(excluding: view) {
            requestFocus(to: next)
        }
    }

    /// pane 是否持有焦点：标志或真相（地址栏字段编辑器是 FR 时标志可能落后于真相）
    private func paneHoldsFocus(_ view: PaneView) -> Bool {
        view.focused || (window.map { view.holdsFirstResponder(of: $0) } ?? false)
    }

    /// 兜底焦点：第一个不在淡出中的 pane
    private func firstLivePane(excluding view: PaneView) -> PaneView? {
        paneList.first { $0 !== view && !model.closingPanes.contains($0.id) }
    }

    /// 淡出中的 pane 立即移除：布局操作 / 工作区切换 / 存档之前调用，保证它们看到的是真实布局
    func flushPendingCloses() {
        for pending in Array(pendingCloses.values) { finishClose(pending.view) }
    }

    /// 关闭 view 后应接管焦点的 pane（scrolling：左邻优先；dwindle：兄弟子树最近叶；浮动：无）。
    /// 在"其他淡出中的 pane 已移除"的布局上算：子进程同时退出等并发关闭（不经 perform，不 flush）
    /// 不能把焦点交给一个正在消失的 pane。
    private func closeSuccessor(of view: PaneView) -> PaneView? {
        let fading = paneList.filter { $0 !== view && model.closingPanes.contains($0.id) }
        switch model.layout {
        case .scrolling(var strip):
            for p in fading { strip = strip.removing(p) }
            return strip.focusTarget(from: view, direction: .left)
                ?? strip.focusTarget(from: view, direction: .right)
                ?? strip.focusTarget(from: view, direction: .up)
                ?? strip.focusTarget(from: view, direction: .down)
        case .dwindle(var tree):
            for p in fading { if let n = tree.root?.node(view: p) { tree = tree.removing(n) } }
            // Hyprland dwindle 语义：焦点交给接管空间的兄弟子树中最近的 pane（下一个，否则上一个）
            return tree.closeSuccessor(of: view)
        }
    }

    /// 同步移除（无动效路径）
    private func removePane(_ view: PaneView, successor explicit: PaneView? = nil) {
        let wasFocused = paneHoldsFocus(view)
        let successor = explicit ?? closeSuccessor(of: view)   // 删除前算：删完兄弟关系就没了
        removeFromActiveLayout(view)  // 放弃引用 → SurfaceView.deinit 释放 surface
        // 最后一个 pane 关闭后窗口保留（RootView 显示"新建终端"提示），不退出程序；
        // 退出只由 Cmd+Q / 菜单触发（AppDelegate.applicationShouldTerminate 决定是否确认）
        // paneList 含浮动层：平铺层清空但还有浮动 pane 时，焦点也要有去处
        if !paneList.isEmpty, wasFocused, let next = successor ?? paneList.first {
            requestFocus(to: next)
        }
    }

    /// 在任一工作区里找到并移除（活动工作区用 removeFromActiveLayout，那条路径还管焦点）
    private func removeFromAnyWorkspace(_ view: PaneView) {
        forgetFileManagerSession(view)
        (view as? BrowserPaneView)?.paneWillClose()
        for i in model.layouts.indices {
            if let idx = model.floatings[i].firstIndex(where: { $0.pane === view }) {
                model.floatings[i].remove(at: idx)
                return
            }
            switch model.layouts[i] {
            case .dwindle(let tree):
                if let node = tree.root?.node(view: view) {
                    model.layouts[i] = .dwindle(tree.removing(node))
                    return
                }
            case .scrolling(let strip):
                if strip.paneList.contains(where: { $0 === view }) {
                    model.layouts[i] = .scrolling(strip.removing(view))
                    return
                }
            }
        }
    }

    private func removeFromActiveLayout(_ view: PaneView) {
        forgetFileManagerSession(view)
        (view as? BrowserPaneView)?.paneWillClose()
        if let idx = model.floating.firstIndex(where: { $0.pane === view }) {
            model.floating.remove(at: idx)
            floatingDrag = nil        // 索引已失效（拖动途中被到点移除时不能再用）
            resetFloatingCursor()
            if resizeTarget === view { resizeTarget = nil }
            return
        }
        switch model.layout {
        case .dwindle(let tree):
            guard let node = tree.root?.node(view: view) else { return }
            model.layout = .dwindle(tree.removing(node))
        case .scrolling(let strip):
            model.layout = .scrolling(strip.removing(view))
        }
    }

    @objc private func ghosttyDidEqualizeSplits(_ note: Foundation.Notification) {
        perform(.equalize)
    }

    @objc private func ghosttyDidCloseSurface(_ notification: Foundation.Notification) {
        guard let view = notification.object as? PaneView else { return }
        if view === model.scratchpadSurface {
            model.scratchpadVisible = false
            model.scratchpadSurface = nil
            return
        }
        guard paneList.contains(view) else {
            // 非活动工作区里的 pane（如切走后 shell 退出）：直接从所在工作区移除，不动焦点。
            // 异步：本方法在引擎 close_surface 回调栈内，后台 pane 没有 SwiftUI 持有，
            // 同步放弃引用会立刻 free 仍在引擎栈上的 surface
            DispatchQueue.main.async { [weak self] in self?.removeFromAnyWorkspace(view) }
            return
        }
        let processAlive = (notification.userInfo?["process_alive"] as? Bool) ?? false
        if finishFileManager(view) { return }   // 文件管理器：按键触发的引擎 close 路径同样处理
        closePane(view, confirmIfNeeded: processAlive)
    }

    // MARK: SwiftUI 回调（dwindle 分隔条 / 双布局拖放）

    func handleSplitOperation(_ op: TerminalSplitOperation) {
        flushPendingCloses()   // 拖放/拖分隔条不经 perform：先落到真实布局
        guard case .dwindle(let tree) = model.layout else { return }
        switch op {
        case .resize(let resize):
            let resized = resize.node.resizing(to: resize.ratio)
            model.layout = .dwindle((try? tree.replacing(node: resize.node, with: resized)) ?? tree)
        case .equalize:
            perform(.equalize)
        case .drop(let drop):
            handleDwindleDrop(drop, tree: tree)
        }
    }

    private func handleDwindleDrop(_ drop: TerminalSplitOperation.Drop,
                                   tree: SplitTree<PaneView>) {
        guard drop.payload !== drop.destination else { return }
        if drop.zone == .center {
            if let swapped = try? tree.swapping(drop.payload, drop.destination) {
                model.layout = .dwindle(swapped)
                requestFocus(to: drop.payload)
            }
            return
        }
        let direction: SplitTree<PaneView>.NewDirection = switch drop.zone {
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
            requestFocus(to: drop.payload)
        }
    }

    /// scrolling 布局拖放（spec §4.2-bis：左右缘=插新列、上下缘=併栈、中心=交换）
    func scrollingDrop(payload: PaneView,
                       destination: PaneView,
                       zone: TerminalSplitDropZone) {
        flushPendingCloses()
        guard case .scrolling(let strip) = model.layout else { return }
        model.layout = .scrolling(strip.dropping(payload, on: destination, zone: zone))
        requestFocus(to: payload)
    }
}

private extension ScrollingStrip.Direction {
    var spatial: SplitTree<PaneView>.Spatial.Direction {
        switch self {
        case .left: .left
        case .right: .right
        case .up: .up
        case .down: .down
        }
    }
}

// MARK: - 浏览器扩展宿主（pane = 扩展眼里的窗口）

extension MainWindowController: BrowserExtensionHost {
    /// 全部工作区（含浮动层与 scratchpad）里的浏览器 pane
    var browserPanes: [BrowserPaneView] { allPanes.compactMap { $0 as? BrowserPaneView } }

    /// 持 first responder 的浏览器 pane；没有就取最近激活的那个
    var focusedBrowserPane: BrowserPaneView? {
        if let window, let holder = browserPanes.first(where: { $0.holdsFirstResponder(of: window) }) {
            return holder
        }
        return mostRecentBrowserPaneAnywhere()
    }

    /// 扩展的 windows.create：在活动工作区新开一个浏览器 pane
    @discardableResult
    func openBrowserWindow(url: URL?) -> BrowserPaneView? {
        openBrowserPane(url: url ?? BrowserPaneView.settings.homeURL, from: focusedPane)
    }
}
