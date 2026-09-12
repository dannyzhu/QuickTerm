import XCTest
import SwiftUI
@testable import QuickTerm

final class BrowserPaneTests: XCTestCase {
    func testAddressInputResolution() {
        let s = BrowserPaneView.Settings()
        XCTAssertEqual(s.url(forInput: "https://a.b/c?d=1")?.absoluteString, "https://a.b/c?d=1", "a complete URL is left alone")
        XCTAssertEqual(s.url(forInput: "http://localhost:8080/x")?.absoluteString, "http://localhost:8080/x")
        XCTAssertEqual(s.url(forInput: "example.com")?.absoluteString, "https://example.com", "looks like a domain -> prepend https")
        XCTAssertEqual(s.url(forInput: "localhost:3000")?.absoluteString, "https://localhost:3000")
        XCTAssertEqual(s.url(forInput: "about:blank")?.absoluteString, "about:blank")
        XCTAssertEqual(s.url(forInput: "hello world")?.absoluteString, "https://www.google.com/search?q=hello%20world",
                       "not a URL -> search")
        XCTAssertEqual(s.url(forInput: "swift")?.absoluteString, "https://www.google.com/search?q=swift", "one word, no dot -> search")
        XCTAssertNil(s.url(forInput: "   "))
    }

    func testUserAgentModes() {
        var s = BrowserPaneView.Settings()
        XCTAssertEqual(s.effectiveUserAgent, BrowserPaneView.Settings.safariUserAgent, "by default it poses as Safari")
        s.userAgent = "webkit"
        XCTAssertNil(s.effectiveUserAgent, "webkit means no spoofing")
        s.userAgent = "MyAgent/1.0"
        XCTAssertEqual(s.effectiveUserAgent, "MyAgent/1.0")
        XCTAssertTrue(BrowserPaneView.Settings.safariUserAgent.contains("Safari/"), "Google decides a browser is embedded from the UA")
    }

    func testHomeFallback() {
        var s = BrowserPaneView.Settings()
        s.home = "not a url"
        XCTAssertEqual(s.homeURL.host, "www.google.com")
    }

    /// Focus-follows-mouse rides the container's own tracking area (owner = pane, with .mouseMoved): an
    /// override of mouseMoved on WKWebView never sees the events, because an internal observer owns its
    /// tracking area.
    @MainActor
    func testBrowserPaneInstallsHoverTrackingArea() {
        let pane = BrowserPaneView(url: nil)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        pane.frame = window.contentView!.bounds
        window.contentView?.addSubview(pane)
        pane.updateTrackingAreas()
        let area = pane.trackingAreas.first { $0.owner === pane }
        XCTAssertNotNil(area, "the container has to own a tracking area")
        XCTAssertTrue(area?.options.contains(.mouseMoved) ?? false)
        XCTAssertTrue(area?.options.contains(.activeAlways) ?? false)
        XCTAssertTrue(pane.installsHoverTracking)
        XCTAssertFalse(Ghostty.SurfaceView.self == type(of: pane), "a terminal pane manages its own tracking area")
        pane.removeFromSuperview()
    }

