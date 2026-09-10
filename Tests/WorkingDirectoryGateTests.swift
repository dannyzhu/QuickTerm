import XCTest
import AppKit
@testable import QuickTerm

/// 启动挂死的回归线（2026-09-11）：
/// 存档里的终端 cwd 落在 TCC 保护目录（~/Desktop ~/Documents ~/Downloads）时，
/// 未获授权的二进制被 LaunchServices 拉起来后，libghostty 在 `ghostty_surface_new` 里的
/// `openat` 会**永远**不返回——整个 app 卡死在 `applicationDidFinishLaunching`，一个窗口都没有。
///
/// 这里用「永不应答的探针」把那种环境搬进用例：复原必须照常建出每一个 pane 并及时返回。
/// （TCC 本身没法在单元测试里模拟，`open` 启动那一半是人工检查，见 docs/manual-launch-check.md）
@MainActor
final class WorkingDirectoryGateTests: XCTestCase {
    private var app: AppDelegate {
        get throws { try XCTUnwrap(NSApp.delegate as? AppDelegate) }
    }

    private var tempDirs: [URL] = []
    private var registries: [ScreenRegistry] = []
    /// 本用例里自建 AppSession 会踩到的进程级全局（`apply` 会把它们改成默认值）
    private var savedBrowserSettings: BrowserPaneView.Settings?
    private var savedBrowserExtensions: Bool?
    private var savedSocketPath: String?
    private var restoreGlobals = false

    override func tearDown() {
        WorkingDirectoryGate.resetForTesting()
        for dir in tempDirs { try? FileManager.default.removeItem(at: dir) }
        tempDirs.removeAll()
        registries.removeAll()
        if restoreGlobals {
            // 自建的 AppSession 会把事件总线接到它自己那个（马上就要释放的）注册表上，
            // 总线是弱引用 → 不接回来的话，本类之后的每一个用例看到的都是一条死总线
            if let app = NSApp.delegate as? AppDelegate {
                ControlEventBus.shared.attach(screens: app.screens)
            }
            if let savedBrowserSettings { BrowserPaneView.settings = savedBrowserSettings }
            if let savedBrowserExtensions { BrowserExtensionManager.shared.isEnabled = savedBrowserExtensions }
            ControlEnvironment.socketPath = savedSocketPath
            restoreGlobals = false
        }
        super.tearDown()
    }

    /// 一个 pane 在存档里长什么样（直接拼 JSON：解码就是启动复原真正走的那一段）
    private func paneJSON(pwd: String?, uuid: UUID = UUID()) -> Data {
        let pwdField = pwd.map { "\"\($0)\"" } ?? "null"
        return Data("""
        {"pwd": \(pwdField), "uuid": "\(uuid.uuidString)", "title": "t", "isUserSetTitle": false}
        """.utf8)
    }

    /// 从一份 pane 存档里读出 cwd
    private func archivedPwd(_ data: Data) throws -> String? {
        struct Probe: Decodable { let pwd: String? }
        return try JSONDecoder().decode(Probe.self, from: data).pwd
    }

    /// 探针永不应答（= 未获授权的二进制被 LaunchServices 拉起来时的 TCC 行为）
    private func denyProtectedRoots() {
        WorkingDirectoryGate.resetForTesting()
        WorkingDirectoryGate.deadline = 0.05
        WorkingDirectoryGate.prober = { _, deadline in
            Thread.sleep(forTimeInterval: deadline)
            return false
        }
    }

    private func spin(_ seconds: TimeInterval = 0.3) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private var home: String { NSHomeDirectory() }

    // MARK: 守卫本身

