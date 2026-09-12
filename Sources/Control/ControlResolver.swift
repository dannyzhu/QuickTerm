import AppKit

/// Target resolution: turning `screen:workspace.pane` into a real controller / workspace index
/// / PaneView.
///
/// Two rules that do not bend:
/// 1. **More than one match is always an error, with the candidates listed** — never "take the
///    first one": silently hitting a different target is the worst failure there is in an agent
///    setting;
/// 2. a pane that is fading out (`model.closingPanes`) is not addressable.
@MainActor
struct ControlResolver {
    let screens: ScreenRegistry
    let origin: ControlRequestOrigin?
    /// The same decision as `ControlStateEncoder.exposesBrowser`. While redaction is in force,
    /// browser panes **stay out of the `title:~` candidate pool**: otherwise the predicate is
    /// itself an oracle for probing a title one character at a time (and `unique()` hands back
    /// the number of matches too, so there is not even a boolean left to guess). Without this,
    /// `expose-browser = "never"` says no and `state` redacts, while this path hands the title
    /// over anyway
    var exposesBrowser: Bool = true

    /// One matching budget, shared by the whole `title:~` command. The caller's regex runs on
    /// the main thread, and ICU is a backtracking engine with **neither a time limit nor a cap
    /// on backtracking steps** by default: seven bytes of `(.|.)+z` against one ordinary
    /// 60-character prompt title will pin the main thread for hours, freezing the entire app —
    /// every screen, terminal rendering, the control socket, the confirmation alert itself —
    /// with nothing left but Force Quit.
    /// And `title:` arrives as a read command: no token, no confirmation, no rate limit either
    static let titleMatchBudget: TimeInterval = 0.2
    /// Length ceiling on the pattern itself (a compile-time backstop; the real guardrail is the
    /// budget above)
    static let maxTitlePatternLength = 512

    struct Resolution {
        var controller: MainWindowController
        /// Zero-based internally (the CLI only ever sees one-based)
        var workspace: Int
        var pane: PaneView?
        var echo: ResolvedTarget
    }

    /// Locate a pane: which screen, and which workspace (zero-based) within it
    static func locate(_ pane: PaneView, in screens: ScreenRegistry) -> (MainWindowController, Int)? {
        for controller in screens.controllers {
            let model = controller.model
            for i in model.layouts.indices where model.layouts[i].paneList.contains(where: { $0 === pane }) {
                return (controller, i)
            }
            for i in model.floatings.indices where model.floatings[i].contains(where: { $0.pane === pane }) {
                return (controller, i)
            }
        }
        return nil
    }

    /// Every addressable pane (fading-out ones excluded, as is the Scratchpad, which belongs to
    /// no workspace)
    static func addressablePanes(in screens: ScreenRegistry) -> [(pane: PaneView, controller: MainWindowController, workspace: Int)] {
        var out: [(PaneView, MainWindowController, Int)] = []
        for controller in screens.controllers {
            let model = controller.model
            for i in model.layouts.indices {
                for pane in model.layouts[i].paneList where !model.closingPanes.contains(pane.id) {
                    out.append((pane, controller, i))
                }
                for floating in model.floatings[i] where !model.closingPanes.contains(floating.pane.id) {
                    out.append((floating.pane, controller, i))
                }
            }
        }
        return out.map { (pane: $0.0, controller: $0.1, workspace: $0.2) }
    }

    /// One title match, under budget. **nil means the budget ran out** — and the caller then
    /// has to fail the whole command.
    ///
    /// `.reportProgress` is the only opening `NSRegularExpression` gives you to abort a long
    /// match: `uregex_setTimeLimit` is not exposed through it, and "throw it on a background
    /// thread with a timeout" only leaks an ICU thread that is pinning a CPU and cannot be
    /// stopped — the DoS is still there.
    /// It is a static method so tests can nail this guardrail down without a window
    static func titleMatches(_ title: String, regex: NSRegularExpression, deadline: Date) -> Bool? {
        var hit = false
        var timedOut = false
        regex.enumerateMatches(in: title, options: [.reportProgress],
                               range: NSRange(title.startIndex..., in: title)) { result, _, stop in
            if result != nil {
                hit = true
                stop.pointee = true
            } else if Date() > deadline {
                timedOut = true
                stop.pointee = true
            }
        }
        return timedOut ? nil : hit
    }

    func handle(_ pane: PaneView) -> String { ControlHandleRegistry.shared.handle(for: pane) }

    // MARK: Context

