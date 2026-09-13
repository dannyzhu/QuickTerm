import AppKit
import WebKit

/// A browser pane: multiple tabs (one WKWebView per tab, sharing a process pool and the login state),
/// a tab bar, and a thin toolbar on top (back / forward / reload, the address bar, the progress bar).
/// The toolbar, the address bar and the progress bar are all bound to the current tab.
/// Keyboard focus lands on the current tab's WKWebView (focusTarget); WM-level Cmd keys are
/// intercepted first by the controller's event monitor, and every other Cmd key goes to the page
/// first, which is WebKit's semantics.
final class BrowserPaneView: PaneView {
    override class var kind: PaneKind { .browser }

    /// Browser behavior configuration: top-level keys in config.toml, parsed by ConfigStore and
    /// written here by the controller.
    struct Settings {
        /// The home page Cmd+B opens.
        var home = "https://www.google.com"
        /// Search template used when the address bar gets something that is not a URL (%s = the terms).
        var search = "https://www.google.com/search?q=%s"
        /// User-Agent: by default we pose as Safari, because Google's sign-in pages refuse "embedded
        /// browsers"; "webkit" means no disguise at all.
        var userAgent = "safari"
        /// Web Inspector ("Inspect Element" in the context menu).
        var inspectable = false
        /// Tab bar: always = always visible (the default); auto = hidden while there is only one tab.
        var tabBar = "always"
        /// Maximum and minimum tab width in points (config browser-tab-width /
        /// browser-tab-min-width).
        var tabWidth = 200
        var tabMinWidth = 80
        /// Where downloads land (config browser-download-dir, `~` supported; falls back to ~/Downloads
        /// when the directory does not exist).
        var downloadDirectory = "~/Downloads"

        /// The system's ~/Downloads, used as the fallback.
        static var systemDownloadsURL: URL {
            FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        }

        /// The resolved download directory: `~` expanded, falling back to ~/Downloads when the path is
        /// not actually a directory.
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
            // URL(string:) returns non-nil even for strings with spaces and the like, percent-encoding
            // them automatically, so validate by scheme and host instead.
            if let url = URL(string: home), let scheme = url.scheme?.lowercased(),
               ["http", "https"].contains(scheme) && url.host != nil || ["file", "about"].contains(scheme) {
                return url
            }
            return URL(string: "https://www.google.com")!
        }

        /// QuickTerm: **always** builds a search URL, and is what the "Search with ..." context-menu
        /// item uses. The difference from `url(forInput:)` is that it skips the "looks like a host,
        /// so just open it" test: the menu says Search, so selecting `github.com/x` means the user
        /// wants search results.
        func searchURL(for raw: String) -> URL? {
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let q = text.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? text
            return URL(string: search.replacingOccurrences(of: "%s", with: q))
        }

        /// Address bar text -> URL: a string with a scheme is used as is; something that looks like a
        /// host (contains a dot, contains no space) gets https prepended; anything else is searched.
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

    /// The process pool and the persistent data store shared by every browser pane: logins survive
    /// across tabs, across panes and across restarts.
    private static let processPool = WKProcessPool()

    /// One tab: its own WKWebView plus its navigation state. It is also what WebExtensions calls a
    /// "tab" (`WKWebExtensionTab`: every tabs.* API an extension calls lands on these methods).
    @MainActor
    final class Tab: NSObject, WKWebExtensionTab {
        let id = UUID()
        /// The pane this tab belongs to, which is what an extension calls a "window".
        weak var pane: BrowserPaneView?
        /// Which extension this webView's pages are dedicated to (nil = an ordinary web configuration).
        /// The WKWebViewConfiguration for an extension page and for an ordinary page are not
        /// interchangeable, so navigating across that boundary swaps the webView in place.
        var extensionContext: WKWebExtensionContext?
        /// Replaced when the webView is swapped across that boundary (see
        /// BrowserPaneView.rebuildWebView).
        fileprivate(set) var webView: BrowserWebView
        var title = ""
        /// The last real URL that was requested. An error page or about:blank must not overwrite it;
        /// the archive, the address bar, reload and open-externally all read it.
        var lastRequestedURL: URL?
        var showingErrorPage = false
        /// Loading the error page itself also calls back into decidePolicyFor, so remember it and do
        /// not mistake it for a new navigation.
        var pendingErrorPageURL: URL?
        var lastProcessTerminationAt: Date?
        var observations: [NSKeyValueObservation] = []

        init(webView: BrowserWebView) {
            self.webView = webView
            super.init()
        }

        /// The "current URL" as seen from outside: on an error page or a blank page it falls back to
        /// the last real URL that was requested.
        var effectiveURL: URL? {
            if let url = webView.url, url.scheme != "about", !showingErrorPage { return url }
            return lastRequestedURL ?? webView.url
        }

        var displayTitle: String {
            if !title.isEmpty { return title }
            return effectiveURL?.host ?? L("browser.tab.untitled")
        }

        // MARK: WKWebExtensionTab (all optional; WebKit uses a default for anything not implemented)

        func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? { pane }

        /// The header requires NSNotFound when the tab is in no window at all; returning 0 would make
        /// the extension believe it is the first tab.
        func indexInWindow(for context: WKWebExtensionContext) -> Int {
            pane?.tabs.firstIndex { $0 === self } ?? NSNotFound
        }

        func webView(for context: WKWebExtensionContext) -> WKWebView? { webView }

        func title(for context: WKWebExtensionContext) -> String? { displayTitle }

        func url(for context: WKWebExtensionContext) -> URL? { effectiveURL }

        /// The URL currently being loaded; nil once loading has finished.
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

