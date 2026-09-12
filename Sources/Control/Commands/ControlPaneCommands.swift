import AppKit

/// `pane new|close|focus|move|swap|set|resize`.
///
/// Every command has the same shape: **compute the diff read-only first, then hand it to
/// `commit`**. This is not a style question - `--dry-run` (change nothing) and `--fail-if-noop`
/// (already in the target state -> exit 7) grow out of that shape; they are not an if-statement
/// bolted onto each command separately.
@MainActor
extension ControlCommandRunner {
    func runPane(_ ctx: ControlContext) throws -> (echo: ResolvedTarget?, data: any Encodable) {
        switch ctx.spec.verb {
        case "new": return try paneNew(ctx)
        case "close": return try paneClose(ctx)
        case "focus": return try paneFocus(ctx)
        case "move": return try paneMove(ctx)
        case "swap": return try paneSwap(ctx)
        case "set": return try paneSet(ctx)
        case "resize": return try paneResize(ctx)
        case "capture-text": return try paneCaptureText(ctx)
        default: throw ControlErrorBody(.unknownCommand, "pane has no verb \(ctx.spec.verb)")
        }
    }

    // MARK: new

    private func paneNew(_ ctx: ControlContext) throws -> (ResolvedTarget?, any Encodable) {
        // Where it lands: an --at anchor wins (it carries its own screen / workspace), otherwise
        // use the scope -t gave.
        var anchor: PaneView?
        var controller: MainWindowController
        var workspace: Int
        if let at = try ctx.parseTarget("at") {
            let hit = try requirePane(ctx, at)
            anchor = hit.pane
            controller = hit.controller
            workspace = hit.workspace
            if let scope = ctx.target, scope.screen != nil || scope.workspace != nil {
                let wanted = try requireScope(ctx, scope)
                guard wanted.controller === controller, wanted.workspace == workspace else {
                    throw ControlErrorBody(
                        .badTarget,
                        "--at \(handleName(hit.pane)) is in \(path(controller, workspace)), not in the \(path(wanted.controller, wanted.workspace)) that -t names",
                        hint: "Drop -t, or pick another anchor.")
                }
            }
        } else {
            let scope = try requireScope(ctx, ctx.target)
            controller = scope.controller
            workspace = scope.workspace
            anchor = scope.pane ?? (workspace == controller.model.activeIndex
                                    ? controller.focusedPane
                                    : controller.model.layouts[workspace].paneList.last)
        }

        let live = controller.model.layouts[workspace].paneList.count
            + controller.model.floatings[workspace].count
        guard live < ControlRateLimiter.maxPanesPerWorkspace else {
            throw ControlErrorBody(
                .denied,
                "Workspace \(path(controller, workspace)) already holds \(live) panes (limit \(ControlRateLimiter.maxPanesPerWorkspace))",
                hint: "Close a few first, or use another workspace.")
        }

        let kind = ctx.string("kind") ?? "terminal"
        let zone = try ctx.zone()
        let cwd = ctx.string("cwd").map { ($0 as NSString).expandingTildeInPath }
        if let cwd, cwd.hasPrefix("~") || cwd.contains("\0") {
            throw ControlErrorBody(.badRequest, "--cwd is not a usable path: \(cwd)")
        }
        // Ask the privacy guard once **before doing anything**: would this directory be turned
        // down when it reaches the engine. The verdict is cached per root directory
        // (`WorkingDirectoryGate`), so asking is free, and it buys two things - `--require-cwd` can
        // fail while not a single pane has been created yet, and the successful path carries a
        // warning that spells out "the directory was not used" instead of a bland ok.
        // **Only ask for the kinds that really consume cwd.** A browser pane does not consume cwd
        // at all (the browser branch of `ControlPaneFactory.make` takes only a url), so telling it
        // "the shell started in the default directory" describes something that never happened,
        // and `--require-cwd` would turn a perfectly normal pane creation into exit code 5.
        let cwdDenied = ControlPaneFactory.consumesWorkingDirectory(kind)
            ? cwd.flatMap { WorkingDirectoryGate.usable($0) == nil ? $0 : nil }
            : nil
        if let cwdDenied, ctx.flag("require-cwd") {
            throw ControlErrorBody(
                .denied,
                "--cwd \(cwdDenied) cannot be used: macOS counts it as a protected directory and QuickTerm has not "
                    + "been granted Files and Folders access. --require-cwd asks to fail rather than land somewhere "
                    + "else, so not a single pane was created",
                hint: "Tick QuickTerm's entry under System Settings ▸ Privacy & Security ▸ Files and Folders and "
                    + "restart it, or drop --require-cwd (the pane opens as usual and the response carries a "
                    + "cwd_denied warning).")
        }
        // The pane-building implementation is shared (`spec apply` goes down the same one): the
        // mutual-exclusion rules on the arguments and the URL resolution both live there.
        let recipe = ControlPaneFactory.Request(
            kind: kind, cwd: cwd, cmd: ctx.string("cmd"), hold: ctx.flag("hold"),
            env: try Self.parseEnvironment(ctx.strings("env")), url: ctx.string("url"))
        try ControlPaneFactory.validate(recipe)

        var created: PaneView?
        let mutation = ControlMutationRequest(
            command: ctx.spec.name, request: ctx.request, peer: ctx.peer,
            changes: [ControlChange(path(controller, workspace),
                                    from: ControlChange.count(live, "pane"),
                                    to: ControlChange.count(live + 1, "pane"))],
            controllers: [controller], undoCommand: ctx.spec.cli,
            target: path(controller, workspace, anchor))

        var payload = try commit(mutation) {
            let made = try ControlPaneFactory.make(recipe, controller: controller,
                                                   inheriting: anchor?.workingDirectory)
            guard controller.controlInsert(made.pane, workspace: workspace, anchor: anchor,
                                           zone: zone, focus: true) else {
                ControlPaneFactory.discard(made, controller: controller)
                throw ControlErrorBody(.failed, "Could not insert the new pane into \(path(controller, workspace))")
            }
            ControlPaneFactory.register(made, controller: controller)
            created = made.pane
        }

        if let cwdDenied {
            // `used` is best effort: it is nil until the shell's first prompt has emitted OSC 7.
            // **Never substitute `workingDirectory` for it** - when the directory was turned down,
            // that field echoes back exactly the directory the user asked for (saved state restores
            // from it, see `deniedWorkingDirectory`), so writing it into the warning as "the
            // directory actually used" explains one true statement with a false one.
            payload.warnings = [.cwdDenied(cwdDenied, used: (created as? Ghostty.SurfaceView)?.pwd)]
        }
        guard let pane = created else {
            // dry-run: nothing was built, so report honestly where it would have been built.
            return (ResolvedTarget(screen: controller.screenIndex + 1,
                                   screenID: controller.windowID.uuidString,
                                   workspace: workspace + 1,
                                   pane: anchor.map { handleName($0) },
                                   paneID: anchor?.id.uuidString), payload)
        }
        payload.pane = paneInfo(pane, controller: controller, workspace: workspace, encoder: ctx.encoder)
        payload.focusPending = controller.focusedPane !== pane ? true : nil
        payload.workspace = ctx.encoder.workspaceInfo(controller, index: workspace)
        return (ResolvedTarget(screen: controller.screenIndex + 1,
                               screenID: controller.windowID.uuidString,
                               workspace: workspace + 1,
                               pane: handleName(pane), paneID: pane.id.uuidString), payload)
    }

