import Foundation

/// **Everything is generated from this one table**: CLI parsing, `--help`, `describe --json`, the
/// safety classes, and (Phase 5) the MCP tool table. No second command description may be
/// hand-written outside this table — a hand-written copy drifts within two releases, and an agent
/// holding a drifted schema just gets exit code 3 with no way to explain it.
enum ControlCommandClass: String, Codable, CaseIterable {
    /// Allowed silently (a caller with no token cannot read browser URLs or titles).
    case read
    /// Executed silently, but visibly (the Phase 2 status-bar flash plus an undo registration).
    case mutate
    /// Destroys something of the user's (closing a pane or a screen): confirmed once per
    /// calling pid and command class, for the rest of this launch.
    case destructive
    /// Opens a panel or pop-up menu that needs the keyboard: **always refused over the socket**.
    case interactive
    /// Touches the user's privacy or someone else's tty (send-text, reading browser URLs): Phase 4.
    case sensitive

    var requiresConsent: Bool { self == .destructive || self == .sensitive }
    var isMutation: Bool { self != .read }
}

struct ControlArgSpec: Codable, Equatable {
    enum Kind: String, Codable { case string, int, double, bool, enumeration }

    var name: String
    var kind: Kind
    var required: Bool
    var positional: Bool
    /// May be given repeatedly (`--env A=1 --env B=2`): the values collect into an array.
    /// Deliberately not comma-separated — an environment variable's value can perfectly well
    /// contain a comma.
    var repeatable: Bool
    var values: [String]?
    var defaultValue: String?
    var help: String

    init(_ name: String, _ kind: Kind, help: String, required: Bool = false,
         positional: Bool = false, repeatable: Bool = false,
         values: [String]? = nil, defaultValue: String? = nil) {
        self.name = name
        self.kind = kind
        self.required = required
        self.positional = positional
        self.repeatable = repeatable
        self.values = values
        self.defaultValue = defaultValue
        self.help = help
    }
}

struct ControlCommandSpec: Codable, Equatable {
    /// The command name on the wire: a top-level command is `state`, the noun-verb layer is
    /// `pane.new` (with a dot).
    /// **This is the only place it is assembled**: the CLI's `pane new`, `--help`, describe and MCP
    /// are all derived from it.
    var name: String
    /// The noun (`pane` / `workspace` / `screen` / `app`); nil for a top-level command.
    var group: String?
    /// The verb (`new` / `set-layout` / `state`).
    var verb: String
    /// The form typed on the command line (`pane new`) — same source as `name`, so the two cannot
    /// diverge.
    var cli: String
    var summary: String
    var cls: ControlCommandClass
    /// The same input run twice leaves the same state (mapped to MCP's idempotentHint in Phase 5).
    var idempotent: Bool
    var acceptsTarget: Bool
    /// Handled entirely on the CLI side, never over the socket (`install-cli`, `--help`).
    var local: Bool
    /// The CLI reads `-f <file>` (or stdin) first, stuffs it into the `spec` argument, and only
    /// then sends the request.
    /// **The server never reads the caller's file system**: the two processes have different cwds
    /// and different permissions to begin with, and "the server will open a path for you" is an
    /// abusable primitive.
    var readsFile: Bool
    var args: [ControlArgSpec]
    var examples: [String]
    /// A query command embeds a real (excerpted) output sample — the thing wezterm's `--help` lacks
    /// and kitty's docs have, and it saves an agent one exploratory call per session.
    var outputSample: String?

    /// Not in the `read` class (it touches privacy and someone else's tty), yet **changes
    /// nothing**: `pane capture-text`.
    /// See `honorsMutationFlags` — these two things have to be stated separately, or "sensitive"
    /// gets read as "mutating".
    var readOnlyEffect: Bool

    /// This command really **implements** `--dry-run` / `--fail-if-noop`.
    ///
    /// Both flags grew out of the noun-verb layer's shape of "compute the diff first, then decide
    /// whether to act" (the exit point is `ControlCommandRunner.commit()`). `action <wm-action>` is
    /// the keybinding-parity passthrough, straight to `perform()`: it can neither compute a diff
    /// nor rehearse anything.
    /// Accepting the flag silently costs twice over — a "rehearsal" actually cuts, and `--dry-run`
    /// also closes the confirmation gate on destructive commands while it is at it.
    /// **Commands with `readOnlyEffect` never accept these two flags either**, and that is more
    /// than "they would be meaningless": inside `handle()`, `--dry-run` doubles as the reason to
    /// **skip the confirmation** (a rehearsal changes nothing, so we do not ask the user). If a
    /// command that changes nothing but hands the caller the text off someone else's shell screen
    /// accepted `--dry-run`, that flag would become a back door past the confirmation gate that
    /// still yields the full contents.
    var honorsMutationFlags: Bool { group != nil && cls.isMutation && !readOnlyEffect }

    init(group: String? = nil, _ verb: String, summary: String, cls: ControlCommandClass,
         idempotent: Bool, acceptsTarget: Bool, local: Bool = false, readsFile: Bool = false,
         readOnlyEffect: Bool = false,
         args: [ControlArgSpec], examples: [String], outputSample: String? = nil) {
        self.name = group.map { "\($0).\(verb)" } ?? verb
        self.group = group
        self.verb = verb
        self.cli = group.map { "\($0) \(verb)" } ?? verb
        self.summary = summary
        self.cls = cls
        self.idempotent = idempotent
        self.acceptsTarget = acceptsTarget
        self.local = local
        self.readsFile = readsFile
        self.readOnlyEffect = readOnlyEffect
        self.args = args
        self.examples = examples
        self.outputSample = outputSample
    }
}

enum ControlCommandTable {
    // MARK: Commands

