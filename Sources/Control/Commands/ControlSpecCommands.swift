import AppKit

/// `spec dump|validate|apply` - composition in one shot.
///
/// This is the path an agent should reach for above all others in the control plane: **lay out a
/// whole workspace in a single call** instead of firing N `pane new` commands and then adjusting
/// widths one by one (N commands = N relayouts, N animations, N failure points, and a failure part
/// way through leaves behind a half-built thing nobody can describe).
@MainActor
extension ControlCommandRunner {
    func runSpec(_ ctx: ControlContext) throws -> (echo: ResolvedTarget?, data: any Encodable) {
        switch ctx.spec.verb {
        case "dump": return try specDump(ctx)
        case "validate": return try specValidate(ctx)
        case "apply": return try specApply(ctx)
        default: throw ControlErrorBody(.unknownCommand, "spec has no verb \(ctx.spec.verb)")
        }
    }

    // MARK: dump

    private func specDump(_ ctx: ControlContext) throws -> (ResolvedTarget?, any Encodable) {
        let scope = try requireScope(ctx, ctx.target)
        let options = SpecCodec.DumpOptions(relocatable: ctx.flag("relocatable"),
                                            includeIDs: ctx.flag("include-ids"),
                                            exposesBrowser: ctx.encoder.exposesBrowser)
        let document: SpecDocument
        if ctx.flag("all") {
            document = .session(SpecCodec.session(screens, options: options))
        } else if let target = ctx.target, target.screen != nil,
                  target.workspace == nil, target.pane == nil {
            // `-t 1` = a whole screen; `-t 1:2` / nothing = one workspace. The scope follows how
            // the target was written rather than inventing a separate --scope switch.
            document = .screen(SpecCodec.screen(scope.controller, options: options))
        } else {
            document = .workspace(SpecCodec.workspace(scope.controller, index: scope.workspace,
                                                      options: options))
        }
        let payload = ControlSpecDumpPayload(
            scope: document.kind.rawValue,
            schema: Self.schema(of: document),
            panes: document.paneCount,
            spec: try document.json())
        return (ResolvedTarget(screen: scope.controller.screenIndex + 1,
                               screenID: scope.controller.windowID.uuidString,
                               workspace: document.kind == .workspace ? scope.workspace + 1 : nil,
                               pane: nil, paneID: nil), payload)
    }

    static func schema(of document: SpecDocument) -> String {
        switch document.kind {
        case .workspace: SpecSchema.workspace
        case .screen: SpecSchema.screen
        case .session: SpecSchema.session
        }
    }

    // MARK: validate

    private func specValidate(_ ctx: ControlContext) throws -> (ResolvedTarget?, any Encodable) {
        let document = try Self.parseSpecArgument(ctx)
        let scope = try requireScope(ctx, ctx.target)
        var notes: [String] = []
        // Scope-dependent checks (the purely structural ones live in `SpecParser`, which has no
        // idea how many workspaces / screens this machine has).
        switch document {
        case .workspace:
            break
        case .screen(let screen):
            try Self.checkWorkspaceIndices(screen, controller: scope.controller)
            if screen.frame != nil || screen.display != nil {
                notes.append("display / frame is echoed back by dump only: spec apply never "
                             + "moves windows (use quickterm screen move)")
            }
        case .session(let session):
            for (controller, screen) in try Self.screenPlan(session, screens: screens) {
                try Self.checkWorkspaceIndices(screen, controller: controller)
            }
        }
        if Self.mentionsCommands(document) {
            notes.append("cmd / env / hold go in but never come back out: spec dump cannot "
                         + "reproduce a command that is already running. --reuse leaves a "
                         + "matching pane exactly where it is (its command is not re-run); "
                         + "--replace tears the pane down and rebuilds it (its command "
                         + "starts over)")
        }
        let payload = ControlSpecValidatePayload(
            valid: true, scope: document.kind.rawValue, schema: Self.schema(of: document),
            panes: document.paneCount, notes: notes)
        return (nil, payload)
    }

