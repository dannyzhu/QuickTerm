import Foundation

/// The **public** schema for Phase 3: `quickterm.workspace/1` (plus the two envelopes
/// `quickterm.screen/1` / `quickterm.session/1`, which reuse the workspace vocabulary verbatim).
///
/// **Deliberately not the internal `PersistedState` v5 archive**, and this is the line that matters
/// most to hold in this phase:
/// - v5 has already rolled v2->v3->v4->v5, and its decoder **refuses to read a version newer than
///   itself** — shipping it as a public format would mean every workspace file a user commits to
///   their dotfiles expires at the next layout refactor;
/// - a v5 terminal leaf only has `pwd` / `title`: **no** command, no env, no hold-on-exit, and
///   those three are exactly the fields you must be able to write for an agent to compose a
///   whole workspace in one shot;
/// - conversely, the public schema should not carry v5's envelope fields (the window frame's
///   coordinate system, legacy column-width normalization, and so on).
///
/// There is exactly one link between the two: the projection pair in
/// `Sources/Control/Spec/SpecCodec.swift` (live model -> spec for dump, spec -> live model for
/// plan). So the two formats **evolve independently**.
///
/// This file lives in `Sources/Control/Wire`: compiled into both the app and the `quickterm` tool
/// target, so it may only `import Foundation`.
enum SpecSchema {
    static let workspace = "quickterm.workspace/1"
    static let screen = "quickterm.screen/1"
    static let session = "quickterm.session/1"
    static let all = [workspace, screen, session]
}

/// The permitted ranges of every numeric field in a spec. **They must cover what the engine can
/// actually hold** — `ControlSpecTests.testSpecLimitsMatchTheEngine` pins them one by one (Wire may
/// only import Foundation and cannot reference `ScrollingStrip`, so each side keeps its own copy
/// and the tests lock them together).
/// Too narrow and a dumped file fails its own validate; too wide and apply pushes down a value the
/// engine cannot lay out.
enum SpecLimits {
    /// Column width factor. **Wider at both ends than `pane set --width` (0.25-0.90, which is the
    /// range for dragging a column by hand)**: "N columns visible per screen" divides the whole
    /// strip into `ScrollingStrip.factor(forVisibleColumns:)` = (1-2×peek)/N — N=1 gives 0.97 and
    /// N=6 gives 0.1617, both outside 0.25-0.90.
    /// Make the public schema even slightly narrower than what the engine can hold and a file from
    /// `spec dump` gets rejected on the spot by `spec validate` (QuickTerm cannot read what
    /// QuickTerm just wrote).
    static let widthRange = 0.15...0.98
    /// Split ratio. Likewise **wider than `pane set --ratio` (0.1-0.9)**: dragging a divider with
    /// the mouse only clamps at 10pt, so a 1600pt-wide pane dragged all the way over lands at
    /// 0.006, and dump has to write that number down honestly — clamp it silently and the dump no
    /// longer describes this workspace, and applying it back makes the divider jump on its own.
    static let ratioRange = 0.001...0.999
    /// == `screen set --visible-columns`
    static let visibleColumns = 1...6
    /// == `ControlRateLimiter.maxPanesPerWorkspace`
    static let maxPanes = 32
    /// The byte ceiling on one spec (a single NDJSON line caps at 1 MiB, and escaping needs
    /// headroom on top of that).
    static let maxBytes = 256 * 1024
    /// == `ControlCommandRunner.maxTitleLength` (the workspace name; Wire cannot reach that side,
    /// so the tests lock the two values together).
    static let maxTitleCharacters = 200
}

/// One pane inside a spec. **Every field may be omitted**, and each one's default when omitted is
/// in its own comment — so a model can write nothing but `{"panes":[{}]}` and get a working
/// terminal pane.
struct PaneSpec: Codable, Equatable {
    /// `terminal` (the default) / `browser` / `file-manager`.
    var kind: String?
    /// The starting directory (`~` is supported). **Defaults to inheriting the anchor pane's
    /// directory** (see `SpecApplier.anchorDirectory`).
    var cwd: String?
    /// The command to run. **Write-only**: a live surface does not remember what command started it
    /// (the v5 archive has no such field either), so `spec dump` never gives `cmd` back.
    var cmd: String?
    /// Keep the pane open after the command exits (it closes by default). Only meaningful with
    /// `cmd`.
    var hold: Bool?
    /// Extra environment variables. Write-only as well.
    var env: [String: String]?
    /// The URL a browser pane opens (= the active tab).
    var url: String?
    /// All the tabs of a browser pane (array order = tab order); `url` decides which one is
    /// active.
    var tabs: [String]?
    /// Only present with `dump --include-ids`: the pane's UUID. `apply --reuse` uses it as the
    /// strongest match; every other mode ignores it.
    var id: String?
    /// Only present with `dump --include-ids`: the short handle (stable only for this run).
    var handle: String?
    /// Only present with `dump --include-ids`: the current title (volatile, for humans to read;
    /// apply always ignores it).
    var title: String?
    /// This browser pane's url / title were redacted because the caller had no token (apply treats
    /// that as "no url was written").
    var redacted: Bool?
}