    static let commands: [ControlCommandSpec] = [
        ControlCommandSpec(
            "state",
            summary: "Read the whole session: a flat pane array plus a screen/workspace skeleton that refers to handles",
            cls: .read, idempotent: true, acceptsTarget: true, local: false,
            args: [
                ControlArgSpec("fields", .string,
                               help: "output only these pane fields (comma-separated, e.g. handle,cwd,title)"),
            ],
            examples: [
                "quickterm state",
                "quickterm state --json | jq '.data.panes[] | select(.focused)'",
                "quickterm state -t 2 --fields handle,title,cwd",
            ],
            outputSample: stateSample),
        ControlCommandSpec(
            "list",
            summary: "List screens / workspaces / panes",
            cls: .read, idempotent: true, acceptsTarget: true, local: false,
            args: [
                ControlArgSpec("what", .enumeration, help: "what to list", required: true,
                               positional: true, values: ["screens", "workspaces", "panes"]),
                ControlArgSpec("fields", .string, help: "output only these fields (comma-separated)"),
            ],
            examples: [
                "quickterm list panes",
                "quickterm list workspaces -t 2",
                "quickterm list panes --json | jq -r '.data.panes[].handle'",
            ],
            outputSample: listSample),
        ControlCommandSpec(
            "get",
            summary: "Read the full record of a single pane",
            cls: .read, idempotent: true, acceptsTarget: true, local: false,
            args: [],
            examples: [
                "quickterm get -t t7",
                "quickterm get -t @self",
                "quickterm get -t 'title:~nvim'",
            ],
            outputSample: getSample),
        ControlCommandSpec(
            "action",
            summary: "Run a WM action (the keybinding-parity passthrough; all \(WMAction.allCases.count) of them)",
            cls: .mutate, idempotent: false, acceptsTarget: true, local: false,
            args: [
                ControlArgSpec("name", .string, help: "action name (kebab-case; see --list)",
                               required: true, positional: true),
                ControlArgSpec("list", .bool, help: "list every action with its safety class instead of running one"),
                ControlArgSpec("precise", .bool, help: "fine step (same as holding Shift for resize-*)"),
            ],
            examples: [
                "quickterm action new-terminal",
                "quickterm action goto-workspace-3 -t 2",
                "quickterm action --list --json",
            ],
            outputSample: nil),
        ControlCommandSpec(
            "describe",
            summary: "Dump the whole control plane as a machine-readable schema (one read per agent session is enough)",
            cls: .read, idempotent: true, acceptsTarget: false, local: false,
            args: [],
            examples: [
                "quickterm describe --json",
                "quickterm describe --json | jq '.commands[].name'",
            ],
            outputSample: nil),
        ControlCommandSpec(
            "version",
            summary: "Print the CLI and running QuickTerm versions, the protocol version and the socket path",
            cls: .read, idempotent: true, acceptsTarget: false, local: false,
            args: [],
            examples: ["quickterm version", "quickterm version --json"],
            outputSample: nil),
        ControlCommandSpec(
            "install-cli",
            summary: "Symlink quickterm (and optionally a qt alias) into PATH — never asks for an admin password",
            cls: .read, idempotent: true, acceptsTarget: false, local: true,
            args: [
                ControlArgSpec("alias", .string, help: "also create a short alias (usually qt)"),
                ControlArgSpec("dir", .string, help: "install directory (default /usr/local/bin, or ~/.local/bin when that is not writable)"),
            ],
            examples: [
                "quickterm install-cli",
                "quickterm install-cli --alias qt",
            ],
            outputSample: nil),

        // MARK: - Phase 2: the noun-verb layer (**absolute setters, never toggles**) -
        // An agent cannot see state, so retrying a toggle undoes its own work. Every command in
        // this layer leaves the same state when run twice, and the second run exits 7 under
        // `--fail-if-noop`. `action <wm-action>` is the only passthrough that keeps toggle
        // semantics.

        ControlCommandSpec(
            group: "pane", "new",
            summary: "Create a pane (terminal / browser / file manager) with an optional cwd, command, environment and placement",
            cls: .mutate, idempotent: false, acceptsTarget: true,
            args: [
                ControlArgSpec("kind", .enumeration, help: "pane kind",
                               values: ["terminal", "browser", "file-manager"], defaultValue: "terminal"),
                ControlArgSpec("cwd", .string, help: "starting directory (~ is expanded; inherited from the anchor pane by default)"),
                ControlArgSpec("require-cwd", .bool,
                               help: "**fail** when --cwd cannot be used (by default the pane opens anyway and the reply carries a cwd_denied warning): "
                                   + "that is what happens for a protected directory (~/Desktop ~/Documents ~/Downloads) with no privacy permission granted"),
                ControlArgSpec("cmd", .string, help: "command to run (the engine sets wait-after-command; by default the pane closes when it exits)"),
                ControlArgSpec("hold", .bool, help: "do **not** close the pane when the command exits (it closes by default)"),
                ControlArgSpec("env", .string, help: "extra environment variable KEY=VALUE", repeatable: true),
                ControlArgSpec("url", .string, help: "URL for the browser pane to open (--kind browser)"),
                ControlArgSpec("at", .string, help: "anchor pane to place it next to (target syntax; defaults to the focused pane)"),
                ControlArgSpec("where", .enumeration, help: "side of the anchor to land on",
                               values: ["right", "left", "up", "down", "stack"], defaultValue: "right"),
            ],
            examples: [
                "quickterm pane new --cwd ~/proj --cmd 'npm run dev' --at t1 --where right",
                "quickterm pane new --kind browser --url http://localhost:3000 --at t1 --where down",
                "quickterm pane new --kind file-manager --cwd ~/proj",
                "quickterm pane new --cmd 'tail -f log' --hold --env RUST_LOG=debug",
                "quickterm pane new --cwd ~/Downloads --require-cwd   # exit 5 if the directory is unusable, never land elsewhere silently",
            ],
            outputSample: paneMutationSample),
        ControlCommandSpec(
            group: "pane", "close",
            summary: "Close a pane, killing the processes inside it (destructive; confirmed once per "
                + "calling pid and command class)",
            cls: .destructive, idempotent: false, acceptsTarget: true,
            args: [
                ControlArgSpec("force", .bool, help: "skip QuickTerm's own \"a process is still running\" prompt"),
            ],
            examples: [
                "quickterm pane close -t t7",
                "quickterm pane close -t b3 --force",
            ],
            outputSample: nil),
        ControlCommandSpec(
            group: "pane", "focus",
            summary: "Give keyboard focus to a pane (idempotent: does nothing when it is already focused)",
            cls: .mutate, idempotent: true, acceptsTarget: true,
            args: [
                ControlArgSpec("where", .enumeration, help: "direction relative to the current focus (omit it and use -t)",
                               positional: true,
                               values: ["left", "right", "up", "down", "next", "prev"]),
            ],
            examples: [
                "quickterm pane focus -t t7",
                "quickterm pane focus right",
            ],
            outputSample: nil),
        ControlCommandSpec(
            group: "pane", "move",
            summary: "Move a pane to another workspace / screen, optionally at a chosen spot (does not follow by default)",
            cls: .mutate, idempotent: false, acceptsTarget: true,
            args: [
                ControlArgSpec("to", .string, help: "destination screen:workspace (e.g. 2:4, :3, @next)", required: true),
                ControlArgSpec("at", .string, help: "anchor pane inside the destination workspace"),
                ControlArgSpec("where", .enumeration, help: "side of the anchor to land on",
                               values: ["right", "left", "up", "down", "stack"], defaultValue: "right"),
                ControlArgSpec("follow", .bool, help: "switch to the destination workspace / screen as well (does not follow by default)"),
                ControlArgSpec("no-follow", .bool, help: "explicitly do not follow (the default)"),
            ],
            examples: [
                "quickterm pane move -t t7 --to :4",
                "quickterm pane move -t t7 --to 2:1 --at t9 --where down --follow",
            ],
            outputSample: nil),
        ControlCommandSpec(
            group: "pane", "swap",
            summary: "Swap two panes (positions are absolute: swapping them back takes a second call)",
            cls: .mutate, idempotent: false, acceptsTarget: true,
            args: [
                ControlArgSpec("with", .string, help: "the pane to swap with (target syntax)", required: true),
            ],
            examples: ["quickterm pane swap -t t7 --with t2"],
            outputSample: nil),
        ControlCommandSpec(
            group: "pane", "set",
            summary: "Absolute setters: zoom / float / column width / dwindle split ratio / title "
                + "(the same command twice lands the same result)",
            cls: .mutate, idempotent: true, acceptsTarget: true,
            args: [
                ControlArgSpec("zoom", .enumeration, help: "whether this pane fills the content area", values: ["on", "off"]),
                ControlArgSpec("float", .enumeration, help: "whether this pane floats", values: ["on", "off"]),
                ControlArgSpec("width", .double, help: "scrolling column width factor (0.25–0.90, absolute)"),
                ControlArgSpec("ratio", .double,
                               help: "ratio of the nearest parent split in dwindle (\(SpecLimits.ratioRange.lowerBound)–\(SpecLimits.ratioRange.upperBound), absolute; out of range is an error)"),
                ControlArgSpec("title", .string,
                               help: "title of a terminal pane (= the right-click \"Change Terminal Title\" item); "
                                   + "an empty string \"\" drops the override and hands the title back to the shell. "
                                   + "Once set, -t 'title:~<regex>' addresses this pane"),
            ],
            examples: [
                "quickterm pane set -t t7 --zoom on",
                "quickterm pane set -t t7 --float off --width 0.33",
                "quickterm pane set -t t7 --title 'build · web'   # -t 'title:~build' finds it afterwards",
                "quickterm pane set -t t7 --title ''              # hand the title back to the shell",
            ],
            outputSample: nil),
        ControlCommandSpec(
            group: "pane", "resize",
            summary: "Resize by ratio, by points or by column width factor, the way dragging a divider or a "
                + "column edge and ⌘⌃arrows do. **A signed value (+0.05 / +120) is relative to where the "
                + "divider is now, so a second call moves it again** — only at the boundary is it a no-op "
                + "(exit 7); a bare value (0.33) is absolute",
            cls: .mutate, idempotent: false, acceptsTarget: true,
            args: [
                ControlArgSpec("width", .string, help: "scrolling column width factor: a delta (+0.05) or an absolute value (0.33)"),
                ControlArgSpec("ratio", .string, help: "dwindle split ratio: a delta (+0.1) or an absolute value (0.5)"),
                ControlArgSpec("points", .string,
                               help: "work in **points** instead: +120 moves this divider 120pt right/down, 120 sets the a side to 120pt"
                                   + " (in scrolling this is the column width in points)"),
                ControlArgSpec("dir", .enumeration,
                               help: "resize by direction, the same as ⌘⌃arrows or a ⌘right-drag: the nearest divider on that axis, "
                                   + "stepping by --points (default 100); mutually exclusive with --split",
                               values: ["left", "right", "up", "down"]),
                ControlArgSpec("split", .string,
                               help: "dwindle: name the divider to move (a tree path of a/b joined by dots; the root one is root); "
                                   + "omit it for this pane's own parent split; mutually exclusive with --dir"),
            ],
            examples: [
                "quickterm pane resize -t t7 --width +0.05",
                "quickterm pane resize -t t8 --ratio 0.5",
                "quickterm pane resize -t t8 --points +120",
                "quickterm pane resize -t t8 --split root --ratio 0.3",
                "quickterm pane resize -t t7 --dir right --points 100",
            ],
            outputSample: resizeSample),
        ControlCommandSpec(
            group: "pane", "capture-text",
            summary: "Read **the text currently on screen** in a terminal pane, optionally with some scrollback — "
                + "off by default, and confirmed once per calling process",
            cls: .sensitive, idempotent: true, acceptsTarget: true, readOnlyEffect: true,
            args: [
                ControlArgSpec("scrollback", .int,
                               help: "how many scrollback lines above the viewport to include (0–\(ControlCaptureLimits.maxScrollback); the default 0 means the viewport only)",
                               defaultValue: "0"),
            ],
            examples: [
                "quickterm pane capture-text -t t7",
                "quickterm pane capture-text -t t7 --scrollback 200",
                "quickterm pane capture-text -t t7 --json | jq -r .data.text",
            ],
            outputSample: captureTextSample),

        // MARK: - Tabs inside a browser pane -
        // `-t` always names the **pane** (`b3`); only `--tab` names one tab inside it.
        // A tab has two forms, both echoed back in the `tabList` of `state` / `get`: the index
        // (1-based, and it shifts as tabs are opened and closed) and the id (unchanged for as long
        // as the tab lives). **A caller without a token cannot read titles or URLs** — the same
        // redaction rule as the pane-level url / title, because a back door anywhere else is the
        // same as not redacting at all.

        ControlCommandSpec(
            group: "browser", "open",
            summary: "Open a new tab in a browser pane and load a URL",
            cls: .mutate, idempotent: false, acceptsTarget: true,
            args: [
                ControlArgSpec("url", .string, help: "URL to open (omit it for the browser home page)"),
                ControlArgSpec("activate", .enumeration,
                               help: "a creation option for **the new tab**, not a setter: on opens it in front, "
                                   + "off opens it behind the current one. It decides nothing about any tab that "
                                   + "already exists — browser goto navigates a tab without activating it, and "
                                   + "`action web-next-tab` / `web-prev-tab` are the only way to change which tab "
                                   + "is active",
                               values: ["on", "off"],
                               defaultValue: "on"),
            ],
            examples: [
                "quickterm browser open -t b3 --url http://localhost:3000",
                "quickterm browser open -t b3 --url https://example.com --activate off",
            ],
            outputSample: browserSample),
        ControlCommandSpec(
            group: "browser", "goto",
            summary: "Navigate a tab to a URL (absolute setter: does nothing when it is already there)",
            cls: .mutate, idempotent: true, acceptsTarget: true,
            args: [
                ControlArgSpec("url", .string, help: "URL to open", required: true),
                ControlArgSpec("tab", .string, help: ControlTabRef.help, defaultValue: "@active"),
            ],
            examples: [
                "quickterm browser goto -t b3 --url http://localhost:5173",
                "quickterm browser goto -t b3 --tab 2 --url https://example.com",
                "quickterm browser goto -t b3 --tab '#8A1F' --url https://example.com",
            ],
            outputSample: nil),
        ControlCommandSpec(
            group: "browser", "reload",
            summary: "Reload a tab (`--hard` bypasses the cache as well)",
            cls: .mutate, idempotent: true, acceptsTarget: true,
            args: [
                ControlArgSpec("tab", .string, help: ControlTabRef.help, defaultValue: "@active"),
                ControlArgSpec("hard", .bool, help: "bypass the cache (same as ⌘⇧R)"),
            ],
            examples: [
                "quickterm browser reload -t b3",
                "quickterm browser reload -t b3 --tab 1 --hard",
            ],
            outputSample: nil),
        ControlCommandSpec(
            group: "browser", "close",
            summary: "-t names the pane; --tab picks the tab (default: the active one). Closes that one tab "
                + "(destructive). **Closing the last tab closes the whole pane** — exactly what ⌘W does",
            cls: .destructive, idempotent: false, acceptsTarget: true,
            args: [
                ControlArgSpec("tab", .string, help: ControlTabRef.help, defaultValue: "@active"),
                ControlArgSpec("others", .bool,
                               help: "the other way round: close every tab **except** the one --tab names (this alone never closes the pane)"),
                ControlArgSpec("force", .bool,
                               help: "only means anything when closing the last tab would close the pane: "
                                   + "skip QuickTerm's \"a process is still running\" prompt"),
            ],
            examples: [
                "quickterm browser close -t b3                 # close the active tab",
                "quickterm browser close -t b3 --tab 1         # close the first tab",
                "quickterm browser close -t b3 --others        # keep only the active one",
            ],
            outputSample: nil),

        ControlCommandSpec(
            group: "workspace", "goto",
            summary: "Switch to a workspace (idempotent)",
            cls: .mutate, idempotent: true, acceptsTarget: true,
            args: [
                ControlArgSpec("index", .int, help: "workspace index (1-based)", required: true, positional: true),
            ],
            examples: ["quickterm workspace goto 3", "quickterm workspace goto 1 -t 2"],
            outputSample: nil),
        ControlCommandSpec(
            group: "workspace", "set-layout",
            summary: "Set a workspace to scrolling / dwindle — **it works on inactive workspaces too**, which toggle-layout cannot do",
            cls: .mutate, idempotent: true, acceptsTarget: true,
            args: [
                ControlArgSpec("layout", .enumeration, help: "layout", required: true, positional: true,
                               values: ["scrolling", "dwindle"]),
            ],
            examples: [
                "quickterm workspace set-layout dwindle -t :4",
                "quickterm workspace set-layout scrolling -t 2:1",
            ],
            outputSample: nil),
        ControlCommandSpec(
            group: "workspace", "set",
            summary: "Absolute setter: name a workspace (the same command twice lands the same result)",
            cls: .mutate, idempotent: true, acceptsTarget: true,
            args: [
                ControlArgSpec("title", .string,
                               help: "name of the workspace (= renaming its pill from the right-click menu); an empty string \"\" clears it and the pill falls back to the index. "
                                   + "The name belongs to the **slot**, not to the panes inside it: workspace clear and closing the last pane "
                                   + "both leave it alone. The only things that change it are this command, a right-click rename, "
                                   + "and a spec that **carries a title** (the one `spec dump` writes does)"),
            ],
            examples: [
                "quickterm workspace set --title dev",
                "quickterm workspace set -t 2:4 --title 'web · logs'",
                "quickterm workspace set -t :4 --title ''            # clear the name",
            ],
            outputSample: nil),
        ControlCommandSpec(
            group: "workspace", "equalize",
            summary: "Equalize every column width and split ratio in a workspace (idempotent)",
            cls: .mutate, idempotent: true, acceptsTarget: true,
            args: [],
            examples: ["quickterm workspace equalize -t :2"],
            outputSample: nil),
        ControlCommandSpec(
            group: "workspace", "clear",
            summary: "Close every pane in a workspace (destructive)",
            cls: .destructive, idempotent: true, acceptsTarget: true,
            args: [
                ControlArgSpec("force", .bool,
                               help: "no longer does anything: the control plane already confirmed once for the whole workspace (same as screen close)"),
            ],
            examples: ["quickterm workspace clear -t :5"],
            outputSample: nil),
        ControlCommandSpec(
            group: "workspace", "count",
            summary: "Set how many workspaces there are (1–10): rewrites workspaces in config.toml, which the config watcher applies",
            cls: .mutate, idempotent: true, acceptsTarget: false,
            args: [
                ControlArgSpec("n", .int, help: "how many (1–10)", required: true, positional: true),
            ],
            examples: ["quickterm workspace count 8"],
            outputSample: nil),

        ControlCommandSpec(
            group: "screen", "new",
            summary: "Create a screen (a window), optionally on a chosen display",
            cls: .mutate, idempotent: false, acceptsTarget: false,
            args: [
                ControlArgSpec("display", .string, help: "display: uuid:<…> / name:<…> / 1-based index"),
                ControlArgSpec("inherit-cwd-from", .string, help: "the new screen's first terminal inherits this pane's directory"),
            ],
            examples: [
                "quickterm screen new",
                "quickterm screen new --display 'name:Studio Display' --inherit-cwd-from t1",
            ],
            outputSample: nil),
        ControlCommandSpec(
            group: "screen", "close",
            summary: "Close a screen together with every pane on it (destructive)",
            cls: .destructive, idempotent: false, acceptsTarget: true,
            args: [
                ControlArgSpec("force", .bool, help: "skip QuickTerm's own close-screen prompt"),
            ],
            examples: ["quickterm screen close -t 2 --force"],
            outputSample: nil),
        ControlCommandSpec(
            group: "screen", "move",
            summary: "Move a screen to another display (idempotent: does nothing when it is already there)",
            cls: .mutate, idempotent: true, acceptsTarget: true,
            args: [
                ControlArgSpec("display", .string, help: "display: uuid:<…> / name:<…> / 1-based index", required: true),
            ],
            examples: ["quickterm screen move -t 2 --display 1"],
            outputSample: nil),
        ControlCommandSpec(
            group: "screen", "focus",
            summary: "Bring a screen's window to the front and make it key (idempotent)",
            cls: .mutate, idempotent: true, acceptsTarget: true,
            args: [],
            examples: ["quickterm screen focus -t 2"],
            outputSample: nil),
        ControlCommandSpec(
            group: "screen", "set",
            summary: "Absolute setters: fullscreen / show on all desktops / columns visible per screen",
            cls: .mutate, idempotent: true, acceptsTarget: true,
            args: [
                ControlArgSpec("fullscreen", .enumeration, help: "non-native fullscreen", values: ["on", "off"]),
                ControlArgSpec("join-all-spaces", .enumeration, help: "show on all desktops", values: ["on", "off"]),
                ControlArgSpec("visible-columns", .int, help: "columns visible per screen in scrolling (1–6)"),
            ],
            examples: [
                "quickterm screen set -t 1 --fullscreen off --visible-columns 3",
                "quickterm screen set -t 2 --join-all-spaces on",
            ],
            outputSample: nil),

        ControlCommandSpec(
            group: "app", "get",
            summary: "Read process-level settings (theme / background / gaps / opacity / status bar / visible columns / control plane)",
            cls: .read, idempotent: true, acceptsTarget: true,
            args: [
                ControlArgSpec("key", .string, help: "read a single setting (omit it for all of them)", positional: true),
            ],
            examples: ["quickterm app get", "quickterm app get theme"],
            outputSample: appGetSample),
        ControlCommandSpec(
            group: "app", "set",
            summary: "Process-level settings as absolute setters (the socket-side route around the 6 modal-panel actions)",
            cls: .mutate, idempotent: true, acceptsTarget: true,
            args: [
                ControlArgSpec("key", .enumeration, help: "setting", required: true, positional: true,
                               values: ControlAppSetting.allCases.map(\.rawValue)),
                ControlArgSpec("value", .string, help: "value (see choices in app get)", required: true, positional: true),
            ],
            examples: [
                "quickterm app set theme tokyo-night",
                "quickterm app set gaps off",
                "quickterm app set visible-columns 3 -t 2",
            ],
            outputSample: nil),

        // MARK: - Phase 3: compose it in one shot (`quickterm.workspace/1`) -
        // Lay out a whole workspace in a single call instead of sending N pane-new commands and
        // then adjusting widths one by one: N commands = N relayouts, N animations, N failure
        // points, and a failure partway through leaves a half-built thing nobody can describe.

        ControlCommandSpec(
            group: "spec", "dump",
            summary: "Dump a workspace, a screen or the whole session as \(SpecSchema.workspace) JSON",
            cls: .read, idempotent: true, acceptsTarget: true,
            args: [
                ControlArgSpec("all", .bool, help: "the whole session (\(SpecSchema.session))"),
                ControlArgSpec("relocatable", .bool, help: "write paths under home as ~/… (so the spec works on another machine)"),
                ControlArgSpec("include-ids", .bool,
                               help: "include id / handle / title (for diffs and --reuse; other modes ignore id, and it never joins the fixed-point comparison)"),
            ],
            examples: [
                "quickterm spec dump > dev.json                # the current workspace",
                "quickterm spec dump -t 1:2 > dev.json",
                "quickterm spec dump -t 1 --relocatable > screen.json   # a -t naming only a screen = that whole screen",
                "quickterm spec dump --all > session.json",
            ],
            outputSample: specSample),
        ControlCommandSpec(
            group: "spec", "validate",
            summary: "Validate a spec and nothing else: known keys, value ranges, whether the workspace index can take it (changes nothing)",
            cls: .read, idempotent: true, acceptsTarget: true, readsFile: true,
            args: [
                ControlArgSpec("file", .string, help: "spec file (- or omitted reads stdin)"),
                ControlArgSpec("spec", .string, help: "the spec JSON body inline (instead of -f)"),
            ],
            examples: [
                "quickterm spec validate -f dev.json",
                "quickterm spec dump | quickterm spec validate",
                "quickterm spec validate --spec '{\"columns\":[{},{}]}'",
            ],
            outputSample: nil),
        ControlCommandSpec(
            group: "spec", "apply",
            summary: "Apply a spec to the target; --replace is destructive and confirms first, --dry-run only reports the diff",
            cls: .destructive, idempotent: true, acceptsTarget: true, readsFile: true,
            args: [
                ControlArgSpec("file", .string, help: "spec file (- or omitted reads stdin)"),
                ControlArgSpec("spec", .string, help: "the spec JSON body inline (instead of -f)"),
                ControlArgSpec("into-empty", .bool,
                               help: "the default: fill an empty workspace only; a non-empty one is refused (exit code 4), so nothing can be destroyed"),
                ControlArgSpec("replace", .bool,
                               help: "overwrite: close every existing pane (**destructive**, confirms first; a no-op when the spec already matches exactly)"),
                ControlArgSpec("reuse", .bool,
                               help: "keep every pane that matches right where it is, so a running dev server is not restarted, and close / create the rest"),
                ControlArgSpec("require-cwd", .bool,
                               help: "**fail** when a directory in the spec cannot be used (by default it is applied anyway and the reply carries a cwd_denied warning): "
                                   + "that is what happens for a protected directory with no privacy permission granted"),
            ],
            examples: [
                "quickterm spec apply -f dev.json --dry-run           # look at the diff first, then decide",
                "quickterm spec apply -f dev.json -t 2:4 --replace",
                "quickterm spec apply -f dev.json --reuse",
                "quickterm spec apply -t :5 --spec '{\"columns\":[{\"panes\":[{}]},{\"panes\":[{},{}]}]}'",
            ],
            outputSample: specApplySample),

        // MARK: - Phase 4: the event stream -
        // Long polling is the **primary form**: a never-ending stream is expensive for a model
        // (every line enters its context and it has to watch the stream itself), while one `poll
        // --since` call answers "what happened since I last looked".
        // **No event ever carries a pane's output** — that is where the privacy leak surface and
        // the flow-control complexity both live.

        ControlCommandSpec(
            group: "events", "poll",
            summary: "Long poll: return as soon as the events missed since --since are in hand (the shape an agent wants)",
            cls: .read, idempotent: true, acceptsTarget: false,
            args: [
                ControlArgSpec("since", .int,
                               help: "the seq you last received (omit it for the current seq, i.e. wait only for what happens next)"),
                ControlArgSpec("timeout", .string, help: "how long to wait when nothing happens (5s / 500ms / 2m)",
                               defaultValue: "5s"),
                ControlArgSpec("limit", .int,
                               help: "how many events one reply may carry (when it truncates, the seq returned only reaches the last event actually sent "
                                   + "and truncated=true comes with it: poll again with that seq right away and nothing is lost)",
                               defaultValue: String(ControlEventLimits.maxBatch)),
                ControlArgSpec("types", .string,
                               help: "only these types (comma-separated, e.g. pane.opened,focus.changed)"),
            ],
            examples: [
                "quickterm events poll --since 412",
                "quickterm events poll --since 412 --timeout 30s",
                "quickterm events poll --types pane.opened,pane.closed --timeout 0",
                "quickterm events poll --since $(quickterm state --json | jq .seq)",
            ],
            outputSample: eventsSample),
        ControlCommandSpec(
            group: "events", "follow",
            summary: "NDJSON stream: the connection stays open and events are pushed one at a time (for humans and shell scripts; Ctrl-C ends it)",
            cls: .read, idempotent: true, acceptsTarget: false,
            args: [
                ControlArgSpec("since", .int, help: "replay what already happened after this seq first (omit it to push only new events)"),
                ControlArgSpec("limit", .int,
                               help: "how many events one batch may carry (a truncated batch loses nothing: the next one carries on)",
                               defaultValue: String(ControlEventLimits.maxBatch)),
                ControlArgSpec("types", .string, help: "only these types (comma-separated)"),
            ],
            examples: [
                "quickterm events follow",
                "quickterm events follow --types focus.changed",
                "quickterm events follow --json | jq -r '.data.events[].type'",
            ],
            outputSample: nil),

        // MARK: - Phase 4: injecting text into a pane -
        // This is the one command in the whole control plane that can make someone else's shell run
        // arbitrary commands. Off by default, and even once it is on, confirmed every single time
        // (except when writing into the caller's own pane).

        ControlCommandSpec(
            group: "input", "send-text",
            summary: "Send text into a terminal pane as keyboard input — **this is typing into that shell** (off by default)",
            cls: .sensitive, idempotent: false, acceptsTarget: true,
            args: [
                ControlArgSpec("text", .string, help: "the text to send (control characters are always refused)",
                               required: true, positional: true),
                ControlArgSpec("enter", .bool,
                               help: "send a Return after the text — **the only way to make it run** (not sent by default)"),
            ],
            examples: [
                "quickterm input send-text 'git status' -t @self",
                "quickterm input send-text 'git status' -t @self --enter",
                "quickterm input send-text 'npm run dev' -t t7 --enter   # another pane: confirmed every single time",
            ],
            outputSample: sendTextSample),

        // MARK: - Phase 5: MCP (stdio) -
        // The tool table is **generated from this command table** (`MCPToolMap`). A hand-written
        // tool description drifts within two releases, and the cost of that drift is an agent
        // holding a stale schema and getting errors it cannot explain.

        ControlCommandSpec(
            "mcp",
            summary: "Run an MCP server over stdio (its tool list is generated from this command table; mount it in Claude Code / Codex)",
            cls: .read, idempotent: true, acceptsTarget: false, local: true,
            args: [
                ControlArgSpec("list-tools", .bool, help: "print the tool list as JSON and exit instead of entering the stdio loop"),
            ],
            examples: [
                "quickterm mcp                       # the MCP host launches this; do not type it in a terminal",
                "quickterm mcp --list-tools          # see which tools get exposed and how they are annotated",
                "quickterm mcp --list-tools | jq -r '.tools[].name'",
            ],
            outputSample: nil),
    ]

