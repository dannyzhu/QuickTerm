import XCTest
import AppKit
@testable import QuickTerm

/// 进程级会话（spec v9 §2）：配置重载的全局/按窗口拆分、共享的键位表与系统状态服务、
/// 按窗口引用计数的非原生全屏 presentationOptions、混合 DPI 下的 surface 缩放。
/// 每个用例都必须把多开的屏幕关掉、key 交还第一个屏幕——否则会污染后续用例。
@MainActor
final class AppSessionTests: XCTestCase {
    private var app: AppDelegate {
        get throws { try XCTUnwrap(NSApp.delegate as? AppDelegate) }
    }

    private func spin(_ seconds: TimeInterval = 0.3) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private func withSecondScreen(
        _ body: (AppDelegate, AppSession, MainWindowController, MainWindowController) throws -> Void
    ) throws {
        let app = try self.app
        let session = try XCTUnwrap(app.session)
        let primary = try XCTUnwrap(app.screens.primary)
        let second = app.newScreen(on: NSScreen.main)
        spin()
        defer {
            if app.controllers.contains(where: { $0 === second }) { app.closeScreen(second) }
            primary.window?.makeKeyAndOrderFront(nil)
            spin()
        }
        try body(app, session, primary, second)
    }

    // MARK: 配置重载：全局部分只做一次，窗口部分每屏一次

    func testGlobalConfigAppliesOncePerReloadWhileEveryScreenUpdates() throws {
        try withSecondScreen { app, session, primary, second in
            let real = ConfigStore.load()
            defer { app.applyConfigToAllScreens(real) }
            var bumped = real
            bumped.workspaces = 7
            let before = session.globalConfigApplyCount
            app.applyConfigToAllScreens(bumped)
            XCTAssertEqual(session.globalConfigApplyCount, before + 1,
                           "一次重载不论几个屏幕，全局部分（键位表 / 引擎 overlay / 浏览器全局设置）只做一次")
            XCTAssertEqual(primary.model.layouts.count, 7, "窗口部分要落到第一个屏幕")
            XCTAssertEqual(second.model.layouts.count, 7, "窗口部分也要落到第二个屏幕")
            XCTAssertEqual(session.settings.workspaces, 7, "会话记住最近一次生效的配置")
        }
    }

    /// 新开的屏幕直接用会话里那份配置，不再自己读盘 / 自己建键位表
    func testNewScreenPicksUpSessionSettingsWithoutReloadingFromDisk() throws {
        let app = try self.app
        let session = try XCTUnwrap(app.session)
        let primary = try XCTUnwrap(app.screens.primary)
        let real = ConfigStore.load()
        var bumped = real
        bumped.workspaces = 8
        app.applyConfigToAllScreens(bumped)
        let afterApply = session.globalConfigApplyCount
        let second = app.newScreen(on: NSScreen.main)
        spin()
        defer {
            app.closeScreen(second)
            app.applyConfigToAllScreens(real)
            primary.window?.makeKeyAndOrderFront(nil)
            spin()
        }
        XCTAssertEqual(second.model.layouts.count, 8, "新屏幕按会话里的配置起步")
        XCTAssertEqual(session.globalConfigApplyCount, afterApply,
                       "建屏幕不该再跑一遍全局配置（否则每开一个窗口就重写一次引擎 overlay）")
    }

    // MARK: 共享的进程级服务

    func testScreensShareOneStatsServiceAndOneKeybindingMap() throws {
        try withSecondScreen { app, session, primary, second in
            XCTAssertTrue(primary.stats === second.stats,
                          "系统状态服务全进程只该有一个（每屏一个 = N 份 2s 轮询 + N 个 NWPathMonitor）")
            XCTAssertTrue(primary.stats === session.stats)

            let real = ConfigStore.load()
            defer { app.applyConfigToAllScreens(real) }
            var bumped = real
            bumped.overrides[.newTerminal] = KeyCombo(key: "y", [.command, .shift])
            let before = session.globalConfigApplyCount
            app.applyConfigToAllScreens(bumped)
            XCTAssertEqual(session.globalConfigApplyCount, before + 1, "键位表由会话统一重建一次")
            for (name, controller) in [("第一个", primary), ("第二个", second)] {
                XCTAssertEqual(controller.keybindings.action(key: "y", modifiers: [.command, .shift])?.action,
                               .newTerminal, "\(name)屏幕读的是会话里那份键位表")
                XCTAssertNil(controller.keybindings.action(key: "return", modifiers: .command),
                             "\(name)屏幕不该留着自己那份旧表")
            }
        }
    }

