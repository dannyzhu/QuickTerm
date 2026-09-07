import AppKit
import WebKit

/// 浏览器 pane：多标签（每标签一个 WKWebView，共享进程池与登录态）+ 标签条 + 顶部薄工具条
/// （后退 / 前进 / 刷新、地址栏、进度）。工具条、地址栏、进度都绑定当前标签。
/// 键盘焦点落在当前标签的 WKWebView（focusTarget）；WM 级 Cmd 键由控制器的事件监视器先行拦截，
/// 其余 Cmd 键先交给页面（WebKit 语义）。
final class BrowserPaneView: PaneView {
    override class var kind: PaneKind { .browser }

    /// 浏览器行为配置（config.toml 顶层键；ConfigStore 解析后由控制器写入）
    struct Settings {
        /// Cmd+B 打开的首页
        var home = "https://www.google.com"
        /// 地址栏输入非 URL 时的搜索模板（%s = 关键词）
        var search = "https://www.google.com/search?q=%s"
        /// User-Agent：默认伪装成 Safari（Google 登录页拒绝"嵌入式浏览器"）；"webkit" = 不伪装
        var userAgent = "safari"
        /// Web Inspector（右键"检查元素"）
        var inspectable = false
        /// 标签条：always = 始终显示（默认）；auto = 只有一个标签时隐藏
        var tabBar = "always"
        /// 标签最大 / 最小宽度 pt（config browser-tab-width / browser-tab-min-width）
        var tabWidth = 200
        var tabMinWidth = 80
        /// 下载落盘目录（config browser-download-dir，支持 `~`；目录不存在时回退 ~/Downloads）
        var downloadDirectory = "~/Downloads"

        /// 系统的 ~/Downloads（回退用）
        static var systemDownloadsURL: URL {
            FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        }

        /// 解析后的下载目录：展开 `~`，不是个真目录就回退 ~/Downloads
        var downloadDirectoryURL: URL {
            let raw = downloadDirectory.trimmingCharacters(in: .whitespaces)
            guard !raw.isEmpty else { return Self.systemDownloadsURL }
            let expanded = (raw as NSString).expandingTildeInPath
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory),
               isDirectory.boolValue {
                return URL(fileURLWithPath: expanded, isDirectory: true)
            }
            return Self.systemDownloadsURL
        }

        static let safariUserAgent =
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.6 Safari/605.1.15"

        var effectiveUserAgent: String? {
            switch userAgent.lowercased() {
            case "safari", "": Self.safariUserAgent
            case "webkit", "default", "none": nil
            default: userAgent
            }
        }

        var tabBarAlwaysVisible: Bool { tabBar.lowercased() == "always" }

        var homeURL: URL {
            // URL(string:) 对含空格等的字符串也会返回非 nil（自动百分号编码）：按 scheme/host 校验
            if let url = URL(string: home), let scheme = url.scheme?.lowercased(),
               ["http", "https"].contains(scheme) && url.host != nil || ["file", "about"].contains(scheme) {
                return url
            }
            return URL(string: "https://www.google.com")!
        }

