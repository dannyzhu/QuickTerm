import XCTest
@testable import QuickTerm

final class BrowserPaneTests: XCTestCase {
    func testAddressInputResolution() {
        let s = BrowserPaneView.Settings()
        XCTAssertEqual(s.url(forInput: "https://a.b/c?d=1")?.absoluteString, "https://a.b/c?d=1", "完整 URL 原样")
        XCTAssertEqual(s.url(forInput: "http://localhost:8080/x")?.absoluteString, "http://localhost:8080/x")
        XCTAssertEqual(s.url(forInput: "example.com")?.absoluteString, "https://example.com", "像域名 → 补 https")
        XCTAssertEqual(s.url(forInput: "localhost:3000")?.absoluteString, "https://localhost:3000")
        XCTAssertEqual(s.url(forInput: "about:blank")?.absoluteString, "about:blank")
        XCTAssertEqual(s.url(forInput: "hello world")?.absoluteString, "https://www.google.com/search?q=hello%20world", "非网址 → 搜索")
        XCTAssertEqual(s.url(forInput: "swift")?.absoluteString, "https://www.google.com/search?q=swift", "单词无点 → 搜索")
        XCTAssertNil(s.url(forInput: "   "))
    }

    func testUserAgentModes() {
        var s = BrowserPaneView.Settings()
        XCTAssertEqual(s.effectiveUserAgent, BrowserPaneView.Settings.safariUserAgent, "默认伪装 Safari")
        s.userAgent = "webkit"
        XCTAssertNil(s.effectiveUserAgent, "webkit = 不伪装")
        s.userAgent = "MyAgent/1.0"
        XCTAssertEqual(s.effectiveUserAgent, "MyAgent/1.0")
        XCTAssertTrue(BrowserPaneView.Settings.safariUserAgent.contains("Safari/"), "Google 按 UA 判定嵌入式浏览器")
    }

    func testHomeFallback() {
        var s = BrowserPaneView.Settings()
        s.home = "not a url"
        XCTAssertEqual(s.homeURL.host, "www.google.com")
    }

    /// 悬停即焦点靠容器自己的 tracking area（owner = pane，含 .mouseMoved）：WKWebView 的 mouseMoved
    /// 覆写收不到事件（其 tracking area 由内部观察者持有）
    @MainActor
    func testBrowserPaneInstallsHoverTrackingArea() {
        let pane = BrowserPaneView(url: nil)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        pane.frame = window.contentView!.bounds
        window.contentView?.addSubview(pane)
        pane.updateTrackingAreas()
        let area = pane.trackingAreas.first { $0.owner === pane }
        XCTAssertNotNil(area, "容器必须有自己的 tracking area")
        XCTAssertTrue(area?.options.contains(.mouseMoved) ?? false)
        XCTAssertTrue(area?.options.contains(.activeAlways) ?? false)
        XCTAssertTrue(pane.installsHoverTracking)
        XCTAssertFalse(Ghostty.SurfaceView.self == type(of: pane), "终端 pane 自己管 tracking area")
        pane.removeFromSuperview()
    }

    /// 完整事件链：点击地址栏 → 输入 baidu.com → 回车 → 请求 https://baidu.com
    @MainActor
    func testTypingInAddressBarNavigates() throws {
        let c = try XCTUnwrap((NSApp.delegate as? AppDelegate)?.controller)
        let home = c.model.activeIndex
        c.model.switchTo(c.model.layouts.count - 1)
        let prev = BrowserPaneView.settings
        BrowserPaneView.settings.home = "about:blank"
        c.perform(.newBrowser)
        let b = try XCTUnwrap(c.paneList.first { $0 is BrowserPaneView } as? BrowserPaneView)
        defer {
            // 显式收尾并等 SwiftUI 重挂原工作区：紧随其后的 EngineSmokeTests 同步检查视图链
            c.closePane(b, confirmIfNeeded: false, animated: false)
            BrowserPaneView.settings = prev
            c.model.switchTo(home)
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        let window = try XCTUnwrap(c.window)
        let field = b.addressField
        let center = field.convert(NSPoint(x: field.bounds.midX, y: field.bounds.midY), to: nil)
        func mouse(_ type: NSEvent.EventType) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: center, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        }
        // NSCell 的鼠标跟踪会循环取 nextEvent 直到 mouseUp：先把 mouseUp 排进队列再发 mouseDown，否则卡死
        NSApp.postEvent(mouse(.leftMouseUp), atStart: false)
        NSApp.sendEvent(mouse(.leftMouseDown))
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertNotNil(field.currentEditor(), "点击后地址栏应进入编辑；FR=\(String(describing: window.firstResponder))")
        XCTAssertTrue(b.focused, "编辑地址栏时 pane 持焦")
        // 首次点击默认全选：⌘C 直接复制、直接输入即替换
        XCTAssertEqual(field.currentEditor()?.selectedRange, NSRange(location: 0, length: field.stringValue.count),
                       "点击地址栏应全选")
        field.currentEditor()?.insertText("baidu.com")   // 直接输入替换全选内容
        let ret = NSEvent.keyEvent(with: .keyDown, location: center, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                   windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
                                   isARepeat: false, keyCode: 36)!
        NSApp.sendEvent(ret)
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        // 站点可能立即跳转（baidu.com → www.baidu.com），只断言主机
        XCTAssertTrue(b.lastRequestedURL?.host?.hasSuffix("baidu.com") ?? false, "回车后应请求 baidu，实际 \(String(describing: b.lastRequestedURL))")
        XCTAssertTrue(window.firstResponder === b.webView, "回车后焦点回到页面")
    }

    @MainActor
    func testBrowserPaneEncodesKindAndURL() throws {
        let pane = BrowserPaneView(url: URL(string: "about:blank"))
        let data = try JSONEncoder().encode(PaneBox(pane: pane))
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(json.contains("\"kind\":\"browser\""), json)
        XCTAssertTrue(json.contains("about:blank"), json)
        let decoded = try JSONDecoder().decode(PaneBox.self, from: data).pane
        XCTAssertTrue(decoded is BrowserPaneView)
        XCTAssertEqual(decoded.id, pane.id)
    }
}

/// 测试用：经 PaneCodable 往返一个 pane
private struct PaneBox: Codable {
    let pane: PaneView
    init(pane: PaneView) { self.pane = pane }
    private enum Keys: String, CodingKey { case pane }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        pane = try PaneView.decodePane(from: c.superDecoder(forKey: .pane))
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try pane.encodePane(to: c.superEncoder(forKey: .pane))
    }
}
