import AppKit
import WebKit
import XCTest
@testable import QuickTerm

/// The download UI of a browser pane (model / button / popover / real downloads).
/// WebKit drives downloads off the main runloop, so every case here is non-async and polls with
/// `RunLoop.main.run(until:)` (an await inside an async test body never turns the main runloop; see the
/// same note in BrowserExtensionTests).
@MainActor
final class BrowserDownloadTests: XCTestCase {
    // MARK: - Model

    /// Aggregate progress = completed bytes over total bytes across the active items; if any one of them
    /// has an unknown total, the answer is nil (indeterminate).
    func testAggregateFraction() {
        let list = BrowserDownloadList()
        XCTAssertNil(list.aggregateFraction, "an empty list has no progress")
        let a = Self.fakeItem(name: "a.bin", total: 100, done: 50)
        let b = Self.fakeItem(name: "b.bin", total: 200, done: 100)
        list.add(a)
        list.add(b)
        XCTAssertEqual(list.activeCount, 2)
        XCTAssertEqual(try XCTUnwrap(list.aggregateFraction), 0.5, accuracy: 0.0001, "150 / 300")
        let unknown = Self.fakeItem(name: "c.bin", total: -1, done: 10)
        list.add(unknown)
        XCTAssertNil(list.aggregateFraction, "one unknown total makes the whole thing indeterminate")
        // Completed items do not count toward the aggregate.
        list.markCompleted(unknown)
        XCTAssertEqual(try XCTUnwrap(list.aggregateFraction), 0.5, accuracy: 0.0001)
        list.markCompleted(a)
        list.markCompleted(b)
        XCTAssertNil(list.aggregateFraction, "no active items -> nil")
        XCTAssertEqual(list.activeCount, 0)
    }

