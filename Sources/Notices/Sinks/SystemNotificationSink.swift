import AppKit
import UserNotifications

/// The slice of `UNUserNotificationCenter` this sink uses, so a test can hand it a recorder
/// (contract §10.7).
///
/// Without it every case below would post a real banner on the machine running the tests, and
/// "did it withdraw the old one" would be a question you answer by looking at the screen.
protocol UserNotificationCentering: AnyObject {
    var delegate: UNUserNotificationCenterDelegate? { get set }
    func requestAuthorization(options: UNAuthorizationOptions,
                              completionHandler: @escaping @Sendable (Bool, (any Error)?) -> Void)
    func getNotificationSettings(completionHandler: @escaping @Sendable (UNNotificationSettings) -> Void)
    func add(_ request: UNNotificationRequest,
             withCompletionHandler: (@Sendable ((any Error)?) -> Void)?)
    func removeDeliveredNotifications(withIdentifiers identifiers: [String])
    func removePendingNotificationRequests(withIdentifiers identifiers: [String])
}

extension UNUserNotificationCenter: UserNotificationCentering {}

/// **The one owner of macOS banners** (design §3.5 "System notification", contract §10.7).
///
/// Until this existed the engine posted its own banners straight to `UNUserNotificationCenter`
/// and kept a set of identifiers on each surface view. That path is deleted (see
/// `GhosttyNoticeProducer`): two owners means one prompt announced twice, and neither half knows
/// that the other already withdrew its banner.
///
/// The three rules that shape everything here:
/// 1. **One banner per pane.** The request identifier is the pane's uuid, so a second notice for
///    the same pane *replaces* the banner instead of stacking a second one under it.
/// 2. **Only when the user is not already looking.** `PaneActivity.isActive` is the whole test:
///    app frontmost, window key, workspace visible, pane focused. All four, because a pane on the
///    other screen of a two-screen setup is not being looked at however frontmost the app is.
/// 3. **A click is navigation, not acknowledgement.** `didReceive` reveals the pane and withdraws
///    the banner; the notice stays live, so with two panes blocked, clicking A and being pulled
///    away leaves A marked.
@MainActor
final class SystemNotificationSink: NSObject, NoticeSink, UNUserNotificationCenterDelegate {
    let sinkID = NoticeSinkID.system
    var isEnabled = true

    /// Registered with **no actions**: the owner's decision (spec §7.6) is that nobody approves a
    /// tool from a banner - the human opens the app and acts in the pane.
    static let category = "dev.danny.quickterm.notice"

    /// One identifier per pane, which is what makes rule 1 true.
    static func identifier(pane: UUID) -> String { "notice-pane-\(pane.uuidString)" }

    private let center: UserNotificationCentering
    private let locator: NoticeLocating
    private let route: (UUID) -> Void
    private let settings: () -> NoticeSettings

    /// Panes whose banner may still be on screen. Only used to take them all down in `clearAll`;
    /// every other withdrawal knows its own pane.
    private var presented: Set<UUID> = []

    /// Authorization is asked for once, lazily, at the first banner - exactly as the engine did.
    /// Not at launch: an app that asks the moment it starts gets denied by people who have no idea
    /// yet what it wants to tell them.
    private var authorizationRequested = false

    init(center: UserNotificationCentering,
         locator: NoticeLocating,
         route: @escaping (UUID) -> Void,
         settings: (() -> NoticeSettings)? = nil) {
        self.center = center
        self.locator = locator
        self.route = route
        // `nil` rather than a default closure, for the reason `ControlPlaneSink` spells out: a
        // default argument expression is nonisolated, and `NoticeCenter.shared` is not.
        self.settings = settings ?? { NoticeCenter.shared.settings }
    }

    /// Become the process's `UNUserNotificationCenterDelegate`, which is what makes a click on a
    /// banner route to its pane. Called once by the launch wiring (contract §10.10); a separate
    /// method rather than a line in `init` because becoming a process-wide delegate is a side
    /// effect, and a sink a test builds to ask "what would this have posted" must not have one.
    func installAsDelegate() {
        center.delegate = self
    }

    // MARK: NoticeSink

    func apply(_ change: NoticeChange) {
        switch change {
        case .posted(let notice, let transition, let activity):
            guard transition.raised else { return }
            present(notice, activity: activity, sound: true)

        case .superseded(_, let new, let transition, let activity):
            // A different tool is asking now. The banner is replaced either way; it only gets a
            // sound when the pane's urgency actually went up, so an `info` quietly overwriting an
            // `info` does not ping twice for one program's chatter.
            guard transition.raised || new.urgency == .needsUser else { return }
            present(new, activity: activity, sound: transition.raised)

        case .resolved(let notice, let transition, _):
            // Only when the pane has nothing left to say. With two notices live, resolving one
            // must not take down the banner that describes the other.
            guard transition.after == nil else { return }
            withdraw(pane: notice.pane)

        case .activityChanged(let pane, let activity):
            // The user is looking at the pane now: whatever is on the lock screen about it is
            // stale. (The notice itself stays live unless it was an `info`, which the centre
            // resolves in the same pass.)
            if activity.isActive { withdraw(pane: pane) }

        case .countsChanged:
            break
        }
    }

    func clearAll() {
        for pane in presented { withdraw(pane: pane) }
        presented.removeAll()
    }

    // MARK: Presenting

