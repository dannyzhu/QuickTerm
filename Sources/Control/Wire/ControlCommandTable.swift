import Foundation

/// **一切从这一张表生成**：CLI 解析、`--help`、`describe --json`、安全分级，
/// 以及（Phase 5）MCP 工具表。命令表之外不得手写第二份命令描述——
/// 手写的那份两个版本之内必然漂移，而 agent 拿着漂移的 schema 只会得到自己解释不了的退出码 3。
enum ControlCommandClass: String, Codable, CaseIterable {
    /// 静默放行（无 token 的调用方读不到浏览器 URL / 标题）
    case read
    /// 静默执行，但可见（Phase 2 的状态栏闪烁 + 撤销登记）
    case mutate
    /// 会毁掉用户的东西（关 pane / 关屏幕）：按 (peer, 类) 确认一次
    case destructive
    /// 会打开需要键盘交互的面板 / 弹出菜单：**经 socket 一律拒绝**
    case interactive
    /// 触碰用户的隐私或别人的 tty（send-text、读浏览器 URL）：Phase 4
    case sensitive

    var requiresConsent: Bool { self == .destructive || self == .sensitive }
    var isMutation: Bool { self != .read }
}

struct ControlArgSpec: Codable, Equatable {
    enum Kind: String, Codable { case string, int, double, bool, enumeration }

    var name: String
    var kind: Kind
    var required: Bool
    var positional: Bool
    var values: [String]?
    var defaultValue: String?
    var help: String

    init(_ name: String, _ kind: Kind, help: String, required: Bool = false,
         positional: Bool = false, values: [String]? = nil, defaultValue: String? = nil) {
        self.name = name
        self.kind = kind
        self.required = required
        self.positional = positional
        self.values = values
        self.defaultValue = defaultValue
        self.help = help
    }
}

struct ControlCommandSpec: Codable, Equatable {
    var name: String
    var summary: String
    var cls: ControlCommandClass
    /// 同样的输入跑两次结果一致（Phase 5 映射成 MCP 的 idempotentHint）
    var idempotent: Bool
    var acceptsTarget: Bool
    /// 完全在 CLI 侧完成，不经 socket（`install-cli`、`--help`）
    var local: Bool
    var args: [ControlArgSpec]
    var examples: [String]
    /// 查询类命令内嵌一段真实的（节选）输出样例——
    /// 这是 wezterm 的 `--help` 缺、kitty 的文档有的那一项，能替 agent 省掉每个会话一次探路调用
    var outputSample: String?
}

enum ControlCommandTable {
    // MARK: 命令

