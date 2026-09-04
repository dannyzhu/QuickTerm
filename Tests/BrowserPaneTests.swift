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
