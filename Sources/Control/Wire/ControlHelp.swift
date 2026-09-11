import Foundation

/// `--help`——**从命令表生成**，目标：一个模型一次读完（≈100 行）。
/// 三条从同类工具里学来的规矩：
/// - 每条子命令的帮助**以 EXAMPLES 结尾**（模型抄例子远比读散文可靠）；
/// - 每条查询命令的帮助内嵌一段真实的（节选）输出样例——wezterm 的 `--help` 缺这个，
///   于是 agent 每个会话都要浪费一次调用去认输出形状；
/// - 退出码成表列出，错误一律带稳定 `code`，模型永远不必去 grep 文案。
enum Help {
    static func root(cliVersion: String) -> String {
        var out: [String] = []
        out.append("quickterm \(cliVersion) —— 从命令行 / AI agent 驱动 QuickTerm 的屏幕、工作区与 pane")
        out.append("")
        out.append("用法： quickterm <命令> [参数] [-t 目标] [--json|--plain]")
        out.append("")
        out.append("命令")
        for spec in ControlCommandTable.commands where spec.group == nil {
            out.append("  " + pad(usage(spec)) + spec.summary)
        }
        out.append("")
        out.append("名词-动词层（**绝对设值，绝不 toggle**；每条都认 --dry-run / --fail-if-noop）")
        for group in ControlCommandTable.groups {
            let verbs = ControlCommandTable.commands(inGroup: group).map(\.verb).joined(separator: " | ")
            out.append("  " + pad(group) + verbs)
        }
        out.append("  （逐条帮助：quickterm <名词> <动词> --help；一组的清单：quickterm <名词> --help）")
        out.append("")
        out.append("目标语法")
        for line in ControlTarget.grammarLines { out.append("  \(line)") }
        out.append("")
        out.append("全局选项")
        for flag in ControlCommandTable.globalFlags {
            let name = "--\(flag.name)"
            out.append("  \(name.padding(toLength: 22, withPad: " ", startingAt: 0))\(flag.help)")
        }
        out.append("  --start               QuickTerm 没在跑时先拉起它并等待（最长 10s）")
        out.append("")
        out.append("退出码")
        for code in ControlExit.allCases {
            out.append("  \(String(code.rawValue).padding(toLength: 22, withPad: " ", startingAt: 0))\(code.summary)")
        }
        out.append("")
        out.append("输出")
        out.append("  stdout 是 TTY → 人类可读；不是 TTY → JSON（agent 不必加任何开关）。")
        out.append("  错误一律是 stderr 上的 JSON，带稳定 code，绝不要去匹配文案。")
        out.append("")
        out.append("EXAMPLES")
        out.append("  quickterm state --json | jq '.data.panes[] | {handle, title, cwd}'")
        out.append("  quickterm list panes --fields handle,kind,title")
        out.append("  quickterm get -t @self                    # 我自己这个 pane 是哪一个")
        out.append("  quickterm action new-terminal             # 等价于按下新建终端的快捷键")
        out.append("  quickterm action goto-workspace-3 -t 2    # 2 号屏幕切到工作区 3")
        out.append("  quickterm action toggle-zoom -t t7        # 先把焦点交给 t7 再执行")
        out.append("  quickterm pane new --cwd ~/proj --cmd 'npm run dev' --at t1 --where right")
        out.append("  quickterm pane set -t t7 --zoom on         # 绝对设值：跑两次结果一样")
        out.append("  quickterm pane set -t t7 --title 'build'   # 给 pane 起个名字……")
        out.append("  quickterm get -t 'title:~build'            # ……之后就能按标题寻址它")
        out.append("  quickterm pane capture-text -t t7          # 读 t7 屏幕上的字（默认关闭，见 [control]）")
        out.append("  quickterm browser open -t b3 --url http://localhost:3000   # 新标签")
        out.append("  quickterm browser goto -t b3 --tab 1 --url https://a.b     # 指定标签换网址")
        out.append("  quickterm workspace set-layout dwindle -t :4   # 非活动工作区也能设")
        out.append("  quickterm pane move -t t7 --to 2:1 --follow")
        out.append("  quickterm spec dump > dev.json            # 把当前工作区存成一份 spec")
        out.append("  quickterm spec apply -f dev.json -t :5 --dry-run   # 先看 diff 再落")
        out.append("  quickterm action --list --json            # 全部 \(WMAction.allCases.count) 个动作及其安全分级")
        out.append("  quickterm describe --json                 # 整个控制面的机器可读 schema（会话开始读一次）")
        out.append("  quickterm install-cli --alias qt          # 装到 PATH（绝不弹管理员密码）")
        out.append("")
        out.append("agent 提示：先读一次 `quickterm describe --json`，之后不必再读 --help。")
        return out.joined(separator: "\n")
    }

