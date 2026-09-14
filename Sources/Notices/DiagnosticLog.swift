import Foundation

/// **A plain-text file log of the notification and agent-state decision path**, off by default and
/// turned on with `[notifications] diagnostic-log = true`.
///
/// It exists because this app's OSLog cannot be read back reliably after the fact (the unified log
/// drops our subsystem on this machine), so when a banner or a Dock badge does not appear the only
/// way to see *why* is a file the user can enable, reproduce with, and hand over. Every line is one
/// timestamped event: what signal arrived, what the notice centre decided, what each sink did, and
/// the counts and authorization at that instant.
///
/// **Never program output.** Notice titles are payload-free by construction (an agent name, a
/// state, a tool name — see `Notice`), so they are safe to write; notice *bodies*, which carry a
/// program's own words, are never written here. The pane is named by its short handle, not its
/// contents.
///
/// Path: `~/Library/Logs/QuickTerm/diagnostics.log`, appended (the directory is created on first
/// write). One file across launches; a `launch` line separates runs. When logging is off, `note`
/// is a single boolean test and returns before building its message (the argument is
/// `@autoclosure`), so an instrumented hot path costs nothing until somebody asks for the log.
@MainActor
final class DiagnosticLog {
    static let shared = DiagnosticLog()

    /// Set from `[notifications] diagnostic-log` on every config load and reload. Turning it on
    /// opens the file and writes a launch marker; turning it off closes the handle.
    var isEnabled = false {
        didSet {
            guard isEnabled != oldValue else { return }
            if isEnabled { open() } else { close() }
        }
    }

    private var handle: FileHandle?

    /// `~/Library/Logs/QuickTerm/diagnostics.log`. `Library/Logs` is the standard place a macOS app
    /// leaves logs the user can find in Console.app, and it is not the config or state directory, so
    /// enabling this never touches anything QuickTerm reads back.
    let url: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/QuickTerm/diagnostics.log")

    private let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private init() {}

    /// Where the log is, so a command or the settings UI can tell the user.
    var path: String { url.path }

    /// Record one event. `category` is a short tag (`notice`, `counts`, `badge`, `banner`,
    /// `activity`, `agent`, `auth`, `selftest`). `message` is only built when logging is on.
    func note(_ category: String, _ message: @autoclosure () -> String) {
        guard isEnabled, let handle else { return }
        let line = "\(formatter.string(from: Date())) [\(category)] \(message())\n"
        guard let data = line.data(using: .utf8) else { return }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            // A write that fails (disk full, the file deleted under us) must never take a notice
            // down with it: drop the handle and carry on silently. The next `open()` restores it.
            self.handle = nil
        }
    }

    private func open() {
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: url)
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        note("launch", "diagnostic log on — QuickTerm \(version) (\(build))")
    }

    private func close() {
        note("launch", "diagnostic log off")
        try? handle?.close()
        handle = nil
    }
}
