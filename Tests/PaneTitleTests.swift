import AppKit
import Combine
import XCTest
@testable import QuickTerm

/// pane 上边框上那块标题：截断算法（纯函数）、开关配置、以及"只有显式设过的标题才露面"。
final class PaneTitleTests: XCTestCase {
    private let metrics = PaneTitleBadge.Metrics.standard

    /// 宽到怎么都放得下：只剩 20 字这一条在管事
    private var roomy: CGFloat { 4000 }

    /// 恰好容得下 `text` 的顶边宽度（反解 `availableTextWidth`）
    private func width(fitting text: String, slack: CGFloat = 0) -> CGFloat {
        metrics.width(of: text) + metrics.leadingInset + metrics.sidePadding
            + CGFloat(metrics.reservedCharacters) * metrics.characterWidth + slack
    }

    // MARK: 截断

    func testShortTitlePassesThrough() {
        XCTAssertEqual(PaneTitleBadge.fit(title: "build", topEdgeWidth: roomy, metrics: metrics), "build")
    }

    func testEmptyOrBlankTitleDrawsNothing() {
        XCTAssertNil(PaneTitleBadge.fit(title: "", topEdgeWidth: roomy, metrics: metrics))
        XCTAssertNil(PaneTitleBadge.fit(title: "   \n ", topEdgeWidth: roomy, metrics: metrics))
    }

    /// 正好 20 字：一个字不动，也不加省略号
    func testExactlyTwentyCharactersIsNotTruncated() {
        let title = String(repeating: "a", count: 20)
        let fitted = PaneTitleBadge.fit(title: title, topEdgeWidth: roomy, metrics: metrics)
        XCTAssertEqual(fitted, title)
        XCTAssertEqual(fitted?.count, 20)
    }

    /// 21 字起就得截，而且省略号**算在 20 个里**：19 个真字符 + `…`
    func testOverTwentyKeepsNineteenPlusEllipsis() {
        for length in [21, 30, 200] {
            let title = String(repeating: "a", count: length)
            let fitted = try? XCTUnwrap(PaneTitleBadge.fit(title: title, topEdgeWidth: roomy, metrics: metrics))
            XCTAssertEqual(fitted, String(repeating: "a", count: 19) + "…", "\(length) 字")
            XCTAssertEqual(fitted?.count, 20, "含省略号一共 20 个字")
        }
    }

    /// CJK 按字素算 1 个（不是按显示宽度、更不是按字节）：22 个汉字 → 19 个 + `…`
    func testCJKCountsAsOneCharacterEach() {
        let title = String(repeating: "编", count: 22)
        let fitted = PaneTitleBadge.fit(title: title, topEdgeWidth: roomy, metrics: metrics)
        XCTAssertEqual(fitted, String(repeating: "编", count: 19) + "…")
        XCTAssertEqual(fitted?.count, 20)
        // 但汉字比拉丁字母宽得多：同样 20 个字，需要的边框宽度不是一回事
        XCTAssertGreaterThan(metrics.width(of: title), metrics.width(of: String(repeating: "a", count: 22)))
    }

    /// emoji（含 ZWJ 拼出来的家庭 emoji、带肤色的）也是 1 个字素簇
    func testEmojiCountsAsOneCharacterEach() {
        let family = "👩‍👩‍👧‍👦"
        XCTAssertEqual(family.count, 1, "前提：这串在 Swift 里就是一个字素簇")
        let title = String(repeating: family, count: 25)
        let fitted = PaneTitleBadge.fit(title: title, topEdgeWidth: roomy, metrics: metrics)
        XCTAssertEqual(fitted?.count, 20)
        XCTAssertTrue(fitted?.hasSuffix("…") ?? false)
        XCTAssertEqual(PaneTitleBadge.fit(title: "🧪 test", topEdgeWidth: roomy, metrics: metrics), "🧪 test")
    }

    /// 窄到一个字都放不下：不画（不是画一个孤零零的省略号，也不是画半个字）
    func testTooNarrowDrawsNoTitleAtAll() {
        for topEdge in [CGFloat(0), 10, 20, metrics.leadingInset + metrics.sidePadding
                        + 2 * metrics.characterWidth] {
            XCTAssertNil(PaneTitleBadge.fit(title: "build", topEdgeWidth: topEdge, metrics: metrics),
                         "顶边 \(topEdge) 放不下任何字符时不该画")
        }
        // 只能容下"一个字 + 省略号"时才开始画，且画出来必有真字符
        let minimal = width(fitting: "b…", slack: 0.5)
        let fitted = PaneTitleBadge.fit(title: "build", topEdgeWidth: minimal, metrics: metrics)
        XCTAssertEqual(fitted, "b…")
        XCTAssertNotEqual(fitted, "…", "绝不画光杆省略号")
    }

