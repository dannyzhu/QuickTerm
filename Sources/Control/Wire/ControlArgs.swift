import Foundation

/// Command-line parsing — **driven entirely by `ControlCommandTable`**.
/// There is no second list of commands here: adding a command means adding one row to the table,
/// and parsing, `--help` and `describe` all follow from it.
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
    case missingVerb(group: String, verbs: [String])
    case unknownVerb(group: String, verb: String, verbs: [String])
    case unknownFlag(String, command: String?)
    case missingValue(String)
    case missingPositional(String, command: String)
    case tooManyPositionals(String)
    case badEnum(flag: String, value: String, allowed: [String])

    var description: String {
        switch self {
        case .unknownCommand(let name):
            "Unknown command \(name) (quickterm --help has the full list)"
        case .missingVerb(let group, let verbs):
            "quickterm \(group) needs a verb after it: \(verbs.joined(separator: " | "))"
        case .unknownVerb(let group, let verb, let verbs):
            "quickterm \(group) has no \(verb) verb; available: \(verbs.joined(separator: " | "))"
        case .unknownFlag(let flag, let command):
            "Unknown option \(flag)\(command.map { " (quickterm \($0) --help)" } ?? "")"
        case .missingValue(let flag):
            "\(flag) needs a value"
        case .missingPositional(let name, let command):
            "quickterm \(command) is missing the argument <\(name)>"
        case .tooManyPositionals(let value):
            "Unexpected extra argument: \(value)"
        case .badEnum(let flag, let value, let allowed):
            "\(flag) does not accept \(value); allowed values: \(allowed.joined(separator: " | "))"
        }
    }
}

enum Args {
    /// Global flags that take a value (when written before the command name, the value has to be
    /// consumed along with the flag).
    static let globalFlagsTakingAValue: Set<String> = ["-t", "--target", "--socket", "-f", "--file"]

    /// Requests that do not land on a specific command, such as global help or version.
    enum Outcome {
        case help(command: ControlCommandSpec?)
        /// `quickterm pane --help`: list the verbs in that group.
        case groupHelp(String)
        case command(ParsedCommand)
    }

    static func parse(_ argv: [String]) throws -> Outcome {
        var rest = argv
        var globalHelp = false
        var groupHelp: String?
        var pending: [String] = []

        // Global flags are allowed before the command name.
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
                // When a value-taking global flag is written **before** the command name
                // (`quickterm --socket /p state`), its value does not itself start with `-`. If we
                // do not consume it here, the next iteration treats that value as the command name
                // and reports a baffling "unknown command /p".
                if Self.globalFlagsTakingAValue.contains(token), !token.contains("="),
                   let value = rest.first, !value.hasPrefix("-") {
                    pending.append(rest.removeFirst())
                }
                continue
            }
            // Noun-verb: `quickterm pane new ...`. In the command table `pane.new` is a single row
            // and the group is just its prefix — we keep no second list here.
            let verbs = ControlCommandTable.commands(inGroup: token)
            if !verbs.isEmpty {
                guard let verbToken = rest.first(where: { !$0.hasPrefix("-") }) else {
                    if globalHelp || rest.contains("--help") || rest.contains("-h") {
                        groupHelp = token
                        break
                    }
                    throw ArgsError.missingVerb(group: token, verbs: verbs.map(\.verb))
                }
                guard let found = ControlCommandTable.command("\(token).\(verbToken)") else {
                    throw ArgsError.unknownVerb(group: token, verb: verbToken, verbs: verbs.map(\.verb))
                }
                if let index = rest.firstIndex(of: verbToken) { rest.remove(at: index) }
                spec = found
                break
            }
            guard let found = ControlCommandTable.command(token) else {
                throw ArgsError.unknownCommand(token)
            }
            spec = found
            break
        }

        if let groupHelp { return .groupHelp(groupHelp) }
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
            case "--dry-run":
                parsed.args[ControlCommandTable.Flag.dryRun] = .bool(true)
            case "--fail-if-noop":
                parsed.args[ControlCommandTable.Flag.failIfNoop] = .bool(true)
            case "-f":
                // `-f` is shorthand for `--file`. Only commands that declare a `file` argument
                // accept it (spec dump/apply/validate); on any other command `-f` is still an
                // "unknown option" — a shorthand should not quietly turn into a global flag that
                // exists everywhere.
                guard spec.args.contains(where: { $0.name == "file" }) else {
                    throw ArgsError.unknownFlag(token, command: spec.name)
                }
                parsed.args["file"] = .string(try value())
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
                    let v = try value()
                    if arg.repeatable {
                        var list = parsed.args[arg.name]?.arrayValue ?? []
                        list.append(.string(v))
                        parsed.args[arg.name] = .array(list)
                    } else {
                        parsed.args[arg.name] = .string(v)
                    }
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
            // `action --list` does not need its positional argument.
            let skipsPositionals = spec.name == "action" && parsed.args["list"]?.boolValue == true
            if !skipsPositionals, let missing = positionals.first(where: { $0.required }) {
                throw ArgsError.missingPositional(missing.name, command: spec.cli)
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
