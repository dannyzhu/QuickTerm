import AppKit
import UserNotifications

/// **The app-level half of the notification centre**: which screen a notice's pane lives on, and
/// what "take me there" does (design §3.5, contract §10.7).
///
/// Everything here is a lookup from a pane uuid - the only thing a `Notice` carries - to the
/// objects that can act on it. A notice knows its pane, its screen id and its workspace index;
/// only the registry knows which `MainWindowController` those belong to, and the registry lives
/// here.
extension AppDelegate {
    // MARK: Installation

    /// Guard for `ensureNoticeInterfaceInstalled`. Static, because what it installs is process-wide.
    @MainActor private static var noticeInterfaceInstalled = false

    /// Point `NoticeCenter.shared` at the real screens and register every sink, once per process
    /// (contract §10.10).
    ///
    /// The centre starts out with `NoticeLocator.unattached`, which answers "no such pane" to
    /// everything, so until this runs nothing can be posted, no mark can be drawn and no count can
    /// be counted. `attach` installs the real locator (the pane-activity source: focused pane, key
    /// window, visible workspace, app frontmost) plus the centre's own observers of the
    /// application becoming and resigning active.
    ///
    /// It is idempotent - `attach` on both counts, `addSink` by sink id - which is what lets it be
    /// called from more than one place without anybody having to own the ordering. Three places
    /// do: `applicationDidFinishLaunching` (the real one, before the config is loaded, so the
    /// first `applyGlobalConfig` already reaches every sink's `isEnabled`), the activation
    /// callback below, and the status bar on its way to the counts - which covers the one case
    /// the other two do not, an app launched in the background that never becomes active.
    @MainActor
    static func ensureNoticeInterfaceInstalled() {
        guard !noticeInterfaceInstalled, let app = NSApp.delegate as? AppDelegate else { return }
        noticeInterfaceInstalled = true
        let center = NoticeCenter.shared
        center.attach(locator: NoticeLocator(screens: app.screens))

        // Each sink gets its own locator: it is a two-word struct over the registry, and sharing
        // one would only invite somebody to give it state.
        let system = SystemNotificationSink(
            center: isRunningTests ? InertNotificationCenter() : UNUserNotificationCenter.current(),
            locator: NoticeLocator(screens: app.screens),
            route: noticeRoute)
        center.systemSink = system
        center.addSink(system)
        // The test host gets a Dock badge that writes nowhere: a test run must not leave a red
        // number on the icon of the app that is running it (`DockBadgeSink` takes the setter for
        // exactly this reason). `NoticeSystemSinkTests` asserts the label through its own sink.
        center.addSink(DockBadgeSink(setBadge: isRunningTests ? { _ in } : nil))
        center.addSink(ControlPlaneSink())
        center.addSink(ActivityLogSink())
        // No pane-mark or workspace-count sink: both surfaces observe the centre directly
        // (`PaneChrome`, `StatusBarView`), because SwiftUI already redraws them from `@Published
        // live` and a sink writing a cached flag onto the view would be a second source of truth.
        // `NoticeSettings.isEnabled(sinkID:)` still owns their switches; the two views ask it.

        // The delegate is what makes a click on a banner route, and it has to be installed before
        // `restoreSession()` runs so that a click which launched the app is delivered to a live
        // delegate rather than dropped. It goes on whichever centre the sink was built with - the
        // real one, or the inert one under the test host - so there is one code path rather than
        // one the tests never execute.
        system.installAsDelegate()
    }

    /// Second call site. `applicationDidFinishLaunching` installs the notice interface first, before
    /// the config is loaded; this callback re-checks on every activation, which costs one comparison
    /// because `ensureNoticeInterfaceInstalled` is idempotent. It stays as a belt-and-braces guard: if
    /// a future launch path ever skips the first call, the interface is still in place the moment the
    /// user brings the app forward. The status bar is the third call site, covering the one case this
    /// one does not: an app launched in the background that never becomes active at all.
    ///
    /// `@MainActor` spelled out: this is an `NSApplicationDelegate` method, so AppKit only ever
    /// calls it on the main thread - but a witness declared in an **extension** does not inherit
    /// the protocol's isolation the way one in the type's own body does, and without the
    /// annotation the body cannot touch the centre at all.
    @MainActor
    @objc
    func applicationDidBecomeActive(_ notification: Foundation.Notification) {
        Self.ensureNoticeInterfaceInstalled()
    }

    // MARK: Click routing

    /// What the system-notification sink is given as its `route:` - a click on a banner ends here.
    /// Stated as a closure because the sink is constructed with one and must not reach for
    /// `NSApp.delegate` itself.
    @MainActor
    static var noticeRoute: (UUID) -> Void {
        { pane in revealNoticePane(pane) }
    }

    /// Resolve a notice's pane to the screen it lives on and reveal it there.
    /// `false` = no screen has that pane any more (it closed while the banner was on screen);
    /// the caller's job is then to do nothing at all, not to fall back to some other pane.
    ///
    /// One line, because there is **one** road: `NoticeRouting.reveal` is what the contract names
    /// and it does the whole job - the same `ControlResolver.addressablePanes` reading of "this
    /// pane exists" (through `NoticeLocator`), plus the focus hold that keeps the routed pane
    /// focused against a mouse still parked where the banner was. This method stays because it is
    /// the app-side name for it: the delegate knows the registry, and the routing takes a locator.
    @discardableResult
    @MainActor
    static func revealNoticePane(_ pane: UUID) -> Bool {
        guard let app = NSApp.delegate as? AppDelegate else { return false }
        return NoticeRouting.reveal(pane: pane, locator: NoticeLocator(screens: app.screens))
    }

    // MARK: The status bar's counts

    /// Panes with a live `needsUser` notice, per workspace of the screen `model` belongs to.
    ///
    /// The status bar holds a `WorkspaceModel` and nothing else, and a count is per **screen** and
    /// workspace (`NoticeCounts.count(screen:workspace:)`) - the pill on screen 2 must not show
    /// screen 1's alarm. Identity, not equality: two screens' models are two objects.
    /// An empty array means "this model is on no screen" (a preview, a fixture), and the pills
    /// then draw exactly as they did before this feature existed.
    @MainActor
    static func workspaceNoticeCounts(for model: WorkspaceModel) -> [Int] {
        ensureNoticeInterfaceInstalled()
        guard let app = NSApp.delegate as? AppDelegate,
              let controller = app.screens.controllers.first(where: { $0.model === model })
        else { return [] }
        let counts = NoticeCenter.shared.counts
        guard counts.total > 0 else { return [] }
        return (0..<model.layouts.count).map {
            counts.count(screen: controller.windowID, workspace: $0)
        }
    }
}