    /// 一组名词的清单（`quickterm pane --help`）
    static func group(_ group: String) -> String {
        var out: [String] = ["quickterm \(group) <动词> [参数] —— \(group) 相关的命令", ""]
        for spec in ControlCommandTable.commands(inGroup: group) {
            out.append("  " + pad(usage(spec), 34) + spec.summary)
        }
        out.append("")
        out.append("EXAMPLES")
        for spec in ControlCommandTable.commands(inGroup: group) {
            if let example = spec.examples.first { out.append("  \(example)") }
        }
        out.append("")
        out.append("逐条帮助：quickterm \(group) <动词> --help")
        return out.joined(separator: "\n")
    }

    static func pad(_ text: String, _ width: Int = 22) -> String {
        text.padding(toLength: max(width, text.count + 1), withPad: " ", startingAt: 0)
    }

    /// 用法行（`pane new` + 位置参数）——命令表之外不再手写第二份
    static func usage(_ spec: ControlCommandSpec) -> String {
        let positional = spec.args.filter(\.positional)
            .map { $0.required ? "<\($0.name)>" : "[\($0.name)]" }
            .joined(separator: " ")
        return ([spec.cli] + [positional]).filter { !$0.isEmpty }.joined(separator: " ")
    }

    static func command(_ spec: ControlCommandSpec) -> String {
        var out: [String] = []
        out.append("quickterm \(usage(spec)) —— \(spec.summary)")
        out.append("")
        out.append("安全分级： \(spec.cls.rawValue)\(spec.cls.requiresConsent ? "（需要在 QuickTerm 里确认一次）" : "")"
                   + "   幂等： \(spec.idempotent ? "是" : "否")"
                   + "   接受 -t： \(spec.acceptsTarget ? "是" : "否")")
        if !spec.args.isEmpty {
            out.append("")
            out.append("参数")
            for arg in spec.args {
                let label = arg.positional ? "<\(arg.name)>" : "--\(arg.name)"
                var line = "  \(label.padding(toLength: 18, withPad: " ", startingAt: 0))\(arg.help)"
                if let values = arg.values { line += "（\(values.joined(separator: " | "))）" }
                if let def = arg.defaultValue { line += "（默认 \(def)）" }
                if arg.repeatable { line += "（可重复）" }
                out.append(line)
            }
        }
        if spec.name == "action" {
            out.append("")
            out.append("动作分级：\(ControlCommandTable.interactiveActions.count) 个会打开需要键盘交互的面板 / 弹出菜单，")
            out.append("经 socket 一律拒绝（退出码 5，code=interactive_action）：")
            out.append("  " + ControlCommandTable.interactiveActions.map(\.rawValue).sorted().joined(separator: " "))
            out.append("\(ControlCommandTable.destructiveActions.count) 个是破坏性的，会先要求用户确认一次：")
            out.append("  " + ControlCommandTable.destructiveActions.map(\.rawValue).sorted().joined(separator: " "))
        }
        if spec.group == "spec" {
            out.append("")
            out.append("\(SpecSchema.workspace) 字段表（每个都可省，括号里是默认值）")
            for field in ControlDescribeDocument.specSchema.fields {
                let name = field.path.padding(toLength: 20, withPad: " ", startingAt: 0)
                out.append("  \(name)\(field.help)"
                           + (field.defaultValue.map { "（默认 \($0)）" } ?? ""))
            }
            out.append("  最小可用的一份：\(ControlDescribeDocument.specSchema.minimal)")
            out.append("")
            out.append("dwindle 形态（同一套词汇）")
            for line in ControlCommandTable.specTreeSample.split(separator: "\n", omittingEmptySubsequences: false) {
                out.append("  \(line)")
            }
            out.append("")
            for note in ControlDescribeDocument.specSchema.notes { out.append("  \(note)") }
        }
        if spec.honorsMutationFlags {
            out.append("")
            out.append("变更类通用开关")
            out.append("  --dry-run         只报告会改什么（changes 就是 diff），什么都不改")
            out.append("  --fail-if-noop    已经是目标状态时退出码 7，而不是静默成功")
        }
        if let sample = spec.outputSample {
            out.append("")
            out.append("输出样例（节选）")
            for line in sample.split(separator: "\n", omittingEmptySubsequences: false) {
                out.append("  \(line)")
            }
        }
        out.append("")
        out.append("EXAMPLES")
        for example in spec.examples { out.append("  \(example)") }
        return out.joined(separator: "\n")
    }
}
