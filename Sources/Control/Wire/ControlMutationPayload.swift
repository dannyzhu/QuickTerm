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

    init(command: String, applied: Bool, changed: Bool, dryRun: Bool,
         changes: [ControlChange] = [], pane: ControlStatePayload.PaneInfo? = nil,
         panes: [ControlStatePayload.PaneInfo]? = nil,
         workspace: ControlStatePayload.WorkspaceInfo? = nil,
         screen: ControlStatePayload.ScreenInfo? = nil,
         focusPending: Bool? = nil, confirmPending: Bool? = nil,
         undo: String? = nil, note: String? = nil, spec: ControlSpecApplyReport? = nil) {
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
    }
}

/// 一条 diff。`path` 用与寻址语法同形的写法（`1:2.t7.zoom`），
/// 这样 agent 读到的 diff 与它下一条命令要写的目标是同一套词汇
struct ControlChange: Codable, Equatable {
    var path: String
    var from: String?
    var to: String?

    init(_ path: String, from: String?, to: String?) {
        self.path = path
        self.from = from
        self.to = to
    }
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
