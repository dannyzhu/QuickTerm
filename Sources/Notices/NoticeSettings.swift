import Foundation

/// The `[notifications]` group as the notification centre reads it (spec §4, contract §10.8).
///
/// A plain value type, `Equatable`, built from `ConfigStore.Settings` in
/// `AppSession.applyGlobalConfig`. Two of the seven keys are not read here at all — `bell` and
/// `command-finished` are questions for the **producers** ("should this signal become a notice
/// at all"), not for the centre, which has no opinion about where a notice came from. They live
/// in this type anyway so that there is one object to hand a producer, and so the settings
/// window has one struct to bind to.
struct NoticeSettings: Equatable {
    /// `inactive` (banner only when the pane is not active) | `never`.
    var system = "inactive"
    /// `never` | `composed` | `always`. The default keeps a program's own words out of
    /// Notification Center, which persists them in its database, on the lock screen and after
    /// QuickTerm is gone.
    var systemBody = "composed"
    var dockBadge = true
    var paneMark = true
    var workspaceCount = true
    /// `ignore` | `info`. A bare bell is not a notice by default (owner's decision, spec §7.4).
    var bell = "ignore"
    /// `never` | `long` | `always`.
    var commandFinished = "long"

    /// What `command-finished = "long"` means, in seconds.
    static let longCommand: TimeInterval = 10

    init() {}

    init(_ settings: ConfigStore.Settings) {
        system = settings.notificationsSystem
        systemBody = settings.notificationsSystemBody
        dockBadge = settings.notificationsDockBadge
        paneMark = settings.notificationsPaneMark
        workspaceCount = settings.notificationsWorkspaceCount
        bell = settings.notificationsBell
        commandFinished = settings.notificationsCommandFinished
    }

    /// Whether a command that ran for `duration` should post an info notice.
    ///
    /// `Duration` is what the engine's `commandFinished` hands over. Converting it here rather
    /// than at the call site keeps the "over ten seconds" rule in one place, and the attosecond
    /// half is included so a 9.99 s command is not rounded up into an alert.
    func allowsCommandFinished(_ duration: Duration) -> Bool {
        switch commandFinished {
        case "never": return false
        case "always": return true
        default:
            let parts = duration.components
            let seconds = Double(parts.seconds) + Double(parts.attoseconds) / 1e18
            return seconds >= Self.longCommand
        }
    }

    var allowsBell: Bool { bell == "info" }

    /// Whether a sink with this id may run. `NoticeCenter` applies it to every registered sink
    /// whenever `settings` is written, so a sink never has to read the config itself — and a
    /// sink whose id is not listed here (the control plane, the activity log) is always on,
    /// because those two are the record of what happened rather than a way of interrupting
    /// somebody.
    func isEnabled(sinkID: String) -> Bool {
        switch sinkID {
        case NoticeSinkID.system: system != "never"
        case NoticeSinkID.dockBadge: dockBadge
        case NoticeSinkID.paneMark: paneMark
        case NoticeSinkID.workspaceCount: workspaceCount
        default: true
        }
    }
}

/// The sink identifiers, spelled once.
///
/// They are plain strings in `NoticeSink.sinkID` because they are also what
/// `NoticeCenter.sink(id:)` and `removeSink(id:)` take on the wire-ish side; these constants
/// exist so the switch above and the sinks themselves cannot disagree about a hyphen.
enum NoticeSinkID {
    static let system = "system"
    static let dockBadge = "dock-badge"
    static let paneMark = "pane-mark"
    static let workspaceCount = "workspace-count"
    static let controlPlane = "control-plane"
    static let activityLog = "activity-log"
}
