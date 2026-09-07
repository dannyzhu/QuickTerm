import XCTest
import AppKit
@testable import QuickTerm

/// 会话存档 v5：多屏幕 + 显示器/frame 恢复 + 一键复原（spec v9 §3.6）。
///
/// 所有用例一律用**临时目录**里的 state.json——绝不能碰用户真实的
/// `~/Library/Application Support/QuickTerm/state.json`（`SessionStore` 在测试宿主里
/// 只有显式注入 URL 才允许写盘，本文件的最后一个用例守着这条线）。
@MainActor
final class SessionStateTests: XCTestCase {
    private var app: AppDelegate {
        get throws { try XCTUnwrap(NSApp.delegate as? AppDelegate) }
    }

    private var tempDirs: [URL] = []
    /// 保活：`SessionStore` 持有注册表，注册表持有控制器
    private var registries: [ScreenRegistry] = []

    override func tearDown() {
        for dir in tempDirs { try? FileManager.default.removeItem(at: dir) }
        tempDirs.removeAll()
        registries.removeAll()
        super.tearDown()
    }

    private func spin(_ seconds: TimeInterval = 0.3) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    /// 临时目录里的 state.json（每个用例一份）
    private func tempStateURL() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("quickterm-session-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDirs.append(dir)
        let url = dir.appendingPathComponent("state.json")
        XCTAssertNotEqual(url, SessionStore.defaultURL, "用例绝不能写用户真实存档")
        return url
    }

    private func makeStore(at url: URL) -> SessionStore {
        let registry = ScreenRegistry()
        registries.append(registry)
        return SessionStore(screens: registry, url: url)
    }

    // MARK: v5 往返：两个屏幕

    /// 两个屏幕（终端 + 浮动 + 浏览器多标签）存盘再读回：布局、activeIndex、浮动层、
    /// 终端 pwd、浏览器标签 URL 一个都不少
    func testV5RoundTripRestoresTwoWindows() throws {
        let c = try XCTUnwrap(try app.controller)
        let url = try tempStateURL()
        let store = makeStore(at: url)

        // 屏幕 A：一个终端（带 cwd）+ 一个浮动终端
        let tiled = c.newSurface(workingDirectory: nil)
        tiled.pwd = "/usr/local/quickterm-test-a"
        let floated = c.newSurface(workingDirectory: nil)
        floated.pwd = "/usr/local/quickterm-test-float"
        let windowA = WindowState(
            layouts: [.scrolling(ScrollingStrip(pane: tiled, widthFactor: 0.5)), .empty],
            floatings: [[FloatingPane(pane: floated, rect: CGRect(x: 0.1, y: 0.2, width: 0.4, height: 0.5))], []],
            activeIndex: 0, visibleColumns: 3,
            display: DisplayRef(screen: NSScreen.main),
            frame: CGRect(x: 40, y: 60, width: 900, height: 600))

        // 屏幕 B：一个浏览器 pane（三个标签，活动标签是第 2 个）
        let browser = BrowserPaneView(url: URL(string: "about:blank"))
        browser.newTab(url: URL(string: "https://example.com/a"))
        browser.newTab(url: URL(string: "https://example.com/b"))
        browser.selectTab(at: 1)
        let windowB = WindowState(
            layouts: [.scrolling(ScrollingStrip(pane: browser, widthFactor: 0.5))],
            floatings: [[]], activeIndex: 0,
            frame: CGRect(x: 10, y: 20, width: 800, height: 500))

        store.snapshotOverride = { PersistedState(windows: [windowA, windowB], keyWindowID: windowB.id) }
        store.saveNow()

        let json = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(json.contains("quickterm-test-a"), "终端 pane 的 cwd 必须进档（一键复原的关键）")
        XCTAssertTrue(json.contains("quickterm-test-float"), "浮动终端的 cwd 也进档")

        let restored = try XCTUnwrap(store.load())
        XCTAssertEqual(restored.version, 5)
        XCTAssertEqual(restored.windows.count, 2, "两个屏幕都要回来")
        XCTAssertEqual(restored.keyWindowID, windowB.id)

        let a = restored.windows[0]
        XCTAssertEqual(a.id, windowA.id)
        XCTAssertEqual(a.layouts.count, 2)
        XCTAssertEqual(a.activeIndex, 0)
        XCTAssertEqual(a.visibleColumns, 3)
        XCTAssertEqual(a.frame, CGRect(x: 40, y: 60, width: 900, height: 600))
        XCTAssertEqual(a.display?.uuid, NSScreen.main?.displayUUID?.uuidString)
        XCTAssertEqual(a.layouts[0].paneList.count, 1)
        XCTAssertEqual(a.floatings?[0].count, 1, "浮动层随屏幕回来")
        XCTAssertEqual(a.floatings?[0].first?.rect, CGRect(x: 0.1, y: 0.2, width: 0.4, height: 0.5))
        XCTAssertTrue(a.layouts[0].paneList[0] is Ghostty.SurfaceView, "终端 pane 仍是终端")

        let b = restored.windows[1]
        let decodedBrowser = try XCTUnwrap(b.layouts[0].paneList.first as? BrowserPaneView)
        XCTAssertEqual(decodedBrowser.tabs.count, 3, "浏览器已打开的网页全部回来")
        XCTAssertEqual(decodedBrowser.activeTabIndex, 1)
        XCTAssertEqual(decodedBrowser.tabs[1].lastRequestedURL?.absoluteString, "https://example.com/a")
        XCTAssertEqual(decodedBrowser.tabs[2].lastRequestedURL?.absoluteString, "https://example.com/b")
    }

