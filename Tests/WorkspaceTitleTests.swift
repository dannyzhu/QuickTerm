import AppKit
import SwiftUI
import XCTest
@testable import QuickTerm

/// 工作区的名字：截断规则（纯函数）、状态条"放不下就整排退回序号"、模型侧的槽位语义。
///
/// 这一组刻意不碰活的屏幕：`WorkspacePill` / `PaneTitleBadge.clamp` 是纯函数，
/// 而"放不下"正是视图里量不出来的那件事——它必须在这一层测得动。
final class WorkspaceTitleTests: XCTestCase {
    // MARK: 截断（与 pane 标题同一条数法，上限 12）

    func testShortNamePassesThrough() {
        XCTAssertEqual(PaneTitleBadge.clamp("dev", to: WorkspacePill.maxCharacters), "dev")
        XCTAssertEqual(WorkspacePill.clamped("  dev  "), "dev", "首尾空白不算名字的一部分")
    }

    func testBlankNameIsNoName() {
        XCTAssertNil(WorkspacePill.clamped(nil))
        XCTAssertNil(WorkspacePill.clamped(""))
        XCTAssertNil(WorkspacePill.clamped("   \n "))
    }

    /// 正好 12 个字：一个字不动，也不加省略号
    func testExactlyTwelveIsNotTruncated() {
        let name = String(repeating: "a", count: 12)
        XCTAssertEqual(WorkspacePill.clamped(name), name)
        XCTAssertEqual(WorkspacePill.clamped(name)?.count, 12)
    }

    /// 13 个字起就得截，而且省略号**算在 12 个里面**：11 个真字符 + `…`
    func testOverTwelveKeepsElevenPlusEllipsis() {
        for length in [13, 30, 200] {
            let clamped = WorkspacePill.clamped(String(repeating: "a", count: length))
            XCTAssertEqual(clamped, String(repeating: "a", count: 11) + "…", "\(length) 字")
            XCTAssertEqual(clamped?.count, 12, "含省略号一共 12 个字")
        }
    }

    /// CJK 与 emoji 各算一个字素簇（与 pane 标题逐条一致）
    func testCJKAndEmojiCountAsOneEach() {
        XCTAssertEqual(WorkspacePill.clamped(String(repeating: "编", count: 14)),
                       String(repeating: "编", count: 11) + "…")
        let family = "👩‍👩‍👧‍👦"
        XCTAssertEqual(family.count, 1, "前提：这串在 Swift 里就是一个字素簇")
        XCTAssertEqual(WorkspacePill.clamped(String(repeating: family, count: 20))?.count, 12)
        XCTAssertEqual(WorkspacePill.clamped("🧪 dev"), "🧪 dev")
    }

    /// 两个上限用的是同一条规则，只有数不同——pane 那边的 20 字不能被这次改动带歪
    func testPaneTitleKeepsItsOwnLimitOnTheSharedRule() {
        let long = String(repeating: "a", count: 40)
        XCTAssertEqual(PaneTitleBadge.clamp(long)?.count, 20)
        XCTAssertEqual(PaneTitleBadge.clamp(long, to: WorkspacePill.maxCharacters)?.count, 12)
        XCTAssertEqual(PaneTitleBadge.fit(title: long, topEdgeWidth: 4000),
                       String(repeating: "a", count: 19) + "…", "边框上那条 20 字的规矩没变")
    }

    // MARK: 胶囊上画什么

    func testPillWithoutANameLooksExactlyLikeToday() {
        XCTAssertEqual(WorkspacePill.label(title: nil, index: 1, active: false, showingTitles: true), "2")
        XCTAssertEqual(WorkspacePill.label(title: nil, index: 1, active: true, showingTitles: true), "■")
        XCTAssertEqual(WorkspacePill.pillWidth(title: nil, index: 1, active: false, showingTitles: true),
                       WorkspacePill.plainWidth)
    }

    func testNamedPillShowsTheNameInPlaceOfTheGlyph() {
        XCTAssertEqual(WorkspacePill.label(title: "dev", index: 1, active: false, showingTitles: true), "dev")
        XCTAssertEqual(WorkspacePill.label(title: "dev", index: 1, active: true, showingTitles: true), "dev",
                       "活动工作区也显示名字（活动的标记是重音色，不是那个方块）")
        XCTAssertGreaterThan(
            WorkspacePill.pillWidth(title: "dev", index: 1, active: false, showingTitles: true),
            WorkspacePill.plainWidth, "名字胶囊比序号胶囊宽")
    }