        /// 地址栏文本 → URL：有 scheme 直接用；像域名（含点、无空格）补 https；否则搜索
        func url(forInput raw: String) -> URL? {
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            if let url = URL(string: text), let scheme = url.scheme,
               ["http", "https", "file", "about"].contains(scheme.lowercased()) {
                return url
            }
            let looksLikeHost = !text.contains(" ") && (text.contains(".") || text.hasPrefix("localhost"))
            if looksLikeHost, let url = URL(string: "https://" + text) { return url }
            let q = text.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? text
            return URL(string: search.replacingOccurrences(of: "%s", with: q))
        }
    }

    static var settings = Settings()

    /// 所有浏览器 pane 共享的进程池 + 持久化数据存储（登录态跨标签、跨 pane、跨重启保留）
    private static let processPool = WKProcessPool()

    /// 一个标签：自己的 WKWebView 与导航状态。同时是 WebExtensions 眼里的"标签"
    /// （`WKWebExtensionTab`：扩展的 tabs.* API 全部落到这些方法上）
    @MainActor
    final class Tab: NSObject, WKWebExtensionTab {
        let id = UUID()
        /// 所属 pane（= 扩展眼里的"窗口"）
        weak var pane: BrowserPaneView?
        /// 当前 webView 是哪个扩展的页面专用的（nil = 普通网页配置）。
        /// 扩展页与普通页的 WKWebViewConfiguration 不通用，跨界导航时要原地换 webView
        var extensionContext: WKWebExtensionContext?
        /// 跨界换 webView 时会被替换（见 BrowserPaneView.rebuildWebView）
        fileprivate(set) var webView: BrowserWebView
        var title = ""
        /// 最近一次请求的真实 URL：错误页 / about:blank 不能覆盖它（存档、地址栏、重载、外部打开都用它）
        var lastRequestedURL: URL?
        var showingErrorPage = false
        /// 错误页自身的加载也会回调 decidePolicyFor：记下它，别把它当成新的导航
        var pendingErrorPageURL: URL?
        var lastProcessTerminationAt: Date?
        var observations: [NSKeyValueObservation] = []

        init(webView: BrowserWebView) {
            self.webView = webView
            super.init()
        }

        /// 对外可见的"当前网址"：错误页 / 空白页时回退到最近请求的真实 URL
        var effectiveURL: URL? {
            if let url = webView.url, url.scheme != "about", !showingErrorPage { return url }
            return lastRequestedURL ?? webView.url
        }

        var displayTitle: String {
            if !title.isEmpty { return title }
            return effectiveURL?.host ?? "新标签页"
        }

        // MARK: WKWebExtensionTab（全部可选；没实现的项 WebKit 用默认值）

        func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? { pane }

        /// 头文件要求：不在任何窗口里时返回 NSNotFound（返回 0 会让扩展以为它是第一个标签）
        func indexInWindow(for context: WKWebExtensionContext) -> Int {
            pane?.tabs.firstIndex { $0 === self } ?? NSNotFound
        }

        func webView(for context: WKWebExtensionContext) -> WKWebView? { webView }

        func title(for context: WKWebExtensionContext) -> String? { displayTitle }

        func url(for context: WKWebExtensionContext) -> URL? { effectiveURL }

        /// 正在加载中的目标网址（加载完成后为 nil）
        func pendingURL(for context: WKWebExtensionContext) -> URL? {
            webView.isLoading ? lastRequestedURL : nil
        }

        func isLoadingComplete(for context: WKWebExtensionContext) -> Bool { !webView.isLoading }

        func isSelected(for context: WKWebExtensionContext) -> Bool { pane?.activeTab === self }

        func size(for context: WKWebExtensionContext) -> CGSize { webView.bounds.size }

        func zoomFactor(for context: WKWebExtensionContext) -> Double { webView.pageZoom }

        func setZoomFactor(_ zoomFactor: Double, for context: WKWebExtensionContext,
                           completionHandler: @escaping ((any Error)?) -> Void) {
            webView.pageZoom = zoomFactor
            completionHandler(nil)
        }

        func activate(for context: WKWebExtensionContext,
                      completionHandler: @escaping ((any Error)?) -> Void) {
            if let pane, let index = pane.tabs.firstIndex(where: { $0 === self }) {
                pane.selectTab(at: index)
            }
            completionHandler(nil)
        }

        func setSelected(_ selected: Bool, for context: WKWebExtensionContext,
                         completionHandler: @escaping ((any Error)?) -> Void) {
            if selected {
                activate(for: context, completionHandler: completionHandler)
            } else {
                completionHandler(nil)
            }
        }

        /// tabs.remove：最后一个标签要连 pane 一起关（与 Cmd+W / 标签条关闭钮 / window.close 一致）——
        /// 只调 closeTab 的话它会被 `tabs.count > 1` 的守卫默默挡掉，而扩展那边收到的是"成功"
        func close(for context: WKWebExtensionContext,
                   completionHandler: @escaping ((any Error)?) -> Void) {
            guard let pane else {
                completionHandler(BrowserExtensionManager.unsupported("标签已经关闭了"))
                return
            }
            if pane.tabs.count > 1 {
                pane.closeTab(self)
            } else {
                pane.requestPaneClose()
            }
            completionHandler(nil)
        }

        func loadURL(_ url: URL, for context: WKWebExtensionContext,
                     completionHandler: @escaping ((any Error)?) -> Void) {
            pane?.load(url, in: self)
            completionHandler(nil)
        }

        func reload(fromOrigin: Bool, for context: WKWebExtensionContext,
                    completionHandler: @escaping ((any Error)?) -> Void) {
            if fromOrigin { webView.reloadFromOrigin() } else { webView.reload() }
            completionHandler(nil)
        }

        func goBack(for context: WKWebExtensionContext,
                    completionHandler: @escaping ((any Error)?) -> Void) {
            webView.goBack()
            completionHandler(nil)
        }

        func goForward(for context: WKWebExtensionContext,
                       completionHandler: @escaping ((any Error)?) -> Void) {
            webView.goForward()
            completionHandler(nil)
        }

        /// 用户点了扩展按钮就算"用户手势"：activeTab 权限按 Chrome 语义临时授予
        func shouldGrantPermissionsOnUserGesture(for context: WKWebExtensionContext) -> Bool { true }
    }

    private(set) var tabs: [Tab] = []
    private(set) var activeTabIndex = 0
    var activeTab: Tab? { tabs.indices.contains(activeTabIndex) ? tabs[activeTabIndex] : nil }
    /// 当前标签的 WKWebView（无标签时是占位，不会发生：pane 至少一个标签）
    var webView: BrowserWebView { activeTab?.webView ?? placeholderWebView }
    private lazy var placeholderWebView = BrowserWebView(frame: .zero, configuration: makeConfiguration())

    private let tabBar = BrowserTabBarView()
    private var tabBarHeight: NSLayoutConstraint!
    private let toolbar = NSView()
    private let backButton = NSButton()
    private let forwardButton = NSButton()
    private let reloadButton = NSButton()
    let addressField = BrowserAddressField()   // 测试需访问
    /// 地址栏的保底宽度：扩展固定得再多也不能把它挤得比这还窄（Chrome 也是同一套做法）
    static let addressFieldMinimumWidth: CGFloat = 200
    /// 保底宽度约束的优先级：必须低于 500（SwiftUI 托管 pane 的量宽优先级），否则窄 pane 会被这条约束撑宽
    static let addressFieldMinimumPriority = NSLayoutConstraint.Priority(rawValue: 300)
    /// 地址栏与扩展工具条之间的下载按钮（无下载时隐藏，宽度与两侧间距一起收成 0）
    let downloadButton = BrowserDownloadButton()
    /// 本 pane 的下载列表（WKDownloadDelegate 的回调都落到它上面）
    let downloads = BrowserDownloadList()
    private lazy var downloadPopover = BrowserDownloadPopover(list: downloads)
    /// 弹出层由 pane 持有：`NSPopover.contentViewController` 是强引用，内容控制器再反持 NSPopover
    /// 就成环（pane 关掉后列表 / 条目 / WKDownload 永远释放不掉）。第一次点开时才建
    private var downloadPopoverHost: NSPopover?
    /// 下载按钮的宽度与右侧间距：隐藏时归零，工具条里就当它不存在
    /// （左侧 6pt 是地址栏与扩展条之间本来就有的间距，一直留着）
    private var downloadButtonWidth: NSLayoutConstraint!
    private var downloadTrailingGap: NSLayoutConstraint!
    /// 地址栏右侧的扩展工具条（下载按钮插在地址栏与它之间）
    let extensionBar = BrowserExtensionToolbar()
    /// Web Store 页面 →「添加到 QuickTerm」的消息处理器（弱引用 pane，避免 WKUserContentController 成环）
    private lazy var scriptHandler = BrowserExtensionScriptHandler(pane: self)
    private let progressBar = NSProgressIndicator()
    private let webArea = NSView()
    private var editingAddress = false
    /// window.close() 时 pane 不在窗口里：挂回窗口后补发关闭请求（测试要读）
    private(set) var pendingCloseRequest = false
    /// Web Store 安装进行中（页面消息重入的闸门）
    private var webStoreInstallInFlight = false
    private var themeBackground: NSColor = .black
    private var themeForeground: NSColor = .white

    /// 页面标题 / 当前 URL（状态条、存档；当前标签的）
    var pageTitle: String { activeTab?.title ?? "" }
    var currentURL: URL? { activeTab?.effectiveURL }
    var lastRequestedURL: URL? { activeTab?.lastRequestedURL }

    override var paneTitle: String { activeTab?.displayTitle ?? "浏览器" }

    /// 最近一次激活（成为焦点 / 被送来链接）的时间：终端 ⌘+点击链接时选"最近的"浏览器 pane 用
    private(set) var lastActivatedAt = Date()

    override func paneDidBecomeFirstResponder() {
        super.paneDidBecomeFirstResponder()
        lastActivatedAt = Date()
        extensionController?.didFocusWindow(self)
    }

    /// 扩展事件的上报目标；config 关掉扩展时为 nil（全部静默）
    private var extensionController: WKWebExtensionController? {
        let manager = BrowserExtensionManager.current
        return manager.isEnabled ? manager.controller : nil
    }

    /// 上报给扩展的标签事件（测试用：验顺序，以及上报当刻标签是否还在 pane 上——
    /// WebKit 就在那一刻回调 `tab.window(for:)` 去算 tabs.onRemoved 的 windowId）
    struct ReportedTabEvent: Equatable {
        let kind: String
        let tab: UUID?
        let previous: UUID?
        let windowAttached: Bool
    }

    /// 测试钩子，生产恒为 nil
    static var tabEventRecorderForTesting: ((ReportedTabEvent) -> Void)?

    private func recordTabEvent(_ kind: String, _ tab: Tab?, previous: Tab? = nil) {
        guard let recorder = Self.tabEventRecorderForTesting else { return }
        recorder(ReportedTabEvent(kind: kind, tab: tab?.id, previous: previous?.id,
                                  windowAttached: tab?.pane != nil))
    }

    private var reportedWindowClose = false

    /// pane 被移出工作区（控制器关 pane 时调用）：告诉扩展这个"窗口"关了。只报一次
    func paneWillClose() {
        guard !reportedWindowClose else { return }
        reportedWindowClose = true
        // 下载列表是 pane 私有的：pane 一关就没有界面、没有进度，WKDownload.delegate 又是弱引用
        // （会自动置空）。与其留一堆没人管的传输，不如明确取消掉
        for item in downloads.items where item.isActive { downloads.cancel(item) }
        downloadPopoverHost?.performClose(nil)
        extensionController?.didCloseWindow(self)
    }

    /// 请求关掉整个 pane（最后一个标签被关 / 扩展 windows.remove / 页面 window.close）。
    /// pane 在非活动工作区时未挂窗口、controller 为 nil：先记下，挂回窗口再补发
    func requestPaneClose() {
        if let controller {
            controller.requestClosePane(self)
        } else {
            pendingCloseRequest = true
        }
    }

    /// 外部（终端 ⌘+点击）送来的链接：新标签打开并激活
    func openLink(_ url: URL) {
        addTab(url: url, activate: true)
        lastActivatedAt = Date()
    }
    /// 容器自己不接受焦点：键盘焦点在当前标签的 WKWebView
    override var acceptsFirstResponder: Bool { false }
    override var focusTarget: NSView { webView }
    /// 悬停即焦点由容器的 tracking area 驱动（WKWebView 的 mouseMoved 覆写收不到事件）
    override var installsHoverTracking: Bool { true }

    // MARK: - 创建

    init(id: UUID = UUID(), url: URL?) {
        super.init(id: id, frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        buildChrome()
        // 扩展是启动时异步加载的（pane 可能先建好）：装 / 卸 / 启停之后重挂注入脚本
        NotificationCenter.default.addObserver(self, selector: #selector(extensionsDidChange),
                                               name: .browserExtensionsDidChange, object: nil)
        extensionController?.didOpenWindow(self)   // 先有窗口再有标签
        _ = addTab(url: url ?? Self.settings.homeURL, activate: true)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if pendingCloseRequest, let controller {
            pendingCloseRequest = false
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                controller.requestClosePane(self)
            }
        }
    }

    deinit {
        for tab in tabs { tearDown(tab) }
    }

    private func makeConfiguration() -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.processPool = Self.processPool
        config.websiteDataStore = .default()
        config.preferences.isElementFullscreenEnabled = true
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        prepareForExtensions(config)
        return config
    }

    /// 扩展接线：每个标签的配置都要挂 controller（不挂的标签对扩展不可见），
    /// 外加 Web Store 详情页的「添加到 QuickTerm」按钮与它的回传通道。
    /// 通道注册在私有 content world 里：页面自己的 JS 够不着 `messageHandlers.quicktermExtension`
    private func prepareForExtensions(_ configuration: WKWebViewConfiguration, extensionPage: Bool = false) {
        let manager = BrowserExtensionManager.current
        guard manager.isEnabled else { return }
        configuration.webExtensionController = manager.controller
        let content = configuration.userContentController
        let world = BrowserExtensionWebStore.contentWorld
        // window.open 给回来的 configuration 可能已经注册过：重复注册会抛 ObjC 异常
        content.removeScriptMessageHandler(forName: BrowserExtensionWebStore.messageHandlerName,
                                           contentWorld: world)
        content.add(scriptHandler, contentWorld: world, name: BrowserExtensionWebStore.messageHandlerName)
        content.addUserScript(BrowserExtensionWebStore.userScript)
        // 网页里嵌的扩展 iframe：tabs.* 等改走后台转发（直接调会被 WebKit 杀掉页面进程）。扩展配置（扩展页开的
        // window.open 弹窗跑在扩展进程里，直接调没问题）不注入；window.open 给回来的 configuration 与开窗方共用
        // 同一个 userContentController，别重复追加
        guard !extensionPage else { return }
        // externally_connectable：网页侧的 chrome.runtime 别名（内容随已装扩展变，按源码首行标记去重）
        if let external = manager.externalMessagingUserScript,
           !content.userScripts.contains(where: { $0.source.hasPrefix(BrowserExtensionCompat.externalMessagingMarker) }) {
            content.addUserScript(external)
        }
        guard !content.userScripts.contains(where: { $0 === BrowserExtensionCompat.frameUserScript }) else { return }
        content.addUserScript(BrowserExtensionCompat.frameUserScript)
    }

    /// 装 / 卸 / 启停扩展之后重挂各标签的注入脚本：externally_connectable 的地址清单变了，
    /// 而 WKUserScript 只能整体清空重加。已经打开的页面不受影响（下次导航才生效，与 Chrome 装扩展一样）。
    /// 扩展自己的页面（配置来自 context.webViewConfiguration）不碰
    @objc private func extensionsDidChange() {
        for tab in tabs where tab.extensionContext == nil {
            let configuration = tab.webView.configuration
            configuration.userContentController.removeAllUserScripts()
            prepareForExtensions(configuration)
        }
    }

    // MARK: - 标签管理

    /// 新标签（url 为 nil = 首页）。webView 参数：window.open 时 WebKit 要求用它给的 configuration 创建
    @discardableResult
    func addTab(url: URL?, activate: Bool, webView given: BrowserWebView? = nil) -> Tab {
        // 扩展自己的页面（webkit-extension://…，如选项页 / tabs.create(runtime.getURL(…))）必须用
        // context.webViewConfiguration 建 WebView，普通配置的主帧加载会被 WebKit 拒掉
        let context = given == nil ? url.flatMap(extensionContext(for:)) : nil
        let webView = given ?? makeWebView(extensionContext: context)
        let tab = Tab(webView: webView)
        tab.pane = self
        tab.extensionContext = context
        install(webView, for: tab)
        tabs.append(tab)
        extensionController?.didOpenTab(tab)
        recordTabEvent("open", tab)
        if let url, given == nil {
            load(url, in: tab)
        }
        if activate { selectTab(at: tabs.count - 1) } else { rebuildTabBar() }
        extensionBar.reload()
        archiveDidChange.send()   // 标签集合变了：排一次防抖存档
        return tab
    }

    /// 这个 URL 属于哪个已加载的扩展（普通网址 = nil）
    private func extensionContext(for url: URL) -> WKWebExtensionContext? {
        BrowserExtensionManager.current.extensionContext(forResourceURL: url)
    }

    private func makeWebView(extensionContext context: WKWebExtensionContext?) -> BrowserWebView {
        // context.webViewConfiguration 是 controller 配置的定制副本（带 requiredWebExtensionBaseURL
        // 与 controller），不要再往上叠 makeConfiguration 的东西
        if let config = context?.webViewConfiguration {
            return BrowserWebView(frame: .zero, configuration: config)
        }
        return BrowserWebView(frame: .zero, configuration: makeConfiguration())
    }

    /// 把一个 WebView 接进 pane（代理 / 外观 / 设置 / KVO / 约束）——新建标签与跨界换 WebView 都走这里
    private func install(_ webView: BrowserWebView, for tab: Tab) {
        webView.pane = self
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.translatesAutoresizingMaskIntoConstraints = false
        applySettings(to: webView)
        // 透明背景：透出 QuickTerm 的壁纸 / 磨砂层（页面自己画背景的地方不受影响）。
        // drawsBackground 走私有 setter（_setDrawsBackground:）：先探测，避免将来被移除时 KVC 抛异常崩在创建/恢复
        if webView.responds(to: Selector(("_setDrawsBackground:"))) {
            webView.setValue(false, forKey: "drawsBackground")
        }
        webView.underPageBackgroundColor = .clear
        observe(tab)
        webArea.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: webArea.topAnchor),
            webView.leadingAnchor.constraint(equalTo: webArea.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: webArea.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: webArea.bottomAnchor),
        ])
        webView.isHidden = true
    }

    /// 扩展页 ↔ 普通页跨界：原地把标签的 WebView 换成配置正确的那种（标签身份、下标、扩展看到的
    /// tabId 都不变）。WebKit 明确要求"在扩展 URL 与普通 URL 之间导航时换掉 tab 的 web view"
    private func rebuildWebView(of tab: Tab, for context: WKWebExtensionContext?) {
        let wasActive = tab === activeTab
        let hadFocus = wasActive && (window.map { holdsFirstResponder(of: $0) } ?? false)
        let old = tab.webView
        tab.observations.removeAll()
        old.navigationDelegate = nil
        old.uiDelegate = nil
        old.pane = nil
        old.removeFromSuperview()
        let webView = makeWebView(extensionContext: context)
        tab.webView = webView
        tab.extensionContext = context
        install(webView, for: tab)
        webView.isHidden = !wasActive
        if wasActive {
            syncChromeToActiveTab()
            if hadFocus { window?.makeFirstResponder(webView) }
        }
    }

    func newTab(url: URL? = nil) { addTab(url: url ?? Self.settings.homeURL, activate: true) }

    /// 切换到第 index 个标签：只显示它、工具条绑定它、焦点（若本 pane 持焦，或调用方要求）交给它
    func selectTab(at index: Int, forceFocus: Bool = false) {
        selectTab(at: index, forceFocus: forceFocus, previous: activeTab)
    }

    /// previous = 上报给扩展的"之前激活的标签"。关标签那条路径必须在数组变短**之前**把它取出来：
    /// 删除之后 activeTabIndex 还是旧值，`activeTab` 指到的已经是别的标签（tabs.onActivated 要么不发、
    /// 要么带着一个从没激活过的 previousTabId）。被关的正是当前标签时传 nil（Chrome 语义：不给 previousTabId）
    private func selectTab(at index: Int, forceFocus: Bool, previous: Tab?) {
        guard tabs.indices.contains(index) else { return }
        let hadFocus = forceFocus || (window.map { holdsFirstResponder(of: $0) } ?? false)
        activeTabIndex = index
        for (i, tab) in tabs.enumerated() { tab.webView.isHidden = i != index }
        rebuildTabBar()
        syncChromeToActiveTab()
        if let current = activeTab, current !== previous {
            extensionController?.didActivateTab(current, previousActiveTab: previous)
            extensionController?.didSelectTabs([current])
            recordTabEvent("activate", current, previous: previous)
            if let previous {
                extensionController?.didDeselectTabs([previous])
                recordTabEvent("deselect", previous)
            }
        }
        extensionBar.reload()
        if hadFocus { window?.makeFirstResponder(webView) }
        objectWillChange.send()
        archiveDidChange.send()   // 活动标签变了（切换 / 关标签）：排一次防抖存档
    }

    /// 相对切换（Ctrl+Tab / Ctrl+Shift+Tab），首尾回绕
    func selectTab(offset: Int) {
        guard tabs.count > 1 else { return }
        selectTab(at: ((activeTabIndex + offset) % tabs.count + tabs.count) % tabs.count)
    }

    /// 关闭第 index 个标签；最后一个标签不在这里关（由控制器关 pane）。返回是否关掉了标签
    @discardableResult
    func closeTab(at index: Int) -> Bool {
        guard tabs.count > 1, tabs.indices.contains(index) else { return false }
        // 先记焦点：被关标签的 webView 脱离窗口时 AppKit 会静默把 FR 重置为窗口（不发 resign），
        // 之后再看 holdsFirstResponder 就是 false，幸存标签拿不到焦点
        let hadFocus = window.map { holdsFirstResponder(of: $0) } ?? false
        // 删之前取：关的就是当前标签 → previous 传 nil（新的当前标签会被正常上报激活）；
        // 关的是别的标签 → 当前标签没变，selectTab 里 current === previous，不会误发激活事件
        let previous: Tab? = index == activeTabIndex ? nil : activeTab
        let tab = tabs.remove(at: index)
        // 先上报再拆：WebKit 在 didCloseTab 里同步回调 tab.window(for:) 去算 tabs.onRemoved 的
        // windowId，此刻 tab.pane 必须还在（先 tearDown 的话拿到的是 windowId = -1）
        extensionController?.didCloseTab(tab, windowIsClosing: false)
        recordTabEvent("close", tab)
        tearDown(tab)
        tab.webView.removeFromSuperview()
        let next = index < activeTabIndex ? activeTabIndex - 1 : min(activeTabIndex, tabs.count - 1)
        selectTab(at: next, forceFocus: hadFocus, previous: previous)
        return true
    }

    @discardableResult
    func closeActiveTab() -> Bool { closeTab(at: activeTabIndex) }

    func closeTab(_ tab: Tab) {
        if let i = tabs.firstIndex(where: { $0 === tab }) { closeTab(at: i) }
    }

    private func tab(for webView: WKWebView) -> Tab? {
        tabs.first { $0.webView === webView }
    }

    private func tearDown(_ tab: Tab) {
        tab.observations.removeAll()
        tab.webView.navigationDelegate = nil
        tab.webView.uiDelegate = nil
        tab.webView.pane = nil
        tab.pane = nil
    }

    // MARK: - 界面

    private func buildChrome() {
        wantsLayer = true
        for v in [tabBar, toolbar, progressBar, webArea] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        tabBar.onSelect = { [weak self] i in self?.selectTab(at: i) }
        tabBar.onNewTab = { [weak self] in self?.newTab() }
        // 最后一个标签的关闭钮关掉整个 pane（与 Cmd+W / window.close 一致），否则那个 x 是死的
        tabBar.onClose = { [weak self] i in
            guard let self, !self.closeTab(at: i), self.tabs.count == 1 else { return }
            self.requestPaneClose()
        }
        tabBarHeight = tabBar.heightAnchor.constraint(equalToConstant: 0)

        for (button, symbol, tip, action) in [
            (backButton, "chevron.left", "后退", #selector(goBack)),
            (forwardButton, "chevron.right", "前进", #selector(goForward)),
            (reloadButton, "arrow.clockwise", "重新加载", #selector(reloadOrStop)),
        ] {
            button.bezelStyle = .accessoryBarAction
            button.isBordered = false
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
            button.toolTip = tip
            button.target = self
            button.action = action
            button.translatesAutoresizingMaskIntoConstraints = false
            toolbar.addSubview(button)
        }
        addressField.pane = self
        addressField.translatesAutoresizingMaskIntoConstraints = false
        addressField.placeholderString = "输入网址或搜索"
        addressField.isBezeled = true
        addressField.bezelStyle = .roundedBezel
        addressField.font = .systemFont(ofSize: 12)
        addressField.lineBreakMode = .byTruncatingTail
        addressField.usesSingleLineMode = true
        addressField.cell?.sendsActionOnEndEditing = false
        // 地址栏的文字宽度不参与"谁被压"的竞争（比扩展条的 .defaultLow 还低一档）：
        // 否则一条长 URL 会反过来把扩展条挤没。地址栏的下限只由下面 >= 200 的约束保证
        addressField.setContentCompressionResistancePriority(
            .init(rawValue: NSLayoutConstraint.Priority.defaultLow.rawValue - 1), for: .horizontal)
        addressField.delegate = self
        addressField.target = self
        addressField.action = #selector(addressEntered)
        toolbar.addSubview(addressField)

        downloadButton.translatesAutoresizingMaskIntoConstraints = false
        downloadButton.target = self
        downloadButton.action = #selector(showDownloads)
        downloadButton.list = downloads
        downloadButton.isHidden = true
        toolbar.addSubview(downloadButton)
        downloads.onChange = { [weak self] in self?.downloadsDidChange() }

        // 扩展工具条：手工布局，只对外报 intrinsicContentSize（非必需优先级，撑不动 pane 宽度）
        extensionBar.pane = self
        extensionBar.translatesAutoresizingMaskIntoConstraints = false
        extensionBar.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        // 压缩阻力比地址栏的保底宽度低：固定的扩展一多，先压扩展条（放不下的按钮藏起来、留在拼图菜单里），
        // 不能把地址栏挤成一小段
        extensionBar.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        toolbar.addSubview(extensionBar)

        progressBar.style = .bar
        progressBar.isIndeterminate = false
        progressBar.minValue = 0
        progressBar.maxValue = 1
        progressBar.controlSize = .small
        progressBar.isHidden = true

        // 地址栏保底宽度：优先级高于扩展条的压缩阻力（.defaultLow = 250）——扩展再多也给地址栏留 200pt；
        // 但必须 **低于 500**：pane 由 SwiftUI 托管，NSHostingView 量 pane 时按 500 的 fitting priority 走，
        // >= 500 的宽度约束（哪怕非必需）会反过来把窄 pane 撑宽（实测 pane 宽 250 会被撑成 300）
        let addressFieldMinWidth = addressField.widthAnchor.constraint(greaterThanOrEqualToConstant:
                                                                        Self.addressFieldMinimumWidth)
        addressFieldMinWidth.priority = Self.addressFieldMinimumPriority
        // 扩展条至少留一颗拼图的宽度：比地址栏保底再高一档（同样 < 500）——pane 窄到连 200pt 地址栏都放不下时
        // 让地址栏继续让（Chrome 同款），拼图按钮永远留在 pane 里、点得到
        let extensionBarMinWidth = extensionBar.widthAnchor.constraint(greaterThanOrEqualToConstant:
                                                                        BrowserExtensionToolbar.buttonSize)
        extensionBarMinWidth.priority = .init(rawValue: Self.addressFieldMinimumPriority.rawValue + 10)

        downloadButtonWidth = downloadButton.widthAnchor.constraint(equalToConstant: 0)
        downloadTrailingGap = downloadButton.trailingAnchor.constraint(equalTo: extensionBar.leadingAnchor,
                                                                       constant: 0)

        NSLayoutConstraint.activate([
            tabBar.topAnchor.constraint(equalTo: topAnchor),
            tabBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            tabBarHeight,
            toolbar.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            toolbar.leadingAnchor.constraint(equalTo: leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: trailingAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 30),
            backButton.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor, constant: 6),
            backButton.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            backButton.widthAnchor.constraint(equalToConstant: 24),
            forwardButton.leadingAnchor.constraint(equalTo: backButton.trailingAnchor, constant: 2),
            forwardButton.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            forwardButton.widthAnchor.constraint(equalToConstant: 24),
            reloadButton.leadingAnchor.constraint(equalTo: forwardButton.trailingAnchor, constant: 2),
            reloadButton.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            reloadButton.widthAnchor.constraint(equalToConstant: 24),
            addressField.leadingAnchor.constraint(equalTo: reloadButton.trailingAnchor, constant: 6),
            // 地址栏 | 6pt | 下载按钮（无下载时宽 0、右侧间距也 0，还原成原来的"地址栏 | 6pt | 扩展条"） | 扩展条
            addressField.trailingAnchor.constraint(equalTo: downloadButton.leadingAnchor, constant: -6),
            downloadButtonWidth,
            downloadTrailingGap,
            downloadButton.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            downloadButton.heightAnchor.constraint(equalToConstant: BrowserDownloadButton.size),
            extensionBar.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor, constant: -6),
            extensionBar.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            extensionBar.heightAnchor.constraint(equalToConstant: BrowserExtensionToolbar.buttonSize),
            addressField.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            addressField.heightAnchor.constraint(equalToConstant: 22),
            addressFieldMinWidth,
            extensionBarMinWidth,
            progressBar.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: -2),
            progressBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            progressBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            progressBar.heightAnchor.constraint(equalToConstant: 3),
            webArea.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            webArea.leadingAnchor.constraint(equalTo: leadingAnchor),
            webArea.trailingAnchor.constraint(equalTo: trailingAnchor),
            webArea.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    /// 测试用：标签项当前宽度
    var tabItemWidthsForTesting: [CGFloat] {
        tabBar.layoutSubtreeIfNeeded()
        return tabBar.itemViews.map { $0.frame.width }
    }

    /// 测试用：标签条视图
    var tabBarForTesting: BrowserTabBarView { tabBar }
    /// 测试用：地址栏
    var addressFieldForTesting: NSTextField { addressField }

    /// 标签条是否显示：always 或多于一个标签
    var tabBarVisible: Bool { Self.settings.tabBarAlwaysVisible || tabs.count > 1 }


    /// 同步标签条：标题 / 激活态交给 BrowserTabBarView（手工布局，对 pane 零约束）
    private func rebuildTabBar() {
        let visible = tabBarVisible
        tabBar.isHidden = !visible
        if !visible { tabBar.updateHover(atBarPoint: nil) }   // 隐藏后收不到 mouseExited
        tabBarHeight.constant = visible ? BrowserTabBarView.Metrics.barHeight : 0
        tabBar.metrics = .init(maxWidth: CGFloat(Self.settings.tabWidth), minWidth: CGFloat(Self.settings.tabMinWidth))
        tabBar.update(items: tabs.enumerated().map { i, tab in
            .init(title: tab.displayTitle, active: i == activeTabIndex)
        })
    }

    private func observe(_ tab: Tab) {
        let webView = tab.webView
        tab.observations = [
            webView.observe(\.url, options: [.new]) { [weak self, weak tab] _, _ in
                guard let self, let tab else { return }
                if tab === self.activeTab { self.urlDidChange() }
                self.extensionController?.didChangeTabProperties(.URL, for: tab)
            },
            webView.observe(\.title, options: [.new]) { [weak self, weak tab] wv, _ in
                guard let self, let tab else { return }
                // KVO 回调是 @Sendable 闭包，而 Tab 已是 MainActor 隔离的：WebKit 的这些通知一律在主线程
                MainActor.assumeIsolated { tab.title = wv.title ?? "" }
                self.rebuildTabBar()
                self.objectWillChange.send()
                self.extensionController?.didChangeTabProperties(.title, for: tab)
            },
            webView.observe(\.estimatedProgress, options: [.new]) { [weak self, weak tab] _, _ in
                guard let self, let tab, tab === self.activeTab else { return }
                self.progressDidChange()
            },
            webView.observe(\.isLoading, options: [.new]) { [weak self, weak tab] _, _ in
                guard let self, let tab else { return }
                self.extensionController?.didChangeTabProperties(.loading, for: tab)
                guard tab === self.activeTab else { return }
                self.progressDidChange()
            },
            webView.observe(\.canGoBack, options: [.new]) { [weak self, weak tab] _, _ in
                guard let self, let tab, tab === self.activeTab else { return }
                self.updateNavigationButtons()
            },
            webView.observe(\.canGoForward, options: [.new]) { [weak self, weak tab] _, _ in
                guard let self, let tab, tab === self.activeTab else { return }
                self.updateNavigationButtons()
            },
        ]
    }

    /// 工具条 / 地址栏 / 进度 / 前进后退全部绑到当前标签
    private func syncChromeToActiveTab() {
        urlDidChange()
        progressDidChange()
        updateNavigationButtons()
    }

    /// 配置热重载：UA / Inspector / 标签条（config.toml 保存即生效，含已打开的 pane 与标签）
    func applySettings() {
        for tab in tabs { applySettings(to: tab.webView) }
        rebuildTabBar()
        extensionBar.reload()
    }

    private func applySettings(to webView: WKWebView) {
        webView.customUserAgent = Self.settings.effectiveUserAgent
        webView.isInspectable = Self.settings.inspectable
    }

    /// 外观：工具条 / 标签条随主题（背景 / 前景色由控制器主题热切换时调用）
    func applyTheme(background: NSColor, foreground: NSColor) {
        themeBackground = background
        themeForeground = foreground
        toolbar.wantsLayer = true
        // 工具条用纯背景色：当前标签同色贴上来（标签条基线在它脚下断开），层次才成立
        toolbar.layer?.backgroundColor = background.cgColor
        tabBar.applyTheme(background: background, foreground: foreground)
        addressField.textColor = foreground
        for b in [backButton, forwardButton, reloadButton] { b.contentTintColor = foreground.withAlphaComponent(0.85) }
        extensionBar.applyTheme(foreground: foreground)
        downloadButton.tint = foreground.withAlphaComponent(0.85)
        rebuildTabBar()
    }

    // MARK: - 导航（作用于当前标签）

    func load(_ url: URL) {
        guard let tab = activeTab else { return }
        load(url, in: tab)
    }

    func load(_ url: URL, in tab: Tab) {
        tab.lastRequestedURL = url
        tab.showingErrorPage = false
        tab.webView.load(URLRequest(url: url))
    }

    /// 地址栏文本（URL 或搜索词）
    func navigate(to text: String) {
        guard let url = Self.settings.url(forInput: text) else { return }
        load(url)
    }

    @objc func goBack() { webView.goBack() }
    @objc func goForward() { webView.goForward() }
    @objc func reloadOrStop() {
        if webView.isLoading { webView.stopLoading() } else { reload() }
    }
    /// 错误页状态下重载的是原网址，不是错误页本身
    func reload() {
        guard let tab = activeTab else { return }
        if tab.showingErrorPage, let url = tab.lastRequestedURL { load(url, in: tab) } else { tab.webView.reload() }
    }

    /// 焦点进地址栏并全选（Cmd+Shift+L）
    func focusAddressBar() {
        window?.makeFirstResponder(addressField)
        addressField.currentEditor()?.selectAll(nil)
        addressField.didFocusProgrammatically()
    }

    /// 当前页面交给系统默认浏览器（Widevine / 通行密钥等 WebKit 嵌入做不到的场景）
    func openExternally() {
        guard let url = effectiveURL else { return }
        NSWorkspace.shared.open(url)
    }

    var effectiveURL: URL? { activeTab?.effectiveURL }

    func zoom(by factor: CGFloat) {
        webView.pageZoom = min(max(webView.pageZoom * factor, 0.5), 3.0)
    }
    func resetZoom() { webView.pageZoom = 1.0 }

    @objc private func addressEntered() {
        navigate(to: addressField.stringValue)
        window?.makeFirstResponder(webView)
    }

    private func urlDidChange() {
        if !editingAddress { addressField.stringValue = effectiveURL?.absoluteString ?? "" }
        objectWillChange.send()
        archiveDidChange.send()   // 「已打开的网页」变了：排一次防抖存档
    }

    private func progressDidChange() {
        let loading = webView.isLoading
        progressBar.isHidden = !loading
        progressBar.doubleValue = webView.estimatedProgress
        reloadButton.image = NSImage(systemSymbolName: loading ? "xmark" : "arrow.clockwise",
                                     accessibilityDescription: loading ? "停止" : "重新加载")
    }

    private func updateNavigationButtons() {
        backButton.isEnabled = webView.canGoBack
        forwardButton.isEnabled = webView.canGoForward
    }

    // MARK: - 存档

    private enum CodingKeys: String, CodingKey { case uuid, url, title, tabs, activeTab }
    private struct TabSnapshot: Codable {
        var url: String?
        var title: String?
    }

    static func decode(from decoder: Decoder) throws -> BrowserPaneView {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let id = try c.decodeIfPresent(String.self, forKey: .uuid).flatMap(UUID.init(uuidString:)) ?? UUID()
        let snapshots = try c.decodeIfPresent([TabSnapshot].self, forKey: .tabs) ?? []
        if snapshots.isEmpty {
            // 单页存档（多标签之前的格式）
            let url = try c.decodeIfPresent(String.self, forKey: .url).flatMap(URL.init(string:))
            let pane = BrowserPaneView(id: id, url: url ?? settings.homeURL)
            if let title = try c.decodeIfPresent(String.self, forKey: .title) { pane.activeTab?.title = title }
            return pane
        }
        let first = snapshots[0]
        let pane = BrowserPaneView(id: id, url: first.url.flatMap(URL.init(string:)) ?? settings.homeURL)
        pane.activeTab?.title = first.title ?? ""
        for snap in snapshots.dropFirst() {
            let tab = pane.addTab(url: snap.url.flatMap(URL.init(string:)) ?? settings.homeURL, activate: false)
            tab.title = snap.title ?? ""
        }
        let active = try c.decodeIfPresent(Int.self, forKey: .activeTab) ?? 0
        pane.selectTab(at: min(max(active, 0), pane.tabs.count - 1))
        return pane
    }

    override func encodePayload(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id.uuidString, forKey: .uuid)
        // 兼容旧格式：url / title 仍写当前标签
        try c.encodeIfPresent(effectiveURL?.absoluteString, forKey: .url)
        try c.encode(pageTitle, forKey: .title)
        try c.encode(tabs.map { TabSnapshot(url: $0.effectiveURL?.absoluteString, title: $0.title) }, forKey: .tabs)
        try c.encode(activeTabIndex, forKey: .activeTab)
    }
}

// MARK: - WebExtensions：pane = 窗口

/// 扩展眼里的"窗口"就是一个浏览器 pane（QuickTerm 只有一个真窗口，pane 才是浏览上下文的单位）
extension BrowserPaneView: WKWebExtensionWindow {
    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] { tabs }

    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? { activeTab }

    func windowType(for context: WKWebExtensionContext) -> WKWebExtension.WindowType { .normal }

    func windowState(for context: WKWebExtensionContext) -> WKWebExtension.WindowState { .normal }

    func isPrivate(for context: WKWebExtensionContext) -> Bool { false }

    func frame(for context: WKWebExtensionContext) -> CGRect {
        guard let window else { return bounds }
        return window.convertToScreen(convert(bounds, to: nil))
    }

    func screenFrame(for context: WKWebExtensionContext) -> CGRect {
        window?.screen?.frame ?? NSScreen.main?.frame ?? .zero
    }

    func focus(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        window?.makeFirstResponder(focusTarget)
        completionHandler(nil)
    }

    /// windows.remove：pane 可能在非活动工作区（没挂窗口、controller 为 nil），
    /// 那时先记下、挂回窗口再关——直接 `controller?.requestClosePane` 会是个静默的空操作
    func close(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        requestPaneClose()
        completionHandler(nil)
    }
}

