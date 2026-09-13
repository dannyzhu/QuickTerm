import AppKit

/// **Where a pane is, and whether anybody is looking at it.**
///
/// The notification centre never touches `ScreenRegistry` itself; it asks this. Two reasons, and
/// the second is the important one:
/// 1. tests can drive every rule in the centre — coalescing, counts across two screens, the
///    resolution rules, the activity pass — with a stub that answers from a dictionary, with no
///    windows, no key window and no frontmost app to arrange;
/// 2. "is the user looking at this pane" is one question with one answer, and it is asked by the
///    centre, by the system-notification sink and by the click routing. Three copies of a
///    four-clause conjunction would have drifted the first time somebody added zoom.
@MainActor
protocol NoticeLocating {
    func locate(_ pane: UUID) -> NoticeLocator.Located?
    func activity(_ pane: UUID) -> PaneActivity?
    func handle(_ pane: UUID) -> String?
}

@MainActor
struct NoticeLocator: NoticeLocating {
    struct Located {
        let pane: PaneView
        let controller: MainWindowController
        /// Zero-based, like `WorkspaceModel.activeIndex`.
        let workspace: Int

        var location: NoticeLocation {
            NoticeLocation(screen: controller.windowID, workspace: workspace)
        }
    }

    private let screens: ScreenRegistry

    init(screens: ScreenRegistry) {
        self.screens = screens
    }

    /// A locator that knows nothing. `NoticeCenter.shared` holds this until `attach` runs, so a
    /// notice posted before the app has finished launching is answered with `.unknownPane`
    /// instead of crashing on a registry that does not exist yet.
    ///
    /// `nonisolated` because it is the default argument of `NoticeCenter.init`, and a default
    /// argument expression is evaluated in a **nonisolated** context however isolated the
    /// initialiser itself is. Building an empty struct touches no shared state, so this is safe
    /// as well as necessary.
    nonisolated static var unattached: NoticeLocating { NoticeLocatorUnattached() }

    /// The same reading of "addressable" the control plane uses: a pane that is fading out is not
    /// addressable. That matters here because `post` answers `.unknownPane` for anything this
    /// cannot find — a notice must not be stored against a pane that is already on its way out,
    /// or it would be resolved as `.paneClosed` one run-loop turn later and nobody would ever see
    /// it.
    func locate(_ pane: UUID) -> Located? {
        for entry in ControlResolver.addressablePanes(in: screens) where entry.pane.id == pane {
            return Located(pane: entry.pane, controller: entry.controller, workspace: entry.workspace)
        }
        return nil
    }

    /// Computed, never cached: every one of the four clauses can change without anything
    /// notifying us, and a stale "the user is looking at it" is the one error that silently
    /// swallows an alarm.
    func activity(_ pane: UUID) -> PaneActivity? {
        guard let found = locate(pane) else { return nil }
        let controller = found.controller
        return PaneActivity(
            appActive: NSApp.isActive,
            screenKey: controller.window?.isKeyWindow == true,
            workspaceVisible: Self.isWorkspaceVisible(found),
            focused: controller.focusedPane === found.pane)
    }

    func handle(_ pane: UUID) -> String? {
        ControlHandleRegistry.shared.existingHandle(for: pane)
    }

    /// The workspace is the screen's active one **and** nothing else is drawn over this pane.
    ///
    /// The zoom clause is the part that is easy to get wrong: a zoomed pane covers the whole
    /// workspace, so every other tiled pane in it is invisible even though its workspace is
    /// "active". A floating pane is the exception — the floating layer draws above the zoom, so
    /// a floating pane stays visible while a tile is zoomed.
    private static func isWorkspaceVisible(_ found: Located) -> Bool {
        let model = found.controller.model
        guard model.activeIndex == found.workspace,
              model.layouts.indices.contains(found.workspace) else { return false }
        guard let zoomed = ControlStateEncoder.zoomedPaneID(in: model.layouts[found.workspace]),
              zoomed != found.pane.id else { return true }
        guard model.floatings.indices.contains(found.workspace) else { return false }
        return model.floatings[found.workspace].contains { $0.pane.id == found.pane.id }
    }
}


/// The do-nothing locator behind `NoticeLocator.unattached`.
///
/// A top-level type rather than one nested in `@MainActor struct NoticeLocator`: a nested type
/// inherits that isolation, and this one has to be constructible from a nonisolated default
/// argument. The protocol's requirements are still main-actor isolated, which is why the three
/// methods below carry the annotation explicitly.
private struct NoticeLocatorUnattached: NoticeLocating {
    /// Explicitly `nonisolated`: conforming to a `@MainActor` protocol infers that isolation onto
    /// the whole type, memberwise initialiser included, and this one has to be constructible from
    /// `NoticeCenter.init`'s default argument.
    nonisolated init() {}

    @MainActor func locate(_ pane: UUID) -> NoticeLocator.Located? { nil }
    @MainActor func activity(_ pane: UUID) -> PaneActivity? { nil }
    @MainActor func handle(_ pane: UUID) -> String? { nil }
}
