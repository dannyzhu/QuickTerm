import AppKit
import Combine

/// **A sink is one way of telling the user.** Each is independent and each is switchable; none of
/// them knows about any other.
///
/// Guarantees the centre makes to every sink:
/// - every call arrives on the main actor;
/// - `.posted` arrives *after* the notice is in `live`, `.resolved` *after* it has left, so
///   `live(pane:)`, `urgency(pane:)` and `counts` already reflect the change inside the callback;
/// - a sink is never called while `isEnabled == false`, and gets exactly one `clearAll()` at the
///   moment it is switched off.
@MainActor
protocol NoticeSink: AnyObject {
    /// One of `NoticeSinkID`'s constants.
    var sinkID: String { get }
    /// Driven by `NoticeCenter.settings`; never written by the sink itself.
    var isEnabled: Bool { get set }
    func apply(_ change: NoticeChange)
    /// Take everything down: the config turned this sink off, or the centre was reset.
    func clearAll()
}

/// **The notification centre** (spec §3.5, contract §10.3).
///
/// A general service, not an agent feature: anything in QuickTerm may post into it, and the six
/// sinks — system banner, Dock badge, pane mark, workspace pill, control plane, activity log —
/// are the only places that decide how a notice is shown. The centre itself draws nothing and
/// knows nothing about AppKit beyond asking its locator where a pane is.
///
/// The three rules that shape all of it (spec §3.5):
/// 1. one notice is **(source, urgency, pane)**, and the centre computes that key;
/// 2. **a post never lowers a pane** — an `info` while a `needsUser` is live is stored under its
///    own key and leaves the alarm alone; a pane's displayed urgency is the maximum over its
///    live notices;
/// 3. there is **no timeout**. An unanswered approval stays visible until it is answered.
@MainActor
final class NoticeCenter: ObservableObject {
    static let shared = NoticeCenter()

    /// How many resolved notices are remembered. `notices list --history` reads this ring; it is
    /// capped because a chatty pane would otherwise grow it without limit for the whole life of
    /// the process.
    static let historyCapacity = 200

    private var locator: NoticeLocating
    /// Injectable so a test can pin `postedAt` / `resolvedAt` instead of racing the wall clock.
    private let clock: () -> Date

    /// Live notices in **post order**. `@Published` so a future SwiftUI surface (the info strip)
    /// can observe it; the sinks are told through `apply`, not through this.
    @Published private(set) var live: [Notice] = []

    /// Resolved notices, oldest first, capped at `historyCapacity`.
    private(set) var history: [Notice] = []

    /// Notices about **QuickTerm itself** — no pane, no sinks, no resolution rules (see
    /// `AppNotice`). They last for the launch. `@Published` for the same reason `live` is: a
    /// surface that wants to draw one observes the centre rather than being pushed at.
    @Published private(set) var appNotices: [AppNotice] = []

    /// Panes with at least one live `needsUser`, and where each of them is. Recomputed after
    /// every change and handed to the sinks only when it actually moved.
    private(set) var counts = NoticeCounts()

    /// The `[notifications]` values. Writing it re-derives every registered sink's `isEnabled`.
    var settings = NoticeSettings() {
        didSet { applySettings() }
    }

    /// What "the user focused the pane and typed into it" does to a live alarm (plan §2.8).
    /// A stored var rather than a direct read of `AgentPolicy.userActed` so a test can drive all
    /// three answers; the app never writes it.
    var userActedPolicy: AgentPolicy.UserActed = AgentPolicy.userActed

    private var sinks: [NoticeSink] = []

    /// The activity each pane holding a live notice had at the last pass, so `.activityChanged`
    /// is only ever sent for a change that really happened.
    private var recordedActivity: [UUID: PaneActivity] = [:]

    private var activityPassScheduled = false
    private var applicationObservers: [NSObjectProtocol] = []

    /// Tests build their own centre with a stub locator; the app calls `attach` once at launch.
    init(locator: NoticeLocating = NoticeLocator.unattached, clock: @escaping () -> Date = Date.init) {
        self.locator = locator
        self.clock = clock
    }