// MARK: - 扩展 UI（弹出层 / 菜单 / Web Store 安装）

extension BrowserPaneView {
    /// 扩展动作的 popup：锚在它自己的按钮上（没有按钮就锚拼图按钮）。
    /// 工具条在 pane 顶部、视图未 flipped：弹层要落在按钮**下方** = minY 边
    func presentExtensionPopup(_ action: WKWebExtension.Action, of context: WKWebExtensionContext) {
        guard let popover = action.popupPopover else { return }
        let anchor = extensionBar.anchorButton(for: context)
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
    }

    /// WM 动作 web-extensions（⌘⇧E）：弹出拼图菜单
    func showExtensionsMenu() {
        extensionBar.showMenu()
    }

    /// Web Store 详情页「添加到 QuickTerm」：下载解包 → 权限确认 → 安装。
    /// 进度写在地址栏的占位文字里（没有别的地方可写，且不打断页面）
    func beginWebStoreInstall(id: String) {
        let manager = BrowserExtensionManager.current
        guard manager.isEnabled else {
            report(title: "扩展已关闭", text: "配置里 browser-extensions = false，先打开再安装。")
            return
        }
        // 一次只装一个：页面若连着发消息，不能堆起 N 个下载 / ditto / 模态弹窗
        guard !webStoreInstallInFlight else { return }
        webStoreInstallInFlight = true
        let placeholder = addressField.placeholderString
        Task { @MainActor in
            defer {
                self.addressField.placeholderString = placeholder
                self.webStoreInstallInFlight = false
            }
            do {
                let staged = try await manager.stageWebStoreInstall(id: id) { [weak self] text in
                    self?.addressField.placeholderString = text
                }
                let alert = NSAlert()
                alert.messageText = "安装「\(staged.displayName)」？"
                let permissions = staged.permissionSummary
                alert.informativeText = permissions.isEmpty
                    ? "该扩展没有声明额外权限。"
                    : "它将获得：\n" + permissions.joined(separator: "\n")
                alert.addButton(withTitle: "安装")
                alert.addButton(withTitle: "取消")
                guard alert.runModal() == .alertFirstButtonReturn else {
                    manager.discard(staged)
                    return
                }
                self.addressField.placeholderString = "正在安装…"
                let installed = try await manager.commit(staged)
                self.report(title: "已安装「\(installed.displayName)」", text: "扩展按钮在地址栏右侧。")
            } catch {
                self.report(title: "安装失败", text: error.localizedDescription)
            }
        }
    }

