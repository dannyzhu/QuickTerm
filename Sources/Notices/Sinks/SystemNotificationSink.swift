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
    /// **A requirement, not only an extension**: the default below is what `UNUserNotificationCenter`
    /// uses, and a double that answers this instead is only reached through dynamic dispatch — which
    /// a method declared solely in a protocol extension does not get.
    func authorizationStatus(_ completion: @escaping @Sendable (SystemNotificationStatus) -> Void)
    func add(_ request: UNNotificationRequest,
             withCompletionHandler: (@Sendable ((any Error)?) -> Void)?)
    func removeDeliveredNotifications(withIdentifiers identifiers: [String])
    func removePendingNotificationRequests(withIdentifiers identifiers: [String])
}

extension UNUserNotificationCenter: UserNotificationCentering {}

extension UserNotificationCentering {
    /// **Where macOS stands, in QuickTerm's own vocabulary.**
    ///
    /// Asked rather than derived from `getNotificationSettings` at the call site for one blunt
    /// reason: `UNNotificationSettings` has **no public initialiser**, so no test double can ever
    /// answer that method — which is exactly why `RecordingNotificationCenter.getNotificationSettings`
    /// is an empty body and why a denial went unnoticed for a whole release. A protocol member
    /// carrying a plain enum can be answered by anybody, so the denied path is reachable in a test.
    ///
    /// This default is the real translation, so `UNUserNotificationCenter` needs no code of its own
    /// and a double that answers nothing simply never calls back (the sink then stays at
    /// `.unavailable`, which is the truth: we did not learn anything).
    ///
    /// `getNotificationSettings` **never prompts** — it is a read. That is what makes it safe to
    /// call at launch, where `requestAuthorization` would not be.
    func authorizationStatus(_ completion: @escaping @Sendable (SystemNotificationStatus) -> Void) {
        getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                // `provisional` and `ephemeral` do deliver — quietly, and straight to Notification
                // Center — so for the one question this answers ("will anything reach the user")
                // they are the same as authorized.
                completion(.authorized)
            case .denied:
                completion(.denied)
            case .notDetermined:
                completion(.notDetermined)
            @unknown default:
                completion(.unavailable)
            }
        }
    }
}

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
///    away leaves A marked. A quieting (plan §2.8) withdraws by the same road and for the same
///    reason: this sink takes banners down, and never resolves anything.
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

    /// Panes that have been **audibly** announced while their `needsUser` alarm is still live. It is
    /// what a re-arm consults to keep the "one sound per pane" rule (spec §3.5 rule 5): a pane can
    /// hold several `needsUser` notices from different sources — all coalesced to one banner — so the
    /// sound decision is per *pane*, not per notice id. Set when a `needsUser` banner actually plays
    /// a sound; **kept across a withdrawal** (a glance does not reset it) and cleared only when the
    /// pane stops needing the user (`.resolved` to nothing or to `info`), which is when the next
    /// alarm becomes a fresh one that may ping again. Bounded by the live-needsUser panes.
    private var pingedPanes: Set<UUID> = []

    /// Authorization is asked for once, lazily, at the first banner - exactly as the engine did.
    /// Not at launch: an app that asks the moment it starts gets denied by people who have no idea
    /// yet what it wants to tell them.
    private var authorizationRequested = false

    /// **Where macOS stands on our banners**, as last learned. Read by `notices list`
    /// (`systemNotifications`) and by nothing else.
    ///
    /// Starts at `.unavailable` and not at `.notDetermined`, because those are different facts and
    /// only one of them is true before `refreshAuthorizationStatus()` has answered: we have not
    /// been able to ask. Under the test host, where the centre is inert, it stays that way.
    private(set) var authorizationStatus: SystemNotificationStatus = .unavailable

    /// The "macOS will show nothing" hint is posted **once per launch** and never again — this is
    /// the latch that says so. A second lock sits under it in `NoticeCenter.postAppNotice`
    /// (deduplication by title), because two roads discover the same fact: the probe at launch and
    /// the first banner macOS refuses.
    private var deniedHintPosted = false

    /// What "tell the user macOS is not going to show this" does. Injected so a test can watch it
    /// happen without an activity log or a shared centre.
    private let announceDenied: () -> Void

    init(center: UserNotificationCentering,
         locator: NoticeLocating,
         route: @escaping (UUID) -> Void,
         settings: (() -> NoticeSettings)? = nil,
         announceDenied: (() -> Void)? = nil) {
        self.center = center
        self.locator = locator
        self.route = route
        // `nil` rather than a default closure, for the reason `ControlPlaneSink` spells out: a
        // default argument expression is nonisolated, and `NoticeCenter.shared` is not.
        self.settings = settings ?? { NoticeCenter.shared.settings }
        self.announceDenied = announceDenied ?? { Self.reportDenialToTheUser() }
    }

    /// Become the process's `UNUserNotificationCenterDelegate`, which is what makes a click on a
    /// banner route to its pane. Called once by the launch wiring (contract §10.10); a separate
    /// method rather than a line in `init` because becoming a process-wide delegate is a side
    /// effect, and a sink a test builds to ask "what would this have posted" must not have one.
    func installAsDelegate() {
        center.delegate = self
    }

    // MARK: Authorization
    //
    // **The gap this closes.** A stored denial outlives reinstalls and is invisible from inside the
    // app: `add` calls back with an error, usernoted writes "ineligible … authorizationStatus:
    // Denied" into the unified log, and the person who has been waiting three minutes for a banner
    // is told nothing at all. Until now the only trace was one `error` line nobody reads.
    //
    // Two roads lead here and both end at `noteAuthorization`, which is where the once-per-launch
    // rule lives: the probe below (a read, at launch) and the first banner macOS refuses.

    /// Ask macOS where we stand. Safe at launch: `getNotificationSettings` is a read and **never
    /// prompts**, unlike `requestAuthorization`, which is still left exactly where it was — at the
    /// first banner, lazily, for a `.notDetermined` install.
    func refreshAuthorizationStatus() {
        center.authorizationStatus { [weak self] status in
            Self.onMain { self?.noteAuthorization(status) }
        }
    }

    /// Record what macOS said, and say it out loud the first time the answer is "never".
    func noteAuthorization(_ status: SystemNotificationStatus) {
        DiagnosticLog.shared.note("auth", "system notifications = \(status.rawValue)")
        authorizationStatus = status
        guard status == .denied, !deniedHintPosted else { return }
        deniedHintPosted = true
        announceDenied()
    }

    /// The three things a denial is worth, and the only place they are spelled: a notice the user
    /// can read, a line in the record, and the OSLog mirror that comes with it.
    ///
    /// Not a `NoticeChange`, so no sink hears it: there is no pane, so there is nothing for the
    /// banner (which is the thing that is broken), the Dock badge or the pane mark to do with it.
    /// The activity log is written directly for the same reason — `ActivityLogSink` only ever sees
    /// pane notices, and giving it a second entrance would be a second owner of one record.
    @MainActor
    static func reportDenialToTheUser() {
        NoticeCenter.shared.postAppNotice(source: .custom("system"), urgency: .info,
                                          evidence: .composed, title: L("notice.system.denied"))
        ControlActivityLog.shared.record(.init(
            at: Date(),
            command: Self.deniedCommand,
            // QuickTerm itself, like every notice entry: nothing outside the app discovered this.
            peer: "QuickTerm",
            originPane: nil,
            target: nil,
            outcome: ControlActivityLog.Entry.Outcome.applied,
            // Not sensitive: this is our own sentence about our own settings, and it is exactly
            // what somebody reading `log stream` after the fact needs to see.
            changes: [ControlChange("notifications.system", from: nil, to: "denied")]))
    }

    /// The activity log's name for it. A constant so the test and the writer cannot drift.
    static let deniedCommand = "notice.system-denied"

    /// Whether an `add` failure means "macOS will not show this", as opposed to a malformed
    /// request. `UNErrorDomain` / `notificationsNotAllowed` is the one code that says so.
    private nonisolated static func meansNotAllowed(_ error: any Error) -> Bool {
        let error = error as NSError
        return error.domain == UNErrorDomain
            && error.code == UNError.Code.notificationsNotAllowed.rawValue
    }

    /// Run `body` on the main actor, **now** when we are already there.
    ///
    /// Both callbacks above are documented by `UserNotifications` as arriving on an unspecified
    /// thread, so the hop is required; hopping unconditionally would also make a double that
    /// answers synchronously land a run-loop turn later, and "the sink posted exactly one hint"
    /// would be a test that has to sleep to be true.
    private nonisolated static func onMain(_ body: @escaping @Sendable @MainActor () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { body() }
        } else {
            DispatchQueue.main.async { MainActor.assumeIsolated { body() } }
        }
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
            // The pane no longer needs the user (resolved to nothing, or downgraded to `info`): the
            // next `needsUser` alarm on it is a fresh one and may ping again, so drop the "already
            // announced" mark. Kept only while the pane genuinely still holds a live approval.
            if transition.after != .needsUser { pingedPanes.remove(notice.pane) }
            // Only take the banner down when the pane has nothing left to say. With two notices
            // live, resolving one must not take down the banner that describes the other.
            guard transition.after == nil else { return }
            withdraw(pane: notice.pane)

        case .activityChanged(let pane, let activity):
            // The user is looking at the pane now: whatever is on the lock screen about it is
            // stale. (The notice itself stays live unless it was an `info`, which the centre
            // resolves in the same pass.)
            if activity.isActive { withdraw(pane: pane) }

        case .quieted(let notice, _):
            // The banner half of the Q1(b) policy (plan §2.8). The user focused the pane and
            // typed into it while this alarm was live: the banner has done its job — it exists to
            // fetch somebody out of another app — so it comes down even though the notice is
            // still live and the pane mark still draws.
            //
            // Nothing is posted again from here. The alarm comes back on screen only when the
            // agent supersedes it with a *different* `needsUser` (a second tool asking), which
            // arrives as `.superseded` above and presents silently — the pane was already loud.
            withdraw(pane: notice.pane)

        case .rearmed(let notice, let activity):
            // The mirror of `.quieted`: the user left a pane that still needs them. Present now —
            // this is the one road by which an alarm raised while the pane was being watched (and so
            // never presented) reaches the screen, and the road back for one a keystroke had quieted.
            // The pane is inactive by construction here, so `present`'s own guard passes. Sound only
            // if this pane has not already been announced audibly (per pane, not per notice id: one
            // pane can hold several sources' `needsUser` notices coalesced to one banner, spec §3.5
            // rule 5). So the alarm raised while the pane was watched pings on first delivery, while
            // one you were already alerted about — by this or any source — returns silently.
            guard let activity else { return }
            present(notice, activity: activity, sound: !pingedPanes.contains(notice.pane))

        case .countsChanged:
            // The badge's business, not the banner's.
            break
        }
    }

    func clearAll() {
        for pane in presented { withdraw(pane: pane) }
        presented.removeAll()
        pingedPanes.removeAll()
    }

    // MARK: Presenting

    /// `settings.system` is read here rather than trusted from `isEnabled`, because the two say
    /// different things: `never` switches the sink off (and `clearAll`s it), while `inactive` -
    /// the only other value - still has to ask whether the user is looking right now.
    private func present(_ notice: Notice, activity: PaneActivity?, sound: Bool) {
        let who = locator.handle(notice.pane) ?? String(notice.pane.uuidString.prefix(8))
        guard settings().system == "inactive" else {
            DiagnosticLog.shared.note("banner", "skip pane=\(who) reason=system=\(settings().system)")
            return
        }
        // An unknown activity means the pane is gone: nothing to tell the user to go and look at.
        guard let activity, !activity.isActive else {
            DiagnosticLog.shared.note(
                "banner",
                "skip pane=\(who) reason=\(activity == nil ? "pane-gone" : "pane-active") auth=\(authorizationStatus.rawValue)")
            return
        }
        DiagnosticLog.shared.note(
            "banner", "present pane=\(who) sound=\(sound) auth=\(authorizationStatus.rawValue)")

        requestAuthorizationIfNeeded()

        let content = UNMutableNotificationContent()
        content.title = notice.title
        if let subtitle = subtitle(for: notice.pane) { content.subtitle = subtitle }
        if let body = bodyToShow(notice) { content.body = body }
        content.categoryIdentifier = Self.category
        content.userInfo = ["pane": notice.pane.uuidString, "notice": notice.id.uuidString]
        if sound { content.sound = .default }
        // A sound actually played for a live approval: this pane is now "already announced", so a
        // re-arm of it (however many sources describe the prompt) stays silent until it resolves.
        if sound, notice.urgency == .needsUser { pingedPanes.insert(notice.pane) }

        presented.insert(notice.pane)
        center.add(UNNotificationRequest(identifier: Self.identifier(pane: notice.pane),
                                         content: content, trigger: nil)) { [weak self] error in
            Self.onMain {
                if let error {
                    DiagnosticLog.shared.note("banner", "add FAILED pane=\(who) error=\(error.localizedDescription)")
                } else {
                    DiagnosticLog.shared.note("banner", "add OK pane=\(who) — macOS accepted the request")
                }
            }
            guard let error else { return }
            // `privacy: .public`: every one of these strings comes from the OS, carries nothing
            // of the user's, and is useless in a bug report when it reads `<private>`.
            AppDelegate.logger.error("notice banner refused: \(error.localizedDescription, privacy: .public)")
            // The second road to the denial hint. The probe at launch normally gets there first,
            // but a permission revoked *while* the app runs arrives only here — and a refusal the
            // user is never told about is the whole bug.
            guard Self.meansNotAllowed(error) else { return }
            Self.onMain { self?.noteAuthorization(.denied) }
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
        // `.badge` as well as `.alert`/`.sound`: without it macOS grants no badge capability, the
        // "Badge app icon" switch never appears in System Settings, and the Dock badge is suppressed.
        center.requestAuthorization(options: [.alert, .sound, .badge]) { [weak self] granted, error in
            Self.onMain {
                DiagnosticLog.shared.note(
                    "auth", "requestAuthorization → granted=\(granted) error=\(error?.localizedDescription ?? "none")")
                if let error {
                    AppDelegate.logger.error(
                        "notification authorization failed: \(error.localizedDescription, privacy: .public)")
                } else {
                    AppDelegate.logger.info("notification authorization granted=\(granted, privacy: .public)")
                }
                // Learn where we now stand — the cached status was read at launch, before the grant.
                self?.refreshAuthorizationStatus()
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
                    // The pane is the one being looked at (or gone): no banner. Still deliver it to
                    // Notification Center (`.list`) rather than dropping it entirely, so a notice is
                    // never silently lost when the app happens to be foreground at delivery.
                    DiagnosticLog.shared.note("banner", "willPresent → list-only (foreground, pane active/gone)")
                    completionHandler([.list])
                    return
                }
                DiagnosticLog.shared.note("banner", "willPresent → banner+sound+list (foreground, pane inactive)")
                completionHandler([.banner, .sound, .list])
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
    /// Spelled out rather than left to the protocol's default, which would call the empty
    /// `getNotificationSettings` above and never call back at all. `unavailable` is the honest
    /// answer for a centre that does nothing: we did not ask macOS anything.
    func authorizationStatus(_ completion: @escaping @Sendable (SystemNotificationStatus) -> Void) {
        completion(.unavailable)
    }
    func add(_ request: UNNotificationRequest,
             withCompletionHandler: (@Sendable ((any Error)?) -> Void)?) {
        withCompletionHandler?(nil)
    }
    func removeDeliveredNotifications(withIdentifiers identifiers: [String]) {}
    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {}
}
