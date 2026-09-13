import AppKit

/// `workspace goto|set|set-layout|equalize|clear|count`.
///
/// `set-layout` is the showcase example of the whole "absolute assignment" rule: the app only has
/// `toggle-layout`, and that **only acts on the active workspace** - setting workspace 4 to
/// dwindle is out of reach for a keyboard shortcut, and further still for an agent (it would have
/// to switch there, read the state, decide whether to flip, and switch back, and a failure at any
/// step in between leaves a mess behind).
@MainActor
extension ControlCommandRunner {
    func runWorkspace(_ ctx: ControlContext) throws -> (echo: ResolvedTarget?, data: any Encodable) {
        switch ctx.spec.verb {
        case "goto": return try workspaceGoto(ctx)
        case "set": return try workspaceSet(ctx)
        case "set-layout": return try workspaceSetLayout(ctx)
        case "equalize": return try workspaceEqualize(ctx)
        case "clear": return try workspaceClear(ctx)
        case "count": return try workspaceCount(ctx)
        default: throw ControlErrorBody(.unknownCommand, "workspace has no verb \(ctx.spec.verb)")
        }
    }

    private func workspaceGoto(_ ctx: ControlContext) throws -> (ResolvedTarget?, any Encodable) {
        let scope = try requireScope(ctx, ctx.target)
        let controller = scope.controller
        guard let wanted = ctx.int("index") else {
            throw ControlErrorBody(.badRequest, "workspace goto needs a workspace index (1-based)")
        }
        let count = controller.model.layouts.count
        guard wanted >= 1, wanted <= count else {
            throw ControlErrorBody(
                .notFound, "Workspace \(wanted) does not exist: screen "
                    + "\(controller.screenIndex + 1) currently has \(count) (1–\(count))",
                hint: "quickterm workspace count \(wanted) grows it to that many (1–10).")
        }
        let index = wanted - 1
        let now = controller.model.activeIndex
        let changes = now == index ? [] : [ControlChange(path(controller),
                                                         from: "workspace \(now + 1)",
                                                         to: "workspace \(index + 1)")]
        let mutation = ControlMutationRequest(
            command: ctx.spec.name, request: ctx.request, peer: ctx.peer, changes: changes,
            controllers: [controller], undoCommand: ctx.spec.cli,
            target: path(controller, index))
        var payload = try commit(mutation) { controller.switchWorkspace(index) }
        payload.workspace = ctx.encoder.workspaceInfo(controller, index: index)
        payload.screen = ctx.encoder.screenInfo(controller, isKey: controller === screens.controlCurrent)
        return (ResolvedTarget(screen: controller.screenIndex + 1,
                               screenID: controller.windowID.uuidString,
                               workspace: index + 1, pane: nil, paneID: nil), payload)
    }

