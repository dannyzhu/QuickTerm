import XCTest
import SwiftUI
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

    /// 多标签：新建激活、相对切换回绕、关闭后选邻居、最后一个标签不在 pane 内关；标签条 auto/always
    @MainActor
    func testTabsLifecycle() throws {
        let prev = BrowserPaneView.settings
        defer { BrowserPaneView.settings = prev }
        BrowserPaneView.settings.home = "about:blank"
        BrowserPaneView.settings.tabBar = "auto"
        let pane = BrowserPaneView(url: URL(string: "about:blank"))
        XCTAssertEqual(pane.tabs.count, 1)
        XCTAssertFalse(pane.tabBarVisible, "单标签 auto 隐藏")
        pane.newTab()
        pane.newTab()
        XCTAssertEqual(pane.tabs.count, 3)
        XCTAssertEqual(pane.activeTabIndex, 2, "新标签激活")
        XCTAssertTrue(pane.tabBarVisible)
        XCTAssertTrue(pane.focusTarget === pane.tabs[2].webView, "焦点目标 = 当前标签")
        XCTAssertTrue(pane.tabs[0].webView.isHidden && !pane.tabs[2].webView.isHidden)
        pane.selectTab(offset: 1)
        XCTAssertEqual(pane.activeTabIndex, 0, "首尾回绕")
        pane.selectTab(offset: -1)
        XCTAssertEqual(pane.activeTabIndex, 2)
        pane.selectTab(at: 1)
        XCTAssertTrue(pane.closeActiveTab())
        XCTAssertEqual(pane.tabs.count, 2)
        XCTAssertEqual(pane.activeTabIndex, 1, "关掉中间标签后选后面那个")
        XCTAssertTrue(pane.closeActiveTab())
        XCTAssertEqual(pane.activeTabIndex, 0, "关掉末尾标签后选前一个")
        XCTAssertFalse(pane.closeActiveTab(), "最后一个标签不在 pane 内关")
        XCTAssertEqual(pane.tabs.count, 1)
        BrowserPaneView.settings.tabBar = "always"
        pane.applySettings()
        XCTAssertTrue(pane.tabBarVisible, "always（默认）：单标签也显示标签条")
        // 标签条右端的"+"新建标签
        pane.tabBarForTesting.newTabButtonForTesting.performClick(nil)
        XCTAssertEqual(pane.tabs.count, 2, "+ 新建标签")
        XCTAssertEqual(pane.activeTabIndex, 1, "新标签激活")
    }

    /// 标签条不能改变 pane 自身宽度（SwiftUI 托管的 pane 没有外部宽度约束，必需的项宽上限会把 pane 挤成 N×200）；
    /// 标签项 ≤ 200 且彼此等宽
    @MainActor
    func testTabBarDoesNotResizePane() throws {
        let prev = BrowserPaneView.settings
        defer { BrowserPaneView.settings = prev }
        BrowserPaneView.settings.home = "about:blank"
        let pane = BrowserPaneView(url: URL(string: "about:blank"))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let hosting = NSHostingView(rootView: PaneHostView(pane: pane).frame(width: 900, height: 600))
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(pane.frame.width, 900, accuracy: 1)
        pane.newTab()
        pane.newTab()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        hosting.layoutSubtreeIfNeeded()
        XCTAssertEqual(pane.frame.width, 900, accuracy: 1, "两个标签后 pane 宽度不能变")
        let items = pane.tabItemWidthsForTesting
        XCTAssertEqual(items.count, 3)
        for w in items { XCTAssertLessThanOrEqual(w, 200.5); XCTAssertGreaterThan(w, 40) }
        XCTAssertEqual(items.max()! - items.min()!, 0, accuracy: 1, "标签等宽")
        pane.closeActiveTab(); pane.closeActiveTab()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        hosting.layoutSubtreeIfNeeded()
        XCTAssertEqual(pane.frame.width, 900, accuracy: 1)
        window.contentView = nil
    }

    /// 标签条几何：[min, max] 内等分；到最小仍放不下 → 横向滚动且当前标签滚入视野；
    /// 当前标签常显关闭钮，非激活标签悬停才露出；斜边外的角落命中穿透给邻居；当前标签在最上层
    @MainActor
    func testTabBarGeometryHoverAndHitTesting() {
        let click = NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                                       windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        let bar = BrowserTabBarView(frame: NSRect(x: 0, y: 0, width: 400, height: BrowserTabBarView.Metrics.barHeight))
        bar.metrics = .init(maxWidth: 200, minWidth: 80)
        bar.update(items: [.init(title: "A", active: true), .init(title: "B", active: false)])
        bar.layoutSubtreeIfNeeded()
        let usable = 400 - 2 * BrowserTabBarView.Metrics.insetX - BrowserTabBarView.Metrics.newTabReserve
        XCTAssertEqual(bar.tabWidth, (usable + BrowserTabBarView.Metrics.overlap) / 2, accuracy: 0.5,
                       "等分标签区（已扣掉右侧 + 的位置）")
        XCTAssertFalse(bar.isOverflowing)
        // 等宽、相邻叠进 overlap
        let f = bar.itemFrames
        XCTAssertEqual(f[0].width, f[1].width, accuracy: 0.01)
        XCTAssertEqual(f[1].minX - f[0].minX, f[0].width - BrowserTabBarView.Metrics.overlap, accuracy: 0.01)
        // 当前标签常显关闭钮；非激活的悬停才显
        let a = bar.itemViews[0], b = bar.itemViews[1]
        XCTAssertTrue(a.closeButtonVisible)
        XCTAssertFalse(b.closeButtonVisible)
        bar.updateHover(atBarPoint: NSPoint(x: f[1].midX, y: f[1].midY))
        bar.layoutSubtreeIfNeeded()
        XCTAssertTrue(b.closeButtonVisible, "悬停露出关闭钮")
        XCTAssertEqual(b.frame.width - b.titleWidthForTesting, a.frame.width - a.titleWidthForTesting, accuracy: 0.01,
                       "悬停不改变标题宽度（关闭钮的位一直留着）")
        // 重叠带（两个标签的矩形都覆盖）里只有最上层的梯形算悬停
        let overlapX = f[1].minX + 2
        bar.updateHover(atBarPoint: NSPoint(x: overlapX, y: f[1].midY))
        XCTAssertEqual([a.hovering, b.hovering].filter { $0 }.count, 1, "重叠带里只有一个标签悬停")
        bar.updateHover(atBarPoint: nil)
        bar.layoutSubtreeIfNeeded()
        XCTAssertFalse(b.closeButtonVisible)
        // 当前标签在最上层（subviews 末尾）
        XCTAssertTrue(bar.subviews.last === a)
        // 命中：B 左上角（斜边外）穿透给压在下面的 A；B 中心命中 B
        let cornerInB = NSPoint(x: f[1].minX + 0.5, y: f[1].minY + 2)   // B 的斜边外、A 的梯形内
        XCTAssertTrue(bar.hitTest(cornerInB) === a || bar.hitTest(cornerInB)?.isDescendant(of: a) == true,
                      "斜边外的角落穿透给邻居")
        let centerB = NSPoint(x: f[1].midX, y: f[1].midY)
        XCTAssertTrue(bar.hitTest(centerB)?.isDescendant(of: b) == true)
        // 8 个标签、最小 80：放不下 → 溢出；选中最后一个滚入视野
        bar.update(items: (0..<8).map { .init(title: "T\($0)", active: $0 == 7) })
        bar.layoutSubtreeIfNeeded()
        XCTAssertEqual(bar.tabWidth, 80, accuracy: 0.01, "到最小宽度不再缩")
        XCTAssertTrue(bar.isOverflowing)
        let last = bar.itemFrames[7]
        let rightEdge = 400 - BrowserTabBarView.Metrics.insetX - BrowserTabBarView.Metrics.newTabReserve
        XCTAssertLessThanOrEqual(last.maxX, rightEdge + 0.5, "当前标签在视野内、不跑到 + 底下")
        XCTAssertGreaterThanOrEqual(bar.newTabButtonForTesting.frame.minX, last.maxX - BrowserTabBarView.Metrics.slant,
                                    "+ 在标签右侧")
        XCTAssertGreaterThanOrEqual(last.minX, 0)
        XCTAssertGreaterThan(bar.scrollOffset, 0)
        bar.scroll(by: -10_000)
        bar.layoutSubtreeIfNeeded()
        XCTAssertEqual(bar.scrollOffset, 0, "滚动钳在 0")
        XCTAssertEqual(bar.itemFrames[0].minX, BrowserTabBarView.Metrics.insetX, accuracy: 0.01)
        // 变窄后当前标签仍在视野内（README 承诺）
        bar.setFrameSize(NSSize(width: 200, height: BrowserTabBarView.Metrics.barHeight))
        bar.layoutSubtreeIfNeeded()
        let lastNarrow = bar.itemFrames[7]
        XCTAssertLessThanOrEqual(lastNarrow.maxX,
                                 200 - BrowserTabBarView.Metrics.insetX - BrowserTabBarView.Metrics.newTabReserve + 0.5,
                                 "变窄后当前标签仍露出")
        XCTAssertGreaterThanOrEqual(lastNarrow.minX, 0)
        bar.setFrameSize(NSSize(width: 400, height: BrowserTabBarView.Metrics.barHeight))
        bar.layoutSubtreeIfNeeded()
        // min > max 时以 max 为准
        bar.metrics = .init(maxWidth: 100, minWidth: 300)
        bar.update(items: [.init(title: "x", active: true)])
        bar.layoutSubtreeIfNeeded()
        XCTAssertEqual(bar.tabWidth, 100, accuracy: 0.01)
        // 点击 / 关闭回调带正确下标
        var selected = -1, closed = -1
        bar.onSelect = { selected = $0 }
        bar.onClose = { closed = $0 }
        bar.update(items: [.init(title: "A", active: true), .init(title: "B", active: false)])
        bar.itemViews[1].mouseDown(with: click)
        XCTAssertEqual(selected, 1)
        bar.itemViews[1].onClose?()
        XCTAssertEqual(closed, 1)
        var created = 0
        bar.onNewTab = { created += 1 }
        bar.newTabButtonForTesting.performClick(nil)
        XCTAssertEqual(created, 1, "+ 触发新建标签")
        // 标签没占满时 + 紧跟最后一个标签；占满时钉在右端
        bar.metrics = .init(maxWidth: 60, minWidth: 40)
        bar.layoutSubtreeIfNeeded()
        let plus = bar.newTabButtonForTesting.frame
        XCTAssertEqual(plus.minX,
                       bar.itemFrames[1].maxX - BrowserTabBarView.Metrics.slant + BrowserTabBarView.Metrics.newTabGap,
                       accuracy: 0.6, "+ 紧跟最后一个标签")
        XCTAssertLessThanOrEqual(plus.maxX, 400 - BrowserTabBarView.Metrics.insetX + 0.5)
    }

    /// 视觉快照（仅当设置 QUICKTERM_SNAPSHOT_DIR）：把标签条 + 工具条画成 PNG 供人工核对
    @MainActor
    func testTabBarSnapshot() throws {
        guard let dir = ProcessInfo.processInfo.environment["QUICKTERM_SNAPSHOT_DIR"] else { return }
        let bg = NSColor(srgbRed: 0.09, green: 0.09, blue: 0.11, alpha: 1)
        let fg = NSColor(srgbRed: 0.92, green: 0.92, blue: 0.94, alpha: 1)
        let width: CGFloat = 640
        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 64))
        container.wantsLayer = true
        container.layer?.backgroundColor = bg.cgColor
        let toolbar = NSView(frame: NSRect(x: 0, y: 4, width: width, height: 30))
        toolbar.wantsLayer = true
        toolbar.layer?.backgroundColor = bg.cgColor
        let bar = BrowserTabBarView(frame: NSRect(x: 0, y: 34, width: width, height: BrowserTabBarView.Metrics.barHeight))
        bar.applyTheme(background: bg, foreground: fg)
        bar.update(items: [
            .init(title: "Google", active: false),
            .init(title: "QuickTerm – GitHub", active: true),
            .init(title: "YouTube – a very long title that gets truncated", active: false),
            .init(title: "百度一下，你就知道", active: false),
        ])
        container.addSubview(toolbar)
        container.addSubview(bar)
        let window = NSWindow(contentRect: container.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = container
        bar.layoutSubtreeIfNeeded()
        let hovered = bar.itemViews[2].frame                                // 第三个标签悬停态
        bar.updateHover(atBarPoint: NSPoint(x: hovered.midX, y: hovered.midY))
        container.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(container.bitmapImageRepForCachingDisplay(in: container.bounds))
        container.cacheDisplay(in: container.bounds, to: rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("tabbar-dark.png"))
        window.contentView = nil
    }

    /// ⌘ 纯点击的转交目标：落在网页上 → WKWebView；落在地址栏 / 标签条等 AppKit 控件上 → nil（不能直接调 mouseDown）
    @MainActor
    func testClickTargetOnlyForwardsToWebView() throws {
        let prev = BrowserPaneView.settings
        defer { BrowserPaneView.settings = prev }
        BrowserPaneView.settings.home = "about:blank"
        let pane = BrowserPaneView(url: URL(string: "about:blank"))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        window.contentView = host
        pane.frame = host.bounds
        host.addSubview(pane)
        pane.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let webCenter = pane.webView.convert(NSPoint(x: pane.webView.bounds.midX, y: pane.webView.bounds.midY), to: nil)
        XCTAssertTrue(pane.clickTarget(atWindowPoint: webCenter) === pane.webView, "网页区域 → WKWebView")
        let field = pane.addressFieldForTesting
        let fieldCenter = field.convert(NSPoint(x: field.bounds.midX, y: field.bounds.midY), to: nil)
        XCTAssertNil(pane.clickTarget(atWindowPoint: fieldCenter), "地址栏 → 不转交")
        XCTAssertNil(pane.clickTarget(atWindowPoint: NSPoint(x: -50, y: -50)), "pane 外 → nil")
        window.contentView = nil
    }

    /// 多标签存档往返（tabs + activeTab），旧单页存档仍可读
    @MainActor
    func testTabsPersistence() throws {
        let prev = BrowserPaneView.settings
        defer { BrowserPaneView.settings = prev }
        BrowserPaneView.settings.home = "about:blank"
        let pane = BrowserPaneView(url: URL(string: "about:blank"))
        pane.newTab(url: URL(string: "https://example.com/a"))
        pane.newTab(url: URL(string: "https://example.com/b"))
        pane.selectTab(at: 1)
        let data = try JSONEncoder().encode(PaneBox(pane: pane))
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(json.contains("\"tabs\""), json)
        XCTAssertTrue(json.contains("example.com\\/b") || json.contains("example.com/b"), "JSONEncoder 会转义斜杠")
        let decoded = try XCTUnwrap(try JSONDecoder().decode(PaneBox.self, from: data).pane as? BrowserPaneView)
        XCTAssertEqual(decoded.tabs.count, 3)
        XCTAssertEqual(decoded.activeTabIndex, 1)
        XCTAssertEqual(decoded.tabs[2].lastRequestedURL?.absoluteString, "https://example.com/b")
        // 旧格式：只有 url
        let legacy = Data(#"{"pane":{"kind":"browser","uuid":"6E1F7C0E-1234-4C1D-9C6B-000000000001","url":"https://example.com/x","title":"x"}}"#.utf8)
        let old = try XCTUnwrap(try JSONDecoder().decode(PaneBox.self, from: legacy).pane as? BrowserPaneView)
        XCTAssertEqual(old.tabs.count, 1)
        XCTAssertEqual(old.lastRequestedURL?.absoluteString, "https://example.com/x")
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
