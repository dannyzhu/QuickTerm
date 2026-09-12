import Foundation

/// 人类可读输出（stdout 是 TTY，或显式 `--plain`）。
/// agent 拿到的永远是 JSON——这里只服务于人，所以可以随意排版。
enum Render {
    static func human(_ reply: ControlReply) -> String {
        guard let data = reply.data, let object = data.objectValue else {
            return summaryLine(reply)
        }
        if object["schema"]?.stringValue == "quickterm.state/1" { return state(object, reply: reply) }
        if object["schema"]?.stringValue == "quickterm.describe/1" { return describe(object) }
        // 抓屏要**先**认：它带着 pane 字段，落到下面的 paneDetail 分支里
        // 正文（也就是调用方唯一要的东西）会被整段丢掉
        if let text = object["text"]?.stringValue, object["lines"] != nil {
            return capture(object, text: text)
        }
        // 变更信封要**先**认：它自己也带 pane / panes / workspace / screen 字段，
        // 落到下面那些分支里就只剩一张表，"改了没有"反而看不见了
        if object["command"] != nil, object["changed"] != nil { return mutation(object, reply: reply) }
        // `spec dump` / `spec validate`（变更信封在上面已经先认过了）
        if let spec = object["spec"], object["scope"] != nil { return specDump(object, spec) }
        if object["valid"] != nil, object["scope"] != nil { return specValidate(object) }
        if let panes = object["panes"]?.arrayValue, object["screens"] == nil {
            return paneTable(panes)
        }
        if let screens = object["screens"]?.arrayValue { return screenTable(screens) }
        if let workspaces = object["workspaces"]?.arrayValue { return workspaceTable(workspaces) }
        if let pane = object["pane"]?.objectValue { return paneDetail(pane) }
        if let actions = object["actions"]?.arrayValue { return actionTable(actions) }
        if let settings = object["settings"]?.arrayValue { return settingsTable(settings) }
        if object["schema"]?.stringValue == "quickterm.events/1" { return events(object, reply: reply) }
        if object["action"] != nil { return actionResult(object, reply: reply) }
        if object["cli"] != nil { return version(object) }
        return summaryLine(reply)
    }

    /// `pane capture-text`：一行元信息 + 原样的正文（人要读的就是正文，别加缩进）
    static func capture(_ object: [String: JSONValue], text: String) -> String {
        let pane = object["pane"]?["handle"]?.stringValue ?? "?"
        var head = "\(pane)"
        if let cols = object["cols"]?.intValue, let rows = object["rows"]?.intValue {
            head += "  \(cols)×\(rows)"
        }
        head += "  \(object["lines"]?.intValue ?? 0) lines"
        if let scrollback = object["scrollback"]?.intValue, scrollback > 0 {
            head += " (incl. \(scrollback) from scrollback)"
        }
        if object["truncated"]?.boolValue == true { head += "  ⚠️ too long, truncated from the top" }
        return head + "\n" + String(repeating: "─", count: 12) + "\n" + text
    }

    /// `events poll` 的人类输出
    static func events(_ object: [String: JSONValue], reply: ControlReply) -> String {
        var out = eventLines(reply)
        if out.isEmpty {
            out.append(object["timedOut"]?.boolValue == true
                ? "(timed out, no new events)" : "(no new events)")
        }
        if object["missed"]?.boolValue == true {
            out.append("⚠️ Some events were pushed out of the buffer "
                + "(oldest=\(object["oldest"]?.intValue ?? 0)): read state again")
        }
        if object["truncated"]?.boolValue == true {
            out.append("⚠️ This batch was truncated by --limit and more is still queued: "
                + "poll again right away with the --since below")
        }
        out.append("Next: --since \(object["seq"]?.intValue ?? reply.seq ?? 0)")
        return out.joined(separator: "\n")
    }

    /// 一批事件 → 每条一行（`events follow` 的流式输出也用它）
    static func eventLines(_ reply: ControlReply) -> [String] {
        guard let events = reply.data?["events"]?.arrayValue else { return [] }
        return events.compactMap { entry in
            guard let e = entry.objectValue else { return nil }
            var line = "\(e["seq"]?.intValue ?? 0)  \(e["ts"]?.stringValue ?? "")  "
                + (e["type"]?.stringValue ?? "?")
            if let screen = e["screen"]?.intValue {
                line += "  \(screen)"
                if let workspace = e["workspace"]?.intValue { line += ":\(workspace)" }
            }
            if let pane = e["pane"]?.stringValue { line += ".\(pane)" }
            if let layout = e["layout"]?.stringValue { line += "  layout=\(layout)" }
            if let title = e["title"]?.stringValue { line += "  \"\(title)\"" }
            if let cwd = e["cwd"]?.stringValue { line += "  \(cwd)" }
            return line
        }
    }

