import AppKit

/// Apply one `quickterm.workspace/1` document to one workspace.
///
/// **Ordering is the entire content of this class**, because there are three concrete traps in this
/// codebase:
///
/// 1. **Never go through `applyArchive` / `restore(from:)`**. That path was written for "a whole
///    window, on a screen that was just created with `restoring: true`": it replaces panes by
///    assignment, so neither `BrowserPaneView.paneWillClose()` (cancel downloads, tell the
///    extension the window closed) nor the file-manager session cleanup runs at all, and it
///    rewrites historical column widths such as 0.49 / 0.44 on the way past. Using it to apply a
///    spec means silent leaks, and not a single test would go red. Panes that get displaced always
///    go through the **real close path**.
/// 2. **Compute the whole layout value first, then assign it to `model.layouts[i]` once.**
///    `layouts` is `@Published`, and every assignment runs a focus reconciliation, a pane
///    save-state resubscribe and a 1.5s debounced save; five assignments are five relayouts, five
///    animations and five passes through the sinks.
/// 3. **Build first, tear down second.** Building panes is the only step that can fail (the
///    directory is gone, the URL does not resolve); putting it ahead of the teardown is what makes
///    "if it cannot land, not a single pane moves" structurally true rather than a matter of
///    discipline.
///
/// Main thread only (`MainWindowController` is not `@MainActor`, and Swift 5.10 will not check this
/// for us).
@MainActor
final class SpecApplier {
    enum Mode: String, CaseIterable {
        /// The default: only put things into an **empty** workspace, and always refuse a
        /// non-empty one (exit code 4) - it cannot destroy anything
        case intoEmpty = "into-empty"
        /// Destructive: every pane already in the workspace goes through the real close path (a
        /// no-op when the whole thing already matches)
        case replace
        /// Panes that match stay exactly where they are (a running dev server is not restarted),
        /// the rest are closed / created
        case reuse
    }

    /// The stages of applying. **Only there for tests to inject a failure**: failing after the
    /// teardown = the workspace has already been changed, and the report has to say partial
    enum Stage: String {
        case creating, assembling, tearingDown
    }

    struct Outcome {
        var created: [PaneView] = []
        var reused: [PaneView] = []
        var closed: [String] = []
        var focus: PaneView?
    }

    /// One slot as produced by walking the spec
    struct SlotSpec {
        /// The position key (`c:0.1` / `p:a.b` / `f:0`) - this is how `focus` / `zoom` find their
        /// place
        var key: String
        var pane: PaneSpec
        var rect: CGRect?
    }

    struct Slot {
        var key: String
        var spec: PaneSpec
        var request: ControlPaneFactory.Request
        var rect: CGRect?
        /// The live pane this matched (nil = one has to be created)
        var existing: PaneView?
        var isFloating: Bool { key.hasPrefix("f:") }
    }

    let controller: MainWindowController
    let workspace: Int
    let spec: WorkspaceSpec
    let mode: Mode
    /// Whether the caller may see a browser pane's URL (same rule as `state`): if not, nothing ever
    /// matches, so that "did it match" cannot itself become a probe for guessing URLs
    let exposesBrowser: Bool
    /// The `visibleColumns` from the screen envelope: once that level has said it, the nested
    /// workspaces do not repeat it (see `SpecCodec.screen`). Columns that leave out `width` have
    /// their width computed from **that** value, otherwise a spec saying "the screen shows 4
    /// columns and no column writes a width" lands with the widths of the current visible column
    /// count
    var visibleColumnsHint: Int?
    /// **Tests only**: throw at a given stage, to pin down "a failure after acting has to report
    /// partial honestly". Always nil in production
    var fault: ((Stage) throws -> Void)?

    private(set) var slots: [Slot] = []
    /// The panes that will be displaced (they go through the real close path)
    private(set) var displaced: [PaneView] = []
    /// The live workspace already matches this spec exactly: not a single pane has to be created
    /// or closed
    private(set) var totalMatch = false
    private(set) var didPreflight = false

    init(controller: MainWindowController, workspace: Int, spec: WorkspaceSpec, mode: Mode,
         exposesBrowser: Bool = true) {
        self.controller = controller
        self.workspace = workspace
        self.spec = spec
        self.mode = mode
        self.exposesBrowser = exposesBrowser
    }

    var existingPanes: [PaneView] {
        let model = controller.model
        let closing = model.closingPanes
        return (model.layouts[workspace].paneList + model.floatings[workspace].map(\.pane))
            .filter { !closing.contains($0.id) }
    }

