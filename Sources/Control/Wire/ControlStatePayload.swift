import Foundation

/// The payload shape for `state` / `list` / `get` (`quickterm.state/1`).
/// A flat pane array (wezterm's shape: easy for jq and for a model to read) plus a workspace
/// skeleton that **only references handles**, rather than repeating the pane records a second time
/// — the JSON for a six-screen session would otherwise eat an agent's whole context.
struct ControlStatePayload: Codable, Equatable {
    var schema = "quickterm.state/1"
    var app: AppInfo
    var screens: [ScreenInfo]
    var panes: [PaneInfo]

    struct AppInfo: Codable, Equatable {
        var version: String
        var protocolVersion: Int
        var workspaceCount: Int
        var mode: String
        /// Whether this request carried a valid origin token (which decides whether browser URLs
        /// and titles are redacted).
        var trusted: Bool
    }

    struct ScreenInfo: Codable, Equatable {
        var index: Int
        var id: String
        var title: String
        var key: Bool
        var activeWorkspace: Int
        var visibleColumns: Int
        var fullscreen: Bool
        var joinAllSpaces: Bool
        var display: DisplayInfo?
        var frame: [Double]?
        var workspaces: [WorkspaceInfo]
    }

    struct DisplayInfo: Codable, Equatable {
        var uuid: String?
        var name: String?
    }

    struct WorkspaceInfo: Codable, Equatable {
        var index: Int
        /// The name of this slot (set from the right-click pill or by `workspace set --title`; if
        /// it was never named, the field is absent entirely).
        /// **Never redacted**: same rule as pane titles — this is text the user wrote themselves,
        /// not something a web page supplied.
        var title: String?
        var layout: String
        var empty: Bool
        var active: Bool
        /// The pane handles in this workspace (order = layout order).
        var panes: [String]
        var zoom: String?
        /// scrolling: per column, a width factor plus the handles inside that column.
        var columns: [ColumnInfo]?
        /// dwindle: the split tree (`{split,ratio,a,b}`, with leaves `{pane:"t1"}`).
        var tree: TreeNode?
        var floating: [String]
        /// How many **panes** in this workspace are waiting for the user (a live `needs-user`
        /// notice), which is what the red `●N` on the workspace pill counts.
        ///
        /// Panes, not notices: two approval prompts in one pane are one thing for the human to go
        /// and handle. Encoded only when non-zero, the same convention `zoom` / `titleSet` follow,
        /// so every existing fixture stays byte-identical.
        var needsUser: Int? = nil
    }

    struct ColumnInfo: Codable, Equatable {
        var width: Double
        var panes: [String]
    }

