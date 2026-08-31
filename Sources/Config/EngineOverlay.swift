import Foundation

/// 引擎配置链第 3 层（spec §4.7）：QuickTerm 生成的覆盖文件。
/// M1 固定注入透明度与 padding；M3 起由 ThemeManager 按当前主题重写。
enum EngineOverlay {
    static var url: URL {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("QuickTerm", isDirectory: true)
        return dir.appendingPathComponent("engine-overlay.conf")
    }

    /// 写入覆盖文件并返回其路径（失败返回 nil，链上其余层不受影响）。
    @discardableResult
    static func install(extra: String = "") -> String? {
        let contents = """
        # 由 QuickTerm 生成，请勿手改（会被覆盖）。用户配置请写 ~/.config/ghostty/config
        # 或 ~/.config/quickterm/config.toml 的 [ghostty] 段。
        window-padding-x = 2
        window-padding-y = 2
        # macOS 26 的 CVDisplayLink（已废弃 API）存在会话级配额：大量创建 surface 后
        # CVDisplayLinkCreateWithActiveCGDisplays 会失败（表现为 surface init OOM）。
        # 关闭 vsync 完全绕开 DisplayLink（渲染仍由 CoreAnimation 节流）。
        # 详见 docs/porting-notes.md「DisplayLink 会话配额」。
        window-vsync = false
        \(extra)
        """
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: url, atomically: true, encoding: .utf8)
            return url.path
        } catch {
            return nil
        }
    }
}
