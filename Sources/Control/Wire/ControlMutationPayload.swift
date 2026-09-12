import Foundation

/// The **single response envelope** for the Phase 2 noun-verb layer.
///
/// It settles three things at once and saves the agent a second round trip:
/// 1. `changed` — was there anything to change at all (the essence of absolute set-value semantics:
///    the second call does nothing);
/// 2. `applied` — did it actually change (always false under `--dry-run`, where `changes` is the
///    diff);
/// 3. the entity after the change (pane / workspace / screen) — which closes the read-after-write
///    window.
///
/// **Pure Foundation**: this directory is compiled into both the app and the `quickterm` tool
/// target.
struct ControlMutationPayload: Codable, Equatable {
    /// The command name as it appears on the wire (`pane.new`).
    var command: String
    /// It really landed in the UI (always false under dry-run).
    var applied: Bool
    /// There was something to change (false = already in the target state; under `--fail-if-noop`
    /// that turns into exit code 7).
    var changed: Bool
    var dryRun: Bool
    /// The diff, entry by entry: under `--dry-run` this is the whole of "what would change".
    var changes: [ControlChange]
    var pane: ControlStatePayload.PaneInfo?
    /// When one command touched several panes (workspace clear).
    var panes: [ControlStatePayload.PaneInfo]?
    var workspace: ControlStatePayload.WorkspaceInfo?
    var screen: ControlStatePayload.ScreenInfo?
    /// Focus handover is retried asynchronously (0.75s at most), so on return it may not have
    /// landed on `resolved.pane` yet.
    var focusPending: Bool?
    /// QuickTerm put up its own "a process is still running" confirmation and is waiting for the
    /// user to answer (the pane is not closed yet).
    var confirmPending: Bool?
    /// The name of the undo entry registered with `AppDelegate.undoManager` (present = this step
    /// can be undone).
    var undo: String?
    /// An extra fact the caller needs to know (for example, "this lands via the config.toml
    /// watcher, so it takes effect shortly").
    var note: String?
    /// The apply report for `spec apply` (which panes were created, kept, or closed).
    var spec: ControlSpecApplyReport?
    /// **The command succeeded, but there is something the caller has to know** (see
    /// `ControlWarning`).
    /// The one that matters most: an explicit `--cwd` was blocked by macOS privacy authorization
    /// and the shell started somewhere else — reporting a bland success and swallowing that is
    /// exactly where undiagnosable "the pane opened but the directory never changed" failures come
    /// from.
    var warnings: [ControlWarning]?

    init(command: String, applied: Bool, changed: Bool, dryRun: Bool,
         changes: [ControlChange] = [], pane: ControlStatePayload.PaneInfo? = nil,
         panes: [ControlStatePayload.PaneInfo]? = nil,
         workspace: ControlStatePayload.WorkspaceInfo? = nil,
         screen: ControlStatePayload.ScreenInfo? = nil,
         focusPending: Bool? = nil, confirmPending: Bool? = nil,
         undo: String? = nil, note: String? = nil, spec: ControlSpecApplyReport? = nil,
         warnings: [ControlWarning]? = nil) {
        self.command = command
        self.applied = applied
        self.changed = changed
        self.dryRun = dryRun
        self.changes = changes
        self.pane = pane
        self.panes = panes
        self.workspace = workspace
        self.screen = screen
        self.focusPending = focusPending
        self.confirmPending = confirmPending
        self.undo = undo
        self.note = note
        self.spec = spec
        self.warnings = warnings
    }
}

/// One "it worked, but you need to know this" warning.
///
/// Why it is not an error: the command **did** land (the pane opened, the spec was laid out), and
/// turning it into a failure would break every script that does not care about this.
/// Why it cannot just go into `note`: `note` is prose for a human, while callers need to branch on
/// `code` (`cwd_denied` is a stable string; the prose is not).
///
/// There is one code so far: `cwd_denied` — the explicitly given working directory falls inside a
/// macOS protected directory (~/Desktop ~/Documents ~/Downloads) that this binary has no
/// authorization for, `WorkingDirectoryGate` blocked it, and the shell started in the engine's
/// default directory. A script that wants this to be a hard error passes `--require-cwd`.
struct ControlWarning: Codable, Equatable {
    /// The stable machine code: **branch on this, never match on the message**.
    var code: String
    var message: String
    var hint: String?
    /// The path the caller asked for.
    var path: String?
    /// The one actually used (omitted when we do not know it — the engine decides its own default
    /// directory).
    var used: String?

    init(code: String, message: String, hint: String? = nil,
         path: String? = nil, used: String? = nil) {
        self.code = code
        self.message = message
        self.hint = hint
        self.path = path
        self.used = used
    }

