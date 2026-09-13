import AppKit

/// `screen new|close|move|focus|set`.
///
/// A "screen" = one window + its own set of workspaces. Every command in this group lands on the
/// entry points `AppDelegate+Screens` already has (`newScreen` / `moveScreen` / `closeScreen`) -
/// those own the registry, the saved state and index reuse, and a window built directly, going
/// around them, ends up in neither the registry nor the saved state.
@MainActor
extension ControlCommandRunner {
    func runScreen(_ ctx: ControlContext) throws -> (echo: ResolvedTarget?, data: any Encodable) {
        switch ctx.spec.verb {
        case "new": return try screenNew(ctx)
        case "close": return try screenClose(ctx)
        case "move": return try screenMove(ctx)
        case "focus": return try screenFocus(ctx)
        case "set": return try screenSet(ctx)
        default: throw ControlErrorBody(.unknownCommand, "screen has no verb \(ctx.spec.verb)")
        }
    }

    /// `--display uuid:... / name:... / <1-based index>`. **A frame is not an identity** (that is
    /// what `DisplayRef` itself says), so only uuid / name / index are accepted
    static func resolveDisplay(_ raw: String) throws -> NSScreen {
        let screens = NSScreen.screens
        func fail(_ why: String) -> ControlErrorBody {
            ControlErrorBody(.notFound, why,
                             hint: "Displays right now: " + screens.enumerated()
                                .map { "\($0.offset + 1)=\($0.element.localizedName)" }
                                .joined(separator: ", "),
                             candidates: screens.map(\.localizedName))
        }
        if raw.hasPrefix("uuid:") {
            let id = String(raw.dropFirst(5)).lowercased()
            guard let screen = screens.first(where: { $0.displayUUID?.uuidString.lowercased() == id }) else {
                throw fail("There is no display with uuid \(id)")
            }
            return screen
        }
        if raw.hasPrefix("name:") {
            let name = String(raw.dropFirst(5))
            let matches = screens.filter { $0.localizedName == name }
            if matches.count > 1 {
                throw ControlErrorBody(.ambiguousTarget,
                                       "\(matches.count) displays are all named `\(name)`",
                                       hint: "Use uuid: or an index instead.",
                                       candidates: matches.compactMap { $0.displayUUID?.uuidString })
            }
            guard let screen = matches.first else { throw fail("There is no display named `\(name)`") }
            return screen
        }
        if let index = Int(raw), index >= 1, index <= screens.count { return screens[index - 1] }
        throw fail("Cannot resolve \(raw) to a display")
    }

    private func screenNew(_ ctx: ControlContext) throws -> (ResolvedTarget?, any Encodable) {
        guard let app = NSApp.delegate as? AppDelegate else {
            throw ControlErrorBody(.internalError, "No AppDelegate")
        }
        let display = try ctx.string("display").map { try Self.resolveDisplay($0) }
        var inherit: PaneView?
        if let from = try ctx.parseTarget("inherit-cwd-from") {
            inherit = try requirePane(ctx, from).pane
        }
        let before = screens.controllers.count
        var created: MainWindowController?
        let mutation = ControlMutationRequest(
            command: ctx.spec.name, request: ctx.request, peer: ctx.peer,
            changes: [ControlChange("screens", from: "\(before)", to: "\(before + 1)")],
            controllers: [],
            // Undoing a screen would mean closing it along with the processes inside it: that is
            // not an undo, that is a second round of damage.
            undoCommand: nil,
            target: display?.localizedName)
        var payload = try commit(mutation) {
            let controller = app.newScreen(on: display, inheritingFrom: inherit)
            controller.ensureStarterPane(inheriting: inherit?.workingDirectory)
            controller.window?.makeKeyAndOrderFront(nil)
            created = controller
        }
        guard let controller = created else { return (nil, payload) }
        payload.screen = ctx.encoder.screenInfo(controller, isKey: true)
        return (ResolvedTarget(screen: controller.screenIndex + 1,
                               screenID: controller.windowID.uuidString,
                               workspace: controller.model.activeIndex + 1,
                               pane: controller.focusedPane.map { handleName($0) },
                               paneID: controller.focusedPane?.id.uuidString), payload)
    }

    private func screenClose(_ ctx: ControlContext) throws -> (ResolvedTarget?, any Encodable) {
        guard let app = NSApp.delegate as? AppDelegate else {
            throw ControlErrorBody(.internalError, "No AppDelegate")
        }
        let scope = try requireScope(ctx, ctx.target)
        let controller = scope.controller
        try verifyPinned(ctx, controller: controller)
        guard screens.controllers.count > 1 else {
            // `limit`: the floor of the screen count, the same structural family as the tab cap.
            // Nobody refused this — there is simply no screen left to close.
            throw ControlErrorBody(
                .limit, "This is the last screen: closing it would quit QuickTerm, and the "
                    + "control surface does not do that",
                hint: "Quit from QuickTerm's own menu instead: that path asks the user first.")
        }
        let panes = controller.model.allPanes.count
        let mutation = ControlMutationRequest(
            command: ctx.spec.name, request: ctx.request, peer: ctx.peer,
            changes: [ControlChange(path(controller), from: "open (\(panes) panes)", to: "closed")],
            controllers: [], undoCommand: nil,
            target: path(controller))
        var payload = try commit(mutation) {
            // Our own confirmation gate has already asked once: the `confirmCloseScreen()` inside
            // `closeScreen` would run an NSAlert.runModal nested run loop **on the control
            // command's own call stack** - the main thread blocks itself and the socket stops with
            // it. Both `--force` and "already confirmed" go through confirmed: true.
            app.closeScreen(controller, confirmed: true)
        }
        payload.note = "Screen closed; the \(panes) panes inside it and their processes are gone"
        return (nil, payload)
    }