/// A positional reference: scrolling uses `{column,row}`, dwindle uses `{path}`, the floating layer
/// uses `{floating}`.
/// `focus` and `zoom` share it — both name **a slot in the layout**, not the identity of a
/// particular pane (identity only comes into existence at apply time, and a spec has to be writable
/// while the panes do not exist yet).
struct PaneRef: Codable, Equatable {
    var column: Int?
    var row: Int?
    /// The dwindle tree path: `a` = left / top, `b` = right / bottom, joined with dots; the root is
    /// the empty string.
    var path: String?
    /// Which entry in the floating layer (0-based).
    var floating: Int?
}

struct ColumnSpec: Codable, Equatable {
    /// Column width factor (0.15-0.98). Defaults to the width implied by the screen's current
    /// "columns visible per screen".
    var width: Double?
    /// The pane stack inside the column, top to bottom. Defaults to `[{}]` (one terminal).
    var panes: [PaneSpec]?
}

/// A dwindle tree node: either a leaf (`pane`) or a split (`a` / `b`).
/// The empty object `{}` is a default leaf (a terminal) — two lines of spec are enough to write a
/// whole tree.
indirect enum NodeSpec: Equatable {
    case leaf(PaneSpec)
    case split(Split)

    struct Split: Equatable {
        /// `horizontal` = a on the left, b on the right (the default); `vertical` = a on top, b
        /// below.
        /// Same names and same meanings as the internal `SplitTree.Direction` — never a second
        /// vocabulary for the same thing.
        var direction: String?
        /// The split ratio (0.001-0.999; typing one by hand, 0.1-0.9 is plenty), default 0.5.
        var ratio: Double?
        var a: NodeSpec
        var b: NodeSpec
    }

    private enum CodingKeys: String, CodingKey { case pane, split, ratio, a, b }
}

extension NodeSpec: Codable {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if c.contains(.a) || c.contains(.b) {
            let a = try c.decodeIfPresent(NodeSpec.self, forKey: .a) ?? .leaf(PaneSpec())
            let b = try c.decodeIfPresent(NodeSpec.self, forKey: .b) ?? .leaf(PaneSpec())
            self = .split(Split(direction: try c.decodeIfPresent(String.self, forKey: .split),
                                ratio: try c.decodeIfPresent(Double.self, forKey: .ratio),
                                a: a, b: b))
            return
        }
        self = .leaf(try c.decodeIfPresent(PaneSpec.self, forKey: .pane) ?? PaneSpec())
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .leaf(let pane):
            try c.encode(pane, forKey: .pane)
        case .split(let split):
            try c.encodeIfPresent(split.direction, forKey: .split)
            try c.encodeIfPresent(split.ratio, forKey: .ratio)
            try c.encode(split.a, forKey: .a)
            try c.encode(split.b, forKey: .b)
        }
    }

    var leafCount: Int {
        switch self {
        case .leaf: 1
        case .split(let s): s.a.leafCount + s.b.leafCount
        }
    }
}

/// One entry in the floating layer: a pane plus optional geometry (as fractions of the content
/// area, `[x,y,w,h]`).
/// Omitting the geometry means the app's own default: centered, 0.75 × the column width, 45% tall.
struct FloatingSpec: Codable, Equatable {
    var rect: [Double]?
    var pane: PaneSpec?
}

/// `quickterm.workspace/1`
struct WorkspaceSpec: Codable, Equatable {
    var schema: String?
    /// The 1-based workspace index. Only meaningful inside the `workspaces[]` of a
    /// `quickterm.screen/1` (omitted, the array position decides where it lands).
    var index: Int?
    /// `scrolling` (the default) / `dwindle`.
    var layout: String?
    /// The name of this slot (omitted = **leave it alone**, the same rule as `visibleColumns`; an
    /// empty string clears it). The name belongs to the slot, not to the panes inside it — so
    /// `apply --replace` swapping out every pane leaves it standing, and only this spec saying so
    /// changes it.
    var title: String?
    /// Columns visible per screen in scrolling (1-6). **Applies to the whole screen**; omitted, it
    /// is left alone.
    var visibleColumns: Int?
    /// scrolling: columns, each with its own vertical stack.
    var columns: [ColumnSpec]?
    /// dwindle: the split tree.
    var tree: NodeSpec?
    /// Which slot is zoomed (omitted / null = none).
    var zoom: PaneRef?
    /// Which slot takes focus (omitted = the first pane).
    var focus: PaneRef?
    /// The floating layer (omitted = empty).
    var floating: [FloatingSpec]?

