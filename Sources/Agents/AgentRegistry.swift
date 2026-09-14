import AppKit

/// **The one owner of "what is the agent in this pane doing"** (plan §2.5).
///
/// Four kinds of signal come in (`PaneSignal`), one reducer decides what they mean
/// (`AgentStateReducer`), and everything downstream is driven from the **transitions** it
/// produces: the pane's own `agentStatus` (which the info strip observes), one
/// `agent.state.changed` event, and — only when a pane starts or stops needing a human — one
/// notice posted or resolved.
///
/// Two invariants hold the whole design up:
/// - **transitions only.** A `working:tool` → `working:tool` hook touches the pane's status and
///   nothing else: the notification centre is never told, so `hook-detail = "tools"` does not
///   turn every tool call into a redraw of every mounted frame (plan §1.5).
/// - **a forger may add a notice, never remove one.** The origin handed in by `agent-event` is
///   stored on the notice it posts, and only that lineage may resolve it as `stateChanged`.
@MainActor
final class AgentRegistry: NoticeSink {
    static let shared = AgentRegistry()

    /// What `apply` did — everything `agent-event` needs to answer its caller.
    struct AgentApplyOutcome: Equatable {
        var status: AgentStatus?
        /// The state moved, so an event went out and `seq` moved with it.
        var changed: Bool
        var noticePosted: UUID?
        var resolved: Int
        /// Live alarms this signal was **refused** permission to resolve (a different lineage or
        /// session posted them).
        var refused: [UUID]

        init(status: AgentStatus? = nil, changed: Bool = false, noticePosted: UUID? = nil,
             resolved: Int = 0, refused: [UUID] = []) {
            self.status = status
            self.changed = changed
            self.noticePosted = noticePosted
            self.resolved = resolved
            self.refused = refused
        }
    }

    /// What the engine can tell us. The registry's ear on `GhosttyNoticeProducer`.
    enum EngineSignal: Equatable {
        case notification(title: String, body: String)
        case commandFinished
    }

    /// `consumed` = a rule matched and the registry owns this signal, so the producer posts no
    /// `.terminal` notice of its own.
    enum EngineSignalOutcome: Equatable { case consumed, ignored }

    // MARK: State

    /// Loaded rule files by id (every loaded one, enabled or not: `agents list` and
    /// `hooks status` report what is loaded, `settings` decides what is acted on).
    private(set) var rules: [String: AgentRules] = [:]
    /// Load order, so "try every rule" is deterministic.
    private var ruleOrder: [String] = []
    private var statuses: [UUID: AgentStatus] = [:]
    /// The live `needsUser` notice this registry posted, per pane.
    private var noticeIDs: [UUID: UUID] = [:]
    /// What the last scan pass found in each pane, per rule (plan §2.5).
    private var presence: [UUID: AgentPresence] = [:]
    /// The request behind that notice, kept for the `.resolveFullyAndRearm` policy: re-arming
    /// means posting **the same thing again**, origin included, not a fresh guess.
    private var lastAlarm: [UUID: NoticeRequest] = [:]
    private var rearmTimers: [UUID: DispatchWorkItem] = [:]
    /// Agents we have already asked about installing hooks for, this launch.
    private var askedThisLaunch: Set<String> = []

    var settings = AgentSettings()
    /// Q1's answer, read here as well as in the centre: the centre decides what a keystroke does
    /// to a notice, the registry decides whether to re-arm afterwards.
    var policy: AgentPolicy.UserActed = AgentPolicy.userActed
    /// Set by `AppSession` once the control plane exists; nil in tests that do not care.
    weak var consent: ControlConsent?

    /// **Seam for the process scan** (package C): the registry asks for a scan on every hook and
    /// on the engine's `commandFinished`, and does not know what performs one. `ProcessScanner`
    /// assigns this when it installs itself; until then a scan request is a no-op, which is
    /// exactly right for a build without one.
    var scanTrigger: () -> Void = {}

    private var locator: NoticeLocating
    private let center: NoticeCenter
    private let bus: ControlEventBus
    private let clock: () -> Date
    private var childExitedObserver: NSObjectProtocol?