    /// `workspace set --title`: name the **slot**. Lined up point by point with
    /// `pane set --title`, because both run the same `TitleRules` - an empty *or blank* string is a
    /// meaningful value (clear the name), the value is trimmed, `TitleRules.maxLength` is the
    /// ceiling, control characters are always refused, the change is treated as sensitive. The name
    /// **does not describe the contents**: neither `workspace clear` nor `spec apply --replace`
    /// touches it, which makes this command (together with rename from the context menu) the only
    /// entry point that can change it
    private func workspaceSet(_ ctx: ControlContext) throws -> (ResolvedTarget?, any Encodable) {
        let scope = try requireScope(ctx, ctx.target)
        let controller = scope.controller
        let index = scope.workspace
        // An empty string != not written (`ctx.string` treats an empty string as not written);
        // same rule as pane set --title.
        guard let title = ctx.rawString("title") else {
            throw ControlErrorBody(.badRequest,
                                   "workspace set needs at least one value to set (--title)",
                                   hint: "quickterm workspace set --help")
        }
        guard title.count <= TitleRules.maxLength else {
            throw ControlErrorBody(
                .badRequest,
                "--title is too long (\(title.count) characters, limit "
                    + "\(TitleRules.maxLength))")
        }
        guard TitleRules.isPrintable(title) else {
            throw ControlErrorBody(.badRequest, "--title contains control characters",
                                   hint: "The name is drawn verbatim into the workspace pill in "
                                       + "the status bar and into the title field in state.")
        }
        // Trim before comparing: `--title " dev "` after `--title "dev"` is the same name, and an
        // idempotency check that missed that would report a change nobody can see.
        let wanted = TitleRules.normalized(title)
        let now = controller.model.title(at: index)
        // The value is text the user wrote, so treat it as sensitive: same rule as pane titles,
        // it never reaches OSLog.
        let changes = now == wanted ? [] : [ControlChange("\(path(controller, index)).title",
                                                          from: now ?? "(unnamed)",
                                                          to: wanted ?? "(cleared)", sensitive: true)]
        let mutation = ControlMutationRequest(
            command: ctx.spec.name, request: ctx.request, peer: ctx.peer, changes: changes,
            controllers: [controller], undoCommand: ctx.spec.cli,
            target: path(controller, index))
        var payload = try commit(mutation) { controller.model.setTitle(wanted, at: index) }
        payload.workspace = ctx.encoder.workspaceInfo(controller, index: index)
        return (ResolvedTarget(screen: controller.screenIndex + 1,
                               screenID: controller.windowID.uuidString,
                               workspace: index + 1, pane: nil, paneID: nil), payload)
    }

    private func workspaceSetLayout(_ ctx: ControlContext) throws -> (ResolvedTarget?, any Encodable) {
        let scope = try requireScope(ctx, ctx.target)
        let controller = scope.controller
        guard let wanted = ctx.string("layout"), ["scrolling", "dwindle"].contains(wanted) else {
            throw ControlErrorBody(.badRequest, "workspace set-layout only accepts scrolling / dwindle",
                                   candidates: ["scrolling", "dwindle"])
        }
        let index = scope.workspace
        let now = controller.model.layouts[index].name
        let before = controller.model.layouts[index].paneList.map(\.id)
        let changes = now == wanted ? [] : [ControlChange("\(path(controller, index)).layout",
                                                          from: now, to: wanted)]
        let mutation = ControlMutationRequest(
            command: ctx.spec.name, request: ctx.request, peer: ctx.peer, changes: changes,
            controllers: [controller], undoCommand: ctx.spec.cli,
            target: path(controller, index))
        var payload = try commit(mutation) {
            // An inactive workspace can be set just the same: that is exactly what toggle-layout
            // cannot do.
            let previous = controller.model.layouts[index]
            guard controller.model.setLayout(wanted, at: index, columnFactor: controller.columnFactor) else {
                throw ControlErrorBody(.failed, "The layout conversion did not produce \(wanted)")
            }
            // The conversion has to preserve the panes and their order (what is lossy is the
            // column widths / the stacking structure, not the panes themselves).
            let after = controller.model.layouts[index].paneList.map(\.id)
            if Set(after) != Set(before) {
                // We already mutated: put the whole thing back (a layout is a value type) to hold
                // the invariant "throwing = nothing changed" - otherwise the pane that went missing
                // is neither in the layout nor has it run any teardown, which is a leaked terminal.
                controller.model.layouts[index] = previous
                throw ControlErrorBody(.internalError,
                                       "The layout conversion lost panes "
                                           + "(\(before.count) → \(after.count))")
            }
            if index == controller.model.activeIndex, let focused = controller.focusedPane {
                controller.requestFocus(to: focused)
            }
        }
        payload.workspace = ctx.encoder.workspaceInfo(controller, index: index)
        return (ResolvedTarget(screen: controller.screenIndex + 1,
                               screenID: controller.windowID.uuidString,
                               workspace: index + 1, pane: nil, paneID: nil), payload)
    }