    /// The whole event chain: click the address bar -> type baidu.com -> press Return -> request https://baidu.com.
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
            // Tear down explicitly and wait for SwiftUI to remount the original workspace: EngineSmokeTests
            // runs right after this one and inspects the view chain synchronously.
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
        // NSCell's mouse tracking loops on nextEvent until it sees a mouseUp: queue the mouseUp first and
        // only then send the mouseDown, otherwise this deadlocks.
        NSApp.postEvent(mouse(.leftMouseUp), atStart: false)
        NSApp.sendEvent(mouse(.leftMouseDown))
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertNotNil(field.currentEditor(),
                        "the address bar should start editing after the click; FR=\(String(describing: window.firstResponder))")
        XCTAssertTrue(b.focused, "the pane holds focus while the address bar is being edited")
        // The first click selects everything: Cmd+C copies straight away, and typing replaces the selection.
        XCTAssertEqual(field.currentEditor()?.selectedRange, NSRange(location: 0, length: field.stringValue.count),
                       "clicking the address bar selects everything")
        field.currentEditor()?.insertText("baidu.com")   // Typing replaces the whole selection
        let ret = NSEvent.keyEvent(with: .keyDown, location: center, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                   windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
                                   isARepeat: false, keyCode: 36)!
        NSApp.sendEvent(ret)
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        // The site may redirect immediately (baidu.com -> www.baidu.com), so only assert on the host.
        XCTAssertTrue(b.lastRequestedURL?.host?.hasSuffix("baidu.com") ?? false,
                      "Return should request baidu; actual \(String(describing: b.lastRequestedURL))")
        XCTAssertTrue(window.firstResponder === b.webView, "focus goes back to the page after Return")
    }

    /// Tabs: a new tab activates, relative switching wraps, closing picks a neighbour, the last tab is never
    /// closed from inside the pane; tab bar auto/always.
    @MainActor
    func testTabsLifecycle() throws {
        let prev = BrowserPaneView.settings
        defer { BrowserPaneView.settings = prev }
        BrowserPaneView.settings.home = "about:blank"
        BrowserPaneView.settings.tabBar = "auto"
        let pane = BrowserPaneView(url: URL(string: "about:blank"))
        XCTAssertEqual(pane.tabs.count, 1)
        XCTAssertFalse(pane.tabBarVisible, "auto hides the bar for a single tab")
        pane.newTab()
        pane.newTab()
        XCTAssertEqual(pane.tabs.count, 3)
        XCTAssertEqual(pane.activeTabIndex, 2, "a new tab becomes active")
        XCTAssertTrue(pane.tabBarVisible)
        XCTAssertTrue(pane.focusTarget === pane.tabs[2].webView, "the focus target is the active tab")
        XCTAssertTrue(pane.tabs[0].webView.isHidden && !pane.tabs[2].webView.isHidden)
        pane.selectTab(offset: 1)
        XCTAssertEqual(pane.activeTabIndex, 0, "it wraps around at the ends")
        pane.selectTab(offset: -1)
        XCTAssertEqual(pane.activeTabIndex, 2)
        pane.selectTab(at: 1)
        XCTAssertTrue(pane.closeActiveTab())
        XCTAssertEqual(pane.tabs.count, 2)
        XCTAssertEqual(pane.activeTabIndex, 1, "closing a middle tab selects the one after it")
        XCTAssertTrue(pane.closeActiveTab())
        XCTAssertEqual(pane.activeTabIndex, 0, "closing the last tab selects the one before it")
        XCTAssertFalse(pane.closeActiveTab(), "the final tab is never closed from inside the pane")
        XCTAssertEqual(pane.tabs.count, 1)
        BrowserPaneView.settings.tabBar = "always"
        pane.applySettings()
        XCTAssertTrue(pane.tabBarVisible, "always (the default): the bar shows even with a single tab")
        // The "+" at the right end of the bar opens a new tab.
        pane.tabBarForTesting.newTabButtonForTesting.performClick(nil)
        XCTAssertEqual(pane.tabs.count, 2, "+ opens a new tab")
        XCTAssertEqual(pane.activeTabIndex, 1, "the new tab becomes active")
    }

    /// The tab bar must not change the pane's own width: a SwiftUI-hosted pane has no external width
    /// constraint, so a required item-width maximum would stretch the pane out to N x 200. Items are
    /// <= 200 wide and all equal.
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
        XCTAssertEqual(pane.frame.width, 900, accuracy: 1, "the pane's width must not change once two more tabs exist")
        let items = pane.tabItemWidthsForTesting
        XCTAssertEqual(items.count, 3)
        for w in items { XCTAssertLessThanOrEqual(w, 200.5); XCTAssertGreaterThan(w, 40) }
        XCTAssertEqual(items.max()! - items.min()!, 0, accuracy: 1, "tabs are equal width")
        pane.closeActiveTab(); pane.closeActiveTab()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        hosting.layoutSubtreeIfNeeded()
        XCTAssertEqual(pane.frame.width, 900, accuracy: 1)
        window.contentView = nil
    }

    /// Tab-bar geometry: split evenly within [min, max]; once even the minimum no longer fits, scroll
    /// horizontally and bring the active tab into view; the active tab always shows its close button while
    /// inactive ones reveal it on hover; corners outside the slanted edge fall through to the neighbour; the
    /// active tab is on top.
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
                       "the tab area is split evenly, with the room for the + on the right already deducted")
        XCTAssertFalse(bar.isOverflowing)
        // Equal widths, and neighbours slide into each other by `overlap`.
        let f = bar.itemFrames
        XCTAssertEqual(f[0].width, f[1].width, accuracy: 0.01)
        XCTAssertEqual(f[1].minX - f[0].minX, f[0].width - BrowserTabBarView.Metrics.overlap, accuracy: 0.01)
        // The active tab always shows its close button; an inactive one only on hover.
        let a = bar.itemViews[0], b = bar.itemViews[1]
        XCTAssertTrue(a.closeButtonVisible)
        XCTAssertFalse(b.closeButtonVisible)
        bar.updateHover(atBarPoint: NSPoint(x: f[1].midX, y: f[1].midY))
        bar.layoutSubtreeIfNeeded()
        XCTAssertTrue(b.closeButtonVisible, "hovering reveals the close button")
        XCTAssertEqual(b.frame.width - b.titleWidthForTesting, a.frame.width - a.titleWidthForTesting, accuracy: 0.01,
                       "hovering does not change the title width; the close button's slot is always reserved")
        // Inside the overlap strip, where both tabs' rects cover the point, only the topmost trapezoid hovers.
        let overlapX = f[1].minX + 2
        bar.updateHover(atBarPoint: NSPoint(x: overlapX, y: f[1].midY))
        XCTAssertEqual([a.hovering, b.hovering].filter { $0 }.count, 1, "only one tab hovers inside the overlap strip")
        bar.updateHover(atBarPoint: nil)
        bar.layoutSubtreeIfNeeded()
        XCTAssertFalse(b.closeButtonVisible)
        // The active tab is on top, which means last in subviews.
        XCTAssertTrue(bar.subviews.last === a)
        // Hit testing: B's top-left corner, outside the slant, falls through to the A underneath; B's center hits B.
        let cornerInB = NSPoint(x: f[1].minX + 0.5, y: f[1].minY + 2)   // Outside B's slant, inside A's trapezoid
        XCTAssertTrue(bar.hitTest(cornerInB) === a || bar.hitTest(cornerInB)?.isDescendant(of: a) == true,
                      "a corner outside the slant falls through to the neighbour")
        let centerB = NSPoint(x: f[1].midX, y: f[1].midY)
        XCTAssertTrue(bar.hitTest(centerB)?.isDescendant(of: b) == true)
        // 8 tabs at a minimum of 80: they no longer fit, so it overflows; selecting the last scrolls it into view.
        bar.update(items: (0..<8).map { .init(title: "T\($0)", active: $0 == 7) })
        bar.layoutSubtreeIfNeeded()
        XCTAssertEqual(bar.tabWidth, 80, accuracy: 0.01, "it stops shrinking at the minimum width")
        XCTAssertTrue(bar.isOverflowing)
        let last = bar.itemFrames[7]
        let rightEdge = 400 - BrowserTabBarView.Metrics.insetX - BrowserTabBarView.Metrics.newTabReserve
        XCTAssertLessThanOrEqual(last.maxX, rightEdge + 0.5, "the active tab stays in view and never slides under the +")
        XCTAssertGreaterThanOrEqual(bar.newTabButtonForTesting.frame.minX, last.maxX - BrowserTabBarView.Metrics.slant,
                                    "the + sits to the right of the tabs")
        XCTAssertGreaterThanOrEqual(last.minX, 0)
        XCTAssertGreaterThan(bar.scrollOffset, 0)
        bar.scroll(by: -10_000)
        bar.layoutSubtreeIfNeeded()
        XCTAssertEqual(bar.scrollOffset, 0, "scrolling clamps at 0")
        XCTAssertEqual(bar.itemFrames[0].minX, BrowserTabBarView.Metrics.insetX, accuracy: 0.01)
        // After narrowing, the active tab is still in view (a README promise).
        bar.setFrameSize(NSSize(width: 200, height: BrowserTabBarView.Metrics.barHeight))
        bar.layoutSubtreeIfNeeded()
        let lastNarrow = bar.itemFrames[7]
        XCTAssertLessThanOrEqual(lastNarrow.maxX,
                                 200 - BrowserTabBarView.Metrics.insetX - BrowserTabBarView.Metrics.newTabReserve + 0.5,
                                 "the active tab is still visible after narrowing")
        XCTAssertGreaterThanOrEqual(lastNarrow.minX, 0)
        bar.setFrameSize(NSSize(width: 400, height: BrowserTabBarView.Metrics.barHeight))
        bar.layoutSubtreeIfNeeded()
        // When min > max, max wins.
        bar.metrics = .init(maxWidth: 100, minWidth: 300)
        bar.update(items: [.init(title: "x", active: true)])
        bar.layoutSubtreeIfNeeded()
        XCTAssertEqual(bar.tabWidth, 100, accuracy: 0.01)
        // The select / close callbacks carry the right index.
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
        XCTAssertEqual(created, 1, "+ fires the new-tab callback")
        // While the tabs do not fill the bar the + follows the last tab; once they do, it pins to the right edge.
        bar.metrics = .init(maxWidth: 60, minWidth: 40)
        bar.layoutSubtreeIfNeeded()
        let plus = bar.newTabButtonForTesting.frame
        XCTAssertEqual(plus.minX,
                       bar.itemFrames[1].maxX - BrowserTabBarView.Metrics.slant + BrowserTabBarView.Metrics.newTabGap,
                       accuracy: 0.6, "the + follows the last tab")
        XCTAssertLessThanOrEqual(plus.maxX, 400 - BrowserTabBarView.Metrics.insetX + 0.5)
    }

    /// Visual snapshot, only when QUICKTERM_SNAPSHOT_DIR is set: renders the tab bar plus toolbar to a PNG
    /// for a human to check.
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
            .init(title: "百度一下，你就知道", active: false),   // CJK title: checks glyph rendering in the snapshot
        ])
        container.addSubview(toolbar)
        container.addSubview(bar)
        let window = NSWindow(contentRect: container.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = container
        bar.layoutSubtreeIfNeeded()
        let hovered = bar.itemViews[2].frame                                // The third tab, hovered
        bar.updateHover(atBarPoint: NSPoint(x: hovered.midX, y: hovered.midY))
        container.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(container.bitmapImageRepForCachingDisplay(in: container.bounds))
        container.cacheDisplay(in: container.bounds, to: rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("tabbar-dark.png"))
        window.contentView = nil
    }

    /// Where a plain Cmd+click is forwarded: on the page it goes to the WKWebView; on the address bar, the tab
    /// bar or any other AppKit control it is nil, because mouseDown must not be called on those directly.
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
        XCTAssertTrue(pane.clickTarget(atWindowPoint: webCenter) === pane.webView, "the page area goes to the WKWebView")
        let field = pane.addressFieldForTesting
        let fieldCenter = field.convert(NSPoint(x: field.bounds.midX, y: field.bounds.midY), to: nil)
        XCTAssertNil(pane.clickTarget(atWindowPoint: fieldCenter), "the address bar is not forwarded")
        XCTAssertNil(pane.clickTarget(atWindowPoint: NSPoint(x: -50, y: -50)), "outside the pane it is nil")
        window.contentView = nil
    }

    /// A multi-tab archive round trip (tabs + activeTab); an old single-page archive still reads.
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
        XCTAssertTrue(json.contains("example.com\\/b") || json.contains("example.com/b"), "JSONEncoder escapes forward slashes")
        let decoded = try XCTUnwrap(try JSONDecoder().decode(PaneBox.self, from: data).pane as? BrowserPaneView)
        XCTAssertEqual(decoded.tabs.count, 3)
        XCTAssertEqual(decoded.activeTabIndex, 1)
        XCTAssertEqual(decoded.tabs[2].lastRequestedURL?.absoluteString, "https://example.com/b")
        // The old format: url only.
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

    // MARK: - Element fullscreen (video)

    /// Build a pane inside a real window, laid out, with one tab.
    @MainActor
    private func makeLaidOutPane(size: NSSize) -> (BrowserPaneView, NSWindow) {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled], backing: .buffered, defer: false)
        // Programmatically created NSWindows are released when closed; in ARC that is a double free.
        window.isReleasedWhenClosed = false
        let pane = BrowserPaneView(url: URL(string: "about:blank"))
        pane.frame = window.contentView!.bounds
        pane.autoresizingMask = [.width, .height]
        window.contentView!.addSubview(pane)
        window.contentView!.layoutSubtreeIfNeeded()
        return (pane, window)
    }

    /// The web view's frame must belong to the web view, never to the pane's Auto Layout engine.
    ///
    /// WKFullScreenWindowController takes ownership of that frame when a page element goes fullscreen,
    /// so a constraint-pinned web view is dragged back to its inline size (or collapses) the moment
    /// either window runs a layout pass. See install() for the full story.
    @MainActor
    func testWebViewOwnsItsOwnFrame() throws {
        let (pane, window) = makeLaidOutPane(size: NSSize(width: 600, height: 400))
        defer { pane.removeFromSuperview() }
        let webArea = pane.webAreaForTesting
        let webView = pane.webView

        XCTAssertTrue(webView.translatesAutoresizingMaskIntoConstraints,
                      "the web view has to keep its own frame: WebKit hands it a fullscreen frame by hand")
        XCTAssertEqual(webView.autoresizingMask, [.width, .height],
                       "inside the pane it follows webArea through the autoresizing mask, not constraints")
        // Constraints we wrote ourselves - as opposed to the NSAutoresizingMaskLayoutConstraints AppKit
        // synthesizes from the mask, which are regenerated against whatever superview the view is in and
        // therefore travel with it into WebKit's window.
        let ours = webArea.constraints.filter {
            type(of: $0) == NSLayoutConstraint.self
                && (($0.firstItem as? NSView) === webView || ($0.secondItem as? NSView) === webView)
        }
        XCTAssertTrue(ours.isEmpty, "no constraint of ours may address the web view: \(ours)")
        XCTAssertEqual(webView.frame, webArea.bounds, "it still fills the pane")

        // And it keeps filling it when the pane is resized - that is what the mask buys us.
        window.setContentSize(NSSize(width: 900, height: 700))
        window.contentView!.layoutSubtreeIfNeeded()
        XCTAssertEqual(webView.frame, webArea.bounds, "the web view follows webArea on a resize")
        XCTAssertGreaterThan(webArea.bounds.width, 600, "sanity: the pane really did grow")
    }

    /// Replay what -[WKFullScreenWindowController enterFullScreen:] does to our view tree - a
    /// placeholder takes the web view's place in webArea, the real web view moves into WebKit's own
    /// window and is given the screen rect by hand - and then run layout passes in both windows, the
    /// way a title change (pause -> play on a video site) or a SwiftUI update does. The fullscreen
    /// frame has to survive; when the pane owned it, the web view was resized back to the pane's
    /// inline size, which is the "sound but a black picture" bug.
    @MainActor
    func testFullscreenReparentingSurvivesLayoutPasses() throws {
        let (pane, window) = makeLaidOutPane(size: NSSize(width: 600, height: 400))
        defer { pane.removeFromSuperview() }
        let webArea = pane.webAreaForTesting
        let webView = pane.webView

        // Stand-in for WebKit's WebCoreFullScreenWindow.
        let fsWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900),
                                styleMask: [.borderless], backing: .buffered, defer: false)
        fsWindow.isReleasedWhenClosed = false
        let fsContent = fsWindow.contentView!

        // WebKit's replaceViewWithView(): placeholder in, web view out, then into the fullscreen window.
        let placeholder = NSView(frame: webView.frame)
        placeholder.autoresizingMask = webView.autoresizingMask
        webArea.addSubview(placeholder, positioned: .above, relativeTo: webView)
        webView.removeFromSuperview()
        fsContent.addSubview(webView)
        webView.frame = fsContent.bounds

        XCTAssertFalse(webView.hasAmbiguousLayout,
                       "in WebKit's window nothing of ours constrains it, so it must not be layout-managed")

        // Layout churn on both sides, several rounds: the pane's window keeps laying itself out while
        // fullscreen is up (tab-bar rebuilds off the title KVO, SwiftUI updates), and so does WebKit's.
        for _ in 0..<3 {
            pane.needsLayout = true
            window.contentView!.needsLayout = true
            window.contentView!.layoutSubtreeIfNeeded()
            fsContent.needsLayout = true
            fsContent.layoutSubtreeIfNeeded()
        }

        XCTAssertEqual(webView.window, fsWindow, "sanity: it is still WebKit's window that owns it")
        XCTAssertEqual(webView.frame, fsContent.bounds,
                       "the fullscreen frame must survive layout in both windows")
        XCTAssertFalse(webView.hasAmbiguousLayout, "and it must not have become layout-ambiguous")

        // Coming back out: WebKit puts the web view back where the placeholder is and removes it.
        webView.removeFromSuperview()
        webView.frame = placeholder.frame
        webArea.addSubview(webView, positioned: .above, relativeTo: placeholder)
        placeholder.removeFromSuperview()
        window.setContentSize(NSSize(width: 700, height: 500))
        window.contentView!.layoutSubtreeIfNeeded()
        XCTAssertEqual(webView.frame, webArea.bounds, "back inline, it fills the pane again and tracks resizes")
    }
}


/// Test helper: round-trip one pane through PaneCodable.
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