    // MARK: NoticeSink

    let sinkID = NoticeSinkID.agentRegistry
    var isEnabled = true

    /// The registry listens to the centre for two things only, and neither makes the centre know
    /// anything about the registry: a pane that closed (rule 4 resolves its notices, and this is
    /// where we hear about it) and, under the re-arm policy, the user having typed.
    func apply(_ change: NoticeChange) {
        switch change {
        case .resolved(let notice, _, _):
            switch notice.resolution {
            case .paneClosed:
                paneClosed(notice.pane)
            case .userActed:
                armRearmIfNeeded(pane: notice.pane)
            default:
                break
            }
        case .posted, .superseded, .quieted, .rearmed, .activityChanged, .countsChanged:
            break
        }
    }

    func clearAll() {}

    // MARK: Life cycle

    /// The app's registry. `bus` is written as nil rather than `.shared` for the same reason
    /// `ControlPlaneSink` does: a default argument is evaluated in a **nonisolated** context
    /// however isolated the initialiser is, and `ControlEventBus.shared` is main-actor isolated.
    init(rules: [AgentRules] = [], center: NoticeCenter? = nil, bus: ControlEventBus? = nil,
         locator: NoticeLocating = NoticeLocator.unattached,
         clock: @escaping () -> Date = Date.init) {
        self.center = center ?? NoticeCenter.shared
        self.bus = bus ?? ControlEventBus.shared
        self.locator = locator
        self.clock = clock
        install(rules)
    }

    /// Point the registry at the real screens, load the rule files, and start listening.
    /// Idempotent, and called right after the notification centre is attached.
    func attach(locator: NoticeLocating, userRuleDirectory: URL? = AgentRulesLoader.defaultUserDirectory) {
        self.locator = locator
        if rules.isEmpty {
            install(AgentRulesLoader.load(userDirectory: userRuleDirectory).rules)
        }
        center.addSink(self)
        guard childExitedObserver == nil else { return }
        // The engine already posts this for every surface whose child exits, so the registry
        // observes it directly rather than making the engine grow a callback for one consumer.
        childExitedObserver = NotificationCenter.default.addObserver(
            forName: Ghostty.Notification.ghosttyChildExited, object: nil, queue: .main
        ) { note in
            MainActor.assumeIsolated {
                guard let pane = (note.object as? PaneView)?.id else { return }
                AgentRegistry.shared.apply(.childExited, pane: pane)
            }
        }
    }

    private func install(_ loaded: [AgentRules]) {
        rules = Dictionary(uniqueKeysWithValues: loaded.map { ($0.id, $0) })
        ruleOrder = loaded.map(\.id)
    }

    /// Tests: swap the rule set wholesale.
    func reloadRulesForTesting(_ loaded: [AgentRules]) { install(loaded) }

    /// Tests: forget every pane, keep the rules.
    func resetForTesting() {
        statuses.removeAll()
        noticeIDs.removeAll()
        presence.removeAll()
        lastAlarm.removeAll()
        askedThisLaunch.removeAll()
        for timer in rearmTimers.values { timer.cancel() }
        rearmTimers.removeAll()
    }

    // MARK: Reading

    func status(pane: UUID) -> AgentStatus? { statuses[pane] }

    /// Every pane with a status, in no particular order — `agents list` walks addressable panes
    /// and looks each one up, so the order of this is not on the wire.
    var allStatuses: [UUID: AgentStatus] { statuses }

    /// The rules that are loaded **and** switched on, in load order.
    var activeRules: [AgentRules] {
        ruleOrder.compactMap { settings.isEnabled($0) ? rules[$0] : nil }
    }

    /// While a pane's status rests on a hook or a report, the engine's own OSC notifications and
    /// `commandFinished` post nothing: the agent is telling us precisely what it is doing, and a
    /// second, vaguer notice about the same moment is noise.
    func mutesEngineNotices(pane: UUID) -> Bool {
        guard let evidence = statuses[pane]?.evidence else { return false }
        return evidence == .hook || evidence == .report
    }