    static func summaryLine(_ reply: ControlReply) -> String {
        var parts = ["ok"]
        if let seq = reply.seq { parts.append("seq=\(seq)") }
        if let resolved = reply.resolved {
            var where_ = ""
            if let s = resolved.screen { where_ += "screen \(s)" }
            if let w = resolved.workspace { where_ += " ws \(w)" }
            if let p = resolved.pane { where_ += " pane \(p)" }
            if !where_.isEmpty { parts.append("→\(where_)") }
        }
        return parts.joined(separator: "  ")
    }

    static func state(_ object: [String: JSONValue], reply: ControlReply) -> String {
        var out: [String] = []
        if let app = object["app"]?.objectValue {
            out.append("QuickTerm \(app["version"]?.stringValue ?? "?")"
                       + "  protocol v\(app["protocolVersion"]?.intValue ?? 0)"
                       + "  mode \(app["mode"]?.stringValue ?? "?")"
                       + "  workspaces \(app["workspaceCount"]?.intValue ?? 0)"
                       + (app["trusted"]?.boolValue == true
                          ? "  [origin token present]" : "  [no origin token: browser URLs redacted]"))
        }
        for screen in object["screens"]?.arrayValue ?? [] {
            guard let s = screen.objectValue else { continue }
            out.append("")
            out.append("Screen \(s["index"]?.intValue ?? 0)  \(s["title"]?.stringValue ?? "")"
                       + (s["key"]?.boolValue == true ? "  (key)" : "")
                       + "  active workspace \(s["activeWorkspace"]?.intValue ?? 0)"
                       + "  visible columns \(s["visibleColumns"]?.intValue ?? 0)")
            for workspace in s["workspaces"]?.arrayValue ?? [] {
                guard let w = workspace.objectValue else { continue }
                let handles = (w["panes"]?.arrayValue ?? []).compactMap { $0.stringValue }
                out.append("  \(w["active"]?.boolValue == true ? "*" : " ") "
                           + "\(w["index"]?.intValue ?? 0)"
                           + (w["title"]?.stringValue.map { "\"\($0)\"" } ?? "")
                           + "  \(w["layout"]?.stringValue ?? "")"
                           + "  \(handles.isEmpty ? "(empty)" : handles.joined(separator: " "))"
                           + (w["zoom"]?.stringValue.map { "  zoom=\($0)" } ?? ""))
            }
        }
        if let panes = object["panes"]?.arrayValue, !panes.isEmpty {
            out.append("")
            out.append(paneTable(panes))
        }
        return out.joined(separator: "\n")
    }

    static func paneTable(_ panes: [JSONValue]) -> String {
        let rows = panes.compactMap(\.objectValue)
        guard !rows.isEmpty else { return "(no panes)" }
        var keys = ["handle", "kind", "screen", "workspace", "title", "cwd"]
        // 投影过的输出只有用户点名的字段
        let present = Set(rows.flatMap { $0.keys })
        keys = keys.filter { present.contains($0) }
        // `id` 与 `tabList` 不进表格：一个是 36 位 uuid，一个是结构化的数组——
        // 塞进一列要么把表撑爆，要么渲染成一片空白。标签明细走 `get` 的逐项输出
        for extra in present.sorted() where !keys.contains(extra) && !["id", "tabList"].contains(extra) {
            keys.append(extra)
        }
        var widths = keys.map { $0.count }
        let cells: [[String]] = rows.map { row in
            keys.enumerated().map { index, key in
                let text = display(row[key])
                widths[index] = max(widths[index], text.count)
                return text
            }
        }
        var out = [zip(keys, widths).map { pad($0, $1) }.joined(separator: "  ")]
        for row in cells { out.append(zip(row, widths).map { pad($0, $1) }.joined(separator: "  ")) }
        return out.joined(separator: "\n")
    }