    static let cwdDenied = "cwd_denied"

    /// The warning for a `--cwd` blocked by the privacy gate (`pane new` and `spec apply` share
    /// this one piece of wording — written out twice, only one copy would ever get updated).
    static func cwdDenied(_ path: String, used: String?) -> ControlWarning {
        ControlWarning(
            code: cwdDenied,
            message: "Working directory \(path) could not be used: macOS counts it as a protected directory and "
                + "QuickTerm has not been granted Files and Folders access, so the shell started in the "
                + "default directory",
            hint: "Tick QuickTerm's entry under System Settings ▸ Privacy & Security ▸ Files and Folders and "
                + "restart it. Add --require-cwd to make this case fail outright instead.",
            path: path, used: used)
    }
}

/// The two limits on `pane capture-text`.
///
/// The line limit is not there to save CPU: stuffing the entire history (the engine keeps tens of
/// thousands of lines by default) into one JSON response eats an agent's whole context in a single
/// call, when what it actually wants is usually the last few dozen lines.
/// The byte limit is the last gate — a single line can run to several KB (`cat` a binary file).
enum ControlCaptureLimits {
    /// The ceiling on `--scrollback`.
    static let maxScrollback = 5000
    /// How many bytes of text one call returns at most (over the limit we cut from the **front**:
    /// the most recent output is always kept).
    static let maxBytes = 256 * 1024
}

/// The payload for `pane capture-text`. **`text` appears exactly once, in this response**: never in
/// the activity log, never in the event stream, never in any record that is kept (see
/// `ControlCaptureCommands`).
struct ControlCaptureTextPayload: Codable, Equatable {
    var command: String
    /// Which pane was read (the same pane record used everywhere else).
    var pane: ControlStatePayload.PaneInfo
    /// The grid the engine measured (`cols` × `rows`) — this is how the caller knows where the text
    /// was wrapped.
    var cols: Int?
    var rows: Int?
    /// How many lines actually came back.
    var lines: Int
    /// How many of those lines come from history **above** the visible area (the stretch
    /// `--scrollback N` asked for).
    var scrollback: Int
    /// Hit a length limit and was truncated (cut from the **front**: the most recent output is
    /// always kept).
    var truncated: Bool?
    /// The plain text of the visible area (plus the optional stretch of history), lines separated
    /// by \n, trailing whitespace stripped.
    var text: String

    init(command: String, pane: ControlStatePayload.PaneInfo, cols: Int? = nil, rows: Int? = nil,
         lines: Int, scrollback: Int, truncated: Bool? = nil, text: String) {
        self.command = command
        self.pane = pane
        self.cols = cols
        self.rows = rows
        self.lines = lines
        self.scrollback = scrollback
        self.truncated = truncated
        self.text = text
    }
}

/// One diff entry. `path` is written in the same shape as the addressing syntax (`1:2.t7.zoom`), so
/// the diff an agent reads and the target it writes in its next command are the same vocabulary.
struct ControlChange: Codable, Equatable {
    var path: String
    var from: String?
    var to: String?
    /// For this entry the **value itself** is private: page titles and URLs, terminal titles (which
    /// permanently carry the cwd or the command line currently running).
    ///
    /// The response still carries it — that side already redacts by token (`browserVisible`), and
    /// it goes to this one caller only. But `ControlActivityLog` mirrors every change into OSLog,
    /// and that log lands in /var/db/diagnostics: any administrator can read it, sysdiagnose
    /// packages it up and carries it off, and it outlives the app. A field that is redacted by
    /// default, written verbatim into a long-lived public log, means the redaction never happened.
    /// Hence: a change carrying this flag is logged with its `path` only.
    ///
    /// **Not on the wire** (not in CodingKeys): it is a local handling rule, not data we send back
    /// to the caller.
    var sensitive: Bool = false

    init(_ path: String, from: String?, to: String?, sensitive: Bool = false) {
        self.path = path
        self.from = from
        self.to = to
        self.sensitive = sensitive
    }

    /// The one way a diff writes "count + unit": `1 pane` / `3 panes`.
    /// The Chinese these strings were first written in has no plural form, so translating them
    /// across straight would have written "1 panes" for every count.
    static func count(_ n: Int, _ noun: String) -> String { "\(n) \(noun)\(n == 1 ? "" : "s")" }

    private enum CodingKeys: String, CodingKey { case path, from, to }
}

/// The payload for `app get`: every entry carries its allowed values, so an agent never has to
/// guess what a valid input looks like.
struct ControlAppPayload: Codable, Equatable {
    var settings: [Setting]

    struct Setting: Codable, Equatable {
        var key: String
        var value: String
        var choices: [String]?
        var scope: String     // "app" | "screen"
        var help: String
    }
}
