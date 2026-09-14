import Foundation

/// **What an agent in a pane is doing** (plan §2.4).
///
/// Six coarse states, because six is what a person glancing at a strip — or an agent deciding
/// whether to interrupt one — can act on. The fine grain lives in `AgentDetail`, and the two are
/// not independent: a detail belongs to exactly one state, which `AgentStateTag` enforces at rule
/// load time so no rule file can invent `idle:approval`.
enum AgentState: String, Codable, Equatable, CaseIterable {
    /// Waiting for the human to say something; nothing is running.
    case idle
    /// Thinking, or running a tool.
    case working
    /// **Waiting for the human**: an approval, an answer, a choice. This is what raises an alarm.
    case blocked
    /// The turn finished.
    case done
    /// The turn failed.
    case error
    /// A process we recognise is running in the pane and it has told us nothing (the scan's
    /// evidence, before any hook is heard).
    case unknown

    /// The pane needs a human. `error` counts: a failed turn is something to go and look at, and
    /// it is where the agent stopped.
    var needsUser: Bool { self == .blocked || self == .error }
}

/// What kind of working / blocked. Each one belongs to exactly one state (see `coarse`).
enum AgentDetail: String, Codable, Equatable, CaseIterable {
    case thinking
    case tool
    case approval
    case input
    case choice

    /// The state this detail is only ever allowed to appear under.
    var coarse: AgentState {
        switch self {
        case .thinking, .tool: .working
        case .approval, .input, .choice: .blocked
        }
    }
}

/// One pane's agent, as the registry holds it.
///
/// `tool` and `message` are the two halves of the title/body rule the notification centre already
/// keeps: a tool **name** is payload-free and may go anywhere, while `message` is the agent's own
/// words and is sensitive — it becomes a notice body, and it is `<redacted>` for a control-plane
/// caller without the token.
struct AgentStatus: Equatable {
    /// The rule id (`claude-code`).
    let agent: String
    /// The display name from the rule file (`Claude Code`).
    let name: String
    var state: AgentState
    var detail: AgentDetail?
    /// A tool name: payload-free.
    var tool: String?
    /// The agent's words, or the summary a rule file pointed at: **sensitive**.
    var message: String?
    /// When `(state, detail)` last changed — not when we last heard anything.
    var since: Date
    /// How we know: `.hook` / `.report` is the agent telling us, `.notification` is an OSC text,
    /// `.process` is only "something by that name is running here".
    var evidence: NoticeEvidence
    var sessionID: String?
    /// The last hook **or** report, whenever it was heard — including one no rule mapped. It is
    /// what the OSC fallback's recency window is measured against: an agent whose hooks are
    /// installed must not have its state overwritten by a notification arriving a moment later.
    var lastHookAt: Date?
    /// The process scan has found this agent's process in this pane at least once. Presence loss
    /// only releases an agent the scan had actually seen — an agent running as an interpreter
    /// (`node …/gemini.js`) is invisible to the scan and is released by its own `SessionEnd`.
    var seenByScan: Bool

    init(agent: String, name: String, state: AgentState, detail: AgentDetail? = nil,
         tool: String? = nil, message: String? = nil, since: Date, evidence: NoticeEvidence,
         sessionID: String? = nil, lastHookAt: Date? = nil, seenByScan: Bool = false) {
        self.agent = agent
        self.name = name
        self.state = state
        self.detail = detail
        self.tool = tool
        self.message = message
        self.since = since
        self.evidence = evidence
        self.sessionID = sessionID
        self.lastHookAt = lastHookAt
        self.seenByScan = seenByScan
    }

    /// This pane is waiting for a human.
    var needsUser: Bool { state.needsUser }
}

extension AgentStatus {
    /// **The one-line state text**, in the UI language — the words the info strip draws.
    ///
    /// It lives here rather than in the strip because the strip is not the only reader (a future
    /// settings or palette surface is the second), and because a key declared in the catalog with
    /// no call site fails `scripts/check-localization.py`: one owner for the nine keys, and the
    /// view asks for it.
    var localizedStateText: String {
        if let detail {
            switch detail {
            case .thinking: return L("agents.strip.thinking")
            case .tool: return L("agents.strip.tool")
            case .approval: return L("agents.strip.approval")
            case .input: return L("agents.strip.input")
            case .choice: return L("agents.strip.choice")
            }
        }
        switch state {
        case .idle: return L("agents.strip.idle")
        case .done: return L("agents.strip.done")
        case .error: return L("agents.strip.error")
        // A state with no detail that is not one of the three above: the agent is running and has
        // not said what it is doing. "Running" is the honest word for both.
        case .working, .blocked, .unknown: return L("agents.strip.unknown")
        }
    }
}
