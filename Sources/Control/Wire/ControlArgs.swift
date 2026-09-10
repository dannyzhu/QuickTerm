import Foundation

/// 命令行解析——**完全由 `ControlCommandTable` 驱动**。
/// 这里没有第二份命令清单：加一条命令只要往表里加一行，解析、`--help`、`describe` 一起就有了。
struct ParsedCommand {
    var spec: ControlCommandSpec
    var args: [String: JSONValue] = [:]
    var target: String?
    var forceJSON = false
    var forcePlain = false
    var socketOverride: String?
    var start = false
    var wantsHelp = false
}

enum ArgsError: Error, CustomStringConvertible {
    case unknownCommand(String)
    case unknownFlag(String, command: String?)
    case missingValue(String)
    case missingPositional(String, command: String)
    case tooManyPositionals(String)
    case badEnum(flag: String, value: String, allowed: [String])

    var description: String {
        switch self {
        case .unknownCommand(let name):
            "未知命令 \(name)（quickterm --help 有完整清单）"
        case .unknownFlag(let flag, let command):
            "未知选项 \(flag)\(command.map { "（quickterm \($0) --help）" } ?? "")"
        case .missingValue(let flag):
            "\(flag) 需要一个值"
        case .missingPositional(let name, let command):
            "quickterm \(command) 缺少参数 <\(name)>"
        case .tooManyPositionals(let value):
            "多余的参数：\(value)"
        case .badEnum(let flag, let value, let allowed):
            "\(flag) 不接受 \(value)；可用值：\(allowed.joined(separator: " | "))"
        }
    }
}

enum Args {
    /// 全局帮助 / 版本这类不落到具体命令的请求
    enum Outcome {
        case help(command: ControlCommandSpec?)
        case command(ParsedCommand)
    }

    static func parse(_ argv: [String]) throws -> Outcome {
        var rest = argv
        var globalHelp = false
        var pending: [String] = []

        // 命令名之前允许出现全局开关
        var spec: ControlCommandSpec?
        while !rest.isEmpty {
            let token = rest.removeFirst()
            if token == "--help" || token == "-h" || token == "help" {
                globalHelp = true
                continue
            }
            if token == "--version" || token == "-V" {
                spec = ControlCommandTable.command("version")
                break
            }
            if token.hasPrefix("-") {
                pending.append(token)
                continue
            }
            guard let found = ControlCommandTable.command(token) else {
                throw ArgsError.unknownCommand(token)
            }
            spec = found
            break
        }

        guard let spec else { return .help(command: nil) }
        var parsed = ParsedCommand(spec: spec)
        if globalHelp { return .help(command: spec) }

        let tokens = pending + rest
        var positionals = spec.args.filter(\.positional)
        var index = 0
        var sawDoubleDash = false

        while index < tokens.count {
            let token = tokens[index]
            index += 1
            if token == "--" { sawDoubleDash = true; continue }
            guard !sawDoubleDash, token.hasPrefix("-"), token != "-" else {
                try takePositional(token, into: &parsed, remaining: &positionals)
                continue
            }
            var name = token
            var inlineValue: String?
            if let eq = token.firstIndex(of: "="), token.hasPrefix("--") {
                name = String(token[token.startIndex..<eq])
                inlineValue = String(token[token.index(after: eq)...])
            }
            func value() throws -> String {
                if let inlineValue { return inlineValue }
                guard index < tokens.count else { throw ArgsError.missingValue(name) }
                let v = tokens[index]
                index += 1
                return v
            }

            switch name {
            case "-t", "--target":
                parsed.target = try value()
            case "--json":
                parsed.forceJSON = true
            case "--plain":
                parsed.forcePlain = true
            case "--socket":
                parsed.socketOverride = try value()
            case "--start":
                parsed.start = true
            case "-h", "--help":
                parsed.wantsHelp = true
            default:
                let long = name.hasPrefix("--") ? String(name.dropFirst(2)) : String(name.dropFirst())
                guard let arg = spec.args.first(where: { $0.name == long && !$0.positional }) else {
                    throw ArgsError.unknownFlag(token, command: spec.name)
                }
                switch arg.kind {
                case .bool:
                    parsed.args[arg.name] = .bool(inlineValue.flatMap { Bool($0) } ?? true)
                case .int:
                    parsed.args[arg.name] = .int(Int(try value()) ?? 0)
                case .double:
                    parsed.args[arg.name] = .double(Double(try value()) ?? 0)
                case .string:
                    parsed.args[arg.name] = .string(try value())
                case .enumeration:
                    let v = try value()
                    guard arg.values?.contains(v) ?? true else {
                        throw ArgsError.badEnum(flag: name, value: v, allowed: arg.values ?? [])
                    }
                    parsed.args[arg.name] = .string(v)
                }
            }
        }

        if !parsed.wantsHelp {
            // `action --list` 不需要位置参数
            let skipsPositionals = spec.name == "action" && parsed.args["list"]?.boolValue == true
            if !skipsPositionals, let missing = positionals.first(where: { $0.required }) {
                throw ArgsError.missingPositional(missing.name, command: spec.name)
            }
        }
        return .command(parsed)
    }

    private static func takePositional(_ value: String, into parsed: inout ParsedCommand,
                                       remaining: inout [ControlArgSpec]) throws {
        guard !remaining.isEmpty else { throw ArgsError.tooManyPositionals(value) }
        let arg = remaining.removeFirst()
        if arg.kind == .enumeration, let allowed = arg.values, !allowed.contains(value) {
            throw ArgsError.badEnum(flag: arg.name, value: value, allowed: allowed)
        }
        parsed.args[arg.name] = .string(value)
    }
}