    // MARK: 非原生全屏：按窗口的 savedFrame + 引用计数的 presentationOptions

    func testFullscreenPresentationOptionsAreRefCountedPerScreen() throws {
        try XCTSkipIf(NSScreen.main == nil, "没有显示器时非原生全屏是 no-op")
        let app = try self.app
        let session = try XCTUnwrap(app.session)
        let primary = try XCTUnwrap(app.screens.primary)
        let a = app.newScreen(on: NSScreen.main)
        spin()
        let b = app.newScreen(on: NSScreen.main)
        spin()
        defer {
            for controller in [a, b] where app.controllers.contains(where: { $0 === controller }) {
                app.closeScreen(controller)
            }
            NSApp.presentationOptions = []
            primary.window?.makeKeyAndOrderFront(nil)
            spin()
        }

        a.perform(.toggleFullscreen)
        XCTAssertTrue(a.isSimpleFullscreen)
        XCTAssertTrue(NSApp.presentationOptions.contains(.autoHideMenuBar), "A 全屏 → 藏菜单栏")

        b.perform(.toggleFullscreen)
        XCTAssertEqual(session.fullscreenScreenCount, 2)
        // 模拟 AppKit 在窗口切换时改写 presentationOptions：B 成为 key 时必须按账本扳回来。
        // 直接调委托方法而不是靠 makeKeyAndOrderFront——测试宿主里拿不拿得到 key 不保证
        // （见 ScreenRegistryTests 里的 key 判断），靠真实 key 切换会 flaky。
        // 这里绕过 acquire/release 直接改选项，不动 GhosttyEmbed 那份计数，后面的还账仍然配平
        NSApp.presentationOptions = []
        b.windowDidBecomeKey(Foundation.Notification(name: NSWindow.didBecomeKeyNotification, object: b.window))
        XCTAssertTrue(NSApp.presentationOptions.contains(.autoHideMenuBar),
                      "还有屏幕在全屏 → key 切换时必须把菜单栏重新藏起来")
        XCTAssertTrue(NSApp.presentationOptions.contains(.autoHideDock),
                      "还有屏幕在全屏 → key 切换时必须把 Dock 重新藏起来")

        a.perform(.toggleFullscreen)   // A 退出全屏，B 还在全屏
        XCTAssertFalse(a.isSimpleFullscreen)
        XCTAssertTrue(b.isSimpleFullscreen)
        XCTAssertEqual(session.fullscreenScreenCount, 1)
        XCTAssertTrue(NSApp.presentationOptions.contains(.autoHideMenuBar),
                      "A 退出全屏不得把菜单栏还回来——B 还在全屏")

        XCTAssertTrue(app.closeScreen(b))   // 关掉全屏中的 B：只还它拿过的那一份
        spin(0.2)
        XCTAssertEqual(session.fullscreenScreenCount, 0)
        XCTAssertFalse(NSApp.presentationOptions.contains(.autoHideMenuBar),
                       "最后一个全屏屏幕关掉后必须把 Dock 与菜单栏还回来")
        XCTAssertFalse(NSApp.presentationOptions.contains(.autoHideDock))

        // 反向：账本空时 key 切换必须把残留的两样让出去（否则 A 退出全屏后菜单栏一直藏着）
        NSApp.presentationOptions = [.autoHideDock, .autoHideMenuBar]
        a.windowDidBecomeKey(Foundation.Notification(name: NSWindow.didBecomeKeyNotification, object: a.window))
        XCTAssertFalse(NSApp.presentationOptions.contains(.autoHideMenuBar), "账本空 → 必须还回菜单栏")
        XCTAssertFalse(NSApp.presentationOptions.contains(.autoHideDock), "账本空 → 必须还回 Dock")

        XCTAssertTrue(app.closeScreen(a))
        spin(0.5)
    }

