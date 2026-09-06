import AppKit
import WebKit
import XCTest
@testable import QuickTerm

/// 浏览器 pane 的下载 UI（模型 / 按钮 / 弹出层 / 真实下载）。
/// WebKit 的下载要靠主 runloop 推进：这些用例一律是非 async 的，用 `RunLoop.main.run(until:)` 轮询
/// （async 测试体里的 await 推不动主 runloop——见 BrowserExtensionTests 的同款注释）。
@MainActor
final class BrowserDownloadTests: XCTestCase {
    // MARK: - 模型

    /// 聚合进度 = 活动项已完成字节之和 / 总字节之和；任一条不知道总大小 → nil（不确定）
    func testAggregateFraction() {
        let list = BrowserDownloadList()
        XCTAssertNil(list.aggregateFraction, "空列表没有进度")
        let a = Self.fakeItem(name: "a.bin", total: 100, done: 50)
        let b = Self.fakeItem(name: "b.bin", total: 200, done: 100)
        list.add(a)
        list.add(b)
        XCTAssertEqual(list.activeCount, 2)
        XCTAssertEqual(try XCTUnwrap(list.aggregateFraction), 0.5, accuracy: 0.0001, "150 / 300")
        let unknown = Self.fakeItem(name: "c.bin", total: -1, done: 10)
        list.add(unknown)
        XCTAssertNil(list.aggregateFraction, "有一条总大小未知 → 整体不确定")
        // 已完成的不参与聚合
        list.markCompleted(unknown)
        XCTAssertEqual(try XCTUnwrap(list.aggregateFraction), 0.5, accuracy: 0.0001)
        list.markCompleted(a)
        list.markCompleted(b)
        XCTAssertNil(list.aggregateFraction, "没有活动项 → nil")
        XCTAssertEqual(list.activeCount, 0)
    }

    /// 取消：调下载自己的取消闭包 + 状态置为已取消；已结束的条目不再被状态流转覆盖
    func testCancelInvokesHandlerAndMarksCancelled() {
        let list = BrowserDownloadList()
        var cancelled = 0
        let item = BrowserDownloadItem(filename: "big.iso", progress: Progress(totalUnitCount: 100)) {
            cancelled += 1
        }
        list.add(item)
        list.cancel(item)
        XCTAssertEqual(cancelled, 1)
        XCTAssertEqual(item.state, .cancelled)
        XCTAssertTrue(item.isFinished)
        list.cancel(item)
        XCTAssertEqual(cancelled, 1, "已取消的不再重复取消")
        // WebKit 随后还会回调一次 didFail(NSURLErrorCancelled)：markCancelled 幂等，不能翻成失败
        list.markFailed(item, message: "boom")
        XCTAssertEqual(item.state, .cancelled)
    }

    /// clearFinished 只删已完成 / 失败 / 取消；remove 删单行；两者都触发 onChange
    func testClearFinishedKeepsActiveItems() {
        let list = BrowserDownloadList()
        var changes = 0
        list.onChange = { changes += 1 }
        let active = Self.fakeItem(name: "active.bin", total: 100, done: 10)
        let done = Self.fakeItem(name: "done.bin", total: 100, done: 100)
        let failed = Self.fakeItem(name: "failed.bin", total: 100, done: 5)
        let cancelled = Self.fakeItem(name: "cancelled.bin", total: 100, done: 5)
        for item in [active, done, failed, cancelled] { list.add(item) }
        XCTAssertEqual(changes, 4, "每次增加都刷新界面")
        list.markCompleted(done)
        list.markFailed(failed, message: "网络错误")
        list.markCancelled(cancelled)
        XCTAssertEqual(failed.state, .failed("网络错误"))
        XCTAssertTrue(failed.statusText.contains("网络错误"))
        let before = changes
        list.clearFinished()
        XCTAssertEqual(list.items.count, 1)
        XCTAssertTrue(list.items.first === active)
        XCTAssertEqual(changes, before + 1, "清除也刷新界面")
        list.remove(active)
        XCTAssertTrue(list.items.isEmpty)
    }

