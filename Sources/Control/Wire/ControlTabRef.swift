import Foundation

/// 浏览器 pane 里**指一个标签**的写法（`--tab`）。
///
/// 与 pane 的寻址刻意分成两级：`-t` 永远指 pane（`b3`），`--tab` 才指 pane 里的标签。
/// 把标签混进 `-t` 的语法里只会得到一个谁也说不清的 `b3.2`——而 `.` 在那套语法里
/// 已经是"工作区.pane"的分隔符了。
///
/// 认三种写法，每一种都能在 `state` / `get` 的 `tabList` 里原样读到：
/// - **序号**（1 起，= 标签栏从左到右）：给人敲的；开关标签会让它整体移位，
///   所以两条命令之间隔着别的操作时别用它；
/// - **id**（`#<uuid 或 ≥4 位前缀>`）：标签活着就不变。agent 该用的那一种——
///   先 `get` 拿到 id，再 `--tab #<id>`，中间谁开了新标签都打不到别的页面上；
/// - **`@active`**（默认）/ **`@last`**：相对写法，不必先读状态。
///
/// **纯 Foundation**：本目录同时编进 app 与 `quickterm` 工具 target。
enum ControlTabRef: Equatable {
    /// 当前标签（`--tab` 不写时就是它）
    case active
    /// 最后一个标签
    case last
    /// 1 起的序号
    case index(Int)
    /// 稳定 id 的前缀（小写，无连字符）
    case id(String)

    /// id 前缀至少要几位——再短就会同时命中好几个标签，而"随便挑一个"是绝不允许的
    static let minIDPrefix = 4

    /// 命令表里 `--tab` 的帮助（**只有这一处**：help / describe / MCP 共用它）
    static let help = "which tab: 1-based index | #<id, or a prefix of ≥\(minIDPrefix)> | @active | @last"

    static let candidates = ["@active", "@last", "1", "#<id prefix>"]

    static func parse(_ raw: String) throws -> ControlTabRef {
        let text = raw.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return .active }
        switch text.lowercased() {
        case "@active", "active", "@current", "@focused": return .active
        case "@last", "last": return .last
        default: break
        }
        if text.hasPrefix("#") {
            let needle = String(text.dropFirst()).replacingOccurrences(of: "-", with: "").lowercased()
            guard needle.count >= minIDPrefix else {
                throw ControlErrorBody(
                    .badRequest,
                    "--tab #\(needle): an id prefix needs at least \(minIDPrefix) characters (anything shorter can match several tabs at once)",
                    hint: "quickterm get -t <pane> --json | jq '.data.pane.tabList'")
            }
            guard needle.allSatisfy({ $0.isHexDigit }) else {
                throw ControlErrorBody(.badRequest, "--tab #\(needle) is not an id (hexadecimal only)",
                                       candidates: candidates)
            }
            return .id(needle)
        }
        if let number = Int(text) {
            guard number >= 1 else {
                throw ControlErrorBody(.badRequest, "--tab indexes start at 1 (got \(number))",
                                       hint: help)
            }
            return .index(number)
        }
        throw ControlErrorBody(.badRequest, "Unrecognized --tab \(text)", hint: help,
                               candidates: candidates)
    }

    /// 回显用（错误文案里写回调用方原本要的那个）
    var text: String {
        switch self {
        case .active: "@active"
        case .last: "@last"
        case .index(let i): String(i)
        case .id(let prefix): "#\(prefix)"
        }
    }
}
