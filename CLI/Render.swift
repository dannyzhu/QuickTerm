import Foundation

/// Human-readable output (stdout is a TTY, or `--plain` was passed explicitly).
/// An agent always gets JSON, so this side only ever has to serve people and is free to lay things
/// out however reads best.
enum Render {
    static func human(_ reply: ControlReply) -> String {
        guard let data = reply.data, let object = data.objectValue else {
            return summaryLine(reply)
        }
        if object["schema"]?.stringValue == "quickterm.state/1" { return state(object, reply: reply) }
        if object["schema"]?.stringValue == "quickterm.describe/1" { return describe(object) }
        // Capture has to be matched **first**: it carries a `pane` field, so if it falls through
        // to the paneDetail branch below, the body — the one thing the caller wanted — is dropped
        // wholesale.
        if let text = object["text"]?.stringValue, object["lines"] != nil {
            return capture(object, text: text)
        }
        // The mutation envelope has to be matched **first** as well: it carries pane / panes /
        // workspace / screen fields of its own, and falling through to those branches below leaves
        // nothing but a table, with "did anything change" nowhere to be seen.
        if object["command"] != nil, object["changed"] != nil { return mutation(object, reply: reply) }
        // `spec dump` / `spec validate` (the mutation envelope was already matched above)
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

    /// `pane capture-text`: one line of metadata plus the body verbatim. The body is what the human
    /// came here to read, so do not indent it.
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

    /// Human-readable output for `events poll`.
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

    /// A batch of events -> one line each. The streaming output of `events follow` runs through
    /// this too.
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
        // A projected response only carries the fields the user named.
        let present = Set(rows.flatMap { $0.keys })
        keys = keys.filter { present.contains($0) }
        // `id` and `tabList` stay out of the table: one is a 36-character uuid, the other a
        // structured array — forcing either into a column either blows the table apart or renders
        // as a blank space. Tab detail goes through `get`'s per-item output instead.
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
        // Tabs are **addressable** (`--tab 2` / `--tab #<id>`), so list them one per line rather
        // than rendering an unusable `{…}`.
        for tab in pane["tabList"]?.arrayValue ?? [] {
            guard let t = tab.objectValue else { continue }
            out.append(pad("tab \(t["index"]?.intValue ?? 0)", 12)
                + (t["active"]?.boolValue == true ? "* " : "  ")
                + pad(String((t["id"]?.stringValue ?? "").prefix(8)), 10)
                + "  \(display(t["title"]))  \(display(t["url"]))")
        }
        return out.joined(separator: "\n")
    }

    /// The human-readable form of `action --list`. It takes `helpEN`: `ActionDoc` carries the
    /// Chinese and English halves side by side, while this side of the command line is English only
    /// (`--json` still hands out both).
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

    /// The Phase 2 mutation envelope: whether anything changed, what changed, and whether it can be
    /// undone, all visible at a glance.
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
            // Warnings have to **stand out**: the command succeeded, but what the user thinks
            // happened and what actually happened are two different things.
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

    /// `spec dump`: in human mode, put one explanatory line ahead of the body; in JSON mode
    /// main.swift prints the bare spec and nothing else.
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