    private func report(title: String, text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.addButton(withTitle: "好")
        alert.runModal()
    }
}

// MARK: - 地址栏

extension BrowserPaneView: NSTextFieldDelegate {
    func controlTextDidBeginEditing(_ obj: Notification) { editingAddress = true }
    func controlTextDidEndEditing(_ obj: Notification) {
        editingAddress = false
        // 回车：NSTextField 先发本通知、后发 action，这里若把文本重置成当前网址，action 读到的就是
        // 当前网址而不是用户输入（"输入什么都回到原页面"）。只有失焦 / 取消才把文本恢复成当前网址
        let movement = (obj.userInfo?["NSTextMovement"] as? Int).flatMap(NSTextMovement.init(rawValue:))
        if movement == .return { return }
        addressField.stringValue = effectiveURL?.absoluteString ?? ""
    }

    /// Esc：放弃编辑，焦点回页面
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            addressField.stringValue = effectiveURL?.absoluteString ?? ""
            window?.makeFirstResponder(webView)
            return true
        }
        return false
    }
}

// MARK: - 导航代理

extension BrowserPaneView: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let tab = tab(for: webView) else { decisionHandler(.allow); return }
        // ⌘+点击链接 → 后台新标签打开（Chrome 习惯），本页不动
        if navigationAction.navigationType == .linkActivated,
           navigationAction.modifierFlags.contains(.command),
           let url = navigationAction.request.url {
            addTab(url: url, activate: false)
            decisionHandler(.cancel)
            return
        }
        // 记住主帧的真实请求（链接点击 / 重定向），错误页不能覆盖它。
        // targetFrame == nil 是 target=_blank（走 createWebViewWith 开新标签），不算本标签的导航；
        // 错误页自身的模拟加载也会回调到这里，跳过
        if navigationAction.targetFrame?.isMainFrame == true,
           let url = navigationAction.request.url, url.scheme != "about" {
            if url == tab.pendingErrorPageURL {
                tab.pendingErrorPageURL = nil
            } else {
                tab.lastRequestedURL = url
                tab.showingErrorPage = false
            }
            // 扩展页 ↔ 普通页跨界：WebKit 要求换一个配置匹配的 web view，否则这次导航会被它取消
            // （扩展配置带 requiredWebExtensionBaseURL：只进得去自己的页面；普通配置进不去扩展页）
            let target = extensionContext(for: url)
            if target !== tab.extensionContext {
                decisionHandler(.cancel)
                rebuildWebView(of: tab, for: target)
                tab.webView.load(URLRequest(url: url))
                return
            }
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        // 页面显示不了的内容（附件 / 未知 MIME）→ 下载
        decisionHandler(navigationResponse.canShowMIMEType ? .allow : .download)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        beginDownload(download)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        beginDownload(download)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if let tab = tab(for: webView) { showError(error, in: tab) }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if let tab = tab(for: webView) { showError(error, in: tab) }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard let tab = tab(for: webView) else { return }
        // WebContent 进程崩溃：首次自动重载；10s 内再崩就停下来提示，避免"崩溃→重载→再崩"死循环
        let now = Date()
        if let last = tab.lastProcessTerminationAt, now.timeIntervalSince(last) < 10 {
            showError(NSError(domain: "QuickTerm.Browser", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "页面进程反复崩溃，已停止自动重载。按 Cmd+R 重试。"]), in: tab)
            return
        }
        tab.lastProcessTerminationAt = now
        if tab.showingErrorPage, let url = tab.lastRequestedURL { load(url, in: tab) } else { tab.webView.reload() }
    }

    private func showError(_ error: Error, in tab: Tab) {
        let ns = error as NSError
        // 取消 / 被下载策略接管 / 帧加载中断都不是错误
        if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled { return }
        if ns.domain == "WebKitErrorDomain" && (ns.code == 102 || ns.code == 204) { return }
        let failing = (ns.userInfo[NSURLErrorFailingURLErrorKey] as? URL) ?? tab.lastRequestedURL
        let url = failing?.absoluteString ?? ""
        let html = """
        <html><head><meta name="color-scheme" content="dark light"><style>
        body{font:14px -apple-system,system-ui;color:#c0caf5;background:transparent;padding:32px}
        h2{font-weight:600;margin:0 0 8px}code{color:#7aa2f7;word-break:break-all}p{opacity:.8}
        </style></head><body><h2>页面无法加载</h2><p>\(Self.escape(ns.localizedDescription))</p>
        <p><code>\(Self.escape(url))</code></p></body></html>
        """
        // 以失败的网址"模拟响应"展示错误页：webView.url 保持为它（地址栏 / 存档 / Cmd+R 不变成 about:blank），
        // 且进历史（后退能回到上一页）；loadHTMLString(baseURL:) 不建历史条目
        tab.showingErrorPage = true
        if let failing {
            tab.pendingErrorPageURL = failing
            tab.webView.loadSimulatedRequest(URLRequest(url: failing), responseHTML: html)
        } else {
            tab.webView.loadHTMLString(html, baseURL: nil)
        }
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}