    init(schema: String? = nil, index: Int? = nil, layout: String? = nil, title: String? = nil,
         visibleColumns: Int? = nil, columns: [ColumnSpec]? = nil, tree: NodeSpec? = nil,
         zoom: PaneRef? = nil, focus: PaneRef? = nil, floating: [FloatingSpec]? = nil) {
        self.schema = schema
        self.index = index
        self.layout = layout
        self.title = title
        self.visibleColumns = visibleColumns
        self.columns = columns
        self.tree = tree
        self.zoom = zoom
        self.focus = focus
        self.floating = floating
    }

    /// The layout name with defaults filled in.
    var layoutName: String { layout ?? (tree != nil ? "dwindle" : "scrolling") }

    /// How many panes this spec asks for in total (tiled plus floating).
    var paneCount: Int {
        let tiled: Int
        switch layoutName {
        case "dwindle": tiled = tree?.leafCount ?? 0
        default: tiled = (columns ?? []).reduce(0) { $0 + ($1.panes?.count ?? 1) }
        }
        return tiled + (floating ?? []).count
    }
}

struct DisplaySpec: Codable, Equatable {
    var uuid: String?
    var name: String?
}

/// `quickterm.screen/1`: an envelope around the workspace vocabulary.
struct ScreenSpec: Codable, Equatable {
    var schema: String?
    /// The 1-based screen index (echoed by dump; apply goes by `-t`).
    var index: Int?
    var display: DisplaySpec?
    /// `[x, y, w, h]` (global coordinates).
    var frame: [Double]?
    var fullscreen: Bool?
    var joinAllSpaces: Bool?
    var visibleColumns: Int?
    /// 1-based.
    var activeWorkspace: Int?
    var workspaces: [WorkspaceSpec]?
}

/// `quickterm.session/1`
struct SessionSpec: Codable, Equatable {
    var schema: String?
    var screens: [ScreenSpec]?
    /// The 1-based index of the key screen.
    var keyScreen: Int?
}

enum SpecKind: String, Codable, CaseIterable {
    case workspace, screen, session
}

/// What one spec file parses into (all three scopes share one vocabulary).
enum SpecDocument: Equatable {
    case workspace(WorkspaceSpec)
    case screen(ScreenSpec)
    case session(SessionSpec)

    var kind: SpecKind {
        switch self {
        case .workspace: .workspace
        case .screen: .screen
        case .session: .session
        }
    }

    /// How many panes it describes in total (both rate limiting and the `--dry-run` summary need
    /// this).
    var paneCount: Int {
        switch self {
        case .workspace(let w): w.paneCount
        case .screen(let s): (s.workspaces ?? []).reduce(0) { $0 + $1.paneCount }
        case .session(let s): (s.screens ?? []).reduce(0) { sum, screen in
            sum + (screen.workspaces ?? []).reduce(0) { $0 + $1.paneCount } }
        }
    }

    func json() throws -> JSONValue {
        let data: Data
        switch self {
        case .workspace(let w): data = try ControlJSON.encoder.encode(w)
        case .screen(let s): data = try ControlJSON.encoder.encode(s)
        case .session(let s): data = try ControlJSON.encoder.encode(s)
        }
        return try ControlJSON.decoder.decode(JSONValue.self, from: data)
    }

    /// The stable byte form (this is what the `dump -> apply -> dump` fixed-point test compares).
    func canonicalJSONString() throws -> String {
        String(decoding: try ControlJSON.encoder.encode(json()), as: UTF8.self)
    }
}

/// One problem found by validation: `path` has the same shape as the spec itself
/// (`columns[1].panes[0].cwd`), so the location a model reads is the key it has to go and edit.
struct SpecIssue: Codable, Equatable {
    var path: String
    var message: String

    var text: String { path.isEmpty ? message : "\(path): \(message)" }
}