    /// 只有三个受保护根目录需要探测，其余路径（含 ~ 自身、~/Library、/tmp）原样放行
    func testProtectedRootClassification() {
        let home = "/Users/probe"
        XCTAssertEqual(WorkingDirectoryGate.protectedRoot(for: "\(home)/Documents", home: home),
                       "\(home)/Documents")
        XCTAssertEqual(WorkingDirectoryGate.protectedRoot(for: "\(home)/Documents/a/b", home: home),
                       "\(home)/Documents")
        XCTAssertEqual(WorkingDirectoryGate.protectedRoot(for: "\(home)/Desktop/x", home: home),
                       "\(home)/Desktop")
        XCTAssertEqual(WorkingDirectoryGate.protectedRoot(for: "\(home)/Downloads", home: home),
                       "\(home)/Downloads")
        XCTAssertNil(WorkingDirectoryGate.protectedRoot(for: home, home: home))
        XCTAssertNil(WorkingDirectoryGate.protectedRoot(for: "\(home)/Library/Caches", home: home))
        XCTAssertNil(WorkingDirectoryGate.protectedRoot(for: "/tmp", home: home))
        XCTAssertNil(WorkingDirectoryGate.protectedRoot(for: "/usr/local", home: home),
                     "前缀相似但不是子目录：Documents2 之类不能误判")
        XCTAssertNil(WorkingDirectoryGate.protectedRoot(for: "\(home)/Documents2", home: home))
    }

    /// 探不通 → 返回 nil（= 交给引擎的默认目录），且每个根目录只探一次
    func testUnansweredProbeFallsBackAndIsMemoised() {
        var probed: [String] = []
        WorkingDirectoryGate.resetForTesting()
        WorkingDirectoryGate.deadline = 0.05
        WorkingDirectoryGate.prober = { root, deadline in
            probed.append(root)
            Thread.sleep(forTimeInterval: deadline)   // 永不应答：等到超时
            return false
        }
        XCTAssertNil(WorkingDirectoryGate.usable("\(home)/Documents/quickterm"))
        XCTAssertNil(WorkingDirectoryGate.usable("\(home)/Documents/another/deep/path"))
        XCTAssertEqual(probed, ["\(home)/Documents"], "同一个根目录只付一次探测代价")

        // 放行的路径根本不探
        XCTAssertEqual(WorkingDirectoryGate.usable("/tmp/x"), "/tmp/x")
        XCTAssertNil(WorkingDirectoryGate.usable(nil))
        XCTAssertEqual(probed.count, 1)
    }

    /// 探得通 → 原样放行（发布版有授权时就是这一条，行为与修复前完全一致）
    func testAnsweredProbePassesThrough() {
        WorkingDirectoryGate.resetForTesting()
        WorkingDirectoryGate.prober = { _, _ in true }
        let path = "\(home)/Documents/quickterm"
        XCTAssertEqual(WorkingDirectoryGate.usable(path), path)
    }

    /// 默认探针在能打开的目录上是即时的（拿 /tmp 当基准，不碰受保护目录）
    func testDefaultProberOpensReachableDirectory() {
        XCTAssertTrue(WorkingDirectoryGate.probeByOpening("/tmp", 1.0))
        XCTAssertFalse(WorkingDirectoryGate.probeByOpening("/quickterm-no-such-dir", 1.0))
    }

    // MARK: 真实复原路径（这条才是当初漏掉的覆盖）

