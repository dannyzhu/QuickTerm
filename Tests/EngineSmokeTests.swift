import XCTest
import GhosttyKit

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