    static let commands: [ControlCommandSpec] = [
        ControlCommandSpec(
            name: "state",
            summary: "读整个会话：扁平 pane 数组 + 引用句柄的屏幕/工作区骨架",
            cls: .read, idempotent: true, acceptsTarget: true, local: false,
            args: [
                ControlArgSpec("fields", .string,
                               help: "只输出这些 pane 字段（逗号分隔，如 handle,cwd,title）"),
            ],
            examples: [
                "quickterm state",
                "quickterm state --json | jq '.data.panes[] | select(.focused)'",
                "quickterm state -t 2 --fields handle,title,cwd",
            ],
            outputSample: stateSample),
        ControlCommandSpec(
            name: "list",
            summary: "列出 screens / workspaces / panes",
            cls: .read, idempotent: true, acceptsTarget: true, local: false,
            args: [
                ControlArgSpec("what", .enumeration, help: "要列的东西", required: true,
                               positional: true, values: ["screens", "workspaces", "panes"]),
                ControlArgSpec("fields", .string, help: "只输出这些字段（逗号分隔）"),
            ],
            examples: [
                "quickterm list panes",
                "quickterm list workspaces -t 2",
                "quickterm list panes --json | jq -r '.data.panes[].handle'",
            ],
            outputSample: listSample),
        ControlCommandSpec(
            name: "get",
            summary: "读单个 pane 的完整记录",
            cls: .read, idempotent: true, acceptsTarget: true, local: false,
            args: [],
            examples: [
                "quickterm get -t t7",
                "quickterm get -t @self",
                "quickterm get -t 'title:~nvim'",
            ],
            outputSample: getSample),
        ControlCommandSpec(
            name: "action",
            summary: "执行一个 WM 动作（快捷键平价直通车；全部 \(WMAction.allCases.count) 个）",
            cls: .mutate, idempotent: false, acceptsTarget: true, local: false,
            args: [
                ControlArgSpec("name", .string, help: "动作名（kebab-case，见 --list）",
                               required: true, positional: true),
                ControlArgSpec("list", .bool, help: "列出全部动作及其分级，不执行"),
                ControlArgSpec("precise", .bool, help: "精细步长（等价按住 Shift 的 resize-*）"),
            ],
            examples: [
                "quickterm action new-terminal",
                "quickterm action goto-workspace-3 -t 2",
                "quickterm action --list --json",
            ],
            outputSample: nil),
        ControlCommandSpec(
            name: "describe",
            summary: "把整个控制面当作机器可读的 schema 吐出来（agent 每个会话读一次即可）",
            cls: .read, idempotent: true, acceptsTarget: false, local: false,
            args: [],
            examples: [
                "quickterm describe --json",
                "quickterm describe --json | jq '.commands[].name'",
            ],
            outputSample: nil),
        ControlCommandSpec(
            name: "version",
            summary: "打印 CLI 与运行中 QuickTerm 的版本、协议版本、socket 路径",
            cls: .read, idempotent: true, acceptsTarget: false, local: false,
            args: [],
            examples: ["quickterm version", "quickterm version --json"],
            outputSample: nil),
        ControlCommandSpec(
            name: "install-cli",
            summary: "把 quickterm（可选 qt 别名）软链到 PATH——绝不弹管理员密码",
            cls: .read, idempotent: true, acceptsTarget: false, local: true,
            args: [
                ControlArgSpec("alias", .string, help: "另建一个短别名（通常是 qt）"),
                ControlArgSpec("dir", .string, help: "安装目录（默认 /usr/local/bin，不可写则 ~/.local/bin）"),
            ],
            examples: [
                "quickterm install-cli",
                "quickterm install-cli --alias qt",
            ],
            outputSample: nil),
    ]

    static func command(_ name: String) -> ControlCommandSpec? {
        commands.first { $0.name == name }
    }

    /// 全局开关（每条子命令都能用）
    static let globalFlags: [ControlArgSpec] = [
        ControlArgSpec("target", .string, help: "目标 screen:workspace.pane（-t）"),
        ControlArgSpec("json", .bool, help: "强制 JSON 输出（stdout 非 TTY 时本来就是 JSON）"),
        ControlArgSpec("plain", .bool, help: "强制人类可读输出"),
        ControlArgSpec("socket", .string, help: "指定 socket 路径（默认读 QUICKTERM_SOCKET）"),
        ControlArgSpec("help", .bool, help: "帮助（每条子命令都以 EXAMPLES 结尾）"),
    ]

    // MARK: WMAction 的安全分级

    /// 打开覆盖面板 / 弹出菜单，之后要靠方向键与回车才能用完——**经 socket 执行等于把 UI 卡在半路**。
    /// `web-extensions` 也在内：`NSMenu.popUp` 会跑一个事件跟踪循环，直接把主线程连同控制服务一起卡住
    /// （比另外 5 个更糟：它连"用户按 Esc"都没有明显的提示）。
    /// 这些动作的替代路径留给 Phase 2 的 `app set theme …` / `app set background …`。
    static let interactiveActions: Set<WMAction> = [
        .themePicker, .backgroundMenu, .keybindingHelp, .mainMenu, .openSettings, .webExtensions,
    ]

    /// 会毁掉用户东西的动作：关闭 pane 会结束其中的进程
    static let destructiveActions: Set<WMAction> = [.closePane]

