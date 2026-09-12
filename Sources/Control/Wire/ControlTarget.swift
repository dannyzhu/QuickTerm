import Foundation

/// Addressing syntax: `screen:workspace.pane`, every part optional, defaulting rightwards from the
/// current context (tmux's shape).
/// **A pure value type that touches no window** — which is why it can run in the window-less test
/// layer, the same way ScrollingStripTests does.
///
/// Disambiguation rules (written into `--help` and `describe`, with no "it depends" left over):
/// - a bare number / `@current` / `@primary` with no `:` or `.` -> a **screen** (pane handles
///   always carry a type prefix, `t7`/`b3`, so a bare number can never be a pane);
/// - `#uuid` without a `:` is a **pane**; to name a screen by uuid you must write `#uuid:`
///   (with the colon);
/// - a `:` inside a predicate (`title:~foo`) and a `.` inside one (`cwd:/a/b.c`) are not treated as
///   separators — we only split when what stands to the left of the separator **is itself** a valid
///   screen or workspace reference.
struct ControlTarget: Equatable {
    var screen: ScreenRef?
    var workspace: WorkspaceRef?
    var pane: PaneRef?

    var isEmpty: Bool { screen == nil && workspace == nil && pane == nil }

    enum ScreenRef: Equatable {
        case index(Int)          // 1-based, matching the window title
        case id(String)          // #uuid (MainWindowController.windowID)
        case current
        case primary
    }

    enum WorkspaceRef: Equatable {
        case index(Int)          // 1-based, matching Cmd+1..0 (the internal 0-based index never leaks)
        case active
        case next
        case prev
    }

    enum PaneRef: Equatable {
        case handle(String)      // t7 / b3 (stable for the lifetime of the process)
        case id(String)          // #uuid, or a prefix of ≥4
        case focused
        case selfPane            // @self: read from QUICKTERM_PANE
        case direction(Direction)
        case cycle(next: Bool)
        case title(String)       // title:~<regex>
        case cwd(String)         // cwd:<prefix>
        case kind(String)        // kind:terminal|browser
        case role(String)        // role:file-manager
    }

    enum Direction: String, Equatable {
        case left, right, up, down
    }

    enum ParseError: Error, Equatable, CustomStringConvertible {
        case empty
        case badScreen(String)
        case badWorkspace(String)
        case badPane(String)
        case badPredicate(String)

        var description: String {
            switch self {
            case .empty: "target is empty"
            case .badScreen(let s): "bad screen reference: \(s) (use a 1-based index, #uuid, @current, @primary)"
            case .badWorkspace(let s): "bad workspace reference: \(s) (use a 1-based index, @active, @next, @prev)"
            case .badPane(let s): "bad pane reference: \(s) (use a t7/b3 handle, #uuid, @focused/@self/@left…, title:~re, cwd:/p, kind:, role:)"
            case .badPredicate(let s): "bad predicate: \(s)"
            }
        }
    }

    static let paneHandlePattern = "^[tb][0-9]+$"

    // MARK: Parsing

    static func parse(_ raw: String) throws -> ControlTarget {
        let text = raw.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { throw ParseError.empty }
        try validateNoControlCharacters(text)

        var screen: ScreenRef?
        var screenOmitted = false
        var rest = Substring(text)

        if text.hasPrefix(":") {
            // `:3` / `:3.t7` — the screen is explicitly omitted, so what follows the colon always
            // starts at the workspace
            screenOmitted = true
            rest = rest.dropFirst()
        } else if let colon = text.firstIndex(of: ":") {
            let head = String(text[text.startIndex..<colon])
            if let parsed = parseScreen(head) {
                screen = parsed
                rest = text[text.index(after: colon)...]
            }
            // head is not a valid screen reference (`title:~foo`) -> treat the whole string as a
            // pane, do not split
        }
        let afterScreen = screen != nil || screenOmitted

        if screen != nil && rest.isEmpty {
            return ControlTarget(screen: screen, workspace: nil, pane: nil)
        }
        guard !rest.isEmpty else { throw ParseError.empty }

        let tail = String(rest)
        // Is the whole string just a screen reference? Only when no colon or dot was written and
        // the screen was not explicitly omitted
        if !afterScreen, !tail.contains(":"), !tail.contains("."), let onlyScreen = bareScreen(tail) {
            return ControlTarget(screen: onlyScreen, workspace: nil, pane: nil)
        }

        var workspace: WorkspaceRef?
        var panePart: String? = tail

        if let dot = tail.firstIndex(of: ".") {
            let head = String(tail[tail.startIndex..<dot])
            let after = String(tail[tail.index(after: dot)...])
            if head.isEmpty {
                // `2:.t7` / `.t7` — the workspace is left empty
                panePart = after.isEmpty ? nil : after
            } else if let parsed = parseWorkspace(head) {
                workspace = parsed
                panePart = after.isEmpty ? nil : after
            }
        }
        if workspace == nil, afterScreen, let candidate = panePart, let parsed = parseWorkspace(candidate) {
            // `2:3` / `:3` — everything to the right of the colon is the workspace
            workspace = parsed
            panePart = nil
        }

        var pane: PaneRef?
        if let panePart {
            pane = try parsePane(panePart)
        }
        return ControlTarget(screen: screen, workspace: workspace, pane: pane)
    }

