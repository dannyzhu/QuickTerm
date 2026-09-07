import XCTest
import AppKit
@testable import QuickTerm

/// 多「屏幕」（多窗口）注册表与路由（spec v9 §1.6）。
/// 每个用例都必须把第二个屏幕关掉、key 交还第一个屏幕——否则会污染后续用例。
@MainActor
final class ScreenRegistryTests: XCTestCase {
    private var app: AppDelegate {
        get throws { try XCTUnwrap(NSApp.delegate as? AppDelegate) }
    }

    /// 跑一轮 runloop，让 SwiftUI 挂载 / 异步的注册表摘除落地
    private func spin(_ seconds: TimeInterval = 0.3) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    /// 开第二个屏幕跑一段用例，结束时一定关掉并把 key 交还第一个屏幕
    private func withSecondScreen(
        on screen: NSScreen? = NSScreen.main,
        _ body: (AppDelegate, MainWindowController, MainWindowController) throws -> Void
    ) throws {
        let app = try self.app
        let primary = try XCTUnwrap(app.screens.primary)
        let second = app.newScreen(on: screen)
        spin()
        defer {
            if app.controllers.contains(where: { $0 === second }) {
                app.closeScreen(second)
            }
            primary.window?.makeKeyAndOrderFront(nil)
            spin()
        }
        try body(app, primary, second)
    }

    // MARK: 注册表与放置

    func testNewScreenRegistersSecondWindow() throws {
        try withSecondScreen { app, primary, second in
            XCTAssertEqual(app.controllers.count, 2, "新建屏幕后注册表应有两个控制器")
            XCTAssertTrue(app.controllers.contains { $0 === primary })
            XCTAssertTrue(app.controllers.contains { $0 === second })
            XCTAssertEqual(primary.window?.title, "QuickTerm", "第一个屏幕标题必须恰好是 QuickTerm")
            XCTAssertEqual(second.window?.title, "QuickTerm 2")
            XCTAssertEqual(second.screenIndex, 1)
        }
    }

    func testNewScreenLandsOnRequestedDisplay() throws {
        let target = try XCTUnwrap(NSScreen.main)
        try withSecondScreen(on: target) { _, primary, second in
            let frame = try XCTUnwrap(second.window?.frame)
            // 允许 1pt 误差（constrainFrameRect 的取整）
            XCTAssertTrue(target.visibleFrame.insetBy(dx: -1, dy: -1).contains(frame),
                          "第二个窗口应落在目标显示器的可见区内（frame \(frame) / visible \(target.visibleFrame)）")
            if primary.window?.screen === target {
                XCTAssertNotEqual(frame.origin, primary.window?.frame.origin,
                                  "同屏已有窗口时应层叠偏移，不与第一个窗口完全重合")
            }
        }
    }

    func testScreenIndexReusesLowestFreeSlot() throws {
        let app = try self.app
        let primary = try XCTUnwrap(app.screens.primary)
        let second = app.newScreen(on: NSScreen.main)
        spin()
        XCTAssertEqual(second.screenIndex, 1)
        app.closeScreen(second)
        spin()
        let third = app.newScreen(on: NSScreen.main)
        spin()
        defer {
            app.closeScreen(third)
            primary.window?.makeKeyAndOrderFront(nil)
            spin()
        }
        XCTAssertEqual(third.screenIndex, 1, "序号复用最小空位：关掉 2 号后新建仍是 2 号")
        XCTAssertEqual(third.window?.title, "QuickTerm 2")
    }

    // MARK: 关闭与释放

    func testCloseScreenReleasesController() throws {
        let app = try self.app
        let primary = try XCTUnwrap(app.screens.primary)
        weak var weakSecond: MainWindowController?
        weak var weakPane: PaneView?
        autoreleasepool {
            let second = app.newScreen(on: NSScreen.main)
            spin()
            weakSecond = second
            weakPane = second.paneList.first
            XCTAssertEqual(app.controllers.count, 2)
            app.closeScreen(second)
        }
        spin(0.8)
        XCTAssertEqual(app.controllers.count, 1, "关闭屏幕后注册表回到 1")
        XCTAssertNil(weakSecond, "控制器必须完全释放（监视器/观察者/主题监听都已拆）")
        XCTAssertNil(weakPane, "屏幕里的 pane 随之释放（shell 进程结束）")
        primary.window?.makeKeyAndOrderFront(nil)
        spin()
    }