/// Parsing plus validation. **The raw JSON is walked first** (known keys, types, value ranges) and
/// only then decoded into types — relying on `JSONDecoder` alone means a misspelled key (`colums`)
/// is silently treated as "not written", and what the agent gets back is a result that succeeded
/// while nothing happened, which is the hardest class of bug to track down.
enum SpecParser {
    static func parse(_ text: String) throws -> SpecDocument {
        guard text.utf8.count <= SpecLimits.maxBytes else {
            throw ControlErrorBody(.badRequest,
                                   "spec is too large (\(text.utf8.count) bytes, limit \(SpecLimits.maxBytes))")
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ControlErrorBody(.badRequest, "spec is empty",
                                   hint: "Run quickterm spec dump > w.json to get a starting point.")
        }
        guard let data = trimmed.data(using: .utf8),
              let value = try? ControlJSON.decoder.decode(JSONValue.self, from: data) else {
            throw ControlErrorBody(.badRequest, "spec is not valid JSON",
                                   hint: "quickterm spec validate points at every problem one by one.")
        }
        // The envelope form is accepted too: when the output of `quickterm spec dump --json` is
        // saved to a file whole ({v,ok,data:{spec:...}}), feeding it straight back works —
        // otherwise the user has to jq it first before they can apply, and that is exactly the step
        // people get wrong
        let body = value["data"]?["spec"] ?? value
        guard let object = body.objectValue else {
            throw ControlErrorBody(.badRequest, "The outermost value of a spec must be a JSON object")
        }
        let kind = try kind(of: object)
        var issues: [SpecIssue] = []
        switch kind {
        case .workspace: SpecValidator.workspace(object, at: "", into: &issues)
        case .screen: SpecValidator.screen(object, at: "", into: &issues)
        case .session: SpecValidator.session(object, at: "", into: &issues)
        }
        guard issues.isEmpty else { throw error(issues) }

        let encoded = try ControlJSON.encoder.encode(body)
        do {
            switch kind {
            case .workspace: return .workspace(try ControlJSON.decoder.decode(WorkspaceSpec.self, from: encoded))
            case .screen: return .screen(try ControlJSON.decoder.decode(ScreenSpec.self, from: encoded))
            case .session: return .session(try ControlJSON.decoder.decode(SessionSpec.self, from: encoded))
            }
        } catch {
            throw ControlErrorBody(.badRequest, "spec failed to decode: \(error)")
        }
    }

    /// `schema` wins when present; without it we go by shape (`screens` = a session, `workspaces` =
    /// a screen, otherwise a workspace).
    static func kind(of object: [String: JSONValue]) throws -> SpecKind {
        if let schema = object["schema"]?.stringValue {
            switch schema {
            case SpecSchema.workspace: return .workspace
            case SpecSchema.screen: return .screen
            case SpecSchema.session: return .session
            default:
                throw ControlErrorBody(.badRequest, "Unknown schema `\(schema)`",
                                       hint: "This version knows: \(SpecSchema.all.joined(separator: " / ")).",
                                       candidates: SpecSchema.all)
            }
        }
        if object["screens"] != nil { return .session }
        if object["workspaces"] != nil { return .screen }
        return .workspace
    }

    static func error(_ issues: [SpecIssue]) -> ControlErrorBody {
        let head = issues.prefix(8).map(\.text).joined(separator: "; ")
        let more = issues.count > 8 ? " (and \(issues.count - 8) more)" : ""
        return ControlErrorBody(.badRequest, "spec is not valid: \(head)\(more)",
                                hint: "quickterm spec validate -f <file> lists them all at once.")
    }
}

/// Structural validation (pure functions; nothing live is touched).
/// The rules are hard-coded on purpose: the set of known keys is an allowlist — a misspelled key is
/// always an error, never silently ignored.
enum SpecValidator {
    static let workspaceKeys: Set<String> = ["schema", "index", "layout", "title", "visibleColumns",
                                             "columns", "tree", "zoom", "focus", "floating"]
    static let screenKeys: Set<String> = ["schema", "index", "display", "frame", "fullscreen",
                                          "joinAllSpaces", "visibleColumns", "activeWorkspace",
                                          "workspaces"]
    static let sessionKeys: Set<String> = ["schema", "screens", "keyScreen"]
    static let paneKeys: Set<String> = ["kind", "cwd", "cmd", "hold", "env", "url", "tabs",
                                        "id", "handle", "title", "redacted"]
    static let columnKeys: Set<String> = ["width", "panes"]
    static let nodeKeys: Set<String> = ["pane", "split", "ratio", "a", "b"]
    static let refKeys: Set<String> = ["column", "row", "path", "floating"]
    static let floatingKeys: Set<String> = ["rect", "pane"]
    static let displayKeys: Set<String> = ["uuid", "name"]

    static let paneKinds = ["terminal", "browser", "file-manager"]
    static let layouts = ["scrolling", "dwindle"]
    static let directions = ["horizontal", "vertical"]

    // MARK: The three scopes

