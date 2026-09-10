import Foundation

/// `quickterm describe --json`：整个控制面一次性吐成机器 schema。
/// 这是"把控制方法通过命令帮助信息提供给大模型"的正解——agent 会话开始时读一次，之后不必再读 `--help`。
/// **全部字段都从 `ControlCommandTable` / `WMAction` 生成**，没有第二份手写描述。
struct ControlDescribeDocument: Codable, Equatable {
    var schema = "quickterm.describe/1"
    var protocolVersion: Int
    var cliVersion: String
    var appVersion: String?
    var appRunning: Bool
    var socket: String?
    var mode: String?
    var phase: Int
    var targetGrammar: TargetGrammar
    var commands: [ControlCommandSpec]
    var globalFlags: [ControlArgSpec]
    var classes: [ClassDoc]
    var exitCodes: [ExitCodeDoc]
    var errorCodes: [ErrorCodeDoc]
    var actions: [ControlCommandTable.ActionDoc]
    var envVars: [EnvDoc]
    var notes: [String]

    struct TargetGrammar: Codable, Equatable {
        var syntax = "screen:workspace.pane"
        var lines: [String]
        var screen: [String]
        var workspace: [String]
        var pane: [String]
        var predicates: [String]
    }

    struct ClassDoc: Codable, Equatable {
        var name: String
        var policy: String
    }

    struct ExitCodeDoc: Codable, Equatable {
        var code: Int32
        var name: String
        var summary: String
    }

    struct ErrorCodeDoc: Codable, Equatable {
        var code: String
        var exit: Int32
        var summary: String
    }

    struct EnvDoc: Codable, Equatable {
        var name: String
        var summary: String
    }

    /// 破坏性命令的现行策略。**跟着实际 mode 走**：写死一句"会确认"的话，
    /// 在 readonly / off 下就成了假话，而 agent 是拿 describe 当合同读的
    static func destructivePolicy(mode: String?) -> String {
        switch mode {
        case "off": "控制面已关闭（[control] mode = \"off\"）：一律不执行"
        case "readonly": "只读模式（[control] mode = \"readonly\"）：一律拒绝，不会弹确认"
        default: "按 (调用进程 pid, 命令类) 在 QuickTerm 内确认一次；确认框里写明将被作用的那个 pane；超时 → 退出码 4"
        }
    }

    /// 唯一构造入口。`appVersion == nil` = 应用没在运行，CLI 拿本地命令表兜底
    static func make(cliVersion: String, appVersion: String?, socket: String?, mode: String?) -> ControlDescribeDocument {
        ControlDescribeDocument(
            protocolVersion: ControlProtocol.version,
            cliVersion: cliVersion,
            appVersion: appVersion,
            appRunning: appVersion != nil,
            socket: socket,
            mode: mode,
            phase: 1,
            targetGrammar: TargetGrammar(
                lines: ControlTarget.grammarLines,
                screen: ["<1 起序号>", "#<uuid>:", "@current", "@primary"],
                workspace: ["<1 起序号>", "@active", "@next", "@prev"],
                pane: ["t<N>", "b<N>", "#<uuid 或 ≥4 位前缀>", "@focused", "@self",
                       "@left", "@right", "@up", "@down", "@next", "@prev"],
                predicates: ["title:~<regex>", "cwd:<prefix>", "kind:terminal|browser", "role:file-manager"]),
            commands: ControlCommandTable.commands,
            globalFlags: ControlCommandTable.globalFlags,
            classes: [
                ClassDoc(name: ControlCommandClass.read.rawValue,
                         policy: "静默放行；无 token 的调用方读不到浏览器 URL/标题（<redacted>）"),
                ClassDoc(name: ControlCommandClass.mutate.rawValue,
                         policy: "静默执行（Phase 2 起状态栏可见 + ⌘Z 可撤销）"),
                ClassDoc(name: ControlCommandClass.destructive.rawValue,
                         policy: destructivePolicy(mode: mode)),
                ClassDoc(name: ControlCommandClass.interactive.rawValue,
                         policy: "一律拒绝：会打开需要键盘交互的面板 / 弹出菜单"),
                ClassDoc(name: ControlCommandClass.sensitive.rawValue,
                         policy: "Phase 4；默认关闭，需要 [control] send-text = true"),
            ],
            exitCodes: ControlExit.allCases.map {
                ExitCodeDoc(code: $0.rawValue, name: String(describing: $0), summary: $0.summary)
            },
            errorCodes: ControlErrorCode.allCases.map {
                ErrorCodeDoc(code: $0.rawValue, exit: $0.exit.rawValue, summary: $0.summary)
            },
            actions: ControlCommandTable.actionDocs,
            envVars: [
                EnvDoc(name: ControlProtocol.Env.socket, summary: "控制 socket 路径（每个新建 pane 都注入）"),
                EnvDoc(name: ControlProtocol.Env.pane, summary: "本 pane 的 UUID —— `-t @self` 就靠它"),
                EnvDoc(name: ControlProtocol.Env.screen, summary: "创建时所在屏幕序号（提示值；pane 移动后不更新）"),
                EnvDoc(name: ControlProtocol.Env.workspace, summary: "创建时所在工作区序号（提示值；pane 移动后不更新）"),
                EnvDoc(name: ControlProtocol.Env.token,
                       summary: "来源证明，**不是权限边界**：能证明命令来自 QuickTerm 开的 pane，但绝不跳过任何确认"),
            ],
            notes: [
                "stdout 不是 TTY 时默认输出 JSON；错误一律是 stderr 上的 JSON，带稳定 code。",
                "目标匹配到多个一律报错并在 candidates 里列出全部，绝不取第一个。",
                "`action` 是快捷键平价的直通车（唯一保留 toggle 语义的地方）；Phase 2 起请优先用绝对设值的名词-动词层。",
                "正在淡出（关闭动效中）的 pane 不可寻址；每条变更命令执行前都会先 flush。",
                "pane 的 `focused` 是**每块屏幕各自**的焦点；全局唯一的那个在 `key: true` 的屏幕上——"
                    + "恒有且只有一块屏幕是 `key`：应用在前台时是真正的 key 窗口，否则是最近一次成为 key 的那块。",
                "短句柄（t7/b3）只在 QuickTerm 这一次运行期间稳定；跨重启唯一稳定的身份是 `id`（UUID）。",
                "本阶段（Phase 1）只有查询与 action；pane/workspace/screen/spec/events/send-text 见 Phase 2–4.",
            ])
    }
}