// MARK: - 下载（落到 browser-download-dir，默认 ~/Downloads，同名加序号）

extension BrowserPaneView: WKDownloadDelegate {
    /// 接管一个下载：挂代理 + 立刻进列表。
    /// 早于 `decideDestinationUsing` —— 连不上服务器的下载根本走不到定目的地那一步，
    /// 但它同样要在列表里显示成"失败"
    func beginDownload(_ download: WKDownload) {
        download.delegate = self
        guard downloads.item(for: download) == nil else { return }
        let guessed = download.originalRequest?.url?.lastPathComponent ?? ""
        let filename = guessed.isEmpty || guessed == "/" ? "下载中的文件" : guessed
        downloads.add(BrowserDownloadItem(download: download, filename: filename))
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        let dir = Self.settings.downloadDirectoryURL
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var name = suggestedFilename.isEmpty ? "download" : suggestedFilename
        var candidate = dir.appendingPathComponent(name)
        var n = 1
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        // 同名判定不能只看磁盘：WebKit 是收到我们的回复之后才建文件的，两条同名下载的
        // decideDestination 可能都赶在建文件之前，于是拿到同一个路径（后一条 EEXIST 失败甚至卡死）。
        // 已经交给别的进行中下载的目的地同样算占用
        let reserved = Set(downloads.items.compactMap {
            $0.isActive ? $0.destination?.standardizedFileURL.path : nil
        })
        func isTaken(_ url: URL) -> Bool {
            FileManager.default.fileExists(atPath: url.path)
                || reserved.contains(url.standardizedFileURL.path)
        }
        while isTaken(candidate) {
            n += 1
            name = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            candidate = dir.appendingPathComponent(name)
        }
        if let item = downloads.item(for: download) {
            item.setDestination(candidate)
            downloadsDidChange()
        } else {
            let item = BrowserDownloadItem(download: download, filename: candidate.lastPathComponent)
            item.setDestination(candidate)
            downloads.add(item)
        }
        completionHandler(candidate)
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let item = downloads.item(for: download) else { return }
        downloads.markCompleted(item)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        guard let item = downloads.item(for: download) else { return }
        let ns = error as NSError
        // 用户点了取消（列表里已经是 .cancelled，markCancelled 幂等）
        if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled {
            downloads.markCancelled(item)
        } else {
            downloads.markFailed(item, message: ns.localizedDescription)
        }
    }

