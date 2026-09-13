import Foundation

/// Event types (Phase 4). **New ones may only be appended**: agents branch on the `type` string,
/// never on the prose.
///
/// ⚠️ There is **no "pane output" type here, and there never will be**.
/// Pushing shell output onto the socket means handing over passwords, tokens and the contents of
/// ssh sessions verbatim, and the flow-control complexity it drags in (tmux built `%pause` /
/// `%extended-output` purely for this) is a price paid for nothing.
/// Events carry **structure** only (what opened, what closed, where focus is, what the layout is)
/// plus two pieces of metadata: title and cwd.
enum ControlEventType: String, Codable, CaseIterable {
    case paneOpened = "pane.opened"
    case paneClosed = "pane.closed"
    case focusChanged = "focus.changed"
    case workspaceChanged = "workspace.changed"
    case layoutChanged = "layout.changed"
    case screenOpened = "screen.opened"
    case screenClosed = "screen.closed"
    case paneTitleChanged = "pane.title.changed"
    case paneCwdChanged = "pane.cwd.changed"

    var summary: String {
        switch self {
        case .paneOpened: "a pane was created (terminal / browser / file manager)"
        case .paneClosed: "a pane closed (reported as soon as the close animation starts, matching what state still counts as addressable)"
        case .focusChanged: "keyboard focus on a screen moved to another pane"
        case .workspaceChanged: "a screen switched workspace (no title field), or a workspace was renamed (title = the new name, \"\" when the name was cleared)"
        case .layoutChanged: "the structure of a workspace changed (layout kind / column width / split ratio / zoom / floating layer)"
        case .screenOpened: "a screen (window) was created"
        case .screenClosed: "a screen closed"
        case .paneTitleChanged: "a pane title changed (**not** its output)"
        case .paneCwdChanged: "the working directory of a terminal pane changed (OSC 7)"
        }
    }
}

/// A single event. Every field is optional; only the ones this event type can actually speak to are
/// filled in.
///
/// **Pure Foundation**: this directory is compiled into both the app and the `quickterm` tool
/// target.
struct ControlEvent: Codable, Equatable {
    /// Monotonically increasing; the same counter as the `seq` in `state` and in every response.
    var seq: Int
    /// ISO8601 (with milliseconds).
    var ts: String
    var type: String
    var screen: Int?
    var screenID: String?
    var workspace: Int?
    var pane: String?
    var paneID: String?
    var kind: String?
    var layout: String?
    /// The title for pane.title.changed / pane.opened; for a browser pane it is `<redacted>` to any
    /// caller without a token.
    /// When workspace.changed carries it, it means **the workspace's name**: a switch between
    /// workspaces has no title field at all, a rename carries the new name, and clearing the name
    /// carries `""` - the same three-way convention pane.title.changed uses. Reading "no title
    /// field" as "the name was cleared" is what this spells out; the two used to be the same event
    /// on the wire.
    var title: String?
    /// The pane's title is **pinned** (taken over by `pane set --title` or by the rename sheet), as
    /// on pane.title.changed. Encoded only when true, the same convention `state`'s `titleSet`
    /// follows: absent means the shell still owns it.
    /// A title event carries it because the pin can flip without the text changing a character -
    /// pinning a pane to the very title the shell is reporting is an ordinary thing for an agent to
    /// do, and a subscriber that only watched `title` would never learn it happened.
    var titleSet: Bool?
    /// The working directory for pane.cwd.changed / pane.opened.
    var cwd: String?
    /// The title / cwd in this event were redacted (the same rule `state` uses).
    var redacted: Bool?

    static let redactedPlaceholder = "<redacted>"

    init(seq: Int = 0, ts: String = "", type: ControlEventType,
         screen: Int? = nil, screenID: String? = nil, workspace: Int? = nil,
         pane: String? = nil, paneID: String? = nil, kind: String? = nil,
         layout: String? = nil, title: String? = nil, titleSet: Bool? = nil,
         cwd: String? = nil, redacted: Bool? = nil) {
        self.seq = seq
        self.ts = ts
        self.type = type.rawValue
        self.screen = screen
        self.screenID = screenID
        self.workspace = workspace
        self.pane = pane
        self.paneID = paneID
        self.kind = kind
        self.layout = layout
        self.title = title
        self.titleSet = titleSet
        self.cwd = cwd
        self.redacted = redacted
    }

