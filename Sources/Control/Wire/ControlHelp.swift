import Foundation

/// `--help` — **generated from the command table**, aimed at a model reading it all in one go
/// (≈100 lines).
/// Three rules taken from comparable tools:
/// - every subcommand's help **ends with EXAMPLES** (a model copies an example far more reliably
///   than it reads prose);
/// - every query command's help embeds a real (excerpted) output sample — wezterm's `--help` has no
///   such thing, so an agent burns one call per session just to learn the shape of the output;
/// - exit codes are laid out as a table and every error carries a stable `code`, so a model never
///   has to grep the prose.
enum Help {
    static func root(cliVersion: String) -> String {
        var out: [String] = []
        out.append("quickterm \(cliVersion) — drive QuickTerm's screens, workspaces and panes "
                   + "from the command line or an AI agent")
        out.append("")
        out.append("Usage: quickterm <command> [args] [-t target] [--json|--plain]")
        out.append("")
        out.append("COMMANDS")
        for spec in ControlCommandTable.commands where spec.group == nil {
            out.append("  " + pad(usage(spec)) + spec.summary)
        }
        out.append("")
        out.append("NOUN-VERB LAYER (**absolute setters, never toggles**; every one takes --dry-run / --fail-if-noop)")
        for group in ControlCommandTable.groups {
            let verbs = ControlCommandTable.commands(inGroup: group).map(\.verb).joined(separator: " | ")
            out.append("  " + pad(group) + verbs)
        }
        out.append("  (Help for one command: quickterm <noun> <verb> --help; the whole group: quickterm <noun> --help)")
        out.append("")
        out.append("TARGET SYNTAX")
        for line in ControlTarget.grammarLines { out.append("  \(line)") }
        out.append("")
        out.append("GLOBAL OPTIONS")
        for flag in ControlCommandTable.globalFlags {
            let name = "--\(flag.name)"
            out.append("  \(name.padding(toLength: 22, withPad: " ", startingAt: 0))\(flag.help)")
        }
        out.append("  --start               launch QuickTerm first if it is not running, then wait (up to 10s)")
        out.append("")
        out.append("EXIT CODES")
        for code in ControlExit.allCases {
            out.append("  \(String(code.rawValue).padding(toLength: 22, withPad: " ", startingAt: 0))\(code.summary)")
        }
        out.append("")
        out.append("OUTPUT")
        out.append("  stdout is a TTY → human-readable; not a TTY → JSON (an agent needs no extra flag).")
        out.append("  Errors are always JSON on stderr carrying a stable code; never match on the message text.")
        out.append("")
        out.append("EXAMPLES")
        out.append("  quickterm state --json | jq '.data.panes[] | {handle, title, cwd}'")
        out.append("  quickterm list panes --fields handle,kind,title")
        out.append("  quickterm get -t @self                    # which pane am I")
        out.append("  quickterm action new-terminal             # same as pressing the new-terminal keybinding")
        out.append("  quickterm action goto-workspace-3 -t 2    # switch screen 2 to workspace 3")
        out.append("  quickterm action toggle-zoom -t t7        # focuses t7 first, then runs")
        out.append("  quickterm pane new --cwd ~/proj --cmd 'npm run dev' --at t1 --where right")
        out.append("  quickterm pane set -t t7 --zoom on        # absolute setter: twice leaves the same state")
        out.append("  quickterm pane set -t t7 --title 'build'  # name the pane...")
        out.append("  quickterm get -t 'title:~build'           # ...then address it by that title")
        out.append("  quickterm pane capture-text -t t7         # read what t7 shows (off by default, see [control])")
        out.append("  quickterm browser open -t b3 --url http://localhost:3000   # a new tab")
        out.append("  quickterm browser goto -t b3 --tab 1 --url https://a.b     # point one tab at a URL")
        out.append("  quickterm workspace set-layout dwindle -t :4   # an inactive workspace works too")
        out.append("  quickterm pane move -t t7 --to 2:1 --follow")
        out.append("  quickterm spec dump > dev.json            # save this workspace as a spec")
        out.append("  quickterm spec apply -f dev.json -t :5 --dry-run   # see the diff before applying")
        out.append("  quickterm action --list --json            "
                   + "# all \(WMAction.allCases.count) actions and their safety class")
        out.append("  quickterm describe --json                 "
                   + "# the whole control plane as machine schema (read once)")
        out.append("  quickterm install-cli --alias qt          # install into PATH (never asks for an admin password)")
        out.append("")
        out.append("Agent tip: read `quickterm describe --json` once at the start of a session; "
                   + "after that you never need --help.")
        return out.joined(separator: "\n")
    }

