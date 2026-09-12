import Foundation

/// Phase 2 名词-动词层的**统一响应信封**。
///
/// 三件事一次说清，省掉 agent 的第二次往返：
/// 1. `changed` —— 有没有东西要改（绝对设值的本质：第二次调用什么都不做）；
/// 2. `applied` —— 真的改了没有（`--dry-run` 恒为 false，`changes` 就是那份 diff）；
/// 3. 改完之后的实体（pane / workspace / screen）——读后写的窗口就此关上。
///
/// **纯 Foundation**：本目录同时编进 app 与 `quickterm` 工具 target。
struct ControlMutationPayload: Codable, Equatable {
    /// 线上的命令名（`pane.new`）
    var command: String
    /// 真的落到 UI 上了（dry-run 恒 false）
    var applied: Bool
    /// 有需要改的东西（false = 已经是目标状态；`--fail-if-noop` 下这条会变成退出码 7）
    var changed: Bool
    var dryRun: Bool
    /// 逐条 diff：`--dry-run` 时这就是"会改什么"的全部内容
    var changes: [ControlChange]
    var pane: ControlStatePayload.PaneInfo?
    /// 一次动了多个 pane 时（workspace clear）
    var panes: [ControlStatePayload.PaneInfo]?
    var workspace: ControlStatePayload.WorkspaceInfo?
    var screen: ControlStatePayload.ScreenInfo?
    /// 焦点交接是异步重试的（最长 0.75s）：返回时可能还没真正落到 `resolved.pane` 上
    var focusPending: Bool?
    /// QuickTerm 自己弹了一个"仍有进程在运行"的确认框，等用户回答（pane 还没关）
    var confirmPending: Bool?
    /// 登记到 `AppDelegate.undoManager` 的撤销项名字（有值 = 这一步可以撤销）
    var undo: String?
    /// 需要告诉调用方的额外事实（如"由 config.toml 监听落地，稍后生效"）
    var note: String?
    /// `spec apply` 的落地报告（新建 / 留用 / 关掉了哪些 pane）
    var spec: ControlSpecApplyReport?
    /// **命令成功了，但有一件调用方必须知道的事**（见 `ControlWarning`）。
    /// 最要紧的一条：显式给的 `--cwd` 被 macOS 隐私授权挡下来了，shell 起在了别处——
    /// 报一句平平无奇的 success 而把这件事咽掉，正是"pane 开了、目录没变"这类
    /// 谁也查不出来的故障的来源
    var warnings: [ControlWarning]?

    init(command: String, applied: Bool, changed: Bool, dryRun: Bool,
         changes: [ControlChange] = [], pane: ControlStatePayload.PaneInfo? = nil,
         panes: [ControlStatePayload.PaneInfo]? = nil,
         workspace: ControlStatePayload.WorkspaceInfo? = nil,
         screen: ControlStatePayload.ScreenInfo? = nil,
         focusPending: Bool? = nil, confirmPending: Bool? = nil,
         undo: String? = nil, note: String? = nil, spec: ControlSpecApplyReport? = nil,
         warnings: [ControlWarning]? = nil) {
        self.command = command
        self.applied = applied
        self.changed = changed
        self.dryRun = dryRun
        self.changes = changes
        self.pane = pane
        self.panes = panes
        self.workspace = workspace
        self.screen = screen
        self.focusPending = focusPending
        self.confirmPending = confirmPending
        self.undo = undo
        self.note = note
        self.spec = spec
        self.warnings = warnings
    }
}

/// 一条"做是做成了，但你得知道这件事"的告警。
///
/// 为什么不是错误：命令**确实**落地了（pane 开出来了、spec 也铺好了），
/// 把它变成失败会让每一个不在乎这件事的脚本都跟着挂掉。
/// 为什么不能只写进 `note`：`note` 是一句给人读的散文，
/// 而调用方要在 `code` 上分支（`cwd_denied` 是稳定的字符串，文案不是）。
///
/// 目前只有一个 code：`cwd_denied`——显式给的工作目录落在 macOS 的受保护目录里
/// （~/Desktop ~/Documents ~/Downloads）而本二进制没有授权，`WorkingDirectoryGate`
/// 把它挡下来了，shell 起在引擎的默认目录。要它变成硬错误的脚本加 `--require-cwd`
struct ControlWarning: Codable, Equatable {
    /// 稳定的机器码：**在它上面分支，绝不要去匹配 message**
    var code: String
    var message: String
    var hint: String?
    /// 调用方要求的那个路径
    var path: String?
    /// 实际用的那个（不知道就省略——引擎的默认目录由引擎决定）
    var used: String?

    init(code: String, message: String, hint: String? = nil,
         path: String? = nil, used: String? = nil) {
        self.code = code
        self.message = message
        self.hint = hint
        self.path = path
        self.used = used
    }