    /// Whether `workspaces[]` can land at all (the workspace count is config-driven, 1-10)
    static func checkWorkspaceIndices(_ screen: ScreenSpec, controller: MainWindowController) throws {
        let count = controller.model.layouts.count
        if let active = screen.activeWorkspace, active < 1 || active > count {
            throw ControlErrorBody(
                .badRequest,
                "activeWorkspace \(active) is out of range: screen \(controller.screenIndex + 1) "
                    + "has \(ControlChange.count(count, "workspace")) (1–\(count))",
                hint: "Change the count with quickterm workspace count N (1–10).")
        }
        var seen = Set<Int>()
        for (i, workspace) in (screen.workspaces ?? []).enumerated() {
            let index = workspace.index ?? (i + 1)
            guard index >= 1, index <= count else {
                throw ControlErrorBody(
                    .badRequest,
                    "workspaces[\(i)] lands on workspace \(index), but screen "
                        + "\(controller.screenIndex + 1) only has \(count) (1–\(count))",
                    hint: "Change the count with quickterm workspace count N (1–10).")
            }
            // One workspace may appear only once in a spec. If both entries landed, the second
            // one's `model.layouts[i] = ...` would overwrite the first **by assignment**: the panes
            // the first entry created would be in no layout at all and would never have gone
            // through the close path (neither the browser's paneWillClose nor the file manager's
            // session cleanup runs), while the report still claims they were created.
            guard seen.insert(index).inserted else {
                throw ControlErrorBody(
                    .badRequest,
                    "workspaces[\(i)] lands on workspace \(index) again: one workspace may "
                        + "only appear once in a spec",
                    hint: "Leaving index out means the array position decides. Mixing explicit "
                        + "index values with positional defaults is the easiest way to collide.")
            }
        }
    }

    /// Which screens `screens[]` lands on. **Count, out of range and duplicates** are all checked
    /// here in one pass, and `spec validate` / `spec apply` / the confirmation gate all read the
    /// same plan
    static func screenPlan(_ session: SessionSpec, screens: ScreenRegistry) throws
        -> [(controller: MainWindowController, spec: ScreenSpec)] {
        let live = screens.controllers.filter { !$0.isClosed }
        let wanted = (session.screens ?? []).count
        guard wanted <= live.count else {
            throw ControlErrorBody(
                .badRequest, "This session spec describes \(wanted) screens, and only "
                    + "\(live.count) exist right now",
                hint: "Open enough screens first with quickterm screen new: spec apply does not "
                    + "open windows for you.")
        }
        var out: [(controller: MainWindowController, spec: ScreenSpec)] = []
        var seen = Set<Int>()
        for (i, screen) in (session.screens ?? []).enumerated() {
            let index = (screen.index ?? (i + 1)) - 1
            guard live.indices.contains(index) else {
                throw ControlErrorBody(.badRequest,
                                       "screens[\(i)] points at screen \(index + 1), and only "
                                           + "\(live.count) exist right now")
            }
            guard seen.insert(index).inserted else {
                throw ControlErrorBody(
                    .badRequest, "screens[\(i)] lands on screen \(index + 1) again: one screen "
                        + "may only appear once",
                    hint: "Leaving index out means the array position decides.")
            }
            out.append((live[index], screen))
        }
        if let key = session.keyScreen, !live.indices.contains(key - 1) {
            throw ControlErrorBody(.badRequest, "keyScreen \(key) points at a screen that does not exist")
        }
        return out
    }

    /// Which (screen, workspace) pairs a spec will actually touch. **The confirmation prompt and
    /// the act itself read the same list** - if the prompt named one workspace while the act
    /// cleared a whole screen, what the user approved would not be what happened
    static func specTargets(_ document: SpecDocument, controller: MainWindowController,
                            workspace: Int, screens: ScreenRegistry) throws
        -> [(controller: MainWindowController, workspace: Int)] {
        func workspaces(_ screen: ScreenSpec, on controller: MainWindowController) throws
            -> [(controller: MainWindowController, workspace: Int)] {
            try checkWorkspaceIndices(screen, controller: controller)
            return (screen.workspaces ?? []).enumerated().map { i, spec in
                (controller, (spec.index ?? (i + 1)) - 1)
            }
        }
        switch document {
        case .workspace:
            return [(controller, workspace)]
        case .screen(let screen):
            return try workspaces(screen, on: controller)
        case .session(let session):
            var out: [(controller: MainWindowController, workspace: Int)] = []
            for (target, screen) in try screenPlan(session, screens: screens) {
                out += try workspaces(screen, on: target)
            }
            return out
        }
    }

