import Foundation

/// What one signal did to a pane's agent status.
struct AgentReduction: Equatable {
    /// The status after the signal; nil means the agent is gone from this pane.
    var status: AgentStatus?
    var kind: Kind

    enum Kind: Equatable {
        /// Nothing worth telling anyone about. `status` may still carry bookkeeping the registry
        /// keeps (a `lastHookAt` bumped by an event no rule maps, a `seenByScan` the scan just
        /// confirmed) — it is stored, it is not published.
        case none
        /// The same (state, detail) as before, now known from a better source: the hook caught up
        /// with the OSC text that described the same prompt. The strip is updated; **no notice is
        /// reposted**, because the alarm already on screen is about this very prompt.
        case evidenceUpgrade
        case changed
        case released
    }
}

/// **The one place precedence lives** (plan §2.4).
///
/// A rule file says what is agent-specific — which event means which state, where the text is.
/// Everything cross-agent is here, once: a hook beats everything, an OSC text may only speak when
/// no hook has been heard recently, the process scan is presence and never a state, and a child
/// exiting ends the story. Four sources, one function, and a fixed clock in the tests.
enum AgentStateReducer {
    /// How long a hook keeps the OSC fallback quiet. An agent whose hooks are installed emits
    /// both for the same prompt, milliseconds apart and in either order; without this window the
    /// text would overwrite the precise state with a guessed one.
    static let hookRecency: TimeInterval = 5

    static func reduce(_ signal: PaneSignal, rules: AgentRules, current: AgentStatus?,
                       now: Date) -> AgentReduction {
        // A status belonging to a different agent is not this signal's history: two agents in one
        // pane is a thing that happens (`claude` started from inside a `codex` session), and the
        // one that just spoke is the one the pane is showing.
        let mine = current?.agent == rules.id ? current : nil
        switch signal {
        case .hook(_, let payload):
            return reduceHook(payload, rules: rules, current: mine, now: now)
        case .report(_, _, let state, let message):
            return reduceReport(state: state, message: message, rules: rules, current: mine, now: now)
        case .notification(let title, let body):
            return reduceNotification(title: title, body: body, rules: rules, current: mine, now: now)
        case .processes(let presence):
            // A pane that already belongs to another rule is not this one's to claim — presence
            // may only create a status where *nothing* is known. The registry routes a scan pass
            // so that this rule is never even asked; the line is here as well because the sentence
            // above ("another agent's status is not this signal's history") is true for a hook and
            // dangerous for a scan, and a direct caller must not be able to get it wrong.
            if mine == nil, current != nil { return AgentReduction(status: current, kind: .none) }
            return reducePresence(presence.pids(for: rules.id), rules: rules, current: mine, now: now)
        case .childExited:
            return mine == nil ? AgentReduction(status: nil, kind: .none)
                               : AgentReduction(status: nil, kind: .released)
        }
    }

    // MARK: 1. Hooks and reports are authoritative

    private static func reduceHook(_ payload: AgentEventPayload, rules: AgentRules,
                                   current: AgentStatus?, now: Date) -> AgentReduction {
        guard let tag = rules.tag(for: payload) else {
            // An event this rule file does not map is still **news that the agent is alive**, and
            // the recency window is measured from "a hook was heard", not from "a hook changed
            // something": an unmapped `PostToolUse` must still keep the OSC fallback quiet.
            guard var status = current else { return AgentReduction(status: nil, kind: .none) }
            status.lastHookAt = now
            if let session = rules.fields.first(rules.fields.session, in: payload) {
                status.sessionID = session
            }
            return AgentReduction(status: status, kind: .none)
        }
        guard case .state(let state, let detail) = tag else {
            return AgentReduction(status: nil, kind: current == nil ? .none : .released)
        }
        var status = AgentStatus(
            agent: rules.id, name: rules.name, state: state, detail: detail,
            tool: rules.fields.first(rules.fields.tool, in: payload),
            message: rules.fields.first(rules.fields.summary, in: payload)
                ?? rules.fields.first(rules.fields.message, in: payload),
            since: now, evidence: .hook,
            sessionID: rules.fields.first(rules.fields.session, in: payload) ?? current?.sessionID,
            lastHookAt: now, seenByScan: current?.seenByScan ?? false)
        return settle(&status, current: current, now: now)
    }

