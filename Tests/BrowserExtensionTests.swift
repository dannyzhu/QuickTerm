import SwiftUI
import WebKit
import XCTest
@testable import QuickTerm

final class BrowserExtensionTests: XCTestCase {
    // MARK: - CRX 头

    /// CRX = 头 + zip：v2 / v3 两种头都要能剥掉；不是 CRX / 头越界返回 nil
    func testCRXZipExtraction() {
        let zip = Data([0x50, 0x4B, 0x03, 0x04, 1, 2, 3, 4])   // "PK\u{3}\u{4}" + 一点内容
        func le32(_ v: UInt32) -> [UInt8] {
            [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]
        }
        // v3：12 字节固定头 + headerLength 字节的 protobuf 头
        let v3Header = [UInt8](repeating: 0xAB, count: 9)
        var crx3 = Array("Cr24".utf8) + le32(3) + le32(UInt32(v3Header.count)) + v3Header
        crx3 += [UInt8](zip)
        XCTAssertEqual(CRX.zipData(from: Data(crx3)), zip, "v3：12 + headerLength")
        // v2：16 字节固定头 + 公钥 + 签名
        let key = [UInt8](repeating: 0x11, count: 5), signature = [UInt8](repeating: 0x22, count: 7)
        var crx2 = Array("Cr24".utf8) + le32(2) + le32(UInt32(key.count)) + le32(UInt32(signature.count))
        crx2 += key + signature + [UInt8](zip)
        XCTAssertEqual(CRX.zipData(from: Data(crx2)), zip, "v2：16 + 公钥 + 签名")
        // 坏输入
        XCTAssertNil(CRX.zipData(from: Data(Array("PK\u{3}\u{4}".utf8) + [UInt8](repeating: 0, count: 20))), "魔数不对")
        XCTAssertNil(CRX.zipData(from: Data(Array("Cr24".utf8) + le32(3) + le32(9))), "头声明的长度超出数据")
        XCTAssertNil(CRX.zipData(from: Data(Array("Cr24".utf8) + le32(9) + le32(0) + le32(0))), "未知版本")
        XCTAssertNil(CRX.zipData(from: Data([0x43, 0x72])), "太短")
    }

    // MARK: - Web Store URL

    func testWebStoreURLParsing() {
        let id = "abcdefghijklmnopabcdefghijklmnop"
        func parse(_ s: String) -> String? {
            BrowserExtensionManager.extensionID(fromWebStoreURL: URL(string: s)!)
        }
        XCTAssertEqual(parse("https://chromewebstore.google.com/detail/some-slug/\(id)"), id)
        XCTAssertEqual(parse("https://chrome.google.com/webstore/detail/some-slug/\(id)?hl=zh"), id, "旧域名 + query")
        XCTAssertEqual(parse("https://chromewebstore.google.com/detail/some-slug/\(id)/reviews"), id, "详情页子路径")
        XCTAssertNil(parse("https://chromewebstore.google.com/category/extensions"), "非详情页")
        XCTAssertNil(parse("https://chromewebstore.google.com/detail/slug/tooshort"), "id 长度不对")
        XCTAssertNil(parse("https://example.com/detail/slug/\(id)"), "非 Web Store 域名")
        XCTAssertTrue(BrowserExtensionManager.webStoreDownloadURL(id: id).absoluteString.contains("id%3D\(id)"))
    }

    // MARK: - 从 Chrome 导入的扫描

