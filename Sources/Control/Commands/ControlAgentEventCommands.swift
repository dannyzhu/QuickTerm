import AppKit

/// `agent-event` — the hook script's road in (plan §2.2).
///
/// One hook process per lifecycle event, each one reporting **about its own pane**: the pane is
/// the proven origin (`QUICKTERM_PANE` + `QUICKTERM_PANE_TOKEN`), never a `-t` target, and the
/// gates in front of this function are the runner's own (`handle()`, the `cls == .report` block):
/// by the time we are called the pane is proven, addressable, and the report bucket has admitted
/// the call. What is left here is the payload and what it means:
///
/// 1. the agent id names a **loaded** rule file (else `bad_request` with the loaded ids);
/// 2. the `event` argument is at most `AgentEventPayload.maxStdinBytes` and decodes;
/// 3. **it is reduced again** — the CLI already reduced what it read on stdin, and this second
///    pass is what makes a hand-built `--event` no more powerful than a real hook: whatever
///    `transcript_path`, `cwd` or five-kilobyte file body somebody types in, only the whitelist
///    survives, clamped to 200 characters a field;
/// 4. the lineage comes from the **peer's pid**, not from anything the caller said about itself:
///    `ControlLineage.root(of:)` walks the parent chain to the direct child of QuickTerm the hook
///    descends from — the pane's own shell. That, plus the agent's session id, is the origin
///    stored on any alarm this event posts, and the only key that may take that alarm down again.
///
/// **A forger may add a notice; it may never remove one.** A resolution refused because the
/// lineage or the session does not match is logged and answered `origin_mismatch` — never
/// swallowed, because a silent refusal here reads to an agent exactly like a resolution.
@MainActor
extension ControlCommandRunner {
    func runAgentEvent(_ ctx: ControlContext) throws -> (echo: ResolvedTarget?, data: any Encodable) {
        // The report gate proved all of this already; re-reading it here keeps this function
        // honest on its own terms (it never trusts a field it did not check) and costs one
        // UUID parse.
        guard let raw = ctx.request.origin?.pane, let paneID = UUID(uuidString: raw) else {
            throw ControlErrorBody(
                .badRequest,
                "agent-event needs QUICKTERM_PANE and QUICKTERM_PANE_TOKEN in the environment "
                    + "(run it from a hook inside a QuickTerm pane)")
        }
        guard let entry = ControlResolver.addressablePanes(in: screens).first(where: { $0.pane.id == paneID })
        else {
            throw ControlErrorBody(.notFound, "That pane is not addressable any more")
        }
        let handle = handleName(entry.pane)

        let registry = AgentRegistry.shared
        // Sorted rather than in load order: `ruleOrder` is the registry's own business, and a
        // candidate list a human reads wants to be stable, not to mirror a directory walk.
        let loaded = registry.rules.keys.sorted()
        guard let id = ctx.string("agent") else {
            throw ControlErrorBody(.badRequest, "agent-event needs --agent <id>",
                                   hint: "The hook script passes the rule id it was installed for.",
                                   candidates: loaded)
        }
        // **Loaded**, not enabled: `[agents] enabled` decides what the registry acts on, and an
        // event for a switched-off agent is a no-op, not a caller error. A *typo* is a caller
        // error, and it is the one thing a human running this by hand needs to be told.
        guard registry.rules[id] != nil else {
            throw ControlErrorBody(.badRequest, "No agent rule named \(id) is loaded",
                                   hint: "quickterm agents list shows the rule ids QuickTerm loaded; "
                                       + "a user rule file goes in ~/.config/quickterm/agents.",
                                   candidates: loaded)
        }

        guard let text = ctx.string("event") else {
            throw ControlErrorBody(.badRequest, "agent-event needs --event <json> (the hook's payload)",
                                   hint: "The CLI builds it from stdin; passing it by hand is for tests.")
        }
        let data = Data(text.utf8)
        guard data.count <= AgentEventPayload.maxStdinBytes else {
            throw ControlErrorBody(
                .badRequest,
                "event is too large (\(data.count) bytes, limit \(AgentEventPayload.maxStdinBytes))",
                hint: "The hook script cuts stdin at the same limit; nothing larger can be a real hook payload.")
        }
        guard let decoded = try? ControlJSON.decoder.decode(AgentEventPayload.self, from: data) else {
            throw ControlErrorBody(.badRequest, "event is not a hook payload object",
                                   hint: "It needs at least a hook_event_name string.")
        }
        // The second reduction (see the note above). It is the same static function the CLI ran.
        guard let payload = AgentEventPayload.reduce(decoded) else {
            throw ControlErrorBody(.badRequest, "event names no hook event (hook_event_name is empty)")
        }

        let origin = NoticeOrigin(lineageRoot: ControlLineage.root(of: ctx.peer.pid),
                                  sessionID: payload.sessionID)
        let outcome = registry.apply(.hook(agent: id, payload: payload), pane: paneID, origin: origin)

        // Every refusal is an entry in the activity log naming the peer: that log is the record
        // the lineage rule promises the user, and the one place a forgery attempt shows up.
        for refused in outcome.refused {
            logRefusal(ctx.request.cmd, peer: ctx.peer, request: ctx.request, code: .originMismatch,
                       message: "cross-pane resolve refused for notice \(refused.uuidString)")
        }
        // Refused **and** nothing resolved = this event took nothing down; say so. If something
        // did resolve, the event did its job and the refusal of a second, foreign alarm in the
        // same pane is a log entry, not a failure of this call.
        if !outcome.refused.isEmpty, outcome.resolved == 0 {
            throw ControlErrorBody(
                .originMismatch,
                "this event may not resolve the alarm on pane \(handle): it was posted by a "
                    + "different process lineage or session",
                hint: "Only the agent that posted a prompt can take it down; the alarm stays live.")
        }

        // No `settleMutation()`: a report is not a mutation. `seq` in the response is whatever the
        // bus holds, which moved exactly when the registry emitted `agent.state.changed` — which
        // is what `changed` says.
        let payloadOut = ControlAgentEventPayload(
            pane: handle,
            agent: id,
            // A released agent is `released`, not its last state: "gone" and "idle" are two
            // different answers to "may I interrupt this pane" (the event says the same). With no
            // status and nothing changed — an unmapped event, or `[agents] detect = false` —
            // nothing is known about this pane's agent, which is what `unknown` says.
            state: outcome.status?.state.rawValue ?? (outcome.changed ? "released" : "unknown"),
            detail: outcome.status?.detail?.rawValue,
            changed: outcome.changed,
            noticeID: outcome.noticePosted?.uuidString,
            resolved: outcome.resolved)
        // No echo: there was no target to resolve. The pane is in the payload, by handle.
        return (nil, payloadOut)
    }
}