    /// How many columns are visible per screen once this spec has landed
    var wantedVisibleColumns: Int {
        spec.visibleColumns ?? visibleColumnsHint ?? controller.visibleColumns
    }

    /// How wide a column that leaves out `width` should be. **Computed from the visible column
    /// count this spec asks for**, not the current one: `setVisibleColumns` only lands after the
    /// layout value has been computed (step 4 of `apply()`), so taking the current factor as the
    /// default would make a spec of "visibleColumns 4 plus no width anywhere" land with the widths
    /// of the old factor, and the next dump would no longer match the spec
    var wantedColumnFactor: Double {
        ScrollingStrip.factor(forVisibleColumns: wantedVisibleColumns)
    }

    /// The directory a newly created pane inherits: the focused pane of the target workspace
    /// first, then any pane already in that workspace, then the focused pane of this screen (with
    /// none of those, it is left to the engine's default)
    var anchorDirectory: String? {
        if workspace == controller.model.activeIndex,
           let cwd = controller.focusedPane?.workingDirectory { return cwd }
        return existingPanes.compactMap(\.workingDirectory).first
            ?? controller.focusedPane?.workingDirectory
    }

    /// Working directories preflight found that **exist but cannot be used** (a macOS protected
    /// directory with no permission granted). `spec apply` turns these into `cwd_denied` warnings
    /// in the response (or into an error under `--require-cwd`)
    private(set) var deniedDirectories: [String] = []

    // MARK: Preflight (**not a single pane built, not a single one closed**)

    func preflight() throws {
        dispatchPrecondition(condition: .onQueue(.main))
        controller.flushPendingCloses()
        deniedDirectories.removeAll()

        var built: [Slot] = []
        for item in Self.tiledSlots(spec) + Self.floatingSlots(spec) {
            let request: ControlPaneFactory.Request
            do {
                request = try Self.request(from: item.pane)
            } catch {
                let body = (error as? ControlErrorBody) ?? ControlErrorBody(.badRequest, "\(error)")
                throw ControlErrorBody(ControlErrorCode(rawValue: body.code) ?? .badRequest,
                                       "spec \(item.key): \(body.message)", hint: body.hint)
            }
            if let problem = ControlPaneFactory.directoryProblem(request.cwd) {
                throw ControlErrorBody(.badRequest, "spec \(item.key): \(problem)",
                                       hint: "Create the directory first, or change the cwd in this spec.")
            }
            // The directory exists but cannot be handed to the engine because the macOS privacy
            // permission is missing (a protected directory): **this is not an error** (the spec
            // still lays out fine), but the caller has to be told - otherwise `spec apply` quietly
            // drops every pane into the default directory.
            // (Only ask for the kinds that really consume cwd: a browser pane never does, so
            //  reporting a cwd_denied for it describes something that never happened, and
            //  `--require-cwd` would refuse the whole spec over it.)
            if let cwd = request.cwd, ControlPaneFactory.consumesWorkingDirectory(request.kind),
               WorkingDirectoryGate.usable(cwd) == nil,
               !deniedDirectories.contains(cwd) {
                deniedDirectories.append(cwd)
            }
            built.append(Slot(key: item.key, spec: item.pane, request: request, rect: item.rect))
        }
        guard built.count <= ControlRateLimiter.maxPanesPerWorkspace else {
            // `limit`, not `denied`: nobody refused this caller anything. The number is a fixed
            // ceiling, so closing a pane makes the very same request succeed - a caller that can
            // tell the two apart retries, while one that reads `denied` gives up or asks for
            // permission it does not need.
            throw ControlErrorBody(
                .limit,
                "This spec asks for \(built.count) panes, over the per-workspace limit of \(ControlRateLimiter.maxPanesPerWorkspace)")
        }
        if let columns = spec.visibleColumns, !SpecLimits.visibleColumns.contains(columns) {
            throw ControlErrorBody(.badRequest,
                                   "visibleColumns must be between \(SpecLimits.visibleColumns.lowerBound) and "
                                       + "\(SpecLimits.visibleColumns.upperBound), got \(columns)")
        }
        // The name: measured with the same ruler as `workspace set --title` - literally the same
        // one, `TitleRules` (`SpecParser` already screens it once, but the applier can also be
        // handed a `WorkspaceSpec` directly - only screening in both places earns the claim "if it
        // cannot land, nothing is touched").
        if let title = spec.title {
            guard title.count <= TitleRules.maxLength else {
                throw ControlErrorBody(.badRequest,
                                       "title is too long (\(title.count) characters, limit \(TitleRules.maxLength))")
            }
            guard TitleRules.isPrintable(title) else {
                throw ControlErrorBody(.badRequest, "title contains control characters")
            }
        }

        // The position references have to be able to land. Checked **before anything is built**:
        // when zoom points at a slot that does not exist, discovering it half way through means the
        // workspace is already half torn down.
        let keys = Set(built.map(\.key))
        for (name, ref) in [("focus", spec.focus), ("zoom", spec.zoom)] {
            guard let ref, let key = Self.key(for: ref) else { continue }
            guard keys.contains(key) else {
                throw ControlErrorBody(
                    .badRequest, "\(name) points at a position this spec does not contain (\(key))",
                    hint: "Position references: {column,row} for scrolling, {path} for dwindle, {floating} for the floating layer.",
                    candidates: built.map(\.key))
            }
        }

        // Matching: live panes that line up are kept. `--replace` only recognizes "the whole thing
        // matches" (which is a no-op) - on a partial match its semantics are "tear everything down
        // and rebuild", otherwise a caller who said replace would inexplicably be left with a pane
        // still running a dev server while believing it had just emptied the workspace.
        let live = existingPanes
        let matched = Self.match(built.map(\.spec), against: live, mode: mode, controller: controller,
                                 exposesBrowser: exposesBrowser)
        let coverage = matched.compactMap { $0 }
        totalMatch = coverage.count == built.count && coverage.count == live.count
        if mode == .reuse || totalMatch {
            for i in built.indices { built[i].existing = matched[i] }
        }
        slots = built
        let kept = Set(slots.compactMap { $0.existing.map(ObjectIdentifier.init) })
        displaced = live.filter { !kept.contains(ObjectIdentifier($0)) }
        didPreflight = true
    }