    static func screenTable(_ screens: [JSONValue]) -> String {
        screens.compactMap(\.objectValue).map { s in
            "\(s["index"]?.intValue ?? 0)  \(s["title"]?.stringValue ?? "")"
                + (s["key"]?.boolValue == true ? "  (key)" : "")
                + "  ws=\(s["activeWorkspace"]?.intValue ?? 0)"
                + "  \(s["display"]?["name"]?.stringValue ?? "")"
        }.joined(separator: "\n")
    }

    static func workspaceTable(_ workspaces: [JSONValue]) -> String {
        workspaces.compactMap(\.objectValue).map { w in
            let handles = (w["panes"]?.arrayValue ?? []).compactMap { $0.stringValue }
            return "\(w["active"]?.boolValue == true ? "*" : " ") \(w["index"]?.intValue ?? 0)"
                + (w["title"]?.stringValue.map { "\"\($0)\"" } ?? "")
                + "  \(w["layout"]?.stringValue ?? "")"
                + "  \(handles.isEmpty ? "(empty)" : handles.joined(separator: " "))"
        }.joined(separator: "\n")
    }

    static func paneDetail(_ pane: [String: JSONValue]) -> String {
        var out = pane.keys.sorted().filter { $0 != "tabList" }
            .map { "\(pad($0, 12))\(display(pane[$0]))" }
        // 标签是**可寻址的东西**（`--tab 2` / `--tab #<id>`），所以逐条列出来，
        // 而不是显示成一个没法用的 `{…}`
        for tab in pane["tabList"]?.arrayValue ?? [] {
            guard let t = tab.objectValue else { continue }
            out.append(pad("tab \(t["index"]?.intValue ?? 0)", 12)
                + (t["active"]?.boolValue == true ? "* " : "  ")
                + pad(String((t["id"]?.stringValue ?? "").prefix(8)), 10)
                + "  \(display(t["title"]))  \(display(t["url"]))")
        }
        return out.joined(separator: "\n")
    }

    /// `action --list` 的人读版。取 `helpEN`：`ActionDoc` 里中英两份并列，
    /// 而命令行这一侧全是英文（`--json` 照旧把两份都给出去）
    static func actionTable(_ actions: [JSONValue]) -> String {
        actions.compactMap(\.objectValue).map { a in
            let help = a["helpEN"]?.stringValue ?? a["helpZH"]?.stringValue ?? ""
            return "\(pad(a["name"]?.stringValue ?? "", 22))\(pad(a["cls"]?.stringValue ?? "", 12))\(help)"
        }.joined(separator: "\n")
    }

    static func actionResult(_ object: [String: JSONValue], reply: ControlReply) -> String {
        var out = ["\(object["action"]?.stringValue ?? ""): "
                   + (object["applied"]?.boolValue == true ? "applied" : "awaiting confirmation")
                   + "  " + summaryLine(reply)]
        if let panes = object["panes"]?.arrayValue, !panes.isEmpty {
            out.append("created:")
            out.append(paneTable(panes))
        }
        return out.joined(separator: "\n")
    }

    /// Phase 2 变更信封：一眼看出"改了没有 / 改了什么 / 能不能撤销"
    static func mutation(_ object: [String: JSONValue], reply: ControlReply) -> String {
        let dry = object["dryRun"]?.boolValue == true
        let changed = object["changed"]?.boolValue == true
        let applied = object["applied"]?.boolValue == true
        let head = "\(object["command"]?.stringValue ?? ""): "
            + (dry ? "dry run (nothing changed)" : applied ? "applied"
               : changed ? "not applied" : "no-op (already in the target state)")
            + "  " + summaryLine(reply)
        var out = [head]
        for change in object["changes"]?.arrayValue ?? [] {
            guard let c = change.objectValue else { continue }
            out.append("  \(c["path"]?.stringValue ?? ""): \(display(c["from"])) → \(display(c["to"]))")
        }
        if let report = object["spec"]?.objectValue {
            func list(_ key: String) -> String {
                let items = (report[key]?.arrayValue ?? []).compactMap(\.stringValue)
                return items.isEmpty ? "—" : items.joined(separator: " ")
            }
            out.append("  spec (\(report["mode"]?.stringValue ?? ""), \(report["scope"]?.stringValue ?? "")): "
                       + "created \(list("created"))  reused \(list("reused"))  closed \(list("closed"))")
            for skipped in (report["skipped"]?.arrayValue ?? []).compactMap(\.stringValue) {
                out.append("  skipped: \(skipped)")
            }
        }
        for warning in object["warnings"]?.arrayValue ?? [] {
            guard let w = warning.objectValue else { continue }
            // 告警要**显眼**：这条命令成功了，而用户以为的和实际发生的不是一回事
            out.append("  ⚠️ \(w["message"]?.stringValue ?? "") (\(w["code"]?.stringValue ?? ""))")
            if let hint = w["hint"]?.stringValue { out.append("     → \(hint)") }
        }
        if let note = object["note"]?.stringValue { out.append("  note: \(note)") }
        if let undo = object["undo"]?.stringValue { out.append("  undoable: Edit ▸ Undo \"\(undo)\"") }
        if let pane = object["pane"]?.objectValue {
            out.append(paneTable([.object(pane)]))
        }
        if let panes = object["panes"]?.arrayValue, !panes.isEmpty {
            out.append(paneTable(panes))
        }
        if let workspace = object["workspace"]?.objectValue {
            out.append(workspaceTable([.object(workspace)]))
        }
        if let screen = object["screen"]?.objectValue {
            out.append(screenTable([.object(screen)]))
        }
        return out.joined(separator: "\n")
    }