    /// 一份「像真的」的存档——两块屏幕、各 5 个工作区、多个终端（cwd 全在 ~/Documents 下）、
    /// 一个带多标签的浏览器 pane——在探针永不应答的环境里复原：
    /// 每个 pane 都要建出来，而且整段必须在超时的量级内返回（修复前是永远不返回）
    func testRestoreWithUnansweredProbeStillBuildsEveryPane() throws {
        let app = try self.app
        let primary = try XCTUnwrap(app.controller)
        let docs = "\(home)/Documents"

        // 存档：屏幕 A = 3 个终端（两个平铺 + 一个浮动），屏幕 B = 1 个终端 + 1 个三标签浏览器
        var terminals: [Ghostty.SurfaceView] = []
        func terminal(_ suffix: String) -> Ghostty.SurfaceView {
            let pane = primary.newSurface(workingDirectory: nil)
            pane.pwd = "\(docs)/\(suffix)"
            terminals.append(pane)
            return pane
        }
        let a1 = terminal("workspace/quickterm")
        let a2 = terminal("notes")
        let aFloat = terminal("scratch")
        let windowA = WindowState(
            layouts: [.scrolling(ScrollingStrip(pane: a1, widthFactor: 0.5)),
                      .scrolling(ScrollingStrip(pane: a2, widthFactor: 0.5)),
                      .empty, .empty, .empty],
            floatings: [[FloatingPane(pane: aFloat,
                                      rect: CGRect(x: 0.1, y: 0.1, width: 0.4, height: 0.4))],
                        [], [], [], []],
            activeIndex: 0, visibleColumns: 2,
            display: DisplayRef(screen: NSScreen.main),
            frame: CGRect(x: 40, y: 60, width: 900, height: 600))

        let b1 = terminal("workspace/other")
        let browser = BrowserPaneView(url: URL(string: "https://example.com/tab0"))
        browser.newTab(url: URL(string: "https://example.com/tab1"))
        browser.newTab(url: URL(string: "https://example.com/tab2"))
        browser.selectTab(at: 1)
        let windowB = WindowState(
            layouts: [.scrolling(ScrollingStrip(pane: b1, widthFactor: 0.5)),
                      .scrolling(ScrollingStrip(pane: browser, widthFactor: 0.5)),
                      .empty, .empty, .empty],
            floatings: [[], [], [], [], []], activeIndex: 1,
            frame: CGRect(x: 10, y: 20, width: 800, height: 500))

        let data = try JSONEncoder().encode(
            PersistedState(windows: [windowA, windowB], keyWindowID: windowB.id,
                           stackingOrder: [windowB.id, windowA.id]))
        for pane in terminals { pane.removeFromSuperview() }

        // TCC 不应答的环境。注意闸门是在**解码**里付代价的：`SessionStore.decode` 就已经
        // 把每个 pane 真的构造出来了（终端 = 起一个 shell），这正是启动挂死的那一段，
        // 所以桩必须在 decode 之前装好，计时也要把 decode 括进去
        var probeCount = 0
        WorkingDirectoryGate.resetForTesting()
        WorkingDirectoryGate.deadline = 0.05
        WorkingDirectoryGate.prober = { _, deadline in
            probeCount += 1
            Thread.sleep(forTimeInterval: deadline)
            return false
        }

        // 真实复原就是从 JSON 来的：走一整轮解码，pane 是重新构造出来的那一套
        let started = Date()
        let state = try XCTUnwrap(SessionStore.decode(data))
        let restored = app.restoreSession(from: state)
        let elapsed = Date().timeIntervalSince(started)
        defer {
            for controller in restored where app.controllers.contains(where: { $0 === controller }) {
                app.closeScreen(controller)
            }
            primary.window?.makeKeyAndOrderFront(nil)
            spin()
        }
        spin()

        XCTAssertEqual(restored.count, 2, "两块屏幕都要回来")
        XCTAssertEqual(restored[0].model.allPanes.count, 3, "屏幕 A：两个平铺 + 一个浮动终端")
        XCTAssertEqual(restored[1].model.allPanes.count, 2, "屏幕 B：一个终端 + 一个浏览器")
        XCTAssertTrue(restored[0].model.layouts[0].paneList.first is Ghostty.SurfaceView)
        let decodedBrowser = try XCTUnwrap(
            restored[1].model.layouts[1].paneList.first as? BrowserPaneView)
        XCTAssertEqual(decodedBrowser.tabs.count, 3, "浏览器 pane 的标签一个不少")
        XCTAssertEqual(decodedBrowser.activeTabIndex, 1)
        XCTAssertEqual(probeCount, 1, "四个终端共用一次 ~/Documents 探测")
        XCTAssertLessThan(elapsed, 5, "复原必须及时返回——修复前这里是永远不返回")
    }