    /// 进度回调节流到 ≤ 10 Hz：一轮里刷 50 次进度，界面刷新不会跟着刷 50 次
    func testProgressNotificationsAreThrottled() {
        let list = BrowserDownloadList()
        let item = Self.fakeItem(name: "throttle.bin", total: 100, done: 0)
        list.add(item)
        var changes = 0
        list.onChange = { changes += 1 }
        for i in 1...50 { item.progress.completedUnitCount = Int64(i) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.35))
        XCTAssertGreaterThanOrEqual(changes, 1, "进度变化最终要刷到界面")
        XCTAssertLessThanOrEqual(changes, 4, "0.35s 内最多 10Hz × 0.35 ≈ 4 次，实际 \(changes)")
        XCTAssertEqual(item.progress.completedUnitCount, 50)
    }

    /// 状态文字用 ByteCountFormatter
    func testStatusText() {
        let item = Self.fakeItem(name: "x.bin", total: 5_000_000, done: 1_200_000)
        XCTAssertTrue(item.statusText.contains("/"), "进行中显示 已下载 / 总量：\(item.statusText)")
        XCTAssertTrue(item.statusText.contains("24%"), "1.2M / 5M ≈ 24%：\(item.statusText)")
        item.state = .completed
        XCTAssertTrue(item.statusText.hasPrefix("已完成"), item.statusText)
        item.state = .cancelled
        XCTAssertEqual(item.statusText, "已取消")
        XCTAssertEqual(BrowserDownloadItem.formatBytes(0), ByteCountFormatter().string(fromByteCount: 0))
    }

    // MARK: - 按钮 / 弹出层

    /// 空列表隐藏；有条目显示；全部完成后仍显示（画勾）直到清除
    func testDownloadButtonVisibility() {
        let list = BrowserDownloadList()
        let button = BrowserDownloadButton()
        button.list = list
        list.onChange = { button.update() }
        button.update()
        XCTAssertTrue(button.isHidden, "没有下载 → 隐藏")
        let item = Self.fakeItem(name: "a.bin", total: 100, done: 20)
        list.add(item)
        XCTAssertFalse(button.isHidden, "有下载 → 显示")
        XCTAssertTrue(button.toolTip?.contains("1 个进行中") ?? false, button.toolTip ?? "nil")
        list.markCompleted(item)
        XCTAssertFalse(button.isHidden, "全部完成仍显示（勾）")
        XCTAssertEqual(list.activeCount, 0)
        list.clearFinished()
        XCTAssertTrue(button.isHidden, "清除后隐藏")
        XCTAssertEqual(button.intrinsicContentSize.width, BrowserDownloadButton.size, accuracy: 0.01)
        // 自绘不能崩（进行中 / 不确定 / 全部完成三种画法）
        for state in [0, 1, 2] {
            if state == 1 { list.add(Self.fakeItem(name: "b.bin", total: -1, done: 3)) }
            if state == 2 { list.items.forEach { list.markCompleted($0) } }
            button.update()
            button.setFrameSize(NSSize(width: BrowserDownloadButton.size, height: BrowserDownloadButton.size))
            button.draw(button.bounds)
        }
    }

    /// 弹出层：一条下载一行，行按状态给出取消 / 移除；「清除已完成」按钮只在有结束项时出现
    func testPopoverRowsFollowList() {
        let list = BrowserDownloadList()
        let popover = BrowserDownloadPopover(list: list)
        popover.loadView()
        XCTAssertTrue(popover.rowsForTesting.isEmpty)
        let a = Self.fakeItem(name: "a.bin", total: 100, done: 20)
        let b = Self.fakeItem(name: "b.bin", total: 100, done: 100)
        list.add(a)
        list.add(b)
        popover.rebuild()
        XCTAssertEqual(popover.rowsForTesting.count, 2)
        let row = try? XCTUnwrap(popover.rowsForTesting.first as? BrowserDownloadRow)
        XCTAssertEqual(row?.nameForTesting, "a.bin")
        XCTAssertEqual(row?.primaryButtonForTesting.toolTip, "取消", "进行中的行给取消钮")
        XCTAssertNil(popover.clearButtonForTesting.superview, "没有已结束的下载 → 不显示清除")
        list.markCompleted(a)
        list.markCompleted(b)
        popover.rebuild()
        XCTAssertNotNil(popover.clearButtonForTesting.superview, "有已结束的下载 → 显示清除")
        list.clearFinished()
        popover.rebuild()
        XCTAssertTrue(popover.rowsForTesting.isEmpty, "清除后行也没了")
    }

    /// 中心符号：进行中 = 箭头；全部完成 = 勾；只要有失败 / 取消 = 感叹号（不能拿勾当"成功"报）
    func testDownloadButtonGlyphFollowsItemStates() {
        let list = BrowserDownloadList()
        let button = BrowserDownloadButton()
        button.list = list
        list.onChange = { button.update() }
        button.update()
        XCTAssertEqual(button.glyph, .arrow, "空列表（隐藏）默认箭头")
        let a = Self.fakeItem(name: "a.bin", total: 100, done: 20)
        list.add(a)
        XCTAssertEqual(button.glyph, .arrow, "进行中 → 箭头")
        list.markCompleted(a)
        XCTAssertEqual(button.glyph, .check, "全部完成 → 勾")
        XCTAssertEqual(button.toolTip, "下载（1 项）")
        let b = Self.fakeItem(name: "b.bin", total: 100, done: 5)
        list.add(b)
        list.markFailed(b, message: "连接被拒")
        XCTAssertEqual(button.glyph, .warning, "有失败项 → 感叹号，不能画勾")
        XCTAssertTrue(button.toolTip?.contains("失败") ?? false, button.toolTip ?? "nil")
        let c = Self.fakeItem(name: "c.bin", total: 100, done: 5)
        list.add(c)
        XCTAssertEqual(button.glyph, .arrow, "又有新下载 → 回到箭头")
        list.cancel(c)
        XCTAssertEqual(button.glyph, .warning, "取消也算没成功")
        list.remove(b)
        list.remove(c)
        XCTAssertEqual(button.glyph, .check, "只剩已完成 → 勾")
        button.setFrameSize(NSSize(width: BrowserDownloadButton.size, height: BrowserDownloadButton.size))
        button.draw(button.bounds)   // 感叹号 / 勾两种画法都不能崩
    }

    /// 自绘方向：NSButton 默认 isFlipped == true（y 向下），而 draw(_:) 的几何是按 y 向上写的。
    /// 少了 isFlipped 覆写就会画成"向上的箭头 + 从 6 点逆时针的进度环"——这里按像素验。
    func testDownloadButtonDrawsDownArrowAndClockwiseArc() throws {
        let list = BrowserDownloadList()
        let button = BrowserDownloadButton()
        button.list = list
        XCTAssertFalse(button.isFlipped, "draw(_:) 用 y 向上的坐标系")
        let item = Self.fakeItem(name: "a.bin", total: 100, done: 25)
        list.add(item)
        button.update()
        button.setFrameSize(NSSize(width: BrowserDownloadButton.size, height: BrowserDownloadButton.size))
        let rep = try XCTUnwrap(button.bitmapImageRepForCachingDisplay(in: button.bounds))
        button.cacheDisplay(in: button.bounds, to: rep)   // 走 isFlipped，直接调 draw 验不出来

        let scale = Double(rep.pixelsWide) / Double(button.bounds.width)
        let center = Double(BrowserDownloadButton.size) / 2
        var glyphTop = 0.0, glyphBottom = 0.0          // 中心箭头：头在下 → 下半更多墨
        var arcTopRight = 0.0, arcElsewhere = 0.0      // 25% 的进度弧：12 点 → 3 点
        for py in 0..<rep.pixelsHigh {
            for px in 0..<rep.pixelsWide {
                guard let alpha = rep.colorAt(x: px, y: py)?.alphaComponent, alpha > 0.6 else { continue }
                // 位图第 0 行在屏幕上方；轨道圆环画的是 25% 透明度，>0.6 只会命中实线部分
                let dx = (Double(px) + 0.5) / scale - center
                let dy = (Double(py) + 0.5) / scale - center   // 向下为正
                if abs(dx) <= 3.5, abs(dy) <= 6 {              // 只框中心符号（圆环在 |dy| ≥ 6.6 处）
                    if dy < 0 { glyphTop += alpha } else { glyphBottom += alpha }
                } else if (dx * dx + dy * dy).squareRoot() >= 6 {
                    if dx >= 0, dy < 0 { arcTopRight += alpha } else { arcElsewhere += alpha }
                }
            }
        }
        XCTAssertGreaterThan(glyphBottom, glyphTop * 2,
                             "箭头头部在下半边（上 \(glyphTop) / 下 \(glyphBottom)）")
        XCTAssertGreaterThan(arcTopRight, arcElsewhere * 5,
                             "25% 的弧应在右上象限（右上 \(arcTopRight) / 其它 \(arcElsewhere)）")
    }

    /// 弹出层控制器不能反过来持有 NSPopover：`contentViewController` 是强引用，
    /// 控制器自己再存一个 NSPopover 就成环，pane 关掉后列表连同 WKDownload 永远释放不掉
    func testPopoverControllerIsReleasedWithItsOwner() {
        let structure = Mirror(reflecting: BrowserDownloadPopover(list: BrowserDownloadList()))
        XCTAssertFalse(structure.children.contains { $0.value is NSPopover },
                       "控制器不能存 NSPopover（contentViewController 是强引用，存了就成环）")
        weak var weakController: BrowserDownloadPopover?
        weak var weakList: BrowserDownloadList?
        autoreleasepool {
            let list = BrowserDownloadList()
            let controller = BrowserDownloadPopover(list: list)
            controller.loadView()
            controller.rebuild()
            let host = NSPopover()          // 持有方是 NSPopover（真实情况是 pane 持有它）
            host.contentViewController = controller
            weakController = controller
            weakList = list
            XCTAssertNotNil(weakController)
        }
        // AppKit 会把控制器 autorelease 一手，转一圈 runloop 再看
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline, weakController != nil {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertNil(weakController, "NSPopover 一放手，控制器就该走")
        XCTAssertNil(weakList, "列表（连同条目与 WKDownload）跟着一起走")
    }

    /// pane 关掉之后，下载列表 / 弹出层控制器都要能释放（原来控制器 ↔ NSPopover 成环，
    /// 而且第一次下载就会把这个环建出来——`downloadsDidChange` 为了读 isShown 把它实例化了）
    func testClosedPaneReleasesDownloadUI() throws {
        weak var weakPane: BrowserPaneView?
        weak var weakList: BrowserDownloadList?
        weak var weakPopover: BrowserDownloadPopover?
        try autoreleasepool {
            let pane = try makePane(downloadDirectory: FileManager.default.temporaryDirectory.path)
            pane.downloads.add(Self.fakeItem(name: "a.bin", total: 100, done: 10))
            weakPane = pane
            weakList = pane.downloads
            weakPopover = pane.downloadPopoverForTesting   // 访问即实例化
            pane.paneWillClose()
            teardown(pane)
        }
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, weakPane != nil || weakPopover != nil {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertNil(weakPane, "pane 关掉后要能释放")
        XCTAssertNil(weakList, "下载列表（连同条目与 WKDownload）跟着走")
        XCTAssertNil(weakPopover, "弹出层控制器跟着走")
    }

    /// pane 关闭：进行中的下载明确取消掉，不留没人管的传输
    func testPaneCloseCancelsActiveDownloads() throws {
        let pane = try makePane(downloadDirectory: FileManager.default.temporaryDirectory.path)
        defer { teardown(pane) }
        var cancelled = 0
        let active = BrowserDownloadItem(filename: "big.iso", progress: Progress(totalUnitCount: 100)) {
            cancelled += 1
        }
        let done = Self.fakeItem(name: "done.bin", total: 100, done: 100)
        pane.downloads.add(active)
        pane.downloads.add(done)
        pane.downloads.markCompleted(done)
        pane.paneWillClose()
        XCTAssertEqual(cancelled, 1, "进行中的下载被取消")
        XCTAssertEqual(active.state, .cancelled)
        XCTAssertEqual(done.state, .completed, "已完成的不动")
    }

    // MARK: - 真实下载

    /// data: URL 下载：落到配置的目录、状态变成已完成、文件内容一致、弹出层一行
    func testRealDownloadLandsInConfiguredDirectory() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("qt-dl-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let pane = try makePane(downloadDirectory: dir.path)
        defer { teardown(pane) }

        let payload = Data("QuickTerm download test payload\n".utf8)
        let url = try XCTUnwrap(URL(string: "data:application/octet-stream;base64,"
                                    + payload.base64EncodedString()))
        pane.webView.startDownload(using: URLRequest(url: url)) { download in
            MainActor.assumeIsolated { pane.beginDownload(download) }
        }
        let item = try wait(for: pane, until: { $0.downloads.items.first?.state == .completed })
        XCTAssertEqual(item.state, .completed, "下载应在 5s 内完成；状态 = \(item.state)")
        let destination = try XCTUnwrap(item.destination)
        XCTAssertEqual(destination.deletingLastPathComponent().standardizedFileURL,
                       dir.standardizedFileURL, "应落在配置的目录里")
        XCTAssertEqual(try Data(contentsOf: destination), payload)
        XCTAssertEqual(item.filename, destination.lastPathComponent)
        XCTAssertEqual(pane.downloads.activeCount, 0)
        XCTAssertFalse(pane.downloadButton.isHidden, "有下载记录 → 按钮显示")
        let popover = pane.downloadPopoverForTesting
        popover.loadView()
        popover.rebuild()
        XCTAssertEqual(popover.rowsForTesting.count, 1)
    }

    /// 连接被拒的下载：进列表并显示为失败（连不上服务器时 decideDestination 根本不会被调用，
    /// 条目要在挂代理那一刻就建好）
    func testFailedDownloadShowsFailureState() throws {
        let pane = try makePane(downloadDirectory: FileManager.default.temporaryDirectory.path)
        defer { teardown(pane) }
        // 9 = discard 端口，本机上没人监听 → 连接被拒
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:9/nope.bin"))
        pane.webView.startDownload(using: URLRequest(url: url)) { download in
            MainActor.assumeIsolated { pane.beginDownload(download) }
        }
        let item = try wait(for: pane, until: { $0.downloads.items.first?.isFinished == true })
        guard case .failed(let message) = item.state else {
            return XCTFail("应该是失败状态，实际 \(item.state)")
        }
        XCTAssertFalse(message.isEmpty, "失败原因要能显示给用户")
        XCTAssertEqual(pane.downloads.activeCount, 0)
        XCTAssertTrue(item.statusText.hasPrefix("失败："), item.statusText)
    }

    /// 两条同名下载几乎同时定目的地：WebKit 要收到我们的回复才建文件，只查磁盘会给出同一个路径
    /// （后一条 EEXIST 失败）。目的地去重必须把"已经交给别的进行中下载"的路径也算上
    func testConcurrentSameNameDownloadsGetDistinctDestinations() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("qt-dl-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let pane = try makePane(downloadDirectory: dir.path)
        defer { teardown(pane) }

        // 两个 data: URL：建议文件名都是 "Unknown"，内容不同（要能分辨谁是谁）
        let payloads = [Data("first payload\n".utf8), Data("second payload\n".utf8)]
        for payload in payloads {
            let url = try XCTUnwrap(URL(string: "data:application/octet-stream;base64,"
                                        + payload.base64EncodedString()))
            pane.webView.startDownload(using: URLRequest(url: url)) { download in
                MainActor.assumeIsolated { pane.beginDownload(download) }
            }
        }
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline,
              !(pane.downloads.items.count == 2 && pane.downloads.items.allSatisfy(\.isFinished)) {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertEqual(pane.downloads.items.count, 2)
        let states = pane.downloads.items.map(\.state)
        XCTAssertEqual(states, [.completed, .completed], "两条都要下完，实际 \(states)")
        let destinations = pane.downloads.items.compactMap(\.destination)
        XCTAssertEqual(Set(destinations.map(\.standardizedFileURL.path)).count, 2,
                       "落盘路径要各不相同：\(destinations.map(\.lastPathComponent))")
        for (destination, payload) in zip(destinations, payloads) {
            XCTAssertEqual(try Data(contentsOf: destination), payload, "内容不能互相覆盖")
        }
    }

    /// 工具条：没有下载时按钮宽度为 0 且不额外占间距——布局与「地址栏 | 6pt | 扩展条」完全一样；
    /// 有下载时才让出 22 + 右侧 6pt
    func testDownloadButtonTakesNoSpaceWhenIdle() throws {
        let pane = try makePane(downloadDirectory: FileManager.default.temporaryDirectory.path)
        defer { teardown(pane) }
        pane.layoutSubtreeIfNeeded()
        let idleWidth = pane.addressFieldForTesting.frame.width
        XCTAssertTrue(pane.downloadButton.isHidden)
        XCTAssertEqual(pane.downloadButton.frame.width, 0, accuracy: 0.01, "隐藏时不占宽度")
        XCTAssertEqual(pane.extensionBar.frame.minX - pane.addressFieldForTesting.frame.maxX, 6,
                       accuracy: 0.5, "空闲时保留地址栏与扩展条之间原有的 6pt 间距")
        pane.downloads.add(Self.fakeItem(name: "a.bin", total: 100, done: 10))
        pane.layoutSubtreeIfNeeded()
        XCTAssertFalse(pane.downloadButton.isHidden)
        XCTAssertEqual(pane.downloadButton.frame.width, BrowserDownloadButton.size, accuracy: 0.01)
        XCTAssertEqual(pane.addressFieldForTesting.frame.width,
                       idleWidth - BrowserDownloadButton.size - 6, accuracy: 1,
                       "按钮 22 + 新增的右侧 6pt 间距从地址栏里让出来")
        XCTAssertLessThanOrEqual(pane.addressFieldForTesting.frame.maxX,
                                 pane.downloadButton.frame.minX + 0.5, "下载按钮在地址栏右侧")
        XCTAssertLessThanOrEqual(pane.downloadButton.frame.maxX,
                                 pane.extensionBar.frame.minX + 0.5, "扩展条在下载按钮右侧")
    }

    // MARK: - 夹具

    private static func fakeItem(name: String, total: Int64, done: Int64) -> BrowserDownloadItem {
        let progress = Progress(totalUnitCount: total)
        progress.completedUnitCount = done
        return BrowserDownloadItem(filename: name, progress: progress,
                                   destination: URL(fileURLWithPath: "/tmp/\(name)"))
    }

    private var windows: [NSWindow] = []
    private var previousSettings: BrowserPaneView.Settings?

    /// 一个挂在窗口里的浏览器 pane（下载目录指到临时目录；扩展指向空管理器，别看用户真装了什么）
    private func makePane(downloadDirectory: String) throws -> BrowserPaneView {
        if previousSettings == nil { previousSettings = BrowserPaneView.settings }
        BrowserPaneView.settings.home = "about:blank"
        BrowserPaneView.settings.downloadDirectory = downloadDirectory
        let store = FileManager.default.temporaryDirectory
            .appendingPathComponent("qt-dlstore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        BrowserExtensionManager.overrideForTesting =
            BrowserExtensionManager(configuration: .nonPersistent(), storeDirectory: store)
        let pane = BrowserPaneView(url: URL(string: "about:blank"))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = pane
        windows.append(window)
        return pane
    }

    private func teardown(_ pane: BrowserPaneView) {
        for window in windows { window.contentView = nil }
        windows.removeAll()
        BrowserExtensionManager.overrideForTesting = nil
        if let previousSettings { BrowserPaneView.settings = previousSettings }
        previousSettings = nil
    }

    /// 转主 runloop 等下载状态落地（WebKit 的下载全靠主 runloop 推进）
    private func wait(for pane: BrowserPaneView,
                      until condition: (BrowserPaneView) -> Bool,
                      timeout: TimeInterval = 8) throws -> BrowserDownloadItem {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !condition(pane) {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        return try XCTUnwrap(pane.downloads.items.first,
                             "下载没有进入列表（items=\(pane.downloads.items.count)）")
    }

    /// 视觉快照（仅当设置 QUICKTERM_SNAPSHOT_DIR）：四种按钮状态（25% / 不确定 / 全部完成 / 只剩失败）放大 4 倍，
    /// 以及三行下载列表的弹出层内容，画成 PNG 供人工核对
    @MainActor
    func testDownloadUISnapshot() throws {
        guard let dir = ProcessInfo.processInfo.environment["QUICKTERM_SNAPSHOT_DIR"] else { return }
        func render(_ view: NSView, scale: CGFloat, name: String) throws {
            let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = view
            view.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.15))
            let w = Int(view.bounds.width * scale), h = Int(view.bounds.height * scale)
            let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8,
                                                     samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            rep.size = view.bounds.size
            view.cacheDisplay(in: view.bounds, to: rep)
            let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
            window.contentView = nil
        }
        let bg = NSColor(srgbRed: 0.09, green: 0.09, blue: 0.11, alpha: 1)
        // 按钮四态
        let strip = NSView(frame: NSRect(x: 0, y: 0, width: 4 * 34 + 10, height: 34))
        strip.wantsLayer = true
        strip.layer?.backgroundColor = bg.cgColor
        var lists: [BrowserDownloadList] = []
        let states: [(String, (BrowserDownloadList) -> Void)] = [
            ("25%", { list in
                let p = Progress(totalUnitCount: 100); p.completedUnitCount = 25
                list.add(BrowserDownloadItem(filename: "a.zip", progress: p) {}) }),
            ("不确定", { list in
                list.add(BrowserDownloadItem(filename: "b.bin", progress: Progress(totalUnitCount: 0)) {}) }),
            ("完成", { list in
                let item = BrowserDownloadItem(filename: "c.dmg", progress: Progress(totalUnitCount: 10)) {}
                list.add(item); list.markCompleted(item) }),
            ("失败", { list in
                let item = BrowserDownloadItem(filename: "d.iso", progress: Progress(totalUnitCount: 10)) {}
                list.add(item); list.markFailed(item, message: "连接被拒绝") }),
        ]
        for (i, (_, fill)) in states.enumerated() {
            let list = BrowserDownloadList(); fill(list); lists.append(list)
            let button = BrowserDownloadButton(frame: NSRect(x: 8 + CGFloat(i) * 34, y: 6, width: 22, height: 22))
            button.list = list
            button.tint = .white
            button.update()
            strip.addSubview(button)
        }
        try render(strip, scale: 4, name: "downloads-button.png")
        // 弹出层内容：三行
        let list = BrowserDownloadList()
        let p1 = Progress(totalUnitCount: 5_000_000); p1.completedUnitCount = 2_250_000
        list.add(BrowserDownloadItem(filename: "QuickTerm-1.5.3.dmg", progress: p1) {})
        let done = BrowserDownloadItem(filename: "report-final-v2-really-final.pdf", progress: Progress(totalUnitCount: 120_000)) {}
        list.add(done); done.progress.completedUnitCount = 120_000; list.markCompleted(done)
        let failed = BrowserDownloadItem(filename: "dataset.tar.gz", progress: Progress(totalUnitCount: 0)) {}
        list.add(failed); list.markFailed(failed, message: "连接被拒绝")
        let popover = BrowserDownloadPopover(list: list)
        popover.rebuild()
        let content = popover.view
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor(srgbRed: 0.16, green: 0.16, blue: 0.18, alpha: 1).cgColor
        content.frame = NSRect(x: 0, y: 0, width: BrowserDownloadPopover.width,
                               height: max(content.fittingSize.height, 60))
        try render(content, scale: 2, name: "downloads-popover.png")
        withExtendedLifetime(lists) {}
    }
}