    static func actionClass(_ action: WMAction) -> ControlCommandClass {
        if interactiveActions.contains(action) { return .interactive }
        if destructiveActions.contains(action) { return .destructive }
        return .mutate
    }

    /// 该动作被 socket 拒绝时给的具体去处
    static func interactiveHint(_ action: WMAction) -> String {
        switch action {
        case .themePicker: "主题面板要靠键盘选择；改主题请写 ~/.config/quickterm/config.toml 的 theme（Phase 2 会有 app set theme）"
        case .backgroundMenu: "背景面板要靠键盘选择（Phase 2 会有 app set background）"
        case .keybindingHelp, .mainMenu: "这是给人看的覆盖面板；机器要的清单在 quickterm describe --json"
        case .openSettings: "它会拉起外部编辑器；直接编辑 ~/.config/quickterm/config.toml 即可"
        case .webExtensions: "它会弹出 NSMenu 并占住主线程；扩展管理请在 QuickTerm 里操作"
        default: "该动作需要键盘交互，不能经 socket 执行"
        }
    }

    struct ActionDoc: Codable, Equatable {
        var name: String
        var cls: ControlCommandClass
        var helpZH: String
        var browserOnly: Bool
        var terminalOnly: Bool
        var workspace: Int?
        var hint: String?
    }

    /// 全部 WMAction 的机器可读清单（`describe` 与 `action --list` 同一出处；
    /// `ControlActionTests` 钉死它与 `WMAction.allCases` 逐一对应）
    static var actionDocs: [ActionDoc] {
        WMAction.allCases.map { action in
            let cls = actionClass(action)
            return ActionDoc(
                name: action.rawValue,
                cls: cls,
                helpZH: action.help,
                browserOnly: action.browserOnly,
                terminalOnly: action.terminalOnly,
                workspace: action.workspaceIndex.map { $0 + 1 },
                hint: cls == .interactive ? interactiveHint(action) : nil)
        }
    }

    // MARK: 输出样例（`--help` 内嵌；`ControlWireTests` 会把它们重新 parse 一遍）

    static let stateSample = """
    {"ok":true,"seq":412,"data":{
      "schema":"quickterm.state/1",
      "app":{"version":"1.5.8","protocol":1,"workspaceCount":5},
      "screens":[{"index":1,"id":"3F2A9C…","title":"QuickTerm","key":true,"activeWorkspace":2,
        "visibleColumns":2,"fullscreen":false,
        "workspaces":[{"index":1,"layout":"scrolling","empty":true,"panes":[]},
                      {"index":2,"layout":"scrolling","empty":false,"panes":["t1","t2"],
                       "columns":[{"width":0.485,"panes":["t1"]},{"width":0.485,"panes":["t2"]}]}]}],
      "panes":[{"handle":"t1","id":"9C1B4E…","kind":"terminal","role":"shell","screen":1,
                "workspace":2,"at":{"column":0,"row":0},"title":"nvim  ~/proj",
                "cwd":"/Users/danny/proj","focused":true,"busy":true,"float":false,"zoom":false},
               {"handle":"b3","id":"41EE07…","kind":"browser","screen":1,"workspace":2,
                "title":"<redacted>","url":"<redacted>","tabs":2,"focused":false}]}}
    """

    static let listSample = """
    {"ok":true,"seq":412,"data":{"panes":[
      {"handle":"t1","kind":"terminal","screen":1,"workspace":2,"title":"zsh","focused":true},
      {"handle":"b3","kind":"browser","screen":1,"workspace":2,"title":"<redacted>"}]}}
    """

    static let getSample = """
    {"ok":true,"seq":412,"resolved":{"screen":1,"workspace":2,"pane":"t7"},
     "data":{"pane":{"handle":"t7","id":"C40D…","kind":"terminal","role":"shell",
       "screen":1,"workspace":2,"at":{"column":2,"row":0},"title":"npm run dev",
       "cwd":"/Users/danny/proj","focused":false,"busy":true,"float":false,"zoom":false}}}
    """
}