    /// 端到端的「一键复原」：把一份存档灌进一个真实的新屏幕（restoring = true 的窗口不自带起步终端）
    func testRestoreAppliesArchiveToRealScreen() throws {
        let app = try self.app
        let c = try XCTUnwrap(app.controller)
        let source = c.newSurface(workingDirectory: nil)
        source.pwd = "/usr/local/quickterm-restore"
        let browser = BrowserPaneView(url: URL(string: "https://example.com/restore"))
        let saved = WindowState(
            layouts: [.scrolling(ScrollingStrip(pane: source, widthFactor: 0.5)),
                      .scrolling(ScrollingStrip(pane: browser, widthFactor: 0.5))],
            floatings: [[], []], activeIndex: 1, visibleColumns: 2,
            display: DisplayRef(screen: NSScreen.main),
            frame: CGRect(x: 30, y: 40, width: 700, height: 480))
        // 经一次 JSON 往返拿到「另一套 pane」（真实恢复就是这么来的）
        let data = try JSONEncoder().encode(PersistedState(windows: [saved], keyWindowID: saved.id))
        let decoded = try XCTUnwrap(SessionStore.decode(data)).windows[0]

        let screen = SessionStore.resolveScreen(for: decoded.display)
        let restored = app.newScreen(on: screen, restoring: true, id: decoded.id,
                                     restoredFrame: decoded.frame)
        defer {
            if app.controllers.contains(where: { $0 === restored }) { app.closeScreen(restored) }
            c.window?.makeKeyAndOrderFront(nil)
            spin()
        }
        XCTAssertTrue(restored.model.allPanes.isEmpty, "restoring 的窗口不该自带起步终端")
        XCTAssertTrue(restored.restore(from: decoded))
        spin()
        XCTAssertEqual(restored.windowID, saved.id, "窗口身份跨启动不变")
        XCTAssertEqual(restored.model.layouts.count, 2)
        XCTAssertEqual(restored.model.activeIndex, 1)
        XCTAssertEqual(restored.model.layouts[0].paneList.count, 1)
        XCTAssertTrue(restored.model.layouts[1].paneList.first is BrowserPaneView,
                      "浏览器 pane 恢复到它原来的工作区")
        let frame = try XCTUnwrap(restored.window?.frame)
        let visible = try XCTUnwrap(screen?.visibleFrame)
        XCTAssertTrue(visible.insetBy(dx: -1, dy: -1).contains(frame),
                      "恢复的 frame 必须落在目标显示器的可见区内（\(frame) / \(visible)）")

        // 再存一次：这个屏幕的快照要能自洽（含 id / display / frame）
        let snapshot = restored.windowState()
        XCTAssertEqual(snapshot.id, saved.id)
        XCTAssertEqual(snapshot.activeIndex, 1)
        XCTAssertNotNil(snapshot.frame)
        XCTAssertEqual(snapshot.layouts.count, 2)
    }

    // MARK: 迁移（v2–v4 → v5）与旧档备份