    /// The order the noun groups appear in (`--help` and `describe` share this one list).
    static var groups: [String] {
        var out: [String] = []
        for spec in commands { if let g = spec.group, !out.contains(g) { out.append(g) } }
        return out
    }

    static func commands(inGroup group: String) -> [ControlCommandSpec] {
        commands.filter { $0.group == group }
    }

    /// Accepts both the wire name (`pane.new`) and the command-line form (`pane new`) — both are
    /// generated in the same place, so they resolve to the same row.
    static func command(_ name: String) -> ControlCommandSpec? {
        let normalized = name.replacingOccurrences(of: " ", with: ".")
        return commands.first { $0.name == normalized }
    }

    /// The global flags (usable on every subcommand).
    static let globalFlags: [ControlArgSpec] = [
        ControlArgSpec("target", .string, help: "target screen:workspace.pane (-t)"),
        ControlArgSpec("json", .bool, help: "force JSON output (it is already JSON when stdout is not a TTY)"),
        ControlArgSpec("plain", .bool, help: "force human-readable output"),
        ControlArgSpec("socket", .string, help: "socket path to use (defaults to QUICKTERM_SOCKET)"),
        ControlArgSpec("help", .bool, help: "help (every subcommand's help ends with EXAMPLES)"),
        ControlArgSpec("dry-run", .bool, help: "report what would change and change nothing (mutating commands only)"),
        ControlArgSpec("fail-if-noop", .bool, help: "exit 7 when already in the requested state instead of succeeding silently"),
        ControlArgSpec("start", .bool,
                       help: "launch QuickTerm first if it is not running, then wait (up to 10s)"),
    ]