    /// 整排退回序号时，名字一个都不露面
    func testFallbackDrawsNumbersEvenForNamedWorkspaces() {
        XCTAssertEqual(WorkspacePill.label(title: "dev", index: 1, active: false, showingTitles: false), "2")
        XCTAssertEqual(WorkspacePill.pillWidth(title: "dev", index: 1, active: false, showingTitles: false),
                       WorkspacePill.plainWidth)
    }

    // MARK: 放不下就整排退回序号

    private let clock = "Wednesday 14:32"

    func testRoomyBarShowsTheNames() {
        XCTAssertTrue(WorkspacePill.showsTitles(contentWidth: 1600,
                                                titles: ["dev", nil, "web", nil, nil],
                                                activeIndex: 0,
                                                clockWidth: WorkspacePill.width(of: clock), flash: nil))
    }

    /// 窄窗口 + 五个长名字：左边那一段会伸进居中的时钟，于是**整排**退回序号
    func testNarrowBarFallsBackForTheWholeRow() {
        let titles = Array(repeating: String(repeating: "长", count: 12), count: 5) as [String?]
        XCTAssertFalse(WorkspacePill.showsTitles(contentWidth: 900, titles: titles, activeIndex: 0,
                                                 clockWidth: WorkspacePill.width(of: clock), flash: nil))
    }

    /// 全有或全无：短名字那一排放得下，多出三个长名字之后**整排**（连那两个短的）一起回到序号。
    /// 这条是结构性的——`showsTitles` 只有一个答案，胶囊没有各自的开关
    func testOneOverlongNameTurnsTheWholeRowOff() {
        let clockWidth = WorkspacePill.width(of: clock)
        let short: [String?] = ["dev", "web", nil, nil, nil]
        var crowded = short
        for index in 2..<5 { crowded[index] = String(repeating: "字", count: 12) }
        let width = 2 * (WorkspacePill.leftSectionWidth(titles: crowded, activeIndex: 0,
                                                        showingTitles: true, flash: nil)
                         + clockWidth / 2 + WorkspacePill.clearance) - 1
        XCTAssertTrue(WorkspacePill.showsTitles(contentWidth: width, titles: short, activeIndex: 0,
                                                clockWidth: clockWidth, flash: nil))
        XCTAssertFalse(WorkspacePill.showsTitles(contentWidth: width, titles: crowded, activeIndex: 0,
                                                 clockWidth: clockWidth, flash: nil))
    }

    /// 阈值不是拍脑袋的数：左边那一段的右沿正好顶到**时钟左沿**那一刻就翻面
    func testTheThresholdIsExactlyTheClockLeftEdge() {
        let titles: [String?] = ["开发环境", "网页", "日志", nil, nil]
        let clockWidth = WorkspacePill.width(of: clock)
        let left = WorkspacePill.leftSectionWidth(titles: titles, activeIndex: 0,
                                                  showingTitles: true, flash: nil)
        let exact = 2 * (left + clockWidth / 2 + WorkspacePill.clearance)
        XCTAssertTrue(WorkspacePill.showsTitles(contentWidth: exact + 1, titles: titles, activeIndex: 0,
                                                clockWidth: clockWidth, flash: nil))
        XCTAssertFalse(WorkspacePill.showsTitles(contentWidth: exact - 1, titles: titles, activeIndex: 0,
                                                 clockWidth: clockWidth, flash: nil))
        // 时钟换成更宽的那种格式，要放下同一排名字就得更宽的窗口——阈值确实跟着时钟走
        let wideClock = WorkspacePill.width(of: "31 September W36 2026")
        XCTAssertGreaterThan(2 * (left + wideClock / 2 + WorkspacePill.clearance), exact)
    }