    /// The skeleton of a dwindle workspace. **The same vocabulary as `spec dump`'s `tree`**
    /// (`split` / `ratio` / `a` / `b`), except the leaves hold handles rather than whole pane
    /// records (those live once in the flat `panes[]`, never repeated here).
    /// This used to be a flat list of `{pane,path}`: you could read the shape but **not the
    /// ratios** — an agent could drag a divider yet never see where it had dragged it to, so it was
    /// tuning blind.
    /// Nothing about paths was lost: the nesting of `a`/`b` is itself the path (`a.b` = left, then
    /// right), and each pane's `at.path` still spells that string out.
    indirect enum TreeNode: Codable, Equatable {
        /// A leaf: one pane handle.
        case leaf(String)
        case split(Split)

        struct Split: Equatable {
            /// `horizontal` = a on the left, b on the right; `vertical` = a on top, b below.
            var split: String
            /// The fraction of the space the `a` side takes (0-1).
            var ratio: Double
            var a: TreeNode
            var b: TreeNode
        }

        private enum CodingKeys: String, CodingKey { case pane, split, ratio, a, b }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            if c.contains(.a) || c.contains(.b) {
                self = .split(Split(split: try c.decode(String.self, forKey: .split),
                                    ratio: try c.decode(Double.self, forKey: .ratio),
                                    a: try c.decode(TreeNode.self, forKey: .a),
                                    b: try c.decode(TreeNode.self, forKey: .b)))
                return
            }
            self = .leaf(try c.decode(String.self, forKey: .pane))
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .leaf(let handle):
                try c.encode(handle, forKey: .pane)
            case .split(let split):
                try c.encode(split.split, forKey: .split)
                try c.encode(split.ratio, forKey: .ratio)
                try c.encode(split.a, forKey: .a)
                try c.encode(split.b, forKey: .b)
            }
        }

        /// The leaf handles, in layout order.
        var handles: [String] {
            switch self {
            case .leaf(let handle): [handle]
            case .split(let split): split.a.handles + split.b.handles
            }
        }
    }

    struct PaneInfo: Codable, Equatable {
        var handle: String
        var id: String
        var kind: String
        var role: String?
        var screen: Int
        var workspace: Int
        var at: Position?
        /// How big this pane is (see `PaneSize`). Given for both floating and tiled panes.
        var size: PaneSize? = nil
        var title: String?
        /// The title is **pinned**: somebody took it over (`pane set --title`, or "Change Terminal
        /// Title" from the context menu) and the shell can no longer change it. Encoded only when
        /// true, the same convention `redacted` follows - absent means "this is whatever the shell
        /// last reported".
        ///
        /// Without this field `state` cannot answer a question three separate rules depend on:
        /// the border only draws a pinned title, `pane set --title` decides "changed or no-op" on
        /// "has it been taken over" rather than on the string, and the advice to address panes by
        /// `title:~` is only sound for a title the shell cannot pull out from under you. Reading
        /// back a `title` told you none of that.
        /// A browser pane never has one: its title belongs to the page, nobody named it.
        var titleSet: Bool? = nil
        var cwd: String?
        var url: String?
        /// The **number** of tabs in a browser pane (the shape never varies: always an integer).
        var tabs: Int?
        /// Per-tab detail for a browser pane (order = tab order).
        /// **The redaction rule is word for word the same as for the pane-level url / title**: a
        /// caller without a token gets index / id / active (needed for addressing) and no title or
        /// URL at all — otherwise "redacted at the pane level, copied verbatim at the tab level" is
        /// the same leak under a different field name.
        var tabList: [TabInfo]? = nil
        var focused: Bool
        var busy: Bool
        var float: Bool
        var zoom: Bool
        /// Whether a browser pane's title / url were redacted (always, for a caller with no token).
        var redacted: Bool?
        /// The notices **live on this pane right now** (post order), or nil when it has none.
        ///
        /// Encoded only when there is something to say, so a session with nothing pending returns
        /// exactly the bytes it always did. `notices | length` is the live count; each record's
        /// `body` follows the same token rule as a browser URL (see `ControlNoticeRecord`).
        var notices: [ControlNoticeRecord]? = nil
        /// The pane's **displayed** urgency: the maximum over its live notices (`info` |
        /// `needs-user`), absent when nothing is live.
        var urgency: String? = nil
        /// This pane is waiting for a human (it holds at least one live `needs-user` notice).
        /// Encoded only when true. It is `urgency == "needs-user"` said in one boolean, because
        /// that is the single question an agent asks before interrupting the user — and a jq
        /// filter on a bool is harder to get wrong than one on a string.
        var needsUser: Bool? = nil
        /// What the AI agent running in this pane is doing, when QuickTerm recognises one
        /// (Phase 2). Encoded only when there is a status, so a session with no agents in it
        /// returns exactly the bytes it always did.
        var agent: ControlAgentRecord? = nil

        struct Position: Codable, Equatable {
            var column: Int?
            var row: Int?
            var path: String?
        }

        /// One tab inside a browser pane. **`index` and `id` are exactly the two forms `--tab`
        /// accepts**: the index is for humans (1-based, matching the tab bar, and it shifts
        /// whenever tabs are opened or closed), while the id is stable (unchanged for as long as
        /// the tab lives, and `--tab #<prefix>` takes it) — an agent that does `get` and then
        /// `--tab #id` cannot land on a different page just because someone opened a tab in
        /// between.
        struct TabInfo: Codable, Equatable {
            /// The 1-based index (= the tab bar, left to right).
            var index: Int
            /// The stable tab id (`--tab #<uuid, or a prefix of ≥4>`).
            var id: String
            /// The current tab (what `--tab @active` names).
            var active: Bool
            /// Title / URL: a caller with no token reads `<redacted>` here.
            var title: String?
            var url: String?
            /// Currently loading.
            var loading: Bool?
        }

        /// The geometry of a pane. **The model is the source of truth**: `rect` is computed
        /// straight from dwindle's ratio or scrolling's column width factor, by the same formula
        /// the renderer uses; `points` / `cols` / `rows` are best-effort — a pane detaches from the
        /// window while SwiftUI rebuilds it, and in that instant there is no frame to read.
        /// Reporting nil beats reporting a stale number from the previous frame (reading a size
        /// must never wait a frame, and must certainly never crash).
        struct PaneSize: Codable, Equatable {
            /// The normalized rect `[x, y, w, h]` within the workspace content area, **origin at
            /// the top left** (the same orientation as the renderer).
            /// For scrolling, the horizontal unit is "one viewport width": when the strip
            /// overflows, `x + w` goes above 1, and that excess is exactly the part you have to
            /// scroll to see.
            var rect: [Double]
            /// This pane's **slot** size in points `[w, h]`, measured against the workspace layout
            /// area (contentView minus the top status bar and the outer padding, = the region
            /// `SplitView` measures).
            /// Inside that slot there is still a ring of PaneChrome padding plus the terminal's
            /// pane-padding, so the terminal canvas is smaller — for the grid read `cols`/`rows`
            /// (measured by the engine); do not divide points by a character width.
            /// Omitted when the window is not attached, or when this pane is covered by a zoom (see
            /// `hidden`).
            var points: [Double]?
            /// Terminal grid columns / rows (present only for a terminal pane, and only once the
            /// engine has measured it).
            var cols: Int?
            var rows: Int?
            /// dwindle: the direction and ratio of the nearest parent split (a lone leaf at the
            /// root of the tree has no parent split).
            var split: String?
            var ratio: Double?
            /// scrolling: the width factor of the column this pane is in.
            var width: Double?
            /// scrolling: the share this pane takes within its column (an evenly split column gives
            /// 1 / the number of panes in it).
            var share: Double?
            /// Some pane in this workspace is zoomed and it is not this one: **this pane is not on
            /// the screen right now**.
            /// `rect` / `ratio` / `width` still describe the tiled layer underneath (that is what
            /// `pane resize` adjusts, and what cancelling the zoom returns to), but `points` is
            /// withheld entirely in this state.
            var hidden: Bool?
        }

        /// The implementation of `--fields handle,cwd,title`: project into a JSON object (still via
        /// JSONEncoder).
        func projected(to fields: [String]) throws -> JSONValue {
            let data = try ControlJSON.encoder.encode(self)
            let value = try ControlJSON.decoder.decode(JSONValue.self, from: data)
            guard let object = value.objectValue else { return value }
            var out: [String: JSONValue] = [:]
            for field in fields {
                if let v = object[field] { out[field] = v }
            }
            // handle is always kept, otherwise the result cannot be addressed afterwards
            if out["handle"] == nil, let h = object["handle"] { out["handle"] = h }
            return .object(out)
        }
    }
}

