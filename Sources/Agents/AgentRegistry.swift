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
    /// Per pane and per agent, the session that last ended there, for
    /// `AgentStateReducer.releasedSessionGrace`: its stragglers (a `Stop` whose async hook lost
    /// the race against the `SessionEnd`, the "task complete" text printed on the way out) are
    /// dropped instead of building the status back. Per agent, because two agents share a pane
    /// (`claude` from inside a `codex` shell tool) and one's live status must not clear the
    /// other's tombstone. Written only by a signal the origin gate let through, cleared when that
    /// agent's live status is written again, swept when expired, and dropped with the pane.
    private var tombstones: [UUID: [String: AgentStateReducer.ReleasedSession]] = [:]
    /// The request behind that notice, kept for the `.resolveFullyAndRearm` policy: re-arming
    /// means posting **the same thing again**, origin included, not a fresh guess.
    private var lastAlarm: [UUID: NoticeRequest] = [:]
    private var rearmTimers: [UUID: DispatchWorkItem] = [:]
    /// Agents we have already asked about installing hooks for, this launch.
    private var askedThisLaunch: Set<String> = []
    /// What each pane's program-status records were at the last `programStatusChanged`, with the
    /// source each one speaks under. The store's `onChange` also fires for changes that are not
    /// news (a refreshed foreground group, a new message), so a repeat is found by comparing
    /// against this, never by trusting the callback (spec decision 17).
    private var programSeen: [UUID: [SeenRecord]] = [:]

    private struct SeenRecord {
        var record: ProgramStatusStore.Record
        var source: NoticeSource
    }

    var settings = AgentSettings()
    /// Paces the band's program-status redraws (spec decision 18). Tests swap in one with a hand
    /// driven clock and scheduler.
    var bandThrottle = BandRedrawThrottle()
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
    /// The OSC 7501 records this registry reads (spec decision 10). The shared store in the app;
    /// a store of its own in a test, so a case never sees the test host's live panes.
    private let programStatus: ProgramStatusStore
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
         programStatus: ProgramStatusStore? = nil,
         clock: @escaping () -> Date = Date.init) {
        self.center = center ?? NoticeCenter.shared
        self.programStatus = programStatus ?? ProgramStatusStore.shared
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
        listenToProgramStatus()
        guard childExitedObserver == nil else { return }
        // The engine already posts this for every surface whose child exits, so the registry
        // observes it directly rather than making the engine grow a callback for one consumer.
        childExitedObserver = NotificationCenter.default.addObserver(
            forName: Ghostty.Notification.ghosttyChildExited, object: nil, queue: .main
        ) { note in
            MainActor.assumeIsolated {
                guard let pane = (note.object as? PaneView)?.id else { return }
                AgentRegistry.shared.apply(.childExited, pane: pane)
                ProgramStatusStore.shared.childExited(pane: pane)
            }
        }
    }

    private func install(_ loaded: [AgentRules]) {
        rules = Dictionary(uniqueKeysWithValues: loaded.map { ($0.id, $0) })
        ruleOrder = loaded.map(\.id)
    }

    /// Tests: swap the rule set wholesale.
    func reloadRulesForTesting(_ loaded: [AgentRules]) { install(loaded) }

    /// Become the store's one listener: every change of a pane's records comes through
    /// `programStatusChanged`. `attach` calls it for the app's registry; a test calls it on a
    /// registry built over a store of its own. Idempotent.
    func listenToProgramStatus() {
        programStatus.onChange = { [weak self] pane in self?.programStatusChanged(pane: pane) }
    }

    /// Tests: forget every pane, keep the rules.
    func resetForTesting() {
        programSeen.removeAll()
        statuses.removeAll()
        noticeIDs.removeAll()
        presence.removeAll()
        tombstones.removeAll()
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
        // Program status ranks above an OSC text too (spec decision 8): an agent reporting over
        // OSC 7501 is already telling us what it is doing.
        return evidence == .hook || evidence == .report || evidence == .programStatus
    }

    // MARK: The engine's ear

    @discardableResult
    func observeEngine(pane: UUID, _ signal: EngineSignal) -> EngineSignalOutcome {
        switch signal {
        case .notification(let title, let body):
            // A straggler of a session that ended is consumed too: the text is the agent's, and
            // the terminal has no business posting a banner the agent's own `done` notice
            // already covered (or the `done` switch turned off).
            let applied = applyDetailed(.notification(title: title, body: body),
                                        pane: pane, origin: nil)
            return applied.kind != .none || applied.straggler ? .consumed : .ignored
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
                                                          kind: AgentReduction.Kind,
                                                          straggler: Bool) {
        guard settings.detect else { return (AgentApplyOutcome(), .none, false) }
        let now = clock()
        let current = statuses[pane]
        sweepTombstones(pane: pane, now: now)

        // Every hook is also a hint that the process tree may have changed (an agent just
        // started, or is about to stop).
        if case .hook = signal { scanTrigger() }
        if case .processes(let found) = signal { presence[pane] = found }

        guard let (rules, reduction) = reduceAgainstCandidates(signal, pane: pane,
                                                              current: current, now: now) else {
            return (AgentApplyOutcome(status: current), .none, false)
        }

        switch reduction.kind {
        case .none:
            // Bookkeeping only (a `lastHookAt` bumped by an unmapped event, a `seenByScan` the
            // scan just confirmed): kept in the registry, never published, so nothing redraws.
            // A `SessionEnd` for a session nobody had heard of lands here too, and still says
            // its stragglers are not news.
            if let status = reduction.status { statuses[pane] = status }
            remember(reduction.released, pane: pane, now: now)
            maybeOfferHookInstall(rules, pane: pane, reduction: reduction)
            return (AgentApplyOutcome(status: reduction.status), .none, reduction.straggler)

        case .evidenceUpgrade, .annotated:
            // The hook caught up with the OSC text describing the same prompt. The strip learns
            // the tool name and the better evidence; the alarm already on screen is about this
            // very prompt and is left exactly as it is.
            writeStatus(reduction.status, pane: pane)
            return (AgentApplyOutcome(status: reduction.status), .evidenceUpgrade, false)

        case .changed, .released:
            // **The origin gate runs before anything is stored** (plan §1.4, §2.2). A refusal has
            // to be total, not just a refusal to resolve: a forged `Stop` that was answered
            // `origin_mismatch` but still left the pane in `done` would make the agent's own next
            // `Stop` — the same state, from the same rule — reduce to `.none`, never reach the
            // resolution path, and the alarm we promise to keep live would be one nobody could
            // ever take down. Refused with nothing to resolve = this signal never happened — the
            // tombstone included: a forged `SessionEnd` that left one behind would have the
            // owner's own next hooks dropped as stragglers.
            if current?.needsUser == true, reduction.status?.needsUser != true,
               let forecast = resolutionForecast(signal, pane: pane, origin: origin),
               forecast.resolved == 0, !forecast.refused.isEmpty {
                return (AgentApplyOutcome(status: current, refused: forecast.refused), .none, false)
            }

            // A session that ended stays ended for the grace window; a live status written for
            // an agent ends its own tombstone, and only its own — unless the scan wrote it: the
            // `SessionEnd` that left the tombstone also triggers a pass, which still finds the
            // process tearing down, and an `unknown` from that pass must not lift the tombstone
            // for the `Stop` that lands 50 ms later.
            remember(reduction.released, pane: pane, now: now)
            if reduction.kind == .changed, let status = reduction.status, status.evidence != .process {
                tombstones[pane]?[status.agent] = nil
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
            return (outcome, reduction.kind, false)
        }
    }

    /// Keeps a release as the pane's tombstone for that agent. A release that knows no session
    /// never replaces one that does inside the grace: the specific fact is the better one.
    private func remember(_ released: AgentStateReducer.ReleasedSession?, pane: UUID, now: Date) {
        guard let released else { return }
        if released.session == nil, let existing = tombstones[pane]?[released.agent],
           existing.session != nil,
           now.timeIntervalSince(existing.at) < AgentStateReducer.releasedSessionGrace {
            return
        }
        tombstones[pane, default: [:]][released.agent] = released
    }

    /// Expired tombstones are inert, but a pane that outlives many sessions would otherwise
    /// collect one per agent for ever.
    private func sweepTombstones(pane: UUID, now: Date) {
        guard let mine = tombstones[pane] else { return }
        let live = mine.filter { now.timeIntervalSince($0.value.at) < AgentStateReducer.releasedSessionGrace }
        tombstones[pane] = live.isEmpty ? nil : live
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
        case .notification, .programStatus:
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
        case .programStatus:
            // Records have a road of their own (`programStatusChanged`), which owns their alarms
            // as well: a record must never post through `handleNeedsUser`.
            return nil
        }
        var fallback: (AgentRules, AgentReduction)?
        var dropped: AgentRules?
        for rules in candidates {
            // A straggler of a session that already ended is not this rule's to reduce: it would
            // build a status back that nothing could ever take down again.
            if AgentStateReducer.isStraggler(signal, rules: rules, released: tombstones[pane]?[rules.id],
                                             now: now) {
                dropped = dropped ?? rules
                continue
            }
            let reduction = AgentStateReducer.reduce(signal, rules: rules, current: current, now: now)
            if reduction.kind != .none { return (rules, reduction) }
            if fallback == nil { fallback = (rules, reduction) }
        }
        if let dropped {
            // Consumed by the agent whose session ended, even though nothing moved: the caller
            // (the engine's ear, `agent-event`) must not treat it as unclaimed.
            var reduction = fallback?.1 ?? AgentReduction(status: current, kind: .none)
            reduction.straggler = true
            return (fallback?.0 ?? dropped, reduction)
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

    /// `publish: false` leaves the pane's own copy to the band throttle (program status, spec
    /// decision 18); everything else publishes at once.
    private func writeStatus(_ status: AgentStatus?, pane: UUID, publish: Bool = true) {
        statuses[pane] = status
        if status == nil {
            noticeIDs[pane] = nil
            lastAlarm[pane] = nil
        }
        // The pane publishes to its own observers and to nobody else's: the info strip watches
        // its pane, so one pane's agent churning redraws one frame (plan §1.5).
        if publish { locator.locate(pane)?.pane.setAgentStatus(status) }
    }

    // MARK: Notices

    private func handleNeedsUser(signal: PaneSignal, rules: AgentRules, before: AgentStatus?,
                                 after: AgentStatus?, pane: UUID, origin: NoticeOrigin?,
                                 outcome: inout AgentApplyOutcome) {
        let wasNeedsUser = before?.needsUser ?? false
        let isNeedsUser = after?.needsUser ?? false

        DiagnosticLog.shared.note(
            "agent",
            "\(rules.id) pane=\(describePane(pane)) signal=\(signal.label) state=\(before?.state.rawValue ?? "none")→\(after?.state.rawValue ?? "none") needsUser=\(wasNeedsUser)→\(isNeedsUser)")

        // The hook took over a prompt a report had raised: post again, so the alarm carries the
        // hook's evidence and origin (same key, so it supersedes the report's).
        let takesOverReport = before?.evidence == .programStatus
            && (after?.evidence == .hook || after?.evidence == .report)
        if isNeedsUser, !wasNeedsUser || takesOverReport, let status = after {
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
            case .notification, .programStatus:
                // A notification-evidenced alarm stored no origin and resolves; a hook-evidenced
                // one refuses, which is correct — an OSC "task complete" may not silence a hook's
                // approval prompt.
                let result = center.agentStateLeftNeedsUser(pane: pane, origin: nil)
                outcome.resolved = result.resolved
                outcome.refused = result.refused
            case .processes, .childExited:
                // The program is gone. Not origin-gated: this is in-process knowledge, and
                // `agent-gone` says on the wire why the prompt went away.
                // Not a program-status alarm: that program is not the agent, and its own record
                // (or its own exit) takes the alarm down.
                outcome.resolved = center.resolveAll(pane: pane, .agentGone, urgency: .needsUser,
                                                     includePrograms: false)
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

    /// `t3 (2E6E1B94, screen 1 workspace 2)` for the diagnostic log: the handle alone cannot show
    /// a status landing on the wrong pane, because the handle is all the log ever printed.
    private func describePane(_ pane: UUID) -> String {
        let id = String(pane.uuidString.prefix(8))
        guard let found = locator.locate(pane) else { return "\(locator.handle(pane) ?? "?") (\(id), gone)" }
        let handle = locator.handle(pane) ?? "?"
        return "\(handle) (\(id), screen \(found.controller.screenIndex + 1) workspace \(found.workspace + 1))"
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
        case .auth:
            return L("program-status.notice.auth", status.name)
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
        programSeen[pane] = nil
        statuses[pane] = nil
        noticeIDs[pane] = nil
        presence[pane] = nil
        tombstones[pane] = nil
        lastAlarm[pane] = nil
        rearmTimers.removeValue(forKey: pane)?.cancel()
        programStatus.paneClosed(pane)
    }

    /// What the program-status heartbeat reads from a pane's terminal: its pty foreground process
    /// group, and whether its process has exited. A pane that is not a terminal answers
    /// (nil, false). Tests replace it, because a real exited process is not something a case
    /// should have to spawn and wait for.
    var terminalProbe: @MainActor (PaneView) -> (foregroundGroup: Int32?, exited: Bool) = { pane in
        guard let surface = pane as? Ghostty.SurfaceView else { return (nil, false) }
        // `processExited` is true when there is no surface at all, which is not an exit.
        return (surface.foregroundProcessGroup, surface.surface != nil && surface.processExited)
    }

    /// The program-status half of the heartbeat (spec decision 5). A pane holding only program
    /// records has no status or notice here, so `paneClosed` never runs for it: the store's own
    /// panes the locator can no longer find are forgotten first. A pane held open after its
    /// process exited (wait-after-command) drops its live records; the engine's child-exit
    /// notification covers only some panes, so this is the backstop. Then every remaining record
    /// is checked against its pane's live pty foreground process group.
    func checkProgramStatus() {
        let store = programStatus
        for pane in store.panes {
            guard let found = locator.locate(pane) else {
                store.paneClosed(pane)
                continue
            }
            if terminalProbe(found.pane).exited { store.childExited(pane: pane) }
        }
        store.checkForeground { [locator, terminalProbe] pane in
            locator.locate(pane).flatMap { terminalProbe($0.pane).foregroundGroup }
        }
    }

    /// Called by the scan with the panes it can still see: anything we hold that the locator no
    /// longer finds is gone, whether or not the scan mentioned it.
    func dropPanesThatAreGone() {
        // Every map keyed by pane, not just the statuses: a pane that closed right after a
        // release has no status and no notice, and would otherwise keep its tombstone and its
        // last presence for the life of the process.
        let known = Set(statuses.keys).union(tombstones.keys).union(presence.keys)
        for pane in known where locator.locate(pane) == nil { paneClosed(pane) }
    }

    // MARK: Program status (OSC 7501, spec decisions 8–18)

    /// One pane's records changed. Two things follow, per source the records speak under:
    /// - **the agent's status** (`applyProgramStatus`), for records an enabled rule owns;
    /// - **the alarms** (`raiseProgramAlarms`), for every source, driven only by records whose
    ///   (state, kind, id) actually moved.
    ///
    /// A pane the locator cannot find is not acted on: the centre resolves its notices as
    /// `paneClosed` itself, and this may be running inside that very resolution (a sink must not
    /// write to the centre from its callback).
    func programStatusChanged(pane: UUID) {
        let before = programSeen[pane] ?? []
        guard locator.locate(pane) != nil else {
            programSeen[pane] = nil
            return
        }
        let active = Dictionary(activeRules.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let after = programStatus.records(pane: pane).map {
            SeenRecord(record: $0, source: programSource(of: $0.report, rules: active))
        }
        programSeen[pane] = after.isEmpty ? nil : after

        var sources: [NoticeSource] = []
        for source in (before + after).map(\.source) where !sources.contains(source) {
            sources.append(source)
        }
        for source in sources {
            let old = before.filter { $0.source == source }.map(\.record)
            let new = after.filter { $0.source == source }.map(\.record)
            var label = programLabel(source)
            // Whether this source is the agent holding the pane's status, before or after this
            // change: that agent speaks through `agent.state.changed`.
            var holds = false
            if case .agent(let id) = source, let rules = active[id] {
                holds = statuses[pane]?.agent == id
                // Only a source whose own records moved is reduced again. Another program's report
                // in the same pane is not news about this agent: re-reducing its unchanged records
                // would build back a status the scan has since released (a Codex `done` that then
                // mutes OSC 9) or put a stale `msg` over a newer hook message.
                guard old.map(\.report) != new.map(\.report) else { continue }
                // A straggler of a session that just ended is the agent's and is consumed: it
                // neither builds the status back nor posts a second "finished".
                guard applyProgramStatus(new, rules: rules, pane: pane) else { continue }
                holds = holds || statuses[pane]?.agent == id
                label = rules.name
            }
            raiseProgramAlarms(source: source, label: label, old: old, new: new, pane: pane)
            // Every other record has `program.status.changed`: a generic program's, and that of
            // an agent another agent's status holds the pane against (it has no state event).
            if !holds { emitProgramChanges(old: old, new: new, pane: pane) }
        }
        // The band redraws at most four times a second (spec decision 18): the pane's records
        // and any status a report moved are published through the throttle. The draw reads the
        // current values when it runs, so the last change of a burst is the one drawn.
        bandThrottle.request(pane) { [weak self] in
            guard let self, let view = self.locator.locate(pane)?.pane else { return }
            view.setProgramRecords(self.programStatus.records(pane: pane))
            view.setAgentStatus(self.statuses[pane])
        }
    }

    /// `program.status.changed` for a record no agent status speaks for (spec decision 19): a
    /// generic program's, or an agent's while another agent holds the pane. One event per record
    /// whose (state, kind) moved, appeared or went away (`cleared`). A progress step or a new
    /// message is not a transition. The holding agent's records speak through its
    /// `agent.state.changed` instead.
    private func emitProgramChanges(old: [ProgramStatusStore.Record], new: [ProgramStatusStore.Record],
                                    pane: UUID) {
        var oldByID: [[String]: ProgramStatusReport] = [:]
        for record in old { oldByID[record.report.id] = record.report }
        let newIDs = Set(new.map(\.report.id))
        var changed: [(report: ProgramStatusReport, cleared: Bool)] = []
        for record in new {
            let previous = oldByID[record.report.id]
            if let previous, previous.state == record.report.state, previous.kind == record.report.kind {
                continue
            }
            changed.append((record.report, false))
        }
        for record in old where !newIDs.contains(record.report.id) {
            changed.append((record.report, true))
        }
        guard !changed.isEmpty else { return }
        let located = locator.locate(pane)
        for (report, cleared) in changed {
            let message = cleared ? nil
                : report.message.map(ProgramStatusReport.displayText).flatMap { $0.isEmpty ? nil : $0 }
            let event = ControlEvent(
                type: .programStatusChanged,
                screen: located.map { $0.controller.screenIndex + 1 },
                screenID: located?.controller.windowID.uuidString,
                workspace: located.map { $0.workspace + 1 },
                pane: locator.handle(pane),
                paneID: pane.uuidString,
                kind: cleared ? nil : report.kind?.rawValue,
                state: cleared ? "cleared" : report.state.rawValue,
                message: message,
                app: report.app,
                id: report.id.joined(separator: "/"),
                progress: cleared ? nil : report.progress)
            bus.emit(event, redactable: message != nil, producer: .agentRegistry)
        }
    }

    /// Decision 11: an enabled agent's record speaks as that agent; anything else as
    /// `program:<app>` (or `program`).
    private func programSource(of report: ProgramStatusReport, rules: [String: AgentRules]) -> NoticeSource {
        ProgramStatusMapper.owner(of: report, rules: rules).map(NoticeSource.agent) ?? .program(report.app)
    }

    /// The name a generic program's notice titles use: its `app`, else "Program". Never its
    /// `title`, which is the program's own text: a notice title is payload-free by construction.
    private func programLabel(_ source: NoticeSource) -> String {
        if case .program(let app?) = source { return app }
        return L("program-status.generic")
    }

    /// The agent half: the most urgent of the agent's records (or "none left") reduced against
    /// the pane's status. No notice is posted or resolved here; `raiseProgramAlarms` owns them.
    /// false = the record was a straggler of a session that ended (nothing changed, and its
    /// alarms are not raised either).
    @discardableResult
    private func applyProgramStatus(_ records: [ProgramStatusStore.Record], rules: AgentRules,
                                    pane: UUID) -> Bool {
        let now = clock()
        sweepTombstones(pane: pane, now: now)
        let current = statuses[pane]
        let speaking: ProgramStatusStore.Record
        if case .program(let record)? = ProgramStatusMapper.winner(agent: nil, records: records) {
            speaking = record
        } else {
            // The reducer's spelling of "this agent has no records left in the pane".
            speaking = ProgramStatusStore.Record(
                report: ProgramStatusReport(state: .clear, kind: nil, progress: nil, id: [],
                                            app: rules.id, title: nil, message: nil),
                foregroundGroup: nil, updatedAt: now)
        }
        let signal = PaneSignal.programStatus(speaking)
        if AgentStateReducer.isStraggler(signal, rules: rules, released: tombstones[pane]?[rules.id],
                                         now: now) {
            return false
        }
        let reduction = AgentStateReducer.reduce(signal, rules: rules, current: current, now: now)
        switch reduction.kind {
        case .none:
            if let status = reduction.status { statuses[pane] = status }
        case .annotated, .evidenceUpgrade:
            // A progress step, a new message, or the same state from a better source: the strip
            // redraws (through the band throttle), nobody else hears about it.
            writeStatus(reduction.status, pane: pane, publish: false)
        case .changed, .released:
            remember(reduction.released, pane: pane, now: now)
            if reduction.kind == .changed, let status = reduction.status {
                tombstones[pane]?[status.agent] = nil
            }
            writeStatus(reduction.status, pane: pane, publish: false)
            emit(reduction.status, pane: pane, released: reduction.kind == .released, before: current)
            rearmTimers.removeValue(forKey: pane)?.cancel()
            DiagnosticLog.shared.note(
                "agent",
                "\(rules.id) pane=\(describePane(pane)) signal=program-status state=\(current?.state.rawValue ?? "none")→\(reduction.status?.state.rawValue ?? "none")")
        }
        return true
    }

    /// The alarm half, for one source (spec decisions 13, 16 and 17).
    ///
    /// - A record of a hook-tracked agent posts **nothing** under that agent's source: the key
    ///   (source, urgency, pane) would supersede the hook's alarm and drop its origin, after which
    ///   a report could resolve it.
    /// - Only records whose (state, kind, id) moved count; a repeat raises nothing.
    /// - `blocked` posts a `needsUser` alarm for the most recent blocked record of the source (a
    ///   new kind supersedes it); when the source has no blocked record left, its alarms resolve —
    ///   **only its own** (`source:`), and with no origin, so a hook's stays.
    /// - `done` and `error` post an `info` notice: no Dock badge, resolved on focus.
    private func raiseProgramAlarms(source: NoticeSource, label: String,
                                    old: [ProgramStatusStore.Record], new: [ProgramStatusStore.Record],
                                    pane: UUID) {
        if case .agent(let id) = source, let status = statuses[pane], status.agent == id,
           status.lastHookAt != nil {
            return
        }
        // Decided on the live notice, not on the status: the pane's status can belong to another
        // agent (a printed OSC 9 text hands it over) while this agent's hook alarm is still up.
        // A report posting under the same key would supersede that alarm with an origin-less one,
        // and its next report could then resolve it.
        if case .agent = source,
           center.live(pane: pane).contains(where: {
               $0.source == source && $0.urgency == .needsUser
                   && ($0.origin != nil || $0.evidence != .programStatus)
           }) {
            return
        }
        var oldByID: [[String]: ProgramStatusReport] = [:]
        for record in old { oldByID[record.report.id] = record.report }
        let newIDs = Set(new.map(\.report.id))

        var touchesBlocked = false
        var finished: [ProgramStatusStore.Record] = []
        for record in new {
            let report = record.report
            let previous = oldByID[report.id]
            if let previous, previous.state == report.state, previous.kind == report.kind { continue }
            if previous?.state == .blocked || report.state == .blocked { touchesBlocked = true }
            if report.state == .done || report.state == .error { finished.append(record) }
        }
        for (id, report) in oldByID where !newIDs.contains(id) && report.state == .blocked {
            touchesBlocked = true
        }

        if touchesBlocked {
            if let blocked = new.filter({ $0.report.state == .blocked }).max(by: { $0.updatedAt < $1.updatedAt }) {
                postProgramNotice(blocked.report, source: source, label: label, urgency: .needsUser,
                                  pane: pane)
            } else {
                center.resolveAll(pane: pane, .stateChanged, urgency: .needsUser, source: source)
            }
        }
        if let latest = finished.max(by: { $0.updatedAt < $1.updatedAt }),
           latest.report.state == .error || center.settings.done {
            postProgramNotice(latest.report, source: source, label: label, urgency: .info, pane: pane)
        }
    }

    private func postProgramNotice(_ report: ProgramStatusReport, source: NoticeSource, label: String,
                                   urgency: NoticeUrgency, pane: UUID) {
        let body = report.message.map(ProgramStatusReport.displayText).flatMap { $0.isEmpty ? nil : $0 }
        center.post(NoticeRequest(source: source, pane: pane, urgency: urgency,
                                  evidence: .programStatus,
                                  title: programTitle(report, label: label), body: body,
                                  bodySensitive: true, origin: nil))
        DiagnosticLog.shared.note(
            "program-status",
            "post pane=\(describePane(pane)) source=\(source.id) state=\(report.state.rawValue) kind=\(report.kind?.rawValue ?? "none") urgency=\(urgency.rawValue)")
    }

    /// Payload-free, like `composedTitle`: the agent's or program's name and what it is waiting
    /// for. The program's words go in the body.
    private func programTitle(_ report: ProgramStatusReport, label: String) -> String {
        switch ProgramStatusMapper.state(of: report) {
        case (_, .approval?): return L("notice.agent.approval.no-tool", label)
        case (_, .auth?): return L("program-status.notice.auth", label)
        case (.done, _): return L("notice.agent.done", label)
        case (.error, _): return L("notice.agent.error.no-type", label)
        default: return L("notice.agent.input", label)
        }
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