    /// The keys of the two global flags every mutating command accepts (the server branches on
    /// them).
    enum Flag {
        static let dryRun = "dry-run"
        static let failIfNoop = "fail-if-noop"
        static let force = "force"
    }

    // MARK: Safety classes for WMAction

    /// These open an overlay panel or a pop-up menu that then needs arrow keys and Return to finish
    /// — **running one over the socket means leaving the UI stuck halfway**.
    /// `web-extensions` is in the set too: `NSMenu.popUp` runs an event-tracking loop that wedges
    /// the main thread and the control service along with it (worse than the other 5: it does not
    /// even hint that the user should press Esc).
    /// The replacement path for these actions is Phase 2's `app set theme ...` / `app set
    /// background ...`.
    static let interactiveActions: Set<WMAction> = [
        .themePicker, .backgroundMenu, .keybindingHelp, .mainMenu, .openSettings, .webExtensions,
    ]

    /// Actions that destroy something of the user's: closing a pane ends the processes inside it.
    static let destructiveActions: Set<WMAction> = [.closePane]

    static func actionClass(_ action: WMAction) -> ControlCommandClass {
        if interactiveActions.contains(action) { return .interactive }
        if destructiveActions.contains(action) { return .destructive }
        return .mutate
    }

    /// The concrete alternative offered when the socket refuses that action.
    static func interactiveHint(_ action: WMAction) -> String {
        switch action {
        case .themePicker: "The theme picker is driven by the keyboard. Use app set theme instead, or write theme in ~/.config/quickterm/config.toml."
        case .backgroundMenu: "The background picker is driven by the keyboard. Use app set background instead."
        case .keybindingHelp, .mainMenu: "This is an overlay panel for humans. The machine-readable list is in quickterm describe --json."
        case .openSettings: "It launches an external editor. Edit ~/.config/quickterm/config.toml directly instead."
        case .webExtensions: "It pops up an NSMenu and holds the main thread. Manage extensions inside QuickTerm itself."
        default: "This action needs keyboard interaction and cannot be run over the socket."
        }
    }

