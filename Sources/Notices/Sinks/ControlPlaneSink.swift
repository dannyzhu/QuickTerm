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

    /// The bus is injectable so a test can watch one in isolation; the app wires this sink up with
    /// no arguments at all (contract §10.10, `ControlPlaneSink()`).
    ///
    /// The default is written as `nil` rather than `.shared` on purpose: a default argument
    /// expression is evaluated in a **nonisolated** context however isolated the initialiser is,
    /// and `ControlEventBus.shared` is main-actor isolated. (`NoticeLocator.unattached` carries the
    /// same note for the same reason.)
    init(bus: ControlEventBus? = nil) {
        self.bus = bus ?? ControlEventBus.shared
    }

    func apply(_ change: NoticeChange) {
        switch change {
        case .posted(let notice, _, _):
            emit(notice, type: .noticePosted)
        case .superseded(let old, let new, _, _):
            // Two events, in this order: the old one really did stop being live, and a subscriber
            // that only heard the new post would keep an id alive for ever. The old one carries
            // `resolution: "superseded"`, which is how an agent tells "a different tool is asking
            // now" from "the user dealt with it".
            emit(old, type: .noticeResolved)
            emit(new, type: .noticePosted)
        case .resolved(let notice, _, _):
            emit(notice, type: .noticeResolved)
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