    /// The pane the caller is in (`QUICKTERM_PANE`); it counts only if it is a PaneView that is
    /// alive right now
    private func originPane() -> (PaneView, MainWindowController, Int)? {
        guard let raw = origin?.pane, let uuid = UUID(uuidString: raw) else { return nil }
        for entry in Self.addressablePanes(in: screens) where entry.pane.id == uuid {
            return (entry.pane, entry.controller, entry.workspace)
        }
        return nil
    }

    /// The context screen: explicit -t → the caller's own pane → controlCurrent (the key window
    /// only counts while NSApp.isActive) → primary
    private func contextController() throws -> MainWindowController {
        if let (_, controller, _) = originPane() { return controller }
        guard let controller = screens.controlCurrent else {
            throw ControlErrorBody(.notFound, "No screens at all", hint: "QuickTerm needs at least one window.")
        }
        return controller
    }

    // MARK: Main entry point

    func resolve(_ target: ControlTarget?) throws -> Resolution {
        let target = target ?? ControlTarget()

        // 1) Screen
        var controller: MainWindowController?
        if let screenRef = target.screen {
            controller = try resolveScreen(screenRef)
        }

        // 2) The pane decides where this lands first: a handle / uuid / predicate is globally
        //    unique, so it needs no context
        var pane: PaneView?
        var paneWorkspace: Int?
        if let paneRef = target.pane, Self.isGlobalRef(paneRef) {
            let found = try resolveGlobalPane(paneRef, scopedTo: controller,
                                              workspace: target.workspace, screenGiven: target.screen != nil)
            pane = found.pane
            paneWorkspace = found.workspace
            if let existing = controller, existing !== found.controller {
                throw ControlErrorBody(
                    .badTarget,
                    "pane \(handle(found.pane)) is on screen \(found.controller.screenIndex + 1), which does not match screen \(existing.screenIndex + 1) in the target",
                    hint: "Drop the screen prefix, or address it as \(found.controller.screenIndex + 1):…")
            }
            controller = found.controller
        }

        let host = try controller ?? contextController()

        // 3) Workspace
        let workspaceIndex: Int
        if let workspaceRef = target.workspace {
            workspaceIndex = try resolveWorkspace(workspaceRef, in: host)
            if let paneWorkspace, paneWorkspace != workspaceIndex {
                throw ControlErrorBody(
                    .badTarget,
                    "pane \(pane.map { handle($0) } ?? "?") is in workspace \(paneWorkspace + 1), which does not match workspace \(workspaceIndex + 1) in the target",
                    hint: "Drop the workspace prefix.")
            }
        } else if let paneWorkspace {
            workspaceIndex = paneWorkspace
        } else if let (_, originController, originWorkspace) = originPane(), originController === host {
            workspaceIndex = originWorkspace
        } else {
            workspaceIndex = host.model.activeIndex
        }

        // 4) Relational / @focused / @self (these need the context before they can be resolved)
        if pane == nil, let paneRef = target.pane {
            pane = try resolveContextualPane(paneRef, in: host, workspace: workspaceIndex)
        }

        return Resolution(
            controller: host,
            workspace: workspaceIndex,
            pane: pane,
            echo: ResolvedTarget(
                screen: host.screenIndex + 1,
                screenID: host.windowID.uuidString,
                workspace: workspaceIndex + 1,
                pane: pane.map { handle($0) },
                paneID: pane?.id.uuidString))
    }

    static func isGlobalRef(_ ref: ControlTarget.PaneRef) -> Bool {
        switch ref {
        case .handle, .id, .title, .cwd, .kind, .role: true
        case .focused, .selfPane, .direction, .cycle: false
        }
    }

    // MARK: The individual segments

    func resolveScreen(_ ref: ControlTarget.ScreenRef) throws -> MainWindowController {
        switch ref {
        case .index(let n):
            guard let controller = screens.controller(screenNumber: n) else {
                let available = screens.controllers.map { String($0.screenIndex + 1) }.sorted()
                throw ControlErrorBody(.notFound, "No screen numbered \(n)",
                                       hint: "Screens available: \(available.joined(separator: ", "))",
                                       candidates: available)
            }
            return controller
        case .id(let raw):
            let matches = screens.controllers.filter {
                $0.windowID.uuidString.lowercased().hasPrefix(raw.lowercased())
            }
            if matches.count > 1 {
                throw ControlErrorBody(.ambiguousTarget, "#\(raw) matches \(matches.count) screens",
                                       hint: "Give more of the uuid.",
                                       candidates: matches.map { $0.windowID.uuidString })
            }
            guard let controller = matches.first else {
                throw ControlErrorBody(.notFound, "No screen whose id starts with \(raw)")
            }
            return controller
        case .current:
            guard let controller = screens.controlCurrent else {
                throw ControlErrorBody(.notFound, "No screens at all")
            }
            return controller
        case .primary:
            guard let controller = screens.primary else {
                throw ControlErrorBody(.notFound, "No screens at all")
            }
            return controller
        }
    }