    struct ActionDoc: Codable, Equatable {
        var name: String
        var cls: ControlCommandClass
        var helpZH: String
        /// The English text. **The Chinese and English copies sit side by side**: describe's output
        /// gets pasted verbatim into agent prompts that mix the two languages.
        var helpEN: String
        var browserOnly: Bool
        var terminalOnly: Bool
        var workspace: Int?
        var hint: String?
    }

    /// The machine-readable list of every WMAction (one source shared by `describe` and
    /// `action --list`; `ControlActionTests` pins it one-to-one against `WMAction.allCases`).
    static var actionDocs: [ActionDoc] {
        WMAction.allCases.map { action in
            let cls = actionClass(action)
            return ActionDoc(
                name: action.rawValue,
                cls: cls,
                helpZH: action.help,
                helpEN: action.helpEN,
                browserOnly: action.browserOnly,
                terminalOnly: action.terminalOnly,
                workspace: action.workspaceIndex.map { $0 + 1 },
                hint: cls == .interactive ? interactiveHint(action) : nil)
        }
    }

    // MARK: Output samples (embedded in `--help`; `ControlWireTests` parses every one of them back)

    static let stateSample = """
    {"ok":true,"seq":412,"data":{
      "schema":"quickterm.state/1",
      "app":{"version":"1.5.8","protocol":1,"workspaceCount":5},
      "screens":[{"index":1,"id":"3F2A9C…","title":"QuickTerm","key":true,"activeWorkspace":2,
        "visibleColumns":2,"fullscreen":false,
        "workspaces":[{"index":1,"layout":"scrolling","empty":true,"panes":[]},
                      {"index":2,"title":"dev","layout":"scrolling","empty":false,"panes":["t1","t2"],
                       "columns":[{"width":0.485,"panes":["t1"]},{"width":0.485,"panes":["t2"]}]},
                      {"index":3,"layout":"dwindle","empty":false,"panes":["t8","b3"],
                       "tree":{"split":"vertical","ratio":0.62,
                               "a":{"pane":"t8"},"b":{"pane":"b3"}}}]}],
      "panes":[{"handle":"t1","id":"9C1B4E…","kind":"terminal","role":"shell","screen":1,
                "workspace":2,"at":{"column":0,"row":0},
                "size":{"rect":[0,0,0.485,1],"points":[776,900],"cols":96,"rows":48,
                        "width":0.485,"share":1},
                "title":"nvim  ~/proj",
                "cwd":"/Users/danny/proj","focused":true,"busy":true,"float":false,"zoom":false},
               {"handle":"b3","id":"41EE07…","kind":"browser","screen":1,"workspace":2,
                "title":"<redacted>","url":"<redacted>","tabs":2,"focused":false}]}}
    """