    func testThemeListenersAreRemovedWithTheScreen() throws {
        let app = try self.app
        let themeManager = try XCTUnwrap(app.themeManager)
        let before = themeManager.overlayListenerCount
        try withSecondScreen { _, _, _ in
            XCTAssertEqual(themeManager.overlayListenerCount, before + 1,
                           "每个屏幕自己注册一份主题监听（单闭包时代只有最后一个窗口会响应）")
        }
        spin(0.4)
        XCTAssertEqual(themeManager.overlayListenerCount, before, "屏幕关掉后监听必须摘干净")
    }

    // MARK: 路由

    func testControllerFollowsKeyWindow() throws {
        try withSecondScreen { app, primary, second in
            NSApp.activate(ignoringOtherApps: true)
            second.window?.makeKeyAndOrderFront(nil)
            spin(0.3)
            if NSApp.keyWindow === second.window {
                XCTAssertTrue(app.controller === second, "AppDelegate.controller 应是 key 窗口的控制器")
            } else {
                // 无窗口服务器焦点（后台跑用例）：至少验证回退语义
                XCTAssertTrue(app.controller === primary, "没有 key 窗口时回退到第一个屏幕")
            }
            primary.window?.makeKeyAndOrderFront(nil)
            spin(0.3)
            XCTAssertTrue(app.controller === primary)
        }
    }

    func testGhosttySurfaceLookupSpansAllScreens() throws {
        try withSecondScreen { app, _, second in
            let pane = try XCTUnwrap(second.paneList.first)
            XCTAssertTrue(app.ghosttySurface(id: pane.id) === pane,
                          "按 UUID 反查 surface 必须覆盖所有屏幕（拖放解析）")
        }
    }

    // MARK: 各屏幕的工作区互相独立

    func testWorkspacesAreIndependentPerScreen() throws {
        try withSecondScreen { _, primary, second in
            primary.model.switchTo(0)
            let primaryBefore = primary.paneList.count
            let secondBefore = second.paneList.count
            second.perform(.newTerminal)
            XCTAssertEqual(second.paneList.count, secondBefore + 1, "新 pane 落在第二个屏幕")
            XCTAssertEqual(primary.paneList.count, primaryBefore, "第一个屏幕的工作区不受影响")
            XCTAssertFalse(primary.model.layouts.contains { layout in
                layout.paneList.contains { second.paneList.contains($0) }
            }, "两个屏幕不共享任何 pane")
            if let pane = second.focusedPane {
                second.closePane(pane, confirmIfNeeded: false, animated: false)
            }
        }
    }

    // MARK: 通知串扰（三个 object: nil 的观察者）

    func testEqualizeNotificationOnlyAffectsOwningScreen() throws {
        try withSecondScreen { _, primary, second in
            primary.perform(.equalize)   // 先把 A 摆成已等分：通知落到 A 上也不会改变它
            second.perform(.newTerminal)
            guard case .scrolling(var strip) = second.model.layout, strip.columns.count >= 2 else {
                return XCTFail("第二个屏幕应为两列 scrolling 布局")
            }
            strip.columns[0].widthFactor = 0.8
            second.model.layout = .scrolling(strip)

            let paneA = try XCTUnwrap(primary.paneList.first)
            NotificationCenter.default.post(
                name: Ghostty.Notification.didEqualizeSplits, object: paneA)
            guard case .scrolling(let afterForeign) = second.model.layout else {
                return XCTFail("布局不应改变类型")
            }
            XCTAssertEqual(afterForeign.columns[0].widthFactor, 0.8, accuracy: 0.001,
                           "A 屏幕的等分通知不得改动 B 屏幕的列宽")

            let paneB = try XCTUnwrap(second.paneList.first)
            NotificationCenter.default.post(
                name: Ghostty.Notification.didEqualizeSplits, object: paneB)
            guard case .scrolling(let afterOwn) = second.model.layout else {
                return XCTFail("布局不应改变类型")
            }
            XCTAssertEqual(afterOwn.columns[0].widthFactor, second.columnFactor, accuracy: 0.001,
                           "自己屏幕的等分通知照常生效")
            for pane in second.paneList.dropFirst() {
                second.closePane(pane, confirmIfNeeded: false, animated: false)
            }
        }
    }

    // MARK: 跨窗口拖放明确拒绝