    /// 是那 2 个字符的预留在动刀：宽度足够写下整串，但扣掉预留就不够了
    func testTwoCharacterReserveIsWhatCuts() {
        let title = "deploy"
        // 恰好塞得下（连预留一起算）
        let justEnough = width(fitting: title, slack: 0.5)
        XCTAssertEqual(PaneTitleBadge.fit(title: title, topEdgeWidth: justEnough, metrics: metrics), title)
        // 同一个宽度，只把"预留"这一项去掉的话本来还有富余——可预留不能动，于是被截
        let shaved = justEnough - 2 * metrics.characterWidth
        let fitted = try? XCTUnwrap(PaneTitleBadge.fit(title: title, topEdgeWidth: shaved, metrics: metrics))
        XCTAssertNotEqual(fitted, title, "预留的两个字符宽必须真的吃掉文字")
        XCTAssertTrue(fitted?.hasSuffix("…") ?? false)
        XCTAssertGreaterThan(metrics.width(of: title), 0)
    }

    /// 画出来的东西**永远**碰不到右上角，而且右边至少剩两个字符长的线
    func testDrawnTitleNeverReachesTheTopRightCorner() {
        let titles = ["build", "编译 · web 服务", String(repeating: "x", count: 60), "🧪 test"]
        for topEdge in stride(from: CGFloat(0), through: 600, by: 7) {
            for title in titles {
                guard let fitted = PaneTitleBadge.fit(title: title, topEdgeWidth: topEdge,
                                                      metrics: metrics) else { continue }
                let gap = PaneTitleBadge.gapRange(for: fitted, metrics: metrics)
                XCTAssertLessThanOrEqual(
                    gap.end + CGFloat(metrics.reservedCharacters) * metrics.characterWidth,
                    topEdge + 0.001,
                    "顶边 \(topEdge) 上的「\(fitted)」把右侧的线吃掉了")
                XCTAssertLessThanOrEqual(fitted.count, PaneTitleBadge.maxCharacters)
            }
        }
    }

    // MARK: 纵向落位（标题必须真压在那条线上）

    /// 默认 `pane-gap = 5`：正常画，而且线心确实落在字身上
    func testDefaultPaneGapDrawsTheTitleOnTheLine() throws {
        let badge = try XCTUnwrap(PaneTitleBadge.place(title: "build", topEdgeWidth: roomy,
                                                       overhang: 5, metrics: metrics))
        XCTAssertEqual(badge.text, "build")
        XCTAssertGreaterThanOrEqual(badge.offsetY, -5, "字顶出了能借的那圈 pane-gap")
        XCTAssertLessThanOrEqual(badge.offsetY + metrics.capTopInset, PaneTitleBadge.lineWidth / 2,
                                 "线心得落在字身里，不能悬在字上方")
    }

    /// 回归：gaps 关掉（Cmd+Shift+Backspace / `app set --gaps off`）或 `pane-gap = 0` 时，
    /// 边框上方一点都借不到——以前会把字整个压到线下面（盖在终端第一行上），
    /// 边框却照样咬开一个空口子。现在是连字带断口一起不画
    func testNoRoomAboveTheLineDrawsNeitherTitleNorGap() {
        for overhang in [CGFloat(0), 0.5, 1, 2] {
            XCTAssertNil(PaneTitleBadge.verticalOffset(overhang: overhang, metrics: metrics),
                         "上方只剩 \(overhang)pt 时不该画")
            XCTAssertNil(PaneTitleBadge.place(title: "build", topEdgeWidth: roomy,
                                              overhang: overhang, metrics: metrics),
                         "上方只剩 \(overhang)pt：断口也不能开")
        }
    }

    /// 只要画得出来，线就一定从字身上穿过去，且字不越出能借的那圈留白
    func testDrawnTitleAlwaysStraddlesTheBorderLine() {
        let lineCentre = PaneTitleBadge.lineWidth / 2
        for overhang in stride(from: CGFloat(0), through: 20, by: 0.25) {
            guard let offset = PaneTitleBadge.verticalOffset(overhang: overhang, metrics: metrics)
            else { continue }
            XCTAssertGreaterThanOrEqual(offset, -overhang - 0.001,
                                        "pane-gap \(overhang)：字顶出了留白，会被槽位裁掉")
            XCTAssertLessThanOrEqual(offset + metrics.capTopInset, lineCentre,
                                     "pane-gap \(overhang)：线心在字上方 = 字掉到线下面了")
            XCTAssertGreaterThanOrEqual(offset + metrics.baselineInset, lineCentre,
                                        "pane-gap \(overhang)：线心在基线下方 = 字飘到线上面了")
        }
    }

    /// 留白够宽就正经居中：盒心压线心
    func testRoomyGapCentresTheTitleOnTheLine() throws {
        let offset = try XCTUnwrap(PaneTitleBadge.verticalOffset(overhang: 20, metrics: metrics))
        XCTAssertEqual(offset, PaneTitleBadge.lineWidth / 2 - metrics.lineHeight / 2, accuracy: 0.001)
    }

