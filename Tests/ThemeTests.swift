import XCTest
@testable import QuickTerm

final class ThemeTests: XCTestCase {
    func testParseColorsToml() {
        let toml = """
        mode = "dark"
        accent = "#7aa2f7"   # 行尾注释
        background = "#1a1b26"
        # 整行注释
        bright_red = "#ff7a93"
        """
        let parsed = Theme.parseColors(toml: toml)
        XCTAssertFalse(parsed.isLight)
        XCTAssertEqual(parsed.colors["accent"], "#7aa2f7")
        XCTAssertEqual(parsed.colors["background"], "#1a1b26")
        XCTAssertEqual(parsed.colors["bright_red"], "#ff7a93")
        XCTAssertNil(parsed.colors["mode"])
    }

    func testBundledThemesDiscovered() {
        let themes = ThemeManager.discoverThemes()
        XCTAssertGreaterThanOrEqual(themes.count, 20, "应发现 20+ 个内置主题（实际 \(themes.count)）")
        let tokyo = themes.first { $0.name == "tokyo-night" }
        XCTAssertNotNil(tokyo)
        XCTAssertEqual(tokyo?.hex("accent"), "#7aa2f7")
        XCTAssertFalse(tokyo?.isLight ?? true)
        XCTAssertTrue(themes.contains { $0.isLight }, "应含浅色主题（mode = light）")
    }

    @MainActor
    func testOverlayExtraFollowsTemplateMapping() throws {
        let manager = ThemeManager()
        guard let tokyo = manager.themes.first(where: { $0.name == "tokyo-night" }) else {
            return XCTFail("缺 tokyo-night")
        }
        manager.apply(tokyo)
        let overlay = manager.overlayExtra()
        // omarchy ghostty.conf.tpl 的映射（M3 权威来源）
        XCTAssertTrue(overlay.contains("background = #1a1b26"))
        XCTAssertTrue(overlay.contains("foreground = #a9b1d6"))
        XCTAssertTrue(overlay.contains("cursor-color = #c0caf5"))
        XCTAssertTrue(overlay.contains("palette = 0=#1a1b26"))
        XCTAssertTrue(overlay.contains("palette = 8=#414868"))
        XCTAssertTrue(overlay.contains("palette = 15=#c0caf5"))
    }

    @MainActor
    func testOpacityToggleOverridesBase() {
        let manager = ThemeManager()
        manager.opacityEnabled = false
        XCTAssertTrue(manager.overlayExtra().contains("background-opacity = 1.0"))
        manager.opacityEnabled = true
        XCTAssertFalse(manager.overlayExtra().contains("background-opacity = 1.0"))
    }

    /// 用户背景目录扫描：仅图片、按名排序
    func testDiscoverBackgroundsFiltersAndSorts() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("qt-bg-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for name in ["b.png", "a.webp", "note.txt", "c.JPG", ".DS_Store"] {
            FileManager.default.createFile(
                atPath: dir.appendingPathComponent(name).path, contents: Data([0]))
        }
        let found = ThemeManager.discoverBackgrounds(in: dir).map(\.lastPathComponent)
        XCTAssertEqual(found, ["a.webp", "b.png", "c.JPG"], "过滤非图片并按名排序")
        XCTAssertEqual(ThemeManager.discoverBackgrounds(
            in: dir.appendingPathComponent("missing")), [], "目录不存在返回空")
    }
}