    static func session(_ object: [String: JSONValue], at path: String, into issues: inout [SpecIssue]) {
        unknownKeys(object, allowed: sessionKeys, at: path, into: &issues)
        schema(object, expected: SpecSchema.session, at: path, into: &issues)
        if let key = object["keyScreen"] { positiveInt(key, at: join(path, "keyScreen"), into: &issues) }
        guard let screens = object["screens"] else { return }
        guard let list = screens.arrayValue else {
            issues.append(.init(path: join(path, "screens"), message: "must be an array"))
            return
        }
        for (i, item) in list.enumerated() {
            let p = "\(join(path, "screens"))[\(i)]"
            guard let child = item.objectValue else {
                issues.append(.init(path: p, message: "must be an object"))
                continue
            }
            screen(child, at: p, into: &issues, nested: true)
        }
    }

    static func screen(_ object: [String: JSONValue], at path: String,
                       into issues: inout [SpecIssue], nested: Bool = false) {
        unknownKeys(object, allowed: screenKeys, at: path, into: &issues)
        if !nested { schema(object, expected: SpecSchema.screen, at: path, into: &issues) }
        if let index = object["index"] { positiveInt(index, at: join(path, "index"), into: &issues) }
        if let active = object["activeWorkspace"] {
            positiveInt(active, at: join(path, "activeWorkspace"), into: &issues)
        }
        if let columns = object["visibleColumns"] {
            intInRange(columns, SpecLimits.visibleColumns, at: join(path, "visibleColumns"), into: &issues)
        }
        for key in ["fullscreen", "joinAllSpaces"] where object[key] != nil {
            boolean(object[key]!, at: join(path, key), into: &issues)
        }
        if let display = object["display"] {
            if let child = display.objectValue {
                unknownKeys(child, allowed: displayKeys, at: join(path, "display"), into: &issues)
            } else if display != .null {
                issues.append(.init(path: join(path, "display"), message: "must be an object {uuid,name}"))
            }
        }
        if let frame = object["frame"], frame != .null {
            guard let list = frame.arrayValue, list.count == 4, list.allSatisfy({ $0.doubleValue != nil }) else {
                issues.append(.init(path: join(path, "frame"), message: "must be 4 numbers [x,y,w,h]"))
                return
            }
        }
        guard let workspaces = object["workspaces"] else { return }
        guard let list = workspaces.arrayValue else {
            issues.append(.init(path: join(path, "workspaces"), message: "must be an array"))
            return
        }
        for (i, item) in list.enumerated() {
            let p = "\(join(path, "workspaces"))[\(i)]"
            guard let child = item.objectValue else {
                issues.append(.init(path: p, message: "must be an object"))
                continue
            }
            workspace(child, at: p, into: &issues, nested: true)
        }
    }