    // MARK: 工具条上的下载按钮

    /// 列表变了：按钮的可见性 / 进度环 + 打开着的弹出层
    func downloadsDidChange() {
        let hasItems = !downloads.items.isEmpty
        downloadButton.update()
        downloadButtonWidth.constant = hasItems ? BrowserDownloadButton.size : 0
        downloadTrailingGap.constant = hasItems ? -6 : 0
        // 用可选链：没点开过就不去实例化弹出层
        if downloadPopoverHost?.isShown == true { downloadPopover.rebuild() }
    }

    @objc func showDownloads() {
        guard !downloads.items.isEmpty else { return }
        let host = downloadPopoverHost ?? {
            let popover = NSPopover()
            popover.behavior = .transient
            popover.contentViewController = downloadPopover
            downloadPopoverHost = popover
            return popover
        }()
        downloadPopover.rebuild()
        host.show(relativeTo: downloadButton.bounds, of: downloadButton, preferredEdge: .maxY)
    }

    /// 测试用：弹出层（不弹出也能查行数）
    var downloadPopoverForTesting: BrowserDownloadPopover { downloadPopover }
}

// MARK: - UI 代理（JS 对话框 / 新窗口 → 新标签 / 文件选择）

extension BrowserPaneView: WKUIDelegate {
    /// JS 对话框宿主：本 pane 的窗口，否则主窗口；都没有（pane 未挂载且 app 不在前台）时同步 runModal——
    /// WebKit 的 completionHandler 必须被调用（挂在从未显示的窗口上永远不完成，页面 JS 线程就此卡死）
    private func present(_ alert: NSAlert, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        if let host = window ?? NSApp.mainWindow, host.isVisible {
            alert.beginSheetModal(for: host, completionHandler: completion)
        } else {
            completion(alert.runModal())
        }
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = frame.request.url?.host ?? "页面消息"
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        present(alert) { _ in completionHandler() }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = frame.request.url?.host ?? "页面确认"
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        alert.addButton(withTitle: "取消")
        present(alert) { completionHandler($0 == .alertFirstButtonReturn) }
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        let alert = NSAlert()
        alert.messageText = prompt
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.stringValue = defaultText ?? ""
        alert.accessoryView = field
        alert.addButton(withTitle: "好")
        alert.addButton(withTitle: "取消")
        present(alert) { completionHandler($0 == .alertFirstButtonReturn ? field.stringValue : nil) }
    }