    /// 每个窗口自己的 savedFrame：A 全屏不该动 B 的窗口，退出全屏各回各的 frame
    func testSavedFrameIsPerScreen() throws {
        try XCTSkipIf(NSScreen.main == nil, "没有显示器时非原生全屏是 no-op")
        try withSecondScreen { app, session, primary, second in
            defer {
                if second.isSimpleFullscreen { second.perform(.toggleFullscreen) }
                NSApp.presentationOptions = []
            }
            let primaryFrame = try XCTUnwrap(primary.window?.frame)
            let secondFrame = try XCTUnwrap(second.window?.frame)
            second.perform(.toggleFullscreen)
            XCTAssertTrue(second.isSimpleFullscreen)
            XCTAssertFalse(primary.isSimpleFullscreen, "全屏是按窗口的")
            XCTAssertEqual(primary.window?.frame, primaryFrame, "另一个屏幕的窗口不该被动过")
            second.perform(.toggleFullscreen)
            XCTAssertEqual(second.window?.frame, secondFrame, "退出全屏回到自己那份 savedFrame")
        }
    }

    // MARK: 混合 DPI：surface 的 backing scale 跟着自己窗口的显示器走

    /// surface 是在 init 里建的（那时还不在任何窗口上），scale_factor 只能先按主显示器种；
    /// 挂进窗口后必须补一次纠正，否则第二台显示器（不同 DPI）上的新 pane 会按错的缩放渲染。
    /// 单显示器上「取的是哪台显示器的缩放」无从分辨，所以这里只验补发这一步真跑了；
    /// 缩放取值本身由下面那条双显示器用例把关
    func testSurfaceAdoptsItsOwnWindowBackingScaleAfterMount() throws {
        let app = try self.app
        let primary = try XCTUnwrap(app.screens.primary)
        spin(0.4)
        let surface = try XCTUnwrap(primary.paneList.compactMap { $0 as? Ghostty.SurfaceView }.first)
        let window = try XCTUnwrap(surface.window)
        XCTAssertEqual(surface.appliedBackingScale, window.backingScaleFactor, accuracy: 0.001,
                       "挂载后 surface 的 backing scale 必须等于自己窗口的")
        // AppKit 自己在插入窗口时也会发一次 viewDidChangeBackingProperties，上面那条断言在
        // 单显示器上光靠系统行为也成立；这条才认得出 viewDidMoveToWindow 里那次主动补发有没有跑
        XCTAssertGreaterThanOrEqual(surface.mountBackingRefreshCount, 1,
                                    "挂进窗口后必须由 viewDidMoveToWindow 主动补一次 backing 纠正")
    }

    func testSurfaceOnSecondaryDisplayUsesThatDisplaysScale() throws {
        let all = NSScreen.screens
        try XCTSkipIf(all.count < 2, "只有一台显示器，混合 DPI 无从验证")
        let app = try self.app
        let primary = try XCTUnwrap(app.screens.primary)
        let target = try XCTUnwrap(all.first { $0 !== NSScreen.main })
        let second = app.newScreen(on: target)
        spin(0.8)
        defer {
            app.closeScreen(second)
            primary.window?.makeKeyAndOrderFront(nil)
            spin()
        }
        let surface = try XCTUnwrap(second.paneList.compactMap { $0 as? Ghostty.SurfaceView }.first)
        let window = try XCTUnwrap(surface.window)
        let screen = try XCTUnwrap(window.screen)
        XCTAssertEqual(surface.appliedBackingScale, screen.backingScaleFactor, accuracy: 0.001,
                       "非主显示器上的窗口，其 pane 必须按那台显示器的缩放渲染")
    }
}