    /// `spec dump`：人看的时候在正文前加一行说明；JSON 模式下 main.swift 只打印 spec 本体
    static func specDump(_ object: [String: JSONValue], _ spec: JSONValue) -> String {
        var out = ["\(object["schema"]?.stringValue ?? "")"
                   + "  scope \(object["scope"]?.stringValue ?? "")"
                   + "  \(object["panes"]?.intValue ?? 0) panes"]
        if let data = try? ControlJSON.prettyEncoder.encode(spec),
           let text = String(data: data, encoding: .utf8) {
            out.append(text)
        }
        out.append("(Redirect it to a file and you can apply it back: quickterm spec dump > w.json)")
        return out.joined(separator: "\n")
    }

    static func specValidate(_ object: [String: JSONValue]) -> String {
        var out = ["spec is valid: \(object["schema"]?.stringValue ?? "")"
                   + "  scope \(object["scope"]?.stringValue ?? "")"
                   + "  \(object["panes"]?.intValue ?? 0) panes"]
        for note in (object["notes"]?.arrayValue ?? []).compactMap(\.stringValue) {
            out.append("  note: \(note)")
        }
        return out.joined(separator: "\n")
    }

    static func settingsTable(_ settings: [JSONValue]) -> String {
        settings.compactMap(\.objectValue).map { s in
            "\(pad(s["key"]?.stringValue ?? "", 18))\(pad(s["value"]?.stringValue ?? "", 16))"
                + "\(pad(s["scope"]?.stringValue ?? "", 8))"
                + ((s["choices"]?.arrayValue?.compactMap { $0.stringValue }).map {
                    $0.count > 6 ? "\($0.prefix(6).joined(separator: "|"))…" : $0.joined(separator: "|")
                } ?? "")
        }.joined(separator: "\n")
    }

    static func version(_ object: [String: JSONValue]) -> String {
        "quickterm \(object["cli"]?.stringValue ?? "?")"
            + " (protocol v\(object["protocolVersion"]?.intValue ?? 0))"
            + (object["running"]?.boolValue == true
               ? "; QuickTerm \(object["app"]?.stringValue ?? "?") is running, socket \(object["socket"]?.stringValue ?? "?")"
               : "; QuickTerm is not running")
    }

    static func describe(_ object: [String: JSONValue]) -> String {
        let commands = (object["commands"]?.arrayValue ?? []).compactMap(\.objectValue)
        var out = ["quickterm.describe/1  protocol v\(object["protocolVersion"]?.intValue ?? 0)"
                   + "  \(commands.count) commands"
                   + "  \((object["actions"]?.arrayValue ?? []).count) actions"]
        out.append("Use --json for the full schema: that is the one written for models.")
        return out.joined(separator: "\n")
    }

    private static func display(_ value: JSONValue?) -> String {
        switch value {
        case .none, .some(.null): "-"
        case .some(.string(let s)): s.isEmpty ? "-" : s
        case .some(.bool(let b)): b ? "yes" : "no"
        case .some(.int(let i)): String(i)
        case .some(.double(let d)): String(format: "%.3f", d)
        case .some(.array(let a)): a.compactMap { $0.stringValue }.joined(separator: ",")
        case .some(.object): "{…}"
        }
    }

    private static func pad(_ text: String, _ width: Int) -> String {
        text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
    }
}