    /// Control characters (< 0x20) are rejected outright: agents hallucinate arguments, and those
    /// must never reach a log, a title or a path.
    static func validateNoControlCharacters(_ text: String) throws {
        if text.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) {
            throw ParseError.badPane(text.debugDescription)
        }
    }

    private static func bareScreen(_ text: String) -> ScreenRef? {
        if let n = Int(text), n >= 1 { return .index(n) }
        switch text {
        case "@current": return .current
        case "@primary": return .primary
        default: return nil
        }
    }

    static func parseScreen(_ text: String) -> ScreenRef? {
        if let bare = bareScreen(text) { return bare }
        if text.hasPrefix("#") {
            let id = String(text.dropFirst())
            return id.isEmpty ? nil : .id(id.lowercased())
        }
        return nil
    }

    static func parseWorkspace(_ text: String) -> WorkspaceRef? {
        if let n = Int(text), n >= 1 { return .index(n) }
        switch text {
        case "@active": return .active
        case "@next": return .next
        case "@prev": return .prev
        default: return nil
        }
    }

    static func parsePane(_ text: String) throws -> PaneRef {
        if text.hasPrefix("@") {
            switch text {
            case "@focused": return .focused
            case "@self": return .selfPane
            case "@left": return .direction(.left)
            case "@right": return .direction(.right)
            case "@up": return .direction(.up)
            case "@down": return .direction(.down)
            case "@next": return .cycle(next: true)
            case "@prev": return .cycle(next: false)
            default: throw ParseError.badPane(text)
            }
        }
        if text.hasPrefix("#") {
            let id = String(text.dropFirst()).lowercased()
            let hex = id.replacingOccurrences(of: "-", with: "")
            guard hex.count >= 4, hex.allSatisfy({ $0.isHexDigit }) else { throw ParseError.badPane(text) }
            return .id(id)
        }
        if let colon = text.firstIndex(of: ":") {
            let field = String(text[text.startIndex..<colon])
            var value = String(text[text.index(after: colon)...])
            switch field {
            case "title":
                guard value.hasPrefix("~") else { throw ParseError.badPredicate(text) }
                value = String(value.dropFirst())
                guard !value.isEmpty else { throw ParseError.badPredicate(text) }
                return .title(value)
            case "cwd":
                guard !value.isEmpty else { throw ParseError.badPredicate(text) }
                return .cwd(value)
            case "kind":
                guard ["terminal", "browser"].contains(value) else { throw ParseError.badPredicate(text) }
                return .kind(value)
            case "role":
                guard !value.isEmpty else { throw ParseError.badPredicate(text) }
                return .role(value)
            default:
                throw ParseError.badPredicate(text)
            }
        }
        if text.range(of: paneHandlePattern, options: .regularExpression) != nil {
            return .handle(text.lowercased())
        }
        throw ParseError.badPane(text)
    }

    // MARK: Writing it back (the round-trip baseline for the tests, and the form error messages use
    // to echo the target)

    var text: String {
        var out = ""
        if let screen {
            switch screen {
            case .index(let n): out += String(n)
            case .id(let id): out += "#\(id)"
            case .current: out += "@current"
            case .primary: out += "@primary"
            }
        }
        if let workspace {
            out += ":"
            switch workspace {
            case .index(let n): out += String(n)
            case .active: out += "@active"
            case .next: out += "@next"
            case .prev: out += "@prev"
            }
        } else if screen != nil && pane != nil {
            out += ":"
        }
        if let pane {
            if screen != nil || workspace != nil { out += "." }
            switch pane {
            case .handle(let h): out += h
            case .id(let id): out += "#\(id)"
            case .focused: out += "@focused"
            case .selfPane: out += "@self"
            case .direction(let d): out += "@\(d.rawValue)"
            case .cycle(let next): out += next ? "@next" : "@prev"
            case .title(let re): out += "title:~\(re)"
            case .cwd(let p): out += "cwd:\(p)"
            case .kind(let k): out += "kind:\(k)"
            case .role(let r): out += "role:\(r)"
            }
        }
        if case .id = screen, workspace == nil, pane == nil {
            out += ":"   // `#uuid:` — a bare `#uuid` is a pane; only with the colon is it a screen
        }
        return out
    }

    /// The single source for the six lines of grammar shown in `--help` and `describe`.
    static let grammarLines: [String] = [
        "-t screen:workspace.pane   every part optional, defaults to the current context",
        "screen     1-based index (= the window title) · #uuid: · @current · @primary",
        "workspace  1-based index (= Cmd+1..0) · @active · @next · @prev",
        "pane       t7 / b3 handle · #uuid (prefix of ≥4) · @focused (default) · @self",
        "           @left @right @up @down · @next @prev",
        "predicate  title:~<regex> · cwd:<prefix> · kind:terminal|browser · role:file-manager",
        "ambiguity  multiple matches: an error that lists them all, never the first (exit code 3)",
    ]
}
