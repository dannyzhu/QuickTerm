import AppKit

/// Everything one command needs while it runs. The reason it exists is entirely practical: all
/// 19 Phase 2 commands need the same set of things (args, target, resolver, encoder, peer
/// identity, the subject the confirmation gate pinned), and threading those through one by one
/// would give every signature seven or eight parameters, so changing one means touching nineteen.
@MainActor
struct ControlContext {
    let spec: ControlCommandSpec
    let request: ControlRequest
    let peer: ControlSocket.Peer
    let target: ControlTarget?
    let resolver: ControlResolver
    let encoder: ControlStateEncoder
    let pinned: ControlCommandRunner.PinnedSubject?

    // MARK: Reading arguments (**not written = nil**; never invent a default on the caller's
    // behalf - "no --zoom at all" and "--zoom off" are two completely different things)

    func string(_ name: String) -> String? {
        guard let raw = request.args[name]?.stringValue, !raw.isEmpty else { return nil }
        return raw
    }

    /// **An empty string still counts as given** (`--title ""` = clear the title, which is not the
    /// same thing as "no --title"). Everywhere else use `string(_:)`: there an empty string really
    /// is synonymous with absent, here it is not
    func rawString(_ name: String) -> String? { request.args[name]?.stringValue }

    func strings(_ name: String) -> [String] {
        guard let value = request.args[name] else { return [] }
        if let list = value.arrayValue { return list.compactMap(\.stringValue) }
        return value.stringValue.map { [$0] } ?? []
    }

    func int(_ name: String) -> Int? { request.args[name]?.intValue }
    func double(_ name: String) -> Double? { request.args[name]?.doubleValue }
    func flag(_ name: String) -> Bool { request.args[name]?.boolValue ?? false }

    /// `on|off` as three states: nil = the switch was not given at all
    func onOff(_ name: String) throws -> Bool? {
        guard let raw = string(name) else { return nil }
        switch raw.lowercased() {
        case "on", "true", "yes", "1": return true
        case "off", "false", "no", "0": return false
        default:
            throw ControlErrorBody(.badRequest, "--\(name) takes on / off only, got \(raw)",
                                   candidates: ["on", "off"])
        }
    }

    /// `--where` -> the drop zone. `nil` = let the app pick its own default landing spot
    func zone(_ name: String = "where") throws -> TerminalSplitDropZone? {
        guard let raw = string(name) else { return nil }
        switch raw {
        case "right": return .right
        case "left": return .left
        case "up": return .top
        case "down": return .bottom
        // Merge into the vertical stack the anchor sits in; in a scrolling layout a "stack" is
        // just one more layer added down the column.
        case "stack": return .bottom
        default:
            throw ControlErrorBody(.badRequest, "--\(name) takes right / left / up / down / stack only",
                                   candidates: ["right", "left", "up", "down", "stack"])
        }
    }

    /// A second target carried in the arguments (`--at` / `--with` / `--to`)
    func parseTarget(_ name: String) throws -> ControlTarget? {
        guard let raw = string(name) else { return nil }
        do {
            return try ControlTarget.parse(raw)
        } catch {
            throw ControlErrorBody(.badTarget, "--\(name) \(raw): \(error)",
                                   hint: ControlTarget.grammarLines.joined(separator: " / "))
        }
    }
}

@MainActor
extension ControlCommandRunner {
    /// Resolve down to one concrete pane (with no pane segment written, take the focused pane
    /// from the context)
    struct PaneHit {
        var controller: MainWindowController
        var workspace: Int
        var pane: PaneView
        var echo: ResolvedTarget
    }

    func requirePane(_ ctx: ControlContext, _ target: ControlTarget?) throws -> PaneHit {
        var effective = target ?? ControlTarget()
        if effective.pane == nil { effective.pane = .focused }
        let resolution = try ctx.resolver.resolve(effective)
        guard let pane = resolution.pane else {
            throw ControlErrorBody(.notFound, "No pane to address",
                                   hint: "quickterm list panes shows the handles that exist.")
        }
        resolution.controller.flushPendingCloses()
        // Check again after the flush: a pane that is fading out gets genuinely removed when its
        // time is up, so by the moment we act it may no longer be in the layout at all.
        guard resolution.controller.model.allPanes.contains(where: { $0 === pane }) else {
            throw ControlErrorBody(.notFound, "The target pane is no longer in the layout (it may have just been closed)",
                                   hint: "Read quickterm state again.")
        }
        return PaneHit(controller: resolution.controller, workspace: resolution.workspace,
                       pane: pane, echo: resolution.echo)
    }

