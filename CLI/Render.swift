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

    /// `events poll` 的人类输出
    static func events(_ object: [String: JSONValue], reply: ControlReply) -> String {
        var out = eventLines(reply)
        if out.isEmpty {
            out.append(object["timedOut"]?.boolValue == true
                ? "（等到点了，没有新事件）" : "（没有新事件）")
        }
        if object["missed"]?.boolValue == true {
            out.append("⚠️ 有事件已经被挤出缓冲（oldest=\(object["oldest"]?.intValue ?? 0)）：重新读一次 state")
        }
        if object["truncated"]?.boolValue == true {
            out.append("⚠️ 这一批被 --limit 截断了，缓冲里还压着更多：拿下面这个 --since 立刻再轮一次")
        }
        out.append("下一次： --since \(object["seq"]?.intValue ?? reply.seq ?? 0)")
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
            if let title = e["title"]?.stringValue { line += "  「\(title)」" }
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
                       + "  协议 v\(app["protocolVersion"]?.intValue ?? 0)"
                       + "  模式 \(app["mode"]?.stringValue ?? "?")"
                       + "  工作区 \(app["workspaceCount"]?.intValue ?? 0)"
                       + (app["trusted"]?.boolValue == true ? "  [来源已标记]" : "  [无来源标记：浏览器网址已打码]"))
        }
        for screen in object["screens"]?.arrayValue ?? [] {
            guard let s = screen.objectValue else { continue }
            out.append("")
            out.append("屏幕 \(s["index"]?.intValue ?? 0)  \(s["title"]?.stringValue ?? "")"
                       + (s["key"]?.boolValue == true ? "  (key)" : "")
                       + "  活动工作区 \(s["activeWorkspace"]?.intValue ?? 0)"
                       + "  可见列 \(s["visibleColumns"]?.intValue ?? 0)")
            for workspace in s["workspaces"]?.arrayValue ?? [] {
                guard let w = workspace.objectValue else { continue }
                let handles = (w["panes"]?.arrayValue ?? []).compactMap { $0.stringValue }
                out.append("  \(w["active"]?.boolValue == true ? "*" : " ") "
                           + "\(w["index"]?.intValue ?? 0)  \(w["layout"]?.stringValue ?? "")"
                           + "  \(handles.isEmpty ? "(空)" : handles.joined(separator: " "))"
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
        guard !rows.isEmpty else { return "（没有 pane）" }
        var keys = ["handle", "kind", "screen", "workspace", "title", "cwd"]
        // 投影过的输出只有用户点名的字段
        let present = Set(rows.flatMap { $0.keys })
        keys = keys.filter { present.contains($0) }
        for extra in present.sorted() where !keys.contains(extra) && extra != "id" { keys.append(extra) }
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
                + "  \(w["layout"]?.stringValue ?? "")"
                + "  \(handles.isEmpty ? "(空)" : handles.joined(separator: " "))"
        }.joined(separator: "\n")
    }

    static func paneDetail(_ pane: [String: JSONValue]) -> String {
        pane.keys.sorted().map { "\(pad($0, 12))\(display(pane[$0]))" }.joined(separator: "\n")
    }

    static func actionTable(_ actions: [JSONValue]) -> String {
        actions.compactMap(\.objectValue).map { a in
            "\(pad(a["name"]?.stringValue ?? "", 22))\(pad(a["cls"]?.stringValue ?? "", 12))\(a["helpZH"]?.stringValue ?? "")"
        }.joined(separator: "\n")
    }

    static func actionResult(_ object: [String: JSONValue], reply: ControlReply) -> String {
        var out = ["\(object["action"]?.stringValue ?? "")："
                   + (object["applied"]?.boolValue == true ? "已执行" : "等待用户确认")
                   + "  " + summaryLine(reply)]
        if let panes = object["panes"]?.arrayValue, !panes.isEmpty {
            out.append("新建：")
            out.append(paneTable(panes))
        }
        return out.joined(separator: "\n")
    }

    /// Phase 2 变更信封：一眼看出"改了没有 / 改了什么 / 能不能撤销"
    static func mutation(_ object: [String: JSONValue], reply: ControlReply) -> String {
        let dry = object["dryRun"]?.boolValue == true
        let changed = object["changed"]?.boolValue == true
        let applied = object["applied"]?.boolValue == true
        let head = "\(object["command"]?.stringValue ?? "")："
            + (dry ? "预演（什么都没改）" : applied ? "已执行" : changed ? "未执行" : "无需改动（已经是目标状态）")
            + "  " + summaryLine(reply)
        var out = [head]
        for change in object["changes"]?.arrayValue ?? [] {
            guard let c = change.objectValue else { continue }
            out.append("  \(c["path"]?.stringValue ?? "")：\(display(c["from"])) → \(display(c["to"]))")
        }
        if let report = object["spec"]?.objectValue {
            func list(_ key: String) -> String {
                let items = (report[key]?.arrayValue ?? []).compactMap(\.stringValue)
                return items.isEmpty ? "—" : items.joined(separator: " ")
            }
            out.append("  spec（\(report["mode"]?.stringValue ?? "")，\(report["scope"]?.stringValue ?? "")）："
                       + "新建 \(list("created"))  留用 \(list("reused"))  关掉 \(list("closed"))")
            for skipped in (report["skipped"]?.arrayValue ?? []).compactMap(\.stringValue) {
                out.append("  跳过：\(skipped)")
            }
        }
        if let note = object["note"]?.stringValue { out.append("  注：\(note)") }
        if let undo = object["undo"]?.stringValue { out.append("  可撤销：Edit ▸ 撤销「\(undo)」") }
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
                   + "  作用域 \(object["scope"]?.stringValue ?? "")"
                   + "  \(object["panes"]?.intValue ?? 0) 个 pane"]
        if let data = try? ControlJSON.prettyEncoder.encode(spec),
           let text = String(data: data, encoding: .utf8) {
            out.append(text)
        }
        out.append("（重定向到文件即可再 apply 回去：quickterm spec dump > w.json）")
        return out.joined(separator: "\n")
    }

    static func specValidate(_ object: [String: JSONValue]) -> String {
        var out = ["spec 合法：\(object["schema"]?.stringValue ?? "")"
                   + "  作用域 \(object["scope"]?.stringValue ?? "")"
                   + "  \(object["panes"]?.intValue ?? 0) 个 pane"]
        for note in (object["notes"]?.arrayValue ?? []).compactMap(\.stringValue) {
            out.append("  注：\(note)")
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
            + "（协议 v\(object["protocolVersion"]?.intValue ?? 0)）"
            + (object["running"]?.boolValue == true
               ? "；QuickTerm \(object["app"]?.stringValue ?? "?") 正在运行，socket \(object["socket"]?.stringValue ?? "?")"
               : "；QuickTerm 没在运行")
    }

    static func describe(_ object: [String: JSONValue]) -> String {
        let commands = (object["commands"]?.arrayValue ?? []).compactMap(\.objectValue)
        var out = ["quickterm.describe/1  协议 v\(object["protocolVersion"]?.intValue ?? 0)"
                   + "  命令 \(commands.count) 条"
                   + "  动作 \((object["actions"]?.arrayValue ?? []).count) 个"]
        out.append("完整 schema 请用 --json（这是给模型看的那一份）。")
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