    static func workspace(_ object: [String: JSONValue], at path: String,
                          into issues: inout [SpecIssue], nested: Bool = false) {
        unknownKeys(object, allowed: workspaceKeys, at: path, into: &issues)
        if !nested { schema(object, expected: SpecSchema.workspace, at: path, into: &issues) }
        if let index = object["index"] { positiveInt(index, at: join(path, "index"), into: &issues) }
        var layoutName = "scrolling"
        if let layout = object["layout"], layout != .null {
            guard let name = layout.stringValue, layouts.contains(name) else {
                issues.append(.init(path: join(path, "layout"),
                                    message: "must be one of \(layouts.joined(separator: " / "))"))
                return
            }
            layoutName = name
        } else if object["tree"] != nil, object["columns"] == nil {
            layoutName = "dwindle"
        }
        if let columns = object["visibleColumns"] {
            intInRange(columns, SpecLimits.visibleColumns, at: join(path, "visibleColumns"), into: &issues)
        }
        if let title = object["title"], title != .null {
            // Validation lines up item for item with `workspace set --title`: length, control
            // characters.
            // If the spec side were the laxer of the two, the result would be "validate passed, but
            // apply was rejected by the command layer"
            guard let text = title.stringValue else {
                issues.append(.init(path: join(path, "title"), message: "must be a string (an empty string clears the name)"))
                return
            }
            if text.count > SpecLimits.maxTitleCharacters {
                issues.append(.init(path: join(path, "title"),
                                    message: "at most \(SpecLimits.maxTitleCharacters) characters, this one has \(text.count)"))
            }
            if text.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F
                                                     || (0x80...0x9F).contains($0.value) }) {
                issues.append(.init(path: join(path, "title"), message: "must not contain control characters"))
            }
        }
        if layoutName == "scrolling", object["tree"] != nil, object["tree"] != .null {
            issues.append(.init(path: join(path, "tree"), message: "only meaningful with layout=dwindle"))
        }
        if layoutName == "dwindle", object["columns"] != nil, object["columns"] != .null {
            issues.append(.init(path: join(path, "columns"), message: "only meaningful with layout=scrolling"))
        }
        var paneCount = 0
        if let columns = object["columns"], columns != .null {
            guard let list = columns.arrayValue else {
                issues.append(.init(path: join(path, "columns"), message: "must be an array"))
                return
            }
            for (i, item) in list.enumerated() {
                let p = "\(join(path, "columns"))[\(i)]"
                guard let child = item.objectValue else {
                    issues.append(.init(path: p, message: "must be an object {width,panes}"))
                    continue
                }
                paneCount += column(child, at: p, into: &issues)
            }
        }
        if let tree = object["tree"], tree != .null {
            paneCount += node(tree, at: join(path, "tree"), into: &issues)
        }
        if let floating = object["floating"], floating != .null {
            guard let list = floating.arrayValue else {
                issues.append(.init(path: join(path, "floating"), message: "must be an array"))
                return
            }
            paneCount += list.count
            for (i, item) in list.enumerated() {
                let p = "\(join(path, "floating"))[\(i)]"
                guard let child = item.objectValue else {
                    issues.append(.init(path: p, message: "must be an object {rect,pane}"))
                    continue
                }
                unknownKeys(child, allowed: floatingKeys, at: p, into: &issues)
                if let rect = child["rect"], rect != .null {
                    guard let numbers = rect.arrayValue, numbers.count == 4,
                          numbers.allSatisfy({ $0.doubleValue != nil }) else {
                        issues.append(.init(path: join(p, "rect"),
                                            message: "must be 4 numbers in 0–1 [x,y,w,h] (fractions of the content area)"))
                        continue
                    }
                }
                if let child2 = child["pane"]?.objectValue { pane(child2, at: join(p, "pane"), into: &issues) }
            }
        }
        for key in ["zoom", "focus"] {
            guard let value = object[key], value != .null else { continue }
            guard let child = value.objectValue else {
                issues.append(.init(path: join(path, key),
                                    message: "must be a position reference: {column,row} / {path} / {floating}"))
                continue
            }
            unknownKeys(child, allowed: refKeys, at: join(path, key), into: &issues)
            for k in ["column", "row", "floating"] where child[k] != nil {
                nonNegativeInt(child[k]!, at: join(join(path, key), k), into: &issues)
            }
            if let p = child["path"], p != .null {
                guard let text = p.stringValue,
                      text.isEmpty || text.split(separator: ".").allSatisfy({ $0 == "a" || $0 == "b" }) else {
                    issues.append(.init(path: join(join(path, key), "path"),
                                        message: "a tree path is a / b joined by dots (the root is the empty string)"))
                    continue
                }
            }
        }
        if paneCount > SpecLimits.maxPanes {
            issues.append(.init(path: path,
                                message: "a workspace holds at most \(SpecLimits.maxPanes) panes, this one has \(paneCount)"))
        }
    }

    /// Returns the number of panes in this column.
    private static func column(_ object: [String: JSONValue], at path: String,
                               into issues: inout [SpecIssue]) -> Int {
        unknownKeys(object, allowed: columnKeys, at: path, into: &issues)
        if let width = object["width"], width != .null {
            doubleInRange(width, SpecLimits.widthRange, at: join(path, "width"), into: &issues)
        }
        guard let panes = object["panes"], panes != .null else { return 1 }
        guard let list = panes.arrayValue else {
            issues.append(.init(path: join(path, "panes"), message: "must be an array"))
            return 0
        }
        if list.isEmpty {
            issues.append(.init(path: join(path, "panes"), message: "a column needs at least one pane (an empty column means nothing)"))
        }
        for (i, item) in list.enumerated() {
            let p = "\(join(path, "panes"))[\(i)]"
            guard let child = item.objectValue else {
                issues.append(.init(path: p, message: "must be an object"))
                continue
            }
            pane(child, at: p, into: &issues)
        }
        return list.count
    }

    /// Returns the number of leaves in this subtree.
    private static func node(_ value: JSONValue, at path: String, into issues: inout [SpecIssue]) -> Int {
        guard let object = value.objectValue else {
            issues.append(.init(path: path, message: "a tree node must be an object: {pane:…} or {split,ratio,a,b}"))
            return 0
        }
        unknownKeys(object, allowed: nodeKeys, at: path, into: &issues)
        let isSplit = object["a"] != nil || object["b"] != nil
        if isSplit {
            if let direction = object["split"], direction != .null {
                guard let name = direction.stringValue, directions.contains(name) else {
                    issues.append(.init(path: join(path, "split"),
                                        message: "must be horizontal (a left, b right) or vertical (a top, b bottom)"))
                    return 0
                }
            }
            if let ratio = object["ratio"], ratio != .null {
                doubleInRange(ratio, SpecLimits.ratioRange, at: join(path, "ratio"), into: &issues)
            }
            if object["pane"] != nil {
                issues.append(.init(path: path, message: "a node cannot be both a split (a/b) and a leaf (pane)"))
            }
            var count = 0
            for key in ["a", "b"] {
                guard let child = object[key] else {
                    issues.append(.init(path: join(path, key), message: "both sides of a split must be spelled out (a missing side is never filled in for you)"))
                    continue
                }
                count += node(child, at: join(path, key), into: &issues)
            }
            return count
        }
        if let leaf = object["pane"] {
            guard let child = leaf.objectValue else {
                issues.append(.init(path: join(path, "pane"), message: "must be an object"))
                return 1
            }
            pane(child, at: join(path, "pane"), into: &issues)
        }
        return 1
    }

    static func pane(_ object: [String: JSONValue], at path: String, into issues: inout [SpecIssue]) {
        unknownKeys(object, allowed: paneKeys, at: path, into: &issues)
        var kind = "terminal"
        if let value = object["kind"], value != .null {
            guard let name = value.stringValue, paneKinds.contains(name) else {
                issues.append(.init(path: join(path, "kind"),
                                    message: "must be one of \(paneKinds.joined(separator: " / "))"))
                return
            }
            kind = name
        }
        if let cwd = object["cwd"], cwd != .null {
            guard let text = cwd.stringValue else {
                issues.append(.init(path: join(path, "cwd"), message: "must be a string"))
                return
            }
            if let bad = pathProblem(text) {
                issues.append(.init(path: join(path, "cwd"), message: bad))
            }
        }
        if let cmd = object["cmd"], cmd != .null {
            guard let text = cmd.stringValue else {
                issues.append(.init(path: join(path, "cmd"), message: "must be a string"))
                return
            }
            if text.isEmpty {
                issues.append(.init(path: join(path, "cmd"), message: "must not be an empty string (omit it to run no command)"))
            } else if hasControlCharacters(text) {
                issues.append(.init(path: join(path, "cmd"), message: "must not contain control characters"))
            }
            if kind == "browser" {
                issues.append(.init(path: join(path, "cmd"), message: "means nothing for a browser pane"))
            }
        }
        if let hold = object["hold"], hold != .null {
            boolean(hold, at: join(path, "hold"), into: &issues)
        }
        if let env = object["env"], env != .null {
            if let map = env.objectValue {
                for (key, value) in map {
                    let p = join(join(path, "env"), key)
                    guard let text = value.stringValue else {
                        issues.append(.init(path: p, message: "an environment variable value must be a string"))
                        continue
                    }
                    if key.isEmpty || key.contains("=") || key.contains(" ") || hasControlCharacters(key) {
                        issues.append(.init(path: p, message: "invalid environment variable name"))
                    }
                    if hasControlCharacters(text) {
                        issues.append(.init(path: p, message: "an environment variable value must not contain control characters"))
                    }
                }
            } else {
                issues.append(.init(path: join(path, "env"), message: "must be an object {KEY: VALUE}"))
            }
        }
        for key in ["url", "id", "handle", "title"] {
            guard let value = object[key], value != .null else { continue }
            guard let text = value.stringValue else {
                issues.append(.init(path: join(path, key), message: "must be a string"))
                continue
            }
            if hasControlCharacters(text) {
                issues.append(.init(path: join(path, key), message: "must not contain control characters"))
            }
        }
        if object["url"] != nil, kind != "browser" {
            issues.append(.init(path: join(path, "url"), message: "only meaningful with kind=browser"))
        }
        if let tabs = object["tabs"], tabs != .null {
            if kind != "browser" {
                issues.append(.init(path: join(path, "tabs"), message: "only meaningful with kind=browser"))
            }
            guard let list = tabs.arrayValue else {
                issues.append(.init(path: join(path, "tabs"), message: "must be an array of strings"))
                return
            }
            for (i, item) in list.enumerated() where item.stringValue == nil || hasControlCharacters(item.stringValue ?? "") {
                issues.append(.init(path: "\(join(path, "tabs"))[\(i)]", message: "must be a URL with no control characters"))
            }
        }
    }

    // MARK: Small pieces

    static func join(_ path: String, _ key: String) -> String {
        path.isEmpty ? key : "\(path).\(key)"
    }

    static func unknownKeys(_ object: [String: JSONValue], allowed: Set<String>, at path: String,
                            into issues: inout [SpecIssue]) {
        for key in object.keys.sorted() where !allowed.contains(key) {
            issues.append(.init(path: join(path, key),
                                message: "unknown key (allowed: \(allowed.sorted().joined(separator: " ")))"))
        }
    }

    static func schema(_ object: [String: JSONValue], expected: String, at path: String,
                       into issues: inout [SpecIssue]) {
        guard let schema = object["schema"] else { return }   // omitted: go by shape instead
        guard schema.stringValue == expected else {
            issues.append(.init(path: join(path, "schema"), message: "the schema at this level should be \(expected)"))
            return
        }
    }

    static func boolean(_ value: JSONValue, at path: String, into issues: inout [SpecIssue]) {
        if case .bool = value { return }
        if value == .null { return }
        issues.append(.init(path: path, message: "must be true or false"))
    }

    static func positiveInt(_ value: JSONValue, at path: String, into issues: inout [SpecIssue]) {
        guard value != .null else { return }
        guard let int = strictInt(value), int >= 1 else {
            issues.append(.init(path: path, message: "must be an integer ≥1 (indexes always start at 1)"))
            return
        }
    }

    static func nonNegativeInt(_ value: JSONValue, at path: String, into issues: inout [SpecIssue]) {
        guard value != .null else { return }
        guard let int = strictInt(value), int >= 0 else {
            issues.append(.init(path: path, message: "must be an integer ≥0"))
            return
        }
    }

    static func intInRange(_ value: JSONValue, _ range: ClosedRange<Int>, at path: String,
                           into issues: inout [SpecIssue]) {
        guard value != .null else { return }
        guard let int = strictInt(value), range.contains(int) else {
            issues.append(.init(path: path,
                                message: "must be an integer in \(range.lowerBound)–\(range.upperBound)"))
            return
        }
    }

    static func doubleInRange(_ value: JSONValue, _ range: ClosedRange<Double>, at path: String,
                              into issues: inout [SpecIssue]) {
        guard value != .null else { return }
        guard let number = strictDouble(value) else {
            issues.append(.init(path: path, message: "must be a number"))
            return
        }
        guard range.contains(number) else {
            // **Never clamp silently**: after a clamp the value the agent reads back does not match
            // what it wrote, with nothing anywhere to say so
            issues.append(.init(path: path,
                                message: "must be in \(range.lowerBound)–\(range.upperBound), got \(number)"))
            return
        }
    }

    /// Only a real JSON number counts (a string like `"3"` does not — accepting it silently
    /// encourages writing specs that will fail in the next version).
    static func strictInt(_ value: JSONValue) -> Int? {
        if case .int(let v) = value { return v }
        if case .double(let v) = value, v == v.rounded() { return Int(v) }
        return nil
    }

    static func strictDouble(_ value: JSONValue) -> Double? {
        switch value {
        case .int(let v): Double(v)
        case .double(let v): v
        default: nil
        }
    }

    static func hasControlCharacters(_ text: String) -> Bool {
        text.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F }
    }

    /// Whether the path itself is well formed (whether it exists is left to the pre-flight check
    /// before apply: validate has to be able to check, offline, a spec written for another
    /// machine).
    static func pathProblem(_ raw: String) -> String? {
        if raw.isEmpty { return "must not be an empty string" }
        if hasControlCharacters(raw) { return "must not contain control characters (NUL included)" }
        let expanded = (raw as NSString).expandingTildeInPath
        if expanded.hasPrefix("~") { return "cannot resolve this ~ path: \(raw)" }
        guard expanded.hasPrefix("/") else { return "must be an absolute path or start with ~ (got \(raw))" }
        return nil
    }

    /// Expands `~` and normalizes `..` (`/a/b/../c` -> `/a/c`). **Not a security boundary** — the
    /// caller could always write any absolute path directly; normalizing just makes dumped paths
    /// comparable and readable.
    static func normalizedPath(_ raw: String) -> String {
        let expanded = (raw as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded).standardizedFileURL.path
    }
}