    static let cwdDenied = "cwd_denied"

    /// `--cwd` 被隐私守卫挡下来的那一条（`pane new` 与 `spec apply` 用的是同一份措辞——
    /// 两处各写一遍必然只改一处）
    static func cwdDenied(_ path: String, used: String?) -> ControlWarning {
        ControlWarning(
            code: cwdDenied,
            message: "Working directory \(path) could not be used: macOS counts it as a protected directory and "
                + "QuickTerm has not been granted Files and Folders access, so the shell started in the "
                + "default directory",
            hint: "Tick QuickTerm's entry under System Settings ▸ Privacy & Security ▸ Files and Folders and "
                + "restart it. Add --require-cwd to make this case fail outright instead.",
            path: path, used: used)
    }
}

/// `pane capture-text` 的两个上限。
///
/// 行数上限存在的理由不是省 CPU：整份历史（引擎默认能存上万行）塞进一次 JSON 响应，
/// 会把 agent 的上下文一次吃光，而它真正要的通常是最后几十行。
/// 字节上限则是最后一道闸——一行可以长到几 KB（`cat` 一个二进制文件）
enum ControlCaptureLimits {
    /// `--scrollback` 的上限
    static let maxScrollback = 5000
    /// 一次最多回多少字节的文本（超了从**头部**截：最近的输出永远留着）
    static let maxBytes = 256 * 1024
}

/// `pane capture-text` 的负载。**text 只在这条响应里出现一次**：
/// 不进活动日志、不进事件流、不进任何长期留存的记录（见 `ControlCaptureCommands`）
struct ControlCaptureTextPayload: Codable, Equatable {
    var command: String
    /// 读的是哪个 pane（与别处同一份 pane 记录）
    var pane: ControlStatePayload.PaneInfo
    /// 引擎量到的网格（`cols` × `rows`）——调用方由此知道这份文本被折行折在哪儿
    var cols: Int?
    var rows: Int?
    /// 真正回了多少行
    var lines: Int
    /// 其中有多少行来自可视区**之上**的历史（`--scrollback N` 要的那一段）
    var scrollback: Int
    /// 撞到长度上限被截断了（从**头部**截：最近的输出永远留着）
    var truncated: Bool?
    /// 可视区（加上可选的那段历史）的纯文本，行以 \n 分隔，行尾空白已去掉
    var text: String

    init(command: String, pane: ControlStatePayload.PaneInfo, cols: Int? = nil, rows: Int? = nil,
         lines: Int, scrollback: Int, truncated: Bool? = nil, text: String) {
        self.command = command
        self.pane = pane
        self.cols = cols
        self.rows = rows
        self.lines = lines
        self.scrollback = scrollback
        self.truncated = truncated
        self.text = text
    }
}

/// 一条 diff。`path` 用与寻址语法同形的写法（`1:2.t7.zoom`），
/// 这样 agent 读到的 diff 与它下一条命令要写的目标是同一套词汇
struct ControlChange: Codable, Equatable {
    var path: String
    var from: String?
    var to: String?
    /// 这一条的**值本身**是隐私：网页标题 / 网址、终端标题（里面常年躺着 cwd 或正在跑的命令行）。
    ///
    /// 响应里照给——那一侧早就按 token 打过码了（`browserVisible`），而且只发给这一个调用方。
    /// 但 `ControlActivityLog` 会把每条变更镜像一份进 OSLog，那份日志落在 /var/db/diagnostics：
    /// 任何管理员读得到、sysdiagnose 会打包带走、应用退出之后还留着。
    /// 一个默认要打码的字段被原样写进一份长期留存的公共日志，等于打码没做过。
    /// 于是：带这个标记的变更，进日志时只留 `path`。
    ///
    /// **不上线**（不在 CodingKeys 里）：它是本地的一条处置规则，不是回给调用方的数据。
    var sensitive: Bool = false

    init(_ path: String, from: String?, to: String?, sensitive: Bool = false) {
        self.path = path
        self.from = from
        self.to = to
        self.sensitive = sensitive
    }

    /// diff 里"数量 + 单位"的统一写法：`1 pane` / `3 panes`。
    /// 中文原文没有单复数，直译过去每个计数都会写出 "1 panes"
    static func count(_ n: Int, _ noun: String) -> String { "\(n) \(noun)\(n == 1 ? "" : "s")" }

    private enum CodingKeys: String, CodingKey { case path, from, to }
}

/// `app get` 的负载：每一项都带上可选值，agent 不必再猜合法输入
struct ControlAppPayload: Codable, Equatable {
    var settings: [Setting]

    struct Setting: Codable, Equatable {
        var key: String
        var value: String
        var choices: [String]?
        var scope: String     // "app" | "screen"
        var help: String
    }
}