    /// The diff `--dry-run` / `--fail-if-noop` read. **Empty = it already looks like this**
    func changes(at path: String) -> [ControlChange] {
        var out: [ControlChange] = []
        let liveLayout = controller.model.layouts[workspace].name
        let wanted = spec.layoutName
        if liveLayout != wanted {
            out.append(ControlChange("\(path).layout", from: liveLayout, to: wanted))
        }
        if let columns = spec.visibleColumns, columns != controller.visibleColumns {
            out.append(ControlChange("\(path).visibleColumns",
                                     from: String(controller.visibleColumns), to: String(columns)))
        }
        // The name: **not written means leave it alone** (same rule as visibleColumns). It only
        // counts as a change when it was written and differs - otherwise a spec that never mentions
        // a name would turn the `--fail-if-noop` verdict into "there is always a change".
        if let wanted = Self.wantedTitle(spec), wanted != controller.model.title(at: workspace) {
            out.append(ControlChange("\(path).title",
                                     from: controller.model.title(at: workspace) ?? "(never named)",
                                     to: wanted ?? "(cleared)", sensitive: true))
        }
        let creating = slots.filter { $0.existing == nil }.count
        if creating > 0 || !displaced.isEmpty {
            out.append(ControlChange(
                "\(path).panes", from: ControlChange.count(existingPanes.count, "pane"),
                to: ControlChange.count(slots.count, "pane") + " (created \(creating), "
                    + "closed \(displaced.count), reused \(slots.count - creating))"))
        }
        // Nothing to create and nothing to close: **what is left is entirely "which pane sits in
        // which slot" plus the geometry**. Both of those have to be genuinely compared - `commit()`
        // simply does not act on an empty diff, so a spec that only rearranges, such as merging two
        // columns into one, would be silently dropped and reported as changed:false.
        guard creating == 0, displaced.isEmpty else { return out }
        let live = SpecCodec.workspace(controller, index: workspace, options: .init(), nested: true)

        // Arrangement: how the columns are grouped / the shape of the tree, plus which pane sits
        // in each slot (geometry stays out of this signature; column widths and split ratios each
        // get their own comparison below, and reporting them twice only makes the diff harder to
        // read).
        let tiledPlan = slots.filter { !$0.isFloating }
        let tiled = tiledPlan.compactMap(\.existing)
        if tiled.count == tiledPlan.count, let next = try? buildLayout(tiled: tiled) {
            let now = Self.arrangement(of: controller.model.layouts[workspace],
                                       closing: controller.model.closingPanes)
            let wantText = Self.arrangement(of: next, closing: [])
            if now != wantText {
                out.append(ControlChange("\(path).\(wanted == "dwindle" ? "tree" : "columns")",
                                         from: now, to: wantText))
            }
        }
        // The floating layer: order and rectangles (a spec that only moves one floating window
        // must not count as a no-op either).
        let floatingPlan = slots.filter { $0.isFloating }
        let wantFloating = buildFloatings(floatingPlan.compactMap(\.existing))
        let liveFloating = controller.model.floatings[workspace]
            .filter { !controller.model.closingPanes.contains($0.pane.id) }
        if floatingPlan.compactMap(\.existing).count == floatingPlan.count,
           Self.floatingSignature(liveFloating) != Self.floatingSignature(wantFloating) {
            out.append(ControlChange("\(path).floating",
                                     from: Self.floatingSignature(liveFloating),
                                     to: Self.floatingSignature(wantFloating)))
        }
        if let liveColumns = live.columns, let want = spec.columns {
            for (i, column) in want.enumerated() where i < liveColumns.count {
                let now = liveColumns[i].width ?? controller.columnFactor
                let next = column.width ?? wantedColumnFactor
                if abs(now - next) >= 0.0005 {
                    out.append(ControlChange("\(path).columns[\(i)].width",
                                             from: Self.number(now), to: Self.number(next)))
                }
            }
        }
        if wanted == "dwindle", let want = spec.tree {
            let now = Self.geometry(of: live.tree)
            let next = Self.geometry(of: want)
            if now != next {
                out.append(ControlChange("\(path).tree", from: now, to: next))
            }
        }
        if live.zoom != spec.zoom {
            out.append(ControlChange("\(path).zoom",
                                     from: Self.describe(live.zoom), to: Self.describe(spec.zoom)))
        }
        if spec.focus != nil, live.focus != spec.focus {
            out.append(ControlChange("\(path).focus",
                                     from: Self.describe(live.focus), to: Self.describe(spec.focus)))
        }
        return out
    }