    /// The length ceiling for `pane set --title`. A title goes into the title bar, the status bar
    /// and every single `state` response - an agent stuffing a whole log into a title is a thing
    /// that really happens
    static let maxTitleLength = 200

    /// `--env KEY=VALUE`. Control characters are always refused: they would ride all the way into
    /// the child process's environment
    static func parseEnvironment(_ raw: [String]) throws -> [String: String] {
        var out: [String: String] = [:]
        for entry in raw {
            guard let eq = entry.firstIndex(of: "="), eq != entry.startIndex else {
                throw ControlErrorBody(.badRequest, "--env must be written as KEY=VALUE, got \(entry)")
            }
            let key = String(entry[entry.startIndex..<eq])
            let value = String(entry[entry.index(after: eq)...])
            guard !key.contains(" "), (key + value).unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7F }) else {
                throw ControlErrorBody(.badRequest, "--env \(key) contains illegal characters")
            }
            out[key] = value
        }
        return out
    }

    // MARK: close

    private func paneClose(_ ctx: ControlContext) throws -> (ResolvedTarget?, any Encodable) {
        let hit = try requirePane(ctx, ctx.target)
        try verifyPinned(ctx, controller: hit.controller, pane: hit.pane)
        let handle = handleName(hit.pane)
        // While a browser pane still holds other tabs, Cmd+W closes the current tab (Chrome's
        // semantics); the command line means "close this pane", which is the harder semantic: the
        // whole thing goes, tabs and all.
        let title = hit.pane.paneTitle
        let force = ctx.flag(ControlCommandTable.Flag.force)

        let mutation = ControlMutationRequest(
            command: ctx.spec.name, request: ctx.request, peer: ctx.peer,
            changes: [ControlChange(path(hit.controller, hit.workspace, hit.pane),
                                    // The title is the web page's / the terminal's: written out in
                                    // full in the panel, only the path survives into OSLog.
                                    from: "open \"\(title)\"", to: "closed", sensitive: true)],
            controllers: [hit.controller],
            // **No undo entry**: the processes have already been killed, and putting the layout
            // back would only manufacture the illusion that they are still there.
            undoCommand: nil,
            target: path(hit.controller, hit.workspace, hit.pane))

        // Only `closePane` itself knows whether a confirmation goes up (a file-manager pane does
        // not raise one even with child processes; an inactive workspace goes through
        // `removeFromAnyWorkspace` and never asks). Guessing up front is guaranteed to be wrong, so
        // **decide from the facts after acting**: the pane is still there = the prompt is up, it is
        // gone = it really closed.
        var stillOpen = false
        var payload = try commit(mutation) {
            if hit.workspace == hit.controller.model.activeIndex {
                hit.controller.closePane(hit.pane, confirmIfNeeded: !force, animated: false)
            } else {
                // Inactive workspace: pull it out directly (teardown included).
                hit.controller.removeFromAnyWorkspace(hit.pane)
            }
            hit.controller.flushPendingCloses()
            stillOpen = hit.controller.model.allPanes.contains { $0 === hit.pane }
        }
        if payload.applied, stillOpen {
            payload.confirmPending = true
            payload.applied = false
            payload.note = "QuickTerm put up a \"processes are still running\" confirmation prompt, so the pane is not closed yet; --force skips it."
        }
        payload.workspace = ctx.encoder.workspaceInfo(hit.controller, index: hit.workspace)
        return (ResolvedTarget(screen: hit.controller.screenIndex + 1,
                               screenID: hit.controller.windowID.uuidString,
                               workspace: hit.workspace + 1,
                               pane: handle, paneID: hit.pane.id.uuidString), payload)
    }

    // MARK: focus

    private func paneFocus(_ ctx: ControlContext) throws -> (ResolvedTarget?, any Encodable) {
        var target = ctx.target
        // `quickterm pane focus right` - the positional argument is sugar for a relative
        // direction, and it lands on the same target grammar.
        if let direction = ctx.string("where") {
            var relative = target ?? ControlTarget()
            relative.pane = switch direction {
            case "left": .direction(.left)
            case "right": .direction(.right)
            case "up": .direction(.up)
            case "down": .direction(.down)
            case "next": .cycle(next: true)
            case "prev": .cycle(next: false)
            default: throw ControlErrorBody(.badRequest, "pane focus takes a direction of left/right/up/down/next/prev")
            }
            target = relative
        }
        let hit = try requirePane(ctx, target)
        let controller = hit.controller
        let already = controller.focusedPane === hit.pane && controller.model.activeIndex == hit.workspace
        var changes: [ControlChange] = []
        if !already {
            changes.append(ControlChange(path(controller, hit.workspace),
                                         from: controller.focusedPane.map { handleName($0) } ?? "—",
                                         to: handleName(hit.pane)))
        }
        let mutation = ControlMutationRequest(
            command: ctx.spec.name, request: ctx.request, peer: ctx.peer, changes: changes,
            // Focus stays off the undo stack (having Cmd+Z undo a focus change only makes things
            // murkier).
            controllers: [controller], undoCommand: nil,
            target: path(controller, hit.workspace, hit.pane))
        var payload = try commit(mutation) {
            if controller.model.activeIndex != hit.workspace { controller.switchWorkspace(hit.workspace) }
            controller.requestFocus(to: hit.pane)
        }
        payload.pane = paneInfo(hit, encoder: ctx.encoder)
        payload.focusPending = controller.focusedPane !== hit.pane ? true : nil
        return (hit.echo, payload)
    }

    // MARK: move

    private func paneMove(_ ctx: ControlContext) throws -> (ResolvedTarget?, any Encodable) {
        let hit = try requirePane(ctx, ctx.target)
        guard let toRaw = ctx.string("to") else {
            throw ControlErrorBody(.badRequest, "pane move needs --to <screen:workspace>")
        }
        guard let to = try ctx.parseTarget("to") else {
            throw ControlErrorBody(.badRequest, "--to \(toRaw) does not parse")
        }
        guard to.pane == nil else {
            throw ControlErrorBody(.badRequest, "--to takes screen:workspace only (use --at / --where for the drop point)")
        }
        let destination = try requireScope(ctx, to)
        let follow = ctx.flag("follow") && !ctx.flag("no-follow")

        var anchor: PaneView?
        if let at = try ctx.parseTarget("at") {
            let anchorHit = try requirePane(ctx, at)
            guard anchorHit.controller === destination.controller,
                  anchorHit.workspace == destination.workspace else {
                throw ControlErrorBody(
                    .badTarget,
                    "--at \(handleName(anchorHit.pane)) is not in the target \(path(destination.controller, destination.workspace))")
            }
            anchor = anchorHit.pane
        }
        let zone = try ctx.zone()

        guard hit.controller !== destination.controller || hit.workspace != destination.workspace else {
            // Already in the target workspace: this is a re-placement (which only means anything
            // with an anchor), otherwise it is a no-op.
            guard let anchor, let zone else {
                let mutation = ControlMutationRequest(
                    command: ctx.spec.name, request: ctx.request, peer: ctx.peer, changes: [],
                    controllers: [hit.controller], undoCommand: nil,
                    target: path(hit.controller, hit.workspace, hit.pane))
                var payload = try commit(mutation) {}
                payload.pane = paneInfo(hit, encoder: ctx.encoder)
                return (hit.echo, payload)
            }
            let mutation = ControlMutationRequest(
                command: ctx.spec.name, request: ctx.request, peer: ctx.peer,
                changes: [ControlChange(path(hit.controller, hit.workspace, hit.pane),
                                        from: "in place", to: "\(ctx.string("where") ?? "right") of \(handleName(anchor))")],
                controllers: [hit.controller], undoCommand: ctx.spec.cli,
                target: path(hit.controller, hit.workspace, hit.pane))
            var payload = try commit(mutation) {
                hit.controller.controlReplace(hit.pane, workspace: hit.workspace,
                                              anchor: anchor, zone: zone)
            }
            payload.pane = paneInfo(hit, encoder: ctx.encoder)
            payload.workspace = ctx.encoder.workspaceInfo(hit.controller, index: hit.workspace)
            return (hit.echo, payload)
        }

        let source = hit.controller
        let target = destination.controller
        let mutation = ControlMutationRequest(
            command: ctx.spec.name, request: ctx.request, peer: ctx.peer,
            changes: [ControlChange(handleName(hit.pane),
                                    from: path(source, hit.workspace),
                                    to: path(target, destination.workspace))],
            controllers: source === target ? [source] : [source, target],
            undoCommand: ctx.spec.cli,
            target: path(target, destination.workspace))

        var moved = false
        var payload = try commit(mutation) {
            guard source.controlHandOff(hit.pane, to: target, workspace: destination.workspace,
                                        anchor: anchor, zone: zone, follow: follow) else {
                // When controlHandOff cannot place it, it has already put the pane back where it
                // was: throwing = nothing changed.
                throw ControlErrorBody(.failed, "Could not put \(handleName(hit.pane)) into \(path(target, destination.workspace))")
            }
            moved = true
        }
        let landedWorkspace = moved ? destination.workspace : hit.workspace
        let landedController = moved ? target : source
        payload.pane = paneInfo(hit.pane, controller: landedController, workspace: landedWorkspace,
                                encoder: ctx.encoder)
        payload.workspace = ctx.encoder.workspaceInfo(landedController, index: landedWorkspace)
        payload.focusPending = follow && landedController.focusedPane !== hit.pane ? true : nil
        if moved, !follow {
            payload.note = "The pane is now in \(path(landedController, landedWorkspace)), but the view did not follow it there (only --follow switches along)."
        }
        return (ResolvedTarget(screen: landedController.screenIndex + 1,
                               screenID: landedController.windowID.uuidString,
                               workspace: landedWorkspace + 1,
                               pane: handleName(hit.pane), paneID: hit.pane.id.uuidString), payload)
    }

    // MARK: swap

    private func paneSwap(_ ctx: ControlContext) throws -> (ResolvedTarget?, any Encodable) {
        let hit = try requirePane(ctx, ctx.target)
        guard let withTarget = try ctx.parseTarget("with") else {
            throw ControlErrorBody(.badRequest, "pane swap needs --with <pane>")
        }
        let other = try requirePane(ctx, withTarget)
        guard hit.pane !== other.pane else {
            throw ControlErrorBody(.badRequest, "A pane cannot be swapped with itself (\(handleName(hit.pane)))")
        }
        guard hit.controller === other.controller, hit.workspace == other.workspace else {
            throw ControlErrorBody(
                .badTarget,
                "The two panes are not in the same workspace (\(path(hit.controller, hit.workspace)) ↔ \(path(other.controller, other.workspace)))",
                hint: "To go across workspaces use quickterm pane move")
        }
        let controller = hit.controller
        let mutation = ControlMutationRequest(
            command: ctx.spec.name, request: ctx.request, peer: ctx.peer,
            changes: [ControlChange(path(controller, hit.workspace),
                                    from: "\(handleName(hit.pane)) ↔ \(handleName(other.pane))",
                                    to: "\(handleName(other.pane)) ↔ \(handleName(hit.pane))")],
            controllers: [controller], undoCommand: ctx.spec.cli,
            target: path(controller, hit.workspace, hit.pane))
        var payload = try commit(mutation) {
            guard controller.controlSwap(hit.pane, other.pane, workspace: hit.workspace) else {
                throw ControlErrorBody(.failed, "Swap failed: both panes have to be in the tiled layer",
                                       hint: "For a floating pane, run quickterm pane set --float off first.")
            }
        }
        payload.pane = paneInfo(hit, encoder: ctx.encoder)
        payload.workspace = ctx.encoder.workspaceInfo(controller, index: hit.workspace)
        return (hit.echo, payload)
    }

    // MARK: set (absolute assignment)

    private func paneSet(_ ctx: ControlContext) throws -> (ResolvedTarget?, any Encodable) {
        let hit = try requirePane(ctx, ctx.target)
        let controller = hit.controller
        let zoom = try ctx.onOff("zoom")
        let float = try ctx.onOff("float")
        let width = ctx.double("width")
        let ratio = ctx.double("ratio")
        // **An empty string is a meaningful value** (`--title "" ` = hand the title back to the
        // shell), so this one cannot go through `ctx.string` (which treats an empty string as "not
        // written"). "Not written" and "written empty" are two different things.
        let title = ctx.rawString("title")
        guard zoom != nil || float != nil || width != nil || ratio != nil || title != nil else {
            throw ControlErrorBody(.badRequest,
                                   "pane set needs at least one value to set (--zoom / --float / --width / --ratio / --title)",
                                   hint: "quickterm pane set --help")
        }
        let layoutName = controller.model.layouts[hit.workspace].name
        if width != nil, layoutName != "scrolling" {
            throw ControlErrorBody(.badRequest, "--width only means anything in a scrolling workspace (this one is \(layoutName))",
                                   hint: "In dwindle, use --ratio")
        }
        if ratio != nil, layoutName != "dwindle" {
            throw ControlErrorBody(.badRequest, "--ratio only means anything in a dwindle workspace (this one is \(layoutName))",
                                   hint: "In scrolling, use --width")
        }
        if let width, !ScrollingStrip.widthRange.contains(width) {
            throw ControlErrorBody(
                .badRequest,
                "--width has to be between \(ScrollingStrip.widthRange.lowerBound) and \(ScrollingStrip.widthRange.upperBound), got \(width)",
                hint: "An out-of-range value is not silently clamped: that would leave the value an agent reads back different from the one it wrote.")
        }
        // What is accepted is the range **the engine can actually hold** (= the spec's
        // ratioRange), not the 0.1-0.9 that is comfortable to type: dragging a divider with the
        // mouse only clamps at 10pt, so a 1600pt-wide pane dragged all the way in lands at 0.006,
        // and `spec apply` accepts that number - if absolute assignment did not, a dumped workspace
        // could not be reproduced with `pane set` (out of range still raises, never a silent
        // clamp).
        if let ratio, !SpecLimits.ratioRange.contains(ratio) {
            throw ControlErrorBody(
                .badRequest,
                "--ratio has to be between \(SpecLimits.ratioRange.lowerBound) and \(SpecLimits.ratioRange.upperBound), got \(ratio)",
                hint: "To have it clamped by the same minimum-size rule the mouse follows, use pane resize --ratio")
        }

        let base = path(controller, hit.workspace, hit.pane)
        var changes: [ControlChange] = []
        let floatingNow = controller.controlIsFloating(hit.pane, workspace: hit.workspace)
        if let float, float != floatingNow {
            guard hit.workspace == controller.model.activeIndex else {
                throw ControlErrorBody(
                    .badTarget, "--float only works on a pane in the active workspace (floating geometry is measured against the current window)",
                    hint: "Run quickterm workspace goto \(hit.workspace + 1) first.")
            }
            changes.append(ControlChange("\(base).float", from: floatingNow ? "on" : "off", to: float ? "on" : "off"))
        }
        // zoom / column width / split ratio are all properties **inside the tiled layer**: a
        // floating pane has none of them. The check has to go by "which layer it is in once this
        // command is done", because a `--float off` in the same command drops it back into the
        // tiled layer first (float comes first in the apply order).
        let willFloat = float ?? floatingNow
        if willFloat, zoom == true || width != nil || ratio != nil {
            throw ControlErrorBody(
                .badRequest,
                "\(handleName(hit.pane)) will still be floating afterwards, and --zoom / --width / --ratio are all properties of the tiled layer",
                hint: "Add --float off to the same command and the pane drops back into the tiled layer "
                    + "before these values are set.")
        }

        let zoomedNow = controller.controlIsZoomed(hit.pane, workspace: hit.workspace)
        if let zoom, zoom != zoomedNow {
            changes.append(ControlChange("\(base).zoom", from: zoomedNow ? "on" : "off", to: zoom ? "on" : "off"))
        }
        let widthNow = controller.controlColumnWidth(of: hit.pane, workspace: hit.workspace)
        if let width {
            if let widthNow {
                if abs(widthNow - width) >= 0.0005 {
                    changes.append(ControlChange("\(base).width", from: Self.number(widthNow), to: Self.number(width)))
                }
            } else {
                // About to fall from the floating layer back into a tiled column (--float off):
                // there is no column width yet at this moment, and without recording it --dry-run
                // would miss a change that really happens, and the call would count as a no-op and
                // exit 7.
                changes.append(ControlChange("\(base).width", from: "floating (no column width)", to: Self.number(width)))
            }
        }
        let ratioNow = controller.controlSplitRatio(of: hit.pane, workspace: hit.workspace)
        if let ratio {
            if let ratioNow {
                if abs(ratioNow - ratio) >= 0.0005 {
                    changes.append(ControlChange("\(base).ratio", from: Self.number(ratioNow), to: Self.number(ratio)))
                }
            } else if floatingNow, !controller.model.layouts[hit.workspace].paneList.isEmpty {
                // About to land back in the tiled layer while the tree already holds other panes:
                // once inserted there is certainly a parent split.
                changes.append(ControlChange("\(base).ratio", from: "floating (no parent split)", to: Self.number(ratio)))
            } else {
                throw ControlErrorBody(.badRequest, "\(handleName(hit.pane)) has no parent split (it is the only pane in the tree), so --ratio has nothing to set")
            }
        }

        // Title: terminal panes only (a browser pane's title comes from the web page and is not
        // ours to set - setting it anyway would be overwritten by the page itself on the next
        // navigation, and that "set but never took effect" is the hardest kind to track down).
        var surfaceForTitle: Ghostty.SurfaceView?
        if let title {
            guard let surface = hit.pane as? Ghostty.SurfaceView else {
                throw ControlErrorBody(
                    .wrongPaneKind,
                    "\(handleName(hit.pane)) is a \(hit.pane.kind.rawValue) pane, and its title is not its own to set "
                        + "(a browser pane's title comes from the web page)",
                    hint: "Only a kind=terminal pane can have its title set.")
            }
            guard title.count <= Self.maxTitleLength else {
                throw ControlErrorBody(.badRequest,
                                       "--title is too long (\(title.count) characters, limit \(Self.maxTitleLength))")
            }
            guard title.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7F
                                                    && !(0x80...0x9F).contains($0.value) }) else {
                throw ControlErrorBody(.badRequest, "--title contains control characters",
                                       hint: "The title is drawn verbatim onto the pane's title bar and echoed in the title field of state.")
            }
            surfaceForTitle = surface
            let now = surface.paneTitle
            if title.isEmpty {
                // Handing it back: it only counts as a change if the title really was taken over
                // (a second run is a no-op, and that is what exit 7 rests on).
                if surface.hasControlTitle {
                    changes.append(ControlChange("\(base).title", from: now, to: "(handed back to the shell)",
                                                 sensitive: true))
                }
            } else if !(surface.hasControlTitle && now == title) {
                // **The criterion is "has it been taken over", not "does it look the same".** When
                // the title the shell reports happens to equal the one being set (very common when
                // an agent uses the directory name as the pane name), a literal comparison makes
                // this a no-op: `setControlTitle` is never called, the title is not pinned, and the
                // shell's next OSC title report replaces it - while the caller was told success.
                // Absolute assignment means "once this returns, that is what it is".
                changes.append(ControlChange(
                    "\(base).title",
                    from: surface.hasControlTitle ? now : "\"\(now)\" (reported by the shell, not taken over)",
                    to: title, sensitive: true))
            }
        }

        let mutation = ControlMutationRequest(
            command: ctx.spec.name, request: ctx.request, peer: ctx.peer, changes: changes,
            controllers: [controller], undoCommand: ctx.spec.cli, target: base)
        var payload = try commit(mutation) {
            if let title, let surfaceForTitle { surfaceForTitle.setControlTitle(title) }
            // **Settle the layer first**: float decides which layer the pane is in, and zoom /
            // width / ratio are all properties within a layer. Written the other way round,
            // `--float off --zoom on` would first write an orphan zoom in the floating layer, which
            // the re-insertion path then wipes out (insertingColumnRight / tree.inserting - both
            // clear zoom).
            if let float, float != floatingNow { controller.toggleFloat(hit.pane) }
            if let zoom { controller.controlSetZoom(hit.pane, workspace: hit.workspace, on: zoom) }
            if let width { controller.controlSetColumnWidth(hit.pane, workspace: hit.workspace, to: width) }
            if let ratio { controller.controlSetSplitRatio(hit.pane, workspace: hit.workspace, to: ratio) }
        }
        payload.pane = paneInfo(hit, encoder: ctx.encoder)
        payload.workspace = ctx.encoder.workspaceInfo(controller, index: hit.workspace)
        return (hit.echo, payload)
    }

    // MARK: resize (= the things the mouse can do; hitting a limit is a no-op)

    /// **On a par with the mouse.** The mouse has exactly three ways to change a size, and the
    /// command line has to be able to express every one of them:
    /// (1) drag a divider -> `--ratio` (or `--points`) + an optional `--split <path>` naming which
    ///     one;
    /// (2) Cmd+right-drag a pane / the `resize-*` keybindings (the nearest parent split running the
    ///     same way, measured in points) -> `--dir` + `--points`;
    /// (3) drag a column width in scrolling -> `--width` (a factor) or `--points` (points).
    /// The clamping rules are lined up with them too: (1) goes through `SplitViewMetrics.ratio`
    /// (10pt left on each side, exactly what the drag gesture uses), (2) through
    /// `SplitTree.resizing` (0.1-0.9, exactly what the keybindings use), (3) through
    /// `ScrollingStrip.widthRange`
    private func paneResize(_ ctx: ControlContext) throws -> (ResolvedTarget?, any Encodable) {
        let hit = try requirePane(ctx, ctx.target)
        let controller = hit.controller
        let base = path(controller, hit.workspace, hit.pane)
        let workspacePath = path(controller, hit.workspace)
        let dwindle = controller.model.layouts[hit.workspace].name == "dwindle"
        let widthRaw = ctx.string("width")
        let ratioRaw = ctx.string("ratio")
        let pointsRaw = ctx.string("points")
        let dirRaw = ctx.string("dir")
        let splitPath = ctx.string("split")

        let given = [widthRaw, ratioRaw, pointsRaw].compactMap { $0 }
        guard given.count <= 1 else {
            throw ControlErrorBody(.badRequest, "--width / --ratio / --points: only one of them per call",
                                   hint: "Points go in --points, a ratio in --ratio, a column width factor in --width")
        }
        guard !given.isEmpty || dirRaw != nil else {
            throw ControlErrorBody(
                .badRequest,
                "pane resize needs --width / --ratio / --points (a delta such as +0.05 is fine), or --dir",
                hint: "quickterm pane resize -t t7 --dir right does exactly what pressing ⌘⌃→ once does.")
        }
        if splitPath != nil, !dwindle {
            throw ControlErrorBody(.badRequest, "--split only means anything in a dwindle workspace (this one is scrolling)",
                                   hint: "In scrolling what you resize is the column width: --width / --points")
        }

        var changes: [ControlChange] = []
        var apply: () -> Void = {}

        if let dirRaw {
            // (2) the keybinding / Cmd+right-drag path: the direction decides the sign, the points
            // are the distance.
            guard widthRaw == nil, ratioRaw == nil else {
                throw ControlErrorBody(.badRequest, "--dir is the resize-by-points path, so pair it with --points",
                                       hint: "To set a ratio outright, leave out --dir: --ratio 0.62 [--split a]")
            }
            // `--dir` adjusts **the nearest divider running the same way** (which one that is
            // follows from the direction and the shape of the tree), so a `--split` naming one
            // explicitly has nowhere to go on this path. Dropping it silently would produce "the
            // agent believed it adjusted the root divider while it actually adjusted another one" -
            // exactly the kind of mistake a control plane must never make.
            guard splitPath == nil else {
                throw ControlErrorBody(
                    .badRequest, "--dir takes the nearest divider running the same way, so it cannot also name one with --split",
                    hint: "To name one, leave out --dir: --split root --points +100, or --split a.b --ratio 0.62")
            }
            guard let direction = Self.direction(dirRaw) else {
                throw ControlErrorBody(.badRequest, "--dir takes left / right / up / down only",
                                       candidates: ["left", "right", "up", "down"])
            }
            let points = try Self.magnitude(pointsRaw ?? "100", flag: "--points")
            (changes, apply) = try previewDirectionalResize(
                hit: hit, direction: direction, points: points, base: base,
                workspacePath: workspacePath)
        } else if dwindle {
            // (1) drag a divider: by default the pane's own parent split, --split names an ancestor
            // one.
            (changes, apply) = try previewSplitResize(
                hit: hit, splitPath: splitPath, ratioRaw: ratioRaw, pointsRaw: pointsRaw,
                widthRaw: widthRaw, workspacePath: workspacePath)
        } else {
            // (3) column width: a factor or points.
            (changes, apply) = try previewColumnResize(
                hit: hit, widthRaw: widthRaw, pointsRaw: pointsRaw, ratioRaw: ratioRaw, base: base)
        }

        let mutation = ControlMutationRequest(
            command: ctx.spec.name, request: ctx.request, peer: ctx.peer, changes: changes,
            controllers: [controller], undoCommand: ctx.spec.cli, target: base)
        var payload = try commit(mutation) { apply() }
        payload.pane = paneInfo(hit, encoder: ctx.encoder)
        payload.workspace = ctx.encoder.workspaceInfo(controller, index: hit.workspace)
        return (hit.echo, payload)
    }

    /// (2) `--dir`: **does not compute a ratio itself**; it hands the same call to the two
    /// functions the mouse / keybindings use, running it on a copy first to get the diff (which is
    /// how `--dry-run` changes not a single byte)
    private func previewDirectionalResize(
        hit: PaneHit, direction: ScrollingStrip.Direction, points: Double,
        base: String, workspacePath: String) throws -> ([ControlChange], () -> Void) {
        let controller = hit.controller
        switch controller.model.layouts[hit.workspace] {
        case .dwindle(let tree):
            guard let node = tree.root?.node(view: hit.pane),
                  let size = ControlGeometry.contentSize(controller) else {
                throw ControlErrorBody(.failed, "Geometry cannot be measured for this workspace right now (the window is not laid out yet)",
                                       hint: "Retry shortly, or use --ratio instead.")
            }
            let bounds = CGRect(origin: .zero, size: size)
            guard let next = try? tree.resizing(node: node, by: UInt16(min(max(points, 1), 30000)),
                                                in: direction.spatial, with: bounds) else {
                throw ControlErrorBody(
                    .badRequest,
                    "--dir \(Self.name(direction)): \(handleName(hit.pane)) has no divider on that side to resize",
                    hint: "Try another direction, or name a divider with --split")
            }
            return (Self.splitChanges(before: tree, after: next, workspacePath: workspacePath),
                    { controller.controlResizeSplit(hit.pane, workspace: hit.workspace,
                                                    points: points, direction: direction.spatial) })
        case .scrolling(let strip):
            guard direction == .left || direction == .right else {
                throw ControlErrorBody(.badRequest,
                                       "In scrolling only the column width is adjustable, so only left / right do anything (up / down are no-ops here, exactly as the keybindings are)",
                                       hint: "To resize heights inside a column, switch the workspace to the dwindle layout.")
            }
            let delta = (direction == .left ? -points : points)
            return previewColumnDelta(hit: hit, strip: strip, deltaPoints: delta, base: base)
        }
    }

    /// (1) dwindle: set one divider's ratio (`--ratio`) or its position (`--points`)
    private func previewSplitResize(
        hit: PaneHit, splitPath: String?, ratioRaw: String?, pointsRaw: String?,
        widthRaw: String?, workspacePath: String) throws -> ([ControlChange], () -> Void) {
        let controller = hit.controller
        if widthRaw != nil {
            throw ControlErrorBody(.badRequest, "--width only means anything in a scrolling workspace",
                                   hint: "In dwindle, use --ratio / --points")
        }
        // The root divider's path is the empty string, and an empty string cannot be carried over
        // the command line (`--split ""` = not given), so it gets the name `root`.
        let wanted = splitPath.map { $0 == "root" ? "" : $0 }
            ?? controller.controlParentSplitPath(of: hit.pane, workspace: hit.workspace)
        guard let wanted else {
            throw ControlErrorBody(.badRequest,
                                   "\(handleName(hit.pane)) has no parent split (it is the only pane in the tree), so there is no divider to resize")
        }
        guard let slot = controller.controlSplitSlot(workspace: hit.workspace, path: wanted) else {
            let available = Self.splitPaths(of: controller, workspace: hit.workspace)
            throw ControlErrorBody(.notFound, "This workspace has no split at \(Self.quoted(wanted))",
                                   hint: "`a` = left / top, `b` = right / bottom, joined with dots; the root one is written `root`",
                                   candidates: available.map(Self.quoted))
        }
        // The length of this split along the direction it divides (pt): converting between points
        // and a ratio is just a division by it. It cannot be measured while the window is not
        // attached (during a SwiftUI rebuild / headless), and then the ratio is the only way left.
        let span = ControlGeometry.contentSize(controller)
            .flatMap { controller.controlSplitSlot(workspace: hit.workspace, path: wanted, size: $0) }
            .map { Double(ControlGeometry.span(of: $0)) }
        let now = slot.ratio
        var target: Double
        if let ratioRaw {
            target = try Self.applyDelta(ratioRaw, to: now, flag: "--ratio")
        } else if let pointsRaw {
            guard let span, span > 0 else {
                throw ControlErrorBody(.failed, "The window is not laid out yet, so points cannot be converted",
                                       hint: "Use --ratio instead, or retry shortly.")
            }
            let text = pointsRaw.trimmingCharacters(in: .whitespaces)
            let value = try Self.number(text, flag: "--points")
            // Signed = **move** this divider by N points (positive = right / down); a bare number
            // = set the a side to N points.
            target = (text.hasPrefix("+") || text.hasPrefix("-")) ? now + value / span : value / span
        } else {
            throw ControlErrorBody(.badRequest, "resize in a dwindle workspace needs --ratio or --points")
        }
        // Clamping: **the same function the drag gesture uses** (10pt left on each side); when the
        // length cannot be measured, fall back to 0.1-0.9.
        let clamped: Double
        if let span, span > 2 * Double(SplitViewMetrics.minSize) {
            clamped = Double(SplitViewMetrics.ratio(dividerAt: CGFloat(target * span), in: CGFloat(span)))
        } else {
            clamped = min(max(target, 0.1), 0.9)
        }
        let rounded = ControlGeometry.rounded(CGFloat(clamped))
        var changes: [ControlChange] = []
        if abs(rounded - now) >= 0.0005 {
            changes.append(ControlChange(Self.splitChangePath(workspacePath, wanted),
                                         from: Self.number(now), to: Self.number(rounded)))
        }
        return (changes, {
            controller.controlSetSplitRatio(workspace: hit.workspace, path: wanted, to: rounded)
        })
    }

    /// (3) scrolling: column width (a factor or points)
    private func previewColumnResize(
        hit: PaneHit, widthRaw: String?, pointsRaw: String?, ratioRaw: String?,
        base: String) throws -> ([ControlChange], () -> Void) {
        let controller = hit.controller
        if ratioRaw != nil {
            throw ControlErrorBody(.badRequest, "--ratio only means anything in a dwindle workspace",
                                   hint: "In scrolling, use --width / --points")
        }
        guard let now = controller.controlColumnWidth(of: hit.pane, workspace: hit.workspace) else {
            throw ControlErrorBody(.badRequest,
                                   "\(handleName(hit.pane)) is not in any column (a floating pane has no column width)")
        }
        let viewport = ControlGeometry.contentSize(controller)?.width
        var target: Double
        if let widthRaw {
            target = try Self.applyDelta(widthRaw, to: now, flag: "--width")
        } else if let pointsRaw {
            guard let viewport, viewport > 0 else {
                throw ControlErrorBody(.failed, "The window is not laid out yet, so points cannot be converted", hint: "Use --width instead.")
            }
            let text = pointsRaw.trimmingCharacters(in: .whitespaces)
            let value = try Self.number(text, flag: "--points")
            target = (text.hasPrefix("+") || text.hasPrefix("-"))
                ? now + value / Double(viewport) : value / Double(viewport)
        } else {
            throw ControlErrorBody(.badRequest, "resize in a scrolling workspace needs --width or --points")
        }
        let clamped = min(max(target, ScrollingStrip.widthRange.lowerBound),
                          ScrollingStrip.widthRange.upperBound)
        let rounded = ControlGeometry.rounded(CGFloat(clamped))
        var changes: [ControlChange] = []
        if abs(rounded - now) >= 0.0005 {
            changes.append(ControlChange("\(base).width", from: Self.number(now), to: Self.number(rounded)))
        }
        return (changes, {
            controller.controlSetColumnWidth(hit.pane, workspace: hit.workspace, to: rounded)
        })
    }

    /// `--dir left|right --points N` applied to scrolling: the same function as a horizontal
    /// Cmd+right-drag
    private func previewColumnDelta(hit: PaneHit, strip: ScrollingStrip, deltaPoints: Double,
                                    base: String) -> ([ControlChange], () -> Void) {
        let controller = hit.controller
        // The conversion and the clamping are all done by `ScrollingStrip.resizingWidth` (the same
        // one a Cmd+right-drag calls); this only runs it on a copy first to get the diff.
        // Same base as `controlResizeColumn`: the area the strip is laid out over, not the window's
        // content area.
        let viewport = Double(ControlGeometry.contentSize(controller)?.width ?? 1000)
        let now = controller.controlColumnWidth(of: hit.pane, workspace: hit.workspace) ?? 0
        let after = strip.resizingWidth(of: hit.pane, delta: deltaPoints / max(viewport, 1))
        let next = after.position(of: hit.pane).map { after.columns[$0.col].widthFactor } ?? now
        var changes: [ControlChange] = []
        if abs(next - now) >= 0.0005 {
            changes.append(ControlChange("\(base).width", from: Self.number(now), to: Self.number(next)))
        }
        return (changes, {
            controller.controlResizeColumn(hit.pane, workspace: hit.workspace,
                                           deltaPoints: CGFloat(deltaPoints))
        })
    }

    // MARK: resize parts

    /// Compare the ratios of two trees split by split (the structure is unchanged, so a pre-order
    /// walk lines them up one to one)
    static func splitChanges(before: SplitTree<PaneView>, after: SplitTree<PaneView>,
                             workspacePath: String) -> [ControlChange] {
        let old = ControlGeometry.splits(in: before, size: ControlGeometry.unit)
        let new = ControlGeometry.splits(in: after, size: ControlGeometry.unit)
        guard old.count == new.count else { return [] }
        var out: [ControlChange] = []
        for (a, b) in zip(old, new) where abs(a.ratio - b.ratio) >= 0.0005 {
            out.append(ControlChange(splitChangePath(workspacePath, a.path),
                                     from: number(a.ratio), to: number(b.ratio)))
        }
        return out
    }

    /// The spelling in a diff has the same shape as `state`'s JSON: `1:2.tree.a.b.ratio`
    static func splitChangePath(_ workspacePath: String, _ path: String) -> String {
        path.isEmpty ? "\(workspacePath).tree.ratio" : "\(workspacePath).tree.\(path).ratio"
    }

    static func splitPaths(of controller: MainWindowController, workspace: Int) -> [String] {
        guard case .dwindle(let tree) = controller.model.layouts[workspace] else { return [] }
        return ControlGeometry.splits(in: tree, size: ControlGeometry.unit).map(\.path)
    }

    /// The root divider is called `root` on the command line (its path is the empty string, which
    /// cannot be typed)
    static func quoted(_ path: String) -> String { path.isEmpty ? "root" : path }

    static func direction(_ raw: String) -> ScrollingStrip.Direction? {
        switch raw {
        case "left": .left
        case "right": .right
        case "up": .up
        case "down": .down
        default: nil
        }
    }

    static func name(_ direction: ScrollingStrip.Direction) -> String {
        switch direction {
        case .left: "left"
        case .right: "right"
        case .up: "up"
        case .down: "down"
        }
    }

    /// Positive numbers only (the direction comes from `--dir`, and a second sign on top would
    /// only fight with it)
    static func magnitude(_ raw: String, flag: String) throws -> Double {
        let value = try number(raw, flag: flag)
        guard value > 0 else {
            throw ControlErrorBody(.badRequest, "\(flag) has to be a positive number (the direction comes from --dir), got \(raw)")
        }
        return value
    }

    static func number(_ raw: String, flag: String) throws -> Double {
        guard let value = Double(raw.trimmingCharacters(in: .whitespaces)) else {
            throw ControlErrorBody(.badRequest, "\(flag) is not a number: \(raw)")
        }
        return value
    }

    /// `+0.05` / `-0.05` (a delta) or `0.33` (absolute). **Only a signed number is a delta** - if
    /// a bare number counted as one too, `--width 0.5` would keep growing the column width while
    /// the caller believed it was assigning a value
    static func applyDelta(_ raw: String, to current: Double, flag: String) throws -> Double {
        let text = raw.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("+") || text.hasPrefix("-") {
            guard let delta = Double(text) else {
                throw ControlErrorBody(.badRequest, "\(flag) is not a number: \(raw)")
            }
            return current + delta
        }
        guard let absolute = Double(text) else {
            throw ControlErrorBody(.badRequest, "\(flag) is not a number: \(raw)")
        }
        return absolute
    }

    static func number(_ value: Double) -> String { String(format: "%.3f", value) }
}
