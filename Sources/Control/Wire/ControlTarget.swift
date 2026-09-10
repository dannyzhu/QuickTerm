import Foundation

/// 寻址语法：`screen:workspace.pane`，每段可省，向右默认取上下文（tmux 的形状）。
/// **纯值类型，不碰任何窗口**——所以能和 ScrollingStripTests 一样在无窗口的用例层跑。
///
/// 消歧规则（写进 `--help` 与 `describe`，不留"看情况"）：
/// - 纯数字 / `@current` / `@primary` 且不带 `:` `.` → **屏幕**（pane 句柄一律带类型前缀 `t7`/`b3`，
///   所以裸数字永远不会是 pane）；
/// - `#uuid` 不带 `:` 时是 **pane**；要按 uuid 指屏幕必须写 `#uuid:`（带冒号）；
/// - 谓词里的 `:`（`title:~foo`）与 `.`（`cwd:/a/b.c`）不会被当成分隔符——
///   只有当分隔符左边**本身就是**合法的屏幕 / 工作区引用时才切分。
struct ControlTarget: Equatable {
    var screen: ScreenRef?
    var workspace: WorkspaceRef?
    var pane: PaneRef?

    var isEmpty: Bool { screen == nil && workspace == nil && pane == nil }

    enum ScreenRef: Equatable {
        case index(Int)          // 1 起，与窗口标题一致
        case id(String)          // #uuid（MainWindowController.windowID）
        case current
        case primary
    }

    enum WorkspaceRef: Equatable {
        case index(Int)          // 1 起，与 Cmd+1..0 一致（内部 0 起绝不外泄）
        case active
        case next
        case prev
    }

    enum PaneRef: Equatable {
        case handle(String)      // t7 / b3（进程内稳定）
        case id(String)          // #uuid 或 ≥4 位前缀
        case focused
        case selfPane            // @self：读 QUICKTERM_PANE
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
            case .empty: "目标为空"
            case .badScreen(let s): "屏幕引用非法：\(s)（用 1 起序号、#uuid、@current、@primary）"
            case .badWorkspace(let s): "工作区引用非法：\(s)（用 1 起序号、@active、@next、@prev）"
            case .badPane(let s): "pane 引用非法：\(s)（用 t7/b3 句柄、#uuid、@focused/@self/@left…、title:~re、cwd:/p、kind:、role:）"
            case .badPredicate(let s): "谓词非法：\(s)"
            }
        }
    }

    static let paneHandlePattern = "^[tb][0-9]+$"

    // MARK: 解析

    static func parse(_ raw: String) throws -> ControlTarget {
        let text = raw.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { throw ParseError.empty }
        try validateNoControlCharacters(text)

        var screen: ScreenRef?
        var screenOmitted = false
        var rest = Substring(text)

        if text.hasPrefix(":") {
            // `:3` / `:3.t7` —— 显式省略屏幕，冒号右边一定从工作区开始
            screenOmitted = true
            rest = rest.dropFirst()
        } else if let colon = text.firstIndex(of: ":") {
            let head = String(text[text.startIndex..<colon])
            if let parsed = parseScreen(head) {
                screen = parsed
                rest = text[text.index(after: colon)...]
            }
            // head 不是合法屏幕引用（`title:~foo`）→ 整串按 pane 处理，不切分
        }
        let afterScreen = screen != nil || screenOmitted

        if screen != nil && rest.isEmpty {
            return ControlTarget(screen: screen, workspace: nil, pane: nil)
        }
        guard !rest.isEmpty else { throw ParseError.empty }

        let tail = String(rest)
        // 整串就是一个屏幕引用？只在没写过冒号 / 点、也没显式省略屏幕时成立
        if !afterScreen, !tail.contains(":"), !tail.contains("."), let onlyScreen = bareScreen(tail) {
            return ControlTarget(screen: onlyScreen, workspace: nil, pane: nil)
        }

        var workspace: WorkspaceRef?
        var panePart: String? = tail

        if let dot = tail.firstIndex(of: ".") {
            let head = String(tail[tail.startIndex..<dot])
            let after = String(tail[tail.index(after: dot)...])
            if head.isEmpty {
                // `2:.t7` / `.t7` —— 工作区留空
                panePart = after.isEmpty ? nil : after
            } else if let parsed = parseWorkspace(head) {
                workspace = parsed
                panePart = after.isEmpty ? nil : after
            }
        }
        if workspace == nil, afterScreen, let candidate = panePart, let parsed = parseWorkspace(candidate) {
            // `2:3` / `:3` —— 冒号右边整体就是工作区
            workspace = parsed
            panePart = nil
        }

        var pane: PaneRef?
        if let panePart {
            pane = try parsePane(panePart)
        }
        return ControlTarget(screen: screen, workspace: workspace, pane: pane)
    }

    /// 控制字符（< 0x20）一律拒绝：agent 会幻觉出参数，绝不能让它们进日志 / 标题 / 路径
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

    // MARK: 回写（用例的往返基准；也是错误信息里回显目标的形式）

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
            out += ":"   // `#uuid:` —— 裸 `#uuid` 是 pane，带冒号才是屏幕
        }
        return out
    }

    /// `--help` / `describe` 里那六行语法说明的唯一出处
    static let grammarLines: [String] = [
        "-t screen:workspace.pane   每段可省，向右默认取上下文",
        "screen     1 起序号（= 窗口标题）· #uuid: · @current · @primary",
        "workspace  1 起序号（= Cmd+1..0）· @active · @next · @prev",
        "pane       t7 / b3 句柄 · #uuid（≥4 位前缀）· @focused（默认）· @self",
        "           @left @right @up @down · @next @prev",
        "谓词       title:~<regex> · cwd:<prefix> · kind:terminal|browser · role:file-manager",
        "歧义       匹配到多个一律报错并列出候选，绝不取第一个（退出码 3）",
    ]
}