    /// `place` 是唯一入口：没标题、窄得放不下、上方腾不出地方——三种情况都得整圈边框连着画
    func testPlacementIsNilWheneverTheFrameMustStayUnbroken() {
        XCTAssertNil(PaneTitleBadge.place(title: nil, topEdgeWidth: roomy, overhang: 5,
                                          metrics: metrics))
        XCTAssertNil(PaneTitleBadge.place(title: "build", topEdgeWidth: 20, overhang: 5,
                                          metrics: metrics))
        XCTAssertNil(PaneTitleBadge.place(title: "build", topEdgeWidth: roomy, overhang: 0,
                                          metrics: metrics))
    }

    /// 断口必须框住真正画出来的那一串（而不是原标题），右边照旧留够两个字符的线
    func testPlacementGapMatchesTheDrawnText() throws {
        let badge = try XCTUnwrap(PaneTitleBadge.place(title: String(repeating: "编", count: 40),
                                                       topEdgeWidth: 400, overhang: 5,
                                                       metrics: metrics))
        let gap = PaneTitleBadge.gapRange(for: badge.text, metrics: metrics)
        XCTAssertEqual(badge.gapStart, gap.start)
        XCTAssertEqual(badge.gapEnd, gap.end)
        XCTAssertLessThanOrEqual(badge.gapEnd + 2 * metrics.characterWidth, 400.001)
    }

    // MARK: 配置项

    func testPaneTitleConfigKey() {
        XCTAssertTrue(ConfigStore.parse("").paneTitle, "默认开")
        XCTAssertFalse(ConfigStore.parse("[appearance]\npane-title = false").paneTitle)
        XCTAssertFalse(ConfigStore.parse("[appearance]\npane-title = off").paneTitle, "off 也认")
        XCTAssertTrue(ConfigStore.parse("[appearance]\npane-title = 1").paneTitle)
        XCTAssertTrue(ConfigStore.parse("[appearance]\npane-title = 乱写").paneTitle, "读不懂就退回默认")
    }

    /// 配置热重载要能立刻关掉它（走的是 pane-gap 那条路）
    @MainActor
    func testThemeManagerFollowsConfig() {
        let manager = ThemeManager()
        XCTAssertTrue(manager.paneTitleEnabled)
        manager.updateFromConfig(passthrough: "", followEngine: false, paneTitle: false)
        XCTAssertFalse(manager.paneTitleEnabled)
        manager.updateFromConfig(passthrough: "", followEngine: false, paneTitle: true)
        XCTAssertTrue(manager.paneTitleEnabled, "改回来也得立刻生效")
    }

    // MARK: 只有显式设过的标题才露面

    @MainActor
    func testOnlyAnExplicitlySetTitleShowsOnTheFrame() throws {
        let appDelegate = try XCTUnwrap(NSApp.delegate as? AppDelegate)
        let surface = Ghostty.SurfaceView(try XCTUnwrap(appDelegate.ghostty.app), baseConfig: nil)
        surface.setControlTitle("shell-reported")   // 先造一个"被接管"的状态再清掉
        _ = surface.setControlTitle(nil)
        XCTAssertNil(surface.customTitle, "shell 报的标题不上边框")

        XCTAssertTrue(surface.setControlTitle("build · web"))
        XCTAssertEqual(surface.customTitle, "build · web")

        _ = surface.setControlTitle("")             // 空串 = 交还给 shell
        XCTAssertNil(surface.customTitle, "交还之后边框上就不该再有")

        // 浏览器 pane 的标题是网页的，不是谁"起"的
        XCTAssertNil(BrowserPaneView(url: URL(string: "about:blank")).customTitle)
    }

    /// 陷阱回归：把标题钉成 shell 此刻正报的那个值——可见标题一个字没变，
    /// `title` 的 @Published 不会响，但边框上必须立刻出现标题。
    /// 所以"钉没钉住"这一位自己得发一次变更
    @MainActor
    func testPinningToTheAlreadyVisibleTitleStillNotifiesSwiftUI() throws {
        let appDelegate = try XCTUnwrap(NSApp.delegate as? AppDelegate)
        let surface = Ghostty.SurfaceView(try XCTUnwrap(appDelegate.ghostty.app), baseConfig: nil)
        surface.setTitle("same-title")
        let deadline = Date().addingTimeInterval(1)
        while surface.paneTitle != "same-title", Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertEqual(surface.paneTitle, "same-title", "前提：标题还在 shell 手里")
        XCTAssertNil(surface.customTitle)

        var notifications = 0
        let token = surface.objectWillChange.sink { _ in notifications += 1 }
        defer { token.cancel() }

        XCTAssertFalse(surface.setControlTitle("same-title"), "可见标题确实一个字没变")
        XCTAssertEqual(surface.customTitle, "same-title", "但它现在被钉住了，边框上要有")
        XCTAssertGreaterThan(notifications, 0, "标题一模一样时 SwiftUI 也必须被叫醒")

        notifications = 0
        _ = surface.setControlTitle("")
        XCTAssertNil(surface.customTitle, "清回 shell 标题后边框上的标题要消失")
        XCTAssertGreaterThan(notifications, 0, "反过来也要叫醒")
    }
}
