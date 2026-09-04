import AppKit
import WebKit

/// 浏览器 pane：WKWebView + 顶部薄工具条（后退 / 前进 / 刷新、地址栏、进度）。
/// 一个 pane 一个页面（Omarchy `--app` 窗口语义，无标签页）。
/// 键盘焦点落在 WKWebView（focusTarget）；WM 级 Cmd 键由控制器的事件监视器先行拦截，
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

        static let safariUserAgent =
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.6 Safari/605.1.15"

        var effectiveUserAgent: String? {
            switch userAgent.lowercased() {
            case "safari", "": Self.safariUserAgent
            case "webkit", "default", "none": nil
            default: userAgent
            }
        }

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

    /// 所有浏览器 pane 共享的进程池 + 持久化数据存储（登录态跨 pane、跨重启保留）
    private static let processPool = WKProcessPool()

    let webView: BrowserWebView
    private let toolbar = NSView()
    private let backButton = NSButton()
    private let forwardButton = NSButton()
    private let reloadButton = NSButton()
    let addressField = BrowserAddressField()   // 测试需访问
    private let progressBar = NSProgressIndicator()

    /// 页面标题 / 当前 URL（状态条、存档）
    @Published private(set) var pageTitle = ""
    @Published private(set) var currentURL: URL?
    /// 最近一次请求的真实 URL：错误页 / about:blank 不能覆盖它（存档、地址栏、重载、外部打开都用它）
    private(set) var lastRequestedURL: URL?
    private var showingErrorPage = false
    /// 错误页自身的加载也会回调 decidePolicyFor：记下它，别把它当成新的导航
    private var pendingErrorPageURL: URL?
    private var lastProcessTerminationAt: Date?
    private var observations: [NSKeyValueObservation] = []
    private var editingAddress = false

    override var paneTitle: String { pageTitle.isEmpty ? (currentURL?.host ?? "浏览器") : pageTitle }
    /// 容器自己不接受焦点：键盘焦点在 WKWebView
    override var acceptsFirstResponder: Bool { false }
    override var focusTarget: NSView { webView }
    /// 悬停即焦点由容器的 tracking area 驱动（WKWebView 的 mouseMoved 覆写收不到事件）
    override var installsHoverTracking: Bool { true }

    // MARK: - 创建

    init(id: UUID = UUID(), url: URL?) {
        let config = WKWebViewConfiguration()
        config.processPool = Self.processPool
        config.websiteDataStore = .default()
        config.preferences.isElementFullscreenEnabled = true
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        webView = BrowserWebView(frame: .zero, configuration: config)
        super.init(id: id, frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        webView.pane = self
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.customUserAgent = Self.settings.effectiveUserAgent
        webView.allowsBackForwardNavigationGestures = true
        applySettings()
        // 透明背景：透出 QuickTerm 的壁纸 / 磨砂层（页面自己画背景的地方不受影响）。
        // drawsBackground 走私有 setter（_setDrawsBackground:）：先探测，避免将来被移除时 KVC 抛异常崩在创建/恢复
        if webView.responds(to: Selector(("_setDrawsBackground:"))) {
            webView.setValue(false, forKey: "drawsBackground")
        }
        webView.underPageBackgroundColor = .clear
        buildChrome()
        observe()
        if let url { load(url) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit {
        observations.removeAll()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
    }

    private func buildChrome() {
        wantsLayer = true
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        webView.translatesAutoresizingMaskIntoConstraints = false
        progressBar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(toolbar)
        addSubview(webView)
        addSubview(progressBar)

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
            toolbar.topAnchor.constraint(equalTo: topAnchor),
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
            webView.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        updateNavigationButtons()
    }

    private func observe() {
        observations = [
            webView.observe(\.url, options: [.new]) { [weak self] _, _ in self?.urlDidChange() },
            webView.observe(\.title, options: [.new]) { [weak self] _, _ in self?.titleDidChange() },
            webView.observe(\.estimatedProgress, options: [.new]) { [weak self] _, _ in self?.progressDidChange() },
            webView.observe(\.isLoading, options: [.new]) { [weak self] _, _ in self?.progressDidChange() },
            webView.observe(\.canGoBack, options: [.new]) { [weak self] _, _ in self?.updateNavigationButtons() },
            webView.observe(\.canGoForward, options: [.new]) { [weak self] _, _ in self?.updateNavigationButtons() },
        ]
    }

    /// 配置热重载：UA / Inspector（config.toml 保存即生效，含已打开的 pane）
    func applySettings() {
        webView.customUserAgent = Self.settings.effectiveUserAgent
        webView.isInspectable = Self.settings.inspectable
    }

    /// 外观：工具条随主题（背景 / 前景色由控制器主题热切换时调用）
    func applyTheme(background: NSColor, foreground: NSColor) {
        toolbar.wantsLayer = true
        toolbar.layer?.backgroundColor = background.withAlphaComponent(0.6).cgColor
        addressField.textColor = foreground
        for b in [backButton, forwardButton, reloadButton] { b.contentTintColor = foreground.withAlphaComponent(0.85) }
    }

    // MARK: - 导航

    func load(_ url: URL) {
        lastRequestedURL = url
        showingErrorPage = false
        webView.load(URLRequest(url: url))
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
        if showingErrorPage, let url = lastRequestedURL { load(url) } else { webView.reload() }
    }

    /// 焦点进地址栏并全选（Cmd+Shift+L）
    func focusAddressBar() {
        window?.makeFirstResponder(addressField)
        addressField.currentEditor()?.selectAll(nil)
    }

    /// 当前页面交给系统默认浏览器（Widevine / 通行密钥等 WebKit 嵌入做不到的场景）
    func openExternally() {
        guard let url = effectiveURL else { return }
        NSWorkspace.shared.open(url)
    }

    /// 对外可见的"当前网址"：错误页 / 空白页时回退到最近请求的真实 URL
    var effectiveURL: URL? {
        if let url = webView.url, url.scheme != "about", !showingErrorPage { return url }
        return lastRequestedURL ?? webView.url
    }

    func zoom(by factor: CGFloat) {
        webView.pageZoom = min(max(webView.pageZoom * factor, 0.5), 3.0)
    }
    func resetZoom() { webView.pageZoom = 1.0 }

    @objc private func addressEntered() {
        navigate(to: addressField.stringValue)
        window?.makeFirstResponder(webView)
    }

    private func urlDidChange() {
        currentURL = effectiveURL
        if !editingAddress { addressField.stringValue = effectiveURL?.absoluteString ?? "" }
        objectWillChange.send()
    }

    private func titleDidChange() {
        pageTitle = webView.title ?? ""
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

    private enum CodingKeys: String, CodingKey { case uuid, url, title }

    static func decode(from decoder: Decoder) throws -> BrowserPaneView {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let id = try c.decodeIfPresent(String.self, forKey: .uuid).flatMap(UUID.init(uuidString:)) ?? UUID()
        let url = try c.decodeIfPresent(String.self, forKey: .url).flatMap(URL.init(string:))
        let pane = BrowserPaneView(id: id, url: url ?? settings.homeURL)
        if let title = try c.decodeIfPresent(String.self, forKey: .title) { pane.pageTitle = title }
        return pane
    }

    override func encodePayload(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id.uuidString, forKey: .uuid)
        try c.encodeIfPresent(effectiveURL?.absoluteString, forKey: .url)
        try c.encode(pageTitle, forKey: .title)
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
        // 记住主帧的真实请求（链接点击 / 重定向），错误页不能覆盖它。
        // targetFrame == nil 是 target=_blank（走 createWebViewWith 开新 pane），不算本 pane 的导航；
        // 错误页自身的模拟加载也会回调到这里，跳过
        if navigationAction.targetFrame?.isMainFrame == true,
           let url = navigationAction.request.url, url.scheme != "about" {
            if url == pendingErrorPageURL {
                pendingErrorPageURL = nil
            } else {
                lastRequestedURL = url
                showingErrorPage = false
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
        showError(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        showError(error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // WebContent 进程崩溃：首次自动重载；10s 内再崩就停下来提示，避免"崩溃→重载→再崩"死循环
        let now = Date()
        if let last = lastProcessTerminationAt, now.timeIntervalSince(last) < 10 {
            showError(NSError(domain: "QuickTerm.Browser", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "页面进程反复崩溃，已停止自动重载。按 Cmd+R 重试。"]))
            return
        }
        lastProcessTerminationAt = now
        reload()
    }

    private func showError(_ error: Error) {
        let ns = error as NSError
        // 取消 / 被下载策略接管 / 帧加载中断都不是错误
        if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled { return }
        if ns.domain == "WebKitErrorDomain" && (ns.code == 102 || ns.code == 204) { return }
        let failing = (ns.userInfo[NSURLErrorFailingURLErrorKey] as? URL) ?? lastRequestedURL
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
        showingErrorPage = true
        if let failing {
            pendingErrorPageURL = failing
            webView.loadSimulatedRequest(URLRequest(url: failing), responseHTML: html)
        } else {
            webView.loadHTMLString(html, baseURL: nil)
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

// MARK: - UI 代理（JS 对话框 / 新窗口 / 文件选择）

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

    /// target=_blank / window.open → 新的浏览器 pane
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // window.open('') / 空 URL（页面稍后再赋 location 的模式）不开空白 pane；返回 nil 即"弹窗被拦截"
        if let url = navigationAction.request.url, url.scheme != "about", !url.absoluteString.isEmpty {
            controller?.openBrowserPane(url: url, from: self)
        }
        return nil
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

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result { pane?.paneDidBecomeFirstResponder() }
        return result
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
