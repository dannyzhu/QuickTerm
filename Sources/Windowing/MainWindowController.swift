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
    /// 进程级会话（配置 / 键位 / 系统状态 / 全屏账本）。会话经注册表强持有本控制器，故必须 unowned
    unowned let session: AppSession
    /// 共享键位表：只读引用，控制器绝不自己重建（重载时 AppSession 换一份，所有屏幕同步）
    var keybindings: KeybindingMap { session.keybindings }
    /// 进程唯一的系统状态轮询（注入 RootView）
    var stats: SystemStatsService { session.stats }
    var themeManager: ThemeManager { session.themeManager }
    private var keyMonitor: Any?
    private var mouseMonitor: Any?
    private var cancellables = Set<AnyCancellable>()
    /// 每个 pane 一条「标题 / cwd 变化」订阅（控制面事件用），随 pane 集合增删
    private var paneEventSubscriptions: [ObjectIdentifier: AnyCancellable] = [:]
    /// 每个 pane 一条「存档内容变化」订阅（见 `resubscribePaneSaves`），随 pane 集合增删
    private var paneSaveSubscriptions: [ObjectIdentifier: AnyCancellable] = [:]
    private var lastSplitAnimationAt: Date?
    /// 关闭动效时长（与创建动效同源）；到点后才真正从布局移除、释放 surface
    static let closeAnimationDuration: TimeInterval = 0.28
    /// 关闭动效开关（系统"减弱动态效果"时关；测试可显式打开）
    var closeAnimationEnabled: Bool = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    /// 淡出中的 pane 及其预先算好的焦点接班人（关闭开始时树还完整，接班关系才算得出）
    private var pendingCloses: [ObjectIdentifier: PendingClose] = [:]
    /// 文件管理器程序（config `file-manager-command`，默认 yazi）——进程级设置，转发到 AppSession
    var fileManagerCommand: String {
        get { session.fileManagerCommand }
        set { session.fileManagerCommand = newValue }
    }
    /// 终端里 ⌘+点击的链接开在哪（config link-opener）：browser-pane = 浏览器 pane；system = 系统默认浏览器
    var linkOpener: String {
        get { session.linkOpener }
        set { session.linkOpener = newValue }
    }
    /// 运行中的文件管理器 pane → 会话（退出时读 cwd 文件决定是否原位开终端；关闭不弹进程确认）
    private var fileManagerSessions: [ObjectIdentifier: FileManagerLaunch.Session] = [:]

    /// 控制面（`state` / `list` / `role:` 谓词）看到的 pane 角色。
    /// 文件管理器 pane 就是一个跑着 yazi 的终端——`kind` 仍是 terminal，靠 role 区分
    func controlRole(of pane: PaneView) -> String? {
        if fileManagerSessions[ObjectIdentifier(pane)] != nil { return "file-manager" }
        return pane.kind == .terminal ? "shell" : nil
    }
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
    private var stripPanSerial = 0
    /// 本屏幕的序号（0 = 第一个屏幕，标题恒为 `QuickTerm`）；关掉后序号可被新屏幕复用
    let screenIndex: Int
    /// 本屏幕在存档里的稳定身份（跨启动不变；`PersistedState.keyWindowID` 指的就是它）
    let windowID: UUID
    /// 窗口已经走过 windowWillClose（监视器/观察者已拆）
    private(set) var isClosed = false

    /// scrolling 每屏可见列数（2 默认；菜单循环 2→3→4；config `visible-columns` 优先）
    private(set) var visibleColumns =
        UserDefaults.standard.object(forKey: "quickterm.visibleColumns") as? Int ?? 2
    var columnFactor: Double { ScrollingStrip.factor(forVisibleColumns: visibleColumns) }

    /// 悬停即焦点（spec §4.2，忠实 Hyprland focus_follows_mouse）。
    override var focusFollowsMouse: Bool { true }

    /// 屏幕关掉之后（监视器已拆、pane 已归还）不再接受 pane 操作：脱离窗口的 pane 不得据此复活本控制器
    override var acceptsPaneOperations: Bool { !isClosed }

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

    /// - Parameters:
    ///   - screen: 目标显示器（nil = 主显示器）；窗口在它的 visibleFrame 内居中，同屏已有窗口时层叠偏移
    ///   - index: 屏幕序号（0 = 第一个，标题 `QuickTerm`）
    ///   - restoring: true = 由 `SessionStore` 随后灌入存档（本控制器不自己开起步终端、也不自己读盘）
    ///   - id: 存档里的窗口身份（恢复时沿用旧 id，新建时随机）
    ///   - restoredFrame: 存档里的窗口 frame（会被收进目标显示器的可见区）
    ///   - inheritedDirectory: 新屏幕首个终端继承的 cwd（来自源窗口焦点 pane）
    init(ghostty: Ghostty.App, session: AppSession,
         screen: NSScreen? = nil, index: Int = 0, restoring: Bool = false,
         id: UUID = UUID(), restoredFrame: CGRect? = nil,
         inheritedDirectory: String? = nil) {
        self.ghostty = ghostty
        self.session = session
        self.screenIndex = index
        self.windowID = id
        let window = HiddenTitlebarWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1024, height: 720),
            styleMask: [],  // HiddenTitlebarWindow 内部固定样式
            backing: .buffered, defer: false)
        window.title = ScreenRegistry.title(forIndex: index)
        super.init(window: window)
        window.windowController = self
        window.delegate = self

        // 焦点对账兜底：布局/工作区/浮动层任何变化都会让 SwiftUI 重挂 SurfaceView，
        // 重挂后 focused 标志可能与窗口 FR 脱节（见 SurfaceView.viewWillMove(toWindow:)）
        for publisher in [model.$layouts.map { _ in () }.eraseToAnyPublisher(),
                          model.$floatings.map { _ in () }.eraseToAnyPublisher(),
                          model.$titles.map { _ in () }.eraseToAnyPublisher(),
                          model.$activeIndex.map { _ in () }.eraseToAnyPublisher()] {
            publisher.dropFirst().sink { [weak self] in
                guard let self else { return }
                self.scheduleFocusReconcile()
                // 布局 / 浮动层 / 活动工作区任何变化都排一次防抖存档（1.5.x 只在退出时存一次，
                // 崩溃或强制退出会丢掉整个会话）
                self.session.sessionStore.scheduleSave()
                // pane 集合可能变了：重订阅每个 pane 的「存档内容变化」（终端 cwd / 浏览器网页）。
                // @Published 在 willSet 发布——此刻 model.layouts 还是旧值，必须等它落定再读
                DispatchQueue.main.async { [weak self] in self?.resubscribePaneSaves() }
            }
            .store(in: &cancellables)
        }

        // 控制面事件（Phase 4）：单独一条 sink，**不并进上面那条**——
        // 那条每次触发都会排一次防抖存档与一次焦点对账，而关闭动效（closingPanes）
        // 只是"这个 pane 已经不可寻址了"，不该顺带多写一次盘。
        // 这里只报一声"有东西可能变了"，具体发生了什么由 `ControlEventBus` 与上一份快照相减得出：
        // 每处手写 emit 必然漏，而 `perform()` 可重入又会让同一件事被报好几遍
        for publisher in [model.$layouts.map { _ in () }.eraseToAnyPublisher(),
                          model.$floatings.map { _ in () }.eraseToAnyPublisher(),
                          model.$titles.map { _ in () }.eraseToAnyPublisher(),
                          model.$activeIndex.map { _ in () }.eraseToAnyPublisher(),
                          model.$closingPanes.map { _ in () }.eraseToAnyPublisher()] {
            publisher.dropFirst().sink { ControlEventBus.noteChange() }.store(in: &cancellables)
        }

        window.contentView = NSHostingView(rootView: RootView(
            model: model, ghostty: ghostty, stats: stats,
            action: { [weak self] op in self?.handleSplitOperation(op) },
            onScrollingDrop: { [weak self] payload, dest, zone in
                self?.scrollingDrop(payload: payload, destination: dest, zone: zone)
            },
            onSelectWorkspace: { [weak self] i in self?.switchWorkspace(i) },
            onRenameWorkspace: { [weak self] i in self?.promptWorkspaceTitle(i) },
            onPanelChoose: { [weak self] i in self?.choosePanelItem(i) })
            .environmentObject(themeManager))

        // 主题热切换：overlay 变更 → 全部 surface 热重载（spec §3.2，< 200ms）。
        // 引擎 app 级 reloadConfig 由 AppDelegate 统一做一次（多屏幕下不重复 N 次）
        themeManager.addOverlayListener(token: self) { [weak self] in
            guard let self else { return }
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

        // 配置链第 4 层：config.toml（键位/工作区数/主题/[ghostty] 透传）。
        // 读盘、模板补全、监听与全局部分（键位表 / 引擎 overlay / 浏览器全局设置）全归 AppSession；
        // 这里只把已经加载好的那份落到本屏幕上
        applyWindowConfig(session.settings)

        // 状态恢复（spec §4.8 / v9 §3）：读盘与迁移全归 `SessionStore`——它建完控制器后调
        // `restore(from:)` 灌入布局（restoring = true）。这里只负责「不恢复」的那条路：
        // 一个空白终端起步（继承源窗口焦点 pane 的 cwd）。
        // 视图尚未被 SwiftUI 挂载：直接 makeFirstResponder 返回 true 却什么都不做（AppKit 报
        // "different window ((null))"），用 Ghostty.moveFocus（等待挂载后再设）
        if !restoring { ensureStarterPane(inheriting: inheritedDirectory) }
        place(on: screen, restoredFrame: restoredFrame)
        window.makeKeyAndOrderFront(nil)

        // 引擎发的这三个通知都以 SurfaceView 为 object 且按 object: nil 注册：
        // 多屏幕下每个控制器都会收到，处理函数开头一律先判归属（见 ghosttyDidCloseSurface 等）
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
            // ⌘ 状态是进程级的：不管事件落在哪个窗口、哪种类型都按事件自带的修饰键重新同步
            // （NSAlert / sheet / popover 成为 key 时事件不属于任何终端窗口；⌘ 的抬起落在别的 app 上时
            // 本地监视器根本看不到——漏掉就会让拖拽源浮层残留：抓手光标不消失、滚轮被浮层吃掉）。
            // N 个控制器写同一个值，幂等；只在真变了时候写，省掉多余的 @Published 通知
            ModifierState.shared.sync(event.modifierFlags)
            if event.type == .flagsChanged {
                // 光标复位只归事件所属窗口的控制器
                guard event.window == nil || event.window === self.window else { return event }
                if !event.modifierFlags.contains(.command), self.floatingDrag == nil { self.resetFloatingCursor() }
                return event
            }
            // 多屏幕：会话内的鼠标事件只认本窗口的（另一个屏幕上的拖动不得驱动本控制器的会话）
            if self.floatingDrag != nil || self.resizeTarget != nil,
               event.window !== self.window { return event }
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
            // 滚轮也顺手同步 ⌘ 状态：错过一次抬起就"终端再也滚不动"的老账在这里也能自愈
            ModifierState.shared.sync(event.modifierFlags)
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
            // ⌘ 拖拽源浮层盖着 pane 时（浮层是 pane 的兄弟子树，沿 superview 找不到 pane），
            // 按它盖住的 pane 认领滚轮
            func effectiveHit(_ point: NSPoint) -> NSView? {
                let hit = content.hitTest(point)
                return (hit as? PaneOverlaying)?.overlaidPane ?? hit
            }
            // 溢出的浏览器标签条自己吃横向滚轮（监视器跑在视图派发之前，否则永远轮不到它）
            if let hit = effectiveHit(p),
               let bar = sequence(first: hit, next: { $0.superview })
                   .compactMap({ $0 as? BrowserTabBarView }).first,
               bar.isOverflowing {
                return event
            }
            // 激活的浏览器 pane 自己吃双指横滑（网页横向滚动 / 前进后退手势），不平移画布
            if let hit = effectiveHit(p), self.browserPaneClaimingScroll(under: hit) != nil {
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

    /// 鼠标下的视图属于某个**持有键盘焦点**的浏览器 pane 时返回它：这时的滚轮 / 双指横滑归网页，
    /// 不做画布平移。没激活的浏览器 pane 照旧平移画布（只是路过）
    func browserPaneClaimingScroll(under view: NSView) -> BrowserPaneView? {
        guard let window,
              let pane = sequence(first: view, next: { $0.superview }).compactMap({ $0 as? BrowserPaneView }).first,
              pane.holdsFirstResponder(of: window) else { return nil }
        return pane
    }

    // MARK: config.toml（配置链第 4 层，spec §4.7）
    // 读盘 / 监听 / 去重 / 全局部分都在 AppSession；这里只负责把一份 Settings 落到**本屏幕**上。
    // 判断标准：改了会影响别的屏幕的（键位表、引擎 overlay、BrowserPaneView.settings、扩展开关）
    // 一律归 applyGlobalConfig，一次重载只做一遍

    func applyWindowConfig(_ settings: ConfigStore.Settings) {
        // 空工作区提示用当前实际绑定（键位表来自 AppSession）
        model.newTerminalCombo = keybindings.displayBindings()
            .first { $0.action == .newTerminal }?.combo ?? "Cmd+Return"
        for case let browser as BrowserPaneView in allPanes { browser.applySettings() }   // UA / Inspector 热重载
        model.setWorkspaceCount(settings.workspaces)
        if let n = settings.visibleColumns { setVisibleColumns(n, persist: false) }
    }

    // MARK: 状态存取（spec §4.8 / v9 §3；读盘与迁移在 `SessionStore`，这里只管一个窗口的那一片）

    /// 本屏幕的存档切片（`SessionStore.snapshot()` 逐个窗口调用）。
    /// **纯读取**：存档现在由防抖定时器触发，快照绝不能改动屏幕上的东西——
    /// 淡出中的 pane 只从副本里滤掉（不 flush，否则会把正在播放的关闭动效截断）
    func windowState() -> WindowState {
        var layouts = model.layouts
        var floatings = model.floatings
        let closing = model.closingPanes
        if !closing.isEmpty {
            for i in layouts.indices {
                for pane in layouts[i].paneList where closing.contains(pane.id) {
                    switch layouts[i] {
                    case .scrolling(let strip):
                        layouts[i] = .scrolling(strip.removing(pane))
                    case .dwindle(let tree):
                        guard let node = tree.root?.node(view: pane) else { continue }
                        layouts[i] = .dwindle(tree.removing(node))
                    }
                }
            }
            for i in floatings.indices { floatings[i].removeAll { closing.contains($0.pane.id) } }
        }
        // 全屏中窗口自己贴满显示器：要存的是退出全屏后要恢复的那个 frame
        return WindowState(
            id: windowID,
            layouts: layouts,
            floatings: floatings,
            activeIndex: model.activeIndex,
            // 一个名字都没起过就整条字段不写：绝大多数存档里它是一串 null，没必要占地方
            workspaceTitles: model.titles.contains(where: { $0 != nil }) ? model.titles : nil,
            visibleColumns: visibleColumns,
            display: DisplayRef(screen: window?.screen),
            frame: savedFrame ?? window?.frame,
            isFullscreen: isSimpleFullscreen,
            joinAllSpaces: joinsAllSpaces,
            focusedPaneID: focusedPane.flatMap { closing.contains($0.id) ? nil : $0.id })
    }

    /// 每个 pane 一条「存档内容变化」订阅（终端 cwd 走 `$pwd`，浏览器走 `archiveDidChange`）。
    /// 布局事件之外 `cd` / 打开网页也要能进档——否则崩溃 / 强制退出后复原的是上一次布局变化时的目录与网页。
    /// pane 集合变化（新建 / 恢复 / 拖入 / 关闭）都会经布局 sink 走到这里，重订阅即可
    private func resubscribePaneSaves() {
        guard !isClosed else { return }
        let live = model.allPanes
        let ids = Set(live.map(ObjectIdentifier.init))
        paneSaveSubscriptions = paneSaveSubscriptions.filter { ids.contains($0.key) }
        for pane in live where paneSaveSubscriptions[ObjectIdentifier(pane)] == nil {
            let changes: AnyPublisher<Void, Never>
            if let terminal = pane as? Ghostty.SurfaceView {
                // dropFirst：订阅那一刻的当前值不是「变化」；removeDuplicates：多数 shell 每个提示符都发一次 OSC 7
                changes = terminal.$pwd.dropFirst().removeDuplicates().map { _ in () }.eraseToAnyPublisher()
            } else {
                changes = pane.archiveDidChange.eraseToAnyPublisher()
            }
            paneSaveSubscriptions[ObjectIdentifier(pane)] = changes.sink { [weak self] in
                self?.session.sessionStore.scheduleSave()
            }
        }
        // 控制面的 pane.title.changed / pane.cwd.changed 走同一条重订阅路径：
        // 终端的标题与 OSC 7 的 pwd 都是 @Published，浏览器 pane 的网页变化走 archiveDidChange。
        // **事件里只会出现标题与 cwd，绝不会出现 pane 的输出内容**
        paneEventSubscriptions = paneEventSubscriptions.filter { ids.contains($0.key) }
        for pane in live where paneEventSubscriptions[ObjectIdentifier(pane)] == nil {
            let changes: AnyPublisher<Void, Never>
            if let terminal = pane as? Ghostty.SurfaceView {
                changes = terminal.$title.dropFirst().removeDuplicates().map { _ in () }
                    .merge(with: terminal.$pwd.dropFirst().removeDuplicates().map { _ in () })
                    .eraseToAnyPublisher()
            } else {
                changes = pane.archiveDidChange.eraseToAnyPublisher()
            }
            paneEventSubscriptions[ObjectIdentifier(pane)] = changes.sink {
                ControlEventBus.noteChange()
            }
        }
    }

    /// 起步 pane：没有任何 pane 时开一个终端（新建屏幕，以及存档为空的兜底）
    func ensureStarterPane(inheriting directory: String? = nil) {
        guard model.allPanes.isEmpty else { return }
        let first = newSurface(workingDirectory: directory)
        model.layout = .scrolling(ScrollingStrip(pane: first, widthFactor: columnFactor))
        requestFocus(to: first)
    }

    /// 灌入一份存档（每 pane 按存档 cwd 重开 shell、每个浏览器 pane 重开它的标签页）；
    /// 空存档 → false（调用方开一个空白终端）
    @discardableResult
    func restore(from state: WindowState) -> Bool {
        // 列宽归一要用最终的列因子：可见列数必须先落（此时布局还空，不会触发重排）。
        // config.toml 明确写了 `visible-columns` 时以配置为准——配置层永远压过存档
        if session.settings.visibleColumns == nil, let columns = state.visibleColumns {
            setVisibleColumns(columns, persist: false)
        }
        let restored = applyArchive(layouts: state.layouts, floatings: state.floatings,
                                    activeIndex: state.activeIndex, titles: state.workspaceTitles)
        guard restored else { return false }
        for case let browser as BrowserPaneView in allPanes { applyBrowserTheme(browser) }   // 恢复的浏览器 pane 也套主题
        // 存档里的焦点 pane 优先（只在活动工作区里找：别把焦点交给一个没挂载的工作区）；
        // 旧档 / 找不到 → 退回第一块 pane（与 v4 行为一致）
        let target = state.focusedPaneID.flatMap { id in paneList.first { $0.id == id } } ?? focusedPane
        if let target { requestFocus(to: target) }
        joinsAllSpaces = state.joinAllSpaces
        if state.isFullscreen, !isSimpleFullscreen { toggleSimpleFullscreen() }
        return true
    }

    /// 布局/浮动层/活动工作区三件套的落地（v2–v5 共用；含历史列宽归一与浮动层补齐）
    private func applyArchive(layouts: [WorkspaceLayout], floatings rawFloatings: [[FloatingPane]]?,
                              activeIndex: Int, titles: [String?]? = nil) -> Bool {
        let floatings = rawFloatings ?? Array(repeating: [], count: layouts.count)
        guard !(layouts.allSatisfy(\.isEmpty) && floatings.allSatisfy(\.isEmpty)) else { return false }
        // 旧状态归一：0.49（露边 2% 时代）/ 0.44（露边 6% 时代）是历史默认列宽，
        // 归到当前列因子；用户手动调过的宽度原样保留
        let legacyDefaults = [0.49, 0.44]
        model.layouts = layouts.map { layout in
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
        // 名字先落，再让 setWorkspaceCount 去对齐长度（老档没有这一项 = 一个名字都没起过）
        if let titles { model.titles = titles }
        model.setWorkspaceCount(max(model.layouts.count, 1))
        model.activeIndex = min(max(activeIndex, 0), model.layouts.count - 1)
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

    // MARK: 窗口放置与屏幕生命周期（多屏幕，spec v9 §1.2）

    /// 同一显示器上已有的 QuickTerm 屏幕窗口（层叠偏移用）
    private static func siblingWindows(excluding window: NSWindow, on screen: NSScreen?) -> [NSWindow] {
        NSApp.windows.filter {
            $0 !== window && $0.isVisible && $0.windowController is MainWindowController
                && (screen == nil || $0.screen === screen)
        }
    }

    /// 放置窗口：给定显示器时在其 visibleFrame 内居中，同屏已有窗口则层叠偏移，最后一律 constrainFrameRect。
    /// 未指定显示器且是本进程第一个窗口时保持历史行为（window.center()）。
    /// `restoredFrame`（存档恢复）优先：原样落回去，只按目标显示器的可见区收一收
    private func place(on screen: NSScreen?, restoredFrame: CGRect? = nil) {
        guard let window else { return }
        if let restoredFrame {
            guard let target = screen ?? NSScreen.main else {
                window.setFrame(restoredFrame, display: false)
                return
            }
            let fitted = SessionStore.constrain(restoredFrame, into: target.visibleFrame)
            window.setFrame(window.constrainFrameRect(fitted, to: target), display: false)
            return
        }
        let siblings = Self.siblingWindows(excluding: window, on: screen ?? NSScreen.main)
        guard let target = screen ?? NSScreen.main else { window.center(); return }
        guard screen != nil || !siblings.isEmpty else { window.center(); return }
        let visible = target.visibleFrame
        var frame = window.frame
        frame.size.width = min(frame.width, visible.width)
        frame.size.height = min(frame.height, visible.height)
        // 居中 + 层叠偏移（同屏第 n 个窗口向右下偏 n×24pt，第 7 个回到起点）
        let step = CGFloat(siblings.count % 6) * 24
        frame.origin = CGPoint(x: visible.midX - frame.width / 2 + step,
                               y: visible.midY - frame.height / 2 - step)
        frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
        frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
        window.setFrame(window.constrainFrameRect(frame, to: target), display: false)
    }

    /// 把本屏幕搬到另一台显示器：保持窗口大小（超出则收），按在原屏可见区里的相对位置落点
    func move(to screen: NSScreen) {
        guard let window, window.screen !== screen else { return }
        let visible = screen.visibleFrame
        // 全屏中窗口自己贴满旧显示器：真正要搬的是退出全屏后要恢复的那个 frame
        var frame = savedFrame ?? window.frame
        frame.size.width = min(frame.width, visible.width)
        frame.size.height = min(frame.height, visible.height)
        let source = (window.screen ?? NSScreen.main)?.visibleFrame
        if let source, source.width > frame.width || source.height > frame.height {
            let rx = source.width > frame.width ? (frame.minX - source.minX) / (source.width - frame.width) : 0.5
            let ry = source.height > frame.height ? (frame.minY - source.minY) / (source.height - frame.height) : 0.5
            frame.origin = CGPoint(x: visible.minX + rx * max(visible.width - frame.width, 0),
                                   y: visible.minY + ry * max(visible.height - frame.height, 0))
        } else {
            frame.origin = CGPoint(x: visible.midX - frame.width / 2, y: visible.midY - frame.height / 2)
        }
        let placed = window.constrainFrameRect(frame, to: screen)
        if savedFrame != nil {
            // 全屏中：窗口跟着贴合新显示器，退出全屏时也要落在新显示器上（否则一退全屏就跳回去）
            savedFrame = placed
            window.setFrame(screen.frame, display: true)
        } else {
            window.setFrame(placed, display: true)
        }
    }

    /// 「在所有桌面显示」：Spaces 无法用公开 API 指定，能提供的只有 canJoinAllSpaces
    var joinsAllSpaces: Bool {
        get { window?.collectionBehavior.contains(.canJoinAllSpaces) ?? false }
        set {
            guard let window else { return }
            var behavior = window.collectionBehavior
            if newValue {
                behavior.insert(.canJoinAllSpaces)
                behavior.remove(.moveToActiveSpace)
            } else {
                behavior.remove(.canJoinAllSpaces)
            }
            window.collectionBehavior = behavior
        }
    }

    /// 右键工作区胶囊：给这个**槽位**起名 / 改名。
    /// 形状与终端的「Change Terminal Title」一模一样（NSAlert + 一行文本框 + 好 / 取消），
    /// 留空 = 清掉名字、胶囊回到序号。只有这条路和 `quickterm workspace set --title` 能改名字——
    /// 清空工作区、关掉最后一个 pane、spec apply 都不碰它
    func promptWorkspaceTitle(_ index: Int) {
        guard model.layouts.indices.contains(index), !AppDelegate.isRunningTests else { return }
        let alert = NSAlert()
        alert.messageText = "给工作区 \(index + 1) 起个名字"
        alert.informativeText = "留空 = 恢复显示序号。名字跟着这个槽位走，清空工作区也不会丢。"
        alert.alertStyle = .informational
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 250, height: 24))
        field.stringValue = model.title(at: index) ?? ""
        alert.accessoryView = field
        alert.addButton(withTitle: "好")
        alert.addButton(withTitle: "取消")
        alert.window.initialFirstResponder = field
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            // 上限与控制面那条命令同源；这里是人在打字，超了就截断而不是报错。
            // 控制字符也一样得在这儿滤掉：这块 `NSTextField` 收得下粘贴进来的换行，
            // 而一个带换行的名字会把胶囊排成两行、顶破 26pt 的状态条
            self.model.setTitle(WorkspaceModel.titleFromInput(field.stringValue), at: index)
        }
        // 有窗口就走 sheet（与「Change Terminal Title」同）：模态框飘在别的屏幕上会让人找不着
        if let window {
            alert.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(alert.runModal())
        }
    }

    /// 关闭这个屏幕前的确认（复用退出确认的计数与文案）；无活跃 pane 直接放行
    func confirmCloseScreen() -> Bool {
        flushPendingCloses()
        let open = model.allPanes.count
        guard AppDelegate.shouldConfirmQuit(openPaneCount: open), !AppDelegate.isRunningTests else { return true }
        let alert = NSAlert()
        alert.messageText = "关闭这个屏幕？"
        alert.informativeText = "还有 \(open) 个终端打开着，关闭会结束其中的进程。"
        alert.addButton(withTitle: "关闭")
        alert.addButton(withTitle: "取消")
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// 拆掉一切会在窗口关掉后仍然活着的东西。窗口关闭时显式调用（不依赖 deinit 顺序）：
    /// 监视器 / 通知 / 主题监听的闭包留着就会吊住控制器，弱引用用例会红
    private func teardown() {
        guard !isClosed else { return }
        isClosed = true
        flushPendingCloses()
        NotificationCenter.default.removeObserver(self)
        themeManager.removeOverlayListener(token: self)
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor); self.mouseMonitor = nil }
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor); self.scrollMonitor = nil }
        cancellables.removeAll()
        paneSaveSubscriptions.removeAll()
        paneEventSubscriptions.removeAll()
        floatingDrag = nil
        resizeTarget = nil
        // 非原生全屏的 presentationOptions 是进程级的：本窗口申请过就得还回去（按窗口记账，
        // 只还自己那一份——别的屏幕还在全屏时 Dock 与菜单栏必须继续藏着）
        savedFrame = nil
        session.setSimpleFullscreen(false, for: self)
        // 与 removeFromActiveLayout / removeFromAnyWorkspace 同一份 pane 级收尾：浏览器 pane
        // 要取消进行中的下载、告诉扩展"窗口"关了（deinit 只 tearDown 标签，这些都不做）。
        // 必须赶在拆视图层级之前：WebKit 处理 didCloseWindow 时会同步回查 tab.window(for:)
        ControlUndo.invalidate()
        for pane in model.allPanes {
            forgetFileManagerSession(pane)
            (pane as? BrowserPaneView)?.paneWillClose()
        }
        // 显式拆掉视图层级：pane 由 SwiftUI 的视图树强持有，窗口对象被 AppKit 多留一会儿
        // 就会让这个屏幕里的 shell 一直活着。关屏幕就该结束里面的进程
        window?.contentView = nil
        model.layouts = model.layouts.map { _ in .empty }
        model.floatings = model.floatings.map { _ in [] }
        model.scratchpadVisible = false
        model.scratchpadSurface = nil
        // 保底：没登记在 allPanes 里的会话（正常应为空，上面的循环已经逐个清过）
        for session in fileManagerSessions.values { FileManagerLaunch.cleanup(session) }
        fileManagerSessions.removeAll()
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

    /// ⌘+右键拖拽：dwindle 调就近分隔条；scrolling 按横向位移调列宽。
    /// 两条都只是**这一个手势**到 `controlResizeSplit` / `controlResizeColumn` 的换算——
    /// 真正的算法只有那一份，控制面的 `pane resize --dir` 调的是同一个函数
    private func resizeByDrag(pane: PaneView, dx: CGFloat, dy: CGFloat) {
        switch model.layout {
        case .dwindle:
            // 单个事件的位移封顶 200pt：手势偶尔会甩出一个离谱的增量
            let amount = min(max(abs(dx) >= abs(dy) ? abs(dx) : abs(dy), 1), 200)
            let direction: SplitTree<PaneView>.Spatial.Direction =
                abs(dx) >= abs(dy) ? (dx > 0 ? .right : .left) : (dy > 0 ? .down : .up)
            controlResizeSplit(pane, workspace: model.activeIndex, points: amount, direction: direction)
        case .scrolling:
            controlResizeColumn(pane, workspace: model.activeIndex, deltaPoints: dx)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    deinit {
        // 正常路径已在 windowWillClose 的 teardown 里拆干净；这里是没走关闭流程时的保底
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
            let made = makeFileManagerPane(startDirectory: start)
            // 只有真的跑起文件管理器才登记会话（免关闭确认 + 退出读目录）；
            // 程序缺失开出的提示 pane 是普通交互 shell，按普通 pane 处理
            if insertNewPane(made.pane), made.launch.found {
                fileManagerSessions[ObjectIdentifier(made.pane)] = made.launch.session
            } else {
                FileManagerLaunch.cleanup(made.launch.session)
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

    /// dwindle 布局区尺寸（contentView 去掉顶部状态条；决定分裂方向的宽高比）。
    /// 控制面往非活动工作区插 pane 时也要它——两处必须是同一份几何
    var dwindleLayoutSize: CGSize? {
        guard let content = window?.contentView else { return nil }
        let barH: CGFloat = model.barVisible ? StatusBarView.height : 0
        return CGSize(width: content.bounds.width, height: content.bounds.height - barH)
    }

    /// **分裂树 / 条带真正铺开的那块地**（pt）= `dwindleLayoutSize` 再去掉 RootView 外圈
    /// 那一圈 pane-gap 留白（`RootView.content` 里的 `.padding(theme.paneGap)`）。
    ///
    /// 不能拿 `window.contentLayoutRect` 当它：那是"去掉标题栏"的矩形，而 RootView
    /// `.ignoresSafeArea(.container, edges: .top)`，布局压根从 contentView 顶边起算——
    /// 横向永远多算一圈留白，纵向的误差还会随 `app set bar off` 变号。
    /// 报尺寸（`size.points`）、`--points` 换算、最小尺寸夹取、⌘右键拖拽与 `resize-*`
    /// 快捷键全部踩这一块底：**只有一份，就不会有"命令行能调到鼠标够不着的地方"**。
    ///
    /// 注意这是 pane 的**槽位**，每个 pane 内部还有 PaneChrome 的一圈 pane-gap 留白
    /// 与终端 pane-padding，终端画布因此比槽位更小（`size.cols/rows` 由引擎量得，不由此推）
    var workspaceLayoutSize: CGSize? {
        guard let base = dwindleLayoutSize else { return nil }
        let inset = 2 * (themeManager.gapsEnabled ? themeManager.paneGap : 0)
        let size = CGSize(width: base.width - inset, height: base.height - inset)
        guard size.width > 1, size.height > 1 else { return nil }
        return size
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
    // 按窗口：各自的 savedFrame，进程级的 presentationOptions 交给 AppSession 记账
    // （A 退出全屏时 B 还全屏 → 菜单栏不能放回来；关掉全屏中的屏幕只还它拿过的那一份）

    /// 本屏幕退出全屏后要恢复的 frame（nil = 不在全屏）
    private(set) var savedFrame: NSRect?

    /// 本屏幕是否处于非原生全屏
    var isSimpleFullscreen: Bool { savedFrame != nil }

    func toggleSimpleFullscreen() {
        guard let window, let screen = window.screen ?? NSScreen.main else { return }
        if let frame = savedFrame {
            savedFrame = nil
            session.setSimpleFullscreen(false, for: self)
            window.setFrame(frame, display: true, animate: false)
        } else {
            savedFrame = window.frame
            session.setSimpleFullscreen(true, for: self)
            window.setFrame(screen.frame, display: true, animate: false)
        }
        session.sessionStore.scheduleSave()
    }

    /// 显示器热插拔 / 分辨率变化后重新贴合（spec v9 §3.5；由 `AppSession` 防抖后逐屏调用）：
    /// 目标显示器没了就用当前所在屏（AppKit 已经把窗口挪过去了），全屏窗口重贴满新屏。
    /// 绝不因为解析失败而动布局——位置可以将就，内容不能丢
    func reflowForScreenChange() {
        guard !isClosed, let window, let screen = window.screen ?? NSScreen.main else { return }
        if isSimpleFullscreen {
            // 退出全屏后要恢复的 frame 也得收进新屏，否则一退全屏就跑到屏幕外
            savedFrame = SessionStore.constrain(savedFrame ?? window.frame, into: screen.visibleFrame)
            if window.frame != screen.frame { window.setFrame(screen.frame, display: true) }
            return
        }
        let fitted = window.constrainFrameRect(
            SessionStore.constrain(window.frame, into: screen.visibleFrame), to: screen)
        if fitted != window.frame { window.setFrame(fitted, display: true) }
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
        case .dwindle:
            // 与 ⌘右键拖拽、控制面 `pane resize --dir` 同一条路径（步长不同而已）
            controlResizeSplit(focused, workspace: model.activeIndex,
                               points: precise ? 10 : 100, direction: direction.spatial)
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

    /// 文件管理器 pane 的构造（**还没插进布局**）：`perform(.fileManager)` 与控制面的
    /// `pane new --kind file-manager` 共用这一份——cwd 文件、登录 shell 包装、
    /// `closesOnChildExit` 这几件事各写一份必然漂移
    func makeFileManagerPane(startDirectory: String)
        -> (pane: Ghostty.SurfaceView, launch: FileManagerLaunch) {
        let cwdFile = NSTemporaryDirectory() + "quickterm-fm-" + UUID().uuidString
        let launch = FileManagerLaunch.plan(program: fileManagerCommand,
                                            startDirectory: startDirectory, cwdFile: cwdFile)
        let pane = newSurface(workingDirectory: startDirectory, command: launch.command,
                              environment: launch.environment)
        pane.pwd = startDirectory      // yazi 不发 OSC 7：种入起始目录，Cmd+Return / 再开文件管理器都能继承
        pane.closesOnChildExit = true  // 退出即关（引擎对带 command 的 surface 不自行 close）
        return (pane, launch)
    }

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
    func clearZoom() {
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
    func mostRecentBrowserPaneAnywhere() -> BrowserPaneView? {
        browserPanes.filter { !model.closingPanes.contains($0.id) }
            .max { $0.lastActivatedAt < $1.lastActivatedAt }
    }

    /// 当前工作区（平铺 + 浮动）里最近激活过的浏览器 pane；淡出中的不算
    func mostRecentBrowserPane() -> BrowserPaneView? {
        paneList.compactMap { $0 as? BrowserPaneView }
            .filter { !model.closingPanes.contains($0.id) }
            .max { $0.lastActivatedAt < $1.lastActivatedAt }
    }

    /// 控制面新建浏览器 pane 时也要套（`controlMakeBrowserPane`）：漏了底色就与主题对不上
    func applyBrowserTheme(_ pane: BrowserPaneView) {
        pane.applyTheme(background: NSColor(themeManager.background), foreground: NSColor(themeManager.foreground))
    }

    /// 指定目录（与可选命令 / 额外环境）新建 surface。带 command 时引擎强制 wait-after-command，
    /// 调用方需自行处理退出（见 SurfaceView.closesOnChildExit）
    func newSurface(workingDirectory: String?, command: String? = nil,
                    environment: [String: String] = [:]) -> Ghostty.SurfaceView {
        var config = Ghostty.SurfaceConfiguration()
        config.workingDirectory = workingDirectory
        config.command = command
        // 控制面自举：QUICKTERM_SOCKET / PANE / SCREEN / WORKSPACE / TOKEN。
        // uuid 必须先定好再注入——PANE 就是这个 uuid（`-t @self` 靠它）
        let paneID = UUID()
        config.environmentVariables = ControlEnvironment.inject(
            into: environment, paneID: paneID,
            screen: screenIndex + 1, workspace: model.activeIndex + 1)
        return Ghostty.SurfaceView(ghostty.app!, baseConfig: config, uuid: paneID)
    }

    /// 把新 pane 插进活动布局（scrolling：锚点右侧新列；dwindle：按锚点空间几何分裂 + 局部进场动效）并聚焦。
    /// 锚点默认为焦点 pane；文件管理器退出"原位开终端"时锚点是即将关闭的那个 pane。
    /// 返回是否真的插进了布局（dwindle 树非空却找不到可用锚点时为 false，调用方不得再引用该 pane）
    /// 控制面（`Sources/Control`）也走这一条：重新实现它的不变量（列宽因子、dwindle 空间几何、
    /// 局部进场动效、焦点交接）必然出 bug，所以从 private 放宽到 internal
    @discardableResult
    func insertNewPane(_ pane: PaneView, anchor: PaneView? = nil) -> Bool {
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
        guard owns(view) else { return }   // 多屏幕：object: nil 注册，别的窗口的 pane 不管
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

    /// 把会话**交出去**（不清理临时文件）：pane 搬到另一块屏幕时会话要跟着走，
    /// 否则新东家不知道它是文件管理器 pane——关闭确认会回来、退出也不再原位开终端。
    /// `forgetFileManagerSession` 是"关闭"语义（会删 cwd 文件），这里刻意不复用
    func controlTakeFileManagerSession(_ view: PaneView) -> FileManagerLaunch.Session? {
        fileManagerSessions.removeValue(forKey: ObjectIdentifier(view))
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

    /// 在任一工作区里找到并移除（活动工作区用 removeFromActiveLayout，那条路径还管焦点）。
    /// **这是"关闭"语义**：会跑 pane 级收尾（浏览器 paneWillClose、文件管理器会话清理）。
    /// 搬家用 `controlDetach(_:)`，那条路径一个收尾都不能跑
    func removeFromAnyWorkspace(_ view: PaneView) {
        ControlUndo.invalidate()
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

    /// 同上，只作用于活动工作区。**同样是"关闭"语义**（会跑 pane 级收尾）
    func removeFromActiveLayout(_ view: PaneView) {
        ControlUndo.invalidate()
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
        // 多屏幕：引擎以双击分隔条的那个 surface 为 object，只有它所属的窗口等分
        guard let view = note.object as? PaneView, owns(view) else { return }
        perform(.equalize)
    }

    /// 这个 pane 属于本屏幕（含非活动工作区、浮动层与 Scratchpad）
    private func owns(_ view: PaneView) -> Bool {
        model.allPanes.contains { $0 === view }
    }

    @objc private func ghosttyDidCloseSurface(_ notification: Foundation.Notification) {
        guard let view = notification.object as? PaneView, owns(view) else { return }
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
        // 树的算法在 SplitTree+QuickTerm.dropping：控制面的 `pane move --where` 用的是同一份，
        // 两处各写一遍的话，拖放与命令行迟早给出不同的落点
        guard let newTree = tree.dropping(drop.payload, on: drop.destination, zone: drop.zone) else { return }
        model.layout = .dwindle(newTree)
        requestFocus(to: drop.payload)
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

/// 方向词的唯一换算（控制面的 `pane resize --dir` 也用它，不再各写一份）
extension ScrollingStrip.Direction {
    var spatial: SplitTree<PaneView>.Spatial.Direction {
        switch self {
        case .left: .left
        case .right: .right
        case .up: .up
        case .down: .down
        }
    }
}

// MARK: - 屏幕（窗口）生命周期

extension MainWindowController: NSWindowDelegate {
    /// 关闭按钮 / performClose：有活跃 pane 时按退出确认的规则问一次
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        confirmCloseScreen()
    }

    /// 控制面登记的撤销项要能被 Edit ▸ 撤销 / ⌘Z 找到：`undo:` 沿响应链走到窗口，
    /// 窗口来问它的 delegate 要 UndoManager。没有这一条，`AppDelegate.undoManager` 里
    /// 登记的东西永远没人能触发（Phase 1 之前它就是这么闲置着的）。
    /// 注意焦点在终端 pane 上时 ⌘Z 由 EditMenuDelegate 交还给终端（kitty 键盘协议），
    /// 那是刻意的——终端里的 ⌘Z 属于终端；菜单项点击则任何时候都能撤销
    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        (NSApp.delegate as? AppDelegate)?.undoManager
    }

    /// key 窗口一换就按 AppSession 的账本重算进程级 presentationOptions：
    /// AppKit 会在激活 / 窗口切换时改写它，而「有没有屏幕在全屏」只有账本知道
    func windowDidBecomeKey(_ notification: Foundation.Notification) {
        guard !isClosed else { return }
        session.screens.recordKeyWindow(self)   // 控制面的"当前屏幕"（应用不在前台时唯一诚实的答案）
        session.refreshPresentationOptions()
        session.sessionStore.scheduleSave()   // keyWindowID 变了：下次启动焦点落在正确的屏幕上
        // 扩展眼里的"当前窗口"是缓存值（只有 didFocusWindow 会改）：多屏幕下换了 key 窗口却不上报，
        // 扩展会一直把消息发到另一台显示器的 pane 上——图标看起来点了没反应
        focusedBrowserPane?.makeCurrentForExtensions()
    }

    /// 窗口移动 / 缩放结束 → 存档（拖动途中不写：live resize 每帧都发通知）
    func windowDidMove(_ notification: Foundation.Notification) {
        guard !isClosed else { return }
        session.sessionStore.scheduleSave()
    }

    func windowDidEndLiveResize(_ notification: Foundation.Notification) {
        guard !isClosed else { return }
        session.sessionStore.scheduleSave()
    }

    func windowWillClose(_ notification: Foundation.Notification) {
        teardown()
        // 注册表条目下一轮 runloop 再摘：本方法可能处在引擎回调栈内，
        // 同步放弃最后一个强引用会立刻 free 仍在栈上的 surface
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            (NSApp.delegate as? AppDelegate)?.forgetScreen(self)
        }
    }
}

// MARK: - 浏览器扩展宿主（pane = 扩展眼里的窗口）

extension MainWindowController: BrowserExtensionHost {
    /// 全部工作区（含浮动层与 scratchpad）里的浏览器 pane
    var browserPanes: [BrowserPaneView] { allPanes.compactMap { $0 as? BrowserPaneView } }

    /// 本窗口里真正持 first responder 的浏览器 pane（App 级聚合宿主先问这个）
    var firstResponderBrowserPane: BrowserPaneView? {
        guard let window else { return nil }
        return browserPanes.first { $0.holdsFirstResponder(of: window) }
    }

    /// 持 first responder 的浏览器 pane；没有就取最近激活的那个
    var focusedBrowserPane: BrowserPaneView? {
        firstResponderBrowserPane ?? mostRecentBrowserPaneAnywhere()
    }

    /// 扩展的 windows.create：在活动工作区新开一个浏览器 pane
    @discardableResult
    func openBrowserWindow(url: URL?) -> BrowserPaneView? {
        openBrowserPane(url: url ?? BrowserPaneView.settings.homeURL, from: focusedPane)
    }
}