    static func mentionsCommands(_ document: SpecDocument) -> Bool {
        func any(_ workspace: WorkspaceSpec) -> Bool {
            (SpecApplier.tiledSlots(workspace) + SpecApplier.floatingSlots(workspace))
                .contains { $0.pane.cmd != nil || $0.pane.env != nil || $0.pane.hold != nil }
        }
        switch document {
        case .workspace(let w): return any(w)
        case .screen(let s): return (s.workspaces ?? []).contains(where: any)
        case .session(let s): return (s.screens ?? []).contains { screen in
            (screen.workspaces ?? []).contains(where: any) }
        }
    }

    // MARK: apply

    private func specApply(_ ctx: ControlContext) throws -> (ResolvedTarget?, any Encodable) {
        let document = try Self.parseSpecArgument(ctx)
        let mode = try Self.mode(ctx)
        let scope = try requireScope(ctx, ctx.target)

        // 1) Compute the entire plan first (**not a single pane built, not a single one closed**).
        var appliers: [SpecApplier] = []
        var screenSettings: [(controller: MainWindowController, spec: ScreenSpec)] = []
        var controllers: [MainWindowController] = []
        var skipped: [String] = []

        func addScreen(_ spec: ScreenSpec, controller: MainWindowController) throws {
            try Self.checkWorkspaceIndices(spec, controller: controller)
            controller.flushPendingCloses()
            if !controllers.contains(where: { $0 === controller }) { controllers.append(controller) }
            screenSettings.append((controller, spec))
            if spec.frame != nil || spec.display != nil {
                skipped.append("display / frame on screen \(controller.screenIndex + 1) "
                               + "(spec apply does not move windows)")
            }
            for (i, workspace) in (spec.workspaces ?? []).enumerated() {
                let index = (workspace.index ?? (i + 1)) - 1
                let applier = SpecApplier(controller: controller, workspace: index,
                                          spec: workspace, mode: mode,
                                          exposesBrowser: ctx.encoder.exposesBrowser)
                // The visible column count is written at the screen level (`SpecCodec.screen` does
                // not repeat it inside every workspace): columns that leave out width are scaled by
                // it, otherwise a spec that says "the screen shows 4 columns" lands with column
                // widths computed from the old factor.
                applier.visibleColumnsHint = spec.visibleColumns
                appliers.append(applier)
            }
        }

        switch document {
        case .workspace(let workspace):
            controllers.append(scope.controller)
            appliers.append(SpecApplier(controller: scope.controller, workspace: scope.workspace,
                                        spec: workspace, mode: mode,
                                        exposesBrowser: ctx.encoder.exposesBrowser))
        case .screen(let screen):
            try addScreen(screen, controller: scope.controller)
        case .session(let session):
            for (controller, screen) in try Self.screenPlan(session, screens: screens) {
                try addScreen(screen, controller: controller)
            }
        }

        var changes: [ControlChange] = []
        for applier in appliers {
            try applier.preflight()
            // `--into-empty` is the default mode: it **cannot destroy anything** - a non-empty
            // workspace is always refused rather than quietly cleared on the way past. To
            // overwrite, say --replace out loud (and that one asks for confirmation first).
            if mode == .intoEmpty, !applier.existingPanes.isEmpty {
                throw ControlErrorBody(
                    .confirmationRequired,
                    "\(path(applier.controller, applier.workspace)) already holds "
                        + ControlChange.count(applier.existingPanes.count, "pane")
                        + ", and --into-empty leaves a non-empty workspace alone",
                    hint: "--replace overwrites it (it confirms first, and the processes inside "
                        + "are killed); --reuse keeps the panes that match.")
            }
            changes += applier.changes(at: path(applier.controller, applier.workspace))
        }
        // Working directories that exist but cannot be used (a protected directory + the missing
        // permission): by default the layout is applied anyway, but this **has to be said out
        // loud**. A script that passes `--require-cwd` wants a failure rather than a workspace
        // where every directory landed in the wrong place, and this step still sits in the "not a
        // single pane built, not a single one closed" phase.
        let deniedDirectories = appliers.flatMap(\.deniedDirectories).reduce(into: [String]()) {
            if !$0.contains($1) { $0.append($1) }
        }
        if !deniedDirectories.isEmpty, ctx.flag("require-cwd") {
            throw ControlErrorBody(
                .denied,
                "\(deniedDirectories.count) directories in this spec are unusable (macOS "
                    + "protected directories, and the Files and Folders permission is missing): "
                    + deniedDirectories.joined(separator: ", ")
                    + ". --require-cwd asks to fail rather than land somewhere else, so nothing "
                    + "was touched this time",
                hint: "Tick QuickTerm's entry under System Settings ▸ Privacy & Security ▸ Files "
                    + "and Folders and restart it, or drop --require-cwd (the layout is applied "
                    + "anyway and the response carries a cwd_denied warning).")
        }
        for (controller, spec) in screenSettings {
            changes += Self.screenChanges(spec, controller: controller, path: path(controller))
        }
        if case .session(let session) = document, let key = session.keyScreen,
           screens.controlCurrent?.screenIndex != key - 1 {
            changes.append(ControlChange("session.keyScreen",
                                         from: screens.controlCurrent.map { String($0.screenIndex + 1) } ?? "—",
                                         to: String(key)))
        }

        // The confirmation gate approved **this batch** of workspaces (more than one under screen
        // / session scope): re-check them one by one before acting. The layout does change during
        // the ten seconds the user spends reading the prompt, and this cut may run across a whole
        // screen.
        try verifyPinnedScopes(ctx, targets: appliers.map { ($0.controller, $0.workspace) })

        var report = ControlSpecApplyReport(mode: mode.rawValue, scope: document.kind.rawValue,
                                            created: [], reused: [], closed: [],
                                            skipped: skipped.isEmpty ? nil : skipped)
        var createdPanes: [(pane: PaneView, controller: MainWindowController, workspace: Int)] = []
        var focus: (pane: PaneView, controller: MainWindowController, workspace: Int)?

        let mutation = ControlMutationRequest(
            command: ctx.spec.name, request: ctx.request, peer: ctx.peer, changes: changes,
            controllers: controllers, undoCommand: ctx.spec.cli,
            target: path(scope.controller, scope.workspace))

        var payload = try commit(mutation) {
            var done = 0
            for applier in appliers {
                do {
                    let outcome = try applier.apply()
                    report.created += outcome.created.map { handleName($0) }
                    report.reused += outcome.reused.map { handleName($0) }
                    report.closed += outcome.closed
                    createdPanes += outcome.created.map {
                        ($0, applier.controller, applier.workspace)
                    }
                    if let target = outcome.focus, focus == nil || applier.controller === scope.controller {
                        focus = (target, applier.controller, applier.workspace)
                    }
                    done += 1
                } catch {
                    // Some workspaces have already landed: this **has to** be reported as partial
                    // so the agent knows the state it holds is now stale.
                    throw SpecApplier.body(error, partial: done > 0)
                }
            }
            for (controller, spec) in screenSettings {
                Self.applyScreenSettings(spec, controller: controller)
            }
            if case .session(let session) = document, let key = session.keyScreen {
                let live = screens.controllers.filter { !$0.isClosed }
                if live.indices.contains(key - 1), screens.controlCurrent !== live[key - 1] {
                    live[key - 1].window?.makeKeyAndOrderFront(nil)
                }
            }
        }
        payload.spec = payload.applied ? report : nil
        if !deniedDirectories.isEmpty {
            payload.warnings = deniedDirectories.map { .cwdDenied($0, used: nil) }
        }
        if payload.applied {
            payload.panes = createdPanes.map {
                paneInfo($0.pane, controller: $0.controller, workspace: $0.workspace, encoder: ctx.encoder)
            }
            payload.workspace = ctx.encoder.workspaceInfo(scope.controller, index: scope.workspace)
            if let focus, focus.controller.focusedPane !== focus.pane { payload.focusPending = true }
        }
        return (ResolvedTarget(screen: scope.controller.screenIndex + 1,
                               screenID: scope.controller.windowID.uuidString,
                               workspace: scope.workspace + 1,
                               pane: focus.map { handleName($0.pane) },
                               paneID: focus?.pane.id.uuidString), payload)
    }