    /// The echo from `pane resize`: the diff paths have the same shape as the JSON in `state`
    /// (`1:2.tree.a.ratio`).
    static let resizeSample = """
    {"ok":true,"seq":418,"resolved":{"screen":1,"workspace":3,"pane":"t8"},
     "data":{"command":"pane.resize","applied":true,"changed":true,"dryRun":false,
       "changes":[{"path":"1:3.tree.ratio","from":"0.620","to":"0.700"}],
       "pane":{"handle":"t8","size":{"rect":[0,0,1,0.7],"points":[1552,630],"cols":192,"rows":33,
                                     "split":"vertical","ratio":0.7}},
       "undo":"Control plane: pane resize"}}
    """

    static let listSample = """
    {"ok":true,"seq":412,"data":{"panes":[
      {"handle":"t1","kind":"terminal","screen":1,"workspace":2,"title":"zsh","focused":true},
      {"handle":"b3","kind":"browser","screen":1,"workspace":2,"title":"<redacted>"}]}}
    """

    /// The single envelope for mutating commands (under `--dry-run`, `applied:false` and `changes`
    /// is the diff).
    static let paneMutationSample = """
    {"ok":true,"seq":415,"resolved":{"screen":1,"workspace":2,"pane":"t9"},
     "data":{"command":"pane.new","applied":true,"changed":true,"dryRun":false,
       "changes":[{"path":"1:2","from":"2 panes","to":"3 panes"}],
       "pane":{"handle":"t9","id":"C40D…","kind":"terminal","role":"shell","screen":1,
               "workspace":2,"at":{"column":2,"row":0},"cwd":"/Users/danny/proj"},
       "focusPending":true,"undo":"Control plane: pane new"}}
    """

