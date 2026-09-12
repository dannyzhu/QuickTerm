import SwiftUI
import WebKit
import XCTest
@testable import QuickTerm

final class BrowserExtensionTests: XCTestCase {
    // MARK: - The CRX header

    /// A CRX is a header plus a zip: both the v2 and the v3 header have to come off, and anything that is
    /// not a CRX, or whose header runs past the data, returns nil.
    func testCRXZipExtraction() {
        let zip = Data([0x50, 0x4B, 0x03, 0x04, 1, 2, 3, 4])   // "PK\u{3}\u{4}" plus a little content
        func le32(_ v: UInt32) -> [UInt8] {
            [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]
        }
        // v3: a 12-byte fixed header plus a protobuf header of headerLength bytes.
        let v3Header = [UInt8](repeating: 0xAB, count: 9)
        var crx3 = Array("Cr24".utf8) + le32(3) + le32(UInt32(v3Header.count)) + v3Header
        crx3 += [UInt8](zip)
        XCTAssertEqual(CRX.zipData(from: Data(crx3)), zip, "v3: 12 + headerLength")
        // v2: a 16-byte fixed header plus the public key and the signature.
        let key = [UInt8](repeating: 0x11, count: 5), signature = [UInt8](repeating: 0x22, count: 7)
        var crx2 = Array("Cr24".utf8) + le32(2) + le32(UInt32(key.count)) + le32(UInt32(signature.count))
        crx2 += key + signature + [UInt8](zip)
        XCTAssertEqual(CRX.zipData(from: Data(crx2)), zip, "v2: 16 + public key + signature")
        // Bad input.
        XCTAssertNil(CRX.zipData(from: Data(Array("PK\u{3}\u{4}".utf8) + [UInt8](repeating: 0, count: 20))), "wrong magic")
        XCTAssertNil(CRX.zipData(from: Data(Array("Cr24".utf8) + le32(3) + le32(9))), "the length the header declares runs past the data")
        XCTAssertNil(CRX.zipData(from: Data(Array("Cr24".utf8) + le32(9) + le32(0) + le32(0))), "unknown version")
        XCTAssertNil(CRX.zipData(from: Data([0x43, 0x72])), "too short")
    }

    // MARK: - Web Store URL

    func testWebStoreURLParsing() {
        let id = "abcdefghijklmnopabcdefghijklmnop"
        func parse(_ s: String) -> String? {
            BrowserExtensionManager.extensionID(fromWebStoreURL: URL(string: s)!)
        }
        XCTAssertEqual(parse("https://chromewebstore.google.com/detail/some-slug/\(id)"), id)
        XCTAssertEqual(parse("https://chrome.google.com/webstore/detail/some-slug/\(id)?hl=zh"), id, "the old domain plus a query")
        XCTAssertEqual(parse("https://chromewebstore.google.com/detail/some-slug/\(id)/reviews"), id, "a sub-path of the detail page")
        XCTAssertNil(parse("https://chromewebstore.google.com/category/extensions"), "not a detail page")
        XCTAssertNil(parse("https://chromewebstore.google.com/detail/slug/tooshort"), "wrong id length")
        XCTAssertNil(parse("https://example.com/detail/slug/\(id)"), "not a Web Store domain")
        XCTAssertTrue(BrowserExtensionManager.webStoreDownloadURL(id: id).absoluteString.contains("id%3D\(id)"))
    }

    // MARK: - Scanning for a Chrome import