    /// `settings.system` is read here rather than trusted from `isEnabled`, because the two say
    /// different things: `never` switches the sink off (and `clearAll`s it), while `inactive` -
    /// the only other value - still has to ask whether the user is looking right now.
    private func present(_ notice: Notice, activity: PaneActivity?, sound: Bool) {
        guard settings().system == "inactive" else { return }
        // An unknown activity means the pane is gone: nothing to tell the user to go and look at.
        guard let activity, !activity.isActive else { return }

        requestAuthorizationIfNeeded()

        let content = UNMutableNotificationContent()
        content.title = notice.title
        if let subtitle = subtitle(for: notice.pane) { content.subtitle = subtitle }
        if let body = bodyToShow(notice) { content.body = body }
        content.categoryIdentifier = Self.category
        content.userInfo = ["pane": notice.pane.uuidString, "notice": notice.id.uuidString]
        if sound { content.sound = .default }

        presented.insert(notice.pane)
        center.add(UNNotificationRequest(identifier: Self.identifier(pane: notice.pane),
                                         content: content, trigger: nil)) { error in
            guard let error else { return }
            // `privacy: .public`: every one of these strings comes from the OS, carries nothing
            // of the user's, and is useless in a bug report when it reads `<private>`.
            AppDelegate.logger.error("notice banner refused: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Which pane this is about, in the words the user addresses it with. The handle (`t7`) is
    /// what they would type at `quickterm notices ack -t t7`; the name is the one they gave the
    /// pane themselves.
    ///
    /// Deliberately **not** the terminal's own OSC title: Notification Center keeps a subtitle in
    /// its database, shows it on the lock screen and outlives the app, and a program's title is a
    /// program's text like any other (the same reason `system-body` defaults to `composed`).
    private func subtitle(for pane: UUID) -> String? {
        guard let handle = locator.handle(pane) else { return nil }
        guard let name = locator.locate(pane)?.pane.customTitle,
              let clamped = TitleRules.clamp(name, to: PaneTitleBadge.maxCharacters)
        else { return L("notice.system.subtitle", handle) }
        return L("notice.system.subtitle-named", handle, clamped)
    }

    /// `never` | `composed` (the default: only text QuickTerm wrote itself) | `always`.
    private func bodyToShow(_ notice: Notice) -> String? {
        guard let body = notice.body else { return nil }
        switch settings().systemBody {
        case "always": return body
        case "composed": return notice.bodySensitive ? nil : body
        default: return nil
        }
    }

    private func requestAuthorizationIfNeeded() {
        guard !authorizationRequested else { return }
        authorizationRequested = true
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                AppDelegate.logger.error(
                    "notification authorization failed: \(error.localizedDescription, privacy: .public)")
            } else {
                AppDelegate.logger.info("notification authorization granted=\(granted, privacy: .public)")
            }
        }
    }

    /// Delivered **and** pending: a banner that has not been shown yet is just as stale as one on
    /// the screen.
    private func withdraw(pane: UUID) {
        guard presented.contains(pane) else { return }
        presented.remove(pane)
        let id = Self.identifier(pane: pane)
        center.removeDeliveredNotifications(withIdentifiers: [id])
        center.removePendingNotificationRequests(withIdentifiers: [id])
    }

    // MARK: UNUserNotificationCenterDelegate
    //
    // Both callbacks are `nonisolated`: `UNUserNotificationCenterDelegate` carries no actor
    // annotation, and the system does not promise which thread it calls on. They hop to the main
    // actor and answer from there, which is also the only place the locator may be asked anything.

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let pane = Self.pane(in: notification.request.content.userInfo)
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                // Asked again at the moment of presentation, not trusted from `present`: macOS
                // shows a banner in the foreground only if the app says so, and between the `add`
                // and this call the user may have walked over to exactly that pane.
                guard let pane, let activity = self.locator.activity(pane), !activity.isActive else {
                    completionHandler([])
                    return
                }
                completionHandler([.banner, .sound])
            }
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let pane = Self.pane(in: response.notification.request.content.userInfo)
        let isDefaultAction = response.actionIdentifier == UNNotificationDefaultActionIdentifier
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                defer { completionHandler() }
                // The dismiss action does nothing on purpose: swiping a banner away is not the
                // user saying they dealt with the pane.
                guard isDefaultAction, let pane else { return }
                self.route(pane)
                self.withdraw(pane: pane)
            }
        }
    }

    /// `nonisolated`: both delegate callbacks read it before they hop to the main actor, so that
    /// the hop carries a plain `UUID?` rather than a dictionary of `Any`.
    private nonisolated static func pane(in userInfo: [AnyHashable: Any]) -> UUID? {
        (userInfo["pane"] as? String).flatMap(UUID.init(uuidString:))
    }
}

/// The notification centre the **test host** gets (contract §10.10).
///
/// Everything the sink does is a method on `UserNotificationCentering`, so handing it one that
/// does nothing is all it takes to keep a test run from posting real banners on the machine, from
/// asking the person sitting there for notification permission, and from leaving anything in
/// Notification Center's database afterwards. The tests that assert *what* would have been posted
/// use their own recorder; this one exists for the app object that the host launches anyway.
final class InertNotificationCenter: UserNotificationCentering {
    var delegate: UNUserNotificationCenterDelegate?
    func requestAuthorization(options: UNAuthorizationOptions,
                              completionHandler: @escaping @Sendable (Bool, (any Error)?) -> Void) {
        completionHandler(false, nil)
    }
    func getNotificationSettings(completionHandler: @escaping @Sendable (UNNotificationSettings) -> Void) {}
    func add(_ request: UNNotificationRequest,
             withCompletionHandler: (@Sendable ((any Error)?) -> Void)?) {
        withCompletionHandler?(nil)
    }
    func removeDeliveredNotifications(withIdentifiers identifiers: [String]) {}
    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {}
}