    static let appGetSample = """
    {"ok":true,"seq":412,"data":{"settings":[
      {"key":"theme","value":"tokyo-night","choices":["tokyo-night","gruvbox","…"]},
      {"key":"gaps","value":"on","choices":["on","off"]},
      {"key":"visible-columns","value":"2","choices":["1","2","3","4","5","6"]}]}}
    """

    /// What `spec dump` prints **is this document itself** (no response envelope around it):
    /// `quickterm spec dump > w.json` has to feed straight back into `spec apply -f w.json`.
    static let specSample = """
    {"schema":"quickterm.workspace/1","layout":"scrolling","visibleColumns":3,
     "columns":[
       {"width":0.33,"panes":[{"kind":"terminal","cwd":"/Users/danny/proj"}]},
       {"width":0.33,"panes":[{"kind":"terminal","cwd":"/Users/danny/proj"},
                              {"kind":"terminal","cwd":"/Users/danny/proj/www"}]},
       {"width":0.33,"panes":[{"kind":"browser","url":"http://localhost:3000"}]}],
     "focus":{"column":0,"row":0}}
    """

    /// The dwindle form (the same vocabulary) — printed by both the `spec` group's help and
    /// describe.
    static let specTreeSample = """
    {"schema":"quickterm.workspace/1","layout":"dwindle",
     "tree":{"split":"horizontal","ratio":0.6,
             "a":{"pane":{"cwd":"~/proj"}},
             "b":{"split":"vertical","ratio":0.5,
                  "a":{"pane":{"cmd":"htop","hold":true}},
                  "b":{"pane":{"kind":"browser","url":"http://localhost:3000"}}}},
     "focus":{"path":"b.a"}}
    """