    private func workspaceEqualize(_ ctx: ControlContext) throws -> (ResolvedTarget?, any Encodable) {
        let scope = try requireScope(ctx, ctx.target)
        let controller = scope.controller
        let index = scope.workspace
        let before = controller.controlGeometry(workspace: index)
        // First work out what equalizing would look like on a **copy**: whether this is a no-op
        // has to be known before anything is actually equalized.
        let after = Self.equalizedGeometry(controller: controller, workspace: index)
        let changes = MainWindowController.geometryMatches(before, after)
            ? []
            : [ControlChange("\(path(controller, index)).geometry",
                             from: Self.describe(before), to: Self.describe(after))]
        let mutation = ControlMutationRequest(
            command: ctx.spec.name, request: ctx.request, peer: ctx.peer, changes: changes,
            controllers: [controller], undoCommand: ctx.spec.cli,
            target: path(controller, index))
        var payload = try commit(mutation) { controller.controlEqualize(workspace: index) }
        payload.workspace = ctx.encoder.workspaceInfo(controller, index: index)
        return (ResolvedTarget(screen: controller.screenIndex + 1,
                               screenID: controller.windowID.uuidString,
                               workspace: index + 1, pane: nil, paneID: nil), payload)
    }

    /// The geometry after equalizing - **pure computation**, never touches the model (this is how
    /// `--dry-run` manages to change not a single byte)
    private static func equalizedGeometry(controller: MainWindowController, workspace: Int) -> [Double] {
        switch controller.model.layouts[workspace] {
        case .scrolling(let strip):
            return Array(repeating: controller.columnFactor, count: strip.columns.count)
        case .dwindle(let tree):
            let equalized = tree.equalized()
            var out: [Double] = []
            func walk(_ node: SplitTree<PaneView>.Node?) {
                guard let node else { return }
                if case .split(let s) = node {
                    out.append(s.ratio)
                    walk(s.left)
                    walk(s.right)
                }
            }
            walk(equalized.root)
            return out
        }
    }

    private static func describe(_ geometry: [Double]) -> String {
        geometry.isEmpty ? "—" : geometry.map { String(format: "%.3f", $0) }.joined(separator: " ")
    }

    private func workspaceClear(_ ctx: ControlContext) throws -> (ResolvedTarget?, any Encodable) {
        let scope = try requireScope(ctx, ctx.target)
        let controller = scope.controller
        let index = scope.workspace
        try verifyPinned(ctx, controller: controller, workspace: index)
        let victims = controller.model.layouts[index].paneList
            + controller.model.floatings[index].map(\.pane)
        let infos = victims.map { paneInfo($0, controller: controller, workspace: index, encoder: ctx.encoder) }
        let changes = victims.isEmpty ? [] : [ControlChange(path(controller, index),
                                                            from: ControlChange.count(victims.count, "pane"),
                                                            to: "0 panes")]
        let mutation = ControlMutationRequest(
            command: ctx.spec.name, request: ctx.request, peer: ctx.peer, changes: changes,
            controllers: [controller],
            // The processes have already been killed: an undo would only manufacture the illusion
            // that they are somehow still there.
            undoCommand: nil,
            target: path(controller, index))
        var payload = try commit(mutation) {
            // **Do not raise QuickTerm's own "processes are still running" prompt per pane**: the
            // confirmation inside `closePane` is dispatched with `DispatchQueue.main.async`, so
            // asking one by one means not a single pane is closed on this pass (while the payload
            // still reports applied), and N `NSAlert.runModal` calls would then open nested run
            // loops back to back after the command returns, wedging the main thread and the socket
            // with it.
            // The control plane's own confirmation gate has already listed this entire group of
            // panes by handle and asked once, and verifyPinned re-checked their identity right
            // before acting - same route as `screen close`: once it is confirmed, land it all in
            // one go.
            _ = controller.controlClearWorkspace(index, confirmIfNeeded: false)
        }
        if payload.applied {
            // Report from the facts: which ones actually closed (an inactive workspace goes
            // through removeFromAnyWorkspace, which is synchronous just the same).
            let remaining = Set((controller.model.layouts[index].paneList
                                 + controller.model.floatings[index].map(\.pane)).map(\.id))
            let closed = zip(victims, infos).filter { !remaining.contains($0.0.id) }.map(\.1)
            payload.panes = closed.isEmpty ? nil : closed
        } else {
            payload.panes = infos    // dry-run: this is the preview of "which ones would close"
        }
        payload.workspace = ctx.encoder.workspaceInfo(controller, index: index)
        return (ResolvedTarget(screen: controller.screenIndex + 1,
                               screenID: controller.windowID.uuidString,
                               workspace: index + 1, pane: nil, paneID: nil), payload)
    }