// MARK: - Command payloads

/// The payload for `spec dump`. `spec` is the document itself — in JSON mode the CLI **prints only
/// that** (`quickterm spec dump > w.json` has to feed straight back into `spec apply -f w.json`).
struct ControlSpecDumpPayload: Codable, Equatable {
    var scope: String
    var schema: String
    var panes: Int
    var spec: JSONValue
}

/// The payload for `spec validate`.
struct ControlSpecValidatePayload: Codable, Equatable {
    var valid: Bool
    var scope: String
    var schema: String
    var panes: Int
    /// Things worth mentioning even though validation passed (for example, that dump never gives
    /// `cmd` back).
    var notes: [String]
}

/// The report from `spec apply` (carried in the `spec` field of the shared mutation envelope).
struct ControlSpecApplyReport: Codable, Equatable {
    var mode: String
    var scope: String
    /// The handles of the panes that were created.
    var created: [String]
    /// The handles of the panes `--reuse` kept and left untouched.
    var reused: [String]
    /// The handles of the panes that were displaced and went through the real close path.
    var closed: [String]
    /// The failure came **after the cut**: the workspace is already half changed. Say so honestly;
    /// never pretend nothing happened.
    var partial: Bool?
    /// The parts skipped while applying (for example, extra screens in a session spec).
    var skipped: [String]?
}
