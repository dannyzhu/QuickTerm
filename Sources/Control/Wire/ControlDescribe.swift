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
    /// `app get/set` 认的设置项（枚举即清单）
    var appSettings: [AppSettingDoc]
    /// `quickterm.workspace/1` 的字段表（Phase 3：agent 靠它一次读懂 spec 怎么写）
    var specSchema: SpecSchemaDoc
    /// 事件类型（Phase 4）。`events poll --since <seq>` 是 agent 该用的那一种
    var events: [EventDoc]
    /// MCP 工具表（Phase 5）——**从命令表生成**，每个工具背后是哪几条命令一并写明
    var mcpTools: [MCPTool.Doc]
    /// 名词分组（`pane` / `workspace` / `screen` / `app`）→ 动词
    var groups: [GroupDoc]
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

    struct AppSettingDoc: Codable, Equatable {
        var key: String
        var scope: String
        var help: String
    }

    /// 公开 schema 的字段表。**刻意不是内部存档 v5 的形状**：两者由
    /// `Sources/Control/Spec/SpecCodec.swift` 的投影对连起来，各自独立演进
    struct SpecSchemaDoc: Codable, Equatable {
        var workspace: String
        var screen: String
        var session: String
        var fields: [FieldDoc]
        /// 两种布局形态各一份完整样例（都是合法 JSON，`ControlSpecTests` 会重新解析它们）
        var examples: [String]
        var minimal: String
        var notes: [String]

        struct FieldDoc: Codable, Equatable {
            var path: String
            var type: String
            var defaultValue: String?
            var help: String
        }
    }

    struct EventDoc: Codable, Equatable {
        var type: String
        var summary: String
    }

    struct GroupDoc: Codable, Equatable {
        var name: String
        var verbs: [String]
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

    /// 敏感命令（`input send-text`）的现行策略。同样**跟着实际 mode 与开关走**
    static func sensitivePolicy(mode: String?) -> String {
        switch mode {
        case "off": "控制面已关闭（[control] mode = \"off\"）：一律不执行"
        case "readonly": "只读模式（[control] mode = \"readonly\"）：一律拒绝"
        default: "**一条命令一个开关，默认全关**（退出码 5，code=denied）："
            + "input send-text 要 `[control] send-text = true`，pane capture-text 要 `[control] capture-text = true`；"
            + "打开一个绝不会顺带打开另一个，确认的缓存也是一条命令一份。"
            + "\n· send-text：打开之后只有写调用方自己那个 pane 免确认——那个 tty 本来就是它自己的；"
            + "判定看的是每 pane 一枚、可验证的 QUICKTERM_PANE_TOKEN 与 -t 真正解析到的那个 pane 对不对得上，"
            + "自报的 QUICKTERM_PANE 不参与判定（它验不了）。"
            + "写**任何**别的 pane 每次都要确认，确认框里会原样列出要打进去的正文与是否跟回车，"
            + "且这次批准不进缓存。控制字符一律拒绝；换行只能靠显式的 --enter。"
            + "\n· capture-text：没有「读自己那个 pane」的豁免（一个进程本来就读不到自己 tty 的回滚缓冲）；"
            + "调用方还必须带着本次启动的 QUICKTERM_TOKEN（与浏览器网址打码同一枚），"
            + "然后每个调用进程确认一次。它什么都不改，因此**不认 --dry-run / --fail-if-noop**——"
            + "那个开关在别处同时意味着免确认，在这里就成了绕过闸门拿到全部内容的后门。"
            + "抓到的正文只在那一条响应里出现一次：不进活动日志、不进事件流、不进统一日志。"
        }
    }

    /// `quickterm.workspace/1` 的字段表（`spec --help` 与 describe 同一出处）
    static var specSchema: SpecSchemaDoc {
        typealias Field = SpecSchemaDoc.FieldDoc
        return SpecSchemaDoc(
            workspace: SpecSchema.workspace,
            screen: SpecSchema.screen,
            session: SpecSchema.session,
            fields: [
                Field(path: "layout", type: "scrolling | dwindle", defaultValue: "scrolling",
                      help: "写了 tree 而没写 layout 时按 dwindle 认"),
                Field(path: "title", type: "string ≤200", defaultValue: "不动",
                      help: "工作区的名字（名字跟着格子走）；写空串 = 清掉，不写这个键 = 一个字不动"),
                Field(path: "visibleColumns", type: "int \(SpecLimits.visibleColumns.lowerBound)–\(SpecLimits.visibleColumns.upperBound)",
                      defaultValue: "不动", help: "scrolling 每屏可见列数（**作用于整块屏幕**）"),
                Field(path: "columns[]", type: "array", defaultValue: "[]",
                      help: "scrolling：列 × 列内自上而下的 pane 栈"),
                Field(path: "columns[].width", type: "double \(SpecLimits.widthRange.lowerBound)–\(SpecLimits.widthRange.upperBound)",
                      defaultValue: "按每屏可见列数折算", help: "列宽因子；越界报错，绝不静默夹紧"),
                Field(path: "columns[].panes[]", type: "pane[]", defaultValue: "[{}]", help: "列里的 pane"),
                Field(path: "tree", type: "{pane} | {split,ratio,a,b}", defaultValue: "—",
                      help: "dwindle：分裂树。split=horizontal（a 左 b 右）/ vertical（a 上 b 下）"),
                Field(path: "tree.ratio", type: "double \(SpecLimits.ratioRange.lowerBound)–\(SpecLimits.ratioRange.upperBound)",
                      defaultValue: "0.5", help: "分裂比例"),
                Field(path: "pane.kind", type: "terminal | browser | file-manager", defaultValue: "terminal",
                      help: "pane 种类"),
                Field(path: "pane.cwd", type: "string（支持 ~）", defaultValue: "继承锚点 pane 的目录",
                      help: "起始目录；apply 前会检查它真的存在"),
                Field(path: "pane.cmd", type: "string", defaultValue: "—",
                      help: "要跑的命令。**只进不出**：dump 回吐不了它"),
                Field(path: "pane.hold", type: "bool", defaultValue: "false", help: "命令退出后不关 pane"),
                Field(path: "pane.env", type: "{KEY: VALUE}", defaultValue: "{}", help: "额外环境变量（只进不出）"),
                Field(path: "pane.url", type: "string", defaultValue: "浏览器主页",
                      help: "kind=browser：活动标签的网址"),
                Field(path: "pane.tabs[]", type: "string[]", defaultValue: "—",
                      help: "kind=browser：全部标签，顺序即标签顺序"),
                Field(path: "zoom", type: "{column,row} | {path} | {floating}", defaultValue: "null",
                      help: "哪一格占满内容区"),
                Field(path: "focus", type: "{column,row} | {path} | {floating}", defaultValue: "第一个 pane",
                      help: "哪一格拿焦点"),
                Field(path: "floating[]", type: "[{rect,pane}]", defaultValue: "[]",
                      help: "浮动层；rect = 内容区比例 [x,y,w,h]，不写就居中默认尺寸"),
            ],
            examples: [ControlCommandTable.specSample, ControlCommandTable.specTreeSample],
            minimal: "{\"columns\":[{\"panes\":[{}]},{\"panes\":[{},{}]}]}",
            notes: [
                "每个字段都可省，省掉时按上表的默认值——两行就能写出一份合法的 spec。",
                "认不得的键一律报错（写错 colums 不会被静默忽略）；数值越界报错并给出范围，绝不静默夹紧。",
                "spec apply 的三种模式：--into-empty（默认，非空目标退 4，毁不掉任何东西）、"
                    + "--replace（破坏性，先确认）、--reuse（能对上的 pane 留着）。",
                "cmd / env / hold 只进不出：再 apply 一次不会重跑已经在跑的命令（--replace 整份一模一样时是空操作）。",
                "quickterm.screen/1 = {display, frame, fullscreen, joinAllSpaces, visibleColumns, "
                    + "activeWorkspace, workspaces[]}；quickterm.session/1 = {screens[], keyScreen}；"
                    + "两者原样复用工作区那一份词汇。apply 不搬窗口（display / frame 只在 dump 里回显）。",
            ])
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
            phase: 5,
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
                         policy: "静默执行，但可见：状态栏闪一下并写进应用内的控制面活动日志；"
                             + "布局类变更登记到 UndoManager（Edit ▸ 撤销 / ⌘Z 可回滚）"),
                ClassDoc(name: ControlCommandClass.destructive.rawValue,
                         policy: destructivePolicy(mode: mode)),
                ClassDoc(name: ControlCommandClass.interactive.rawValue,
                         policy: "一律拒绝：会打开需要键盘交互的面板 / 弹出菜单"),
                ClassDoc(name: ControlCommandClass.sensitive.rawValue,
                         policy: sensitivePolicy(mode: mode)),
            ],
            exitCodes: ControlExit.allCases.map {
                ExitCodeDoc(code: $0.rawValue, name: String(describing: $0), summary: $0.summary)
            },
            errorCodes: ControlErrorCode.allCases.map {
                ErrorCodeDoc(code: $0.rawValue, exit: $0.exit.rawValue, summary: $0.summary)
            },
            actions: ControlCommandTable.actionDocs,
            appSettings: ControlAppSetting.allCases.map {
                AppSettingDoc(key: $0.rawValue, scope: $0.isPerScreen ? "screen" : "app", help: $0.help)
            },
            specSchema: specSchema,
            events: ControlEventType.allCases.map { EventDoc(type: $0.rawValue, summary: $0.summary) },
            mcpTools: MCPToolMap.tools.map(\.doc),
            groups: ControlCommandTable.groups.map {
                GroupDoc(name: $0, verbs: ControlCommandTable.commands(inGroup: $0).map(\.verb))
            },
            envVars: [
                EnvDoc(name: ControlProtocol.Env.socket, summary: "控制 socket 路径（每个新建 pane 都注入）"),
                EnvDoc(name: ControlProtocol.Env.pane, summary: "本 pane 的 UUID —— `-t @self` 就靠它"),
                EnvDoc(name: ControlProtocol.Env.screen, summary: "创建时所在屏幕序号（提示值；pane 移动后不更新）"),
                EnvDoc(name: ControlProtocol.Env.workspace, summary: "创建时所在工作区序号（提示值；pane 移动后不更新）"),
                EnvDoc(name: ControlProtocol.Env.token,
                       summary: "来源证明，**不是权限边界**：能证明命令来自 QuickTerm 开的 pane，但绝不跳过任何确认"),
                EnvDoc(name: ControlProtocol.Env.paneToken,
                       summary: "每 pane 一枚、可验证的来源标记（HMAC）。只用在一处：input send-text 写"
                           + "调用方自己那个 pane 时免确认。同样不是权限边界"),
            ],
            notes: [
                "stdout 不是 TTY 时默认输出 JSON；错误一律是 stderr 上的 JSON，带稳定 code。",
                "目标匹配到多个一律报错并在 candidates 里列出全部，绝不取第一个。",
                "`action` 是快捷键平价的直通车（**唯一**保留 toggle 语义的地方）；"
                    + "优先用名词-动词层：它全是绝对设值，同一条命令跑两次结果一致。",
                "名词-动词层的变更命令都认 --dry-run（只回 changes，什么都不改）与 --fail-if-noop；action 直通车两个都不认"
                    + "（已经是目标状态时退出码 7，而不是静默成功）。",
                "`workspace set-layout` 能作用在**非活动**工作区上——这是 `action toggle-layout` 做不到的。",
                "`workspace count N` 改写 config.toml 并由配置监听落地：命令返回后约 0.2s 才读得到新的个数。",
                "变更命令按来源限流（超出 → 退出码 6 并带 retryAfterMs）；"
                    + "QuickTerm 里有模态对话框挂着时，**任何**变更命令都会被拒（退出码 6）。",
                "正在淡出（关闭动效中）的 pane 不可寻址；每条变更命令执行前都会先 flush。",
                "pane 的 `focused` 是**每块屏幕各自**的焦点；全局唯一的那个在 `key: true` 的屏幕上——"
                    + "恒有且只有一块屏幕是 `key`：应用在前台时是真正的 key 窗口，否则是最近一次成为 key 的那块。",
                "短句柄（t7/b3）只在 QuickTerm 这一次运行期间稳定；跨重启唯一稳定的身份是 `id`（UUID）。",
                "一次要摆好一整个工作区就用 `spec apply`，别发 N 条 pane new："
                    + "N 条命令 = N 次重排、N 次动画、N 个失败点；spec 是一次算完、一次落地。",
                "`spec apply --replace` 之前先跑一次 `--dry-run`：它返回同样的信封，applied=false，changes 就是那份 diff。",
                "`spec dump` 打印的就是那份 spec 本身（不套响应信封），可以直接重定向到文件再 apply 回去。",
                "每一条成功的变更都会推进 `seq`（响应里回的那个）；`events poll --since <seq>` 拿回这中间发生的事件。"
                    + "两处的 seq 是同一条尺子：拿变更响应回的 seq 去 poll，不会漏掉自己那条命令产生的事件。",
                "事件**绝不携带 pane 的输出内容**——只有结构、标题与 cwd，"
                    + "而浏览器 pane 的标题 / cwd 对没有 token 的调用方与 `state` 一样打码。",
                "`events poll` 是 agent 该用的形式（一次请求-应答）；`events follow` 是给人和 shell 脚本的 NDJSON 流。"
                    + "缓冲是环形的（\(ControlEventLimits.ringCapacity) 条）：`missed: true` 意味着中间漏了，重新读一次 state。",
                "`input send-text` 等于在那个 tty 上打字（可能是 root、可能是一条 ssh 会话）："
                    + "默认关闭、sensitive 类、每次确认、控制字符拒绝、换行只能靠 --enter。",
                "`quickterm mcp` 是同一张命令表生成的 MCP stdio 服务（\(MCPToolMap.tools.count) 个粗粒度工具，"
                    + "带 readOnlyHint / destructiveHint / idempotentHint 与 outputSchema）："
                    + "**交互式的一次性控制用 MCP**（宿主那一层能自动放行读、对破坏性调用弹确认），"
                    + "**批量组合用 CLI**（不调用就不占上下文，而工具表是每次会话都要付的上下文税）。",
                "MCP 这一层没有任何自己的特权：每次 tools/call 走的都是同一条 socket、同一套确认与限流。"
                    + "`events follow`（流）与 `install-cli`（造软链）刻意不上 MCP。",
                "全部动作与命令的说明都有中英两份（`helpZH` / `helpEN`）：describe 的输出会被原样粘进中英混排的提示里。",
            ])
    }
}