    /// 复原期间绝不写盘：半个模型落地会把用户的会话截断掉
    func testNoSaveLandsWhileRestoring() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("quickterm-gate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDirs.append(dir)
        let url = dir.appendingPathComponent("state.json")
        XCTAssertNotEqual(url, SessionStore.defaultURL)
        let registry = ScreenRegistry()
        registries.append(registry)
        let store = SessionStore(screens: registry, url: url)
        store.snapshotOverride = { PersistedState(windows: [WindowState(layouts: [.empty],
                                                                        floatings: [[]],
                                                                        activeIndex: 0)]) }

        store.beginRestore()
        store.scheduleSave()
        store.saveNow()
        spin(SessionStore.debounceInterval + 0.4)
        XCTAssertEqual(store.writeCount, 0, "复原期间一次都不许落盘")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))

        store.endRestore()
        store.saveNow()
        XCTAssertEqual(store.writeCount, 1, "复原结束后照常写盘")
    }

    // MARK: 被挡下来的目录不能污染存档

    /// TCC 挡下来之后 shell 起在引擎的默认目录（家目录），几毫秒后 OSC 7 就把它报回来。
    /// 那个值**绝不能**写进存档——否则用户存的 ~/Documents 在第一次防抖存档（或退出时的
    /// `saveNow`）就被改写成家目录，而且再也找不回来了
    func testDeniedWorkingDirectorySurvivesTheOSC7Fallback() throws {
        denyProtectedRoots()
        let archived = "\(home)/Documents/quickterm"
        let pane = try JSONDecoder().decode(Ghostty.SurfaceView.self, from: paneJSON(pwd: archived))
        defer { pane.removeFromSuperview() }

        // shell 报回引擎的回退目录
        pane.pwd = home
        XCTAssertEqual(try archivedPwd(JSONEncoder().encode(pane)), archived,
                       "被挡下来的那次，存档里必须还是用户自己的目录")
        // 同一个回退目录再报几次（每个提示符都会发一次）也不能改变结论
        pane.pwd = home
        XCTAssertEqual(try archivedPwd(JSONEncoder().encode(pane)), archived)

        // 用户真的 cd 走了 → 从这一刻起照常存实际位置
        pane.pwd = "/tmp"
        XCTAssertEqual(try archivedPwd(JSONEncoder().encode(pane)), "/tmp",
                       "真正的 cd 必须照常入档，否则这个 pane 就永远钉在旧目录上了")
    }

    /// 有授权时（发布版 / 已授权的二进制）行为完全不变：存的就是 shell 报回来的实际位置
    func testGrantedWorkingDirectoryStillPersistsTheLivePwd() throws {
        WorkingDirectoryGate.resetForTesting()
        WorkingDirectoryGate.prober = { _, _ in true }
        let archived = "\(home)/Documents/quickterm"
        let pane = try JSONDecoder().decode(Ghostty.SurfaceView.self, from: paneJSON(pwd: archived))
        defer { pane.removeFromSuperview() }
        pane.pwd = home
        XCTAssertEqual(try archivedPwd(JSONEncoder().encode(pane)), home)
    }

    /// 超时之后那次 `open` 才成功（授权窗一直开着，用户过一会儿才点「允许」）：
    /// 缓存要改回可用，之后新建的 pane 就该拿到真实目录。超时 ≠ 拒绝
    func testLateProbeSuccessReopensTheRoot() {
        denyProtectedRoots()
        let root = "\(home)/Documents"
        XCTAssertNil(WorkingDirectoryGate.usable("\(root)/x"), "先记成不可用")
        WorkingDirectoryGate.noteLateSuccess(root)   // 探测线程晚一步回来了
        XCTAssertEqual(WorkingDirectoryGate.usable("\(root)/x"), "\(root)/x",
                       "晚到的成功要把这个根目录改回可用")
    }

    // MARK: 上一次会话的副本

    /// 本进程第一次写盘前留一份上一次会话的副本：一次坏掉的启动不能把用户的会话变成绝笔
    func testPreviousSessionArchiveIsKeptBeforeFirstWrite() throws {
        let dir = try makeTempDir()
        let url = dir.appendingPathComponent("state.json")
        let registry = ScreenRegistry()
        registries.append(registry)
        let store = SessionStore(screens: registry, url: url)
        let old = Data(#"{"version":5,"windows":[]}"#.utf8)
        try old.write(to: url)
        store.snapshotOverride = { PersistedState(windows: [WindowState(layouts: [.empty],
                                                                        floatings: [[]],
                                                                        activeIndex: 0)]) }

        store.saveNow()
        XCTAssertEqual(try Data(contentsOf: store.previousSessionURL), old,
                       "第一次写盘前，盘上那份要原样留一份")
        XCTAssertNotEqual(try Data(contentsOf: url), old)

        store.saveNow()
        XCTAssertEqual(try Data(contentsOf: store.previousSessionURL), old,
                       "同一次会话的续写不能把那份副本盖掉")
    }

    // MARK: 控制面环境（复原出来的 pane 也必须有）

    /// socket **必须**在复原之前就绑好：环境变量是 spawn 那一刻烤进 pane 的，
    /// 晚绑一步，整个会话里的终端就都没有 QUICKTERM_SOCKET / TOKEN / PANE_TOKEN 了
    /// （`input send-text` 写自己那个 pane 会开始弹确认框；带 QUICKTERM_CONTROL_SOCKET
    /// 起的第二个实例，它 pane 里的 CLI 会去驱动用户那台真正的 QuickTerm）
    func testControlSocketIsBoundBeforeRestoreSoPanesInheritIt() throws {
        let dir = try makeTempDir()
        // socket 路径必须装得进 sun_path 的 104 字节（与 ControlServerTests 同一条线）
        let sock = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("qtg-\(UUID().uuidString.prefix(8)).sock")
        try XCTSkipUnless(ControlPaths.fits(sock), "临时目录太长，装不进 sun_path 104 字节")
        defer { try? FileManager.default.removeItem(atPath: sock) }
        let registry = ScreenRegistry()
        registries.append(registry)
        savedBrowserSettings = BrowserPaneView.settings
        savedBrowserExtensions = BrowserExtensionManager.shared.isEnabled
        savedSocketPath = ControlEnvironment.socketPath
        restoreGlobals = true
        let session = AppSession(screens: registry, themeManager: ThemeManager(),
                                 stateURL: dir.appendingPathComponent("state.json"),
                                 controlSocketPath: sock)
        defer { session.controlServer.stop() }

        // 这一行就是 `AppDelegate` 里 `loadInitialConfig()` 做的那一半——它跑在复原**之前**
        session.applyGlobalConfig(ConfigStore.Settings())
        XCTAssertTrue(session.controlServer.isListening, "复原之前 socket 就该绑好")
        XCTAssertEqual(ControlEnvironment.socketPath, sock)

        // 这一刻解码出来的 pane（= 启动复原建出来的那批）必须带齐控制面环境
        let paneID = UUID()
        let pane = try JSONDecoder().decode(Ghostty.SurfaceView.self,
                                            from: paneJSON(pwd: "/tmp", uuid: paneID))
        defer { pane.removeFromSuperview() }
        XCTAssertEqual(pane.initialEnvironment[ControlProtocol.Env.socket], sock)
        XCTAssertEqual(pane.initialEnvironment[ControlProtocol.Env.token], ControlEnvironment.token)
        XCTAssertEqual(pane.initialEnvironment[ControlProtocol.Env.paneToken],
                       ControlEnvironment.paneToken(for: paneID),
                       "自写免确认唯一的依据：每 pane 一枚的来源标记")
        XCTAssertEqual(pane.initialEnvironment[ControlProtocol.Env.pane], paneID.uuidString)
    }

    private func makeTempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("quickterm-gate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDirs.append(dir)
        return dir
    }
}
