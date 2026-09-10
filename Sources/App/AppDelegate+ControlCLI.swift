import AppKit

/// 「安装 quickterm 命令行工具…」菜单项。
/// 安装逻辑只有一份——就在随包的 `quickterm` 二进制里（`install-cli` 子命令），
/// 这里只是把它跑一遍并把结果显示出来。在 app 里再写一份必然与 CLI 那份漂移。
@MainActor
extension AppDelegate {
    /// 随包 CLI 的位置：`QuickTerm.app/Contents/SharedSupport/quickterm`。
    /// **不能**放 Contents/MacOS —— APFS 默认大小写不敏感，`quickterm` 会覆盖掉主可执行文件 `QuickTerm`
    static var bundledCLIURL: URL? {
        Bundle.main.sharedSupportURL?.appendingPathComponent("quickterm")
    }

    @objc func installCLIAction(_ sender: Any?) {
        let alert = NSAlert()
        guard let cli = Self.bundledCLIURL, FileManager.default.isExecutableFile(atPath: cli.path) else {
            alert.messageText = "找不到随包的 quickterm"
            alert.informativeText = "应该在 QuickTerm.app/Contents/SharedSupport/quickterm。请重新构建或重新安装 QuickTerm。"
            alert.runModal()
            return
        }
        let process = Process()
        process.executableURL = cli
        process.arguments = ["install-cli", "--alias", "qt", "--plain"]
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do {
            try process.run()
        } catch {
            alert.messageText = "安装失败"
            alert.informativeText = "\(error)"
            alert.runModal()
            return
        }
        let stdout = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        process.waitUntilExit()

        alert.messageText = process.terminationStatus == 0 ? "quickterm 已装到 PATH" : "安装失败"
        alert.informativeText = (process.terminationStatus == 0 ? stdout : stderr)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        alert.runModal()
    }
}
