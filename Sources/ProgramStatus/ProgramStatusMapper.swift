import Foundation

/// **How an OSC 7501 report reads in the agent model** (spec decisions 9, 11 and 14).
///
/// Pure functions, no state: whose report it is, which agent state it means, and which of a
/// pane's statuses is the one to show. The registry decides what happens because of them.
enum ProgramStatusMapper {
    /// What the band shows for a pane: its agent status, or one program-status record.
    enum Winner: Equatable {
        case agent(AgentStatus)
        case program(ProgramStatusStore.Record)
    }

    /// The rule id this report belongs to (decision 11): its `app` names a rule's id, or one of a
    /// rule's `process` names. nil = a generic program (`cargo`, or no `app` at all).
    ///
    /// `rules` is whatever the caller considers loaded and on; a process name claimed by two rules
    /// goes to the one whose id sorts first, so the answer never depends on dictionary order.
    static func owner(of report: ProgramStatusReport, rules: [String: AgentRules]) -> String? {
        guard let app = report.app else { return nil }
        if rules[app] != nil { return app }
        return rules.keys.sorted().first { rules[$0]?.process.contains(app) == true }
    }

    /// Decision 9's table. `clear` is never stored as a record; it reads as idle if asked.
    static func state(of report: ProgramStatusReport) -> (AgentState, AgentDetail?) {
        switch report.state {
        case .idle, .clear: return (.idle, nil)
        case .working: return (.working, nil)
        case .done: return (.done, nil)
        case .error: return (.error, nil)
        case .blocked:
            switch report.kind {
            case .permission: return (.blocked, .approval)
            case .auth: return (.blocked, .auth)
            // A question, or no kind at all: the program is waiting for an answer.
            case .question, nil: return (.blocked, .input)
            }
        }
    }

    /// Decision 14: the most urgent of the pane's agent status and its records, ordered
    /// blocked > error > working > done > idle, ties going to the most recently updated. nil when
    /// there is nothing at all.
    ///
    /// A `cargo` waiting for input outranks a hook-tracked agent that is merely working. An agent
    /// status the scan created (`unknown`) ranks with idle: it has told us nothing.
    static func winner(agent: AgentStatus?, records: [ProgramStatusStore.Record]) -> Winner? {
        var candidates: [(winner: Winner, rank: Int, at: Date)] = records.map {
            (.program($0), rank(state(of: $0.report).0), $0.updatedAt)
        }
        if let agent {
            let heard = max(agent.since, agent.lastHookAt ?? agent.since)
            candidates.append((.agent(agent), rank(agent.state), heard))
        }
        return candidates.max { a, b in
            a.rank != b.rank ? a.rank < b.rank : a.at < b.at
        }?.winner
    }

    /// The records that compete with `agent` for the band. The records of the agent holding the
    /// pane's status are already folded into that status (decision 12: while a hook speaks, they
    /// only add a progress and a message; without one, they are the status), so they are not a
    /// second candidate: a hook-tracked agent's own `blocked` report must not turn the band to
    /// "waiting". Every other record competes. `rules` is the set of loaded and enabled rules,
    /// the same set the registry decides ownership with.
    static func bandRecords(agent: AgentStatus?, records: [ProgramStatusStore.Record],
                            rules: [String: AgentRules]) -> [ProgramStatusStore.Record] {
        guard let agent else { return records }
        return records.filter { owner(of: $0.report, rules: rules) != agent.agent }
    }

    private static func rank(_ state: AgentState) -> Int {
        switch state {
        case .blocked: 4
        case .error: 3
        case .working: 2
        case .done: 1
        case .idle, .unknown: 0
        }
    }
}
