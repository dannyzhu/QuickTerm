import Foundation

/// **The scanner for the agent rule files** (plan §2.3).
///
/// Why not `ConfigTOML.scan`: that one is a flat section/key/value scanner with no arrays, no
/// quoted keys and no dotted tables, and **every config load in the app runs through it**.
/// Widening it so a rule file can say `[hooks.Notification.values]` would widen the parser the
/// user's own `config.toml` is read with, for the sake of files nobody but us writes.
///
/// The grammar is exactly this and nothing more:
/// - `#` to end of line (outside a string), and blank lines;
/// - table headers `[a]`, `[a.b]`, `[a.b.c]` — segments `[A-Za-z0-9_-]+`, depth at most 3;
/// - `key = value`, the key bare (`[A-Za-z0-9_-]+`) or double-quoted, the value a double-quoted
///   string (escapes `\"`, `\\`, `\n` only) or a one-line array of double-quoted strings.
///
/// Anything else throws, and **the file is rejected whole**: a rule file that half-loaded would
/// silently disable exactly the events whose lines were mistyped, which is the one failure mode
/// nobody would notice until an approval prompt went unreported.
enum AgentRulesTOML {
    enum Value: Equatable {
        case string(String)
        case strings([String])

        var stringValue: String? { if case .string(let v) = self { v } else { nil } }
        /// A single string reads as a one-element list, so a rule file may write either
        /// `summary = "$.message"` or `summary = ["$.a", "$.b"]` wherever a list is allowed.
        var listValue: [String] {
            switch self {
            case .string(let v): [v]
            case .strings(let v): v
            }
        }
    }

    /// One table's entries, **in file order** — `[notifications]` matches its prefixes in the
    /// order they are written, so the order is part of the data, not an accident of parsing.
    struct Table: Equatable {
        /// `[]` for the keys written before the first header.
        var path: [String]
        var entries: [Entry]

        var name: String { path.joined(separator: ".") }

        func value(_ key: String) -> Value? { entries.first { $0.key == key }?.value }
    }

    struct Entry: Equatable {
        var key: String
        var value: Value
        var line: Int
    }

    struct Document: Equatable {
        var tables: [Table]

        func table(_ name: String) -> Table? { tables.first { $0.name == name } }
        /// Every table whose path starts with these segments (`hooks.` prefixed tables).
        func tables(under prefix: String) -> [Table] {
            tables.filter { $0.name == prefix || $0.name.hasPrefix(prefix + ".") }
        }
        /// A top-level key (written before the first header).
        func root(_ key: String) -> Value? { table("")?.value(key) }
    }