    func resolveWorkspace(_ ref: ControlTarget.WorkspaceRef, in controller: MainWindowController) throws -> Int {
        let count = controller.model.layouts.count
        switch ref {
        case .index(let n):
            guard n >= 1, n <= count else {
                throw ControlErrorBody(
                    .notFound, "Workspace \(n) does not exist: screen \(controller.screenIndex + 1) "
                        + "currently has \(count) (1–\(count))",
                    hint: "Raise workspaces (1–10) in ~/.config/quickterm/config.toml to get more")
            }
            return n - 1
        case .active:
            return controller.model.activeIndex
        case .next:
            return (controller.model.activeIndex + 1) % count
        case .prev:
            return (controller.model.activeIndex + count - 1) % count
        }
    }

    /// A global reference (handle / uuid / predicate)
    private func resolveGlobalPane(_ ref: ControlTarget.PaneRef, scopedTo controller: MainWindowController?,
                                   workspace: ControlTarget.WorkspaceRef?, screenGiven: Bool)
        throws -> (pane: PaneView, controller: MainWindowController, workspace: Int) {
        var pool = Self.addressablePanes(in: screens)
        if let controller { pool = pool.filter { $0.controller === controller } }
        if let controller, let workspace, let index = try? resolveWorkspace(workspace, in: controller) {
            pool = pool.filter { $0.workspace == index }
        }

        func fail(_ description: String) -> ControlErrorBody {
            ControlErrorBody(.notFound, "No pane matches \(description)",
                             hint: "quickterm list panes shows the handles that exist.")
        }

        switch ref {
        case .handle(let h):
            guard let id = ControlHandleRegistry.shared.paneID(forHandle: h) else { throw fail(h) }
            guard let entry = pool.first(where: { $0.pane.id == id }) else { throw fail(h) }
            return (entry.pane, entry.controller, entry.workspace)

        case .id(let raw):
            let needle = raw.lowercased()
            let matches = pool.filter { $0.pane.id.uuidString.lowercased().hasPrefix(needle) }
            if matches.count > 1 {
                throw ControlErrorBody(.ambiguousTarget, "#\(raw) matches \(matches.count) panes",
                                       hint: "Give more of the uuid, or use the short handle instead.",
                                       candidates: matches.map { handle($0.pane) })
            }
            guard let entry = matches.first else { throw fail("#\(raw)") }
            return (entry.pane, entry.controller, entry.workspace)

        case .title(let pattern):
            guard pattern.utf16.count <= Self.maxTitlePatternLength else {
                throw ControlErrorBody(.badTarget,
                                       "The title:~ pattern is too long (limit \(Self.maxTitlePatternLength) characters)",
                                       hint: "Use -t <handle> instead.")
            }
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                throw ControlErrorBody(.badTarget, "title:~\(pattern) is not a valid regular expression")
            }
            // While redaction is in force, move browser panes out of the candidate pool
            // entirely — both the match count and not_found have to be computed over the safe
            // pool, or "how many matched" on its own is enough to read a redacted title back one
            // character at a time
            let searchable = exposesBrowser ? pool : pool.filter { !($0.pane is BrowserPaneView) }
            // One budget for the whole command; N panes must not multiply it by N
            let deadline = Date().addingTimeInterval(Self.titleMatchBudget)
            var matches: [(pane: PaneView, controller: MainWindowController, workspace: Int)] = []
            for entry in searchable {
                // On timeout **the whole command fails**: computing ambiguity / not_found over
                // a pool that was only half walked is precisely the "silently answer wrong" this
                // design forbids outright
                guard let hit = Self.titleMatches(entry.pane.paneTitle, regex: regex, deadline: deadline) else {
                    throw ControlErrorBody(.badTarget, "title:~\(pattern) timed out while matching (runaway regex backtracking)",
                                           hint: "Drop the nested quantifiers such as (a|aa)+ or (.|.)+, or just use -t <handle>")
                }
                if hit { matches.append(entry) }
            }
            return try unique(matches, description: "title:~\(pattern)")

        case .cwd(let prefix):
            let expanded = (prefix as NSString).expandingTildeInPath
            return try unique(pool.filter { ($0.pane.workingDirectory ?? "").hasPrefix(expanded) },
                              description: "cwd:\(prefix)")

        case .kind(let kind):
            return try unique(pool.filter { $0.pane.kind.rawValue == kind }, description: "kind:\(kind)")

        case .role(let role):
            return try unique(pool.filter { $0.controller.controlRole(of: $0.pane) == role },
                              description: "role:\(role)")

        case .focused, .selfPane, .direction, .cycle:
            throw ControlErrorBody(.internalError, "A relational target must not go through global resolution")
        }
    }

    private func unique(_ matches: [(pane: PaneView, controller: MainWindowController, workspace: Int)],
                        description: String)
        throws -> (pane: PaneView, controller: MainWindowController, workspace: Int) {
        if matches.count > 1 {
            throw ControlErrorBody(.ambiguousTarget, "\(matches.count) panes match \(description)",
                                   hint: "Name one exactly with -t <handle>",
                                   candidates: matches.map { handle($0.pane) })
        }
        guard let only = matches.first else {
            throw ControlErrorBody(.notFound, "No pane matches \(description)",
                                   hint: "quickterm list panes shows the handles that exist.")
        }
        return only
    }

    /// Relational references (these need the context)
    private func resolveContextualPane(_ ref: ControlTarget.PaneRef, in controller: MainWindowController,
                                       workspace: Int) throws -> PaneView {
        switch ref {
        case .selfPane:
            guard let (pane, _, _) = originPane() else {
                throw ControlErrorBody(.notFound, "@self could not be resolved: no usable QUICKTERM_PANE",
                                       hint: "Run this inside a QuickTerm pane, or use -t <handle> instead.")
            }
            return pane

        case .focused:
            guard let pane = focusedAddressablePane(in: controller, workspace: workspace) else {
                throw ControlErrorBody(.notFound, "Workspace \(workspace + 1) has no addressable pane")
            }
            return pane

        case .direction(let direction):
            guard let from = focusedAddressablePane(in: controller, workspace: workspace) else {
                throw ControlErrorBody(.notFound, "No focused pane, so @\(direction.rawValue) cannot be resolved")
            }
            guard let target = Self.neighbour(of: from, direction: direction,
                                              layout: controller.model.layouts[workspace]) else {
                throw ControlErrorBody(.notFound, "There is no pane @\(direction.rawValue) of \(handle(from))")
            }
            return target

        case .cycle(let next):
            guard let from = focusedAddressablePane(in: controller, workspace: workspace) else {
                throw ControlErrorBody(.notFound, "No focused pane, so @\(next ? "next" : "prev") cannot be resolved")
            }
            guard let target = Self.cycled(from: from, next: next,
                                           layout: controller.model.layouts[workspace]) else {
                throw ControlErrorBody(.notFound, "The workspace has only one pane, so there is nothing to cycle to")
            }
            return target

        default:
            throw ControlErrorBody(.internalError, "A global reference must not go through contextual resolution")
        }
    }

    /// The focused pane, fading-out ones excluded; when the workspace is not the active one,
    /// fall back to that workspace's first pane
    private func focusedAddressablePane(in controller: MainWindowController, workspace: Int) -> PaneView? {
        let model = controller.model
        let panes = model.layouts[workspace].paneList + model.floatings[workspace].map(\.pane)
        let live = panes.filter { !model.closingPanes.contains($0.id) }
        if workspace == model.activeIndex, let focused = controller.focusedPane,
           live.contains(where: { $0 === focused }) {
            return focused
        }
        return live.first
    }

    static func neighbour(of pane: PaneView, direction: ControlTarget.Direction,
                          layout: WorkspaceLayout) -> PaneView? {
        let strip: ScrollingStrip.Direction = switch direction {
        case .left: .left
        case .right: .right
        case .up: .up
        case .down: .down
        }
        // The Direction → Spatial.Direction mapping inside MainWindowController is fileprivate,
        // so this carries its own copy rather than widening that visibility (the mapping is the
        // identity, so there is no room for the two to drift apart)
        let spatial: SplitTree<PaneView>.Spatial.Direction = switch direction {
        case .left: .left
        case .right: .right
        case .up: .up
        case .down: .down
        }
        switch layout {
        case .scrolling(let s):
            return s.focusTarget(from: pane, direction: strip)
        case .dwindle(let tree):
            guard let node = tree.root?.node(view: pane) else { return nil }
            return tree.focusTarget(for: .spatial(spatial), from: node)
        }
    }

    static func cycled(from pane: PaneView, next: Bool, layout: WorkspaceLayout) -> PaneView? {
        switch layout {
        case .scrolling(let s):
            return s.linearTarget(from: pane, next: next)
        case .dwindle(let tree):
            guard let node = tree.root?.node(view: pane) else { return nil }
            return tree.focusTarget(for: next ? .next : .previous, from: node)
        }
    }
}