    // MARK: The engine's ear

    @discardableResult
    func observeEngine(pane: UUID, _ signal: EngineSignal) -> EngineSignalOutcome {
        switch signal {
        case .notification(let title, let body):
            let consumed = applyDetailed(.notification(title: title, body: body),
                                         pane: pane, origin: nil).kind != .none
            return consumed ? .consumed : .ignored
        case .commandFinished:
            // A scan trigger, never a state: a command finishing says nothing about an agent, but
            // it is a cheap moment to notice one appearing or going away.
            scanTrigger()
            return .ignored
        }
    }

    // MARK: Applying a signal

    @discardableResult
    func apply(_ signal: PaneSignal, pane: UUID, origin: NoticeOrigin? = nil) -> AgentApplyOutcome {
        applyDetailed(signal, pane: pane, origin: origin).outcome
    }

    private func applyDetailed(_ signal: PaneSignal, pane: UUID,
                               origin: NoticeOrigin?) -> (outcome: AgentApplyOutcome,
                                                          kind: AgentReduction.Kind) {
        guard settings.detect else { return (AgentApplyOutcome(), .none) }
        let now = clock()
        let current = statuses[pane]

        // Every hook is also a hint that the process tree may have changed (an agent just
        // started, or is about to stop).
        if case .hook = signal { scanTrigger() }
        if case .processes(let found) = signal { presence[pane] = found }

        guard let (rules, reduction) = reduceAgainstCandidates(signal, pane: pane,
                                                              current: current, now: now) else {
            return (AgentApplyOutcome(status: current), .none)
        }

        switch reduction.kind {
        case .none:
            // Bookkeeping only (a `lastHookAt` bumped by an unmapped event, a `seenByScan` the
            // scan just confirmed): kept in the registry, never published, so nothing redraws.
            if let status = reduction.status { statuses[pane] = status }
            maybeOfferHookInstall(rules, pane: pane, reduction: reduction)
            return (AgentApplyOutcome(status: reduction.status), .none)

        case .evidenceUpgrade:
            // The hook caught up with the OSC text describing the same prompt. The strip learns
            // the tool name and the better evidence; the alarm already on screen is about this
            // very prompt and is left exactly as it is.
            writeStatus(reduction.status, pane: pane)
            return (AgentApplyOutcome(status: reduction.status), .evidenceUpgrade)

        case .changed, .released:
            // **The origin gate runs before anything is stored** (plan §1.4, §2.2). A refusal has
            // to be total, not just a refusal to resolve: a forged `Stop` that was answered
            // `origin_mismatch` but still left the pane in `done` would make the agent's own next
            // `Stop` — the same state, from the same rule — reduce to `.none`, never reach the
            // resolution path, and the alarm we promise to keep live would be one nobody could
            // ever take down. Refused with nothing to resolve = this signal never happened.
            if current?.needsUser == true, reduction.status?.needsUser != true,
               let forecast = resolutionForecast(signal, pane: pane, origin: origin),
               forecast.resolved == 0, !forecast.refused.isEmpty {
                return (AgentApplyOutcome(status: current, refused: forecast.refused), .none)
            }

            var outcome = AgentApplyOutcome(status: reduction.status, changed: true)
            let before = current
            writeStatus(reduction.status, pane: pane)
            emit(reduction.status, pane: pane, released: reduction.kind == .released, before: before)
            handleNeedsUser(signal: signal, rules: rules, before: before, after: reduction.status,
                            pane: pane, origin: origin, outcome: &outcome)
            maybeOfferHookInstall(rules, pane: pane, reduction: reduction)
            // Any real signal about this pane makes a pending re-arm moot: the world has moved on.
            rearmTimers.removeValue(forKey: pane)?.cancel()
            return (outcome, reduction.kind)
        }
    }

