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