    func testCrossWindowDropIsRejected() throws {
        try withSecondScreen { _, primary, second in
            let paneA = try XCTUnwrap(primary.paneList.first)
            let paneB = try XCTUnwrap(second.paneList.first)
            try XCTSkipIf(paneA.window == nil || paneB.window == nil, "pane 尚未挂载到窗口")
            PaneDragState.shared.begin(pane: paneA)
            defer { PaneDragState.shared.end() }
            XCTAssertFalse(PaneDragState.shared.allowsDrop(on: paneB),
                           "跨窗口拖放必须明确拒绝（禁止光标），不是静默无操作")
            XCTAssertTrue(PaneDragState.shared.allowsDrop(on: paneA), "同窗口拖放照常")
        }
    }

    func testNoDragSessionAllowsEveryDrop() throws {
        let app = try self.app
        let primary = try XCTUnwrap(app.screens.primary)
        PaneDragState.shared.end()
        let pane = try XCTUnwrap(primary.paneList.first)
        XCTAssertTrue(PaneDragState.shared.allowsDrop(on: pane), "没有进行中的拖拽会话时不拦截")
    }

    // MARK: 扩展宿主聚合

    func testExtensionHostAggregatesBrowserPanesAcrossScreens() throws {
        try withSecondScreen { app, primary, second in
            let host = try XCTUnwrap(BrowserExtensionManager.shared.host)
            XCTAssertTrue(host is AppBrowserExtensionHost, "扩展宿主应是 App 级聚合器，不是某个窗口")
            let before = host.browserPanes.count
            let url = try XCTUnwrap(URL(string: "about:blank"))
            let a = try XCTUnwrap(primary.openBrowserPane(url: url, from: primary.focusedPane))
            let b = try XCTUnwrap(second.openBrowserPane(url: url, from: second.focusedPane))
            defer {
                primary.closePane(a, confirmIfNeeded: false, animated: false)
                second.closePane(b, confirmIfNeeded: false, animated: false)
            }
            XCTAssertEqual(host.browserPanes.count, before + 2,
                           "两个屏幕各开一个浏览器 pane，宿主应看到两个")
            XCTAssertTrue(host.browserPanes.contains { $0 === a })
            XCTAssertTrue(host.browserPanes.contains { $0 === b })
        }
    }

    // MARK: 配置重载 fan-out（监听归 AppDelegate，设置落到每个屏幕）

    func testConfigAppliesToEveryScreen() throws {
        try withSecondScreen { app, primary, second in
            let real = ConfigStore.load()
            var bumped = real
            bumped.workspaces = 7
            app.applyConfigToAllScreens(bumped)   // AppDelegate 的 fan-out 本身就是被测对象
            XCTAssertEqual(primary.model.layouts.count, 7)
            XCTAssertEqual(second.model.layouts.count, 7)
            app.applyConfigToAllScreens(real)
            XCTAssertEqual(second.model.layouts.count, real.workspaces)
            XCTAssertEqual(primary.model.layouts.count, real.workspaces)
        }
    }

    // MARK: 关屏幕的收尾（teardown 走的不是 closePane 那条路）

    /// 非原生全屏的 presentationOptions 是进程级的：关掉全屏中的屏幕必须还回去，
    /// 否则剩下的屏幕会一直没有 Dock 与菜单栏，而它们自己并不知道"在全屏"
    func testClosingFullscreenScreenReleasesPresentationOptions() throws {
        try XCTSkipIf(NSScreen.main == nil, "没有显示器时非原生全屏是 no-op")
        let app = try self.app
        let primary = try XCTUnwrap(app.screens.primary)
        defer {
            NSApp.presentationOptions = []
            primary.window?.makeKeyAndOrderFront(nil)
            spin()
        }
        let second = app.newScreen(on: NSScreen.main)
        spin()
        second.perform(.toggleFullscreen)
        XCTAssertFalse(NSApp.presentationOptions.isEmpty, "非原生全屏会隐藏 Dock 与菜单栏")
        XCTAssertTrue(app.closeScreen(second))
        XCTAssertTrue(NSApp.presentationOptions.isEmpty,
                      "关屏幕必须把本窗口申请的进程级 presentationOptions 还回去")
        spin(0.5)
    }