    /// 控制面闪烁也占着左边那一段：同样宽的窗口，它一出现名字就该让位
    func testControlFlashCountsAgainstTheBudget() {
        let titles: [String?] = ["开发环境", "网页", "日志", nil, nil]
        let clockWidth = WorkspacePill.width(of: clock)
        let flash = "控制面：workspace set"
        let bare = WorkspacePill.leftSectionWidth(titles: titles, activeIndex: 0,
                                                  showingTitles: true, flash: nil)
        let crowded = WorkspacePill.leftSectionWidth(titles: titles, activeIndex: 0,
                                                     showingTitles: true, flash: flash)
        XCTAssertGreaterThan(crowded, bare + 1, "闪烁那一块是有宽度的")
        let width = 2 * (crowded + clockWidth / 2 + WorkspacePill.clearance) - 1
        XCTAssertTrue(WorkspacePill.showsTitles(contentWidth: width, titles: titles, activeIndex: 0,
                                                clockWidth: clockWidth, flash: nil))
        XCTAssertFalse(WorkspacePill.showsTitles(contentWidth: width, titles: titles, activeIndex: 0,
                                                 clockWidth: clockWidth, flash: flash))
    }

    /// 一个名字都没起：这一排本来就全是序号，用不着量
    func testNothingNamedMeansNothingToMeasure() {
        XCTAssertFalse(WorkspacePill.showsTitles(contentWidth: 4000, titles: [nil, nil, nil],
                                                 activeIndex: 0, clockWidth: 100, flash: nil))
    }

    /// 宽度还没量出来（第一帧）：宁可晚一帧显示名字，也不要先画坏一帧
    func testUnmeasuredBarDrawsNumbers() {
        XCTAssertFalse(WorkspacePill.showsTitles(contentWidth: 0, titles: ["dev", nil],
                                                 activeIndex: 0, clockWidth: 100, flash: nil))
    }

    // MARK: 右键才是改名，左键还是切工作区