    /// `workspace count N`: **rewrite config.toml and let the existing config watcher apply it**.
    /// Calling `setWorkspaceCount` ourselves on top of that would have the watcher apply it a
    /// second time 0.2s later - in the window between, the keymap gets rebuilt twice, and the
    /// workspace count is an input to the keymap (`goto-workspace-N`). One write to disk, one path
    /// that takes effect, so there is only ever one truth.
    private func workspaceCount(_ ctx: ControlContext) throws -> (ResolvedTarget?, any Encodable) {
        guard let wanted = ctx.int("n") else {
            throw ControlErrorBody(.badRequest, "workspace count needs a number (1–10)")
        }
        guard (1...10).contains(wanted) else {
            throw ControlErrorBody(.badRequest, "The workspace count must be 1–10, got \(wanted)",
                                   hint: "That is the hard limit in "
                                       + "WorkspaceModel.setWorkspaceCount (⌘1..0 is ten keys).")
        }
        guard let session = (NSApp.delegate as? AppDelegate)?.session else {
            throw ControlErrorBody(.internalError, "No session")
        }
        let now = session.settings.workspaces
        // Shrink guard: the config layer already refuses to cut away a non-empty workspace, but it
        // keeps it **silently** - an agent would believe it set the count to 3, read back 6, and
        // get no explanation at all.
        if wanted < now {
            let highest = screens.controllers.compactMap { controller -> Int? in
                (0..<controller.model.layouts.count).last { !controller.model.isEmpty($0) }.map { $0 + 1 }
            }.max() ?? 0
            if wanted < highest {
                // `limit`, not `denied`: this is a structural ceiling ("you still have panes down
                // there"), not a policy refusal. Clear that workspace and the identical command
                // goes through - which is exactly the difference a caller has to be able to read
                // off the code without parsing the prose.
                throw ControlErrorBody(
                    .limit, "Cannot shrink to \(wanted): workspace \(highest) still has panes "
                        + "in it",
                    hint: "Clear it first with quickterm workspace clear -t :\(highest) (that "
                        + "kills the processes inside).")
            }
        }
        let changes = now == wanted ? [] : [ControlChange("config.workspaces",
                                                          from: String(now), to: String(wanted))]
        let mutation = ControlMutationRequest(
            command: ctx.spec.name, request: ctx.request, peer: ctx.peer, changes: changes,
            controllers: screens.controllers,
            // An undo would have to rewrite the config file back as well - that is the user's
            // file, and Cmd+Z has no business touching it.
            undoCommand: nil,
            target: ConfigStore.activeConfigURL.lastPathComponent)
        var payload = try commit(mutation) {
            do {
                try ConfigStore.rewrite(key: "workspaces", value: String(wanted))
            } catch {
                throw ControlErrorBody(.failed, "Rewriting config.toml failed: \(error)")
            }
        }
        if payload.applied {
            payload.note = "Wrote workspaces = \(wanted) into "
                + "\(ConfigStore.activeConfigURL.path); the config watcher hot-reloads it "
                + "(quickterm state shows the new count about 0.2s from now)"
        }
        return (nil, payload)
    }
}
