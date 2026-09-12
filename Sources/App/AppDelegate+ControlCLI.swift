import AppKit

/// The "Install quickterm Command Line Tool..." menu item.
/// There is exactly one copy of the install logic: it lives in the bundled `quickterm` binary (the
/// `install-cli` subcommand), and this only runs it and shows the result. A second copy inside the
/// app would inevitably drift away from the CLI's.
@MainActor
extension AppDelegate {
    /// Where the bundled CLI lives: `QuickTerm.app/Contents/SharedSupport/quickterm`.
    /// It **cannot** go in Contents/MacOS: APFS is case-insensitive by default, so `quickterm`
    /// would overwrite the main executable `QuickTerm`.
    static var bundledCLIURL: URL? {
        Bundle.main.sharedSupportURL?.appendingPathComponent("quickterm")
    }

    /// "Control Plane Activity...": lays the recent control commands out for the user.
    /// `mutate` commands put up no dialog and ask no one - the user being able to look them up
    /// afterwards is the precondition that makes that design defensible.
    @objc func controlActivityAction(_ sender: Any?) {
        let entries = ControlActivityLog.shared.recent(40)
        let alert = NSAlert()
        alert.messageText = Lp("window.control-activity.title", count: entries.count, entries.count)
        alert.informativeText = entries.isEmpty
            ? L("window.control-activity.empty",
                ControlEnvironment.socketPath ?? L("window.control-activity.socket-none"))
            : entries.map(\.line).joined(separator: "\n")
        alert.addButton(withTitle: L("window.button.ok"))
        if !entries.isEmpty { alert.addButton(withTitle: L("window.control-activity.button.clear")) }
        if alert.runModal() == .alertSecondButtonReturn { ControlActivityLog.shared.clear() }
    }

    @objc func installCLIAction(_ sender: Any?) {
        let alert = NSAlert()
        guard let cli = Self.bundledCLIURL, FileManager.default.isExecutableFile(atPath: cli.path) else {
            alert.messageText = L("window.install-cli.missing-title")
            alert.informativeText = L("window.install-cli.missing-detail")
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
            alert.messageText = L("window.install-cli.failed-title")
            alert.informativeText = "\(error)"
            alert.runModal()
            return
        }
        let stdout = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        process.waitUntilExit()

        alert.messageText = process.terminationStatus == 0
            ? L("window.install-cli.installed-title")
            : L("window.install-cli.failed-title")
        alert.informativeText = (process.terminationStatus == 0 ? stdout : stderr)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        alert.runModal()
    }
}