    /// Cancelling calls the download's own cancel closure and marks it cancelled; an item that already
    /// finished is never overwritten by a later state transition.
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
        XCTAssertEqual(cancelled, 1, "an already-cancelled item is not cancelled twice")
        // WebKit follows up with one more didFail(NSURLErrorCancelled): markCancelled is idempotent and
        // must not flip the item to failed.
        list.markFailed(item, message: "boom")
        XCTAssertEqual(item.state, .cancelled)
    }

    /// clearFinished removes only completed / failed / cancelled items, remove drops one row, and both fire
    /// onChange.
    func testClearFinishedKeepsActiveItems() {
        let list = BrowserDownloadList()
        var changes = 0
        list.onChange = { changes += 1 }
        let active = Self.fakeItem(name: "active.bin", total: 100, done: 10)
        let done = Self.fakeItem(name: "done.bin", total: 100, done: 100)
        let failed = Self.fakeItem(name: "failed.bin", total: 100, done: 5)
        let cancelled = Self.fakeItem(name: "cancelled.bin", total: 100, done: 5)
        for item in [active, done, failed, cancelled] { list.add(item) }
        XCTAssertEqual(changes, 4, "every add refreshes the UI")
        list.markCompleted(done)
        list.markFailed(failed, message: "network error")
        list.markCancelled(cancelled)
        XCTAssertEqual(failed.state, .failed("network error"))
        XCTAssertTrue(failed.statusText.contains("network error"))
        let before = changes
        list.clearFinished()
        XCTAssertEqual(list.items.count, 1)
        XCTAssertTrue(list.items.first === active)
        XCTAssertEqual(changes, before + 1, "clearing refreshes the UI too")
        list.remove(active)
        XCTAssertTrue(list.items.isEmpty)
    }

    /// Progress callbacks are throttled to <= 10 Hz: bump the progress 50 times in one go and the UI does
    /// not refresh 50 times.
    func testProgressNotificationsAreThrottled() {
        let list = BrowserDownloadList()
        let item = Self.fakeItem(name: "throttle.bin", total: 100, done: 0)
        list.add(item)
        var changes = 0
        list.onChange = { changes += 1 }
        for i in 1...50 { item.progress.completedUnitCount = Int64(i) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.35))
        XCTAssertGreaterThanOrEqual(changes, 1, "a progress change has to reach the UI eventually")
        XCTAssertLessThanOrEqual(changes, 4, "at most 10Hz × 0.35 ≈ 4 refreshes in 0.35s; actual \(changes)")
        XCTAssertEqual(item.progress.completedUnitCount, 50)
    }

    /// The status text goes through ByteCountFormatter.
    func testStatusText() {
        pinUILanguage(.en)
        let item = Self.fakeItem(name: "x.bin", total: 5_000_000, done: 1_200_000)
        XCTAssertTrue(item.statusText.contains("/"), "in progress shows downloaded / total: \(item.statusText)")
        XCTAssertTrue(item.statusText.contains("24%"), "1.2M / 5M ≈ 24%: \(item.statusText)")
        item.state = .completed
        XCTAssertTrue(item.statusText.hasPrefix("Completed"), item.statusText)
        item.state = .cancelled
        XCTAssertEqual(item.statusText, "Canceled")
        XCTAssertEqual(BrowserDownloadItem.formatBytes(0), ByteCountFormatter().string(fromByteCount: 0))
    }

    // MARK: - Button and popover

    /// Hidden while the list is empty, shown once an item exists, and still shown as a checkmark after
    /// everything finishes, until it is cleared.
    func testDownloadButtonVisibility() {
        pinUILanguage(.en)
        let list = BrowserDownloadList()
        let button = BrowserDownloadButton()
        button.list = list
        list.onChange = { button.update() }
        button.update()
        XCTAssertTrue(button.isHidden, "no downloads -> hidden")
        let item = Self.fakeItem(name: "a.bin", total: 100, done: 20)
        list.add(item)
        XCTAssertFalse(button.isHidden, "a download -> shown")
        XCTAssertTrue(button.toolTip?.contains("1 in progress") ?? false, button.toolTip ?? "nil")
        list.markCompleted(item)
        XCTAssertFalse(button.isHidden, "still shown when everything is done (the checkmark)")
        XCTAssertEqual(list.activeCount, 0)
        list.clearFinished()
        XCTAssertTrue(button.isHidden, "hidden again after clearing")
        XCTAssertEqual(button.intrinsicContentSize.width, BrowserDownloadButton.size, accuracy: 0.01)
        // The custom drawing must not crash in any of its three modes: in progress, indeterminate, all done.
        for state in [0, 1, 2] {
            if state == 1 { list.add(Self.fakeItem(name: "b.bin", total: -1, done: 3)) }
            if state == 2 { list.items.forEach { list.markCompleted($0) } }
            button.update()
            button.setFrameSize(NSSize(width: BrowserDownloadButton.size, height: BrowserDownloadButton.size))
            button.draw(button.bounds)
        }
    }

    /// The popover: one row per download, each offering cancel or remove according to its state, and the
    /// "clear completed" button showing up only once something has finished.
    func testPopoverRowsFollowList() {
        pinUILanguage(.en)
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
        XCTAssertEqual(row?.primaryButtonForTesting.toolTip, "Cancel", "a row in progress offers a cancel button")
        XCTAssertNil(popover.clearButtonForTesting.superview, "nothing finished -> no clear button")
        list.markCompleted(a)
        list.markCompleted(b)
        popover.rebuild()
        XCTAssertNotNil(popover.clearButtonForTesting.superview, "something finished -> the clear button appears")
        list.clearFinished()
        popover.rebuild()
        XCTAssertTrue(popover.rowsForTesting.isEmpty, "the rows are gone after clearing")
    }

    /// The center glyph: in progress is an arrow, all done is a checkmark, and a single failure or
    /// cancellation makes it an exclamation mark. A checkmark must never claim "success" that did not happen.
    func testDownloadButtonGlyphFollowsItemStates() {
        pinUILanguage(.en)
        let list = BrowserDownloadList()
        let button = BrowserDownloadButton()
        button.list = list
        list.onChange = { button.update() }
        button.update()
        XCTAssertEqual(button.glyph, .arrow, "an empty (hidden) list defaults to the arrow")
        let a = Self.fakeItem(name: "a.bin", total: 100, done: 20)
        list.add(a)
        XCTAssertEqual(button.glyph, .arrow, "in progress -> arrow")
        list.markCompleted(a)
        XCTAssertEqual(button.glyph, .check, "all done -> checkmark")
        XCTAssertEqual(button.toolTip, "Downloads (1 item)")
        let b = Self.fakeItem(name: "b.bin", total: 100, done: 5)
        list.add(b)
        list.markFailed(b, message: "connection refused")
        XCTAssertEqual(button.glyph, .warning, "a failed item -> exclamation mark, never a checkmark")
        XCTAssertTrue(button.toolTip?.contains("failed") ?? false, button.toolTip ?? "nil")
        let c = Self.fakeItem(name: "c.bin", total: 100, done: 5)
        list.add(c)
        XCTAssertEqual(button.glyph, .arrow, "a new download -> back to the arrow")
        list.cancel(c)
        XCTAssertEqual(button.glyph, .warning, "a cancellation counts as not-succeeded too")
        list.remove(b)
        list.remove(c)
        XCTAssertEqual(button.glyph, .check, "only completed items left -> checkmark")
        button.setFrameSize(NSSize(width: BrowserDownloadButton.size, height: BrowserDownloadButton.size))
        button.draw(button.bounds)   // Neither the exclamation mark nor the checkmark drawing may crash
    }

    /// Drawing orientation: NSButton defaults to isFlipped == true (y pointing down), while the geometry in
    /// draw(_:) is written for y pointing up. Without the isFlipped override this comes out as "an upward
    /// arrow plus a progress ring running counter-clockwise from 6 o'clock", so this checks the pixels.
    func testDownloadButtonDrawsDownArrowAndClockwiseArc() throws {
        let list = BrowserDownloadList()
        let button = BrowserDownloadButton()
        button.list = list
        XCTAssertFalse(button.isFlipped, "draw(_:) works in a y-up coordinate system")
        let item = Self.fakeItem(name: "a.bin", total: 100, done: 25)
        list.add(item)
        button.update()
        button.setFrameSize(NSSize(width: BrowserDownloadButton.size, height: BrowserDownloadButton.size))
        let rep = try XCTUnwrap(button.bitmapImageRepForCachingDisplay(in: button.bounds))
        button.cacheDisplay(in: button.bounds, to: rep)   // Goes through isFlipped; calling draw directly proves nothing

        let scale = Double(rep.pixelsWide) / Double(button.bounds.width)
        let center = Double(BrowserDownloadButton.size) / 2
        var glyphTop = 0.0, glyphBottom = 0.0          // Center arrow: head at the bottom -> more ink below
        var arcTopRight = 0.0, arcElsewhere = 0.0      // The 25% progress arc: 12 o'clock -> 3 o'clock
        for py in 0..<rep.pixelsHigh {
            for px in 0..<rep.pixelsWide {
                guard let alpha = rep.colorAt(x: px, y: py)?.alphaComponent, alpha > 0.6 else { continue }
                // Row 0 of the bitmap is the top of the screen; the track ring is drawn at 25% alpha, so
                // a threshold of > 0.6 only hits the solid stroke.
                let dx = (Double(px) + 0.5) / scale - center
                let dy = (Double(py) + 0.5) / scale - center   // Down is positive
                if abs(dx) <= 3.5, abs(dy) <= 6 {              // Box in the center glyph only (the ring sits at |dy| >= 6.6)
                    if dy < 0 { glyphTop += alpha } else { glyphBottom += alpha }
                } else if (dx * dx + dy * dy).squareRoot() >= 6 {
                    if dx >= 0, dy < 0 { arcTopRight += alpha } else { arcElsewhere += alpha }
                }
            }
        }
        XCTAssertGreaterThan(glyphBottom, glyphTop * 2,
                             "the arrowhead is in the lower half (top \(glyphTop) / bottom \(glyphBottom))")
        XCTAssertGreaterThan(arcTopRight, arcElsewhere * 5,
                             "the 25% arc belongs in the top-right quadrant (top-right \(arcTopRight) / elsewhere \(arcElsewhere))")
    }

    /// The popover controller must not hold the NSPopover back: `contentViewController` is a strong
    /// reference, so a controller that also stores an NSPopover closes a cycle, and once the pane is closed
    /// the list and its WKDownloads can never be released.
    func testPopoverControllerIsReleasedWithItsOwner() {
        let structure = Mirror(reflecting: BrowserDownloadPopover(list: BrowserDownloadList()))
        XCTAssertFalse(structure.children.contains { $0.value is NSPopover },
                       "the controller must not store an NSPopover: contentViewController is strong, so that closes a cycle")
        weak var weakController: BrowserDownloadPopover?
        weak var weakList: BrowserDownloadList?
        autoreleasepool {
            let list = BrowserDownloadList()
            let controller = BrowserDownloadPopover(list: list)
            controller.loadView()
            controller.rebuild()
            let host = NSPopover()          // The NSPopover owns it here; in the real app the pane owns the popover
            host.contentViewController = controller
            weakController = controller
            weakList = list
            XCTAssertNotNil(weakController)
        }
        // AppKit autoreleases the controller once, so turn the runloop before looking again.
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline, weakController != nil {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertNil(weakController, "the moment NSPopover lets go, the controller has to go")
        XCTAssertNil(weakList, "and the list goes with it, items and WKDownloads included")
    }

    /// Once the pane is closed, both the download list and the popover controller have to be released. There
    /// used to be a controller <-> NSPopover cycle, and the very first download built it: `downloadsDidChange`
    /// instantiated the popover just to read isShown.
    func testClosedPaneReleasesDownloadUI() throws {
        weak var weakPane: BrowserPaneView?
        weak var weakList: BrowserDownloadList?
        weak var weakPopover: BrowserDownloadPopover?
        try autoreleasepool {
            let pane = try makePane(downloadDirectory: FileManager.default.temporaryDirectory.path)
            pane.downloads.add(Self.fakeItem(name: "a.bin", total: 100, done: 10))
            weakPane = pane
            weakList = pane.downloads
            weakPopover = pane.downloadPopoverForTesting   // Touching it instantiates it
            pane.paneWillClose()
            teardown(pane)
        }
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, weakPane != nil || weakPopover != nil {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertNil(weakPane, "a closed pane has to be released")
        XCTAssertNil(weakList, "the download list goes with it, items and WKDownloads included")
        XCTAssertNil(weakPopover, "the popover controller goes with it")
    }

    /// Closing a pane cancels in-flight downloads outright, leaving no orphaned transfer.
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
        XCTAssertEqual(cancelled, 1, "the in-flight download was cancelled")
        XCTAssertEqual(active.state, .cancelled)
        XCTAssertEqual(done.state, .completed, "a completed one is left alone")
    }

    // MARK: - Real downloads

    /// A data: URL download: it lands in the configured directory, the state turns completed, the contents
    /// match, and the popover shows one row.
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
        XCTAssertEqual(item.state, .completed, "the download should finish within 5s; state = \(item.state)")
        let destination = try XCTUnwrap(item.destination)
        XCTAssertEqual(destination.deletingLastPathComponent().standardizedFileURL,
                       dir.standardizedFileURL, "it has to land in the configured directory")
        XCTAssertEqual(try Data(contentsOf: destination), payload)
        XCTAssertEqual(item.filename, destination.lastPathComponent)
        XCTAssertEqual(pane.downloads.activeCount, 0)
        XCTAssertFalse(pane.downloadButton.isHidden, "a download on record -> the button shows")
        let popover = pane.downloadPopoverForTesting
        popover.loadView()
        popover.rebuild()
        XCTAssertEqual(popover.rowsForTesting.count, 1)
    }

    /// A refused connection still enters the list and shows as failed: when the server cannot be reached
    /// decideDestination is never called at all, so the item has to exist the moment the delegate is attached.
    func testFailedDownloadShowsFailureState() throws {
        pinUILanguage(.en)
        let pane = try makePane(downloadDirectory: FileManager.default.temporaryDirectory.path)
        defer { teardown(pane) }
        // Port 9 is discard, and nothing listens on it locally, so the connection is refused.
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:9/nope.bin"))
        pane.webView.startDownload(using: URLRequest(url: url)) { download in
            MainActor.assumeIsolated { pane.beginDownload(download) }
        }
        let item = try wait(for: pane, until: { $0.downloads.items.first?.isFinished == true })
        guard case .failed(let message) = item.state else {
            return XCTFail("expected the failed state; actual \(item.state)")
        }
        XCTAssertFalse(message.isEmpty, "the reason has to be showable to the user")
        XCTAssertEqual(pane.downloads.activeCount, 0)
        XCTAssertTrue(item.statusText.hasPrefix("Failed:"), item.statusText)
    }

    /// Two same-named downloads settle their destinations almost simultaneously: WebKit only creates the file
    /// after it has our answer, so checking the disk alone hands out the same path twice and the second one
    /// fails with EEXIST. Destination deduplication has to count paths already given to another in-flight download.
    func testConcurrentSameNameDownloadsGetDistinctDestinations() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("qt-dl-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let pane = try makePane(downloadDirectory: dir.path)
        defer { teardown(pane) }

        // Two data: URLs: both suggest the filename "Unknown", with different contents so they can be told apart.
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
        XCTAssertEqual(states, [.completed, .completed], "both have to finish; actual \(states)")
        let destinations = pane.downloads.items.compactMap(\.destination)
        XCTAssertEqual(Set(destinations.map(\.standardizedFileURL.path)).count, 2,
                       "the paths on disk have to differ: \(destinations.map(\.lastPathComponent))")
        for (destination, payload) in zip(destinations, payloads) {
            XCTAssertEqual(try Data(contentsOf: destination), payload, "the contents must not overwrite each other")
        }
    }

    /// The toolbar: with no downloads the button is 0 wide and claims no extra spacing, so the layout is
    /// exactly "address field | 6pt | extension bar". Only with a download does it take 22 plus 6pt on its right.
    func testDownloadButtonTakesNoSpaceWhenIdle() throws {
        let pane = try makePane(downloadDirectory: FileManager.default.temporaryDirectory.path)
        defer { teardown(pane) }
        pane.layoutSubtreeIfNeeded()
        let idleWidth = pane.addressFieldForTesting.frame.width
        XCTAssertTrue(pane.downloadButton.isHidden)
        XCTAssertEqual(pane.downloadButton.frame.width, 0, accuracy: 0.01, "hidden means zero width")
        XCTAssertEqual(pane.extensionBar.frame.minX - pane.addressFieldForTesting.frame.maxX, 6,
                       accuracy: 0.5, "while idle, the original 6pt between address field and extension bar stays")
        pane.downloads.add(Self.fakeItem(name: "a.bin", total: 100, done: 10))
        pane.layoutSubtreeIfNeeded()
        XCTAssertFalse(pane.downloadButton.isHidden)
        XCTAssertEqual(pane.downloadButton.frame.width, BrowserDownloadButton.size, accuracy: 0.01)
        XCTAssertEqual(pane.addressFieldForTesting.frame.width,
                       idleWidth - BrowserDownloadButton.size - 6, accuracy: 1,
                       "the button's 22 plus the new 6pt to its right come out of the address field")
        XCTAssertLessThanOrEqual(pane.addressFieldForTesting.frame.maxX,
                                 pane.downloadButton.frame.minX + 0.5, "the download button sits right of the address field")
        XCTAssertLessThanOrEqual(pane.downloadButton.frame.maxX,
                                 pane.extensionBar.frame.minX + 0.5, "the extension bar sits right of the download button")
    }

    // MARK: - Fixtures

    private static func fakeItem(name: String, total: Int64, done: Int64) -> BrowserDownloadItem {
        let progress = Progress(totalUnitCount: total)
        progress.completedUnitCount = done
        return BrowserDownloadItem(filename: name, progress: progress,
                                   destination: URL(fileURLWithPath: "/tmp/\(name)"))
    }

    private var windows: [NSWindow] = []
    private var previousSettings: BrowserPaneView.Settings?

    /// A browser pane mounted in a window: downloads go to a temporary directory, and extensions point at an
    /// empty manager so whatever the user really installed stays out of it.
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

    /// Turn the main runloop until the download state lands (WebKit drives downloads from the main runloop).
    private func wait(for pane: BrowserPaneView,
                      until condition: (BrowserPaneView) -> Bool,
                      timeout: TimeInterval = 8) throws -> BrowserDownloadItem {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !condition(pane) {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        return try XCTUnwrap(pane.downloads.items.first,
                             "the download never entered the list (items=\(pane.downloads.items.count))")
    }

    /// Visual snapshot, only when QUICKTERM_SNAPSHOT_DIR is set: the four button states (25% / indeterminate /
    /// all done / failures only) at 4x, plus the popover content for a three-row list, rendered to PNGs for a
    /// human to check.
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
        // The four button states.
        let strip = NSView(frame: NSRect(x: 0, y: 0, width: 4 * 34 + 10, height: 34))
        strip.wantsLayer = true
        strip.layer?.backgroundColor = bg.cgColor
        var lists: [BrowserDownloadList] = []
        let states: [(String, (BrowserDownloadList) -> Void)] = [
            ("25%", { list in
                let p = Progress(totalUnitCount: 100); p.completedUnitCount = 25
                list.add(BrowserDownloadItem(filename: "a.zip", progress: p) {}) }),
            ("indeterminate", { list in
                list.add(BrowserDownloadItem(filename: "b.bin", progress: Progress(totalUnitCount: 0)) {}) }),
            ("completed", { list in
                let item = BrowserDownloadItem(filename: "c.dmg", progress: Progress(totalUnitCount: 10)) {}
                list.add(item); list.markCompleted(item) }),
            ("failed", { list in
                let item = BrowserDownloadItem(filename: "d.iso", progress: Progress(totalUnitCount: 10)) {}
                list.add(item); list.markFailed(item, message: "Connection refused") }),
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
        // Popover content: three rows.
        let list = BrowserDownloadList()
        let p1 = Progress(totalUnitCount: 5_000_000); p1.completedUnitCount = 2_250_000
        list.add(BrowserDownloadItem(filename: "QuickTerm-1.5.3.dmg", progress: p1) {})
        let done = BrowserDownloadItem(filename: "report-final-v2-really-final.pdf", progress: Progress(totalUnitCount: 120_000)) {}
        list.add(done); done.progress.completedUnitCount = 120_000; list.markCompleted(done)
        let failed = BrowserDownloadItem(filename: "dataset.tar.gz", progress: Progress(totalUnitCount: 0)) {}
        list.add(failed); list.markFailed(failed, message: "Connection refused")
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