    /// What the centre would say about this signal taking the pane out of `needsUser`, with the
    /// very origin `handleNeedsUser` will hand it — or nil for a signal the lineage rule does not
    /// gate at all.
    ///
    /// `.processes` and `.childExited` are the nil ones: the program is gone, that is in-process
    /// knowledge rather than somebody's claim, and their resolution is `agent-gone` and
    /// unconditional.
    private func resolutionForecast(_ signal: PaneSignal, pane: UUID,
                                    origin: NoticeOrigin?) -> NoticeCenter.StateChangeOutcome? {
        switch signal {
        case .hook, .report:
            return center.stateChangeForecast(pane: pane, origin: origin)
        case .notification:
            // The same nil `handleNeedsUser` passes: a notification-evidenced alarm stored no
            // origin and resolves, a hook-evidenced one refuses — an OSC "task complete" may not
            // silence a hook's approval prompt, nor quietly mark its pane done.
            return center.stateChangeForecast(pane: pane, origin: nil)
        case .processes, .childExited:
            return nil
        }
    }

    /// Which rule set this signal is about. A hook names its own; a notification or a scan result
    /// names none, so every enabled rule is tried and the first that yields something wins.
    private func reduceAgainstCandidates(_ signal: PaneSignal, pane: UUID, current: AgentStatus?,
                                         now: Date) -> (AgentRules, AgentReduction)? {
        var candidates: [AgentRules] = []
        switch signal {
        case .hook(let agent, _), .report(_, let agent, _, _):
            guard settings.isEnabled(agent), let rules = rules[agent] else { return nil }
            candidates = [rules]
        case .childExited:
            guard let agent = current?.agent, let rules = rules[agent] else { return nil }
            candidates = [rules]
        case .notification:
            // The pane's own agent first: a status that exists is the best guess at whose
            // notification this is, and trying the others first could hand the pane to a rule
            // that merely matches a common prefix.
            if let agent = current?.agent, let rules = rules[agent] { candidates = [rules] }
            candidates += activeRules.filter { $0.id != current?.agent }
        case .processes(let found):
            // A scan pass is routed, not tried: see below.
            return presenceCandidate(found, current: current, now: now)
        }
        var fallback: (AgentRules, AgentReduction)?
        for rules in candidates {
            let reduction = AgentStateReducer.reduce(signal, rules: rules, current: current, now: now)
            if reduction.kind != .none { return (rules, reduction) }
            if fallback == nil { fallback = (rules, reduction) }
        }
        return fallback
    }

    /// **A scan pass is routed per rule** (plan §2.4 rule 3), which is why it is not the loop
    /// above.
    ///
    /// The scan's name match already knows *whose* process it found, so a rule is only ever asked
    /// about its own presence, and a rule the pass did not find here is not asked at all — silence
    /// is not "the agent left", because that rule may never have been in this pane.
    ///
    /// Who may answer:
    /// - **a pane that has a status: only that status's rule.** Another rule's process appearing
    ///   is presence for *that* rule, never a reason to take the pane away from the agent whose
    ///   hook is speaking. Trying every rule is what let a `codex` process replace a live
    ///   `claude-code` approval with a fresh `unknown`, whereupon the alarm was resolved as
    ///   `agent-gone` — the pane's agent had, as far as the registry could tell, disappeared.
    /// - **a pane with no status: the first enabled rule the pass actually found here**, as
    ///   `unknown`/`process`.
    ///
    /// A pane whose agent is released while a second rule's process is still running gets that
    /// second agent on the next pass, not this one: one `apply` is one transition.
    private func presenceCandidate(_ found: AgentPresence, current: AgentStatus?,
                                   now: Date) -> (AgentRules, AgentReduction)? {
        if let current {
            // Not gated on the rule still being enabled: switching a rule off must not strand a
            // status it already owns, and presence loss is how that status is let go.
            guard let owner = rules[current.agent] else { return nil }
            return (owner, AgentStateReducer.reduce(.processes(found), rules: owner,
                                                    current: current, now: now))
        }
        for candidate in activeRules where !found.pids(for: candidate.id).isEmpty {
            let reduction = AgentStateReducer.reduce(.processes(found), rules: candidate,
                                                     current: nil, now: now)
            if reduction.kind != .none { return (candidate, reduction) }
        }
        return nil
    }