    // MARK: The screen level

    static func screenChanges(_ spec: ScreenSpec, controller: MainWindowController,
                              path: String) -> [ControlChange] {
        var out: [ControlChange] = []
        if let columns = spec.visibleColumns, columns != controller.visibleColumns {
            out.append(ControlChange("\(path).visibleColumns",
                                     from: String(controller.visibleColumns), to: String(columns)))
        }
        if let fullscreen = spec.fullscreen, fullscreen != controller.isSimpleFullscreen {
            out.append(ControlChange("\(path).fullscreen",
                                     from: controller.isSimpleFullscreen ? "on" : "off",
                                     to: fullscreen ? "on" : "off"))
        }
        if let join = spec.joinAllSpaces, join != controller.joinsAllSpaces {
            out.append(ControlChange("\(path).joinAllSpaces",
                                     from: controller.joinsAllSpaces ? "on" : "off",
                                     to: join ? "on" : "off"))
        }
        if let active = spec.activeWorkspace, active - 1 != controller.model.activeIndex {
            out.append(ControlChange("\(path).activeWorkspace",
                                     from: String(controller.model.activeIndex + 1), to: String(active)))
        }
        return out
    }

    /// The screen level is only touched **after the workspaces have landed**: before switching to
    /// a workspace there has to be something in it
    static func applyScreenSettings(_ spec: ScreenSpec, controller: MainWindowController) {
        if let columns = spec.visibleColumns, columns != controller.visibleColumns {
            controller.setVisibleColumns(columns, persist: true)
        }
        if let join = spec.joinAllSpaces, join != controller.joinsAllSpaces {
            controller.joinsAllSpaces = join
        }
        if let fullscreen = spec.fullscreen, fullscreen != controller.isSimpleFullscreen {
            controller.toggleSimpleFullscreen()
        }
        if let active = spec.activeWorkspace, active - 1 != controller.model.activeIndex,
           controller.model.layouts.indices.contains(active - 1) {
            controller.switchWorkspace(active - 1)
        }
    }

