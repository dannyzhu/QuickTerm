import AppKit
import OSLog

/// In-app activity log for the control plane (ring buffer, the last 200 entries).
///
/// Why it exists: `mutate` commands run **silently** — no dialog, nobody gets asked. Silence is
/// only defensible if it stays visible after the fact: the status-bar flash tells the user that
/// somebody just changed something, and this log answers what exactly they changed. Without it,
/// the only trace a runaway agent leaves behind is "the layout went strange on its own".
///
/// Every entry is mirrored into OSLog as well (`log stream --predicate 'subsystem ==
/// "dev.danny.quickterm"'`), so the trail survives an app crash, or a user who only notices
/// something is wrong long after the fact.
@MainActor
final class ControlActivityLog: ObservableObject {
    static let shared = ControlActivityLog()
    static let capacity = 200

    static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "dev.danny.quickterm",
                               category: "ControlActivity")

    struct Entry: Identifiable, Equatable {
        let id = UUID()
        var at: Date
        /// The command's name on the wire (`pane.new`)
        var command: String
        /// Peer process name + pid as the kernel reports them (**the only trustworthy identity**)
        var peer: String
        /// The pane the caller claims to be in (only set when it carried the token; the wording
        /// always says "claims")
        var originPane: String?
        /// Where it landed (`1:2.t7`)
        var target: String?
        /// Outcome: applied / noop / dry-run / one of the error codes
        var outcome: String
        var changes: [ControlChange]

        /// The vocabulary `outcome` is written in.
        ///
        /// These tokens are English in both UI languages, because the very same value is
        /// mirrored into OSLog — which is read with `log stream`, long after the fact, often by
        /// somebody who is not this user. `localizedOutcome` translates the two that are
        /// sentences for the in-app panel; `applied` / `noop` / `dry-run` are the CLI's own
        /// words and stay as they are on both sides.
        enum Outcome {
            static let applied = "applied"
            static let noop = "noop"
            static let noopFailIfNoop = "noop(exit 7)"
            static let dryRun = "dry-run"
            static let failedPrefix = "failed: "
            static let refusedPrefix = "refused: "

            static func failed(_ code: String) -> String { failedPrefix + code }
            static func refused(_ code: String) -> String { refusedPrefix + code }
        }

        /// The in-app copy (the activity-log panel): values written out in full. Whoever reads
        /// it is the user sitting at this machine.
        var line: String { render(redactingSensitiveValues: false, localizingOutcome: true) }

        /// The copy written into OSLog: a `sensitive` change keeps only its `path`.
        ///
        /// The two copies differ **on purpose**: the panel is a glance for the user, while OSLog
        /// lands in /var/db/diagnostics — readable by any admin, swept up by sysdiagnose, still
        /// there after the app is gone. A URL or title that is redacted by default unless the
        /// caller holds the token opens a back door around that redaction the moment it is
        /// written into that file verbatim. (`input.send-text` has worked this way from the
        /// start: the payload never enters the log, only "N characters".)
        var logLine: String { render(redactingSensitiveValues: true, localizingOutcome: false) }

        private func render(redactingSensitiveValues redacting: Bool,
                            localizingOutcome localizing: Bool) -> String {
            let stamp = Entry.formatter.string(from: at)
            let origin = originPane.map { " ←\($0)" } ?? ""
            let where_ = target.map { " @\($0)" } ?? ""
            let diff = changes.isEmpty ? "" : "  " + changes.map {
                if redacting, $0.sensitive { return "\($0.path): changed (value kept out of the log)" }
                return "\($0.path): \($0.from ?? "-") → \($0.to ?? "-")"
            }.joined(separator: ", ")
            let result = localizing ? localizedOutcome : outcome
            return "\(stamp)  \(command)\(where_)  [\(result)]  \(peer)\(origin)\(diff)"
        }

        /// `outcome` as the activity-log panel shows it: the stored token is English and reaches
        /// OSLog untouched, only this rendering follows the UI language.
        private var localizedOutcome: String {
            if outcome.hasPrefix(Outcome.failedPrefix) {
                return L("control.activity.outcome.failed",
                         String(outcome.dropFirst(Outcome.failedPrefix.count)))
            }
            if outcome.hasPrefix(Outcome.refusedPrefix) {
                return L("control.activity.outcome.refused",
                         String(outcome.dropFirst(Outcome.refusedPrefix.count)))
            }
            return outcome
        }

        static let formatter: DateFormatter = {
            let f = DateFormatter()
            f.dateFormat = "HH:mm:ss"
            return f
        }()
    }

    @Published private(set) var entries: [Entry] = []

    private init() {}

    func record(_ entry: Entry) {
        entries.append(entry)
        if entries.count > Self.capacity { entries.removeFirst(entries.count - Self.capacity) }
        Self.logger.notice("\(entry.logLine, privacy: .public)")
    }

    /// The most recent N entries (newest first)
    func recent(_ n: Int = 50) -> [Entry] { Array(entries.suffix(n).reversed()) }

    func clear() { entries.removeAll() }
}