    private func screenMove(_ ctx: ControlContext) throws -> (ResolvedTarget?, any Encodable) {
        guard let app = NSApp.delegate as? AppDelegate else {
            throw ControlErrorBody(.internalError, "No AppDelegate")
        }
        let scope = try requireScope(ctx, ctx.target)
        let controller = scope.controller
        guard let raw = ctx.string("display") else {
            throw ControlErrorBody(.badRequest, "screen move needs --display")
        }
        let display = try Self.resolveDisplay(raw)
        let now = controller.window?.screen
        let changes = now === display
            ? []
            : [ControlChange("\(path(controller)).display",
                             from: now?.localizedName ?? "—", to: display.localizedName)]
        let mutation = ControlMutationRequest(
            command: ctx.spec.name, request: ctx.request, peer: ctx.peer, changes: changes,
            // Window geometry stays off the undo stack (the snapshot does not carry it).
            controllers: [controller], undoCommand: nil,
            target: path(controller))
        var payload = try commit(mutation) { app.moveScreen(controller, to: display) }
        payload.screen = ctx.encoder.screenInfo(controller, isKey: controller === screens.controlCurrent)
        return (ResolvedTarget(screen: controller.screenIndex + 1,
                               screenID: controller.windowID.uuidString,
                               workspace: controller.model.activeIndex + 1,
                               pane: nil, paneID: nil), payload)
    }

    private func screenFocus(_ ctx: ControlContext) throws -> (ResolvedTarget?, any Encodable) {
        let scope = try requireScope(ctx, ctx.target)
        let controller = scope.controller
        let now = screens.controlCurrent
        let changes = now === controller
            ? []
            : [ControlChange("key screen", from: now.map { String($0.screenIndex + 1) } ?? "—",
                             to: String(controller.screenIndex + 1))]
        let mutation = ControlMutationRequest(
            command: ctx.spec.name, request: ctx.request, peer: ctx.peer, changes: changes,
            controllers: [controller], undoCommand: nil, target: path(controller))
        var payload = try commit(mutation) {
            controller.window?.makeKeyAndOrderFront(nil)
            if let focused = controller.focusedPane { controller.requestFocus(to: focused) }
        }
        payload.screen = ctx.encoder.screenInfo(controller, isKey: true)
        return (ResolvedTarget(screen: controller.screenIndex + 1,
                               screenID: controller.windowID.uuidString,
                               workspace: controller.model.activeIndex + 1,
                               pane: controller.focusedPane.map { handleName($0) },
                               paneID: controller.focusedPane?.id.uuidString), payload)
    }

    private func screenSet(_ ctx: ControlContext) throws -> (ResolvedTarget?, any Encodable) {
        let scope = try requireScope(ctx, ctx.target)
        let controller = scope.controller
        let fullscreen = try ctx.onOff("fullscreen")
        let joinAll = try ctx.onOff("join-all-spaces")
        let columns = ctx.int("visible-columns")
        guard fullscreen != nil || joinAll != nil || columns != nil else {
            throw ControlErrorBody(.badRequest,
                                   "screen set needs at least one value to set "
                                       + "(--fullscreen / --join-all-spaces / --visible-columns)")
        }
        if let columns, !(1...6).contains(columns) {
            throw ControlErrorBody(.badRequest, "--visible-columns must be 1–6, got \(columns)")
        }
        let base = path(controller)
        var changes: [ControlChange] = []
        if let fullscreen, fullscreen != controller.isSimpleFullscreen {
            changes.append(ControlChange("\(base).fullscreen",
                                         from: controller.isSimpleFullscreen ? "on" : "off",
                                         to: fullscreen ? "on" : "off"))
        }
        if let joinAll, joinAll != controller.joinsAllSpaces {
            changes.append(ControlChange("\(base).joinAllSpaces",
                                         from: controller.joinsAllSpaces ? "on" : "off",
                                         to: joinAll ? "on" : "off"))
        }
        if let columns, columns != controller.visibleColumns {
            changes.append(ControlChange("\(base).visibleColumns",
                                         from: String(controller.visibleColumns), to: String(columns)))
        }
        let mutation = ControlMutationRequest(
            command: ctx.spec.name, request: ctx.request, peer: ctx.peer, changes: changes,
            controllers: [controller], undoCommand: ctx.spec.cli, target: base)
        var payload = try commit(mutation) {
            // Everything here is "set it to this value": toggleSimpleFullscreen is a toggle, so
            // compare first and only flip when the values actually differ.
            if let fullscreen, fullscreen != controller.isSimpleFullscreen {
                controller.toggleSimpleFullscreen()
            }
            if let joinAll { controller.joinsAllSpaces = joinAll }
            if let columns { controller.setVisibleColumns(columns) }
        }
        payload.screen = ctx.encoder.screenInfo(controller, isKey: controller === screens.controlCurrent)
        return (ResolvedTarget(screen: controller.screenIndex + 1,
                               screenID: controller.windowID.uuidString,
                               workspace: controller.model.activeIndex + 1,
                               pane: nil, paneID: nil), payload)
    }
}