/// One notice on the wire (`quickterm.notices/1`, and the `notices[]` of a pane record).
///
/// It is a flat record of strings on purpose: this directory is compiled into the `quickterm` tool
/// as well, which knows nothing of `Notice` / `NoticeCenter` (those live in the app). The mapping
/// lives in `ControlStateEncoder.noticeRecord(_:)`, in one place, so the two spellings of a source
/// or a resolution cannot drift apart.
///
/// **Title and body are two fields with two rules** (spec §3.5). The title is payload-free by
/// construction — the notification centre builds it from an agent id, a state and a tool *name* —
/// so it is never redacted. The body carries the program's own words (an OSC 777 body, a summary of
/// a tool's input) and follows exactly the rule a browser URL follows: a caller that did not
/// inherit `QUICKTERM_TOKEN` reads `<redacted>` and `redacted: true`, never the text.
struct ControlNoticeRecord: Codable, Equatable {
    var id: String
    /// The pane's short handle (`t7`). Empty only for a pane that never got one, which cannot
    /// happen for a pane that was addressable when the notice was posted.
    var pane: String
    var paneID: String
    /// One-based, as everywhere on the wire. `0` means that screen is gone — only reachable
    /// through `--history`, where the record outlives the window it was posted on.
    var screen: Int
    var screenID: String
    /// One-based, **as it was when the notice was posted** (a pane moved while an approval is
    /// pending keeps the count where the alarm was raised; see `NoticeCenter.recomputeCounts`).
    var workspace: Int
    /// `NoticeSource.id`: `agent:<id>` | `terminal` | `command` | `bell` | `download` | `control` |
    /// `custom:<name>`. Stable — branch on it.
    var source: String
    /// `info` | `needs-user`.
    var urgency: String
    /// `hook` | `report` | `notification` | `process` | `composed` — where the text came from.
    /// `composed` is the only one that means QuickTerm wrote the sentence itself.
    var evidence: String
    var title: String
    /// The program's own words, `<redacted>` for a caller with no token, absent when the notice
    /// has no body at all.
    var body: String?
    /// A body exists and was withheld (say so, or the caller believes the body really reads
    /// `<redacted>`).
    var redacted: Bool?
    /// ISO8601 with milliseconds, the same stamp the event stream uses.
    var postedAt: String
    /// The user focused this pane and typed into it while the alarm was still live, so the
    /// **interrupting** sinks (the banner, the Dock badge) let go of it — the pane mark, the
    /// workspace count and this record stay until the agent or its process confirms (plan §2.8,
    /// owner decision Q1(b)). Absent means nothing has been quieted. A quieted notice is still
    /// live: `notices list --needs-user` keeps listing it, and `notices ack` still resolves it.
    var quietedAt: String? = nil
    /// Set only on a resolved notice (`notices list --history`).
    var resolvedAt: String?
    /// `state-changed` | `user-acted` | `acknowledged` | `superseded` | `pane-focused` |
    /// `pane-closed`.
    var resolution: String?
}