    /// The listing for one noun group (`quickterm pane --help`).
    static func group(_ group: String) -> String {
        var out: [String] = ["quickterm \(group) <verb> [args] — the \(group) commands", ""]
        for spec in ControlCommandTable.commands(inGroup: group) {
            out.append("  " + pad(usage(spec), 34) + spec.summary)
        }
        out.append("")
        out.append("EXAMPLES")
        for spec in ControlCommandTable.commands(inGroup: group) {
            if let example = spec.examples.first { out.append("  \(example)") }
        }
        out.append("")
        out.append("Help for one command: quickterm \(group) <verb> --help")
        return out.joined(separator: "\n")
    }

    static func pad(_ text: String, _ width: Int = 22) -> String {
        text.padding(toLength: max(width, text.count + 1), withPad: " ", startingAt: 0)
    }

    /// The usage line (`pane new` plus its positionals) — no second copy is hand-written anywhere
    /// outside the command table.
    static func usage(_ spec: ControlCommandSpec) -> String {
        let positional = spec.args.filter(\.positional)
            .map { $0.required ? "<\($0.name)>" : "[\($0.name)]" }
            .joined(separator: " ")
        return ([spec.cli] + [positional]).filter { !$0.isEmpty }.joined(separator: " ")
    }

    static func command(_ spec: ControlCommandSpec) -> String {
        var out: [String] = []
        out.append("quickterm \(usage(spec)) — \(spec.summary)")
        out.append("")
        out.append("Class: \(spec.cls.rawValue)\(spec.cls.requiresConsent ? " (confirmed once inside QuickTerm)" : "")"
                   + "   Idempotent: \(spec.idempotent ? "yes" : "no")"
                   + "   Takes -t: \(spec.acceptsTarget ? "yes" : "no")")
        if !spec.args.isEmpty {
            out.append("")
            out.append("ARGUMENTS")
            for arg in spec.args {
                let label = arg.positional ? "<\(arg.name)>" : "--\(arg.name)"
                var line = "  \(label.padding(toLength: 18, withPad: " ", startingAt: 0))\(arg.help)"
                if let values = arg.values { line += " (\(values.joined(separator: " | ")))" }
                if let def = arg.defaultValue { line += " (default \(def))" }
                if arg.repeatable { line += " (repeatable)" }
                out.append(line)
            }
        }
        if spec.name == "action" {
            out.append("")
            out.append("Action classes: \(ControlCommandTable.interactiveActions.count) actions open a panel or "
                       + "pop-up menu that needs the keyboard,")
            out.append("and are always refused over the socket (exit code 5, code=interactive_action):")
            out.append("  " + ControlCommandTable.interactiveActions.map(\.rawValue).sorted().joined(separator: " "))
            out.append("\(ControlCommandTable.destructiveActions.count) are destructive and ask "
                       + "the user to confirm first:")
            out.append("  " + ControlCommandTable.destructiveActions.map(\.rawValue).sorted().joined(separator: " "))
        }
        if spec.group == "spec" {
            out.append("")
            out.append("\(SpecSchema.workspace) fields (every one may be omitted; the default is in parentheses)")
            for field in ControlDescribeDocument.specSchema.fields {
                let name = field.path.padding(toLength: 20, withPad: " ", startingAt: 0)
                out.append("  \(name)\(field.help)"
                           + (field.defaultValue.map { " (default \($0))" } ?? ""))
            }
            out.append("  Smallest usable spec: \(ControlDescribeDocument.specSchema.minimal)")
            out.append("")
            out.append("dwindle form (the same vocabulary)")
            for line in ControlCommandTable.specTreeSample.split(separator: "\n", omittingEmptySubsequences: false) {
                out.append("  \(line)")
            }
            out.append("")
            for note in ControlDescribeDocument.specSchema.notes { out.append("  \(note)") }
        }
        if spec.honorsMutationFlags {
            out.append("")
            out.append("COMMON MUTATION FLAGS")
            out.append("  --dry-run         report what would change (`changes` is the diff) and change nothing")
            out.append("  --fail-if-noop    exit 7 when already in the requested state "
                       + "instead of succeeding silently")
        }
        if let sample = spec.outputSample {
            out.append("")
            out.append("OUTPUT SAMPLE (excerpt)")
            for line in sample.split(separator: "\n", omittingEmptySubsequences: false) {
                out.append("  \(line)")
            }
        }
        out.append("")
        out.append("EXAMPLES")
        for example in spec.examples { out.append("  \(example)") }
        return out.joined(separator: "\n")
    }
}