    static let specApplySample = """
    {"ok":true,"seq":418,"resolved":{"screen":1,"workspace":2,"pane":"t9"},
     "data":{"command":"spec.apply","applied":true,"changed":true,"dryRun":false,
       "changes":[{"path":"1:2.panes","from":"2 panes","to":"4 panes (created 3, closed 1, reused 1)"}],
       "spec":{"mode":"reuse","scope":"workspace","created":["t9","t10","b4"],
               "reused":["t3"],"closed":["t4"]}}}
    """

    /// One batch from `events poll` / `events follow`. `data.seq` is **the value the next `--since`
    /// should be given** (when `--limit` truncated the batch it only advances to the last event
    /// actually shipped, and `truncated:true` comes along with it).
    static let eventsSample = """
    {"ok":true,"seq":420,"data":{"schema":"quickterm.events/1","seq":420,"oldest":301,
     "events":[
      {"seq":418,"ts":"2026-09-10T09:12:03.221Z","type":"pane.opened","pane":"t9","paneID":"C40D…",
       "kind":"terminal","screen":1,"workspace":2,"cwd":"/Users/danny/proj"},
      {"seq":419,"ts":"2026-09-10T09:12:03.402Z","type":"focus.changed","pane":"t9","screen":1,"workspace":2},
      {"seq":420,"ts":"2026-09-10T09:12:07.118Z","type":"layout.changed","screen":1,"workspace":2,
       "layout":"dwindle"}]}}
    """

    static let sendTextSample = """
    {"ok":true,"seq":421,"resolved":{"screen":1,"workspace":2,"pane":"t7"},
     "data":{"command":"input.send-text","applied":true,"changed":true,"dryRun":false,
       "changes":[{"path":"1:2.t7","from":"(keyboard input)","to":"12 characters + Return"}],
       "pane":{"handle":"t7","kind":"terminal","screen":1,"workspace":2}}}
    """

    /// The echo from `pane capture-text`. **`text` appears here exactly once**: never in a log,
    /// never in the event stream.
    static let captureTextSample = """
    {"ok":true,"seq":430,"resolved":{"screen":1,"workspace":2,"pane":"t7"},
     "data":{"command":"pane.capture-text","cols":96,"rows":24,"lines":3,"scrollback":0,
       "pane":{"handle":"t7","kind":"terminal","screen":1,"workspace":2},
       "text":"~/proj $ npm test\\n  12 passing\\n~/proj $ "}}
    """

    /// The echo from the browser-tab commands: `pane.tabList` is exactly what the next `--tab`
    /// should be written from.
    static let browserSample = """
    {"ok":true,"seq":432,"resolved":{"screen":1,"workspace":2,"pane":"b3"},
     "data":{"command":"browser.open","applied":true,"changed":true,"dryRun":false,
       "changes":[{"path":"1:2.b3.tabs","from":"2 tabs","to":"3 tabs"}],
       "pane":{"handle":"b3","kind":"browser","screen":1,"workspace":2,"tabs":3,
         "tabList":[{"index":1,"id":"8A1F…","active":false,"title":"QuickTerm","url":"https://…"},
                    {"index":2,"id":"C40D…","active":false,"title":"docs","url":"https://…"},
                    {"index":3,"id":"F17B…","active":true,"title":"","url":"http://localhost:3000",
                     "loading":true}]}}}
    """

    static let getSample = """
    {"ok":true,"seq":412,"resolved":{"screen":1,"workspace":2,"pane":"t7"},
     "data":{"pane":{"handle":"t7","id":"C40D…","kind":"terminal","role":"shell",
       "screen":1,"workspace":2,"at":{"column":2,"row":0},
       "size":{"rect":[0.97,0,0.485,1],"points":[776,900],"cols":96,"rows":48,
               "width":0.485,"share":1},
       "title":"npm run dev",
       "cwd":"/Users/danny/proj","focused":false,"busy":true,"float":false,"zoom":false}}}
    """
}

/// The settings `app get` / `app set` accept. **The enum is the list**: the command table's values,
/// describe, and the server's switch all come from here, so an entry that exists in the help but
/// not in the implementation is impossible.
enum ControlAppSetting: String, Codable, CaseIterable {
    case theme
    case background
    case gaps
    case opacity
    case bar
    case visibleColumns = "visible-columns"

    var help: String {
        switch self {
        case .theme: "color theme name (app get theme lists every choice)"
        case .background: "wallpaper: a name, a 1-based index, or none"
        case .gaps: "gaps between panes on|off"
        case .opacity: "transparency / blur on|off"
        case .bar: "top status bar on|off (per screen; name it with -t)"
        case .visibleColumns: "columns visible per screen in scrolling 1–6 (per screen; name it with -t)"
        }
    }

    /// Applies to one particular screen (the rest are process-level).
    var isPerScreen: Bool { self == .bar || self == .visibleColumns }
}
