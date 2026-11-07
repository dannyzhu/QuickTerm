import AppKit

/// **The control plane's ear on the notification centre**: every change becomes one typed event on
/// the event bus, so an agent watching `quickterm events poll` learns that a pane started waiting
/// for the human without polling `state` in a loop.
///
/// It is the only producer of `notice.posted` / `notice.resolved`, which is what lets
/// `ControlEventBus.emit` skip the snapshot diff (see the comment there): the centre has already
/// coalesced duplicates (an identical repost reaches no sink at all) and supersessions, so one call
/// here is exactly one thing that happened.
///
/// Not switchable by config, and deliberately so: `[notifications]` decides how loudly the user is
/// interrupted, while this sink and the activity log are the **record** of what happened. Turning
/// the Dock badge off must not blind the agent that is trying to stay out of the user's way — and
/// `NoticeSettings.isEnabled(sinkID:)` says the same thing by answering `true` for this id.
@MainActor
final class ControlPlaneSink: NoticeSink {
    let sinkID = NoticeSinkID.controlPlane
    var isEnabled = true

    private let bus: ControlEventBus

    typealias Schedule = (_ delay: TimeInterval, _ run: @escaping @MainActor () -> Void) -> Void

    private let clock: () -> Date
    private let schedule: Schedule

    /// **Coalescing silent re-raises** (spec decision 18). A program toggling `blocked` and
    /// `working` posts and resolves a silent alarm at its report rate, and every pair would push
    /// two events into a ring of `ControlEventLimits.ringCapacity`. Per notice key, at most one
    /// silent notice's events go out per `NoticeCenter.programAlarmFloodWindow`:
    /// - `silentWindow[key]`: when the last program-status alarm under the key was emitted;
    /// - `held[key]`: the newest silent notice skipped inside that window and still live. When
    ///   the window ends it is emitted, so a burst that ends blocked still says so on the stream;
    /// - `skipped`: notices whose `notice.posted` never went out, so their `notice.resolved`
    ///   does not either (a subscriber is never told an id it has never heard of went away).
    private var silentWindow: [String: Date] = [:]
    private var held: [String: Notice] = [:]
    private var skipped: Set<UUID> = []
    /// Keys with a window-end callback pending: one per key, however many notices it skips.
    private var armed: Set<String> = []

    /// The bus is injectable so a test can watch one in isolation; the app wires this sink up with
    /// no arguments at all (contract §10.10, `ControlPlaneSink()`). The clock and the scheduler are
    /// injectable so a test can drive the coalescing window by hand.
    ///
    /// The default is written as `nil` rather than `.shared` on purpose: a default argument
    /// expression is evaluated in a **nonisolated** context however isolated the initialiser is,
    /// and `ControlEventBus.shared` is main-actor isolated. (`NoticeLocator.unattached` carries the
    /// same note for the same reason.)
    init(bus: ControlEventBus? = nil, clock: @escaping () -> Date = Date.init,
         schedule: Schedule? = nil) {
        self.bus = bus ?? ControlEventBus.shared
        self.clock = clock
        self.schedule = schedule ?? { delay, run in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated(run) }
        }
    }

    func apply(_ change: NoticeChange) {
        switch change {
        case .posted(let notice, _, _):
            posted(notice)
        case .superseded(let old, let new, _, _):
            // Two events, in this order: the old one really did stop being live, and a subscriber
            // that only heard the new post would keep an id alive for ever. The old one carries
            // `resolution: "superseded"`, which is how an agent tells "a different tool is asking
            // now" from "the user dealt with it".
            resolved(old)
            posted(new)
        case .resolved(let notice, _, _):
            resolved(notice)
        case .quieted, .rearmed, .activityChanged, .countsChanged:
            // None of them is an event: activity is "is the user looking at this pane", which the
            // focus / workspace events already describe, the counts are a function of the posts
            // and resolutions that were just emitted, and a quieting — or its re-arm when the user
            // walks away — changes nothing an agent can act on: the notice is still live and still
            // in `state`, only its `quietedAt` moved.
            break
        }
    }

    func clearAll() {
        // Nothing to take down: the events already went out, and the ring is the caller's history.
        // (A sink that is switched off gets this once; this one is never switched off.)
    }

    // MARK: Coalescing (spec decision 18)

    private func posted(_ notice: Notice) {
        guard NoticeCenter.isProgramAlarm(notice) else {
            emit(notice, type: .noticePosted)
            return
        }
        let now = clock()
        let window = NoticeCenter.programAlarmFloodWindow
        silentWindow = silentWindow.filter { now.timeIntervalSince($0.value) < window }
        // A banner-worthy alarm always goes out, and opens the window its silent re-raises
        // are coalesced in.
        guard notice.silent, let start = silentWindow[notice.key] else {
            silentWindow[notice.key] = now
            emit(notice, type: .noticePosted)
            return
        }
        skipped.insert(notice.id)
        held[notice.key] = notice
        guard armed.insert(notice.key).inserted else { return }
        let key = notice.key
        schedule(max(0, window - now.timeIntervalSince(start))) { [weak self] in
            self?.releaseHeld(key: key)
        }
    }

    private func resolved(_ notice: Notice) {
        guard skipped.remove(notice.id) == nil else {
            if held[notice.key]?.id == notice.id { held[notice.key] = nil }
            return
        }
        emit(notice, type: .noticeResolved)
    }

    /// The window is over: the newest skipped notice, if it is still live, goes out now and
    /// opens the next window. Its resolution is then emitted like any other.
    private func releaseHeld(key: String) {
        armed.remove(key)
        guard let notice = held.removeValue(forKey: key) else { return }
        skipped.remove(notice.id)
        silentWindow[key] = clock()
        emit(notice, type: .noticePosted)
    }

    private func emit(_ notice: Notice, type: ControlEventType) {
        // The screen index is looked up rather than stored on the notice: it is a position in a
        // list that moves when a window closes, while `screen` (the window's uuid) does not.
        // A notice whose window has since gone reports no index at all — better than a number
        // that now points at somebody else.
        let screens = (NSApp.delegate as? AppDelegate)?.screens
        // **Where the pane is now**, not where it was posted: an agent that moves a pane while
        // its own approval is pending would otherwise be told the alarm is on the workspace it
        // left (plan §1.1). A history entry whose pane is gone keeps the stored pair.
        let location = NoticeCenter.shared.location(of: notice)
        let screenIndex = screens?.controller(id: location.screen).map { $0.screenIndex + 1 }
        let event = ControlEvent(
            type: type,
            screen: screenIndex,
            screenID: location.screen.uuidString,
            workspace: location.workspace + 1,
            // Allocating here when the pane has never been encoded: an event that names no pane is
            // an event nobody can act on (see `ControlStateEncoder.handle(forPane:in:)`).
            pane: screens.flatMap { ControlStateEncoder.handle(forPane: notice.pane, in: $0) },
            paneID: notice.pane.uuidString,
            title: notice.title,
            noticeID: notice.id.uuidString,
            urgency: notice.urgency.rawValue,
            source: notice.source.id,
            body: notice.body,
            resolution: notice.resolution?.rawValue)
        // Redactable exactly when there is a body to withhold. The title is payload-free by
        // construction and stays readable for every caller (see `ControlEventBus.redact`).
        bus.emit(event, redactable: notice.body != nil, producer: .noticeCenter)
    }
}