    private func writeStatus(_ status: AgentStatus?, pane: UUID) {
        statuses[pane] = status
        if status == nil {
            noticeIDs[pane] = nil
            lastAlarm[pane] = nil
        }
        // The pane publishes to its own observers and to nobody else's: the info strip watches
        // its pane, so one pane's agent churning redraws one frame (plan §1.5).
        locator.locate(pane)?.pane.setAgentStatus(status)
    }

    // MARK: Notices

    private func handleNeedsUser(signal: PaneSignal, rules: AgentRules, before: AgentStatus?,
                                 after: AgentStatus?, pane: UUID, origin: NoticeOrigin?,
                                 outcome: inout AgentApplyOutcome) {
        let wasNeedsUser = before?.needsUser ?? false
        let isNeedsUser = after?.needsUser ?? false

        if isNeedsUser, !wasNeedsUser, let status = after {
            let request = NoticeRequest(
                source: .agent(status.agent), pane: pane, urgency: .needsUser,
                evidence: status.evidence,
                title: composedTitle(status, rules: rules, signal: signal),
                body: status.message, bodySensitive: true, origin: origin)
            switch center.post(request) {
            case .posted(let id), .duplicate(let id):
                noticeIDs[pane] = id
                lastAlarm[pane] = request
                outcome.noticePosted = id
            case .superseded(_, let new):
                noticeIDs[pane] = new
                lastAlarm[pane] = request
                outcome.noticePosted = new
            case .unknownPane:
                break
            }
            return
        }

        if wasNeedsUser, !isNeedsUser {
            switch signal {
            case .hook, .report:
                // Only the lineage that posted the alarm may take it down. A refusal is reported,
                // never swallowed: it is the one case the whole rule exists to catch.
                let result = center.agentStateLeftNeedsUser(pane: pane, origin: origin)
                outcome.resolved = result.resolved
                outcome.refused = result.refused
            case .notification:
                // A notification-evidenced alarm stored no origin and resolves; a hook-evidenced
                // one refuses, which is correct — an OSC "task complete" may not silence a hook's
                // approval prompt.
                let result = center.agentStateLeftNeedsUser(pane: pane, origin: nil)
                outcome.resolved = result.resolved
                outcome.refused = result.refused
            case .processes, .childExited:
                // The program is gone. Not origin-gated: this is in-process knowledge, and
                // `agent-gone` says on the wire why the prompt went away.
                outcome.resolved = center.resolveAll(pane: pane, .agentGone, urgency: .needsUser)
            }
            if outcome.resolved > 0 {
                noticeIDs[pane] = nil
                lastAlarm[pane] = nil
            }
        }

        // A finished turn, when the user is not looking: information, never an alarm. `info`
        // notices never count toward the Dock badge and resolve the moment the pane is focused.
        if let status = after, status.state == .done, !wasNeedsUser || outcome.resolved > 0,
           center.settings.done {
            center.post(NoticeRequest(source: .agent(status.agent), pane: pane, urgency: .info,
                                      evidence: .composed, title: L("notice.agent.done", status.name),
                                      body: nil, bodySensitive: false))
        }
    }

    /// The notice title. **Payload-free by construction**: the agent's name, what it is waiting
    /// for, and a tool *name* or an error *type* — never a command line, which is what the body
    /// is for.
    private func composedTitle(_ status: AgentStatus, rules: AgentRules, signal: PaneSignal) -> String {
        switch status.detail {
        case .approval:
            if let tool = status.tool { return L("notice.agent.approval", status.name, tool) }
            return L("notice.agent.approval.no-tool", status.name)
        case .input:
            return L("notice.agent.input", status.name)
        case .choice:
            return L("notice.agent.choice", status.name)
        default:
            break
        }
        if status.state == .error {
            if let type = errorType(rules: rules, signal: signal) {
                return L("notice.agent.error", status.name, type)
            }
            return L("notice.agent.error.no-type", status.name)
        }
        // `blocked` with no detail cannot be produced by a rule file (a bare `blocked` fails at
        // load), so this is the honest catch-all for anything a future signal invents.
        return L("notice.agent.input", status.name)
    }