    /// 关屏幕清空模型走的是 teardown，不是 closePane：浏览器 pane 仍要收尾
    /// （取消进行中的下载、向扩展上报"窗口关了"）
    func testCloseScreenRunsPaneWillCloseForBrowserPanes() throws {
        let app = try self.app
        let primary = try XCTUnwrap(app.screens.primary)
        let second = app.newScreen(on: NSScreen.main)
        spin()
        defer {
            if app.controllers.contains(where: { $0 === second }) { app.closeScreen(second) }
            primary.window?.makeKeyAndOrderFront(nil)
            spin()
        }
        let url = try XCTUnwrap(URL(string: "about:blank"))
        let pane = try XCTUnwrap(second.openBrowserPane(url: url, from: second.focusedPane))
        var cancelled = 0
        let active = BrowserDownloadItem(filename: "big.iso", progress: Progress(totalUnitCount: 100)) {
            cancelled += 1
        }
        pane.downloads.add(active)
        XCTAssertTrue(app.closeScreen(second))
        XCTAssertEqual(cancelled, 1, "关屏幕时进行中的下载必须被取消，不留没人管的传输")
        XCTAssertEqual(active.state, .cancelled)
        spin(0.5)
    }

    // MARK: 扩展宿主的焦点归属

    /// `focusedBrowserPane` 取当前（key）屏幕的：非 key 窗口的 first responder 只是残留焦点，
    /// 不能把选项页 / 新标签开到另一台显示器上去
    func testFocusedBrowserPaneComesFromTheCurrentScreen() throws {
        try withSecondScreen { app, primary, second in
            let host = try XCTUnwrap(BrowserExtensionManager.shared.host as? AppBrowserExtensionHost)
            let url = try XCTUnwrap(URL(string: "about:blank"))
            let a = try XCTUnwrap(primary.openBrowserPane(url: url, from: primary.focusedPane))
            let b = try XCTUnwrap(second.openBrowserPane(url: url, from: second.focusedPane))
            defer {
                primary.closePane(a, confirmIfNeeded: false, animated: false)
                second.closePane(b, confirmIfNeeded: false, animated: false)
            }
            spin(0.8)   // 等 openBrowserPane 的延时补焦点跑完，免得它把 FR 抢回去
            // 另一个屏幕的浏览器 pane 持有它自己窗口的 first responder（非 key 窗口的残留焦点）
            second.window?.makeFirstResponder(b)
            // 当前屏幕的焦点落在终端上
            if let terminal = primary.paneList.first(where: { !($0 is BrowserPaneView) }) {
                primary.window?.makeFirstResponder(terminal)
            }
            primary.window?.makeKeyAndOrderFront(nil)
            spin(0.3)
            let current = try XCTUnwrap(app.screens.current)
            let focused = try XCTUnwrap(host.focusedBrowserPane)
            XCTAssertTrue(current.browserPanes.contains { $0 === focused },
                          "焦点浏览器 pane 必须来自当前屏幕，而不是另一台显示器上的残留 FR")
            if current === primary {
                XCTAssertTrue(focused === a, "key 屏幕焦点在终端上时取它自己最近激活的浏览器 pane")
            }
        }
    }

    // MARK: 全屏中搬显示器

    /// 全屏中搬到另一台显示器：退出全屏要落在新显示器上，不能跳回原显示器
    func testMoveWhileFullscreenKeepsRestoreFrameOnNewDisplay() throws {
        let all = NSScreen.screens
        try XCTSkipIf(all.count < 2, "只有一台显示器，跨显示器搬迁无从验证")
        let app = try self.app
        let primary = try XCTUnwrap(app.screens.primary)
        defer {
            NSApp.presentationOptions = []
            primary.window?.makeKeyAndOrderFront(nil)
            spin()
        }
        let start = try XCTUnwrap(all.first)
        let second = app.newScreen(on: start)
        spin()
        let target = try XCTUnwrap(all.first { $0 !== second.window?.screen })
        second.perform(.toggleFullscreen)
        second.move(to: target)
        spin(0.2)
        second.perform(.toggleFullscreen)   // 退出全屏
        spin(0.2)
        let frame = try XCTUnwrap(second.window?.frame)
        XCTAssertTrue(target.visibleFrame.insetBy(dx: -1, dy: -1).contains(frame),
                      "退出全屏后的窗口必须留在搬过去的那台显示器上（frame \(frame)）")
        XCTAssertTrue(app.closeScreen(second))
        spin(0.5)
    }
}
