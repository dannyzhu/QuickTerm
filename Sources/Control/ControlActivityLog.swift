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

        /// 应用内那一份（活动日志面板）：值写全。看的人就是这台机器前面的用户本人
        var line: String { render(redactingSensitiveValues: false) }

        /// 写进 OSLog 的那一份：`sensitive` 的变更只留 `path`。
        ///
        /// 这两份不一样**是有意的**：面板是给用户看的一瞥，而 OSLog 落在
        /// /var/db/diagnostics——任何管理员读得到、sysdiagnose 会打包带走、应用关了还在。
        /// 把一个默认要按 token 打码的网址/标题原样写进那里，等于给打码开了一扇后门
        /// （`input.send-text` 早就是这么办的：正文从不入日志，只记「N 个字符」）
        var logLine: String { render(redactingSensitiveValues: true) }

        private func render(redactingSensitiveValues redacting: Bool) -> String {
            let stamp = Entry.formatter.string(from: at)
            let origin = originPane.map { " ←\($0)" } ?? ""
            let where_ = target.map { " @\($0)" } ?? ""
            let diff = changes.isEmpty ? "" : "  " + changes.map {
                if redacting, $0.sensitive { return "\($0.path): 已变更（值不入日志）" }
                return "\($0.path): \($0.from ?? "-") → \($0.to ?? "-")"
            }.joined(separator: "，")
            return "\(stamp)  \(command)\(where_)  [\(outcome)]  \(peer)\(origin)\(diff)"
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
