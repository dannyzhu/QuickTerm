import XCTest
import GhosttyKit
@testable import QuickTerm

final class EngineSmokeTests: XCTestCase {
    override class func setUp() {
        // ghostty_init 每进程一次（int ghostty_init(uintptr_t, char**)）
        _ = ghostty_init(0, nil)
    }

    func testConfigLoadsDefaultFiles() {
        guard let config = ghostty_config_new() else {
            return XCTFail("ghostty_config_new returned nil")
        }
        defer { ghostty_config_free(config) }
        // 读取 ~/.config/ghostty/config（XDG）——配置链第 2 层
        ghostty_config_load_default_files(config)
        ghostty_config_finalize(config)
        // finalize 后取一个已知键，验证配置系统可用
        var decoration = false
        let key = "window-decoration"
        let ok = ghostty_config_get(config, &decoration, key, UInt(key.utf8.count))
        XCTAssertTrue(ok, "ghostty_config_get(window-decoration) should succeed after finalize")
    }
}

final class SurfaceHostingTests: XCTestCase {
    /// 回归锁（拖拽窗口终端不跟随 bug）：contentView 必须是 SurfaceScrollView 宿主，
    /// 而非裸 SurfaceView——尺寸同步（sizeDidChange → ghostty_surface_set_size）由宿主驱动。
    @MainActor
    func testWindowHostsSurfaceScrollView() throws {
        let window = try XCTUnwrap(NSApp.windows.first { $0.title == "QuickTerm" })
        XCTAssertTrue(window.contentView is SurfaceScrollView,
                      "window.contentView 应为 SurfaceScrollView（实际: \(type(of: window.contentView!))）")
    }

    /// 宿主布局行为：resize 后 surfaceView.frame 跟随宿主 bounds。
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