    // MARK: Arguments

    /// The contents of `-f <file>` are read by the CLI and passed in the `spec` argument (the
    /// server never reads the caller's filesystem: the two processes have different cwds and
    /// different permissions to begin with, and "the server opens a path on your behalf" is a
    /// primitive that can be abused)
    static func parseSpecArgument(_ ctx: ControlContext) throws -> SpecDocument {
        guard let text = ctx.string("spec"), !text.isEmpty else {
            throw ControlErrorBody(.badRequest, "No spec content was provided",
                                   hint: "quickterm spec \(ctx.spec.verb) -f <file>, or pipe the "
                                       + "spec in on stdin")
        }
        return try SpecParser.parse(text)
    }

    static func mode(_ ctx: ControlContext) throws -> SpecApplier.Mode {
        let flags = SpecApplier.Mode.allCases.filter { ctx.flag($0.rawValue) }
        guard flags.count <= 1 else {
            throw ControlErrorBody(.badRequest,
                                   "--into-empty / --replace / --reuse are mutually exclusive, "
                                       + "got "
                                       + flags.map { "--\($0.rawValue)" }.joined(separator: " "),
                                   candidates: SpecApplier.Mode.allCases.map(\.rawValue))
        }
        return flags.first ?? .intoEmpty
    }
}