    // MARK: Applying

    func apply() throws -> Outcome {
        dispatchPrecondition(condition: .onQueue(.main))
        precondition(didPreflight, "SpecApplier.apply() requires preflight() to have run first")
        var outcome = Outcome()

        // 1) Build. **This is the only step that can fail, which is why it comes before the
        //    teardown**: on failure the panes built in this batch are cleaned up and not a byte of
        //    the workspace has moved.
        var madeList: [ControlPaneFactory.Made] = []
        var panes: [PaneView] = []
        do {
            try fault?(.creating)
            for slot in slots {
                if let existing = slot.existing {
                    panes.append(existing)
                    outcome.reused.append(existing)
                    continue
                }
                let made = try ControlPaneFactory.make(slot.request, controller: controller,
                                                       inheriting: anchorDirectory)
                if let browser = made.pane as? BrowserPaneView { Self.restoreTabs(slot.spec, in: browser) }
                madeList.append(made)
                panes.append(made.pane)
                outcome.created.append(made.pane)
            }

            // 2) Compute the whole layout value (reuse column ids wherever possible: the moment
            //    `ScrollingStrip.Column.id` changes, SwiftUI rebuilds the entire column and the
            //    SurfaceViews inside it detach and re-attach - one frame of flicker and a silently
            //    reset first responder).
            try fault?(.assembling)
        } catch {
            for made in madeList { ControlPaneFactory.discard(made, controller: controller) }
            throw Self.body(error, partial: false)
        }
        let tiledCount = slots.filter { !$0.isFloating }.count
        let layout: WorkspaceLayout
        let floatings: [FloatingPane]
        do {
            layout = try buildLayout(tiled: Array(panes.prefix(tiledCount)))
            floatings = buildFloatings(Array(panes.suffix(from: tiledCount)))
        } catch {
            for made in madeList { ControlPaneFactory.discard(made, controller: controller) }
            throw Self.body(error, partial: false)
        }

        // 3) Tear down: a displaced pane always goes through the **real close path** (a browser
        //    pane's paneWillClose and the file manager's session cleanup both live on that path).
        do {
            for pane in displaced {
                outcome.closed.append(ControlHandleRegistry.shared.handle(for: pane))
                if workspace == controller.model.activeIndex {
                    controller.closePane(pane, confirmIfNeeded: false, animated: false)
                } else {
                    controller.removeFromAnyWorkspace(pane)
                }
                try fault?(.tearingDown)
            }
            controller.flushPendingCloses()
        } catch {
            // We have already mutated: clean up the panes built in this batch (they never made it
            // into any layout) and report partial honestly - never pretend nothing happened.
            for made in madeList { ControlPaneFactory.discard(made, controller: controller) }
            controller.flushPendingCloses()
            throw Self.body(error, partial: !outcome.closed.isEmpty)
        }

        // 4) One assignment. The visible column count has to land **first** (it re-lays out every
        //    scrolling workspace with the new factor, so in the other order it would wash away the
        //    column widths from the spec).
        if let columns = spec.visibleColumns, columns != controller.visibleColumns {
            controller.setVisibleColumns(columns, persist: true)
        }
        if let wanted = Self.wantedTitle(spec) { controller.model.setTitle(wanted, at: workspace) }
        controller.model.layouts[workspace] = layout
        if !floatings.isEmpty || !controller.model.floatings[workspace].isEmpty {
            controller.model.floatings[workspace] = floatings
        }
        for made in madeList { ControlPaneFactory.register(made, controller: controller) }

        // 5) Focus (only meaningful for the active workspace: never hand focus to a workspace that
        //    is not mounted).
        let focus = Self.key(for: spec.focus).flatMap { key in
            slots.firstIndex { $0.key == key }.map { panes[$0] }
        } ?? panes.first
        outcome.focus = focus
        if workspace == controller.model.activeIndex, let focus {
            controller.requestFocus(to: focus)
        }
        return outcome
    }