    /// target=_blank / window.open → 同 pane 新标签。必须用 WebKit 给的 configuration 创建并返回该 webView：
    /// 页面拿到真实的 window 对象（window.opener / postMessage 可用，弹窗登录能回传）
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        let source = tab(for: webView)
        prepareForExtensions(configuration, extensionPage: source?.extensionContext != nil)
        let popup = BrowserWebView(frame: .zero, configuration: configuration)
        // 来源是当前标签才前台打开；后台标签（定时 window.open 等）的弹窗在后台开，不打断用户输入
        let tab = addTab(url: nil, activate: source === activeTab, webView: popup)
        // WebKit 给的 configuration 继承了开窗方的扩展绑定：新标签的"当前配置属于谁"要跟着记，
        // 否则第一次跨界导航判断会错
        tab.extensionContext = source?.extensionContext
        return popup
    }

    /// 页面自己调用 window.close() → 关掉那个标签；最后一个标签 → 请求控制器关 pane。
    /// pane 在非活动工作区（未挂窗口、controller 为 nil）时先记下，挂回窗口再补发（WebKit 只回调一次）
    func webViewDidClose(_ webView: WKWebView) {
        guard let tab = tab(for: webView) else { return }
        if tabs.count > 1 { closeTab(tab) } else { requestPaneClose() }
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = true
        if let host = window ?? NSApp.mainWindow, host.isVisible {
            panel.beginSheetModal(for: host) { completionHandler($0 == .OK ? panel.urls : nil) }
        } else {
            completionHandler(panel.runModal() == .OK ? panel.urls : nil)
        }
    }
}