    /// Point the centre at the real screens, and start watching the two application-wide halves
    /// of `PaneActivity` that no pane or window can report for itself.
    func attach(locator: NoticeLocating) {
        self.locator = locator
        guard applicationObservers.isEmpty else { return }
        for name in [NSApplication.didBecomeActiveNotification,
                     NSApplication.didResignActiveNotification] {
            let token = NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main
            ) { _ in
                // Delivered on the main queue, so this is the same `assumeIsolated` shape as
                // `ControlEventBus.noteChange()`.
                NoticeCenter.noteActivityChange()
            }
            applicationObservers.append(token)
        }
    }

    // MARK: Posting

    enum PostOutcome: Equatable {
        case posted(UUID)
        case duplicate(UUID)
        case superseded(old: UUID, new: UUID)
        /// The pane is not addressable (it never existed, or it is fading out).
        case unknownPane
    }

    /// Post a notice. The steps are in the order the contract states, and the order matters:
    /// nothing is stored for an unknown pane, an identical repost touches nothing at all, and the
    /// counts are recomputed before any sink is called so every callback sees one consistent
    /// world.
    @discardableResult
    func post(_ request: NoticeRequest) -> PostOutcome {
        // 1. A pane that is fading out is not addressable — same reading as `state`. Nothing is
        //    stored and nothing is logged: a notice against a pane that is already gone would be
        //    resolved as `.paneClosed` one turn later, which is noise, not information.
        guard let located = locator.locate(request.pane) else { return .unknownPane }

        // 2. Sanitise once, here, so every sink may trust `title` and `body` without filtering.
        let title = sanitizedTitle(request)
        let body = Notice.sanitizedBody(request.body)
        let key = Notice.key(source: request.source, urgency: request.urgency, pane: request.pane)
        let before = urgency(pane: request.pane)
        let now = clock()

        let existingIndex = live.firstIndex { $0.key == key }

        // 3. Identical content under the same key: a duplicate. Nothing changes — not `postedAt`,
        //    not one sink call. This is what stops `PermissionRequest` and the OSC notification
        //    that describes the *same* prompt from re-presenting the banner with sound twice.
        if let index = existingIndex, live[index].title == title, live[index].body == body {
            return .duplicate(live[index].id)
        }

        let notice = Notice(
            id: UUID(), key: key, source: request.source, pane: request.pane,
            screen: located.controller.windowID, workspace: located.workspace,
            urgency: request.urgency, evidence: request.evidence, title: title, body: body,
            bodySensitive: request.bodySensitive, origin: request.origin, postedAt: now,
            quietedAt: nil, resolvedAt: nil, resolution: nil)

        // 4./5. Same key, different content: the old one is superseded and the new one takes its
        //       place. Otherwise this is simply a new notice.
        var superseded: Notice?
        if let index = existingIndex {
            var old = live.remove(at: index)
            old.resolvedAt = now
            old.resolution = .superseded
            appendToHistory(old)
            superseded = old
        }
        live.append(notice)

        let after = urgency(pane: request.pane)
        let transition = PaneTransition(pane: request.pane, before: before, after: after)
        let activity = locator.activity(request.pane)
        noteActivity(request.pane, activity)
        let countsMoved = recomputeCounts()

        if let superseded {
            dispatch(.superseded(old: superseded, new: notice, transition, activity))
        } else {
            dispatch(.posted(notice, transition, activity))
        }
        // 6. The counts call always comes *after* the posted/superseded call: a sink that draws
        //    both a per-pane mark and a per-screen number wants the pane state first.
        if countsMoved { dispatch(.countsChanged(counts)) }

        return superseded.map { .superseded(old: $0.id, new: notice.id) } ?? .posted(notice.id)
    }

    // MARK: App notices

    /// Post something the app has to say about itself. Returns nil when the same thing is already
    /// on the list.
    ///
    /// Deduplicated by `AppNotice.key`, which is the same rule a pane notice follows minus the
    /// pane. That is a second lock on top of whatever latch the poster keeps: "tell the user once
    /// per launch" must hold even if two roads discover the same fact (the authorization probe at
    /// launch, and the first banner that macOS refuses, both learn that notifications are denied).
    ///
    /// No sink is told. There is nothing pane-shaped for a sink to draw, and the two surfaces that
    /// do read this — the control plane's `notices list` and the in-app activity log — are written
    /// by the poster itself, which is also the only thing that knows whether the fact is worth a
    /// log line at all.
    @discardableResult
    func postAppNotice(source: NoticeSource, urgency: NoticeUrgency, evidence: NoticeEvidence,
                       title: String, body: String? = nil) -> AppNotice? {
        let cleaned = Notice.sanitizedTitle(title)
        let notice = AppNotice(
            id: UUID(), source: source, urgency: urgency, evidence: evidence,
            title: cleaned.isEmpty ? L("notice.title.fallback", source.id) : cleaned,
            body: Notice.sanitizedBody(body), postedAt: clock())
        guard !appNotices.contains(where: { $0.key == notice.key }) else { return nil }
        appNotices.append(notice)
        return notice
    }

    /// An empty title is not an option: something has to be readable on the banner and in the
    /// pane tooltip, so a poster that hands in nothing but control characters gets the source's
    /// name. The lookup lives here rather than in `Notice` because `Notice.swift` is
    /// Foundation-only (the control plane's wire types are built from it) and `L` is app-side.
    private func sanitizedTitle(_ request: NoticeRequest) -> String {
        let cleaned = Notice.sanitizedTitle(request.title)
        return cleaned.isEmpty ? L("notice.title.fallback", request.source.id) : cleaned
    }

    // MARK: Resolving

    enum ResolveOutcome: Equatable {
        case resolved
        /// It exists, but it is already in the history.
        case notLive
        case notFound
        /// `.stateChanged` from somewhere other than the lineage that posted it.
        case originMismatch
    }

    @discardableResult
    func resolve(_ id: UUID, _ how: NoticeResolution, origin: NoticeOrigin? = nil) -> ResolveOutcome {
        guard let index = live.firstIndex(where: { $0.id == id }) else {
            return history.contains { $0.id == id } ? .notLive : .notFound
        }
        // The whole point of `NoticeOrigin`: a forger may add a notice, it may never remove one.
        // A notice with no stored origin is resolvable by anyone — Phase 1 posts none, so this
        // clause is dormant until the agent hooks arrive.
        if how == .stateChanged, let stored = live[index].origin, !stored.permits(origin) {
            return .originMismatch
        }
        resolveAtIndex(index, how)
        return .resolved
    }

    /// Every live notice of the pane, optionally only one urgency. Returns how many really
    /// resolved — the number `notices ack` reports as its change, and what tells rule 1 whether
    /// it silenced anything.
    @discardableResult
    func resolveAll(pane: UUID, _ how: NoticeResolution,
                    urgency: NoticeUrgency? = nil, origin: NoticeOrigin? = nil) -> Int {
        var resolved = 0
        // Walk by identity rather than by index: `resolveAtIndex` mutates `live`, and each
        // resolution dispatches into sinks that may read (never write) the centre.
        let targets = live.filter { notice in
            guard notice.pane == pane else { return false }
            guard urgency == nil || notice.urgency == urgency else { return false }
            if how == .stateChanged, let stored = notice.origin, !stored.permits(origin) {
                return false
            }
            return true
        }.map(\.id)
        for id in targets {
            guard let index = live.firstIndex(where: { $0.id == id }) else { continue }
            resolveAtIndex(index, how)
            resolved += 1
        }
        return resolved
    }

    /// One resolution, all of it: mutate, then tell the sinks, then the counts if they moved.
    private func resolveAtIndex(_ index: Int, _ how: NoticeResolution) {
        var notice = live[index]
        let pane = notice.pane
        let before = urgency(pane: pane)
        notice.resolvedAt = clock()
        notice.resolution = how
        live.remove(at: index)
        appendToHistory(notice)

        let after = urgency(pane: pane)
        let transition = PaneTransition(pane: pane, before: before, after: after)
        let activity = locator.activity(pane)
        noteActivity(pane, activity)
        let countsMoved = recomputeCounts()

        dispatch(.resolved(notice, transition, activity))
        if countsMoved { dispatch(.countsChanged(counts)) }
    }

    // MARK: The resolution rules (spec §3.5)

    /// What rule 1 did: how many alarms really resolved, and which live ones **refused** the
    /// caller's origin.
    ///
    /// The two have to be told apart, or `agent-event` cannot distinguish "nothing was live" from
    /// "a cross-pane attempt was refused" — and the second is the case the whole lineage rule
    /// exists to catch, so it has to be reportable (plan §1.4).
    struct StateChangeOutcome: Equatable {
        var resolved: Int
        var refused: [UUID]

        init(resolved: Int = 0, refused: [UUID] = []) {
            self.resolved = resolved
            self.refused = refused
        }
    }

    /// What `agentStateLeftNeedsUser` **would** answer, changing nothing.
    ///
    /// `AgentRegistry` asks this *before* it stores a status, because a refusal has to be total:
    /// a report that may not take this pane's alarm down may not take the pane's agent status
    /// with it either (the reason is spelled out at that call site). The two filters are the same
    /// two the real thing uses, so the forecast cannot drift from it.
    func stateChangeForecast(pane: UUID, origin: NoticeOrigin?) -> StateChangeOutcome {
        var out = StateChangeOutcome()
        for notice in live where notice.pane == pane && notice.urgency == .needsUser {
            if let stored = notice.origin, !stored.permits(origin) {
                out.refused.append(notice.id)
            } else {
                out.resolved += 1
            }
        }
        return out
    }

    /// Rule 1 — the pane's agent state left `blocked`/`error`, and the poster's own lineage said
    /// so. Phase 2's `agent-event` is the only caller.
    @discardableResult
    func agentStateLeftNeedsUser(pane: UUID, origin: NoticeOrigin?) -> StateChangeOutcome {
        let refused = stateChangeForecast(pane: pane, origin: origin).refused
        let resolved = resolveAll(pane: pane, .stateChanged, urgency: .needsUser, origin: origin)
        return StateChangeOutcome(resolved: resolved, refused: refused)
    }

    /// Rule 2 — the user focused the pane and typed into it.
    ///
    /// What that means is the owner's Q1 answer, held in `userActedPolicy` (plan §2.8):
    /// - `.resolveFully` (Phase 1's behaviour): every urgency of that pane resolves;
    /// - `.clearInterruptingSinks` (**the default**): an alarm with *hook or report* evidence is
    ///   **quieted** — banner and Dock badge let go, the pane mark, the pill count and the strip
    ///   stay until the agent or its process confirms. Everything else resolves, because no later
    ///   signal will ever come for it: a notification-evidenced alarm has no hook behind it.
    /// - `.resolveFullyAndRearm`: as `.resolveFully` here; the registry arms the re-arm timer.
    func userDidType(in pane: UUID) {
        switch userActedPolicy {
        case .resolveFully, .resolveFullyAndRearm:
            resolveAll(pane: pane, .userActed)
        case .clearInterruptingSinks:
            quietOrResolve(pane: pane)
        }
    }

    /// Q1(b): quiet what a hook will speak for again, resolve the rest.
    private func quietOrResolve(pane: UUID) {
        let now = clock()
        var quieted = false
        for id in live(pane: pane).map(\.id) {
            guard let index = live.firstIndex(where: { $0.id == id }) else { continue }
            let notice = live[index]
            guard notice.urgency == .needsUser,
                  notice.evidence == .hook || notice.evidence == .report else {
                resolveAtIndex(index, .userActed)
                continue
            }
            guard notice.quietedAt == nil else { continue }
            live[index].quietedAt = now
            quieted = true
            dispatch(.quieted(live[index], locator.activity(pane)))
        }
        guard quieted, recomputeCounts() else { return }
        dispatch(.countsChanged(counts))
    }

    /// The **only** road to rule 2, and it is deliberately narrow: a real `NSEvent` delivered to
    /// the focused pane of the key window of the active app.
    ///
    /// Text arriving through `input send-text` (`Ghostty.Surface.sendText`) must never count —
    /// otherwise a same-uid process could silence another pane's alarm by typing a space into it,
    /// which is exactly the hole the lineage rule closes on the other side. `NoticeCenterTests`
    /// pins both halves.
    ///
    /// `nonisolated static`, wrapped in `assumeIsolated`, because `Ghostty.SurfaceView` carries
    /// no actor annotation — the same shape as `ControlEventBus.noteChange()`.
    nonisolated static func noteKeyDown(in pane: PaneView) {
        MainActor.assumeIsolated {
            guard pane.window?.isKeyWindow == true, NSApp.isActive, pane.focused else { return }
            shared.userDidType(in: pane.id)
        }
    }

    /// "Something that could change who is looking at a pane happened." Coalesced exactly like
    /// `ControlEventBus.scheduleScan()`: any number of calls in one run-loop turn produce one
    /// pass. The five call sites are listed in the contract §10.4 and nowhere else adds one.
    nonisolated static func noteActivityChange() {
        MainActor.assumeIsolated { shared.scheduleActivityPass() }
    }

    func scheduleActivityPass() {
        guard !activityPassScheduled else { return }
        activityPassScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self, self.activityPassScheduled else { return }
            self.activityPassScheduled = false
            self.runActivityPass()
        }
    }

    /// Run the pass now (the tests, and anywhere that needs the answer before the next turn).
    func flushActivityPass() {
        activityPassScheduled = false
        runActivityPass()
    }

    /// Rule 4 (`paneClosed`), "info resolves on focus" (`paneFocused`), and `.activityChanged`
    /// for everything else — one walk over the panes that actually hold something live.
    private func runActivityPass() {
        for pane in panesWithLiveNotices() {
            guard let activity = locator.activity(pane) else {
                // The pane is gone. Rule 4: everything it held resolves.
                resolveAll(pane: pane, .paneClosed)
                recordedActivity[pane] = nil
                continue
            }
            if activity.isActive {
                // `info` only. An approval prompt is not answered by looking at it.
                resolveAll(pane: pane, .paneFocused, urgency: .info)
            }
            guard !live(pane: pane).isEmpty else {
                recordedActivity[pane] = nil
                continue
            }
            guard recordedActivity[pane] != activity else { continue }
            recordedActivity[pane] = activity
            dispatch(.activityChanged(pane: pane, activity))
        }
        // A pane that **moved** changes no notice and resolves nothing, so nothing above would
        // have recomputed the counts — and the pill on the workspace it left would keep the
        // number. The pass already runs on every layout change, so this is where a move lands.
        if recomputeCounts() { dispatch(.countsChanged(counts)) }
    }

    /// Panes holding at least one live notice, in post order, deduplicated. A snapshot: the walk
    /// resolves notices as it goes.
    private func panesWithLiveNotices() -> [UUID] {
        var seen = Set<UUID>()
        var out: [UUID] = []
        for notice in live where seen.insert(notice.pane).inserted { out.append(notice.pane) }
        return out
    }

    // MARK: Reading

    /// **Where a notice is now.** The pane's current location while the pane still exists, the
    /// pair recorded at post time when it does not (a history entry outliving its pane).
    ///
    /// Everything that asks "which workspace is this alarm on" comes through here — the counts,
    /// `notices list -t 1:2`, the wire records and the event stream — so the pill, the Dock total
    /// and what an agent reads can never give three different answers. `pane move -t t7 --to 1:3`
    /// by the very agent arranging the work is routine, and Phase 2 makes approval notices live
    /// for minutes (plan §1.1).
    func location(of notice: Notice) -> NoticeLocation {
        guard let located = locator.locate(notice.pane) else { return notice.location }
        return NoticeLocation(screen: located.controller.windowID, workspace: located.workspace)
    }

    func live(pane: UUID) -> [Notice] {
        live.filter { $0.pane == pane }
    }

    func notice(id: UUID) -> Notice? {
        live.first { $0.id == id } ?? history.first { $0.id == id }
    }

    /// The pane's **displayed** urgency: the maximum over its live notices, nil when it has none.
    func urgency(pane: UUID) -> NoticeUrgency? {
        live.reduce(into: nil as NoticeUrgency?) { result, notice in
            guard notice.pane == pane else { return }
            if result == nil || notice.urgency > result! { result = notice.urgency }
        }
    }

    /// Panes needing the user, optionally narrowed to one screen or one workspace of it.
    func needsUserCount(screen: UUID? = nil, workspace: Int? = nil) -> Int {
        counts.needsUser.values.reduce(0) { total, location in
            if let screen, location.screen != screen { return total }
            if let workspace, location.workspace != workspace { return total }
            return total + 1
        }
    }

    // MARK: Sinks

    func addSink(_ sink: NoticeSink) {
        guard !sinks.contains(where: { $0.sinkID == sink.sinkID }) else { return }
        sink.isEnabled = settings.isEnabled(sinkID: sink.sinkID)
        sinks.append(sink)
    }

    func removeSink(id: String) {
        sinks.removeAll { $0.sinkID == id }
    }

    func sink(id: String) -> NoticeSink? {
        sinks.first { $0.sinkID == id }
    }

    /// The system-notification sink, kept by name as well as in `sinks` because it is the one
    /// sink with a second job: it is also the process's `UNUserNotificationCenterDelegate`, and
    /// whoever installs that delegate has to be able to find the same object again (contract
    /// §10.3/§10.10). Strong, like every other sink reference here — the delegate property on
    /// `UNUserNotificationCenter` is weak, so this is what keeps a banner click routable.
    var systemSink: SystemNotificationSink?

    private func dispatch(_ change: NoticeChange) {
        for sink in sinks where sink.isEnabled { sink.apply(change) }
    }

    /// One config reload -> each sink's switch. A sink that was just switched **off** is told to
    /// clear itself exactly once, after its flag is down, so that a Dock badge or a banner does
    /// not survive the setting that turned it off; switching one back on replays nothing, because
    /// every sink that draws rebuilds itself from `counts` on the next change anyway.
    private func applySettings() {
        for sink in sinks {
            let enabled = settings.isEnabled(sinkID: sink.sinkID)
            guard enabled != sink.isEnabled else { continue }
            sink.isEnabled = enabled
            if !enabled { sink.clearAll() }
        }
    }

    // MARK: Bookkeeping

    private func appendToHistory(_ notice: Notice) {
        history.append(notice)
        if history.count > Self.historyCapacity {
            history.removeFirst(history.count - Self.historyCapacity)
        }
    }

    /// Recompute `counts` and say whether they moved.
    ///
    /// The location comes from `location(of:)` — **where the pane is now** — so a pane dragged to
    /// another workspace while an approval is pending takes its count with it. The activity pass
    /// already runs on every `$layouts` / `$floatings` change, so the move is picked up in the
    /// same turn (plan §1.1).
    ///
    /// `interrupting` counts the panes whose alarm has not been quieted; `needsUser` counts every
    /// pane with a live alarm, quieted or not. Two numbers because two sets of sinks: the banner
    /// and the Dock badge let go when the user starts dealing with it, while the pane mark and the
    /// pill stay until the agent confirms (owner decision Q1(b) / Q6).
    @discardableResult
    private func recomputeCounts() -> Bool {
        var map: [UUID: NoticeLocation] = [:]
        var interrupting = Set<UUID>()
        for notice in live where notice.urgency == .needsUser {
            map[notice.pane] = location(of: notice)
            if notice.quietedAt == nil { interrupting.insert(notice.pane) }
        }
        let fresh = NoticeCounts(needsUser: map, interrupting: interrupting.count)
        guard fresh != counts else { return false }
        counts = fresh
        return true
    }

    private func noteActivity(_ pane: UUID, _ activity: PaneActivity?) {
        guard let activity, !live(pane: pane).isEmpty else {
            recordedActivity[pane] = nil
            return
        }
        recordedActivity[pane] = activity
    }

    /// Tests only: forget every notice. **The sinks stay registered** — a test that installed a
    /// recorder keeps it across a reset, which is what makes "a disabled sink received nothing"
    /// assertable at all.
    func resetForTesting() {
        live.removeAll()
        history.removeAll()
        appNotices.removeAll()
        counts = NoticeCounts()
        recordedActivity.removeAll()
        activityPassScheduled = false
    }
}