/// One notice that is about QuickTerm itself rather than about a pane (`AppNotice` on the app
/// side): no pane, no screen, no workspace, no resolution. Today exactly one thing posts one —
/// "macOS has notifications switched off for QuickTerm".
///
/// A separate record rather than a `ControlNoticeRecord` with empty strings in `pane` / `paneID`:
/// an agent filtering `notices[]` by pane would otherwise have to know that `""` is a real value,
/// and the first one that forgets follows a handle that does not exist.
struct ControlAppNoticeRecord: Codable, Equatable {
    var id: String
    /// `NoticeSource.id` — `custom:system` for the notification-permission hint.
    var source: String
    /// `info` | `needs-user`.
    var urgency: String
    var evidence: String
    /// Composed by QuickTerm, so never redacted — same rule as a pane notice's title.
    var title: String
    var body: String?
    var postedAt: String
}

/// The payload for `notices list`.
struct ControlNoticesPayload: Codable, Equatable {
    var schema = "quickterm.notices/1"
    /// Live notices first (post order), then the resolved ring (oldest first) when `--history`
    /// asked for it. `resolvedAt` tells the two apart without counting.
    var notices: [ControlNoticeRecord]
    /// **How many panes** (not notices) are waiting for a human, within whatever the target
    /// scoped this call to. This is the number an agent branches on before interrupting the user.
    var panesNeedingUser: Int
    /// **Whether macOS will show QuickTerm's banners at all**: `authorized` | `denied` |
    /// `notDetermined` | `unavailable`.
    ///
    /// Always present, and deliberately not scoped by `-t`: it is a property of the app, not of a
    /// pane. `denied` means every banner this launch posts is thrown away by macOS — the pane mark,
    /// the workspace count and this very list still work, so an agent that reads `denied` knows the
    /// human will not be pulled out of another app and can say so instead of assuming they were
    /// told. `unavailable` means we could not ask; it is not a denial.
    ///
    /// Spelled by `SystemNotificationStatus.rawValue` on the app side, which is the only writer;
    /// the default here is the value that is true before anybody has managed to ask.
    var systemNotifications: String = "unavailable"
    /// Notices about the app itself, when there are any. Absent (not `[]`) when there are none, so
    /// a session with nothing to say encodes exactly the bytes it always did.
    var appNotices: [ControlAppNoticeRecord]? = nil
}