    /// What this spec wants the name set to. An outer nil = the spec never mentions a name (leave
    /// it alone); an inner nil (an empty string was written) = clear the name
    nonisolated static func wantedTitle(_ spec: WorkspaceSpec) -> String?? {
        guard let title = spec.title else { return nil }
        return .some(TitleRules.normalized(title))
    }

    // MARK: Assembly (pure value computation)

    private func buildLayout(tiled: [PaneView]) throws -> WorkspaceLayout {
        switch spec.layoutName {
        case "dwindle":
            guard let tree = spec.tree, !tiled.isEmpty else {
                return .dwindle(SplitTree<PaneView>(root: nil, zoomed: nil))
            }
            var cursor = 0
            let root = try Self.buildNode(tree, panes: tiled, cursor: &cursor)
            let built = SplitTree<PaneView>(root: root, zoomed: nil)
            guard let zoomKey = Self.key(for: spec.zoom),
                  let index = slots.firstIndex(where: { $0.key == zoomKey }), index < tiled.count,
                  let node = built.root?.node(view: tiled[index]) else { return .dwindle(built) }
            return .dwindle(SplitTree<PaneView>(root: built.root, zoomed: node))
        default:
            var strip = ScrollingStrip()
            var cursor = 0
            var previous: [Set<UUID>: UUID] = [:]
            if case .scrolling(let live) = controller.model.layouts[workspace] {
                for column in live.columns where previous[Set(column.panes.map(\.id))] == nil {
                    previous[Set(column.panes.map(\.id))] = column.id
                }
            }
            for column in spec.columns ?? [] {
                let count = column.panes?.count ?? 1
                guard cursor + count <= tiled.count else { break }
                let panes = Array(tiled[cursor..<(cursor + count)])
                cursor += count
                var built = ScrollingStrip.Column(panes: panes,
                                                  widthFactor: column.width ?? wantedColumnFactor)
                if let id = previous[Set(panes.map(\.id))] { built.id = id }
                strip.columns.append(built)
            }
            if let zoomKey = Self.key(for: spec.zoom),
               let index = slots.firstIndex(where: { $0.key == zoomKey }), index < tiled.count {
                strip.zoomedID = tiled[index].id
            }
            return .scrolling(strip)
        }
    }

    private func buildFloatings(_ panes: [PaneView]) -> [FloatingPane] {
        let specs = spec.floating ?? []
        return panes.enumerated().map { i, pane in
            let rect = i < specs.count ? Self.rect(specs[i].rect) : nil
            return FloatingPane(pane: pane,
                                rect: rect ?? FloatingPane.defaultRect(columnFactor: controller.columnFactor))
                .clamped()
        }
    }

