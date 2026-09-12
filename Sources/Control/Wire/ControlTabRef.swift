import Foundation

/// How to **name a single tab** inside a browser pane (`--tab`).
///
/// Addressing is deliberately split into two levels from pane addressing: `-t` always names a pane
/// (`b3`), and only `--tab` names a tab within that pane. Folding tabs into the `-t` syntax would
/// produce an unreadable `b3.2` — and in that syntax `.` is already the separator in
/// "workspace.pane".
///
/// Three forms are accepted, and every one of them can be read back verbatim from the `tabList` in
/// `state` / `get`:
/// - **index** (1-based, = the tab bar left to right): for humans to type; opening or closing a tab
///   shifts all of them, so do not use it when other operations happen between two commands;
/// - **id** (`#<uuid, or a prefix of ≥4>`): stable for as long as the tab lives. This is the one an
///   agent should use — `get` the id first, then `--tab #<id>`, and no tab someone opens in between
///   can make the command land on a different page;
/// - **`@active`** (the default) / **`@last`**: relative forms that need no prior state read.
///
/// **Pure Foundation**: this directory is compiled into both the app and the `quickterm` tool
/// target.
enum ControlTabRef: Equatable {
    /// The current tab (what you get when `--tab` is omitted).
    case active
    /// The last tab.
    case last
    /// A 1-based index.
    case index(Int)
    /// A prefix of the stable id (lowercased, hyphens stripped).
    case id(String)

    /// How many characters an id prefix needs at minimum — anything shorter can match several tabs
    /// at once, and "just pick one" is never allowed.
    static let minIDPrefix = 4

    /// The help text for `--tab` in the command table (**this is the only copy**: help, describe
    /// and MCP all share it).
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

    /// For echoing back: error messages quote the form the caller actually asked for.
    var text: String {
        switch self {
        case .active: "@active"
        case .last: "@last"
        case .index(let i): String(i)
        case .id(let prefix): "#\(prefix)"
        }
    }
}