    /// Take the highest-versioned directory for each extension; skip themes, packaged apps, and anything
    /// without a name.
    func testChromeCandidateScan() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("qt-chrome-\(UUID().uuidString)/Extensions")
        defer { try? fm.removeItem(at: root.deletingLastPathComponent()) }
        let normal = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        let theme = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        let nameless = "cccccccccccccccccccccccccccccccc"
        func write(_ id: String, _ version: String, _ manifest: [String: Any]) throws {
            let dir = root.appendingPathComponent("\(id)/\(version)")
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: manifest)
                .write(to: dir.appendingPathComponent("manifest.json"))
        }
        // Chrome's real directory name is `<version>_<installCount>`.
        try write(normal, "1.15.4_1", ["name": "Old", "version": "1.15.4", "manifest_version": 3])
        try write(normal, "1.15.5_0", ["name": "New", "version": "1.15.5", "manifest_version": 3])
        try write(theme, "1.0_0", ["name": "Theme", "theme": ["colors": [:]]])
        try write(nameless, "1.0_0", ["manifest_version": 3])
        let candidates = BrowserExtensionManager.chromeCandidates(inExtensions: root)
        XCTAssertEqual(candidates.count, 1, "only one of them is importable")
        XCTAssertEqual(candidates.first?.id, normal)
        XCTAssertEqual(candidates.first?.directory.lastPathComponent, "1.15.5_0", "the highest-version directory wins")
        XCTAssertTrue(BrowserExtensionManager.compareVersions("1.9.0", "1.10.0"), "compared numerically per segment, not lexicographically")
        XCTAssertFalse(BrowserExtensionManager.compareVersions("2.0", "1.99"))
        // The `_N` suffix must not take part in the comparison: Int("4_1") is nil, which would read the last
        // segment as 0 and make the two compare equal.
        XCTAssertTrue(BrowserExtensionManager.compareVersions("1.15.4_1", "1.15.5_0"))
        XCTAssertFalse(BrowserExtensionManager.compareVersions("1.15.5_0", "1.15.4_1"))
        XCTAssertTrue(BrowserExtensionManager.compareVersions("1.0.0.6_1", "1.0.0.7_0"))
        XCTAssertTrue(BrowserExtensionManager.compareVersions("2.8.28_0", "2.9_0"))
        XCTAssertTrue(BrowserExtensionManager.compareVersions("1.0_0", "1.0_1"), "same version, decided by the install count")
    }

    // MARK: - Origin checks on the Web Store install channel

    /// The message posted back by "Add to QuickTerm" is accepted only from the **main frame** of a Web Store
    /// detail page, and its id has to match that page. Otherwise any page or iframe could raise the native
    /// install dialog with a single postMessage, under whatever extension name it picked.
    func testWebStoreInstallMessageGate() {
        let id = "abcdefghijklmnopabcdefghijklmnop"
        let other = "ponmlkjihgfedcbaponmlkjihgfedcba"
        let store = URL(string: "https://chromewebstore.google.com/detail/some-slug/\(id)")!
        func accepted(body: Any = ["id": "abcdefghijklmnopabcdefghijklmnop"],
                      isMainFrame: Bool = true, frameURL: URL? = nil,
                      originHost: String? = "chromewebstore.google.com") -> String? {
            BrowserExtensionWebStore.acceptedInstallID(body: body, isMainFrame: isMainFrame,
                                                       frameURL: frameURL ?? store, originHost: originHost)
        }
        XCTAssertEqual(accepted(), id, "store detail page, main frame, matching id")
        XCTAssertNil(accepted(isMainFrame: false), "a subframe, meaning a third-party iframe")
        XCTAssertNil(accepted(frameURL: URL(string: "https://evil.example/detail/x/\(id)")!), "not a store domain")
        XCTAssertNil(accepted(frameURL: URL(string: "https://chromewebstore.google.com/category/extensions")!),
                     "not a detail page")
        XCTAssertNil(accepted(body: ["id": other]), "the id does not match the detail page")
        XCTAssertNil(accepted(originHost: "evil.example"), "the script's origin is not the store")
        XCTAssertNil(accepted(body: ["id": 42]), "the body has the wrong shape")
        XCTAssertNil(accepted(body: "abcdefghijklmnopabcdefghijklmnop"))
    }

    // MARK: - The injected Web Store button (end to end)

    /// On a store detail page the injected "Add to QuickTerm" has to sit next to the store's own (greyed-out)
    /// "Add to Chrome" button; a click sends the id to the native side over a channel in a private content
    /// world; off a detail page the button hides.
    @MainActor
    func testWebStoreButtonSitsNextToStoreButtonAndPostsID() throws {
        let id = "abcdefghijklmnopabcdefghijklmnop"
        final class Recorder: NSObject, WKScriptMessageHandler {
            var received: [Any] = []
            func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) { received.append(m.body) }
        }
        let recorder = Recorder()
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.addUserScript(BrowserExtensionWebStore.userScript)
        configuration.userContentController.add(recorder, contentWorld: BrowserExtensionWebStore.contentWorld,
                                                name: BrowserExtensionWebStore.messageHandlerName)
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), configuration: configuration)
        let window = NSWindow(contentRect: webView.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = webView
        defer { window.contentView = nil }
        let url = try XCTUnwrap(URL(string: "https://chromewebstore.google.com/detail/video-speed/\(id)?pli=1"))
            // The store renders its own button from JS a moment later: start with an empty shell and add it
            // afterwards, which exercises the MutationObserver that moves ours into place. The label below is
            // the store's own Chinese text, which the injected script matches (see BrowserExtensionUI.swift).
        webView.loadHTMLString("""
            <html><body><h1>Ext</h1><div id="row"></div>
            <script>setTimeout(function(){
              var b=document.createElement('button'); b.textContent='添加至 Chrome'; b.disabled=true;
              document.getElementById('row').appendChild(b);}, 150);</script></body></html>
            """, baseURL: url)
        func eval(_ js: String) throws -> Any? {
            var result: Any?; var done = false
            webView.evaluateJavaScript(js, in: nil, in: BrowserExtensionWebStore.contentWorld) { r in
                if case .success(let v) = r { result = v }
                done = true
            }
            let deadline = Date().addingTimeInterval(3)
            while !done, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
            return result
        }
        let probe = "(function(){var b=document.getElementById('quickterm-install-button');" +
            "return b && b.previousElementSibling ? b.previousElementSibling.textContent : null})()"
        let deadline = Date().addingTimeInterval(5)
        var neighbour: String?
        while Date() < deadline, neighbour != "添加至 Chrome" {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            neighbour = try eval(probe) as? String
        }
        XCTAssertEqual(neighbour, "添加至 Chrome", "the injected button sits right after the store's own")
        XCTAssertEqual(try eval("document.getElementById('quickterm-install-button').style.position") as? String, "static",
                       "once it moves into the row it is no longer floating in the bottom-right corner")
        _ = try eval("document.getElementById('quickterm-install-button').click(); 0")
        let clickDeadline = Date().addingTimeInterval(3)
        while Date() < clickDeadline, recorder.received.isEmpty { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        XCTAssertEqual((recorder.received.first as? [String: Any])?["id"] as? String, id, "the click sends the detail page's id")
        // An in-site navigation away from the detail page hides the button.
        _ = try eval("history.pushState({}, '', '/category/extensions'); window.dispatchEvent(new Event('popstate')); 0")
        XCTAssertEqual(try eval("document.getElementById('quickterm-install-button').hidden") as? Bool, true)
    }

    // MARK: - The manager: install, enable/disable, remove

    @MainActor
    func testInstallEnableDisableRemove() async throws {
        let store = try Self.makeStore()
        defer { try? FileManager.default.removeItem(at: store) }
        let manager = BrowserExtensionManager(configuration: .nonPersistent(), storeDirectory: store)
        let fixture = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let id = "abcdefghijklmnopabcdefghijklmnop"

        let item = try await manager.install(directory: fixture, id: id, source: .local)
        XCTAssertEqual(manager.installed.count, 1)
        XCTAssertEqual(item.context.uniqueIdentifier, id, "the context identifier is the extension id, which keeps page origins stable")
        XCTAssertTrue(item.context.isLoaded)
        XCTAssertEqual(manager.controller.extensionContexts.count, 1)
        XCTAssertTrue(item.hasOptionsPage)
        XCTAssertEqual(item.displayName, "QuickTerm Test Extension")
        // Every permission and host the manifest asks for is granted at install time, with an expiry in the
        // distant future rather than one that has already passed.
        XCTAssertTrue(item.context.hasPermission(.storage))
        XCTAssertTrue(item.context.hasAccess(to: URL(string: "http://example.test/page")!))
        XCTAssertNotNil(item.context.action(for: nil), "the manifest has an action, so there is an action")

        manager.setEnabled(false, for: item)
        XCTAssertFalse(item.context.isLoaded, "disabling unloads it from the controller")
        XCTAssertTrue(manager.controller.extensionContexts.isEmpty)

        // The record is on disk: another manager loading from the same store directory keeps the enabled bit.
        let reloaded = BrowserExtensionManager(configuration: .nonPersistent(), storeDirectory: store)
        await reloaded.loadInstalled()
        XCTAssertEqual(reloaded.installed.count, 1)
        XCTAssertFalse(reloaded.installed[0].enabled, "the disabled state persists")
        XCTAssertFalse(reloaded.installed[0].context.isLoaded)

        manager.setEnabled(true, for: item)
        XCTAssertTrue(item.context.isLoaded, "enabled again")
        // Flipping the global switch off unloads everything.
        manager.isEnabled = false
        XCTAssertFalse(item.context.isLoaded)
        manager.isEnabled = true
        XCTAssertTrue(item.context.isLoaded)

        manager.remove(item)
        XCTAssertTrue(manager.installed.isEmpty)
        XCTAssertTrue(manager.controller.extensionContexts.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.appendingPathComponent(id).path),
                       "removing also deletes the extension's directory")
    }

    // MARK: - The tab and window protocols

    @MainActor
    func testTabAndWindowProtocols() async throws {
        let store = try Self.makeStore()
        defer { try? FileManager.default.removeItem(at: store) }
        let manager = BrowserExtensionManager(configuration: .nonPersistent(), storeDirectory: store)
        let fixture = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let item = try await manager.install(directory: fixture, id: "abcdefghijklmnopabcdefghijklmnop",
                                             source: .local)
        let context = item.context

        let previous = BrowserPaneView.settings
        defer { BrowserPaneView.settings = previous }
        BrowserPaneView.settings.home = "about:blank"
        let pane = BrowserPaneView(url: URL(string: "about:blank"))
        pane.newTab(url: URL(string: "about:blank"))
        XCTAssertEqual(pane.tabs.count, 2)

        XCTAssertEqual(pane.tabs(for: context).count, 2)
        XCTAssertTrue(pane.activeTab(for: context) === pane.tabs[1])
        XCTAssertEqual(pane.windowType(for: context), .normal)
        XCTAssertEqual(pane.windowState(for: context), .normal)
        XCTAssertFalse(pane.isPrivate(for: context))
        XCTAssertTrue(pane.tabs[1].window(for: context) === pane)
        XCTAssertEqual(pane.tabs[0].indexInWindow(for: context), 0)
        XCTAssertEqual(pane.tabs[1].indexInWindow(for: context), 1)
        XCTAssertTrue(pane.tabs[1].isSelected(for: context))
        XCTAssertFalse(pane.tabs[0].isSelected(for: context))
        XCTAssertTrue(pane.tabs[0].webView(for: context) === pane.tabs[0].webView)
        XCTAssertTrue(pane.tabs[0].shouldGrantPermissionsOnUserGesture(for: context),
                      "clicking an extension button counts as a user gesture (activeTab semantics)")

        let activated = expectation(description: "activate")
        pane.tabs[0].activate(for: context) { _ in activated.fulfill() }
        await fulfillment(of: [activated], timeout: 2)
        XCTAssertEqual(pane.activeTabIndex, 0, "the extension's tabs.update({active:true}) switches the active tab")

        let removed = pane.tabs[1]
        let closed = expectation(description: "close")
        pane.tabs[1].close(for: context) { _ in closed.fulfill() }
        await fulfillment(of: [closed], timeout: 2)
        XCTAssertEqual(pane.tabs.count, 1, "the extension's tabs.remove closes the tab")
        XCTAssertNil(removed.window(for: context), "a closed tab no longer belongs to any window")
        XCTAssertEqual(removed.indexInWindow(for: context), NSNotFound, "the header requires NSNotFound when it is in no window")

        // Closing a tab that has already left the pane has to report an error, not claim success.
        let orphan = expectation(description: "orphan")
        removed.close(for: context) { error in
            XCTAssertNotNil(error, "an already-closed tab has to come back with an error")
            orphan.fulfill()
        }
        await fulfillment(of: [orphan], timeout: 2)

        // The last tab: closeTab is refused by the guard, so it turns into a request to close the whole pane
        // (the pane is not in a window yet, so the request is only recorded).
        let last = expectation(description: "last")
        pane.tabs[0].close(for: context) { error in
            XCTAssertNil(error)
            last.fulfill()
        }
        await fulfillment(of: [last], timeout: 2)
        XCTAssertEqual(pane.tabs.count, 1, "the final tab is not closed at the tab layer")
        XCTAssertTrue(pane.pendingCloseRequest, "it becomes a request to close the pane, not a silent no-op")

        // windows.remove works the same way: a pane in an inactive workspace, whose controller is nil, still
        // has to leave a pending close request behind.
        let other = BrowserPaneView(url: URL(string: "about:blank"))
        let windowClosed = expectation(description: "window close")
        other.close(for: context) { error in
            XCTAssertNil(error)
            windowClosed.fulfill()
        }
        await fulfillment(of: [windowClosed], timeout: 2)
        XCTAssertTrue(other.pendingCloseRequest)
    }

    // MARK: - The events reported to extensions when a tab closes

    /// Closing a tab reports didCloseTab first: at that moment WebKit calls back into window(for:) to work out
    /// the windowId for tabs.onRemoved, so the tab has to still be attached to the pane. The tab that takes
    /// over is then reported as activated with previous = nil.
    @MainActor
    func testCloseTabEventOrderAndActivation() throws {
        let previous = BrowserPaneView.settings
        defer { BrowserPaneView.settings = previous }
        BrowserPaneView.settings.home = "about:blank"
        let pane = BrowserPaneView(url: URL(string: "about:blank"))
        pane.newTab(url: URL(string: "about:blank"))
        pane.newTab(url: URL(string: "about:blank"))
        pane.selectTab(at: 1)
        XCTAssertEqual(pane.tabs.count, 3)

        var events: [BrowserPaneView.ReportedTabEvent] = []
        BrowserPaneView.tabEventRecorderForTesting = { events.append($0) }
        defer { BrowserPaneView.tabEventRecorderForTesting = nil }

        let closed = pane.tabs[1], successor = pane.tabs[2]
        XCTAssertTrue(pane.closeTab(at: 1), "close the active tab, the middle one")
        XCTAssertEqual(events.map(\.kind), ["close", "activate"], "close first, then activate")
        XCTAssertEqual(events[0].tab, closed.id)
        XCTAssertTrue(events[0].windowAttached,
                      "the tab is still on the pane when didCloseTab is reported, which keeps windowId from being -1")
        XCTAssertEqual(events[1].tab, successor.id, "the tab that takes over is reported as activated")
        XCTAssertNil(events[1].previous, "a closed tab must not be used as previousTabId")
        XCTAssertTrue(pane.activeTab === successor)

        // Closing a tab that is not active: the active tab does not change, so there must be no activate or
        // deselect event at all.
        events.removeAll()
        XCTAssertTrue(pane.closeTab(at: 0))
        XCTAssertEqual(events.map(\.kind), ["close"])
        XCTAssertTrue(pane.activeTab === successor)
    }

    // MARK: - Content scripts (end to end)

    /// On a WebView with the controller attached, an extension's content script really has to be injected,
    /// which here means rewriting the page title.
    /// Deliberately not an async case: WebKit's loading is driven by the main runloop, and inside an async
    /// test body `RunLoop.run(until:)` never turns it.
    @MainActor
    func testContentScriptRunsInWebViewWithController() throws {
        let store = try Self.makeStore()
        defer { try? FileManager.default.removeItem(at: store) }
        let manager = BrowserExtensionManager(configuration: .nonPersistent(), storeDirectory: store)
        let fixture = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        try Self.installSynchronously(fixture, id: "abcdefghijklmnopabcdefghijklmnop", into: manager)

        let configuration = WKWebViewConfiguration()
        configuration.webExtensionController = manager.controller
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300),
                                configuration: configuration)
        let window = NSWindow(contentRect: webView.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = webView
        defer { window.contentView = nil }
        let url = try XCTUnwrap(URL(string: "http://example.test/index.html"))
        webView.loadHTMLString("<html><head><title>before</title></head><body>hi</body></html>",
                               baseURL: url)
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, webView.title != "EXT-OK" {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertEqual(webView.title, "EXT-OK",
                       "the content script should set the title to EXT-OK; actual title=\(webView.title ?? "nil") "
                       + "url=\(webView.url?.absoluteString ?? "nil") loading=\(webView.isLoading)")
    }

    /// After an extension is installed, removed, enabled or disabled, every tab calls `removeAllUserScripts()`
    /// and re-adds our own injected scripts, because the address list in the externally_connectable shim
    /// changes. WebKit runs extension content scripts over a channel of its own, not through this
    /// userContentController, so after the wipe those content scripts still have to be injected.
    /// Otherwise every tab that is already open would stop running any extension content script for good.
    @MainActor
    func testRemovingUserScriptsKeepsExtensionContentScripts() throws {
        let store = try Self.makeStore()
        defer { try? FileManager.default.removeItem(at: store) }
        let manager = BrowserExtensionManager(configuration: .nonPersistent(), storeDirectory: store)
        let fixture = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        try Self.installSynchronously(fixture, id: "abcdefghijklmnopabcdefghijklmnop", into: manager)

        let configuration = WKWebViewConfiguration()
        configuration.webExtensionController = manager.controller
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300),
                                configuration: configuration)
        let window = NSWindow(contentRect: webView.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = webView
        defer { window.contentView = nil }
        let url = try XCTUnwrap(URL(string: "http://example.test/index.html"))
        func loadAndWaitForContentScript(_ what: String) {
            webView.loadHTMLString("<html><head><title>before</title></head><body>hi</body></html>",
                                   baseURL: url)
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline, webView.title != "EXT-OK" {
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            }
            XCTAssertEqual(webView.title, "EXT-OK", what)
        }
        loadAndWaitForContentScript("baseline: the content script is injected")
        // Simulate the re-add that follows a change to the set of extensions.
        configuration.userContentController.removeAllUserScripts()
        loadAndWaitForContentScript("content scripts are still injected after removeAllUserScripts")
    }

    // MARK: - The extension's own pages (the options page)

    /// A `webkit-extension://` main frame only loads in a WebView built from `context.webViewConfiguration`:
    /// with an ordinary configuration (makeConfiguration) WebKit answers NSURLErrorResourceUnavailable, the
    /// page turns into QuickTerm's error page, and the extension is told the open succeeded.
    @MainActor
    func testOptionsPageLoadsInExtensionConfiguredTab() throws {
        let store = try Self.makeStore()
        defer { try? FileManager.default.removeItem(at: store) }
        let manager = BrowserExtensionManager(configuration: .nonPersistent(), storeDirectory: store)
        let fixture = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        try Self.installSynchronously(fixture, id: "abcdefghijklmnopabcdefghijklmnop", into: manager)
        BrowserExtensionManager.overrideForTesting = manager
        defer { BrowserExtensionManager.overrideForTesting = nil }

        let previous = BrowserPaneView.settings
        defer { BrowserPaneView.settings = previous }
        BrowserPaneView.settings.home = "about:blank"
        let pane = BrowserPaneView(url: URL(string: "about:blank"))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = pane
        defer { window.contentView = nil }

        let options = try XCTUnwrap(manager.installed.first?.context.optionsPageURL)
        XCTAssertEqual(options.host, "abcdefghijklmnopabcdefghijklmnop",
                       "the baseURL lines up with the extension id, which keeps extension page origins stable across restarts")
        let tab = pane.addTab(url: options, activate: true)
        XCTAssertNotNil(tab.extensionContext, "the tab uses the extension-specific configuration")
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, tab.webView.title != "OPTIONS-OK" {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        // The error page is itself loaded against the failing URL with loadSimulatedRequest, so webView.url
        // looks the same either way: check the title and the error-page flag instead.
        XCTAssertEqual(tab.webView.title, "OPTIONS-OK",
                       "the options page has to really load; actual title=\(tab.webView.title ?? "nil") "
                       + "url=\(tab.webView.url?.absoluteString ?? "nil")")
        XCTAssertFalse(tab.showingErrorPage)
        XCTAssertEqual(tab.webView.url, options)
    }

    // MARK: - The toolbar

    /// The extension toolbar is laid out by hand: it must not stretch the pane (a SwiftUI-hosted pane has no
    /// external width constraint).
    @MainActor
    func testExtensionBarDoesNotResizePane() throws {
        // The toolbar reads the "current" manager, so point it at an empty temporary one and keep whatever
        // the user really installed out of this.
        let store = try Self.makeStore()
        defer { try? FileManager.default.removeItem(at: store) }
        BrowserExtensionManager.overrideForTesting =
            BrowserExtensionManager(configuration: .nonPersistent(), storeDirectory: store)
        defer { BrowserExtensionManager.overrideForTesting = nil }
        let previous = BrowserPaneView.settings
        defer { BrowserPaneView.settings = previous }
        BrowserPaneView.settings.home = "about:blank"
        let pane = BrowserPaneView(url: URL(string: "about:blank"))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let hosting = NSHostingView(rootView: PaneHostView(pane: pane).frame(width: 900, height: 600))
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(pane.frame.width, 900, accuracy: 1)
        let bar = pane.extensionBar
        // With no extensions installed, only the puzzle button is left.
        XCTAssertTrue(bar.actionButtonsForTesting.isEmpty)
        XCTAssertEqual(bar.intrinsicContentSize.width, BrowserExtensionToolbar.step, accuracy: 0.01)
        bar.layoutSubtreeIfNeeded()
        XCTAssertEqual(bar.menuButtonForTesting.frame.width, BrowserExtensionToolbar.buttonSize, accuracy: 0.01)
        // The address field sits left of the extension bar, and both stay inside the toolbar.
        let field = pane.addressFieldForTesting
        XCTAssertLessThanOrEqual(field.frame.maxX, bar.frame.minX + 0.5, "the extension bar is right of the address field")
        XCTAssertGreaterThan(field.frame.width, 100, "the address field still takes the remaining space")
        window.contentView = nil
    }

    /// The puzzle menu: with nothing installed there are only three items (import, store, folder) plus the hint.
    @MainActor
    func testExtensionMenuCommands() throws {
        pinUILanguage(.en)
        let previous = BrowserPaneView.settings
        defer { BrowserPaneView.settings = previous }
        BrowserPaneView.settings.home = "about:blank"
        let pane = BrowserPaneView(url: URL(string: "about:blank"))
        let titles = pane.extensionBar.buildMenu().items.map(\.title)
        XCTAssertTrue(titles.contains("Import Installed Extensions from Chrome…"), "\(titles)")
        XCTAssertTrue(titles.contains("Open the Chrome Web Store"))
        XCTAssertTrue(titles.contains("Open the Extensions Folder"))
    }

    // MARK: - Pinning to the toolbar

    /// An old state.json (1.5.2 and earlier, with no pinned key) decodes as unpinned; after setPinned it
    /// round-trips through disk.
    @MainActor
    func testPinnedFlagDefaultsFalseForLegacyStateAndRoundTrips() throws {
        let store = try Self.makeStore()
        defer { try? FileManager.default.removeItem(at: store) }
        let fixture = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let id = "abcdefghijklmnopabcdefghijklmnop"
        try FileManager.default.copyItem(at: fixture, to: store.appendingPathComponent(id, isDirectory: true))
        // The old format: enabled only, no pinned.
        try """
        [{"enabled": true, "id": "\(id)", "installedAt": "2026-01-01T00:00:00Z", "source": "chrome"}]
        """.write(to: store.appendingPathComponent("state.json"), atomically: true, encoding: .utf8)

        let manager = BrowserExtensionManager(configuration: .nonPersistent(), storeDirectory: store)
        try Self.runUntilDone("loading the installed extensions") { await manager.loadInstalled() }
        let item = try XCTUnwrap(manager.installedExtension(withID: id))
        // source / installedAt only line up if the old record really decoded: when decoding fails,
        // loadInstalled() synthesizes a fallback of .local plus the current time, and that one is also
        // enabled=true / pinned=false, so those two bits alone would never catch the regression.
        XCTAssertEqual(item.record.source, .chrome, "the record came from the old state.json, not from the fallback for a missing one")
        XCTAssertEqual(item.record.installedAt,
                       try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-01-01T00:00:00Z")))
        XCTAssertTrue(item.enabled)
        XCTAssertFalse(item.pinned, "a missing pinned key means unpinned")

        manager.setPinned(true, for: item)
        XCTAssertTrue(item.pinned)
        let reloaded = BrowserExtensionManager(configuration: .nonPersistent(), storeDirectory: store)
        try Self.runUntilDone("reloading") { await reloaded.loadInstalled() }
        XCTAssertTrue(try XCTUnwrap(reloaded.installedExtension(withID: id)).pinned, "the pinned state persists")
    }

    /// extensions.pinned_extensions in Chrome's `<profile>/Preferences` is the set that stays pinned after an import.
    func testChromePinnedExtensionIDs() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("qt-chromeprefs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let preferences = dir.appendingPathComponent("Preferences")
        XCTAssertTrue(BrowserExtensionManager.chromePinnedExtensionIDs(preferences: preferences).isEmpty,
                      "no file means nothing is pinned")

        let a = String(repeating: "a", count: 32), b = String(repeating: "b", count: 32)
        try #"{"extensions": {"pinned_extensions": ["\#(a)", "\#(b)"]}, "profile": {"name": "x"}}"#
            .write(to: preferences, atomically: true, encoding: .utf8)
        XCTAssertEqual(BrowserExtensionManager.chromePinnedExtensionIDs(preferences: preferences), [a, b])

        try "not json at all".write(to: preferences, atomically: true, encoding: .utf8)
        XCTAssertTrue(BrowserExtensionManager.chromePinnedExtensionIDs(preferences: preferences).isEmpty,
                      "a parse failure means nothing is pinned, and is not an error")
    }

    /// The toolbar shows only pinned extensions; when more are pinned than fit it fills left to right and
    /// hides the rest (the puzzle button is always at the far right).
    @MainActor
    func testToolbarShowsOnlyPinnedExtensionsAndHidesOverflow() throws {
        let store = try Self.makeStore()
        defer { try? FileManager.default.removeItem(at: store) }
        let manager = BrowserExtensionManager(configuration: .nonPersistent(), storeDirectory: store)
        BrowserExtensionManager.overrideForTesting = manager
        defer { BrowserExtensionManager.overrideForTesting = nil }
        let fixture = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let first = String(repeating: "a", count: 32), second = String(repeating: "b", count: 32)
        try Self.installSynchronously(fixture, id: first, into: manager)
        try Self.installSynchronously(fixture, id: second, into: manager)
        let one = try XCTUnwrap(manager.installedExtension(withID: first))
        let two = try XCTUnwrap(manager.installedExtension(withID: second))

        let bar = BrowserExtensionToolbar(frame: NSRect(x: 0, y: 0, width: 400, height: 22))
        bar.reload()
        XCTAssertTrue(bar.actionButtonsForTesting.isEmpty, "neither is pinned -> no buttons on the toolbar")

        manager.setPinned(true, for: one)
        bar.reload()
        XCTAssertEqual(bar.actionButtonsForTesting.count, 1, "only the pinned one reaches the toolbar")

        manager.setPinned(false, for: one)
        bar.reload()
        XCTAssertTrue(bar.actionButtonsForTesting.isEmpty, "unpinned -> back into the puzzle menu")

        manager.setPinned(true, for: one)
        manager.setPinned(true, for: two)
        bar.reload()
        XCTAssertEqual(bar.actionButtonsForTesting.count, 2)
        XCTAssertEqual(bar.intrinsicContentSize.width, 3 * BrowserExtensionToolbar.step, accuracy: 0.01)
        // Squeeze it down to one button plus the puzzle.
        bar.frame = NSRect(x: 0, y: 0, width: BrowserExtensionToolbar.step + BrowserExtensionToolbar.buttonSize,
                           height: 22)
        bar.needsLayout = true
        bar.layoutSubtreeIfNeeded()
        XCTAssertFalse(bar.actionButtonsForTesting[0].isHidden, "the first one still fits")
        XCTAssertTrue(bar.actionButtonsForTesting[1].isHidden, "the second does not fit -> hidden, though still in the puzzle menu")
        let menu = bar.menuButtonForTesting
        XCTAssertFalse(menu.isHidden)
        XCTAssertEqual(menu.frame.maxX, bar.bounds.maxX, accuracy: 0.01, "the puzzle is always at the far right")
        XCTAssertGreaterThanOrEqual(menu.frame.minX, bar.actionButtonsForTesting[0].frame.maxX - 0.01)

        // When the width is not a whole number of slots (46 is the special case of exactly one slot plus the
        // puzzle) the puzzle still hugs the right edge, leaving no gap behind it.
        bar.frame = NSRect(x: 0, y: 0, width: 60, height: 22)
        bar.needsLayout = true
        bar.layoutSubtreeIfNeeded()
        XCTAssertFalse(bar.actionButtonsForTesting[0].isHidden)
        XCTAssertTrue(bar.actionButtonsForTesting[1].isHidden)
        XCTAssertEqual(menu.frame.maxX, bar.bounds.maxX, accuracy: 0.01, "with buttons hidden, the puzzle hugs the right edge")
        XCTAssertLessThanOrEqual(bar.actionButtonsForTesting[0].frame.maxX, menu.frame.minX + 0.01,
                                 "the puzzle does not sit on top of a button")

        // When everything fits, the old behavior stands: the puzzle follows immediately after the buttons.
        bar.frame = NSRect(x: 0, y: 0, width: 400, height: 22)
        bar.needsLayout = true
        bar.layoutSubtreeIfNeeded()
        XCTAssertEqual(menu.frame.minX, 2 * BrowserExtensionToolbar.step, accuracy: 0.01)
    }

    /// The puzzle menu: one row per extension, with the "Pin to Toolbar" check in the submenu following the
    /// record, and a suffix on the disabled ones.
    @MainActor
    func testExtensionMenuPinItem() throws {
        pinUILanguage(.en)
        let store = try Self.makeStore()
        defer { try? FileManager.default.removeItem(at: store) }
        let manager = BrowserExtensionManager(configuration: .nonPersistent(), storeDirectory: store)
        BrowserExtensionManager.overrideForTesting = manager
        defer { BrowserExtensionManager.overrideForTesting = nil }
        let fixture = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let id = String(repeating: "a", count: 32)
        try Self.installSynchronously(fixture, id: id, into: manager)
        let item = try XCTUnwrap(manager.installedExtension(withID: id))

        let bar = BrowserExtensionToolbar(frame: NSRect(x: 0, y: 0, width: 400, height: 22))
        func submenuItem(_ title: String) throws -> NSMenuItem {
            let entry = try XCTUnwrap(bar.buildMenu().items.first { $0.title.hasPrefix(item.displayName) })
            return try XCTUnwrap(entry.submenu?.items.first { $0.title == title })
        }
        XCTAssertEqual(try submenuItem("Pin to Toolbar").state, .off, "unpinned by default")
        XCTAssertEqual(try submenuItem("Enabled").state, .on)
        manager.setPinned(true, for: item)
        XCTAssertEqual(try submenuItem("Pin to Toolbar").state, .on)

        manager.setEnabled(false, for: item)
        let titles = bar.buildMenu().items.map(\.title)
        XCTAssertTrue(titles.contains("\(item.displayName) (Disabled)"), "\(titles)")
        XCTAssertEqual(try submenuItem("Enabled").state, .off)
    }

    /// The address field has a floor: when more extensions are pinned than fit, the extension bar is what gets
    /// squeezed, not the address field, and an internal constraint must not change the pane's width either.
    @MainActor
    func testAddressFieldKeepsMinimumWidthWhenManyExtensionsPinned() throws {
        let store = try Self.makeStore()
        defer { try? FileManager.default.removeItem(at: store) }
        let manager = BrowserExtensionManager(configuration: .nonPersistent(), storeDirectory: store)
        BrowserExtensionManager.overrideForTesting = manager
        defer { BrowserExtensionManager.overrideForTesting = nil }
        let fixture = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        for letter in ["a", "b", "c", "d", "e", "f"] {
            let id = String(repeating: letter, count: 32)
            try Self.installSynchronously(fixture, id: id, into: manager)
            manager.setPinned(true, for: try XCTUnwrap(manager.installedExtension(withID: id)))
        }

        let previous = BrowserPaneView.settings
        defer { BrowserPaneView.settings = previous }
        BrowserPaneView.settings.home = "about:blank"
        let pane = BrowserPaneView(url: URL(string: "about:blank"))
        let width: CGFloat = 420
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let hosting = NSHostingView(rootView: PaneHostView(pane: pane).frame(width: width, height: 600))
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        defer { window.contentView = nil }

        XCTAssertEqual(pane.frame.width, width, accuracy: 1, "an internal constraint must not turn around and resize the pane")
        let bar = pane.extensionBar
        XCTAssertEqual(bar.actionButtonsForTesting.count, 6, "all six are pinned")
        let field = pane.addressFieldForTesting
        XCTAssertGreaterThanOrEqual(field.frame.width, BrowserPaneView.addressFieldMinimumWidth - 0.5,
                                    "the address field keeps at least 200pt; the extension bar is what gives")
        XCTAssertLessThan(bar.frame.width, bar.intrinsicContentSize.width, "the extension bar is squeezed narrower")
        let hidden = bar.actionButtonsForTesting.filter(\.isHidden).count
        XCTAssertGreaterThan(hidden, 0, "buttons that do not fit are hidden, and stay reachable from the puzzle menu")
        XCTAssertFalse(bar.menuButtonForTesting.isHidden)
        XCTAssertLessThanOrEqual(bar.menuButtonForTesting.frame.maxX, bar.bounds.maxX + 0.01,
                                 "the puzzle never overflows the toolbar")
    }

    /// When the pane is too narrow even for a 200pt address field: the address field keeps giving way and the
    /// puzzle button stays inside the pane where it can be clicked. The floor constraint must not stretch the
    /// pane either, because the SwiftUI hosting this NSView measures its width at priority 500.
    @MainActor
    func testNarrowPaneKeepsPuzzleInsideAndDoesNotResizePane() throws {
        let store = try Self.makeStore()
        defer { try? FileManager.default.removeItem(at: store) }
        let manager = BrowserExtensionManager(configuration: .nonPersistent(), storeDirectory: store)
        BrowserExtensionManager.overrideForTesting = manager
        defer { BrowserExtensionManager.overrideForTesting = nil }
        let fixture = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        for letter in ["a", "b", "c"] {
            let id = String(repeating: letter, count: 32)
            try Self.installSynchronously(fixture, id: id, into: manager)
            manager.setPinned(true, for: try XCTUnwrap(manager.installedExtension(withID: id)))
        }

        let previous = BrowserPaneView.settings
        defer { BrowserPaneView.settings = previous }
        BrowserPaneView.settings.home = "about:blank"
        let pane = BrowserPaneView(url: URL(string: "about:blank"))
        let width: CGFloat = 250
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let hosting = NSHostingView(rootView: PaneHostView(pane: pane).frame(width: width, height: 600))
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        defer { window.contentView = nil }

        XCTAssertEqual(pane.frame.width, width, accuracy: 1, "the floor constraint must not turn around and resize the pane")
        let bar = pane.extensionBar
        let field = pane.addressFieldForTesting
        XCTAssertGreaterThanOrEqual(bar.frame.width, BrowserExtensionToolbar.buttonSize - 0.5,
                                    "the extension bar always keeps room for one puzzle")
        let menu = bar.menuButtonForTesting
        XCTAssertFalse(menu.isHidden)
        let puzzle = bar.convert(menu.frame, to: pane)
        XCTAssertTrue(pane.bounds.contains(puzzle), "the whole puzzle is inside the pane: \(puzzle) vs \(pane.bounds)")
        XCTAssertGreaterThan(field.frame.width, 0)
        XCTAssertLessThan(field.frame.width, BrowserPaneView.addressFieldMinimumWidth,
                          "in a pane this narrow it is the address field that gives way, not the puzzle")
        XCTAssertLessThanOrEqual(field.frame.maxX, bar.frame.minX + 0.5, "the address field is still left of the extension bar")
    }

    /// A reinstall or update from the store page does not overwrite a pin the user turned off by hand (Chrome
    /// does not touch pinned_extensions when it updates an extension either).
    @MainActor
    func testWebStoreReinstallKeepsUserUnpinned() async throws {
        let store = try Self.makeStore()
        defer { try? FileManager.default.removeItem(at: store) }
        let manager = BrowserExtensionManager(configuration: .nonPersistent(), storeDirectory: store)
        let fixture = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let id = String(repeating: "a", count: 32)

        let item = try await manager.install(directory: fixture, id: id, source: .webStore, pinned: true)
        XCTAssertTrue(item.pinned, "a store install pins to the toolbar by default")
        manager.setPinned(false, for: item)

        // The user clicks "Add to QuickTerm" on the store page again, which is the update-in-place path.
        _ = try await manager.install(directory: fixture, id: id, source: .webStore, pinned: true)
        XCTAssertEqual(manager.installed.count, 1)
        let again = manager.installedExtension(withID: id)
        XCTAssertEqual(again?.pinned, false, "the user's decision to unpin is kept")
        XCTAssertEqual(again?.enabled, true)

        // A different id, installed for the first time, is still pinned by default.
        let other = String(repeating: "b", count: 32)
        let fresh = try await manager.install(directory: fixture, id: other, source: .webStore, pinned: true)
        XCTAssertTrue(fresh.pinned)
    }

    // MARK: - Fixtures

    /// Wait for an async operation to land inside a non-async case: turn the main runloop instead of blocking
    /// @MainActor.
    @MainActor
    private static func runUntilDone(_ what: String, timeout: TimeInterval = 5,
                                     _ body: @escaping @MainActor () async -> Void) throws {
        var done = false
        Task { @MainActor in
            await body()
            done = true
        }
        let deadline = Date().addingTimeInterval(timeout)
        while !done, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertTrue(done, "\(what) should finish within \(timeout)s")
    }

    // MARK: - Clicking an extension icon (the user report: "Stylish's icon stops responding after a while")

    /// Clicking an extension icon on the toolbar **does not change the first responder**, while
    /// `tabs.query({active:true,currentWindow:true})` reads the cached `WKWebExtensionContext.focusedWindow`.
    /// Unless that is reported at the moment of the click, the extension's messages go to a tab in some other
    /// pane, possibly on another screen, which looks exactly like "clicking does nothing".
    @MainActor
    func testActionClickMakesClickedPaneCurrentForExtensions() throws {
        let store = try Self.makeStore()
        defer { try? FileManager.default.removeItem(at: store) }
        let manager = BrowserExtensionManager(configuration: .nonPersistent(), storeDirectory: store)
        BrowserExtensionManager.overrideForTesting = manager
        defer { BrowserExtensionManager.overrideForTesting = nil }
        // The Stylish shape: no popup, so clicking the icon only fires action.onClicked.
        let fixture = try Self.makeFixture(popup: false)
        defer { try? FileManager.default.removeItem(at: fixture) }
        try Self.installSynchronously(fixture, id: String(repeating: "a", count: 32), into: manager)
        let item = try XCTUnwrap(manager.installed.first)
        manager.setPinned(true, for: item)

        let previous = BrowserPaneView.settings
        defer { BrowserPaneView.settings = previous }
        BrowserPaneView.settings.home = "about:blank"
        let a = BrowserPaneView(url: URL(string: "about:blank"))
        let b = BrowserPaneView(url: URL(string: "about:blank"))
        manager.controller.didFocusWindow(b)
        XCTAssertTrue(item.context.focusedWindow as? BrowserPaneView === b, "precondition: the current window is b")

        let bar = a.extensionBar
        bar.reload()
        let button = try XCTUnwrap(bar.actionButtonsForTesting.first, "a pinned extension has a toolbar button")
        XCTAssertTrue(button.isEnabled, "the button is always clickable: an NSButton with isEnabled = false swallows the click silently")
        XCTAssertNotNil(item.context.action(for: a.activeTab),
                        "the action is fetched for the current tab, not cached when the button was built")

        // The click has to be dispatched **through the manager**: waking a sleeping MV3 background happens in
        // that step. The old way, calling item.context.performAction(for:) directly, skips it and leaves the
        // icon mute.
        var dispatched: [(id: String, tab: BrowserPaneView.Tab?)] = []
        BrowserExtensionManager.actionDispatchRecorderForTesting = { dispatched.append(($0, $1)) }
        defer { BrowserExtensionManager.actionDispatchRecorderForTesting = nil }

        button.performClick(nil)
        XCTAssertTrue(item.context.focusedWindow as? BrowserPaneView === a,
                      "whoever's toolbar you click becomes the current window in the extension's eyes")
        XCTAssertEqual(dispatched.count, 1, "one click, one dispatch, and it goes through the manager")
        let sent = try XCTUnwrap(dispatched.first)
        XCTAssertEqual(sent.id, item.id)
        XCTAssertTrue(sent.tab === a.activeTab, "it uses the active tab of the pane that was clicked")
    }

    /// Clicking the icon has to wake a sleeping MV3 background, which means the click has to reach
    /// `manager.performAction`, where the wake-up lives; "Open" in the puzzle menu takes the same road. The
    /// old way, calling `context.performAction(for:)` directly, never wakes the background, so
    /// `action.onClicked` never runs and the user sees "clicking does nothing".
    @MainActor
    func testActionClickAndMenuGoThroughManagerSoBackgroundGetsWoken() throws {
        pinUILanguage(.en)
        let store = try Self.makeStore()
        defer { try? FileManager.default.removeItem(at: store) }
        let manager = BrowserExtensionManager(configuration: .nonPersistent(), storeDirectory: store)
        BrowserExtensionManager.overrideForTesting = manager
        defer { BrowserExtensionManager.overrideForTesting = nil }
        // The shape with a background service worker, which is what Stylish is: dispatch has to pass through
        // the wake-up step first.
        let fixture = try Self.makeFixture(popup: false, background: .throwing)
        defer { try? FileManager.default.removeItem(at: fixture) }
        try Self.installSynchronously(fixture, id: String(repeating: "a", count: 32), into: manager)
        let item = try XCTUnwrap(manager.installed.first)
        XCTAssertTrue(item.webExtension.hasBackgroundContent, "it has background content, so dispatch takes the wake-up branch")
        manager.setPinned(true, for: item)

        let previous = BrowserPaneView.settings
        defer { BrowserPaneView.settings = previous }
        BrowserPaneView.settings.home = "about:blank"
        let pane = BrowserPaneView(url: URL(string: "about:blank"))
        let bar = pane.extensionBar
        bar.reload()

        var dispatched: [(id: String, tab: BrowserPaneView.Tab?)] = []
        BrowserExtensionManager.actionDispatchRecorderForTesting = { dispatched.append(($0, $1)) }
        defer { BrowserExtensionManager.actionDispatchRecorderForTesting = nil }

        try XCTUnwrap(bar.actionButtonsForTesting.first).performClick(nil)
        XCTAssertEqual(dispatched.count, 1, "the toolbar button dispatches through the manager, which is where the background gets woken")
        XCTAssertTrue(try XCTUnwrap(dispatched.first).tab === pane.activeTab)

        // "Open" in the puzzle menu is the same as clicking its toolbar button, and it is the only entry point
        // when an extension is unpinned or does not fit, so it has to wake the background too.
        let entry = try XCTUnwrap(bar.buildMenu().items.first { $0.title.hasPrefix(item.displayName) })
        let open = try XCTUnwrap(entry.submenu?.items.first { $0.title == "Open" })
        let selector = try XCTUnwrap(open.action)
        _ = (open.target as? NSObject)?.perform(selector, with: open)
        XCTAssertEqual(dispatched.count, 2, "\"Open\" in the puzzle menu takes the same road")
        let fromMenu = try XCTUnwrap(dispatched.last)
        XCTAssertEqual(fromMenu.id, item.id)
        XCTAssertTrue(fromMenu.tab === pane.activeTab)
    }

    /// An extension action is per tab, with its icon and enabled state following the URL, so the toolbar has
    /// to re-read after a navigation,
    /// or the buttons stay frozen on the previous page's snapshot.
    @MainActor
    func testNavigationReloadsExtensionToolbar() throws {
        let store = try Self.makeStore()
        defer { try? FileManager.default.removeItem(at: store) }
        let manager = BrowserExtensionManager(configuration: .nonPersistent(), storeDirectory: store)
        BrowserExtensionManager.overrideForTesting = manager
        defer { BrowserExtensionManager.overrideForTesting = nil }
        let fixture = try Self.makeFixture(popup: false)
        defer { try? FileManager.default.removeItem(at: fixture) }
        try Self.installSynchronously(fixture, id: String(repeating: "a", count: 32), into: manager)
        manager.setPinned(true, for: try XCTUnwrap(manager.installed.first))

        let previous = BrowserPaneView.settings
        defer { BrowserPaneView.settings = previous }
        BrowserPaneView.settings.home = "about:blank"
        let pane = BrowserPaneView(url: URL(string: "about:blank"))
        let bar = pane.extensionBar
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))   // Let the first about:blank settle
        let before = bar.reloadCountForTesting

        let target = try XCTUnwrap(URL(string: "https://example.test/page"))
        pane.webView.loadHTMLString("<html><body>hi</body></html>", baseURL: target)
        let deadline = Date().addingTimeInterval(5)
        while bar.reloadCountForTesting == before, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertEqual(pane.webView.url, target, "it really did navigate")
        XCTAssertGreaterThan(bar.reloadCountForTesting, before, "after navigating, the toolbar is rebuilt from the new tab state")
    }

    /// When the pane being closed is exactly the "current window" in the extension's eyes, focusedWindow must
    /// not be left empty: an empty one makes every `currentWindow` query miss, and every icon click after that
    /// is mute.
    @MainActor
    func testClosingFocusedBrowserPaneHandsCurrentWindowToSurvivor() throws {
        let store = try Self.makeStore()
        defer { try? FileManager.default.removeItem(at: store) }
        let manager = BrowserExtensionManager(configuration: .nonPersistent(), storeDirectory: store)
        BrowserExtensionManager.overrideForTesting = manager
        defer { BrowserExtensionManager.overrideForTesting = nil }
        let fixture = try Self.makeFixture(popup: false)
        defer { try? FileManager.default.removeItem(at: fixture) }
        try Self.installSynchronously(fixture, id: String(repeating: "a", count: 32), into: manager)
        let item = try XCTUnwrap(manager.installed.first)

        let previous = BrowserPaneView.settings
        defer { BrowserPaneView.settings = previous }
        BrowserPaneView.settings.home = "about:blank"
        let a = BrowserPaneView(url: URL(string: "about:blank"))
        let b = BrowserPaneView(url: URL(string: "about:blank"))
        let host = StubExtensionHost()
        host.panes = [a, b]
        manager.host = host
        a.makeCurrentForExtensions()
        XCTAssertTrue(item.context.focusedWindow as? BrowserPaneView === a)

        a.paneWillClose()
        host.panes = [b]          // The controller drops a afterwards
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertTrue(item.context.focusedWindow as? BrowserPaneView === b,
                      "the current window is handed to a surviving browser pane rather than left empty")
    }

    /// An MV3 background service worker that cannot be woken used to fail in complete silence, and all the user
    /// saw was an icon that did nothing. It has to leave a trace, and the same error is reported only once.
    @MainActor
    func testBackgroundLoadFailureIsSurfacedNotSwallowed() throws {
        let store = try Self.makeStore()
        defer { try? FileManager.default.removeItem(at: store) }
        let manager = BrowserExtensionManager(configuration: .nonPersistent(), storeDirectory: store)
        BrowserExtensionManager.overrideForTesting = manager
        defer { BrowserExtensionManager.overrideForTesting = nil }
        let id = String(repeating: "a", count: 32)
        let fixture = try Self.makeFixture(popup: false, background: .throwing)
        defer { try? FileManager.default.removeItem(at: fixture) }
        try Self.installSynchronously(fixture, id: id, into: manager)
        let item = try XCTUnwrap(manager.installed.first)
        XCTAssertTrue(item.webExtension.hasBackgroundContent, "the fixture really does have background content")

        var recorded: [(String, NSError)] = []
        BrowserExtensionManager.errorRecorderForTesting = { recorded.append(($0, $1)) }
        defer { BrowserExtensionManager.errorRecorderForTesting = nil }

        let previous = BrowserPaneView.settings
        defer { BrowserPaneView.settings = previous }
        BrowserPaneView.settings.home = "about:blank"
        let pane = BrowserPaneView(url: URL(string: "about:blank"))
        manager.performAction(of: item, tab: pane.activeTab)
        let deadline = Date().addingTimeInterval(10)
        while recorded.isEmpty, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertFalse(recorded.isEmpty, "a background load failure has to be recorded (there used to be 302 of them in 12h, all silent)")
        XCTAssertEqual(recorded.first?.0, id)
        let before = recorded.count
        XCTAssertEqual(manager.reportNewErrors(of: item), 0, "the same error is reported only once")
        XCTAssertEqual(recorded.count, before)
    }

    /// Run one async install from a non-async case: start a Task, then turn the main runloop until it lands.
    @MainActor
    private static func installSynchronously(_ directory: URL, id: String,
                                             into manager: BrowserExtensionManager) throws {
        var error: Error?
        var done = false
        Task { @MainActor in
            do { _ = try await manager.install(directory: directory, id: id, source: .local) }
            catch let e { error = e }
            done = true
        }
        let deadline = Date().addingTimeInterval(5)
        while !done, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        if let error { throw error }
        XCTAssertTrue(done, "the install should finish within 5s")
    }

    /// The shape of the background content in the fixture (`.throwing` gives a service worker that always fails to load).
    enum Background { case none, throwing }

    private static func makeStore() throws -> URL {
        let store = FileManager.default.temporaryDirectory
            .appendingPathComponent("qt-extstore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        return store
    }

    /// A minimal MV3 extension: a content script that rewrites example.test's title to EXT-OK, plus an action,
    /// a popup and an options page. `popup: false` builds the Stylish shape, where clicking the icon only
    /// fires action.onClicked.
    /// `background:` attaches an MV3 service worker (the `.throwing` one always fails to load, which is how
    /// error reporting gets exercised).
    private static func makeFixture(popup: Bool = true, background: Background = .none) throws -> URL {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("qt-extfixture-\(UUID().uuidString)",
                                                               isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        var manifest: [String: Any] = [
            "manifest_version": 3,
            "name": "QuickTerm Test Extension",
            "version": "1.0",
            "permissions": ["storage"],
            "host_permissions": ["http://example.test/*"],
            "content_scripts": [[
                "matches": ["http://example.test/*"],
                "js": ["content.js"],
                "run_at": "document_end",
            ]],
            "action": popup ? ["default_title": "QuickTerm Test", "default_popup": "popup.html"]
                            : ["default_title": "QuickTerm Test"],
            "options_page": "options.html",
        ]
        if background == .throwing {
            manifest["background"] = ["service_worker": "sw.js"]
            try "throw new Error('QuickTerm test: background refuses to load');\n"
                .write(to: dir.appendingPathComponent("sw.js"), atomically: true, encoding: .utf8)
        }
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted])
            .write(to: dir.appendingPathComponent("manifest.json"))
        try "document.title = 'EXT-OK';\n".write(to: dir.appendingPathComponent("content.js"),
                                                 atomically: true, encoding: .utf8)
        try "<html><body>popup</body></html>\n".write(to: dir.appendingPathComponent("popup.html"),
                                                      atomically: true, encoding: .utf8)
        try "<html><head><title>OPTIONS-OK</title></head><body>options</body></html>\n"
            .write(to: dir.appendingPathComponent("options.html"), atomically: true, encoding: .utf8)
        return dir
    }
}

/// Test double for the extension manager's host (the real one is MainWindowController).
private final class StubExtensionHost: BrowserExtensionHost {
    var panes: [BrowserPaneView] = []
    var browserPanes: [BrowserPaneView] { panes }
    var focusedBrowserPane: BrowserPaneView? { panes.first }
    @discardableResult func openBrowserWindow(url: URL?) -> BrowserPaneView? { nil }
}
