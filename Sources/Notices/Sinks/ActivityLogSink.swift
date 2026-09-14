import AppKit

/// **The record that makes a silent alarm accountable.** Every `needs-user` notice that is posted,
/// and every resolution of one, lands in the control plane's activity log — the same panel and the
/// same OSLog mirror the `mutate` commands write to.
///
/// Why only `needs-user`: the log is a ring of 200 entries whose job is to answer "who changed
/// something behind my back". `info` notices are chatty by nature (every long command, every OSC
/// notification from any program) and would push the real mutations out of the ring within a
/// minute. The event bus carries those instead — it holds 512 entries and nobody reads it looking
/// for an audit trail.
///
/// The body is written as a **sensitive** change, so `ControlActivityLog.Entry.logLine` keeps only
/// its path: the in-app panel shows the text to the person sitting here, and /var/db/diagnostics —
/// readable by any admin, swept up by sysdiagnose, outliving the app — never does.
@MainActor
final class ActivityLogSink: NoticeSink {
    let sinkID = NoticeSinkID.activityLog
    var isEnabled = true

    private let log: ControlActivityLog

    static let postCommand = "notice.post"
    static let resolveCommand = "notice.resolve"

    /// The default is `nil` rather than `.shared` because a default argument expression is
    /// evaluated in a **nonisolated** context however isolated the initialiser is, and
    /// `ControlActivityLog.shared` is main-actor isolated.
    init(log: ControlActivityLog? = nil) {
        self.log = log ?? ControlActivityLog.shared
    }

    func apply(_ change: NoticeChange) {
        switch change {
        case .posted(let notice, _, _):
            record(notice, command: Self.postCommand, outcome: ControlActivityLog.Entry.Outcome.applied)
        case .superseded(let old, let new, _, _):
            // A supersession is a resolution followed by a post, and both halves matter: what the
            // pane was asking for a moment ago is part of the trail.
            record(old, command: Self.resolveCommand,
                   outcome: old.resolution?.rawValue ?? ControlActivityLog.Entry.Outcome.applied)
            record(new, command: Self.postCommand, outcome: ControlActivityLog.Entry.Outcome.applied)
        case .resolved(let notice, _, _):
            record(notice, command: Self.resolveCommand,
                   outcome: notice.resolution?.rawValue ?? ControlActivityLog.Entry.Outcome.applied)
        case .quieted, .activityChanged, .countsChanged:
            // A quieting is not a resolution — the alarm is still live and still in the record.
            // What the user did about it will be logged when it really resolves.
            break
        }
    }

    func clearAll() {
        // The log is a record of what happened; switching a sink off does not unhappen it.
    }

    private func record(_ notice: Notice, command: String, outcome: String) {
        guard notice.urgency == .needsUser else { return }
        // Allocating the handle when the pane has never been encoded, for the same reason the
        // event does: an entry naming no pane is an entry nobody can follow up
        // (`ControlStateEncoder.handle(forPane:in:)`).
        let screens: ScreenRegistry? = (NSApp.delegate as? AppDelegate)?.screens
        var changes = [ControlChange("notice.title", from: nil, to: notice.title)]
        if let body = notice.body {
            changes.append(ControlChange("notice.body", from: nil, to: body, sensitive: true))
        }
        log.record(.init(
            at: notice.resolvedAt ?? notice.postedAt,
            command: command,
            // The peer is QuickTerm itself: in Phase 1 nothing outside the app posts a notice, and
            // when `agent-event` arrives in Phase 2 it will be a command of its own with its own
            // peer line. Writing a pid here that belongs to us would read as an external caller.
            peer: "QuickTerm",
            originPane: nil,
            target: screens.flatMap { ControlStateEncoder.handle(forPane: notice.pane, in: $0) },
            outcome: outcome,
            changes: changes))
    }
}