/// **What one pane's agent is doing** — the record `agents list`, `state` and `get` all share.
///
/// A flat record of strings, like `ControlNoticeRecord` and for the same reason: this directory
/// is compiled into the `quickterm` tool, which knows nothing of `AgentStatus`. The mapping
/// lives in one place on the app side, so the spellings of a state or an evidence cannot drift.
///
/// `message` is the agent's own words and follows the browser-URL rule exactly (a caller with no
/// `QUICKTERM_TOKEN` reads `<redacted>`); everything else — the agent id, the state, the tool
/// **name** — is payload-free and always readable, because deciding whether to interrupt the
/// user is precisely what this record exists for.
struct ControlAgentRecord: Codable, Equatable {
    /// The rule id (`claude-code` | `codex` | `gemini` | a user rule file's id).
    var id: String
    /// The display name from the rule file (`Claude Code`).
    var name: String
    /// `idle` | `working` | `blocked` | `done` | `error` | `unknown`. Stable — branch on it.
    var state: String
    /// What kind of working / blocked: `thinking` | `tool` | `approval` | `input` | `choice`.
    var detail: String?
    /// A tool **name** (`Bash`), never a command line.
    var tool: String?
    /// The agent's own words, `<redacted>` for a caller with no token, absent when there are none.
    var message: String?
    /// A message exists and was withheld.
    var redacted: Bool?
    /// `hook` | `report` | `notification` | `process` — how sure we are. A hook is the agent
    /// telling us; `process` means only that a process with that name is running in the pane.
    var evidence: String
    var sessionID: String?
    /// When the state last changed. ISO8601 with milliseconds, the same stamp events use.
    var since: String
    /// The pane is waiting for a human (`blocked` or `error`). Encoded only when true.
    var needsUser: Bool?
}

/// One row of `agents list`: the pane, where it is, and its agent.
struct ControlAgentListEntry: Codable, Equatable {
    var pane: String
    var paneID: String
    var screen: Int
    var screenID: String
    var workspace: Int
    var agent: ControlAgentRecord
}

/// The payload for `agents list`.
struct ControlAgentsPayload: Codable, Equatable {
    var schema = "quickterm.agents/1"
    /// One entry per pane that has an agent status, in pane order. A pane with no agent is not
    /// listed at all — "no agent here" is the absence of a row, never a row full of nils.
    var agents: [ControlAgentListEntry]
}

/// The hook script on disk, as `hooks status` reports it.
struct HookScriptStatus: Codable, Equatable {
    /// `~/.config/quickterm/hooks/quickterm-agent-state.sh`.
    var path: String
    var exists: Bool
    /// The path is a symlink. QuickTerm **refuses to install over one** rather than follow it:
    /// writing through a link means writing wherever somebody else pointed it.
    var isSymlink: Bool
    /// The `quickterm` binary baked into the script (it is never taken from the environment, so
    /// a project `.envrc` cannot choose which binary every prompt runs).
    var bakedBinary: String?
    var bakedBinaryExists: Bool
    /// The script is there, ours, and its baked binary exists.
    var ok: Bool