    /// 只认右键。多认一种事件类型，胶囊的左键（切到这个工作区）就当场被这层透明视图吃掉
    func testOnlyRightClicksAreClaimed() {
        XCTAssertTrue(RightClickCatcher.claims(.rightMouseDown))
        XCTAssertTrue(RightClickCatcher.claims(.rightMouseUp))
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp, .leftMouseDragged,
                     .mouseMoved, .scrollWheel, .keyDown] {
            XCTAssertFalse(RightClickCatcher.claims(type), "\(type) 必须原样穿过去给按钮")
        }
        XCTAssertFalse(RightClickCatcher.claims(nil), "不在事件派发里（比如布局查询）也一律不认领")
    }

    // MARK: 模型：名字是**槽位**的

    func testSetTitleNormalisesAndIsIdempotent() {
        let model = WorkspaceModel()
        XCTAssertTrue(model.setTitle("  dev  ", at: 1))
        XCTAssertEqual(model.title(at: 1), "dev")
        XCTAssertFalse(model.setTitle("dev", at: 1), "同样的值第二次不算改动（退 7 靠这一条）")
        XCTAssertTrue(model.setTitle("", at: 1), "空串 = 清掉")
        XCTAssertNil(model.title(at: 1))
        XCTAssertFalse(model.setTitle("   ", at: 1), "已经没名字了，再清一次不算改动")
    }

    func testOutOfRangeSlotIsIgnored() {
        let model = WorkspaceModel()
        XCTAssertFalse(model.setTitle("dev", at: 99))
        XCTAssertNil(model.title(at: 99))
        XCTAssertNil(model.title(at: -1))
    }

    /// 工作区数变了（config 热重载就是这么落的）名字不许错位、更不许崩
    func testNamesSurviveWorkspaceCountChanges() {
        let model = WorkspaceModel()
        model.setTitle("one", at: 0)
        model.setTitle("five", at: 4)

        model.setWorkspaceCount(10)
        XCTAssertEqual(model.titles.count, 10)
        XCTAssertEqual(model.title(at: 0), "one")
        XCTAssertEqual(model.title(at: 4), "five", "扩容不该让名字往后串")
        XCTAssertNil(model.title(at: 9))

        model.setTitle("ten", at: 9)
        model.setWorkspaceCount(3)
        XCTAssertEqual(model.title(at: 0), "one", "缩容之后剩下的槽位名字照旧")
        XCTAssertNil(model.title(at: 9), "裁掉的槽位读不到名字")

        model.setWorkspaceCount(10)
        XCTAssertEqual(model.title(at: 4), "five", "调回来名字还在：名字是槽位的")
        XCTAssertEqual(model.title(at: 9), "ten")
    }

    /// 名字命名的是槽位，不是里面那堆 pane：布局整个换掉也不动它
    func testReplacingTheLayoutLeavesTheNameAlone() {
        let model = WorkspaceModel()
        model.setTitle("dev", at: 0)
        model.layouts[0] = .empty
        model.setLayout("dwindle", at: 0)
        XCTAssertEqual(model.title(at: 0), "dev")
    }

    // MARK: 存档往返

    func testArchiveRoundTripKeepsTheNames() throws {
        let saved = WindowState(layouts: [.empty, .empty, .empty],
                                floatings: [[], [], []], activeIndex: 1,
                                workspaceTitles: ["dev", nil, "日志"])
        let data = try JSONEncoder().encode(saved)
        let back = try JSONDecoder().decode(WindowState.self, from: data)
        XCTAssertEqual(back.workspaceTitles?.count, 3)
        XCTAssertEqual(back.workspaceTitles?[0], "dev")
        XCTAssertNil(back.workspaceTitles?[1] ?? nil)
        XCTAssertEqual(back.workspaceTitles?[2], "日志")
    }

    /// 老档（v5 里没有这一项）照常解码——新增一个可选字段不该废掉一次用户会话
    func testOlderArchiveWithoutTheFieldStillDecodes() throws {
        let saved = WindowState(layouts: [.empty, .empty], activeIndex: 0,
                                workspaceTitles: ["dev", nil])
        var raw = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: try JSONEncoder().encode(saved)) as? [String: Any])
        raw.removeValue(forKey: "workspaceTitles")
        let back = try JSONDecoder().decode(
            WindowState.self, from: try JSONSerialization.data(withJSONObject: raw))
        XCTAssertNil(back.workspaceTitles, "缺字段 = 一个名字都没起过")
        XCTAssertEqual(back.layouts.count, 2)
    }

    /// 存档里的名字比工作区还多（存的时候 10 个、config 改成 3 个）：不许崩，也不许错位
    func testMoreNamesThanWorkspacesIsHarmless() throws {
        let saved = WindowState(layouts: [.empty, .empty], activeIndex: 0,
                                workspaceTitles: ["dev", "web", "log", "x", "y"])
        let back = try JSONDecoder().decode(WindowState.self, from: try JSONEncoder().encode(saved))
        let model = WorkspaceModel()
        model.layouts = [.empty, .empty]
        model.titles = try XCTUnwrap(back.workspaceTitles)
        model.setWorkspaceCount(2)
        XCTAssertEqual(model.title(at: 0), "dev")
        XCTAssertEqual(model.title(at: 1), "web")
    }

    /// spec 的名字上限与控制面那条命令是同一个数（Wire 够不着 `ControlCommandRunner`，只能锁死）
    @MainActor
    func testSpecTitleLimitMatchesTheCommand() {
        XCTAssertEqual(SpecLimits.maxTitleCharacters, ControlCommandRunner.maxTitleLength)
    }

    // MARK: 预算与真正排出来的胶囊

    /// 一个胶囊的预算宽度必须等于 SwiftUI 真排出来的宽度。
    ///
    /// **这一条只能靠真排一遍**：`padding` 包在 `frame(minWidth:)` 外面还是里面，
    /// 公式看上去都"差不多对"，差出来的却正好是一个胶囊 8pt——而整排统共只有 8pt 余量，
    /// 五个一个字的名字就能把最后一格怼到时钟上
    @MainActor
    func testPillWidthMatchesTheLaidOutPill() {
        for name in ["a", "ab", "编", "dev", "开发环境", "🧪 dev", String(repeating: "a", count: 12)] {
            let laidOut = NSHostingView(
                rootView: WorkspacePill.pill(title: name, index: 0, active: false,
                                             showingTitles: true)).fittingSize.width
            let budget = WorkspacePill.pillWidth(title: name, index: 0, active: false,
                                                 showingTitles: true)
            XCTAssertEqual(budget, laidOut, accuracy: 1,
                           "「\(name)」：量出来 \(budget)，排出来 \(laidOut)")
        }
    }

    /// 没起名的胶囊还是那 18pt——这次改动一个点也不该动它
    @MainActor
    func testPlainPillIsStillEighteenPoints() {
        for (active, showing) in [(false, false), (true, false), (false, true), (true, true)] {
            let laidOut = NSHostingView(
                rootView: WorkspacePill.pill(title: nil, index: 3, active: active,
                                             showingTitles: showing)).fittingSize.width
            XCTAssertEqual(laidOut, WorkspacePill.plainWidth, accuracy: 1)
        }
    }

    /// 名字里混进换行也不许把状态条顶高：条高 26pt 是写死的，第二行会直接排到背景外面。
    /// （名字进不进得来是另一层的事：命令行报错、对话框滤掉——这里兜的是已经进来了的情况，
    /// 比如手改过的存档）
    @MainActor
    func testAMultiLineNameCannotGrowTheBar() {
        let tall = NSHostingView(
            rootView: WorkspacePill.pill(title: "a\nb\nc", index: 0, active: false,
                                         showingTitles: true)).fittingSize.height
        XCTAssertLessThanOrEqual(tall, StatusBarView.height, "一行字，多高都不许超过状态条")
    }

    /// 对话框里粘进来的换行 / 制表 / DEL 一律滤掉（命令行那头是报错，人这头只能滤）
    func testTypedNameLosesControlCharacters() {
        XCTAssertEqual(WorkspaceModel.titleFromInput("dev\n日志"), "dev日志")
        XCTAssertEqual(WorkspaceModel.titleFromInput("a\tb\u{7}c\u{7F}"), "abc")
        XCTAssertEqual(WorkspaceModel.titleFromInput("开发"), "开发", "正常的字一个不动")
        XCTAssertEqual(
            WorkspaceModel.titleFromInput(String(repeating: "a", count: 500)).count,
            ControlCommandRunner.maxTitleLength, "超了截断，不报错")
        // 滤完再交给模型，状态条上就只剩一行
        let model = WorkspaceModel()
        model.setTitle(WorkspaceModel.titleFromInput("a\nb"), at: 0)
        XCTAssertEqual(model.title(at: 0), "ab")
    }

    /// 工作区数缩回去之后，要量的还是**画出来的那一排**。
    /// `titles` 缩容不裁（名字是槽位的），拿它原样去量就会替几个根本不画的胶囊买单
    func testShrunkRowMeasuresOnlyThePillsItDraws() {
        let model = WorkspaceModel()
        model.setWorkspaceCount(10)
        for index in 0..<10 { model.setTitle("名字\(index)", at: index) }
        model.setWorkspaceCount(5)
        XCTAssertEqual(model.titles.count, 10, "前提：缩容不裁名字")
        XCTAssertEqual(model.visibleTitles.count, 5, "画出来的只有 5 个胶囊")
        XCTAssertEqual(model.visibleTitles.last ?? nil, "名字4")

        let clockWidth = WorkspacePill.width(of: clock)
        let drawn = WorkspacePill.leftSectionWidth(titles: model.visibleTitles, activeIndex: 0,
                                                   showingTitles: true, flash: nil)
        let width = 2 * (drawn + clockWidth / 2 + WorkspacePill.clearance) + 1
        XCTAssertTrue(WorkspacePill.showsTitles(contentWidth: width, titles: model.visibleTitles,
                                                activeIndex: 0, clockWidth: clockWidth, flash: nil),
                      "这一排放得下")
        XCTAssertFalse(WorkspacePill.showsTitles(contentWidth: width, titles: model.titles,
                                                 activeIndex: 0, clockWidth: clockWidth, flash: nil),
                       "同一条栏，按没裁的 titles 去量就说放不下——这正是不能拿它去量的理由")
    }

    // MARK: 帮助里那句话

    /// `--title` 的帮助是**生成**给 agent 看的（`--help` / `describe --json` / MCP 工具表同一份），
    /// 所以它不能与 `SpecApplier` 的实际行为打架：写了 `title` 的 spec 就是会改名
    func testHelpTellsTheTruthAboutSpecApply() throws {
        let command = try XCTUnwrap(ControlCommandTable.commands.first { $0.name == "workspace.set" })
        let help = try XCTUnwrap(command.args.first { $0.name == "title" }).help
        XCTAssertTrue(help.contains("spec"), "帮助得交代 spec apply 到底动不动名字")
        XCTAssertTrue(help.contains("carries a title"),
                      "帮助必须说清「spec 里写了 title 就会改名」——与下面两条断言是同一件事：\(help)")
        XCTAssertNil(SpecApplier.wantedTitle(WorkspaceSpec()), "不写 title = 不动名字")
        XCTAssertEqual(SpecApplier.wantedTitle(WorkspaceSpec(title: "dev")) ?? nil, "dev",
                       "写了 title 的 spec 会改名——帮助里说的必须是这件事")
    }
}