    private static func buildNode(_ node: NodeSpec, panes: [PaneView],
                                  cursor: inout Int) throws -> SplitTree<PaneView>.Node {
        switch node {
        case .leaf:
            guard cursor < panes.count else {
                throw ControlErrorBody(.internalError, "Leaf count does not line up while assembling the dwindle tree")
            }
            defer { cursor += 1 }
            return .leaf(view: panes[cursor])
        case .split(let split):
            let left = try buildNode(split.a, panes: panes, cursor: &cursor)
            let right = try buildNode(split.b, panes: panes, cursor: &cursor)
            let direction: SplitTree<PaneView>.Direction =
                split.direction == "vertical" ? .vertical : .horizontal
            return .split(.init(direction: direction, ratio: split.ratio ?? 0.5,
                                left: left, right: right))
        }
    }

    /// The remaining tabs of a browser pane. Construction opens `tabs[0]` (see `request(from:)`),
    /// and this fills in the rest in order, then makes the one `url` points at the active tab
    private static func restoreTabs(_ spec: PaneSpec, in pane: BrowserPaneView) {
        guard let tabs = spec.tabs, tabs.count > 1 else { return }
        // `resolveURL` rather than `url(forInput:)`: what a dump produces are absolute URLs, and
        // handing a scheme like an extension page's to the address-bar heuristics turns it into a
        // search (see ControlPaneFactory.passthroughSchemes).
        let urls = tabs.compactMap { ControlPaneFactory.resolveURL($0) }
        for url in urls.dropFirst() { _ = pane.addTab(url: url, activate: false) }
        let active = spec.url.flatMap { raw in urls.firstIndex { $0.absoluteString == raw } } ?? 0
        if pane.tabs.indices.contains(active) { pane.selectTab(at: active) }
    }

    // MARK: Walking (**building and assembly have to use the same order**)

    /// The slots of the tiled layer: scrolling goes column by column, top to bottom within a
    /// column; dwindle is a depth-first walk of a -> b
    nonisolated static func tiledSlots(_ spec: WorkspaceSpec) -> [SlotSpec] {
        var out: [SlotSpec] = []
        switch spec.layoutName {
        case "dwindle":
            guard let tree = spec.tree else { return [] }
            walk(tree, path: "", into: &out)
        default:
            for (c, column) in (spec.columns ?? []).enumerated() {
                for (r, pane) in (column.panes ?? [PaneSpec()]).enumerated() {
                    out.append(SlotSpec(key: "c:\(c).\(r)", pane: pane))
                }
            }
        }
        return out
    }

    nonisolated static func floatingSlots(_ spec: WorkspaceSpec) -> [SlotSpec] {
        (spec.floating ?? []).enumerated().map { i, item in
            SlotSpec(key: "f:\(i)", pane: item.pane ?? PaneSpec(), rect: rect(item.rect))
        }
    }

    nonisolated private static func walk(_ node: NodeSpec, path: String, into out: inout [SlotSpec]) {
        switch node {
        case .leaf(let pane):
            out.append(SlotSpec(key: "p:\(path)", pane: pane))
        case .split(let split):
            walk(split.a, path: path.isEmpty ? "a" : path + ".a", into: &out)
            walk(split.b, path: path.isEmpty ? "b" : path + ".b", into: &out)
        }
    }

    nonisolated static func key(for ref: PaneRef?) -> String? {
        guard let ref else { return nil }
        if let floating = ref.floating { return "f:\(floating)" }
        if let path = ref.path { return "p:\(path)" }
        if let column = ref.column { return "c:\(column).\(ref.row ?? 0)" }
        if let row = ref.row { return "c:0.\(row)" }
        return nil
    }

