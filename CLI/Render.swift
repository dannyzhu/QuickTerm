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
        if let panes = object["panes"]?.arrayValue, object["screens"] == nil {
            return paneTable(panes)
        }
        if let screens = object["screens"]?.arrayValue { return screenTable(screens) }
        if let workspaces = object["workspaces"]?.arrayValue { return workspaceTable(workspaces) }
        if let pane = object["pane"]?.objectValue { return paneDetail(pane) }
        if let actions = object["actions"]?.arrayValue { return actionTable(actions) }
        if object["action"] != nil { return actionResult(object, reply: reply) }
        if object["cli"] != nil { return version(object) }
        return summaryLine(reply)
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
