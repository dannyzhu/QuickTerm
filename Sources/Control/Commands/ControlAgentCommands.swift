import AppKit

/// `agents list` — what each pane's agent is doing (plan §2.9).
///
/// This is the read that answers "may I interrupt?" one step earlier than `notices list` does.
/// A notice exists only while a pane is *waiting for the human*; an agent status exists for as
/// long as an agent is in the pane at all, so this surface also answers "is that pane busy",
/// "with which tool" and "since when" — the three things a second agent needs before it decides
/// to type into somebody else's workspace or to ask the user a question.
///
/// Two rules, both inherited rather than invented here:
/// - **panes, not agents.** One row per pane, in pane order, and a pane with no agent is simply
///   not listed: "no agent here" is the absence of a row, never a row full of nulls.
/// - **the state is free, the message is not.** `ControlStateEncoder.agentRecord` applies the
///   notice-body rule to `message` and to nothing else, so `agents list`, the `agent` field in
///   `state` and the `agent.state.changed` event all redact the same text for the same callers.
@MainActor
extension ControlCommandRunner {
    func runAgents(_ ctx: ControlContext) throws -> (echo: ResolvedTarget?, data: any Encodable) {
        switch ctx.spec.verb {
        case "list": return try agentsList(ctx)
        default:
            throw ControlErrorBody(.unknownCommand, "agents has no verb \(ctx.spec.verb)",
                                   candidates: ControlCommandTable.commands(inGroup: "agents").map(\.verb))
        }
    }

    // MARK: list

    /// What `-t` narrows the listing to, read at the **precision it was written** — the same
    /// rule `notices list` follows, and for the same reason: resolving `-t 1` and then reading
    /// the resolution's workspace would silently narrow a screen-wide question to that screen's
    /// *active* workspace, and a caller asking "is anything running on screen 1" would be told
    /// "no" while a background workspace held a blocked agent.
    private struct AgentScope {
        var pane: UUID?
        var screen: UUID?
        var workspace: Int?

        /// Where the pane **is**, taken from the walk itself rather than from anything stored on
        /// the status: a status outlives a `pane move`, and the row has to name where the human
        /// would go to look right now.
        ///
        /// `@MainActor` spelled out: a nested type does not inherit the extension's isolation,
        /// and this reads views and controllers.
        @MainActor func admits(_ entry: (pane: PaneView, controller: MainWindowController, workspace: Int)) -> Bool {
            if let pane, entry.pane.id != pane { return false }
            if let screen, entry.controller.windowID != screen { return false }
            if let workspace, entry.workspace != workspace { return false }
            return true
        }
    }

    private func agentsList(_ ctx: ControlContext) throws -> (ResolvedTarget?, any Encodable) {
        var scope = AgentScope()
        var echo: ResolvedTarget?

        if let target = ctx.target, !target.isEmpty {
            let resolution = try ctx.resolver.resolve(target)
            echo = resolution.echo
            if target.pane != nil {
                guard let pane = resolution.pane else {
                    throw ControlErrorBody(.notFound, "No pane to address",
                                           hint: "quickterm list panes shows the handles that exist.")
                }
                scope.pane = pane.id
            } else if target.workspace != nil {
                scope.screen = resolution.controller.windowID
                scope.workspace = resolution.workspace
            } else if target.screen != nil {
                scope.screen = resolution.controller.windowID
            }
        }

        // **Walk the panes, not the registry.** The registry may still hold a pane that closed
        // while the app was in the background (it is cleared by the next scan, plan §2.5), and a
        // row naming a pane nobody can address is worse than no row at all. Walking addressable
        // panes makes that impossible by construction, and gives every row its screen and
        // workspace for free.
        let registry = AgentRegistry.shared
        let agents = ControlResolver.addressablePanes(in: screens)
            .filter { scope.admits($0) }
            .compactMap { entry -> ControlAgentListEntry? in
                guard let status = registry.status(pane: entry.pane.id) else { return nil }
                return ControlAgentListEntry(
                    pane: ControlHandleRegistry.shared.handle(for: entry.pane),
                    paneID: entry.pane.id.uuidString,
                    screen: entry.controller.screenIndex + 1,
                    screenID: entry.controller.windowID.uuidString,
                    workspace: entry.workspace + 1,
                    agent: ctx.encoder.agentRecord(status))
            }

        return (echo, ControlAgentsPayload(agents: agents))
    }
}