    /// Timestamp: ISO8601 plus milliseconds (one per event; the formatter itself is static).
    static func stamp(_ date: Date = Date()) -> String { formatter.string(from: date) }

    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f
    }()
}

/// The payload for `events poll` / `events follow`.
struct ControlEventsPayload: Codable, Equatable {
    var schema = "quickterm.events/1"
    /// This batch of events (ascending by seq).
    var events: [ControlEvent]
    /// **This is what the next `--since` should be given** (even when this batch came back empty).
    ///
    /// It is a **cursor**, not necessarily the current global seq: when `truncated` is true it
    /// points at the last event actually shipped in this batch, and whatever `--limit` cut off
    /// arrives on the next round. Poll along this value and no event is ever dropped or delivered
    /// twice.
    var seq: Int
    /// The oldest event still held in the ring buffer.
    var oldest: Int?
    /// `--since` is older than `oldest`: events in between were pushed out of the ring, the
    /// snapshot you hold is incomplete, read `state` again.
    var missed: Bool?
    /// The long poll hit its deadline with no events (**not an error**: poll again with the same
    /// seq).
    var timedOut: Bool?
    /// This batch was cut short by `--limit` and more is still queued in the buffer: poll again
    /// **immediately** with the `seq` above instead of waiting for the next timeout (`missed` means
    /// something else entirely — that events were pushed out of the ring and are gone for good).
    var truncated: Bool?
    /// This batch came from an `events follow` stream (the connection stays open).
    var follow: Bool?
}

/// Event-related constants (one copy, shared by the app and the CLI).
enum ControlEventLimits {
    /// Ring buffer capacity: past this the oldest entries are pushed out, and `missed` tells the
    /// caller it happened.
    static let ringCapacity = 512
    /// How many events a single poll returns at most.
    static let maxBatch = 256
    /// How many concurrent `events follow` streams are allowed (each one holds a connection open).
    static let maxFollowers = 8
    static let defaultPollTimeout: TimeInterval = 5
    static let maxPollTimeout: TimeInterval = 300

    /// `--timeout 5s` / `500ms` / `5` (seconds). **Anything we cannot parse is an error; it is
    /// never silently treated as the default.**
    static func parseTimeout(_ raw: String?) throws -> TimeInterval {
        guard let raw, !raw.isEmpty else { return defaultPollTimeout }
        let text = raw.trimmingCharacters(in: .whitespaces).lowercased()
        let value: Double?
        var scale = 1.0
        if text.hasSuffix("ms") {
            value = Double(text.dropLast(2))
            scale = 0.001
        } else if text.hasSuffix("s") {
            value = Double(text.dropLast())
        } else if text.hasSuffix("m") {
            value = Double(text.dropLast())
            scale = 60
        } else {
            value = Double(text)
        }
        guard let value, value >= 0, value.isFinite else {
            throw ControlErrorBody(.badRequest, "--timeout does not understand \(raw)",
                                   hint: "Write it as 5s / 500ms / 2m, or just give a number of seconds.")
        }
        let seconds = value * scale
        guard seconds <= maxPollTimeout else {
            throw ControlErrorBody(.badRequest,
                                   "--timeout is at most \(Int(maxPollTimeout))s (got \(Int(seconds))s)",
                                   hint: "A long poll that times out returns an empty batch, just poll again.")
        }
        return seconds
    }

    /// `--types pane.opened,focus.changed`. An unrecognized type name is an error that lists every
    /// valid type.
    static func parseTypes(_ raw: String?) throws -> Set<String>? {
        guard let raw, !raw.isEmpty else { return nil }
        let names = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !names.isEmpty else { return nil }
        let known = Set(ControlEventType.allCases.map(\.rawValue))
        for name in names where !known.contains(name) {
            throw ControlErrorBody(.badRequest, "Unknown event type \(name)",
                                   hint: "The events section of quickterm describe --json lists every type.",
                                   candidates: ControlEventType.allCases.map(\.rawValue))
        }
        return Set(names)
    }
}