    static func parse(_ text: String) throws -> Document {
        var tables: [Table] = [Table(path: [], entries: [])]
        var current = 0
        for (offset, rawLine) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let number = offset + 1
            let line = stripComment(String(rawLine)).trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("[") {
                let path = try header(line, number: number)
                if let index = tables.firstIndex(where: { $0.path == path }) {
                    current = index
                } else {
                    tables.append(Table(path: path, entries: []))
                    current = tables.count - 1
                }
                continue
            }
            let entry = try assignment(line, number: number)
            guard !tables[current].entries.contains(where: { $0.key == entry.key }) else {
                throw AgentRulesError.syntax(line: number, text: "duplicate key \(entry.key)")
            }
            tables[current].entries.append(entry)
        }
        // Drop an empty root table so `tables` reads as "what the file actually declared".
        if tables.first?.entries.isEmpty == true { tables.removeFirst() }
        return Document(tables: tables)
    }

    // MARK: Lines

    /// Everything from an unquoted `#` on is a comment. Quotes are tracked so a `#` inside a
    /// notification prefix (`"Claude #1 needs you"`) survives.
    private static func stripComment(_ line: String) -> String {
        var out = ""
        var inString = false
        var escaped = false
        for character in line {
            if escaped { out.append(character); escaped = false; continue }
            if inString, character == "\\" { out.append(character); escaped = true; continue }
            if character == "\"" { inString.toggle(); out.append(character); continue }
            if character == "#", !inString { break }
            out.append(character)
        }
        return out
    }

    private static func header(_ line: String, number: Int) throws -> [String] {
        guard line.hasSuffix("]") else {
            throw AgentRulesError.syntax(line: number, text: "unterminated table header")
        }
        let inner = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        let path = inner.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard !path.isEmpty, path.count <= 3 else {
            throw AgentRulesError.syntax(line: number, text: "a table path is 1 to 3 segments")
        }
        for segment in path where !isBareKey(segment) {
            throw AgentRulesError.syntax(line: number, text: "bad table segment \(segment)")
        }
        return path
    }

    private static func assignment(_ line: String, number: Int) throws -> Entry {
        var scanner = Substring(line)
        let key: String
        if scanner.hasPrefix("\"") {
            key = try quoted(&scanner, number: number)
        } else {
            let raw = scanner.prefix { $0 != "=" && $0 != " " }
            scanner = scanner.dropFirst(raw.count)
            key = String(raw)
            guard isBareKey(key) else {
                throw AgentRulesError.syntax(line: number, text: "bad key \(key)")
            }
        }
        scanner = Substring(scanner.drop { $0 == " " })
        guard scanner.hasPrefix("=") else {
            throw AgentRulesError.syntax(line: number, text: "expected = after \(key)")
        }
        scanner = Substring(scanner.dropFirst().drop { $0 == " " })
        let value = try self.value(&scanner, number: number)
        guard scanner.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw AgentRulesError.syntax(line: number, text: "trailing text after the value of \(key)")
        }
        return Entry(key: key, value: value, line: number)
    }

    private static func value(_ scanner: inout Substring, number: Int) throws -> Value {
        if scanner.hasPrefix("\"") { return .string(try quoted(&scanner, number: number)) }
        guard scanner.hasPrefix("[") else {
            throw AgentRulesError.syntax(line: number,
                                         text: "a value is a \"string\" or a [\"list\", \"of\", \"strings\"]")
        }
        scanner = Substring(scanner.dropFirst().drop { $0 == " " })
        var out: [String] = []
        while true {
            if scanner.hasPrefix("]") { scanner = scanner.dropFirst(); break }
            guard scanner.hasPrefix("\"") else {
                throw AgentRulesError.syntax(line: number, text: "a list holds \"strings\" only")
            }
            out.append(try quoted(&scanner, number: number))
            scanner = Substring(scanner.drop { $0 == " " })
            if scanner.hasPrefix(",") {
                scanner = Substring(scanner.dropFirst().drop { $0 == " " })
                continue
            }
            guard scanner.hasPrefix("]") else {
                throw AgentRulesError.syntax(line: number, text: "expected , or ] in a list")
            }
            scanner = scanner.dropFirst()
            break
        }
        return .strings(out)
    }

    /// One double-quoted string, consuming it from the scanner. `\"`, `\\` and `\n` are the only
    /// escapes: a rule file has no business carrying a unicode escape, and refusing one is better
    /// than half-implementing it.
    private static func quoted(_ scanner: inout Substring, number: Int) throws -> String {
        guard scanner.hasPrefix("\"") else {
            throw AgentRulesError.syntax(line: number, text: "expected a quoted string")
        }
        var out = ""
        var index = scanner.index(after: scanner.startIndex)
        while index < scanner.endIndex {
            let character = scanner[index]
            if character == "\\" {
                let next = scanner.index(after: index)
                guard next < scanner.endIndex else {
                    throw AgentRulesError.syntax(line: number, text: "a string ends in a backslash")
                }
                switch scanner[next] {
                case "\"": out.append("\"")
                case "\\": out.append("\\")
                case "n": out.append("\n")
                default:
                    throw AgentRulesError.syntax(line: number,
                                                 text: "unsupported escape \\\(scanner[next])")
                }
                index = scanner.index(after: next)
                continue
            }
            if character == "\"" {
                scanner = scanner[scanner.index(after: index)...]
                return out
            }
            out.append(character)
            index = scanner.index(after: index)
        }
        throw AgentRulesError.syntax(line: number, text: "unterminated string")
    }

    private static func isBareKey(_ text: String) -> Bool {
        !text.isEmpty && text.allSatisfy {
            $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-")
        }
    }
}