    nonisolated static func rect(_ numbers: [Double]?) -> CGRect? {
        guard let numbers, numbers.count == 4 else { return nil }
        return CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3])
    }

    /// The **arrangement** signature of a layout (how the columns are grouped / the shape of the
    /// tree, plus which pane sits in each slot, **with no geometry**). This is how `changes()`
    /// spots "not a single pane changed, they were only rearranged" - without it, a spec like that
    /// would be dropped by `commit()` as a no-op
    static func arrangement(of layout: WorkspaceLayout, closing: Set<UUID>) -> String {
        switch layout {
        case .scrolling(let strip):
            return strip.columns
                .map { column in
                    column.panes.filter { !closing.contains($0.id) }
                        .map { ControlHandleRegistry.shared.handle(for: $0) }
                        .joined(separator: ",")
                }
                .filter { !$0.isEmpty }
                .joined(separator: " | ")
        case .dwindle(let tree):
            return arrangement(of: tree.root, closing: closing)
        }
    }

    private static func arrangement(of node: SplitTree<PaneView>.Node?, closing: Set<UUID>) -> String {
        guard let node else { return "empty" }
        switch node {
        case .leaf(let view):
            // A leaf that is fading out counts as already gone (the same collapse rule as
            // `SpecCodec.node`).
            return closing.contains(view.id) ? "" : ControlHandleRegistry.shared.handle(for: view)
        case .split(let split):
            let a = arrangement(of: split.left, closing: closing)
            let b = arrangement(of: split.right, closing: closing)
            if a.isEmpty { return b }
            if b.isEmpty { return a }
            return "(\(a),\(b))"
        }
    }

    /// The signature of the floating layer: the order plus each rectangle (pinned to 3 decimal
    /// places, the same precision as the numbers in a diff)
    static func floatingSignature(_ items: [FloatingPane]) -> String {
        items.map { item in
            let rect = item.rect
            return ControlHandleRegistry.shared.handle(for: item.pane)
                + "@" + [rect.origin.x, rect.origin.y, rect.size.width, rect.size.height]
                    .map { number(Double($0)) }.joined(separator: ",")
        }.joined(separator: " ")
    }

    /// The **geometry** signature of a tree (shape + direction + ratios, with no pane content): the
    /// diff uses it to decide "only the ratios changed"
    nonisolated static func geometry(of node: NodeSpec?) -> String {
        guard let node else { return "empty" }
        switch node {
        case .leaf: return "·"
        case .split(let split):
            let direction = split.direction == "vertical" ? "vertical" : "horizontal"
            return "\(direction) \(number(split.ratio ?? 0.5))(\(geometry(of: split.a)),\(geometry(of: split.b)))"
        }
    }

    // MARK: Matching (`--reuse` and the "the whole thing already matches" verdict)

    /// Every slot of the spec -> a live pane (or nil = one has to be created). Three rounds, each
    /// looser than the last:
    /// (1) an exact `id` hit (a spec produced by `dump --include-ids`) - **only under `--reuse`**,
    ///     and the kind still has to match;
    /// (2) same kind + same cwd / same URL;
    /// (3) same kind, and the slot **writes neither a command nor a cwd/URL** ("just give me a
    ///     terminal").
    /// A slot that writes a command is "something that has to be running": outside `--reuse` an
    /// existing shell is never used to satisfy it (doing so would mean that command never ran once
    /// while the caller was told "success, nothing changed").
    /// Each live pane is used at most once
    static func match(_ specs: [PaneSpec], against live: [PaneView], mode: Mode,
                      controller: MainWindowController, exposesBrowser: Bool) -> [PaneView?] {
        var out = [PaneView?](repeating: nil, count: specs.count)
        var used = Set<ObjectIdentifier>()

        func take(_ index: Int, _ pane: PaneView) {
            out[index] = pane
            used.insert(ObjectIdentifier(pane))
        }
        func available() -> [PaneView] { live.filter { !used.contains(ObjectIdentifier($0)) } }

        // A slot that writes a command is "something that has to be running". `--replace` means
        // tear down and rebuild: satisfying it with an existing shell would mean that command never
        // ran once while the caller was told "success, nothing changed".
        // `--reuse` is the other way round - "whatever matches stays where it is" is exactly the
        // path for "retrying must not restart the dev server".
        func wantsFreshProcess(_ spec: PaneSpec) -> Bool { spec.cmd != nil && mode != .reuse }

        // (1) id: **only under `--reuse`**. An id names one specific pane, and reuse is the only
        // mode that honors such naming; honoring it elsewhere means `dump --include-ids` -> edit
        // one cwd -> `apply --replace` matches every slot by id, so the edit is dropped wholesale
        // and reported as "it already looks like this".
        if mode == .reuse {
            for (i, spec) in specs.enumerated() {
                guard let raw = spec.id, let id = UUID(uuidString: raw) else { continue }
                if let hit = available().first(where: {
                    $0.id == id && kind(of: spec) == liveKind($0, controller: controller)
                }) { take(i, hit) }
            }
        }
        for (i, spec) in specs.enumerated() where out[i] == nil && !wantsFreshProcess(spec) {
            if let hit = available().first(where: {
                identityMatches(spec, $0, controller: controller, exposesBrowser: exposesBrowser)
            }) { take(i, hit) }
        }
        for (i, spec) in specs.enumerated() where out[i] == nil && spec.cmd == nil {
            if let hit = available().first(where: {
                kind(of: spec) == liveKind($0, controller: controller) && looseMatch(spec, $0)
            }) { take(i, hit) }
        }
        return out
    }

    nonisolated static func kind(of spec: PaneSpec) -> String { spec.kind ?? "terminal" }

    /// A file-manager pane is just a terminal running yazi: in a spec it is a kind of its own, and
    /// using one to satisfy a plain terminal would drag the "quitting opens a terminal in its
    /// place" semantics along with it
    static func liveKind(_ pane: PaneView, controller: MainWindowController) -> String {
        controller.controlRole(of: pane) == "file-manager" ? "file-manager" : pane.kind.rawValue
    }

    /// The same thing: the kinds are equal and a terminal's cwd / a browser's URL lines up
    static func identityMatches(_ spec: PaneSpec, _ pane: PaneView,
                                controller: MainWindowController, exposesBrowser: Bool) -> Bool {
        guard kind(of: spec) == liveKind(pane, controller: controller) else { return false }
        if let browser = pane as? BrowserPaneView {
            // A caller without a token cannot read a live pane's URL, so nothing ever matches
            // (rebuild rather than let "did it match" become a probe for guessing URLs).
            guard exposesBrowser, let wanted = spec.url else { return false }
            // Compare after normalization: a hand-written spec says `http://localhost:3000` while
            // the live pane reports `http://localhost:3000/`. Compared literally they would never
            // match, so every apply would tear down and rebuild a pane that is already sitting on
            // the target page.
            return ControlPaneFactory.sameURL(browser.currentURL,
                                              ControlPaneFactory.resolveURL(wanted))
        }
        guard let cwd = spec.cwd, let live = pane.workingDirectory else { return false }
        return samePath(cwd, live)
    }

    /// The third round: that slot of the spec writes no cwd / URL
    nonisolated static func looseMatch(_ spec: PaneSpec, _ pane: PaneView) -> Bool {
        pane is BrowserPaneView ? spec.url == nil : spec.cwd == nil
    }

    /// Path comparison always resolves down to the physical path: `/tmp` and `/private/tmp` are
    /// the same directory, and the shell's OSC 7 reports the latter - without resolving, every
    /// apply would rebuild the pane
    nonisolated static func samePath(_ a: String, _ b: String) -> Bool {
        resolved(a) == resolved(b)
    }

    nonisolated static func resolved(_ path: String) -> String {
        URL(fileURLWithPath: SpecValidator.normalizedPath(path)).resolvingSymlinksInPath().path
    }

    // MARK: Parts

    static func request(from spec: PaneSpec) throws -> ControlPaneFactory.Request {
        var request = ControlPaneFactory.Request()
        request.kind = kind(of: spec)
        request.cwd = spec.cwd.map { SpecValidator.normalizedPath($0) }
        request.cmd = spec.cmd
        request.hold = spec.hold ?? false
        request.env = spec.env ?? [:]
        // A multi-tab browser pane starts from tabs[0] (restoreTabs fills in the rest), which keeps
        // the tab order identical to what was dumped. A wrong kind (a terminal that wrote a url) is
        // left to the factory to reject - that mutual-exclusion rule lives in exactly one place.
        request.url = spec.tabs?.first ?? spec.url
        try ControlPaneFactory.validate(request)
        return request
    }

    nonisolated static func describe(_ ref: PaneRef?) -> String {
        guard let ref, let key = key(for: ref) else { return "none" }
        return key
    }

    nonisolated static func number(_ value: Double) -> String { String(format: "%.3f", value) }

    /// Normalize whatever was thrown into a `ControlErrorBody`; a failure after acting gets its own
    /// **separate error code**, so an agent can tell "nothing happened" from "half of it changed"
    /// by `code` alone, without having to read the prose
    nonisolated static func body(_ error: any Error, partial: Bool) -> ControlErrorBody {
        let base = (error as? ControlErrorBody) ?? ControlErrorBody(.failed, "\(error)")
        // If an inner layer already reported partial, pass it out unchanged: two layers of prefix
        // only make the message harder to read, and the code is the same either way.
        guard partial, base.code != ControlErrorCode.partialApply.rawValue else { return base }
        return ControlErrorBody(
            .partialApply, "spec was only half applied: \(base.message)",
            hint: "The workspace has already been changed: the old panes are closed and the new layout never landed. "
                + "Run quickterm spec dump to see where things stand, then decide whether to resend or clean up.")
    }
}