    private func errorType(rules: AgentRules, signal: PaneSignal) -> String? {
        guard case .hook(_, let payload) = signal else { return nil }
        return rules.fields.first(rules.fields.error, in: payload)
    }

    // MARK: Events

    private func emit(_ status: AgentStatus?, pane: UUID, released: Bool, before: AgentStatus?) {
        guard let subject = status ?? before else { return }
        let located = locator.locate(pane)
        let event = ControlEvent(
            type: .agentStateChanged,
            screen: located.map { $0.controller.screenIndex + 1 },
            screenID: located?.controller.windowID.uuidString,
            workspace: located.map { $0.workspace + 1 },
            pane: locator.handle(pane),
            paneID: pane.uuidString,
            agent: subject.agent,
            // A released agent is reported as `released`, not as its last state: "gone" and
            // "idle" are two different answers to "may I interrupt this pane".
            state: released ? "released" : subject.state.rawValue,
            detail: released ? nil : subject.detail?.rawValue,
            tool: released ? nil : subject.tool,
            evidence: released ? nil : subject.evidence.rawValue,
            message: released ? nil : subject.message)
        bus.emit(event, redactable: event.message != nil, producer: .agentRegistry)
    }

    // MARK: Pane life cycle

    /// Forget a pane. Two roads lead here and neither makes the centre know about the registry:
    /// the centre resolving that pane's notices as `.paneClosed` (this object is an ordinary
    /// sink), and a scan result naming a pane the locator can no longer find.
    func paneClosed(_ pane: UUID) {
        statuses[pane] = nil
        noticeIDs[pane] = nil
        presence[pane] = nil
        lastAlarm[pane] = nil
        rearmTimers.removeValue(forKey: pane)?.cancel()
    }

    /// Called by the scan with the panes it can still see: anything we hold that the locator no
    /// longer finds is gone, whether or not the scan mentioned it.
    func dropPanesThatAreGone() {
        for pane in statuses.keys where locator.locate(pane) == nil { paneClosed(pane) }
    }

    // MARK: The re-arm policy (Q1(c), off by default)

    private func armRearmIfNeeded(pane: UUID) {
        guard case .resolveFullyAndRearm(let seconds) = policy,
              let status = statuses[pane], status.needsUser,
              status.evidence == .hook || status.evidence == .report,
              let request = lastAlarm[pane] else { return }
        rearmTimers.removeValue(forKey: pane)?.cancel()
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.rearmTimers[pane] != nil else { return }
                self.rearmTimers[pane] = nil
                // Only if nothing has contradicted it since: any apply for this pane cancels.
                guard let current = self.statuses[pane], current.needsUser else { return }
                self.center.post(request)
            }
        }
        rearmTimers[pane] = item
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
    }

    // MARK: The auto-install ask

    /// The first time a pane runs an agent whose hooks are missing, offer to install them —
    /// once per agent per launch, and only for an agent that has an installer at all.
    private func maybeOfferHookInstall(_ rules: AgentRules, pane: UUID, reduction: AgentReduction) {
        guard reduction.status?.evidence == .process, rules.install != nil,
              settings.autoInstallHooks != "never",
              !askedThisLaunch.contains(rules.id),
              !HookInstaller.status(id: rules.id).installed else { return }
        askedThisLaunch.insert(rules.id)
        guard settings.autoInstallHooks == "ask" else {
            _ = try? HookInstaller.install(id: rules.id)
            return
        }
        guard let consent else { return }
        let path = rules.install?.config ?? ""
        consent.evaluate(.init(peerName: "QuickTerm", peerPID: getpid(), cls: .mutate,
                               summary: L("agents.install.ask", rules.name, path),
                               originPane: nil, originVerified: false, tokenPresent: true,
                               cacheable: true, scope: "hooks.install:\(rules.id)")) { decision in
            guard decision == .allow else { return }
            _ = try? HookInstaller.install(id: rules.id)
        }
    }
}
