import XCTest
import GhosttyKit
@testable import QuickTerm

final class EngineSmokeTests: XCTestCase {
    override class func setUp() {
        // ghostty_init runs once per process (int ghostty_init(uintptr_t, char**)).
        _ = ghostty_init(0, nil)
    }

    func testConfigLoadsDefaultFiles() {
        guard let config = ghostty_config_new() else {
            return XCTFail("ghostty_config_new returned nil")
        }
        defer { ghostty_config_free(config) }
        // Reads ~/.config/ghostty/config (XDG): layer 2 of the config chain.
        ghostty_config_load_default_files(config)
        ghostty_config_finalize(config)
        // After finalize, read back a known key to prove the config system works.
        var decoration = false
        let key = "window-decoration"
        let ok = ghostty_config_get(config, &decoration, key, UInt(key.utf8.count))
        XCTAssertTrue(ok, "ghostty_config_get(window-decoration) should succeed after finalize")
    }
}

final class SurfaceHostingTests: XCTestCase {
    /// Regression lock for the "terminal does not follow while the window is dragged" bug: since M1 the
    /// contentView is an NSHostingView (the RootView -> TerminalSplitTreeView -> SurfaceWrapper ->
    /// SurfaceScrollView chain) and size sync is driven by SurfaceScrollView.layout(). Asserts the window
    /// structure, a non-empty tree, and the hidden-titlebar style.
    @MainActor
    func testWindowHostsSplitTreeContent() throws {
        let window = try XCTUnwrap(NSApp.windows.first { $0.title == "QuickTerm" })
        XCTAssertTrue(window is HiddenTitlebarWindow, "the main window must be a HiddenTitlebarWindow")
        XCTAssertTrue(window.styleMask.contains(.fullSizeContentView))
        XCTAssertEqual(window.titleVisibility, .hidden)
        let content = try XCTUnwrap(window.contentView)
        XCTAssertTrue(String(describing: type(of: content)).contains("NSHostingView"),
                      "contentView must be an NSHostingView (actual: \(type(of: content)))")
        // Non-empty tree: a SurfaceScrollView descendant really exists inside the window, which is where
        // size sync is hosted.
        func findScrollHost(_ v: NSView) -> Bool {
            if v is SurfaceScrollView { return true }
            return v.subviews.contains(where: findScrollHost)
        }
        XCTAssertTrue(findScrollHost(content), "the view chain must contain a SurfaceScrollView host")
    }

    /// Host layout behavior: after a resize, surfaceView.frame follows the host's bounds.
    @MainActor
    func testScrollViewHostSyncsSurfaceFrameOnResize() throws {
        let appDelegate = try XCTUnwrap(NSApp.delegate as? AppDelegate)
        let sv = Ghostty.SurfaceView(try XCTUnwrap(appDelegate.ghostty.app), baseConfig: nil)
        let host = SurfaceScrollView(contentSize: CGSize(width: 400, height: 300), surfaceView: sv)
        host.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        host.layoutSubtreeIfNeeded()
        host.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        host.needsLayout = true
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(sv.frame.size.width, 800, accuracy: 0.5)
    }
}
