import AppKit

/// `notices list` / `notices ack` — the control plane's half of the notification centre.
///
/// The question this surface exists to answer is one an agent has no other way to ask: **is a
/// human already being asked for something?** Another pane holding an approval prompt is the one
/// case where "just ask the user" is the wrong move, and `notices list --needs-user` is one call
/// that answers it without reading anybody's screen.
///
/// Two rules run through the whole file:
/// - **panes, not notices.** `panesNeedingUser`, the workspace counts and the pane's `needsUser`
///   all count panes with at least one live `needs-user` notice; two prompts in one pane are one
///   thing for the user to go and handle.
/// - **the title is free, the body is not.** The notification centre composes every title out of an
///   agent id, a state and a tool *name*, so it carries no payload and is never redacted. The body
///   is the program's own words and follows the browser-URL rule exactly
///   (`ControlStateEncoder.exposesNoticeBody`).
@MainActor
extension ControlCommandRunner {
    func runNotices(_ ctx: ControlContext) throws -> (echo: ResolvedTarget?, data: any Encodable) {
        switch ctx.spec.verb {
        case "list": return try noticesList(ctx)
        case "ack": return try noticesAck(ctx)
        default:
            throw ControlErrorBody(.unknownCommand, "notices has no verb \(ctx.spec.verb)",
                                   candidates: ControlCommandTable.commands(inGroup: "notices").map(\.verb))
        }
    }

    // MARK: list

    /// What `-t` narrows this call to. Nothing given = the whole session, which is the reading an
    /// agent wants by default ("is anyone waiting for the user, anywhere").
    private struct NoticeScope {
        var pane: UUID?
        var screen: UUID?
        var workspace: Int?

        /// **Where the pane is now** (`NoticeCenter.location(of:)`), not where the notice was
        /// posted: `-t 1:3` has to find the alarm of a pane the caller has just moved there,
        /// and the count beside it is computed from the same reading (plan §1.1).
        ///
        /// `@MainActor` spelled out: a nested type does not inherit the extension's isolation,
        /// and this reads the centre.
        @MainActor func admits(_ notice: Notice) -> Bool {
            if let pane, notice.pane != pane { return false }
            let location = NoticeCenter.shared.location(of: notice)
            if let screen, location.screen != screen { return false }
            if let workspace, location.workspace != workspace { return false }
            return true
        }
    }

    private func noticesList(_ ctx: ControlContext) throws -> (ResolvedTarget?, any Encodable) {
        let center = NoticeCenter.shared
        var scope = NoticeScope()
        var echo: ResolvedTarget?

        // The target is read at the **precision it was written**: `-t 1` scopes to a screen, `-t
        // 1:2` to one workspace, `-t t7` to one pane. Resolving first and then always reading
        // `resolution.workspace` would silently narrow `-t 1` to that screen's active workspace,
        // and a caller asking "is anything pending on screen 1" would be told "no" while a
        // background workspace held an approval prompt.
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

        let needsUserOnly = ctx.flag("needs-user")
        var notices = center.live.filter(scope.admits)
        if needsUserOnly {
            notices = notices.filter { $0.urgency == .needsUser }
        } else if ctx.flag("history") {
            // Live first (post order), then the resolved ring (oldest first). `--needs-user` asks
            // "who is waiting right now", so history never joins that answer: a prompt that was
            // answered ten minutes ago is not somebody waiting.
            notices += center.history.filter(scope.admits)
        }

        // The count follows the same scope as the list, and it is **not** derived from the rows
        // above: `--needs-user` filters the rows, while this number answers "how many panes are
        // waiting" either way, so a caller can print the rows and branch on the count.
        let panesNeedingUser: Int
        if let pane = scope.pane {
            panesNeedingUser = center.urgency(pane: pane) == .needsUser ? 1 : 0
        } else {
            panesNeedingUser = center.needsUserCount(screen: scope.screen, workspace: scope.workspace)
        }

        return (echo, ControlNoticesPayload(notices: notices.map { ctx.encoder.noticeRecord($0) },
                                            panesNeedingUser: panesNeedingUser))
    }

    // MARK: ack

    private func noticesAck(_ ctx: ControlContext) throws -> (ResolvedTarget?, any Encodable) {
        // **A pane has to be named.** Everywhere else in the noun-verb layer an omitted pane
        // means "the focused one", and that default is exactly wrong here: acknowledging is
        // throwing an alarm away, and the pane that happens to hold focus while an agent runs a
        // command is rarely the pane that is waiting for the user.
        guard let target = ctx.target, target.pane != nil else {
            throw ControlErrorBody(
                .badRequest, "notices ack needs a pane: -t <handle>",
                hint: "quickterm notices list --needs-user names the panes that are waiting; "
                    + "pass one of their handles (-t t7).")
        }
        let hit = try requirePane(ctx, target)
        let center = NoticeCenter.shared
        let handle = handleName(hit.pane)
        let live = center.live(pane: hit.pane.id).count

        // An empty diff is how the whole noun-verb layer says "already in the requested state":
        // `commit` then skips `apply`, the second call is a silent success, and `--fail-if-noop`
        // turns it into exit 7. Nothing extra is needed here for idempotence.
        let changes = live == 0
            ? []
            : [ControlChange("notices.\(handle)", from: "\(live) live", to: "0")]
        let mutation = ControlMutationRequest(
            command: ctx.spec.name, request: ctx.request, peer: ctx.peer, changes: changes,
            controllers: [hit.controller],
            // Nothing to undo: a notice is not layout, and Cmd+Z putting an alarm back would be a
            // lie about a prompt that may well have been answered in the meantime.
            undoCommand: nil,
            target: path(hit.controller, hit.workspace, hit.pane))
        var payload = try commit(mutation) {
            _ = center.resolveAll(pane: hit.pane.id, .acknowledged)
        }
        payload.pane = paneInfo(hit, encoder: ctx.encoder)
        return (hit.echo, payload)
    }
}