    /// 每个扩展取版本号最大的目录；主题 / 打包应用 / 没有 name 的跳过
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
        // Chrome 真实的目录名是 `<version>_<installCount>`
        try write(normal, "1.15.4_1", ["name": "Old", "version": "1.15.4", "manifest_version": 3])
        try write(normal, "1.15.5_0", ["name": "New", "version": "1.15.5", "manifest_version": 3])
        try write(theme, "1.0_0", ["name": "Theme", "theme": ["colors": [:]]])
        try write(nameless, "1.0_0", ["manifest_version": 3])
        let candidates = BrowserExtensionManager.chromeCandidates(inExtensions: root)
        XCTAssertEqual(candidates.count, 1, "只有一个可导入")
        XCTAssertEqual(candidates.first?.id, normal)
        XCTAssertEqual(candidates.first?.directory.lastPathComponent, "1.15.5_0", "取最高版本目录")
        XCTAssertTrue(BrowserExtensionManager.compareVersions("1.9.0", "1.10.0"), "按数字段比较，不是字典序")
        XCTAssertFalse(BrowserExtensionManager.compareVersions("2.0", "1.99"))
        // `_N` 后缀不能参与版本比较（Int("4_1") 是 nil，会把最后一段当成 0 → 两者比成相等）
        XCTAssertTrue(BrowserExtensionManager.compareVersions("1.15.4_1", "1.15.5_0"))
        XCTAssertFalse(BrowserExtensionManager.compareVersions("1.15.5_0", "1.15.4_1"))
        XCTAssertTrue(BrowserExtensionManager.compareVersions("1.0.0.6_1", "1.0.0.7_0"))
        XCTAssertTrue(BrowserExtensionManager.compareVersions("2.8.28_0", "2.9_0"))
        XCTAssertTrue(BrowserExtensionManager.compareVersions("1.0_0", "1.0_1"), "同版本按安装计数")
    }

    // MARK: - Web Store 安装通道的来源校验

    /// 「添加到 QuickTerm」的回传消息只认 Web Store 详情页的**主框架**，且 id 要与该详情页一致：
    /// 否则任意页面 / iframe 都能凭一条 postMessage 拉起原生安装弹窗（标题还是它自己挑的扩展名）
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
        XCTAssertEqual(accepted(), id, "商店详情页主框架 + id 一致")
        XCTAssertNil(accepted(isMainFrame: false), "子框架（第三方 iframe）")
        XCTAssertNil(accepted(frameURL: URL(string: "https://evil.example/detail/x/\(id)")!), "非商店域名")
        XCTAssertNil(accepted(frameURL: URL(string: "https://chromewebstore.google.com/category/extensions")!),
                     "不是详情页")
        XCTAssertNil(accepted(body: ["id": other]), "id 与详情页对不上")
        XCTAssertNil(accepted(originHost: "evil.example"), "脚本来源不是商店")
        XCTAssertNil(accepted(body: ["id": 42]), "body 形状不对")
        XCTAssertNil(accepted(body: "abcdefghijklmnopabcdefghijklmnop"))
    }

    // MARK: - Web Store 注入按钮（端到端）

    /// 商店详情页上，注入的「添加到 QuickTerm」要挨着商店自己（灰掉的）「添加至 Chrome」按钮；
    /// 点击后经私有 content world 的通道把 id 送到原生侧；不在详情页时按钮隐藏
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
        // 商店按钮由 JS 晚些渲染：先给空壳，再补上，检验 MutationObserver 的挪位
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
        XCTAssertEqual(neighbour, "添加至 Chrome", "注入按钮应挨在商店按钮后面")
        XCTAssertEqual(try eval("document.getElementById('quickterm-install-button').style.position") as? String, "static",
                       "挪到行内后不再是右下角浮动")
        _ = try eval("document.getElementById('quickterm-install-button').click(); 0")
        let clickDeadline = Date().addingTimeInterval(3)
        while Date() < clickDeadline, recorder.received.isEmpty { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        XCTAssertEqual((recorder.received.first as? [String: Any])?["id"] as? String, id, "点击后送出详情页的 id")
        // 站内跳到非详情页：按钮隐藏
        _ = try eval("history.pushState({}, '', '/category/extensions'); window.dispatchEvent(new Event('popstate')); 0")
        XCTAssertEqual(try eval("document.getElementById('quickterm-install-button').hidden") as? Bool, true)
    }

    // MARK: - 管理器：安装 / 启停 / 移除

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
        XCTAssertEqual(item.context.uniqueIdentifier, id, "context 标识 = 扩展 id（页面 origin 稳定）")
        XCTAssertTrue(item.context.isLoaded)
        XCTAssertEqual(manager.controller.extensionContexts.count, 1)
        XCTAssertTrue(item.hasOptionsPage)
        XCTAssertEqual(item.displayName, "QuickTerm Test Extension")
        // manifest 里请求的权限 / 主机在安装时全部授予（过期时间 = distant future，不是"当场过期"）
        XCTAssertTrue(item.context.hasPermission(.storage))
        XCTAssertTrue(item.context.hasAccess(to: URL(string: "http://example.test/page")!))
        XCTAssertNotNil(item.context.action(for: nil), "manifest 有 action → 有动作")

        manager.setEnabled(false, for: item)
        XCTAssertFalse(item.context.isLoaded, "停用 = 从 controller 卸载")
        XCTAssertTrue(manager.controller.extensionContexts.isEmpty)

        // 记录落盘：另一个 manager 从同一个 store 目录重新加载，启停位保持
        let reloaded = BrowserExtensionManager(configuration: .nonPersistent(), storeDirectory: store)
        await reloaded.loadInstalled()
        XCTAssertEqual(reloaded.installed.count, 1)
        XCTAssertFalse(reloaded.installed[0].enabled, "停用状态持久化")
        XCTAssertFalse(reloaded.installed[0].context.isLoaded)

        manager.setEnabled(true, for: item)
        XCTAssertTrue(item.context.isLoaded, "重新启用")
        // 全局开关关掉 = 全部卸载
        manager.isEnabled = false
        XCTAssertFalse(item.context.isLoaded)
        manager.isEnabled = true
        XCTAssertTrue(item.context.isLoaded)

        manager.remove(item)
        XCTAssertTrue(manager.installed.isEmpty)
        XCTAssertTrue(manager.controller.extensionContexts.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.appendingPathComponent(id).path),
                       "移除同时删掉扩展目录")
    }

    // MARK: - 标签 / 窗口协议

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
                      "点扩展按钮算用户手势（activeTab 语义）")

        let activated = expectation(description: "activate")
        pane.tabs[0].activate(for: context) { _ in activated.fulfill() }
        await fulfillment(of: [activated], timeout: 2)
        XCTAssertEqual(pane.activeTabIndex, 0, "扩展 tabs.update({active:true}) 切换当前标签")

        let removed = pane.tabs[1]
        let closed = expectation(description: "close")
        pane.tabs[1].close(for: context) { _ in closed.fulfill() }
        await fulfillment(of: [closed], timeout: 2)
        XCTAssertEqual(pane.tabs.count, 1, "扩展 tabs.remove 关掉标签")
        XCTAssertNil(removed.window(for: context), "关掉的标签不再属于任何窗口")
        XCTAssertEqual(removed.indexInWindow(for: context), NSNotFound, "头文件要求：不在窗口里返回 NSNotFound")

        // 已经脱离 pane 的标签再关 → 报错，不能谎报成功
        let orphan = expectation(description: "orphan")
        removed.close(for: context) { error in
            XCTAssertNotNil(error, "标签已关闭应回错")
            orphan.fulfill()
        }
        await fulfillment(of: [orphan], timeout: 2)

        // 最后一个标签：closeTab 会被守卫挡掉，要转成"关整个 pane"的请求（pane 未挂窗口 → 先记下）
        let last = expectation(description: "last")
        pane.tabs[0].close(for: context) { error in
            XCTAssertNil(error)
            last.fulfill()
        }
        await fulfillment(of: [last], timeout: 2)
        XCTAssertEqual(pane.tabs.count, 1, "最后一个标签不在标签层关")
        XCTAssertTrue(pane.pendingCloseRequest, "转成关 pane 的请求，不是静默的空操作")

        // windows.remove 同理：非活动工作区的 pane（controller 为 nil）也要留下待关请求
        let other = BrowserPaneView(url: URL(string: "about:blank"))
        let windowClosed = expectation(description: "window close")
        other.close(for: context) { error in
            XCTAssertNil(error)
            windowClosed.fulfill()
        }
        await fulfillment(of: [windowClosed], timeout: 2)
        XCTAssertTrue(other.pendingCloseRequest)
    }

    // MARK: - 关标签时上报给扩展的事件

    /// 关标签要先上报 didCloseTab（那一刻 WebKit 会回调 window(for:) 去算 tabs.onRemoved 的 windowId，
    /// 标签必须还挂在 pane 上），随后接班的标签要带 previous = nil 被上报激活
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
        XCTAssertTrue(pane.closeTab(at: 1), "关掉当前标签（中间那个）")
        XCTAssertEqual(events.map(\.kind), ["close", "activate"], "先 close 后 activate")
        XCTAssertEqual(events[0].tab, closed.id)
        XCTAssertTrue(events[0].windowAttached, "上报 didCloseTab 时标签还在 pane 上（windowId 才不是 -1）")
        XCTAssertEqual(events[1].tab, successor.id, "接班的标签被上报激活")
        XCTAssertNil(events[1].previous, "被关掉的标签不能当 previousTabId")
        XCTAssertTrue(pane.activeTab === successor)

        // 关非当前标签：当前标签没变，不该有任何激活 / 取消选中事件
        events.removeAll()
        XCTAssertTrue(pane.closeTab(at: 0))
        XCTAssertEqual(events.map(\.kind), ["close"])
        XCTAssertTrue(pane.activeTab === successor)
    }

    // MARK: - 内容脚本（端到端）

    /// 挂了 controller 的 WebView 上，扩展的内容脚本应真的注入（改写页面标题）。
    /// 非 async 用例：WebKit 的加载要靠主 runloop 推进，async 测试体里 `RunLoop.run(until:)` 推不动它
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
                       "内容脚本应把标题改成 EXT-OK；实际 title=\(webView.title ?? "nil") "
                       + "url=\(webView.url?.absoluteString ?? "nil") loading=\(webView.isLoading)")
    }

    /// 装 / 卸 / 启停扩展后各标签会 `removeAllUserScripts()` 再重挂我们自己的注入脚本
    /// （externally_connectable 垫片的地址清单会变）。WebKit 给扩展内容脚本用的是它自己的通道，
    /// 不在这个 userContentController 里——清空之后内容脚本必须照常注入，否则已开着的标签
    /// 从此再也跑不了任何扩展的内容脚本
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
        loadAndWaitForContentScript("基线：内容脚本注入")
        // 模拟扩展集合变化后的重挂
        configuration.userContentController.removeAllUserScripts()
        loadAndWaitForContentScript("removeAllUserScripts 之后内容脚本仍应注入")
    }

    // MARK: - 扩展自己的页面（选项页）

    /// `webkit-extension://` 的主帧只能在 `context.webViewConfiguration` 建的 WebView 里加载：
    /// 用普通配置（makeConfiguration）的话 WebKit 直接回 NSURLErrorResourceUnavailable，
    /// 页面变成 QuickTerm 的错误页，而扩展那边收到的却是"打开成功"
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
                       "baseURL 与扩展 id 对齐，扩展页面的 origin 才跨重启稳定")
        let tab = pane.addTab(url: options, activate: true)
        XCTAssertNotNil(tab.extensionContext, "标签用的是扩展专用配置")
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, tab.webView.title != "OPTIONS-OK" {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        // 错误页也是用失败网址 loadSimulatedRequest 出来的（webView.url 一样），所以要看标题 / 错误页标记
        XCTAssertEqual(tab.webView.title, "OPTIONS-OK",
                       "选项页应真的加载；实际 title=\(tab.webView.title ?? "nil") "
                       + "url=\(tab.webView.url?.absoluteString ?? "nil")")
        XCTAssertFalse(tab.showingErrorPage)
        XCTAssertEqual(tab.webView.url, options)
    }

    // MARK: - 工具条

    /// 扩展工具条是手工布局：pane 宽度不能被它撑走（SwiftUI 托管的 pane 没有外部宽度约束）
    @MainActor
    func testExtensionBarDoesNotResizePane() throws {
        // 工具条读的是"当前"管理器：显式指向一个空的临时管理器，别看用户真装了什么
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
        // 没有扩展时只剩拼图按钮
        XCTAssertTrue(bar.actionButtonsForTesting.isEmpty)
        XCTAssertEqual(bar.intrinsicContentSize.width, BrowserExtensionToolbar.step, accuracy: 0.01)
        bar.layoutSubtreeIfNeeded()
        XCTAssertEqual(bar.menuButtonForTesting.frame.width, BrowserExtensionToolbar.buttonSize, accuracy: 0.01)
        // 地址栏在扩展条左边，两者都在工具条内
        let field = pane.addressFieldForTesting
        XCTAssertLessThanOrEqual(field.frame.maxX, bar.frame.minX + 0.5, "扩展条在地址栏右侧")
        XCTAssertGreaterThan(field.frame.width, 100, "地址栏仍占据剩余空间")
        window.contentView = nil
    }

    /// 拼图菜单：没装扩展时只有导入 / 商店 / 文件夹三项 + 提示
    @MainActor
    func testExtensionMenuCommands() throws {
        let previous = BrowserPaneView.settings
        defer { BrowserPaneView.settings = previous }
        BrowserPaneView.settings.home = "about:blank"
        let pane = BrowserPaneView(url: URL(string: "about:blank"))
        let titles = pane.extensionBar.buildMenu().items.map(\.title)
        XCTAssertTrue(titles.contains("从 Chrome 导入已安装扩展…"), "\(titles)")
        XCTAssertTrue(titles.contains("打开 Chrome Web Store"))
        XCTAssertTrue(titles.contains("打开扩展文件夹"))
    }

    // MARK: - 固定到工具条

    /// 旧 state.json（1.5.2 及更早，没有 pinned 键）解码出来 = 不固定；setPinned 之后往返存盘
    @MainActor
    func testPinnedFlagDefaultsFalseForLegacyStateAndRoundTrips() throws {
        let store = try Self.makeStore()
        defer { try? FileManager.default.removeItem(at: store) }
        let fixture = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let id = "abcdefghijklmnopabcdefghijklmnop"
        try FileManager.default.copyItem(at: fixture, to: store.appendingPathComponent(id, isDirectory: true))
        // 老格式：只有 enabled，没有 pinned
        try """
        [{"enabled": true, "id": "\(id)", "installedAt": "2026-01-01T00:00:00Z", "source": "chrome"}]
        """.write(to: store.appendingPathComponent("state.json"), atomically: true, encoding: .utf8)

        let manager = BrowserExtensionManager(configuration: .nonPersistent(), storeDirectory: store)
        try Self.runUntilDone("加载已装扩展") { await manager.loadInstalled() }
        let item = try XCTUnwrap(manager.installedExtension(withID: id))
        // source / installedAt 只有"旧记录真的解出来了"才对得上：解码失败时 loadInstalled() 会合成一条
        // .local + 当下时间的兜底记录，那条同样是 enabled=true / pinned=false，光看这两位测不出回归
        XCTAssertEqual(item.record.source, .chrome, "记录来自旧 state.json，不是缺记录时合成的兜底值")
        XCTAssertEqual(item.record.installedAt,
                       try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-01-01T00:00:00Z")))
        XCTAssertTrue(item.enabled)
        XCTAssertFalse(item.pinned, "缺 pinned 键 = 不固定")

        manager.setPinned(true, for: item)
        XCTAssertTrue(item.pinned)
        let reloaded = BrowserExtensionManager(configuration: .nonPersistent(), storeDirectory: store)
        try Self.runUntilDone("重新加载") { await reloaded.loadInstalled() }
        XCTAssertTrue(try XCTUnwrap(reloaded.installedExtension(withID: id)).pinned, "固定状态持久化")
    }

    /// Chrome 的 `<profile>/Preferences` 里 extensions.pinned_extensions = 导入后同样固定的那批
    func testChromePinnedExtensionIDs() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("qt-chromeprefs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let preferences = dir.appendingPathComponent("Preferences")
        XCTAssertTrue(BrowserExtensionManager.chromePinnedExtensionIDs(preferences: preferences).isEmpty,
                      "文件不存在 = 一个都不固定")

        let a = String(repeating: "a", count: 32), b = String(repeating: "b", count: 32)
        try #"{"extensions": {"pinned_extensions": ["\#(a)", "\#(b)"]}, "profile": {"name": "x"}}"#
            .write(to: preferences, atomically: true, encoding: .utf8)
        XCTAssertEqual(BrowserExtensionManager.chromePinnedExtensionIDs(preferences: preferences), [a, b])

        try "not json at all".write(to: preferences, atomically: true, encoding: .utf8)
        XCTAssertTrue(BrowserExtensionManager.chromePinnedExtensionIDs(preferences: preferences).isEmpty,
                      "解析失败 = 一个都不固定，不是错误")
    }

    /// 工具条只显示固定的扩展；固定得放不下时从左到右摆，放不下的藏起来（拼图永远在最右）
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
        XCTAssertTrue(bar.actionButtonsForTesting.isEmpty, "两个都没固定 → 工具条上没有按钮")

        manager.setPinned(true, for: one)
        bar.reload()
        XCTAssertEqual(bar.actionButtonsForTesting.count, 1, "只有固定的那个上工具条")

        manager.setPinned(false, for: one)
        bar.reload()
        XCTAssertTrue(bar.actionButtonsForTesting.isEmpty, "取消固定 → 回到拼图菜单里")

        manager.setPinned(true, for: one)
        manager.setPinned(true, for: two)
        bar.reload()
        XCTAssertEqual(bar.actionButtonsForTesting.count, 2)
        XCTAssertEqual(bar.intrinsicContentSize.width, 3 * BrowserExtensionToolbar.step, accuracy: 0.01)
        // 压到只够一个按钮 + 拼图
        bar.frame = NSRect(x: 0, y: 0, width: BrowserExtensionToolbar.step + BrowserExtensionToolbar.buttonSize,
                           height: 22)
        bar.needsLayout = true
        bar.layoutSubtreeIfNeeded()
        XCTAssertFalse(bar.actionButtonsForTesting[0].isHidden, "第一个还摆得下")
        XCTAssertTrue(bar.actionButtonsForTesting[1].isHidden, "第二个放不下 → 藏起来（仍在拼图菜单里）")
        let menu = bar.menuButtonForTesting
        XCTAssertFalse(menu.isHidden)
        XCTAssertEqual(menu.frame.maxX, bar.bounds.maxX, accuracy: 0.01, "拼图永远在最右")
        XCTAssertGreaterThanOrEqual(menu.frame.minX, bar.actionButtonsForTesting[0].frame.maxX - 0.01)

        // 宽度不是整格时（46 是"刚好一格 + 拼图"的特例）拼图同样贴住右边缘，不留一截空隙
        bar.frame = NSRect(x: 0, y: 0, width: 60, height: 22)
        bar.needsLayout = true
        bar.layoutSubtreeIfNeeded()
        XCTAssertFalse(bar.actionButtonsForTesting[0].isHidden)
        XCTAssertTrue(bar.actionButtonsForTesting[1].isHidden)
        XCTAssertEqual(menu.frame.maxX, bar.bounds.maxX, accuracy: 0.01, "有按钮被藏起来 → 拼图贴右边缘")
        XCTAssertLessThanOrEqual(bar.actionButtonsForTesting[0].frame.maxX, menu.frame.minX + 0.01,
                                 "拼图不压在按钮上")

        // 全放得下时保持老行为：按钮右边紧跟拼图
        bar.frame = NSRect(x: 0, y: 0, width: 400, height: 22)
        bar.needsLayout = true
        bar.layoutSubtreeIfNeeded()
        XCTAssertEqual(menu.frame.minX, 2 * BrowserExtensionToolbar.step, accuracy: 0.01)
    }

    /// 拼图菜单：每个扩展一行，子菜单里「固定到工具条」的勾选跟着记录走；停用的加后缀
    @MainActor
    func testExtensionMenuPinItem() throws {
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
        XCTAssertEqual(try submenuItem("固定到工具条").state, .off, "默认不固定")
        XCTAssertEqual(try submenuItem("启用").state, .on)
        manager.setPinned(true, for: item)
        XCTAssertEqual(try submenuItem("固定到工具条").state, .on)

        manager.setEnabled(false, for: item)
        let titles = bar.buildMenu().items.map(\.title)
        XCTAssertTrue(titles.contains("\(item.displayName)（已停用）"), "\(titles)")
        XCTAssertEqual(try submenuItem("启用").state, .off)
    }

    /// 地址栏保底：固定的扩展多到摆不下时，压的是扩展条，不是地址栏；pane 宽度也不能被内部约束改掉
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

        XCTAssertEqual(pane.frame.width, width, accuracy: 1, "内部约束不能反过来改 pane 宽度")
        let bar = pane.extensionBar
        XCTAssertEqual(bar.actionButtonsForTesting.count, 6, "六个都固定了")
        let field = pane.addressFieldForTesting
        XCTAssertGreaterThanOrEqual(field.frame.width, BrowserPaneView.addressFieldMinimumWidth - 0.5,
                                    "地址栏至少 200pt，被压的是扩展条")
        XCTAssertLessThan(bar.frame.width, bar.intrinsicContentSize.width, "扩展条被压窄")
        let hidden = bar.actionButtonsForTesting.filter(\.isHidden).count
        XCTAssertGreaterThan(hidden, 0, "放不下的按钮藏起来（仍可从拼图菜单点开）")
        XCTAssertFalse(bar.menuButtonForTesting.isHidden)
        XCTAssertLessThanOrEqual(bar.menuButtonForTesting.frame.maxX, bar.bounds.maxX + 0.01,
                                 "拼图不会溢出工具条")
    }

    /// pane 窄到连 200pt 地址栏都放不下时：让地址栏继续让，拼图按钮仍在 pane 里（点得到）；
    /// 而且保底约束不能反过来把 pane 撑宽——托管这块 NSView 的 SwiftUI 是按 500 的优先级量宽的
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

        XCTAssertEqual(pane.frame.width, width, accuracy: 1, "保底约束不能反过来改 pane 宽度")
        let bar = pane.extensionBar
        let field = pane.addressFieldForTesting
        XCTAssertGreaterThanOrEqual(bar.frame.width, BrowserExtensionToolbar.buttonSize - 0.5,
                                    "扩展条至少留得下一颗拼图")
        let menu = bar.menuButtonForTesting
        XCTAssertFalse(menu.isHidden)
        let puzzle = bar.convert(menu.frame, to: pane)
        XCTAssertTrue(pane.bounds.contains(puzzle), "拼图整颗都在 pane 里：\(puzzle) vs \(pane.bounds)")
        XCTAssertGreaterThan(field.frame.width, 0)
        XCTAssertLessThan(field.frame.width, BrowserPaneView.addressFieldMinimumWidth,
                          "这么窄的 pane 里让步的是地址栏，不是拼图")
        XCTAssertLessThanOrEqual(field.frame.maxX, bar.frame.minX + 0.5, "地址栏仍在扩展条左边")
    }

    /// 商店页重装 / 更新不覆盖用户手动取消过的固定状态（Chrome 更新扩展也不动 pinned_extensions）
    @MainActor
    func testWebStoreReinstallKeepsUserUnpinned() async throws {
        let store = try Self.makeStore()
        defer { try? FileManager.default.removeItem(at: store) }
        let manager = BrowserExtensionManager(configuration: .nonPersistent(), storeDirectory: store)
        let fixture = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let id = String(repeating: "a", count: 32)

        let item = try await manager.install(directory: fixture, id: id, source: .webStore, pinned: true)
        XCTAssertTrue(item.pinned, "商店安装默认固定到工具条")
        manager.setPinned(false, for: item)

        // 用户又点了一次商店页的「添加到 QuickTerm」（= 更新同路径）
        _ = try await manager.install(directory: fixture, id: id, source: .webStore, pinned: true)
        XCTAssertEqual(manager.installed.count, 1)
        let again = manager.installedExtension(withID: id)
        XCTAssertEqual(again?.pinned, false, "沿用用户取消固定的选择")
        XCTAssertEqual(again?.enabled, true)

        // 换个 id 首次安装仍然默认固定
        let other = String(repeating: "b", count: 32)
        let fresh = try await manager.install(directory: fixture, id: other, source: .webStore, pinned: true)
        XCTAssertTrue(fresh.pinned)
    }

    // MARK: - 夹具

    /// 非 async 用例里等一个异步操作落地（转主 runloop，别阻塞 @MainActor）
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
        XCTAssertTrue(done, "\(what)应在 \(timeout)s 内完成")
    }

    /// 非 async 用例里跑一次异步安装：起 Task 后转主 runloop 等它落地
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
        XCTAssertTrue(done, "安装应在 5s 内完成")
    }

    private static func makeStore() throws -> URL {
        let store = FileManager.default.temporaryDirectory
            .appendingPathComponent("qt-extstore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        return store
    }

    /// 最小 MV3 扩展：内容脚本把 example.test 的标题改成 EXT-OK，另有 action + popup + 选项页
    private static func makeFixture() throws -> URL {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("qt-extfixture-\(UUID().uuidString)",
                                                               isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let manifest: [String: Any] = [
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
            "action": ["default_title": "QuickTerm Test", "default_popup": "popup.html"],
            "options_page": "options.html",
        ]
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