/// 地址栏：成为 first responder 时回报给 pane——随后接管的字段编辑器是 pane 的后代，
/// pane 视为仍持有焦点（边框亮着、Cmd+W 会把焦点交给接班人）
final class BrowserAddressField: NSTextField {
    weak var pane: BrowserPaneView?
    /// 成为 first responder 后尚未交互：接下来的第一次 mouseDown 全选。
    /// AppKit 在把 mouseDown 交给视图之前就先 makeFirstResponder，所以点击进入时这里先置位、
    /// 随后 mouseDown 消费；键盘 / Cmd+Shift+L 进入的由 focusAddressBar 自己全选并清掉标记
    private var selectAllOnFirstClick = false

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result {
            pane?.paneDidBecomeFirstResponder()
            selectAllOnFirstClick = true
        }
        return result
    }

    /// 程序化聚焦（Cmd+Shift+L）后调用：随后的点击按普通编辑处理
    func didFocusProgrammatically() { selectAllOnFirstClick = false }

    /// 首次点击全选——⌘C 直接复制网址、直接输入即替换（Safari / Chrome 习惯）；
    /// 已在编辑中再点击：正常定位光标 / 双击选词 / 拖选
    override func mouseDown(with event: NSEvent) {
        let firstClick = selectAllOnFirstClick
        selectAllOnFirstClick = false
        super.mouseDown(with: event)   // 安装 / 使用字段编辑器并同步跟踪到 mouseUp
        if firstClick, let editor = currentEditor(), editor.selectedRange.length == 0 {
            editor.selectAll(nil)      // 纯点击 → 全选；拖选 → 保留拖出的选区
        }
    }
}

/// WKWebView 子类：first responder 变化回报给所属 pane（焦点真相 = FR 是 pane 的后代）。
/// 悬停即焦点不在这里：WKWebView 的 tracking area 由内部观察者持有，覆写 mouseMoved 收不到事件，
/// 由 PaneView 容器自己的 tracking area 处理（installsHoverTracking）。
final class BrowserWebView: WKWebView {
    weak var pane: BrowserPaneView?

    // 页面右键菜单里的扩展项不用我们加：WebKit 的 WebContextMenuProxyMac 见到配置上挂着
    // webExtensionController 就会自己把各扩展的 contextMenus 项（含分隔线）追加进去。
    // 自己再 append 一遍 = 重复项，而且 context.menuItems(for:) 给的是**标签条**右键的那一套（tab 上下文）

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result { pane?.paneDidBecomeFirstResponder() }
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result { pane?.paneDidResignFirstResponder() }
        return result
    }
}
