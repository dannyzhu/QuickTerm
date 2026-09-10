import AppKit

/// `input send-text` —— 整个控制面里**唯一**一条能让别人的 shell 执行任意命令的命令。
///
/// 说清楚它到底是什么：这不是"给终端发一条消息"，是**在那个 tty 上打字**。
/// 那里跑的可能是 root 的 shell，可能是一条活着的 ssh 会话，也可能是 vim 的普通模式；
/// 送进去的每一个字符都会被那个程序按它自己的规则解释。tmux / kitty 的远程控制被武器化，
/// 用的就是这个原语。所以它身上叠了四道闸门，每一道都独立生效：
///
/// 1. **默认关闭**：`[control] send-text = true` 之前，命令连执行的机会都没有
///    （`ControlCommandRunner.handle` 里对 `sensitive` 类的那一道，位置在限流与确认之前）；
/// 2. **`sensitive` 类**：命令表里写死，describe / MCP 的 hint 都从那里生成；
/// 3. **每次确认**：往调用方自己那个 pane 以外的任何地方注入，都要用户在 QuickTerm 里点一次
///    "允许"，而且**这次批准不进缓存**（见 `ControlConsent.Request.cacheable`）；
/// 4. **控制字符一律拒绝，换行只能靠 `--enter`**：没有这一条，一个"只是想填个输入框"的调用
///    会顺手把命令执行掉；有了这一条，"送文本"与"让它跑"是两个必须分别写出来的意图。
///
/// 唯一的免确认口子是"写自己那个 pane"，判定在 `ControlCommandRunner.writesIntoOwnPane`：
/// 那个 tty 本来就是调用进程自己的，它不经过 QuickTerm 也能往上写。
@MainActor
extension ControlCommandRunner {
    /// 一次最多送多少个字符。agent 幻觉出一整个文件粘进 shell 是真实会发生的事
    static let maxSendTextLength = 4096

    func runInput(_ ctx: ControlContext) throws -> (echo: ResolvedTarget?, data: any Encodable) {
        switch ctx.spec.verb {
        case "send-text": return try inputSendText(ctx)
        default:
            throw ControlErrorBody(.unknownCommand, "input 没有 \(ctx.spec.verb) 这个动词",
                                   candidates: ControlCommandTable.commands(inGroup: "input").map(\.verb))
        }
    }

    private func inputSendText(_ ctx: ControlContext) throws -> (ResolvedTarget?, any Encodable) {
        // **必须显式写 -t。** 别处的默认落点是"焦点 pane"，在这里那等于
        // "往此刻碰巧被聚焦的那个 shell 里打字"——agent 看不见焦点，这个默认值只会制造
        // 那种谁也查不出来的事故。要写焦点 pane 就明确地写 `-t @focused`
        guard ctx.target?.pane != nil else {
            throw ControlErrorBody(
                .badTarget, "input send-text 必须显式指定目标 pane（-t）",
                hint: "写自己这个 pane 是 -t @self；别的 pane 用 -t <句柄>，每次都会要求确认")
        }
        let raw = ctx.request.args["text"]?.stringValue ?? ""
        let text = try Self.validateSendText(raw)
        let enter = ctx.flag("enter")

        let hit = try requirePane(ctx, ctx.target)
        try verifyPinned(ctx, controller: hit.controller, workspace: hit.workspace, pane: hit.pane)
        guard let surface = hit.pane as? Ghostty.SurfaceView else {
            throw ControlErrorBody(
                .wrongPaneKind,
                "\(handleName(hit.pane)) 是 \(hit.pane.kind.rawValue) pane，没有可以打字的终端",
                hint: "只有 kind=terminal 的 pane 能接收 send-text（quickterm list panes）")
        }
        guard let model = surface.surfaceModel else {
            throw ControlErrorBody(.busy, "终端还没准备好（引擎 surface 尚未创建）",
                                   hint: "稍后重试；本次什么都没做", retryAfterMs: 200)
        }

        // diff 里**绝不写出正文**：活动日志与状态栏闪烁是给用户看的，
        // 而送进去的往往是命令行——把它原样记进一份长期留存的日志，本身就是一个新的外泄面
        let changes = [ControlChange(path(hit.controller, hit.workspace, hit.pane),
                                     from: "(键盘输入)",
                                     to: "\(text.count) 个字符" + (enter ? " + 回车" : "（无回车）"))]
        let mutation = ControlMutationRequest(
            command: ctx.spec.name, request: ctx.request, peer: ctx.peer, changes: changes,
            controllers: [hit.controller],
            // **不可撤销**：打进 shell 的字不存在"放回去"这回事，
            // 登记一个撤销项只会让用户以为 ⌘Z 能把已经跑起来的命令收回来
            undoName: nil,
            target: path(hit.controller, hit.workspace, hit.pane))
        var payload = try commit(mutation) {
            if !text.isEmpty { model.sendText(text) }
            // 回车是 CR（0x0D），不是 LF：终端的 Enter 一直都是这个
            if enter { model.sendText("\r") }
        }
        payload.pane = paneInfo(hit, encoder: ctx.encoder)
        return (hit.echo, payload)
    }

    /// 正文校验。**拒绝而不是过滤**：悄悄剥掉一个字符会让调用方以为送出去的是它写的那一串，
    /// 而实际到达 shell 的是另一串——这正是注入类事故的形状
    static func validateSendText(_ raw: String) throws -> String {
        guard raw.utf16.count <= maxSendTextLength else {
            throw ControlErrorBody(
                .badRequest, "文本太长了（\(raw.utf16.count) 个字符，上限 \(maxSendTextLength)）",
                hint: "分几次送，或者用 pane new --cmd 直接起一条命令")
        }
        for scalar in raw.unicodeScalars {
            let value = scalar.value
            let isC0 = value < 0x20
            let isDelete = value == 0x7F
            let isC1 = (0x80...0x9F).contains(value)
            guard isC0 || isDelete || isC1 else { continue }
            let name: String
            switch value {
            case 0x0A: name = "换行（\\n）"
            case 0x0D: name = "回车（\\r）"
            case 0x09: name = "制表符（\\t）"
            case 0x1B: name = "Esc"
            case 0x03: name = "Ctrl-C"
            default: name = String(format: "U+%04X", value)
            }
            throw ControlErrorBody(
                .badRequest, "文本里有控制字符：\(name)。send-text 只送可见文本",
                hint: value == 0x0A || value == 0x0D
                    ? "换行只能用 --enter 显式给出——那是让 shell 真的执行它的唯一方式"
                    : "控制字符（含 Esc / Ctrl-x / 制表符）一律拒绝：它们会被终端里的程序当成指令")
        }
        return raw
    }
}
