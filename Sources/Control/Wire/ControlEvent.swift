import Foundation

/// 事件类型（Phase 4）。**新增只能追加**：agent 按 `type` 字符串分支，绝不按文案分支。
///
/// ⚠️ 这张表里**没有、也绝不会有**"pane 输出"这一类。
/// 把 shell 的输出推到 socket 上等于把密码、token、ssh 会话内容原样交出去，
/// 而且流控复杂度（tmux 为此专门做了 `%pause` / `%extended-output`）全是白付的代价。
/// 事件只携带**结构**（谁开了、谁关了、焦点在哪、布局是什么）与两项元数据（标题、cwd）。
enum ControlEventType: String, Codable, CaseIterable {
    case paneOpened = "pane.opened"
    case paneClosed = "pane.closed"
    case focusChanged = "focus.changed"
    case workspaceChanged = "workspace.changed"
    case layoutChanged = "layout.changed"
    case screenOpened = "screen.opened"
    case screenClosed = "screen.closed"
    case paneTitleChanged = "pane.title.changed"
    case paneCwdChanged = "pane.cwd.changed"

    var summary: String {
        switch self {
        case .paneOpened: "新建了一个 pane（终端 / 浏览器 / 文件管理器）"
        case .paneClosed: "一个 pane 关掉了（进入关闭动效即上报，与 state 的可寻址口径一致）"
        case .focusChanged: "某块屏幕的键盘焦点换了 pane"
        case .workspaceChanged: "某块屏幕切了工作区"
        case .layoutChanged: "某个工作区的结构变了（布局种类 / 列宽 / split 比例 / zoom / 浮动层）"
        case .screenOpened: "新建了一块屏幕（窗口）"
        case .screenClosed: "一块屏幕关掉了"
        case .paneTitleChanged: "pane 标题变了（**不是**输出内容）"
        case .paneCwdChanged: "终端 pane 的工作目录变了（OSC 7）"
        }
    }
}

/// 一条事件。字段全部可选，只填这一类事件真正说得清的那几项。
///
/// **纯 Foundation**：本目录同时编进 app 与 `quickterm` 工具 target。
struct ControlEvent: Codable, Equatable {
    /// 单调递增，与 `state` / 每条响应里的 `seq` 是同一个计数器
    var seq: Int
    /// ISO8601（带毫秒）
    var ts: String
    var type: String
    var screen: Int?
    var screenID: String?
    var workspace: Int?
    var pane: String?
    var paneID: String?
    var kind: String?
    var layout: String?
    /// pane.title.changed / pane.opened 的标题；浏览器 pane 对无 token 的调用方是 `<redacted>`
    var title: String?
    /// pane.cwd.changed / pane.opened 的工作目录
    var cwd: String?
    /// 这条事件里的 title / cwd 被打码了（与 `state` 同一条规则）
    var redacted: Bool?

    static let redactedPlaceholder = "<redacted>"

    init(seq: Int = 0, ts: String = "", type: ControlEventType,
         screen: Int? = nil, screenID: String? = nil, workspace: Int? = nil,
         pane: String? = nil, paneID: String? = nil, kind: String? = nil,
         layout: String? = nil, title: String? = nil, cwd: String? = nil,
         redacted: Bool? = nil) {
        self.seq = seq
        self.ts = ts
        self.type = type.rawValue
        self.screen = screen
        self.screenID = screenID
        self.workspace = workspace
        self.pane = pane
        self.paneID = paneID
        self.kind = kind
        self.layout = layout
        self.title = title
        self.cwd = cwd
        self.redacted = redacted
    }

    /// 时间戳：ISO8601 + 毫秒（每条事件一份，格式化器是静态的）
    static func stamp(_ date: Date = Date()) -> String { formatter.string(from: date) }

    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f
    }()
}

/// `events poll` / `events follow` 的负载
struct ControlEventsPayload: Codable, Equatable {
    var schema = "quickterm.events/1"
    /// 这一批事件（按 seq 升序）
    var events: [ControlEvent]
    /// **下一次 `--since` 就该给它**（哪怕这一批是空的）。
    ///
    /// 这是**游标**，不一定是当下的全局 seq：`truncated` 为真时它指向这一批里
    /// 最后一条真的送出去的事件，被 `--limit` 砍掉的那些下一轮才补。
    /// 照着它轮下去，一条事件既不会漏也不会重复
    var seq: Int
    /// 环形缓冲里还留着的最老一条
    var oldest: Int?
    /// `--since` 比 `oldest` 还老：中间有事件被挤掉了，手里的快照不完整，重新读一次 `state`
    var missed: Bool?
    /// 长轮询到点，没有任何事件（**不是错误**：再拿同一个 seq 轮一次即可）
    var timedOut: Bool?
    /// 这一批被 `--limit` 截断了，缓冲里还压着更多：拿着上面那个 `seq` **立刻**再轮一次，
    /// 不必等下一次 timeout（`missed` 说的是另一件事——那是事件已经被挤掉、再也拿不回来了）
    var truncated: Bool?
    /// 这是 `events follow` 流里的一批（连接会一直开着）
    var follow: Bool?
}

/// 事件相关的常量（app 与 CLI 共用一份）
enum ControlEventLimits {
    /// 环形缓冲容量：超出后最老的被挤掉，`missed` 会告诉调用方
    static let ringCapacity = 512
    /// 一次 poll 最多回多少条
    static let maxBatch = 256
    /// 同时最多几条 `events follow`（每条占住一条连接）
    static let maxFollowers = 8
    static let defaultPollTimeout: TimeInterval = 5
    static let maxPollTimeout: TimeInterval = 300

    /// `--timeout 5s` / `500ms` / `5`（秒）。**认不得的写法一律报错，绝不悄悄当默认值**
    static func parseTimeout(_ raw: String?) throws -> TimeInterval {
        guard let raw, !raw.isEmpty else { return defaultPollTimeout }
        let text = raw.trimmingCharacters(in: .whitespaces).lowercased()
        let value: Double?
        var scale = 1.0
        if text.hasSuffix("ms") {
            value = Double(text.dropLast(2))
            scale = 0.001
        } else if text.hasSuffix("s") {
            value = Double(text.dropLast())
        } else if text.hasSuffix("m") {
            value = Double(text.dropLast())
            scale = 60
        } else {
            value = Double(text)
        }
        guard let value, value >= 0, value.isFinite else {
            throw ControlErrorBody(.badRequest, "--timeout 认不得 \(raw)",
                                   hint: "写成 5s / 500ms / 2m，或直接给秒数")
        }
        let seconds = value * scale
        guard seconds <= maxPollTimeout else {
            throw ControlErrorBody(.badRequest,
                                   "--timeout 最多 \(Int(maxPollTimeout))s（给了 \(Int(seconds))s）",
                                   hint: "长轮询到点会回一批空的，再轮一次即可")
        }
        return seconds
    }

    /// `--types pane.opened,focus.changed`。认不得的类型名一律报错并列出全部
    static func parseTypes(_ raw: String?) throws -> Set<String>? {
        guard let raw, !raw.isEmpty else { return nil }
        let names = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !names.isEmpty else { return nil }
        let known = Set(ControlEventType.allCases.map(\.rawValue))
        for name in names where !known.contains(name) {
            throw ControlErrorBody(.badRequest, "未知事件类型 \(name)",
                                   hint: "quickterm describe --json 的 events 里有全部类型",
                                   candidates: ControlEventType.allCases.map(\.rawValue))
        }
        return Set(names)
    }
}
