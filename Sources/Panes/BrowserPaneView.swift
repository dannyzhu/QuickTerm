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

    /// 一个标签：自己的 WKWebView 与导航状态
    final class Tab {
        let id = UUID()
        let webView: BrowserWebView
        var title = ""
        /// 最近一次请求的真实 URL：错误页 / about:blank 不能覆盖它（存档、地址栏、重载、外部打开都用它）
        var lastRequestedURL: URL?
        var showingErrorPage = false
        /// 错误页自身的加载也会回调 decidePolicyFor：记下它，别把它当成新的导航
        var pendingErrorPageURL: URL?
        var lastProcessTerminationAt: Date?
        var observations: [NSKeyValueObservation] = []

        init(webView: BrowserWebView) { self.webView = webView }

        /// 对外可见的"当前网址"：错误页 / 空白页时回退到最近请求的真实 URL
        var effectiveURL: URL? {
            if let url = webView.url, url.scheme != "about", !showingErrorPage { return url }
            return lastRequestedURL ?? webView.url
        }

        var displayTitle: String {
            if !title.isEmpty { return title }
            return effectiveURL?.host ?? "新标签页"
        }
    }

    private(set) var tabs: [Tab] = []
    private(set) var activeTabIndex = 0
    var activeTab: Tab? { tabs.indices.contains(activeTabIndex) ? tabs[activeTabIndex] : nil }
    /// 当前标签的 WKWebView（无标签时是占位，不会发生：pane 至少一个标签）
    var webView: BrowserWebView { activeTab?.webView ?? placeholderWebView }
    private lazy var placeholderWebView = BrowserWebView(frame: .zero, configuration: Self.makeConfiguration())

    private let tabBar = BrowserTabBarView()
    private var tabBarHeight: NSLayoutConstraint!
    private let toolbar = NSView()
    private let backButton = NSButton()
    private let forwardButton = NSButton()
    private let reloadButton = NSButton()
    let addressField = BrowserAddressField()   // 测试需访问
    private let progressBar = NSProgressIndicator()
    private let webArea = NSView()
    private var editingAddress = false
    /// window.close() 时 pane 不在窗口里：挂回窗口后补发关闭请求
    private var pendingCloseRequest = false
    private var themeBackground: NSColor = .black
    private var themeForeground: NSColor = .white

    /// 页面标题 / 当前 URL（状态条、存档；当前标签的）
    var pageTitle: String { activeTab?.title ?? "" }
    var currentURL: URL? { activeTab?.effectiveURL }
    var lastRequestedURL: URL? { activeTab?.lastRequestedURL }

    override var paneTitle: String { activeTab?.displayTitle ?? "浏览器" }
    /// 容器自己不接受焦点：键盘焦点在当前标签的 WKWebView
    override var acceptsFirstResponder: Bool { false }
    override var focusTarget: NSView { webView }
    /// 悬停即焦点由容器的 tracking area 驱动（WKWebView 的 mouseMoved 覆写收不到事件）
    override var installsHoverTracking: Bool { true }

    // MARK: - 创建

    init(id: UUID = UUID(), url: URL?) {
        super.init(id: id, frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        buildChrome()
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

    private static func makeConfiguration() -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.processPool = processPool
        config.websiteDataStore = .default()
        config.preferences.isElementFullscreenEnabled = true
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        return config
    }

    // MARK: - 标签管理

    /// 新标签（url 为 nil = 首页）。webView 参数：window.open 时 WebKit 要求用它给的 configuration 创建
    @discardableResult
    func addTab(url: URL?, activate: Bool, webView given: BrowserWebView? = nil) -> Tab {
        let webView = given ?? BrowserWebView(frame: .zero, configuration: Self.makeConfiguration())
        let tab = Tab(webView: webView)
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
        tabs.append(tab)
        if let url, given == nil {
            load(url, in: tab)
        }
        if activate { selectTab(at: tabs.count - 1) } else { rebuildTabBar() }
        return tab
    }

    func newTab(url: URL? = nil) { addTab(url: url ?? Self.settings.homeURL, activate: true) }

    /// 切换到第 index 个标签：只显示它、工具条绑定它、焦点（若本 pane 持焦，或调用方要求）交给它
    func selectTab(at index: Int, forceFocus: Bool = false) {
        guard tabs.indices.contains(index) else { return }
        let hadFocus = forceFocus || (window.map { holdsFirstResponder(of: $0) } ?? false)
        activeTabIndex = index
        for (i, tab) in tabs.enumerated() { tab.webView.isHidden = i != index }
        rebuildTabBar()
        syncChromeToActiveTab()
        if hadFocus { window?.makeFirstResponder(webView) }
        objectWillChange.send()
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
        let tab = tabs.remove(at: index)
        tearDown(tab)
        tab.webView.removeFromSuperview()
        let next = index < activeTabIndex ? activeTabIndex - 1 : min(activeTabIndex, tabs.count - 1)
        selectTab(at: next, forceFocus: hadFocus)
        return true
    }

    @discardableResult
    func closeActiveTab() -> Bool { closeTab(at: activeTabIndex) }

    private func closeTab(_ tab: Tab) {
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
            self.controller?.requestClosePane(self)
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
        addressField.delegate = self
        addressField.target = self
        addressField.action = #selector(addressEntered)
        toolbar.addSubview(addressField)

        progressBar.style = .bar
        progressBar.isIndeterminate = false
        progressBar.minValue = 0
        progressBar.maxValue = 1
        progressBar.controlSize = .small
        progressBar.isHidden = true

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
            addressField.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor, constant: -6),
            addressField.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            addressField.heightAnchor.constraint(equalToConstant: 22),
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
            },
            webView.observe(\.title, options: [.new]) { [weak self, weak tab] wv, _ in
                guard let self, let tab else { return }
                tab.title = wv.title ?? ""
                self.rebuildTabBar()
                self.objectWillChange.send()
            },
            webView.observe(\.estimatedProgress, options: [.new]) { [weak self, weak tab] _, _ in
                guard let self, let tab, tab === self.activeTab else { return }
                self.progressDidChange()
            },
            webView.observe(\.isLoading, options: [.new]) { [weak self, weak tab] _, _ in
                guard let self, let tab, tab === self.activeTab else { return }
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
        rebuildTabBar()
    }

    // MARK: - 导航（作用于当前标签）

    func load(_ url: URL) {
        guard let tab = activeTab else { return }
        load(url, in: tab)
    }

    private func load(_ url: URL, in tab: Tab) {
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
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        // 页面显示不了的内容（附件 / 未知 MIME）→ 下载
        decisionHandler(navigationResponse.canShowMIMEType ? .allow : .download)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
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

// MARK: - 下载（落到 ~/Downloads，同名加序号）

extension BrowserPaneView: WKDownloadDelegate {
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        let dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        var name = suggestedFilename.isEmpty ? "download" : suggestedFilename
        var candidate = dir.appendingPathComponent(name)
        var n = 1
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        while FileManager.default.fileExists(atPath: candidate.path) {
            n += 1
            name = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            candidate = dir.appendingPathComponent(name)
        }
        completionHandler(candidate)
    }

    func downloadDidFinish(_ download: WKDownload) {}
    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {}
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
        let popup = BrowserWebView(frame: .zero, configuration: configuration)
        // 来源是当前标签才前台打开；后台标签（定时 window.open 等）的弹窗在后台开，不打断用户输入
        addTab(url: nil, activate: tab(for: webView) === activeTab, webView: popup)
        return popup
    }

    /// 页面自己调用 window.close() → 关掉那个标签；最后一个标签 → 请求控制器关 pane。
    /// pane 在非活动工作区（未挂窗口、controller 为 nil）时先记下，挂回窗口再补发（WebKit 只回调一次）
    func webViewDidClose(_ webView: WKWebView) {
        guard let tab = tab(for: webView) else { return }
        if tabs.count > 1 {
            closeTab(tab)
        } else if let controller {
            controller.requestClosePane(self)
        } else {
            pendingCloseRequest = true
        }
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