    func testV4ArchiveMigratesIntoSingleWindowAndWritesBackup() throws {
        let c = try XCTUnwrap(try app.controller)
        let url = try tempStateURL()
        let pane = c.newSurface(workingDirectory: nil)
        pane.pwd = "/usr/local/quickterm-v4"
        let legacy = LegacyPersistedState(
            layouts: [.scrolling(ScrollingStrip(pane: pane, widthFactor: 0.5)), .empty],
            floatings: [[], []], activeIndex: 1)
        try JSONEncoder().encode(legacy).write(to: url, options: .atomic)

        let store = makeStore(at: url)
        let state = try XCTUnwrap(store.load())
        XCTAssertEqual(state.version, 5, "v4 读进来就是 v5")
        XCTAssertEqual(state.windows.count, 1, "旧档 = 一个屏幕")
        let window = state.windows[0]
        XCTAssertEqual(state.keyWindowID, window.id)
        XCTAssertNil(window.display, "旧档没有显示器信息 → 保持主屏居中的历史行为")
        XCTAssertNil(window.frame)
        XCTAssertFalse(window.isFullscreen)
        XCTAssertEqual(window.activeIndex, 1)
        XCTAssertEqual(window.layouts.count, 2)
        XCTAssertEqual(window.layouts[0].paneList.count, 1, "逐 pane 相等：布局里的终端还在")
        XCTAssertTrue(window.layouts[0].paneList[0] is Ghostty.SurfaceView)
        XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).contains("quickterm-v4"))

        // 首次 v5 写盘前留下旧档副本（v5 不可降级）
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.backupURL.path))
        store.snapshotOverride = { state }
        store.saveNow()
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.backupURL.path), "迁移后应有 state.pre-v5.json")
        let backup = try Data(contentsOf: store.backupURL)
        XCTAssertEqual((try JSONDecoder().decode(LegacyPersistedState.self, from: backup)).version, 4,
                       "副本是原封不动的旧档")
        XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).contains("\"windows\""), "新档是 v5 信封")
    }

    func testV2ArchiveWithoutFloatingsMigrates() throws {
        let c = try XCTUnwrap(try app.controller)
        let url = try tempStateURL()
        let pane = c.newSurface(workingDirectory: nil)
        pane.pwd = "/usr/local/quickterm-v2"
        let legacy = LegacyPersistedState(
            layouts: [.scrolling(ScrollingStrip(pane: pane, widthFactor: 0.5))],
            floatings: nil, activeIndex: 0)
        var raw = try JSONSerialization.jsonObject(with: try JSONEncoder().encode(legacy)) as! [String: Any]
        raw["version"] = 2
        raw.removeValue(forKey: "floatings")
        try JSONSerialization.data(withJSONObject: raw).write(to: url, options: .atomic)

        let state = try XCTUnwrap(makeStore(at: url).load())
        XCTAssertEqual(state.windows.count, 1)
        XCTAssertNil(state.windows[0].floatings, "v2 没有浮动层字段：缺省即可，不能解码失败")
        XCTAssertEqual(state.windows[0].layouts[0].paneList.count, 1)
        XCTAssertFalse(state.windows[0].isEmpty)
    }

    // MARK: 显示器解析与 frame 约束

    func testDisplayRefResolution() throws {
        let main = try XCTUnwrap(NSScreen.main)
        let hit = DisplayRef(screen: main)
        XCTAssertNotNil(hit)
        XCTAssertEqual(SessionStore.matchScreen(for: hit), main, "UUID 命中")

        let byName = DisplayRef(uuid: UUID().uuidString, name: main.localizedName, frame: main.frame)
        let named = NSScreen.screens.filter { $0.localizedName == main.localizedName }
        if named.count == 1 {
            XCTAssertEqual(SessionStore.matchScreen(for: byName), main, "UUID 不命中时按名称找回")
        }

        let miss = DisplayRef(uuid: UUID().uuidString, name: "QuickTerm 不存在的显示器", frame: .zero)
        XCTAssertNil(SessionStore.matchScreen(for: miss), "都不命中 → 没有匹配")
        XCTAssertEqual(SessionStore.resolveScreen(for: miss), NSScreen.main, "回退主屏，绝不丢窗口")
        XCTAssertEqual(SessionStore.resolveScreen(for: nil), NSScreen.main, "旧档没有显示器信息 → 主屏")
    }

    func testFrameIsConstrainedIntoVisibleArea() {
        let visible = CGRect(x: 0, y: 0, width: 1440, height: 900)
        // 存档时在另一台（更远/更大）显示器上
        let offscreen = SessionStore.constrain(CGRect(x: 3000, y: 1800, width: 1000, height: 700), into: visible)
        XCTAssertTrue(visible.contains(offscreen), "离屏 frame 必须被收回可见区：\(offscreen)")
        XCTAssertEqual(offscreen.size, CGSize(width: 1000, height: 700), "位置能收就不改尺寸")

        let oversized = SessionStore.constrain(CGRect(x: -500, y: -500, width: 4000, height: 3000), into: visible)
        XCTAssertEqual(oversized, visible, "比屏幕还大 → 收成整个可见区")

        let inside = CGRect(x: 100, y: 80, width: 800, height: 600)
        XCTAssertEqual(SessionStore.constrain(inside, into: visible), inside, "本来就在里面 → 原样")

        // 可见区原点不为零（外接显示器在主屏右侧）
        let right = CGRect(x: 1440, y: 0, width: 1920, height: 1080)
        let moved = SessionStore.constrain(CGRect(x: 0, y: 0, width: 800, height: 600), into: right)
        XCTAssertTrue(right.contains(moved))
    }

    // MARK: 写盘时机

    /// 连续 10 次变化只落一次盘（1.5s 防抖）
    func testDebouncedSaveWritesOnce() throws {
        let url = try tempStateURL()
        let store = makeStore(at: url)
        store.snapshotOverride = { PersistedState(windows: [WindowState(layouts: [.empty])]) }
        for _ in 0..<10 { store.scheduleSave() }
        XCTAssertEqual(store.writeCount, 0, "防抖期间不写盘")
        spin(SessionStore.debounceInterval + 0.8)
        XCTAssertEqual(store.writeCount, 1, "连续变化只写一次")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    /// 退出路径：同步写，不等防抖
    func testSaveNowWritesSynchronously() throws {
        let url = try tempStateURL()
        let store = makeStore(at: url)
        store.snapshotOverride = { PersistedState(windows: [WindowState(layouts: [.empty])]) }
        store.scheduleSave()
        store.saveNow()
        XCTAssertEqual(store.writeCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "saveNow 必须立刻落盘")
        spin(SessionStore.debounceInterval + 0.5)
        XCTAssertEqual(store.writeCount, 1, "saveNow 应取消挂起的防抖写")
    }

    /// 一个窗口都没有时绝不写盘（否则关掉最后一个屏幕会用空档覆盖用户会话）
    func testEmptySnapshotNeverOverwritesArchive() throws {
        let url = try tempStateURL()
        let store = makeStore(at: url)
        store.snapshotOverride = { PersistedState(windows: []) }
        store.saveNow()
        XCTAssertEqual(store.writeCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    // MARK: 缺档 / 损坏 → 全新开始

    func testMissingOrCorruptArchiveStartsFresh() throws {
        let url = try tempStateURL()
        XCTAssertNil(makeStore(at: url).load(), "没有存档 → 全新开始")

        try Data("这不是 JSON".utf8).write(to: url, options: .atomic)
        XCTAssertNil(makeStore(at: url).load(), "损坏存档 → 全新开始")

        try Data(#"{"version":99,"windows":[]}"#.utf8).write(to: url, options: .atomic)
        XCTAssertNil(makeStore(at: url).load(), "空窗口列表 → 全新开始")

        // 全空的窗口（没有任何 pane）不该开出一个空窗口
        let empty = PersistedState(windows: [WindowState(layouts: [.empty, .empty], floatings: [[], []])])
        try JSONEncoder().encode(empty).write(to: url, options: .atomic)
        XCTAssertNil(makeStore(at: url).load(), "全空存档 → 全新开始（与 1.5.x 一致）")
    }

    /// 一个屏幕的存档坏了不能带走别的屏幕（宽松解码）
    func testBrokenWindowDoesNotDropTheOthers() throws {
        let c = try XCTUnwrap(try app.controller)
        let url = try tempStateURL()
        let good = WindowState(layouts: [.scrolling(ScrollingStrip(pane: c.newSurface(workingDirectory: nil),
                                                                  widthFactor: 0.5))],
                               floatings: [[]], activeIndex: 0)
        let data = try JSONEncoder().encode(PersistedState(windows: [good], keyWindowID: good.id))
        var raw = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        var windows = raw["windows"] as! [[String: Any]]
        var broken = windows[0]
        broken["id"] = UUID().uuidString
        broken["layouts"] = ["这不是一个布局"]   // 坏掉的那个屏幕
        windows.append(broken)
        raw["windows"] = windows
        try JSONSerialization.data(withJSONObject: raw).write(to: url, options: .atomic)

        let state = try XCTUnwrap(makeStore(at: url).load())
        XCTAssertEqual(state.windows.count, 1, "坏窗口被丢掉，好窗口照常恢复")
        XCTAssertEqual(state.windows[0].id, good.id)
        XCTAssertEqual(state.keyWindowID, good.id)
    }

    // MARK: 更新版本的存档（降级保命）

    /// 更新版本（v6+）写的存档：本版**拒读**，且第一次写盘前原封不动留一份。
    /// 回归的是「跑一次老版本就永久截断并降级掉新版会话」——按 v5 的形状去读 v6，
    /// 本版不认识的 pane 种类会让整个窗口解码失败被丢掉，启动 1.5s 后就被写回去
    func testNewerArchiveIsRefusedAndBackedUpBeforeOverwrite() throws {
        let c = try XCTUnwrap(try app.controller)
        let url = try tempStateURL()
        let good = WindowState(
            layouts: [.scrolling(ScrollingStrip(pane: c.newSurface(workingDirectory: nil), widthFactor: 0.5))],
            floatings: [[]], activeIndex: 0)
        let goodJSON = try XCTUnwrap(String(data: try JSONEncoder().encode(good), encoding: .utf8))
        // 第二个窗口装着本版不认识的 pane 种类（未来版本才有的东西）
        let futureJSON = goodJSON
            .replacingOccurrences(of: #""kind":"terminal""#, with: #""kind":"quickterm-future-pane""#)
            .replacingOccurrences(of: good.id.uuidString, with: UUID().uuidString)
        XCTAssertNotEqual(futureJSON, goodJSON, "夹具必须真的带上一个本版不认识的 pane 种类")
        let future = PersistedState.currentVersion + 1
        let original = Data(#"{"version":\#(future),"windows":[\#(goodJSON),\#(futureJSON)]}"#.utf8)
        try original.write(to: url, options: .atomic)

        let store = makeStore(at: url)
        XCTAssertNil(store.load(), "更新版本的存档一律拒读，绝不按 v5 的形状截断它")

        // 拒读之后照常开新会话并写盘：原档必须先被完整备份
        store.snapshotOverride = { PersistedState(windows: [WindowState(layouts: [.empty])]) }
        store.saveNow()
        let backup = store.backupURL(forVersion: future)
        XCTAssertEqual(backup.lastPathComponent, "state.v\(future).json")
        XCTAssertNotEqual(backup, store.backupURL, "新档副本不能和 pre-v5 副本撞名")
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path), "被覆盖前必须留下副本")
        XCTAssertEqual(try Data(contentsOf: backup), original, "副本与原档逐字节相同")
        XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).contains(#""version":\#(PersistedState.currentVersion)"#))
    }

    // MARK: 终端 cwd 的存档

    /// shell 还没发 OSC 7（慢启动的 zsh / 一次恢复出一堆 pane）时的防抖存档：
    /// 绝不能把已知的起始目录写成 null——那正是崩溃 / 强制退出后会丢掉的东西
    func testArchivedCwdSurvivesSaveBeforeShellReportsPwd() throws {
        let c = try XCTUnwrap(try app.controller)
        let url = try tempStateURL()
        let seed = url.deletingLastPathComponent().path   // 真实存在的目录
        let store = makeStore(at: url)
        let pane = c.newSurface(workingDirectory: seed)
        XCTAssertNil(pane.pwd, "OSC 7 之前 pwd 就是 nil")
        let window = WindowState(layouts: [.scrolling(ScrollingStrip(pane: pane, widthFactor: 0.5))],
                                 floatings: [[]], activeIndex: 0)
        store.snapshotOverride = { PersistedState(windows: [window]) }
        store.saveNow()

        let json = try String(contentsOf: url, encoding: .utf8)
        // JSONEncoder 会把 "/" 转义成 "\/"：按目录名（不含分隔符）断言
        XCTAssertTrue(json.contains(url.deletingLastPathComponent().lastPathComponent),
                      "存档要用创建时的起始目录兜底")
        XCTAssertFalse(json.contains(#""pwd":null"#), "已知的 cwd 绝不能被写成 null")
        let restored = try XCTUnwrap(SessionStore.decode(Data(json.utf8)))
        let decoded = try XCTUnwrap(restored.windows[0].layouts[0].paneList.first as? Ghostty.SurfaceView)
        XCTAssertEqual(decoded.workingDirectory, seed, "复原出来的终端回到同一个目录")
    }

    /// `cd`（OSC 7）本身也要排一次存档：否则布局不动的长会话崩溃后复原的是旧目录
    func testTerminalCwdChangeSchedulesSave() throws {
        let app = try self.app
        let primary = try XCTUnwrap(app.controller)
        let store = try XCTUnwrap(app.session).sessionStore
        let screen = app.newScreen()
        defer {
            if app.controllers.contains(where: { $0 === screen }) { app.closeScreen(screen) }
            primary.window?.makeKeyAndOrderFront(nil)
            spin()
        }
        spin()
        let pane = try XCTUnwrap(screen.model.allPanes.first as? Ghostty.SurfaceView)
        let before = store.scheduleCount
        pane.pwd = "/usr/local/quickterm-cd"
        XCTAssertGreaterThan(store.scheduleCount, before, "cd 之后要排一次存档")
        let repeated = store.scheduleCount
        pane.pwd = "/usr/local/quickterm-cd"   // 多数 shell 每个提示符都发一次 OSC 7
        XCTAssertEqual(store.scheduleCount, repeated, "同一个目录重复上报不再排存档")
    }

    // MARK: 快照是纯读取

    /// 存档由防抖定时器触发，快照绝不能改动屏幕上的东西：
    /// 淡出中的 pane 只从副本里滤掉，动效照播（1.5.x 只在退出时快照，flush 无所谓）
    func testSnapshotFiltersFadingPanesWithoutCuttingTheAnimation() throws {
        let c = try XCTUnwrap(try app.controller)
        let prevAnim = c.closeAnimationEnabled
        let home = c.model.activeIndex
        let ws = c.model.layouts.count - 1
        c.model.switchTo(ws)
        defer {
            // 末位工作区必须还回去（别的用例按「空工作区」取夹具）
            for pane in c.paneList { c.closePane(pane, confirmIfNeeded: false, animated: false) }
            c.closeAnimationEnabled = prevAnim
            c.model.switchTo(home)
        }
        XCTAssertTrue(c.model.layout.isEmpty, "末位工作区应为空")
        c.closeAnimationEnabled = true
        spin(0.2)
        c.perform(.newTerminal)
        let a = try XCTUnwrap(c.paneList.first)
        spin(0.5)
        c.perform(.newTerminal)
        let b = try XCTUnwrap(c.paneList.first { $0 !== a })
        spin(0.6)

        c.closePane(b, confirmIfNeeded: false)
        XCTAssertTrue(c.model.closingPanes.contains(b.id))
        let snapshot = c.windowState()
        XCTAssertEqual(snapshot.layouts[ws].paneList.count, 1, "淡出中的 pane 不进存档")
        XCTAssertFalse(snapshot.layouts[ws].paneList.contains { $0 === b })
        XCTAssertEqual(c.paneList.count, 2, "快照不得提前结束关闭动效")
        XCTAssertTrue(c.model.closingPanes.contains(b.id), "淡出状态不被快照改动")
        spin(0.5)
        XCTAssertEqual(c.paneList.count, 1, "动效到点后照常移除")
    }

    // MARK: 信封新字段：焦点 pane 与叠放次序

    func testFocusedPaneAndStackingOrderRoundTrip() throws {
        let c = try XCTUnwrap(try app.controller)
        let pane = c.newSurface(workingDirectory: nil)
        let window = WindowState(layouts: [.scrolling(ScrollingStrip(pane: pane, widthFactor: 0.5))],
                                 floatings: [[]], activeIndex: 0, focusedPaneID: pane.id)
        let other = UUID()
        let data = try JSONEncoder().encode(
            PersistedState(windows: [window], keyWindowID: window.id, stackingOrder: [other, window.id]))
        let restored = try XCTUnwrap(SessionStore.decode(data))
        XCTAssertEqual(restored.windows[0].focusedPaneID, pane.id)
        XCTAssertEqual(restored.stackingOrder, [other, window.id])

        // 老的 v5 存档没有这两个键：缺着读，退回历史行为
        var raw = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        raw.removeValue(forKey: "stackingOrder")
        var windows = raw["windows"] as! [[String: Any]]
        windows[0].removeValue(forKey: "focusedPaneID")
        raw["windows"] = windows
        let legacy = try XCTUnwrap(SessionStore.decode(try JSONSerialization.data(withJSONObject: raw)))
        XCTAssertNil(legacy.stackingOrder)
        XCTAssertNil(legacy.windows[0].focusedPaneID)
    }

    // MARK: 一键复原的入口

    /// `restoreSession(from:)`：逐窗口建屏 + 灌档 + 置前。显示器没了的那个窗口回退主屏，
    /// 存档里的 key 屏幕最后置前
    func testRestoreSessionRebuildsEveryScreen() throws {
        let app = try self.app
        let primary = try XCTUnwrap(app.controller)
        let before = app.controllers.count
        let terminal = primary.newSurface(workingDirectory: nil)
        terminal.pwd = "/usr/local/quickterm-restore-session"
        let browser = BrowserPaneView(url: URL(string: "https://example.com/session"))
        // 屏幕 A：存档里的显示器已经不在了（必须回退主屏，绝不丢窗口）
        let a = WindowState(
            layouts: [.scrolling(ScrollingStrip(pane: terminal, widthFactor: 0.5))],
            floatings: [[]], activeIndex: 0,
            display: DisplayRef(uuid: UUID().uuidString, name: "QuickTerm 不存在的显示器", frame: .zero))
        // 屏幕 B：存档里的 key 屏幕
        let b = WindowState(layouts: [.scrolling(ScrollingStrip(pane: browser, widthFactor: 0.5))],
                            floatings: [[]], activeIndex: 0)
        let data = try JSONEncoder().encode(
            PersistedState(windows: [a, b], keyWindowID: b.id, stackingOrder: [b.id, a.id]))
        let state = try XCTUnwrap(SessionStore.decode(data))

        let restored = app.restoreSession(from: state)
        defer {
            for controller in restored where app.controllers.contains(where: { $0 === controller }) {
                app.closeScreen(controller)
            }
            primary.window?.makeKeyAndOrderFront(nil)
            spin()
        }
        spin()
        XCTAssertEqual(restored.count, 2, "存档里的每个屏幕都要回来")
        XCTAssertEqual(app.controllers.count, before + 2)
        XCTAssertEqual(restored[0].windowID, a.id)
        XCTAssertEqual(restored[1].windowID, b.id)
        XCTAssertEqual(restored[0].window?.screen, NSScreen.main, "显示器没了 → 回退主屏")
        XCTAssertEqual(restored[0].model.layouts[0].paneList.count, 1)
        XCTAssertTrue(restored[0].model.layouts[0].paneList[0] is Ghostty.SurfaceView)
        XCTAssertTrue(restored[1].model.layouts[0].paneList.first is BrowserPaneView,
                      "浏览器 pane 与它已打开的网页一起回来")
        // key 窗口在测试宿主里不保证拿得到（见 ScreenRegistryTests）：拿到了才断言落点
        if NSApp.keyWindow === restored[1].window { XCTAssertTrue(app.controller === restored[1]) }
    }

    /// 一个屏幕都建不出来（存档里的窗口全是空的）→ 兜底开一个新屏幕，绝不留下零窗口
    func testRestoreSessionFallsBackToOneScreen() throws {
        let app = try self.app
        let primary = try XCTUnwrap(app.controller)
        let before = app.controllers.count
        let restored = app.restoreSession(from: PersistedState(windows: []))
        defer {
            for controller in restored where app.controllers.contains(where: { $0 === controller }) {
                app.closeScreen(controller)
            }
            primary.window?.makeKeyAndOrderFront(nil)
            spin()
        }
        spin()
        XCTAssertEqual(restored.count, 1)
        XCTAssertEqual(app.controllers.count, before + 1)
        XCTAssertEqual(restored[0].model.allPanes.count, 1, "兜底屏幕自带一个起步终端")
    }

    // MARK: 安全线：测试宿主里的 App 存档绝不写盘

    func testAppSessionStoreNeverWritesRealArchiveUnderTests() throws {
        let store = try XCTUnwrap(try app.session).sessionStore
        XCTAssertEqual(store.url, SessionStore.defaultURL)
        store.scheduleSave()
        store.saveNow()
        spin(SessionStore.debounceInterval + 0.5)
        XCTAssertEqual(store.writeCount, 0, "测试宿主里绝不能写用户的 state.json")
    }
}
