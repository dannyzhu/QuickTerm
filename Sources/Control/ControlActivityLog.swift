import AppKit
import OSLog

/// 应用内的控制面活动日志（环形缓冲，最近 200 条）。
///
/// 为什么要有：`mutate` 类命令是**静默执行**的——不弹框、不问人。
/// 静默的前提是事后可见：状态栏闪一下告诉用户"刚刚有人动了什么"，
/// 而这份日志回答"到底动了哪些"。没有它，一个跑飞的 agent 留下的
/// 唯一痕迹就是"布局莫名其妙变了"。
///
/// 同时写一份到 OSLog（`log stream --predicate 'subsystem == "dev.danny.quickterm"'`），
/// 这样应用崩了、或者用户事后才发现不对劲，痕迹也还在。
@MainActor
final class ControlActivityLog: ObservableObject {
    static let shared = ControlActivityLog()
    static let capacity = 200

    static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "dev.danny.quickterm",
                               category: "ControlActivity")

    struct Entry: Identifiable, Equatable {
        let id = UUID()
        var at: Date
        /// 线上的命令名（`pane.new`）
        var command: String
        /// 内核给的对端进程名 + pid（**唯一可信的身份**）
        var peer: String
        /// 调用方自称所在的 pane（带 token 才有；文案里始终写"自称"）
        var originPane: String?
        /// 落点（`1:2.t7`）
        var target: String?
        /// 结果：applied / noop / dry-run / 各种错误码
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

        /// 应用内那一份（活动日志面板）：值写全。看的人就是这台机器前面的用户本人
        var line: String { render(redactingSensitiveValues: false, localizingOutcome: true) }

        /// 写进 OSLog 的那一份：`sensitive` 的变更只留 `path`。
        ///
        /// 这两份不一样**是有意的**：面板是给用户看的一瞥，而 OSLog 落在
        /// /var/db/diagnostics——任何管理员读得到、sysdiagnose 会打包带走、应用关了还在。
        /// 把一个默认要按 token 打码的网址/标题原样写进那里，等于给打码开了一扇后门
        /// （`input.send-text` 早就是这么办的：正文从不入日志，只记「N 个字符」）
        var logLine: String { render(redactingSensitiveValues: true, localizingOutcome: false) }

        private func render(redactingSensitiveValues redacting: Bool,
                            localizingOutcome localizing: Bool) -> String {
            let stamp = Entry.formatter.string(from: at)
            let origin = originPane.map { " ←\($0)" } ?? ""
            let where_ = target.map { " @\($0)" } ?? ""
            let diff = changes.isEmpty ? "" : "  " + changes.map {
                if redacting, $0.sensitive { return "\($0.path): 已变更（值不入日志）" }
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

    /// 最近 N 条（新的在前）
    func recent(_ n: Int = 50) -> [Entry] { Array(entries.suffix(n).reversed()) }

    func clear() { entries.removeAll() }
}