    init(path: String, exists: Bool, isSymlink: Bool = false, bakedBinary: String? = nil,
         bakedBinaryExists: Bool = false, ok: Bool = false) {
        self.path = path
        self.exists = exists
        self.isSymlink = isSymlink
        self.bakedBinary = bakedBinary
        self.bakedBinaryExists = bakedBinaryExists
        self.ok = ok
    }
}

/// One agent's hook installation, as `hooks status` reports it.
struct HookAgentStatus: Codable, Equatable {
    var id: String
    var name: String
    /// The agent's own user-level config file (`~/.claude/settings.json`), `~` already expanded.
    /// nil when this rule file declares no installer at all.
    var configPath: String?
    var configExists: Bool
    /// At least one entry carrying our marker is in that file.
    var installed: Bool
    /// The hook events we own in it, in file order.
    var entries: [String]
    /// `lifecycle` | `tools` | `mixed` — which tier those entries add up to; nil when none.
    var detail: String?
    /// Why this agent cannot be installed / what is wrong with what is there.
    var issue: String?

    init(id: String, name: String, configPath: String? = nil, configExists: Bool = false,
         installed: Bool = false, entries: [String] = [], detail: String? = nil,
         issue: String? = nil) {
        self.id = id
        self.name = name
        self.configPath = configPath
        self.configExists = configExists
        self.installed = installed
        self.entries = entries
        self.detail = detail
        self.issue = issue
    }
}

/// The payload for `hooks status`.
struct ControlHooksPayload: Codable, Equatable {
    var schema = "quickterm.hooks/1"
    var script: HookScriptStatus
    var agents: [HookAgentStatus]
}

/// The payload for `agent-event` — what the hook is told about the report it just made.
///
/// There is no mutation envelope here and no `seq` bump of its own: a report is not a mutation
/// of anything the user owns (plan §2.1). `seq` in the response moved **iff** the registry
/// emitted `agent.state.changed`, which is exactly what `changed` says.
struct ControlAgentEventPayload: Codable, Equatable {
    var schema = "quickterm.agent-event/1"
    /// The caller's own pane, by handle.
    var pane: String
    var agent: String
    var state: String
    var detail: String?
    /// The event moved the pane's agent state (and therefore moved `seq`).
    var changed: Bool
    /// A `needs-user` notice was posted by this event.
    var noticeID: String?
    /// How many live notices this event resolved.
    var resolved: Int
}

/// The payload for `list` (exactly one of the three is non-nil).
struct ControlListPayload: Codable, Equatable {
    var screens: [ControlStatePayload.ScreenInfo]?
    var workspaces: [ControlStatePayload.WorkspaceInfo]?
    var panes: [JSONValue]?
}

struct ControlPanePayload: Codable, Equatable {
    var pane: ControlStatePayload.PaneInfo
}

/// The payload for `action`.
struct ControlActionPayload: Codable, Equatable {
    var action: String
    var cls: ControlCommandClass
    var applied: Bool
    /// True when close-pane hit the "a process is still running" confirmation: the pane is not
    /// closed, we are waiting for the user to answer.
    var confirmPending: Bool?
    /// Focus handover is retried asynchronously (0.75s at most): when the command returns, focus
    /// may not have landed on `resolved.pane` yet.
    var focusPending: Bool?
    var panes: [ControlStatePayload.PaneInfo]?
}

struct ControlActionListPayload: Codable, Equatable {
    var actions: [ControlCommandTable.ActionDoc]
}

struct ControlVersionPayload: Codable, Equatable {
    /// The version of the calling binary. **The app side always leaves this nil** — it has no way
    /// to know who is calling it; the CLI fills it in itself. Filling it with the app's version
    /// would make "CLI and app disagree" always look like agreement, and an old `quickterm` left on
    /// PATH after an upgrade is exactly what this field exists to surface.
    var cli: String?
    var app: String?
    var protocolVersion: Int
    var appProtocolVersion: Int?
    var socket: String?
    var running: Bool
}