    /// Resolve down to one screen + one workspace (there need not be a pane)
    func requireScope(_ ctx: ControlContext, _ target: ControlTarget?) throws -> ControlResolver.Resolution {
        let resolution = try ctx.resolver.resolve(target)
        resolution.controller.flushPendingCloses()
        return resolution
    }

    func handleName(_ pane: PaneView) -> String { ControlHandleRegistry.shared.handle(for: pane) }

    /// Path notation for diffs: the same shape as the addressing grammar (`1:2.t7`), so the diff
    /// an agent reads and the target it types in its next command are one vocabulary
    func path(_ controller: MainWindowController, _ workspace: Int? = nil, _ pane: PaneView? = nil) -> String {
        var out = String(controller.screenIndex + 1)
        if let workspace { out += ":\(workspace + 1)" }
        if let pane { out += ".\(handleName(pane))" }
        return out
    }

    func paneInfo(_ hit: PaneHit, encoder: ControlStateEncoder) -> ControlStatePayload.PaneInfo {
        paneInfo(hit.pane, controller: hit.controller, workspace: hit.workspace, encoder: encoder)
    }

    func paneInfo(_ pane: PaneView, controller: MainWindowController, workspace: Int,
                  encoder: ControlStateEncoder) -> ControlStatePayload.PaneInfo {
        let positions = ControlStateEncoder.positions(in: controller.model.layouts[workspace],
                                                     closing: controller.model.closingPanes)
        return encoder.paneInfo(pane, controller: controller, workspace: workspace,
                                at: positions[pane.id],
                                float: controller.controlIsFloating(pane, workspace: workspace),
                                zoomed: controller.controlIsZoomed(pane, workspace: workspace))
    }

    /// The confirmation gate approved **this one** subject: re-check its identity before acting.
    /// During the ten seconds the user spends reading the prompt, a mutating command that needs no
    /// confirmation is entirely free to move the focus / the layout out from under us
    func verifyPinned(_ ctx: ControlContext, controller: MainWindowController,
                      workspace: Int? = nil, pane: PaneView? = nil) throws {
        guard let pinned = ctx.pinned else { return }
        var drifted = pinned.controller !== controller
        if let workspace, pinned.workspace != workspace { drifted = true }
        if let pane {
            if pinned.pane !== pane { drifted = true }
            if controller.model.closingPanes.contains(pane.id) { drifted = true }
        }
        if let pinnedPaneIDs = pinned.paneIDs, let workspace, !drifted {
            let now = Set((controller.model.layouts[workspace].paneList
                           + controller.model.floatings[workspace].map(\.pane)).map(\.id))
            if now != pinnedPaneIDs { drifted = true }
        }
        guard !drifted else {
            throw ControlErrorBody(
                .busy, "The target changed while the confirmation prompt was up "
                    + "(what was confirmed: \(pinned.description)): nothing was done",
                hint: "Send it again, or name the target exactly with -t.", retryAfterMs: 200)
        }
    }

    /// The `spec apply` flavour of the same thing: the prompt named **a batch** of workspaces
    /// (more than one under screen / session scope), so re-check them one by one before acting -
    /// if any single one in the batch has drifted, the whole command lands nothing
    func verifyPinnedScopes(_ ctx: ControlContext,
                            targets: [(controller: MainWindowController, workspace: Int)]) throws {
        guard let pinned = ctx.pinned else { return }
        var drifted = pinned.scopes.count != targets.count
        for (scope, target) in zip(pinned.scopes, targets) where !drifted {
            guard scope.controller === target.controller, scope.workspace == target.workspace else {
                drifted = true
                break
            }
            let closing = target.controller.model.closingPanes
            let now = Set((target.controller.model.layouts[target.workspace].paneList
                           + target.controller.model.floatings[target.workspace].map(\.pane))
                .filter { !closing.contains($0.id) }.map(\.id))
            if now != scope.paneIDs { drifted = true }
        }
        guard !drifted else {
            throw ControlErrorBody(
                .busy, "The target changed while the confirmation prompt was up "
                    + "(what was confirmed: \(pinned.description)): nothing was done",
                hint: "Send it again, or name the target exactly with -t.", retryAfterMs: 200)
        }
    }
}