    private static func reduceReport(state: AgentState, message: String?, rules: AgentRules,
                                     current: AgentStatus?, now: Date) -> AgentReduction {
        var status = AgentStatus(
            agent: rules.id, name: rules.name, state: state, detail: current?.detail.flatMap {
                // A detail only survives a report that stays in the same coarse state: carrying
                // `approval` into `working` would describe a prompt that has been answered.
                $0.coarse == state ? $0 : nil
            },
            tool: nil, message: message, since: now, evidence: .report,
            sessionID: current?.sessionID, lastHookAt: now,
            seenByScan: current?.seenByScan ?? false)
        return settle(&status, current: current, now: now)
    }

    // MARK: 2. A notification may only speak when no hook has been heard recently

    private static func reduceNotification(title: String, body: String, rules: AgentRules,
                                           current: AgentStatus?, now: Date) -> AgentReduction {
        if let heard = current?.lastHookAt, now.timeIntervalSince(heard) <= hookRecency {
            return AgentReduction(status: current, kind: .none)
        }
        guard let tag = rules.tag(title: title, body: body) else {
            return AgentReduction(status: current, kind: .none)
        }
        guard case .state(let state, let detail) = tag else {
            return AgentReduction(status: nil, kind: current == nil ? .none : .released)
        }
        var status = AgentStatus(
            agent: rules.id, name: rules.name, state: state, detail: detail,
            tool: nil, message: body.isEmpty ? nil : body, since: now, evidence: .notification,
            sessionID: current?.sessionID, lastHookAt: current?.lastHookAt,
            seenByScan: current?.seenByScan ?? false)
        return settle(&status, current: current, now: now)
    }

    // MARK: 3. The scan is presence, never a state

    /// `pids` is **this rule's** share of the pass, never the pane's whole process set: a rule is
    /// only ever released by its own agent leaving, and only ever creates a status for a process
    /// its own `process` list named.
    private static func reducePresence(_ pids: Set<pid_t>, rules: AgentRules,
                                       current: AgentStatus?, now: Date) -> AgentReduction {
        guard !pids.isEmpty else {
            // An agent the scan never saw — one running as an interpreter, whose executable is
            // `node` — is released only by its own SessionEnd or by the pane closing. Releasing it
            // here would wipe a live status the scan was never able to confirm in the first place.
            guard current?.seenByScan == true else { return AgentReduction(status: current, kind: .none) }
            return AgentReduction(status: nil, kind: .released)
        }
        guard var status = current else {
            return AgentReduction(
                status: AgentStatus(agent: rules.id, name: rules.name, state: .unknown,
                                    since: now, evidence: .process, seenByScan: true),
                kind: .changed)
        }
        guard !status.seenByScan else { return AgentReduction(status: status, kind: .none) }
        status.seenByScan = true
        return AgentReduction(status: status, kind: .none)
    }

    // MARK: Shared tail

    /// `since`, and which kind of change this is.
    ///
    /// `since` moves only when `(state, detail)` moves — it is "how long has it been waiting",
    /// which a repeated `PreToolUse` for the same tool must not reset. The kind is what decides
    /// whether anybody hears about it: a changed `(state, detail, tool)` is news; the same state
    /// arriving from a better source is an upgrade the strip wants and the centre does not; and a
    /// message changing on its own is neither.
    private static func settle(_ status: inout AgentStatus, current: AgentStatus?,
                               now: Date) -> AgentReduction {
        guard let current else { return AgentReduction(status: status, kind: .changed) }
        let sameState = current.state == status.state && current.detail == status.detail
        if sameState { status.since = current.since }
        if !sameState || current.tool != status.tool {
            return AgentReduction(status: status, kind: .changed)
        }
        if current.evidence != status.evidence,
           current.evidence == .notification || current.evidence == .process {
            return AgentReduction(status: status, kind: .evidenceUpgrade)
        }
        return AgentReduction(status: status, kind: .none)
    }
}