        /// tabs.remove: closing the last tab has to close the pane with it, exactly as Cmd+W, the tab
        /// bar's close button and window.close do. Calling closeTab alone would be swallowed silently
        /// by its `tabs.count > 1` guard while the extension is told the call succeeded.
        func close(for context: WKWebExtensionContext,
                   completionHandler: @escaping ((any Error)?) -> Void) {
            guard let pane else {
                completionHandler(BrowserExtensionManager.unsupported("The tab is already closed."))
                return
            }
            if pane.tabs.count > 1 {
                // A refused close (the page is in element fullscreen) has to reach the extension as
                // an error: tabs.remove resolving successfully while the tab is still there is how an
                // extension ends up looping on it.
                guard pane.closeTab(self) else {
                    completionHandler(BrowserExtensionManager.unsupported(
                        "The tab cannot be closed while its page is in fullscreen."))
                    return
                }
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

        /// A click on the extension's button counts as a user gesture: activeTab permission is granted
        /// temporarily, following Chrome's semantics.
        func shouldGrantPermissionsOnUserGesture(for context: WKWebExtensionContext) -> Bool { true }
    }

    private(set) var tabs: [Tab] = []
    private(set) var activeTabIndex = 0
    var activeTab: Tab? { tabs.indices.contains(activeTabIndex) ? tabs[activeTabIndex] : nil }
    /// The current tab's WKWebView. With no tabs this is a placeholder, which cannot happen: a pane
    /// always has at least one tab.
    var webView: BrowserWebView { activeTab?.webView ?? placeholderWebView }
    private lazy var placeholderWebView = BrowserWebView(frame: .zero, configuration: makeConfiguration())

    private let tabBar = BrowserTabBarView()
    private var tabBarHeight: NSLayoutConstraint!
    private let toolbar = NSView()
    private let backButton = NSButton()
    private let forwardButton = NSButton()
    private let reloadButton = NSButton()
    let addressField = BrowserAddressField()   // tests need access to it
    /// Floor width for the address bar: no number of pinned extensions may squeeze it below this.
    /// Chrome does exactly the same.
    static let addressFieldMinimumWidth: CGFloat = 200
    /// Priority of that floor constraint: it has to stay below 500, the priority SwiftUI measures a
    /// hosted pane's width at, or the constraint stretches a narrow pane instead.
    static let addressFieldMinimumPriority = NSLayoutConstraint.Priority(rawValue: 300)
    /// The download button between the address bar and the extension toolbar. Hidden when there are no
    /// downloads, with its width and its surrounding gaps collapsing to 0 together.
    let downloadButton = BrowserDownloadButton()
    /// This pane's download list; every WKDownloadDelegate callback lands on it.
    let downloads = BrowserDownloadList()
    private lazy var downloadPopover = BrowserDownloadPopover(list: downloads)
    /// The pane owns the popover: `NSPopover.contentViewController` is a strong reference, so a content
    /// controller that also held the NSPopover would form a cycle and closing the pane would never
    /// release the list, the items or the WKDownloads. Built lazily on the first click.
    private var downloadPopoverHost: NSPopover?
    /// The download button's width and its trailing gap: both go to zero when it is hidden, so the
    /// toolbar behaves as if it were not there at all. The 6pt on its leading side is the gap that
    /// already existed between the address bar and the extension toolbar, and it stays.
    private var downloadButtonWidth: NSLayoutConstraint!
    private var downloadTrailingGap: NSLayoutConstraint!
    /// The extension toolbar to the right of the address bar; the download button sits between them.
    let extensionBar = BrowserExtensionToolbar()
    /// Handler for the "Add to QuickTerm" message posted by a Web Store page. It holds the pane weakly
    /// so that WKUserContentController does not form a cycle.
    private lazy var scriptHandler = BrowserExtensionScriptHandler(pane: self)
    private let progressBar = NSProgressIndicator()
    private let webArea = NSView()
    private var editingAddress = false
    /// The pane was not in a window when window.close() arrived: the close request is re-sent once it
    /// is attached again. Tests read this.
    private(set) var pendingCloseRequest = false
    /// A Web Store install is in flight; this gates re-entry from further page messages.
    private var webStoreInstallInFlight = false
    private var themeBackground: NSColor = .black
    private var themeForeground: NSColor = .white

    /// Page title and current URL of the active tab, for the status bar and the archive.
    var pageTitle: String { activeTab?.title ?? "" }
    var currentURL: URL? { activeTab?.effectiveURL }
    var lastRequestedURL: URL? { activeTab?.lastRequestedURL }

    override var paneTitle: String { activeTab?.displayTitle ?? L("browser.pane.title") }

    /// When this pane was last activated - focused, or handed a link. Used to pick the "most recent"
    /// browser pane when a link is Cmd+clicked in a terminal.
    private(set) var lastActivatedAt = Date()

    override func paneDidBecomeFirstResponder() {
        super.paneDidBecomeFirstResponder()
        makeCurrentForExtensions()
    }

    /// Make the extension world treat this pane as the current window.
    ///
    /// `WKWebExtensionContext.focusedWindow` is a **cached value**. Only `didFocusWindow(_:)` changes
    /// it; WebKit never goes back and asks the delegate. It is exactly what
    /// `tabs.query({active:true,currentWindow:true})` reads, so once the cache drifts, an extension's
    /// messages are delivered to a tab in a different pane - possibly on a different screen - which
    /// looks to the user like "clicking the icon does nothing".
    /// So besides taking keyboard focus, announce it again when a toolbar button is clicked (which does
    /// not change the first responder) and when the window becomes key.
    func makeCurrentForExtensions() {
        lastActivatedAt = Date()
        extensionController?.didFocusWindow(self)
    }

    /// Where extension events are reported; nil when the config turns extensions off, which silences
    /// all of them.
    private var extensionController: WKWebExtensionController? {
        let manager = BrowserExtensionManager.current
        return manager.isEnabled ? manager.controller : nil
    }

    /// A tab event as reported to the extensions. For tests: it checks the ordering, and whether the
    /// tab was still attached to the pane at the moment it was reported - WebKit calls
    /// `tab.window(for:)` back right then to compute the windowId for tabs.onRemoved.
    struct ReportedTabEvent: Equatable {
        let kind: String
        let tab: UUID?
        let previous: UUID?
        let windowAttached: Bool
    }

    /// Test hook; always nil in production.
    static var tabEventRecorderForTesting: ((ReportedTabEvent) -> Void)?

    private func recordTabEvent(_ kind: String, _ tab: Tab?, previous: Tab? = nil) {
        guard let recorder = Self.tabEventRecorderForTesting else { return }
        recorder(ReportedTabEvent(kind: kind, tab: tab?.id, previous: previous?.id,
                                  windowAttached: tab?.pane != nil))
    }

    /// One-shot "teardown already ran" flag. **Read-only from outside**: the control-plane tests use it
    /// to prove that a browser pane which was displaced really went through the close path. The lazy
    /// shortcut in `spec apply --replace` is to swap the pane out by assignment, and then this stays
    /// false forever while the downloads and the extension window events leak.
    private(set) var reportedWindowClose = false

    /// The pane is being removed from the workspace (called when the controller closes it): tell the
    /// extensions that this "window" is gone. Reported exactly once.
    func paneWillClose() {
        guard !reportedWindowClose else { return }
        reportedWindowClose = true
        // The download list is private to the pane: once the pane is gone there is no UI and no
        // progress, and WKDownload.delegate is a weak reference that nils itself out. Better to cancel
        // the transfers explicitly than to leave a pile of them running with nobody watching.
        for item in downloads.items where item.isActive { downloads.cancel(item) }
        downloadPopoverHost?.performClose(nil)
        extensionController?.didCloseWindow(self)
        // If the pane we just closed was the extensions' current window, focusedWindow would stay
        // empty: every `currentWindow` query misses and extension icons stop responding to clicks. So
        // on the next turn of the run loop, hand "current window" to a browser pane that is still
        // alive.
        DispatchQueue.main.async { [weak self] in
            guard let next = BrowserExtensionManager.current.host?.focusedBrowserPane,
                  next !== self else { return }
            next.makeCurrentForExtensions()
        }
    }

    /// Request that the whole pane be closed (the last tab was closed, an extension called
    /// windows.remove, or the page called window.close).
    /// A pane in an inactive workspace, or one caught in a hierarchy rebuild, has no window: record the
    /// request and re-send it once it is attached again.
    /// This has to check whether the pane is attached to a window **right now**: `controller` falls
    /// back to the most recent controller (link routing needs that), but `closePane` only knows panes
    /// in the active workspace, so closing through the fallback controller is a silent no-op.
    func requestPaneClose() {
        if window != nil, let controller {
            controller.requestClosePane(self)
        } else {
            pendingCloseRequest = true
        }
    }

    /// A link handed in from outside (a Cmd+click in a terminal): open it in a new tab and activate it.
    func openLink(_ url: URL) {
        addTab(url: url, activate: true)
        lastActivatedAt = Date()
    }
    /// The container itself does not take focus: keyboard focus lives on the current tab's WKWebView.
    override var acceptsFirstResponder: Bool { false }
    override var focusTarget: NSView { webView }
    /// Hover-to-focus is driven by the container's tracking area; an override of WKWebView's
    /// mouseMoved never receives the events.
    override var installsHoverTracking: Bool { true }

    // MARK: - Construction

    init(id: UUID = UUID(), url: URL?) {
        super.init(id: id, frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        buildChrome()
        // Extensions load asynchronously at startup and the pane may well be built first: reinstall
        // the injected scripts after an install, a removal or an enable/disable.
        NotificationCenter.default.addObserver(self, selector: #selector(extensionsDidChange),
                                               name: .browserExtensionsDidChange, object: nil)
        extensionController?.didOpenWindow(self)   // the window has to exist before the tabs do
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

    // MARK: - WebKit's own UA

    /// The UA without the web-facing disguise: it is what an extension's background, its workers and
    /// its own pages see.
    /// The fallback value is WKWebView's default UA on macOS, with the system version baked in by
    /// WebKit. The real one is measured once when the first pane comes up, and if it differs it
    /// overwrites this and makes every tab reinstall its injected scripts - so a WebKit version bump,
    /// or adding applicationNameForUserAgent later, is picked up automatically.
    private(set) static var webKitUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko)"
    private static var userAgentProbe: UserAgentProbe?
    private static var didCaptureUserAgent = false

    static func captureWebKitUserAgent() {
        guard !didCaptureUserAgent else { return }
        didCaptureUserAgent = true
        let probe = UserAgentProbe()
        userAgentProbe = probe
        probe.measure { measured in
            userAgentProbe = nil
            guard !measured.isEmpty, measured != webKitUserAgent else { return }
            webKitUserAgent = measured
            // Reinstall the injected scripts in tabs that are already open: the UA inside a script is
            // baked in when the script is generated.
            NotificationCenter.default.post(name: .browserExtensionsDidChange, object: nil)
        }
    }

    /// Measure `navigator.userAgent` once in a clean configuration - no controller attached, no
    /// customUserAgent set.
    /// Evaluating it on an empty WebView is unreliable because there is no page, so load an empty
    /// document first and ask afterwards.
    private final class UserAgentProbe: NSObject, WKNavigationDelegate {
        private let webView = WKWebView(frame: .zero)
        private var completion: ((String) -> Void)?

        func measure(_ completion: @escaping (String) -> Void) {
            self.completion = completion
            webView.navigationDelegate = self
            webView.loadHTMLString("<html></html>", baseURL: nil)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { read() }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { read() }

        private func read() {
            guard completion != nil else { return }
            webView.evaluateJavaScript("navigator.userAgent") { [weak self] value, _ in
                guard let self, let completion else { return }
                self.completion = nil
                completion(value as? String ?? "")
            }
        }
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

    /// Wiring for extensions: every tab's configuration has to carry the controller, because a tab
    /// without it is invisible to the extensions - plus the "Add to QuickTerm" button on Web Store
    /// detail pages and the channel it posts back through.
    /// That channel is registered in a private content world, so a page's own JS cannot reach
    /// `messageHandlers.quicktermExtension`.
    private func prepareForExtensions(_ configuration: WKWebViewConfiguration, extensionPage: Bool = false) {
        let manager = BrowserExtensionManager.current
        guard manager.isEnabled else { return }
        Self.captureWebKitUserAgent()
        configuration.webExtensionController = manager.controller
        let content = configuration.userContentController
        let world = BrowserExtensionWebStore.contentWorld
        // The configuration handed back by window.open may already be registered, and registering the
        // same name twice throws an ObjC exception.
        content.removeScriptMessageHandler(forName: BrowserExtensionWebStore.messageHandlerName,
                                           contentWorld: world)
        content.add(scriptHandler, contentWorld: world, name: BrowserExtensionWebStore.messageHandlerName)
        content.addUserScript(BrowserExtensionWebStore.userScript)
        // An extension iframe embedded in a web page routes tabs.* and friends through the background
        // instead; calling them directly gets the page process killed by WebKit. An extension
        // configuration is not injected (a window.open popup from an extension page runs in the
        // extension process, where calling them directly is fine), and the configuration handed back by
        // window.open shares one userContentController with the opener, so do not append twice.
        guard !extensionPage else { return }
        // externally_connectable: the page-side chrome.runtime alias. Its contents change with the set
        // of installed extensions, so deduplicate on the marker in the script's first line.
        if let external = manager.externalMessagingUserScript,
           !content.userScripts.contains(where: { $0.source.hasPrefix(BrowserExtensionCompat.externalMessagingMarker) }) {
            content.addUserScript(external)
        }
        // An extension iframe embedded in a web page inherits the web-facing UA disguise from the page's
        // WebView, whereas in Chrome an extension's frames always report the browser's own UA. So swap
        // navigator.userAgent inside such a frame back to WebKit's own; see userAgentScript.
        if !content.userScripts.contains(where: { $0.source.hasPrefix(BrowserExtensionCompat.userAgentMarker) }) {
            content.addUserScript(BrowserExtensionCompat.userAgentUserScript(Self.webKitUserAgent))
        }
        guard !content.userScripts.contains(where: { $0 === BrowserExtensionCompat.frameUserScript }) else { return }
        content.addUserScript(BrowserExtensionCompat.frameUserScript)
    }

    /// Reinstall every tab's injected scripts after an extension is added, removed, enabled or
    /// disabled: the externally_connectable address list has changed, and WKUserScript can only be
    /// cleared and re-added wholesale. Pages that are already open are unaffected and only pick it up
    /// on their next navigation, exactly as installing an extension in Chrome behaves.
    /// Extensions' own pages, whose configuration comes from context.webViewConfiguration, are left
    /// alone.
    @objc private func extensionsDidChange() {
        for tab in tabs where tab.extensionContext == nil {
            let configuration = tab.webView.configuration
            configuration.userContentController.removeAllUserScripts()
            prepareForExtensions(configuration)
        }
    }

    // MARK: - Tab management

    /// A new tab (a nil url means the home page). The webView parameter exists because on window.open
    /// WebKit demands that the view be created from the configuration it handed us; at that point only
    /// the opener knows which extension that configuration belongs to, which is what `inheriting`
    /// carries in.
    @discardableResult
    func addTab(url: URL?, activate: Bool, webView given: BrowserWebView? = nil,
                inheriting inherited: WKWebExtensionContext? = nil) -> Tab {
        // An extension's own page (webkit-extension://..., such as an options page or
        // tabs.create(runtime.getURL(...))) must be built from context.webViewConfiguration; WebKit
        // rejects the main-frame load in an ordinary configuration.
        // A popup opened from an extension page is still inside the same extension, so the binding has
        // to be in place before install(), which uses it to decide whether to apply the web-facing UA
        // disguise.
        let context = given == nil ? url.flatMap(extensionContext(for:)) : inherited
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
        archiveDidChange.send()   // the set of tabs changed: schedule one debounced archive write
        return tab
    }

    /// Which loaded extension this URL belongs to; nil for an ordinary web address.
    private func extensionContext(for url: URL) -> WKWebExtensionContext? {
        BrowserExtensionManager.current.extensionContext(forResourceURL: url)
    }

    private func makeWebView(extensionContext context: WKWebExtensionContext?) -> BrowserWebView {
        // context.webViewConfiguration is a customized copy of the controller's configuration, already
        // carrying requiredWebExtensionBaseURL and the controller; do not pile makeConfiguration's
        // settings on top of it.
        if let config = context?.webViewConfiguration {
            return BrowserWebView(frame: .zero, configuration: config)
        }
        return BrowserWebView(frame: .zero, configuration: makeConfiguration())
    }

    /// Wire a WebView into the pane: delegates, appearance, settings, KVO and geometry. Both a new tab
    /// and a cross-boundary WebView swap go through here.
    private func install(_ webView: BrowserWebView, for tab: Tab) {
        webView.pane = self
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        // Springs and struts, NOT Auto Layout - deliberately, and the one place in this pane that is.
        //
        // When a page element goes fullscreen (the fullscreen button on a <video>), WebKit does not
        // ask us anything: -[WKFullScreenWindowController enterFullScreen:] drops a
        // WKFullScreenPlaceholderView where the web view sat, moves the real WKWebView into its own
        // WebCoreFullScreenWindow and sets its frame to the screen rect **by hand**. From that moment
        // the frame belongs to WebKit, in a window that is not ours.
        //
        // With translatesAutoresizingMaskIntoConstraints = false and four edge constraints into
        // webArea, that frame is owned by a layout engine instead, and the engine does not follow the
        // view out of the pane: the web view arrives in WebKit's window layout-managed but
        // unconstrained, and the next layout pass - a SwiftUI update, or rebuildTabBar() off the title
        // KVO, which is exactly what a pause-then-play on a video site fires - writes the pane's inline
        // size back over WebKit's fullscreen frame. The page is then laid out at ~500x600 in the corner
        // of a 1728x1117 black fullscreen backdrop, and because we also turn the web view's own
        // background off (below) nothing paints at all: the user sees a solid black picture, the audio
        // keeps playing because the media element never changed state, and a right-click still lands on
        // the live render tree, so they get an ordinary WebKit page menu on the black.
        //
        // An autoresizing mask has no such owner. Inside the pane it makes the view follow webArea on
        // every resize; the moment WebKit moves it, the mask travels with the view and makes it follow
        // WebKit's window instead. Do not "tidy this up" into constraints, and do not try to flip the
        // flag from a fullscreen callback either - macOS WKUIDelegate has no fullscreen hook at all
        // (_WKFullscreenDelegate is SPI), so there is no supported moment to flip it in.
        webView.translatesAutoresizingMaskIntoConstraints = true
        applySettings(to: webView, extensionPage: tab.extensionContext != nil)
        // Transparent background, so QuickTerm's wallpaper and blur layer show through; wherever the
        // page paints its own background nothing changes.
        // drawsBackground goes through a private setter (_setDrawsBackground:), so probe for it first:
        // if it is ever removed, KVC would throw and crash during pane creation or restore.
        if webView.responds(to: Selector(("_setDrawsBackground:"))) {
            webView.setValue(false, forKey: "drawsBackground")
        }
        webView.underPageBackgroundColor = .clear
        observe(tab)
        // Fill webArea and keep filling it. webArea itself is still laid out by Auto Layout; a
        // springs-and-struts subview inside an Auto Layout parent is the supported mixed mode, and it
        // is what lets the view keep a frame of its own while WebKit has it.
        webView.frame = webArea.bounds
        webView.autoresizingMask = [.width, .height]
        webArea.addSubview(webView)
        webView.isHidden = true
    }

    /// Is WebKit holding this tab's web view right now?
    ///
    /// When a page element goes fullscreen, -[WKFullScreenWindowController enterFullScreen:] drops a
    /// WKFullScreenPlaceholderView where the web view sat and moves the real WKWebView into its own
    /// WebCoreFullScreenWindow (see install() for the frame half of the same story). From that moment
    /// the view is **not ours to touch**, and a live probe measured both halves of what that costs:
    /// setting `isHidden` on it blanks the fullscreen window outright - an empty screen with the page
    /// still running and the audio still playing, and the fullscreen window's first responder dropped
    /// and never came back - and taking it out of its superview would tear it out of WebKit's window,
    /// leaving our placeholder behind in webArea and an empty fullscreen window covering the screen
    /// with no way out of it.
    ///
    /// The test is "whose window is it in". A web view in no window at all is nobody's: that is a tab
    /// still being installed, or the whole pane parked in an inactive workspace, and those must stay
    /// ordinary.
    private func isLentToWebKit(_ tab: Tab) -> Bool {
        guard let host = tab.webView.window else { return false }
        return host !== window
    }

    /// Is WebKit holding this tab's web view in element fullscreen right now?
    ///
    /// The in-app paths answer a refusal by leaving things alone, which is the right outcome for a
    /// keystroke. A control-plane caller needs the opposite: it has to hear that the close did not
    /// happen, or `browser close` reports `applied: true` for a tab that is still open. So the
    /// command layer asks this BEFORE it records any change and refuses the whole command.
    func webKitHoldsFullscreen(_ tab: Tab) -> Bool { isLentToWebKit(tab) }

    /// Crossing the extension-page / ordinary-page boundary: swap the tab's WebView in place for one
    /// with the right configuration, keeping the tab's identity, its index and the tabId the extensions
    /// see. WebKit explicitly requires replacing a tab's web view when navigating between an extension
    /// URL and an ordinary one.
    /// Returns false when the swap was refused, which is only ever the fullscreen case.
    @discardableResult
    private func rebuildWebView(of tab: Tab, for context: WKWebExtensionContext?) -> Bool {
        // Refuse rather than half-swap: `old.removeFromSuperview()` below would take the view out of
        // WebKit's fullscreen window (see isLentToWebKit). The navigation that asked for the swap has
        // already been cancelled by the caller, so the page just stays where it is until the user
        // leaves fullscreen - which is the one outcome here that destroys nothing.
        guard !isLentToWebKit(tab) else {
            fputs("[quickterm] browser: not swapping a tab's web view while WebKit has it in element "
                  + "fullscreen; the navigation across the extension-page boundary is dropped\n", stderr)
            return false
        }
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
        return true
    }

    func newTab(url: URL? = nil) { addTab(url: url ?? Self.settings.homeURL, activate: true) }

    /// Switch to the tab at `index`: show only it, bind the toolbar to it, and give it focus if this
    /// pane already held focus or the caller asked for it.
    func selectTab(at index: Int, forceFocus: Bool = false) {
        selectTab(at: index, forceFocus: forceFocus, previous: activeTab)
    }

    /// `previous` is the "previously active tab" reported to the extensions. The close-tab path has to
    /// read it out **before** the array shrinks: after the removal activeTabIndex still holds the old
    /// value and `activeTab` already points at a different tab, so tabs.onActivated either never fires
    /// or fires carrying a previousTabId that was never active. When the tab being closed is the
    /// current one, pass nil - Chrome's semantics is to send no previousTabId at all.
    private func selectTab(at index: Int, forceFocus: Bool, previous: Tab?) {
        guard tabs.indices.contains(index) else { return }
        let hadFocus = forceFocus || (window.map { holdsFirstResponder(of: $0) } ?? false)
        activeTabIndex = index
        // Skip a tab WebKit is holding in element fullscreen: writing isHidden on that view blanks
        // WebKit's fullscreen window (see isLentToWebKit). Deliberately a skipped write and not a
        // refused switch - nothing here is destructive, the switch is honoured for every tab we do
        // own, and refusing would break Ctrl+Tab, an extension's tabs.update and `browser goto --tab`
        // for the *other* tabs while buying no safety. The write that was skipped is made good in
        // webViewDidMoveToWindow, when WebKit hands the view back.
        for (i, tab) in tabs.enumerated() where !isLentToWebKit(tab) { tab.webView.isHidden = i != index }
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
        archiveDidChange.send()   // the active tab changed (switch or close): schedule a debounced write
    }

    /// Relative switching (Ctrl+Tab / Ctrl+Shift+Tab), wrapping around at both ends.
    func selectTab(offset: Int) {
        guard tabs.count > 1 else { return }
        selectTab(at: ((activeTabIndex + offset) % tabs.count + tabs.count) % tabs.count)
    }

    /// Close the tab at `index`. The last tab is not closed here; the controller closes the pane
    /// instead. Returns whether a tab was actually closed.
    @discardableResult
    func closeTab(at index: Int) -> Bool {
        guard tabs.count > 1, tabs.indices.contains(index) else { return false }
        // Refuse the whole close while WebKit has this tab's web view in element fullscreen. Unlike
        // the tab switch above there is no "do the rest and skip one write" here: the
        // removeFromSuperview below would tear the view out of WebKit's fullscreen window (see
        // isLentToWebKit), and what the user would be left with is an empty fullscreen window over
        // the whole screen. `false` is the same "nothing was closed" answer the last-tab guard gives,
        // so every caller that already honours it keeps the pane and the tab intact.
        guard !isLentToWebKit(tabs[index]) else {
            fputs("[quickterm] browser: refusing to close a tab while WebKit has its web view in "
                  + "element fullscreen; leave fullscreen first\n", stderr)
            return false
        }
        // Record focus first: when the closing tab's webView leaves the window, AppKit silently resets
        // the FR to the window without sending resign, so a later holdsFirstResponder reads false and
        // the surviving tab never gets focus.
        let hadFocus = window.map { holdsFirstResponder(of: $0) } ?? false
        // Read it before the removal: closing the current tab means previous = nil, and the new current
        // tab is reported as activated normally; closing some other tab leaves the current tab
        // unchanged, so current === previous inside selectTab and no spurious activation is sent.
        let previous: Tab? = index == activeTabIndex ? nil : activeTab
        let tab = tabs.remove(at: index)
        // Report before tearing down: inside didCloseTab WebKit synchronously calls tab.window(for:)
        // back to compute the windowId for tabs.onRemoved, and tab.pane has to still be there at that
        // moment - tearing down first yields windowId = -1.
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

    /// Returns whether the tab was actually closed, so that a caller who has to answer someone else -
    /// an extension's tabs.remove - can report the refusal instead of claiming success.
    @discardableResult
    func closeTab(_ tab: Tab) -> Bool {
        guard let i = tabs.firstIndex(where: { $0 === tab }) else { return false }
        return closeTab(at: i)
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

    // MARK: Element fullscreen: the web view leaves the pane and comes back

    /// A tab's web view is about to leave the window it is in. Record whether it is the first
    /// responder **now**: when the first-responder view is taken out of a window, AppKit silently
    /// resets the window's first responder and never calls resignFirstResponder (measured with a
    /// standalone probe, docs/porting-notes.md), so once the move is over there is nothing left to
    /// read back.
    fileprivate func webViewWillMove(_ webView: BrowserWebView, to newWindow: NSWindow?) {
        guard let host = webView.window, host !== newWindow else { return }
        webView.heldFirstResponderBeforeMove = (host.firstResponder as? NSView)
            .map { $0 === webView || $0.isDescendant(of: webView) } ?? false
    }

    /// A tab's web view finished moving between windows. Only element fullscreen gets here with a
    /// window that is not ours; a pane being remounted by SwiftUI moves the whole subtree, web views
    /// included, and never lands in a foreign window.
    fileprivate func webViewDidMoveToWindow(_ webView: BrowserWebView) {
        // No entry in `tabs` yet means install() is still running for a brand-new tab.
        guard let tab = tab(for: webView), let host = webView.window else { return }
        guard host === window else {
            // WebKit just took it for fullscreen. Latch the focus it carried out of our window: the
            // pane's own `focused` flag is the second witness, because it is still true here - the
            // silent reset above is exactly the case where no resign ever arrives.
            webView.wasFocusedWhenTakenForFullscreen =
                webView.heldFirstResponderBeforeMove || (tab === activeTab && focused)
            return
        }
        // Home again, where the web view is ours once more. Re-apply the visibility invariant that
        // selectTab skipped while it was not: the user may have switched tabs in the meantime, and
        // two visible web views stacked in webArea paint over each other.
        webView.isHidden = tab !== activeTab
        guard webView.wasFocusedWhenTakenForFullscreen else { return }
        webView.wasFocusedWhenTakenForFullscreen = false
        // Entering fullscreen reset this window's first responder to the window and leaving it never
        // puts it back, so the pane sits on `focused == true` with no responder behind it - the
        // stale-focus hazard docs/porting-notes.md describes, reached without the pane ever detaching
        // from its window, so PaneView's own reclaim-on-attach never runs. Hand the first responder
        // to the **active** tab's web view: the one coming back may be a background tab by now.
        // Never steal it from a responder that took focus while we were away (the same rule as
        // PaneView.viewDidMoveToWindow); the window itself, nothing at all, or the view that just
        // came back all mean the detach dropped it.
        if let fr = host.firstResponder, fr !== host, fr !== webView,
           (fr as? NSView)?.window === host { return }
        if let controller, !controller.paneMayReclaimFocus(self) { return }
        host.makeFirstResponder(focusTarget)
    }

    // MARK: - Chrome

    private func buildChrome() {
        wantsLayer = true
        for v in [tabBar, toolbar, progressBar, webArea] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        tabBar.onSelect = { [weak self] i in self?.selectTab(at: i) }
        tabBar.onNewTab = { [weak self] in self?.newTab() }
        // The close button on the last tab closes the whole pane, matching Cmd+W and window.close;
        // otherwise that x would be dead.
        tabBar.onClose = { [weak self] i in
            guard let self, !self.closeTab(at: i), self.tabs.count == 1 else { return }
            self.requestPaneClose()
        }
        tabBarHeight = tabBar.heightAnchor.constraint(equalToConstant: 0)

        for (button, symbol, tip, action) in [
            (backButton, "chevron.left", L("browser.toolbar.back"), #selector(goBack)),
            (forwardButton, "chevron.right", L("browser.toolbar.forward"), #selector(goForward)),
            (reloadButton, "arrow.clockwise", L("browser.toolbar.reload"), #selector(reloadOrStop)),
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
        addressField.placeholderString = L("browser.address.placeholder")
        addressField.isBezeled = true
        addressField.bezelStyle = .roundedBezel
        addressField.font = .systemFont(ofSize: 12)
        addressField.lineBreakMode = .byTruncatingTail
        addressField.usesSingleLineMode = true
        addressField.cell?.sendsActionOnEndEditing = false
        // The address bar's text width stays out of the "who gets squeezed" contest, one notch below
        // the extension toolbar's .defaultLow: otherwise a long URL would squeeze the toolbar out of
        // existence. The address bar's floor comes solely from the >= 200 constraint below.
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

        // The extension toolbar lays itself out by hand and only publishes an intrinsicContentSize, at
        // a non-required priority, so it cannot stretch the pane's width.
        extensionBar.pane = self
        extensionBar.translatesAutoresizingMaskIntoConstraints = false
        extensionBar.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        // Compression resistance below the address bar's floor: as pinned extensions pile up, the
        // toolbar is squeezed first (the buttons that no longer fit hide and stay in the puzzle menu)
        // rather than shrinking the address bar to a stub.
        extensionBar.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        toolbar.addSubview(extensionBar)

        progressBar.style = .bar
        progressBar.isIndeterminate = false
        progressBar.minValue = 0
        progressBar.maxValue = 1
        progressBar.controlSize = .small
        progressBar.isHidden = true

        // The address bar's floor width: above the extension toolbar's compression resistance
        // (.defaultLow = 250), so no number of extensions takes the address bar below 200pt. But it has
        // to stay **below 500**: the pane is hosted by SwiftUI, NSHostingView measures it at a fitting
        // priority of 500, and a width constraint at >= 500 stretches a narrow pane even when it is not
        // required (measured: a 250-wide pane came out at 300).
        let addressFieldMinWidth = addressField.widthAnchor.constraint(greaterThanOrEqualToConstant:
                                                                        Self.addressFieldMinimumWidth)
        addressFieldMinWidth.priority = Self.addressFieldMinimumPriority
        // The extension toolbar keeps at least one puzzle button's width, one notch above the address
        // bar's floor and still < 500: once the pane is too narrow even for a 200pt address bar, the
        // address bar keeps giving way (as in Chrome) and the puzzle button stays in the pane, where it
        // can still be clicked.
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
            // address bar | 6pt | download button | extension toolbar. With no downloads the button's
            // width and its trailing gap are both 0, which restores the original
            // "address bar | 6pt | extension toolbar".
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

    /// For tests: the current width of each tab item.
    var tabItemWidthsForTesting: [CGFloat] {
        tabBar.layoutSubtreeIfNeeded()
        return tabBar.itemViews.map { $0.frame.width }
    }

    /// For tests: the tab bar view.
    var tabBarForTesting: BrowserTabBarView { tabBar }
    /// For tests: the address bar.
    var addressFieldForTesting: NSTextField { addressField }
    /// For tests: the container the tab web views live in.
    var webAreaForTesting: NSView { webArea }

    /// Whether the tab bar is shown: either always, or once there is more than one tab.
    var tabBarVisible: Bool { Self.settings.tabBarAlwaysVisible || tabs.count > 1 }


    /// Sync the tab bar: titles and active state are handed to BrowserTabBarView, which lays itself out
    /// by hand and puts zero constraints on the pane.
    private func rebuildTabBar() {
        let visible = tabBarVisible
        tabBar.isHidden = !visible
        if !visible { tabBar.updateHover(atBarPoint: nil) }   // no mouseExited arrives once hidden
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
                // An extension action is computed per tab, and both its icon and whether it is enabled
                // follow the URL. Without re-reading after a navigation, the toolbar button is stuck in
                // the previous page's state, and a button with `isEnabled == false` swallows clicks
                // silently.
                if tab === self.activeTab { self.extensionBar.reload() }
            },
            webView.observe(\.title, options: [.new]) { [weak self, weak tab] wv, _ in
                guard let self, let tab else { return }
                // The KVO callback is a @Sendable closure while Tab is MainActor-isolated; these
                // particular WebKit notifications always arrive on the main thread.
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

    /// Bind the toolbar, the address bar, the progress bar and back/forward to the current tab.
    private func syncChromeToActiveTab() {
        urlDidChange()
        progressDidChange()
        updateNavigationButtons()
    }

    /// Live config reload: UA, Inspector and the tab bar. Saving config.toml takes effect immediately,
    /// including in panes and tabs that are already open.
    func applySettings() {
        for tab in tabs { applySettings(to: tab.webView, extensionPage: tab.extensionContext != nil) }
        rebuildTabBar()
        extensionBar.reload()
    }

    /// An extension's own pages (its options page, `tabs.create(runtime.getURL(...))`) do not get the
    /// web-facing UA disguise: the extension's background and its workers see WebKit's own UA, and the
    /// page half has to agree with them. Otherwise the two halves of one extension see two different
    /// browsers and a library takes a different branch in one of them (see
    /// BrowserExtensionCompat.userAgentScript).
    private func applySettings(to webView: WKWebView, extensionPage: Bool) {
        webView.customUserAgent = extensionPage ? nil : Self.settings.effectiveUserAgent
        webView.isInspectable = Self.settings.inspectable
    }

    /// Appearance: the toolbar and the tab bar follow the theme. The controller calls this with the
    /// background and foreground colors when the theme is switched live.
    func applyTheme(background: NSColor, foreground: NSColor) {
        themeBackground = background
        themeForeground = foreground
        toolbar.wantsLayer = true
        // The toolbar takes the pure background color so the current tab, in the same color, joins onto
        // it (the tab bar's baseline breaks under that tab); that is what makes the layering read.
        toolbar.layer?.backgroundColor = background.cgColor
        tabBar.applyTheme(background: background, foreground: foreground)
        addressField.textColor = foreground
        for b in [backButton, forwardButton, reloadButton] { b.contentTintColor = foreground.withAlphaComponent(0.85) }
        extensionBar.applyTheme(foreground: foreground)
        downloadButton.tint = foreground.withAlphaComponent(0.85)
        rebuildTabBar()
    }

    // MARK: - Navigation (acting on the current tab)

    func load(_ url: URL) {
        guard let tab = activeTab else { return }
        load(url, in: tab)
    }

    func load(_ url: URL, in tab: Tab) {
        tab.lastRequestedURL = url
        tab.showingErrorPage = false
        tab.webView.load(URLRequest(url: url))
    }

    /// Address bar text: either a URL or search terms.
    func navigate(to text: String) {
        guard let url = Self.settings.url(forInput: text) else { return }
        load(url)
    }

    @objc func goBack() { webView.goBack() }
    @objc func goForward() { webView.goForward() }
    @objc func reloadOrStop() {
        if webView.isLoading { webView.stopLoading() } else { reload() }
    }
    /// On an error page, reload the original URL rather than the error page itself.
    func reload() {
        guard let tab = activeTab else { return }
        reload(tab, fromOrigin: false)
    }

    /// Reload one named tab; this is what the control plane's `browser reload` uses, and `fromOrigin`
    /// bypasses the cache.
    /// The error-page rule is written **exactly once**, here: what gets reloaded is the original URL,
    /// not the error page itself.
    func reload(_ tab: Tab, fromOrigin: Bool) {
        if tab.showingErrorPage, let url = tab.lastRequestedURL {
            load(url, in: tab)
            return
        }
        if fromOrigin { tab.webView.reloadFromOrigin() } else { tab.webView.reload() }
    }

    /// Move focus into the address bar and select all of it (Cmd+Shift+L).
    func focusAddressBar() {
        window?.makeFirstResponder(addressField)
        addressField.currentEditor()?.selectAll(nil)
        addressField.didFocusProgrammatically()
    }

    /// Hand the current page to the system default browser, for what an embedded WebKit cannot do:
    /// Widevine, passkeys and the like.
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
        archiveDidChange.send()   // the page that is open changed: schedule a debounced archive write
    }

    private func progressDidChange() {
        let loading = webView.isLoading
        progressBar.isHidden = !loading
        progressBar.doubleValue = webView.estimatedProgress
        let reloadLabel = loading ? L("browser.toolbar.stop") : L("browser.toolbar.reload")
        reloadButton.image = NSImage(systemSymbolName: loading ? "xmark" : "arrow.clockwise",
                                     accessibilityDescription: reloadLabel)
    }

    private func updateNavigationButtons() {
        backButton.isEnabled = webView.canGoBack
        forwardButton.isEnabled = webView.canGoForward
    }

    // MARK: - Archiving

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
            // A single-page archive, the format from before tabs existed.
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
        // Compatibility with the old format: url / title still carry the current tab.
        try c.encodeIfPresent(effectiveURL?.absoluteString, forKey: .url)
        try c.encode(pageTitle, forKey: .title)
        try c.encode(tabs.map { TabSnapshot(url: $0.effectiveURL?.absoluteString, title: $0.title) }, forKey: .tabs)
        try c.encode(activeTabIndex, forKey: .activeTab)
    }
}

// MARK: - WebExtensions: a pane is a window

/// What an extension calls a "window" is one browser pane: QuickTerm has a single real window, and the
/// pane is the unit of browsing context.
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

    /// windows.remove: the pane may be in an inactive workspace, with no window attached and a nil
    /// controller. In that case record the request and close once it is attached again; calling
    /// `controller?.requestClosePane` straight away would be a silent no-op.
    func close(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        requestPaneClose()
        completionHandler(nil)
    }
}

// MARK: - Extension UI (popovers / menus / Web Store installs)

extension BrowserPaneView {
    /// An extension action's popup, anchored to its own button, or to the puzzle button when it has
    /// none.
    /// The toolbar is at the top of the pane and the view is not flipped, so the popover has to land
    /// **below** the button, which is the minY edge.
    func presentExtensionPopup(_ action: WKWebExtension.Action, of context: WKWebExtensionContext) {
        guard let popover = action.popupPopover else { return }
        let anchor = extensionBar.anchorButton(for: context)
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
    }

    /// The web-extensions WM action (Cmd+Shift+E): pop up the puzzle menu.
    func showExtensionsMenu() {
        extensionBar.showMenu()
    }

    /// "Add to QuickTerm" on a Web Store detail page: download and unpack, confirm the permissions,
    /// install.
    /// Progress is written into the address bar's placeholder text - there is nowhere else to put it,
    /// and it does not interrupt the page.
    func beginWebStoreInstall(id: String) {
        let manager = BrowserExtensionManager.current
        guard manager.isEnabled else {
            report(title: L("browser.install.turned-off.title"),
                   text: L("browser.install.turned-off.body"))
            return
        }
        // One install at a time: if the page posts messages back to back, we must not pile up N
        // downloads, N ditto processes and N modal alerts.
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
                alert.messageText = L("browser.install.confirm.title", staged.displayName)
                let permissions = staged.permissionSummary
                alert.informativeText = permissions.isEmpty
                    ? L("browser.install.confirm.no-permissions")
                    : L("browser.install.confirm.permissions", permissions.joined(separator: "\n"))
                alert.addButton(withTitle: L("browser.install.confirm.button"))
                alert.addButton(withTitle: L("browser.button.cancel"))
                guard alert.runModal() == .alertFirstButtonReturn else {
                    manager.discard(staged)
                    return
                }
                self.addressField.placeholderString = L("browser.install.progress.installing")
                let installed = try await manager.commit(staged)
                self.report(title: L("browser.install.done.title", installed.displayName),
                            text: L("browser.install.done.body"))
            } catch {
                self.report(title: L("browser.install.failed.title"), text: error.localizedDescription)
            }
        }
    }

    private func report(title: String, text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.addButton(withTitle: L("browser.button.ok"))
        alert.runModal()
    }
}

// MARK: - Address bar

extension BrowserPaneView: NSTextFieldDelegate {
    func controlTextDidBeginEditing(_ obj: Notification) { editingAddress = true }
    func controlTextDidEndEditing(_ obj: Notification) {
        editingAddress = false
        // On Return, NSTextField posts this notification first and sends its action afterwards, so
        // resetting the text to the current URL here would make the action read the current URL instead
        // of what the user typed - "whatever you type takes you back to the same page". Only losing
        // focus or cancelling restores the text to the current URL.
        let movement = (obj.userInfo?["NSTextMovement"] as? Int).flatMap(NSTextMovement.init(rawValue:))
        if movement == .return { return }
        addressField.stringValue = effectiveURL?.absoluteString ?? ""
    }

    /// Esc: abandon the edit and return focus to the page.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            addressField.stringValue = effectiveURL?.absoluteString ?? ""
            window?.makeFirstResponder(webView)
            return true
        }
        return false
    }
}

// MARK: - Navigation delegate

extension BrowserPaneView: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let tab = tab(for: webView) else { decisionHandler(.allow); return }
        // Cmd+clicking a link opens it in a new background tab, as Chrome does, leaving this page alone.
        if navigationAction.navigationType == .linkActivated,
           navigationAction.modifierFlags.contains(.command),
           let url = navigationAction.request.url {
            addTab(url: url, activate: false)
            decisionHandler(.cancel)
            return
        }
        // Remember the main frame's real request (a link click, a redirect); an error page must not
        // overwrite it.
        // targetFrame == nil means target=_blank, which goes through createWebViewWith to open a new
        // tab and is not a navigation of this tab; the error page's own simulated load also calls back
        // in here, so skip it.
        if navigationAction.targetFrame?.isMainFrame == true,
           let url = navigationAction.request.url, url.scheme != "about" {
            if url == tab.pendingErrorPageURL {
                tab.pendingErrorPageURL = nil
            } else {
                tab.lastRequestedURL = url
                tab.showingErrorPage = false
            }
            // Crossing the extension-page / ordinary-page boundary: WebKit requires a web view whose
            // configuration matches, or it cancels the navigation. An extension configuration carries
            // requiredWebExtensionBaseURL and can only reach that extension's own pages, and an
            // ordinary configuration cannot reach extension pages at all.
            let target = extensionContext(for: url)
            if target !== tab.extensionContext {
                decisionHandler(.cancel)
                // Only load when the swap really happened: with the old web view still in place the
                // configuration is the wrong side of the boundary and WebKit would cancel the
                // main-frame load anyway, leaving a half-dead tab behind.
                if rebuildWebView(of: tab, for: target) { tab.webView.load(URLRequest(url: url)) }
                return
            }
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        // Content the page cannot display (an attachment, an unknown MIME type) becomes a download.
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
        // The WebContent process crashed: reload automatically the first time, but if it crashes again
        // within 10s, stop and show a message instead of looping crash -> reload -> crash.
        let now = Date()
        if let last = tab.lastProcessTerminationAt, now.timeIntervalSince(last) < 10 {
            showError(NSError(domain: "QuickTerm.Browser", code: 1, userInfo: [
                NSLocalizedDescriptionKey: L("browser.error.repeated-crash")]), in: tab)
            return
        }
        tab.lastProcessTerminationAt = now
        if tab.showingErrorPage, let url = tab.lastRequestedURL { load(url, in: tab) } else { tab.webView.reload() }
    }

    private func showError(_ error: Error, in tab: Tab) {
        let ns = error as NSError
        // A cancellation, a hand-off to the download policy, and an interrupted frame load are not
        // errors.
        if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled { return }
        if ns.domain == "WebKitErrorDomain" && (ns.code == 102 || ns.code == 204) { return }
        let failing = (ns.userInfo[NSURLErrorFailingURLErrorKey] as? URL) ?? tab.lastRequestedURL
        let url = failing?.absoluteString ?? ""
        let title = L("browser.error.title")
        let html = """
        <html><head><meta name="color-scheme" content="dark light"><style>
        body{font:14px -apple-system,system-ui;color:#c0caf5;background:transparent;padding:32px}
        h2{font-weight:600;margin:0 0 8px}code{color:#7aa2f7;word-break:break-all}p{opacity:.8}
        </style></head><body><h2>\(Self.escape(title))</h2><p>\(Self.escape(ns.localizedDescription))</p>
        <p><code>\(Self.escape(url))</code></p></body></html>
        """
        // Present the error page as a simulated response for the failing URL: webView.url stays on it,
        // so the address bar, the archive and Cmd+R do not turn into about:blank, and it enters the
        // history so Back returns to the previous page. loadHTMLString(baseURL:) creates no history
        // entry.
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

// MARK: - Downloads (into browser-download-dir, ~/Downloads by default, numbering name collisions)

extension BrowserPaneView: WKDownloadDelegate {
    /// Take over a download: attach the delegate and put it in the list immediately.
    /// This happens before `decideDestinationUsing`, because a download that cannot reach the server
    /// never gets as far as picking a destination - and it still has to show up in the list as
    /// "failed".
    func beginDownload(_ download: WKDownload) {
        download.delegate = self
        guard downloads.item(for: download) == nil else { return }
        let guessed = download.originalRequest?.url?.lastPathComponent ?? ""
        let filename = guessed.isEmpty || guessed == "/" ? L("browser.download.default-filename") : guessed
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
        // Collision detection cannot look at the disk alone: WebKit only creates the file after we
        // reply, so two downloads with the same name can both run decideDestination before either file
        // exists and walk away with the same path (the second one then fails with EEXIST, or hangs).
        // A destination already handed to another in-flight download counts as taken too.
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
        // The user pressed cancel; the list already reads .cancelled and markCancelled is idempotent.
        if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled {
            downloads.markCancelled(item)
        } else {
            downloads.markFailed(item, message: ns.localizedDescription)
        }
    }

    // MARK: The download button in the toolbar

    /// The list changed: refresh the button's visibility and progress ring, and the popover if it is
    /// open.
    func downloadsDidChange() {
        let hasItems = !downloads.items.isEmpty
        downloadButton.update()
        downloadButtonWidth.constant = hasItems ? BrowserDownloadButton.size : 0
        downloadTrailingGap.constant = hasItems ? -6 : 0
        // Optional chaining on purpose: do not instantiate the popover if it was never opened.
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

    /// For tests: the popover, so rows can be counted without showing it.
    var downloadPopoverForTesting: BrowserDownloadPopover { downloadPopover }
}

// MARK: - UI delegate (JS dialogs / a new window becomes a new tab / file pickers)

extension BrowserPaneView: WKUIDelegate {
    /// Host for a JS dialog: this pane's window, else the main window; and when there is neither (the
    /// pane is unmounted and the app is not frontmost), runModal synchronously. WebKit's
    /// completionHandler has to be called: a sheet attached to a window that is never shown never
    /// completes, and the page's JS thread wedges there forever.
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
        alert.messageText = frame.request.url?.host ?? L("browser.dialog.alert-title")
        alert.informativeText = message
        alert.addButton(withTitle: L("browser.button.ok"))
        present(alert) { _ in completionHandler() }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = frame.request.url?.host ?? L("browser.dialog.confirm-title")
        alert.informativeText = message
        alert.addButton(withTitle: L("browser.button.ok"))
        alert.addButton(withTitle: L("browser.button.cancel"))
        present(alert) { completionHandler($0 == .alertFirstButtonReturn) }
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        let alert = NSAlert()
        alert.messageText = prompt
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.stringValue = defaultText ?? ""
        alert.accessoryView = field
        alert.addButton(withTitle: L("browser.button.ok"))
        alert.addButton(withTitle: L("browser.button.cancel"))
        present(alert) { completionHandler($0 == .alertFirstButtonReturn ? field.stringValue : nil) }
    }

    /// target=_blank and window.open become a new tab in the same pane. The webView has to be created
    /// from the configuration WebKit handed us, and returned: that is what gives the page a real window
    /// object, so window.opener and postMessage work and a popup login can post its result back.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        let source = tab(for: webView)
        prepareForExtensions(configuration, extensionPage: source?.extensionContext != nil)
        let popup = BrowserWebView(frame: .zero, configuration: configuration)
        // Only open in the foreground when the opener is the current tab; a popup from a background tab
        // (a timed window.open, say) opens in the background and does not interrupt what the user is
        // typing.
        // The configuration WebKit handed us inherited the opener's extension binding, so the new tab
        // has to record which extension its configuration belongs to. Otherwise the first
        // cross-boundary navigation check is wrong, and an extension popup opened from an extension
        // page gets treated as a web page and given the UA disguise, disagreeing with the extension's
        // other half.
        _ = addTab(url: nil, activate: source === activeTab, webView: popup,
                   inheriting: source?.extensionContext)
        return popup
    }

    /// The page called window.close() itself: close that tab, or, when it is the last tab, ask the
    /// controller to close the pane.
    /// While the pane is in an inactive workspace (no window attached, controller nil) the request is
    /// recorded and re-sent once it is attached again - WebKit only calls back once.
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

/// The address bar reports back to the pane when it becomes first responder: the field editor that
/// takes over afterwards is a descendant of the pane, so the pane still counts as holding focus (its
/// border stays lit, and Cmd+W hands focus to the successor).
final class BrowserAddressField: NSTextField {
    weak var pane: BrowserPaneView?
    /// Became first responder and has not been interacted with yet: the next mouseDown selects all.
    /// AppKit calls makeFirstResponder before it hands the mouseDown to the view, so clicking in sets
    /// this flag first and the mouseDown consumes it right after. Entering by keyboard or Cmd+Shift+L
    /// goes through focusAddressBar, which selects all itself and clears the flag.
    private var selectAllOnFirstClick = false

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result {
            pane?.paneDidBecomeFirstResponder()
            selectAllOnFirstClick = true
        }
        return result
    }

    /// Called after a programmatic focus (Cmd+Shift+L): treat later clicks as ordinary editing.
    func didFocusProgrammatically() { selectAllOnFirstClick = false }

    /// The first click selects everything, so Cmd+C copies the URL outright and typing replaces it,
    /// the way Safari and Chrome behave. A click while already editing behaves normally: place the
    /// caret, double-click to select a word, drag to select.
    override func mouseDown(with event: NSEvent) {
        let firstClick = selectAllOnFirstClick
        selectAllOnFirstClick = false
        super.mouseDown(with: event)   // installs/uses the field editor and tracks through to mouseUp
        if firstClick, let editor = currentEditor(), editor.selectedRange.length == 0 {
            editor.selectAll(nil)      // a plain click selects all; a drag keeps the dragged selection
        }
    }
}

/// WKWebView subclass: first-responder changes are reported back to the owning pane (the truth about
/// focus is that the FR is a descendant of the pane).
/// Hover-to-focus does not live here: WKWebView's tracking area is held by an internal observer and an
/// override of mouseMoved never receives the events, so the PaneView container's own tracking area
/// handles it (installsHoverTracking).
final class BrowserWebView: WKWebView {
    weak var pane: BrowserPaneView?

    /// Was this view the first responder just before it last changed windows? Written in
    /// viewWillMove, because the move itself destroys the answer (AppKit resets the first responder
    /// without a resign; see BrowserPaneView.webViewWillMove).
    fileprivate var heldFirstResponderBeforeMove = false
    /// ... and the latched version of it: the view held keyboard focus at the moment WebKit carried
    /// it off into its fullscreen window, so focus is owed back to the pane when it returns.
    fileprivate var wasFocusedWhenTakenForFullscreen = false

    /// WebKit re-parents this view into its own window for element fullscreen and back again
    /// afterwards, without telling us through any delegate - macOS WKUIDelegate has no fullscreen
    /// hook at all (_WKFullscreenDelegate is SPI). These two are the only notice we get, so the
    /// pane's visibility and focus invariants are re-established from here.
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        pane?.webViewWillMove(self, to: newWindow)
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        pane?.webViewDidMoveToWindow(self)
    }

    // We do not add the extensions' entries to the page context menu ourselves: WebKit's
    // WebContextMenuProxyMac sees the webExtensionController on the configuration and appends each
    // extension's contextMenus entries, separators included, on its own.
    // Appending them again would duplicate every entry, and besides, context.menuItems(for:) returns
    // the set for the **tab bar's** context menu (the tab context), not this one.

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
