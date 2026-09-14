import Foundation

/// **Which agents the latest scan found in one pane** (plan §2.4 rule 3).
///
/// Presence is kept **per rule**, and that is the entire point of the type. Two agents in one pane
/// is ordinary — a `claude` started from inside a `codex` session — and one merged pid set cannot
/// say which of them appeared or left. A merged set lets a rule that merely happens to be enabled
/// claim a pane whose hook is speaking for another agent, and it keeps an agent alive because its
/// *neighbour's* process is still running. Both of those are the same bug wearing two hats.
///
/// The scan never has to guess whose a process is: the executable-name match that finds it is also
/// what names its rule.
struct AgentPresence: Equatable, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    /// Rule id → that rule's pids in this pane. A rule that is **absent** has no process here,
    /// which is how one agent's presence is lost while another's stays.
    private(set) var byRule: [String: Set<pid_t>]
    /// Pids known to be an agent's without knowing whose. The scan never produces one — it always
    /// knows — but a caller holding nothing but pids can still say "something is running here",
    /// and then every rule is a candidate.
    private(set) var unattributed: Set<pid_t>

    init(byRule: [String: Set<pid_t>] = [:], unattributed: Set<pid_t> = []) {
        // An empty pid set is "no process", which is the same thing as not being in the map at
        // all: normalised here so that two spellings of the same pane never compare unequal.
        self.byRule = byRule.filter { !$0.value.isEmpty }
        self.unattributed = unattributed
    }

    /// `[]` / `[42]` — presence with no rule attribution.
    init(arrayLiteral elements: pid_t...) { self.init(unattributed: Set(elements)) }

    /// `["codex": [42]]` — the attributed form, which is what the scan produces.
    init(dictionaryLiteral elements: (String, Set<pid_t>)...) {
        self.init(byRule: Dictionary(elements, uniquingKeysWith: { $0.union($1) }))
    }

    /// What this rule has running in the pane. Unattributed pids count for every rule, because
    /// "an agent is here and we do not know which" is a claim about all of them.
    func pids(for rule: String) -> Set<pid_t> { (byRule[rule] ?? []).union(unattributed) }

    /// Nothing found. Spelled out rather than `AgentPresence()`, which the two literal
    /// initialisers make ambiguous.
    static let empty = AgentPresence(byRule: [:])

    /// Record one process against every rule whose `process` list named its executable.
    mutating func add(pid: pid_t, rules: some Sequence<String>) {
        for rule in rules { byRule[rule, default: []].insert(pid) }
    }
}

/// **Everything that can say something about a pane's agent** (plan §2.4).
///
/// One vocabulary, four sources, and the reducer is the only place that knows which of them wins.
/// Written as an enum rather than four entry points on the registry so that the precedence rules
/// are a `switch` somebody can read top to bottom, instead of four call sites each remembering
/// what the other three are allowed to overwrite.
enum PaneSignal: Equatable {
    /// A hook process reported an event about its own pane (`quickterm agent-event`).
    case hook(agent: String, payload: AgentEventPayload)
    /// A cooperating supervisor reported on an agent's behalf. Phase 3 feeds it; the reducer
    /// treats it exactly like a hook (same authority, same recency window) so the shim that
    /// arrives later needs no new rule.
    case report(source: String, agent: String, state: AgentState, message: String?)
    /// OSC 9 / 777 text from the pane — the fallback for an agent with no hooks installed.
    case notification(title: String, body: String)
    /// What the latest scan found in this pane, **per rule** (empty = nothing at all).
    case processes(AgentPresence)
    /// The pane's child process exited.
    case childExited

    /// A short, payload-free tag for the diagnostic log.
    var label: String {
        switch self {
        case .hook: "hook"
        case .report: "report"
        case .notification: "notification"
        case .processes: "processes"
        case .childExited: "child-exited"
        }
    }
}
