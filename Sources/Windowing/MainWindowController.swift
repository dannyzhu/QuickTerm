import AppKit
import Combine
import GhosttyKit
import SwiftUI
import UniformTypeIdentifiers

/// QuickTerm's main window controller: the sole owner of the workspace layout state
/// (spec §3 plus §4.2-bis).
/// It subclasses GhosttyEmbed's BaseTerminalController shim so the embedding layer's paths -
/// focus-follows-mouse, the split checks - work as they are.
/// Every WM action is dispatched on the active workspace's layout (scrolling by default, or
/// dwindle).
final class MainWindowController: BaseTerminalController {
    let model = WorkspaceModel()
    let ghostty: Ghostty.App
    /// The process-level session (config, keybindings, system stats, the fullscreen ledger). The
    /// session holds this controller strongly through the registry, so this has to be unowned.
    unowned let session: AppSession
    /// The shared keybinding table: a read-only reference, never rebuilt by a controller (on
    /// reload AppSession swaps in a new one and every screen is in sync).
    var keybindings: KeybindingMap { session.keybindings }
    /// The one system-stats poller in the process (injected into RootView)
    var stats: SystemStatsService { session.stats }
    var themeManager: ThemeManager { session.themeManager }
    private var keyMonitor: Any?
    private var mouseMonitor: Any?
    private var cancellables = Set<AnyCancellable>()
    /// One "title / cwd changed" subscription per pane (for control-plane events), added and
    /// removed along with the pane set
    private var paneEventSubscriptions: [ObjectIdentifier: AnyCancellable] = [:]
    /// One "archived content changed" subscription per pane (see `resubscribePaneSaves`), added and
    /// removed along with the pane set
    private var paneSaveSubscriptions: [ObjectIdentifier: AnyCancellable] = [:]
    private var lastSplitAnimationAt: Date?
    /// Close animation duration (the same source as the create animation); only when it elapses is
    /// the pane really removed from the layout and the surface released.
    static let closeAnimationDuration: TimeInterval = 0.28
    /// Close animation switch (off when the system has "Reduce motion" on; tests can turn it on
    /// explicitly)
    var closeAnimationEnabled: Bool = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    /// Panes fading out, each with its focus successor computed up front - the tree is still intact
    /// when the close begins, which is the only time the succession can be worked out.
    private var pendingCloses: [ObjectIdentifier: PendingClose] = [:]
    /// The file manager program (config `file-manager-command`, yazi by default) - a process-level
    /// setting, forwarded to AppSession.
    var fileManagerCommand: String {
        get { session.fileManagerCommand }
        set { session.fileManagerCommand = newValue }
    }
    /// Where a Cmd+clicked link in a terminal opens (config link-opener): browser-pane = in a
    /// browser pane, system = in the system default browser.
    var linkOpener: String {
        get { session.linkOpener }
        set { session.linkOpener = newValue }
    }
    /// Running file manager panes mapped to their session (on exit we read the cwd file to decide
    /// whether to open a terminal in its place; closing one does not raise the running-process
    /// confirmation)
    private var fileManagerSessions: [ObjectIdentifier: FileManagerLaunch.Session] = [:]

    /// The pane role the control plane sees (`state`, `list`, the `role:` predicate).
    /// A file manager pane is just a terminal running yazi - its `kind` is still terminal, and the
    /// role is what tells them apart.
    func controlRole(of pane: PaneView) -> String? {
        if fileManagerSessions[ObjectIdentifier(pane)] != nil { return "file-manager" }
        return pane.kind == .terminal ? "shell" : nil
    }
    private struct PendingClose {
        let view: PaneView
        let successor: PaneView?
    }
    private var scrollMonitor: Any?
    private var resizeTarget: PaneView?
    /// The Cmd+left-drag session on a floating pane: empty `edges` means move (and raise to the
    /// top), anything else means resize by that edge or corner.
    /// The session starts on mouse-down (raise, set the cursor), but it only counts as a real drag
    /// once the movement passes the threshold; if the mouse comes up without that, it was a plain
    /// click and both the down and the up are handed to the pane itself (Cmd+clicking a link relies
    /// on the engine calling open_url on release).
    struct FloatingDragSession {
        /// The session tracks the pane, not an index: while the button is held, Cmd+T, switching
        /// workspaces and moving a pane all mutate the floating array.
        weak var pane: PaneView?
        let edges: FloatingPane.DragEdges
        let down: NSEvent
        var moved = false
        static let threshold: CGFloat = 3
    }
    private var floatingDrag: FloatingDragSession?
    /// We set the cursor while Cmd-hovering a floating pane (reset on leaving, on releasing Cmd,
    /// and when the drag finishes)
    private var floatingCursorActive = false
    /// Width of the draggable resize band around a floating pane, in points
    static let floatingEdgeBand: CGFloat = 14
    private var stripPanSerial = 0
    /// This screen's index (0 = the first screen, whose title is always `QuickTerm`); once closed
    /// the index can be reused by a new screen.
    let screenIndex: Int
    /// This screen's stable identity in the archive (unchanged across launches; this is what
    /// `PersistedState.keyWindowID` refers to)
    let windowID: UUID
    /// The window has already been through windowWillClose (monitors and observers are torn down)
    private(set) var isClosed = false

    /// Visible columns per screen in scrolling mode (2 by default; the menu cycles 2 -> 3 -> 4; the
    /// config's `visible-columns` wins)
    private(set) var visibleColumns =
        UserDefaults.standard.object(forKey: "quickterm.visibleColumns") as? Int ?? 2
    var columnFactor: Double { ScrollingStrip.factor(forVisibleColumns: visibleColumns) }

    /// Hover to focus (spec §4.2, faithful to Hyprland's focus_follows_mouse).
    override var focusFollowsMouse: Bool { true }

    /// Once the screen is closed (monitors torn down, panes handed back) it accepts no more pane
    /// operations: a pane that has left the window must not resurrect this controller through one.
    override var acceptsPaneOperations: Bool { !isClosed }

    /// The tree view the embedding layer requires (only meaningful for the dwindle layout;
    /// scrolling returns an empty tree)
    override var surfaceTree: SplitTree<PaneView> {
        get {
            if case .dwindle(let tree) = model.layout { return tree }
            return SplitTree()
        }
        set {
            if case .dwindle = model.layout { model.layout = .dwindle(newValue) }
        }
    }

    /// Every pane in the active workspace (tiled plus floating; linear cycling and the focus scan
    /// cover both layers)
    var paneList: [PaneView] {
        model.layout.paneList + model.floating.map(\.pane)
    }
    /// Whether this controller consumes a WM key: a browser-only action is only consumed while the
    /// focus is on a browser pane.
    static func consumes(_ action: WMAction, focusedPane: PaneView?) -> Bool {
        if action.browserOnly { return focusedPane is BrowserPaneView }
        if action.terminalOnly { return focusedPane is Ghostty.SurfaceView }
        return true
    }

    /// Whether a menu item's fixed shortcut actually performs its action: [keybinds] and the pane
    /// consumption rules decide. A combination that has been unbound or rebound, and an action the
    /// focused pane does not consume (clear-screen while the focus is on a browser), both do
    /// nothing, and the key is handed back to the focused terminal. Clicking the menu item with the
    /// mouse (not a keyDown) always performs it.
    static func menuShortcutAllowed(_ action: WMAction, event: NSEvent?, keybindings: KeybindingMap,
                                   focusedPane: PaneView?) -> Bool {
        guard let event, event.type == .keyDown else { return true }
        guard keybindings.action(for: event)?.action == action else { return false }
        return consumes(action, focusedPane: focusedPane)
    }

    /// The clear-screen target: the window's real first responder decides. The Scratchpad is not in
    /// `paneList`, so `focusedPane` would fall back to the first tiled pane - picking the target
    /// that way clears the scrollback of a terminal the user cannot even see.
    var clearTarget: Ghostty.SurfaceView? {
        if let window, let fr = window.firstResponder as? Ghostty.SurfaceView { return fr }
        if model.scratchpadVisible, let scratch = model.scratchpadSurface { return scratch }
        return focusedSurface
    }

    /// Run the engine's clear_screen on the clear target (clears the screen and the scrollback).
    /// false means there was no terminal target, or the engine did not perform it (ghostty marks
    /// clear_screen as performable: on the alt screen, in vim or less, it does nothing and the key
    /// belongs to the program).
    @discardableResult
    func clearFocusedTerminal() -> Bool {
        clearTarget?.surfaceModel?.perform(action: "clear_screen") == true
    }

    /// Whether the focused pane is on the floating layer
    var focusedIsFloating: Bool {
        guard let f = focusedPane else { return false }
        return model.floating.contains { $0.pane === f }
    }
    /// Every pane across every workspace, including the scratchpad
    var allPanes: [PaneView] { model.allPanes }

    override var focusedPane: PaneView? {
        // Ground truth first (the `focused` flag can linger briefly while a view is remounted):
        // the first responder is a pane, or a descendant of one (a browser pane's WKWebView).
        if let window, let holder = paneList.first(where: { $0.holdsFirstResponder(of: window) }) {
            return holder
        }
        return paneList.first { $0.focused } ?? paneList.first
    }

    /// The single-focus invariant: when any pane becomes first responder, clear the leftover
    /// `focused` on every other pane. AppKit sends no resign when the first responder view leaves
    /// the window - see SurfaceView.viewWillMove(toWindow:).
    override func paneDidBecomeFirstResponder(_ pane: PaneView) {
        if pendingFocusTarget === pane { pendingFocusTarget = nil }   // The intent has been met
        for other in model.allPanes where other !== pane && other.focused {
            other.focusDidChange(false)
        }
    }

    /// The pane the controller explicitly wants focused (the intent). While it is set, no other
    /// surface being remounted may reclaim focus - on a dwindle split, the original pane's
    /// leaf-to-split remount triggers exactly such a reclaim and steals the focus we just handed to
    /// the new pane.
    private var pendingFocusTarget: PaneView?

    override func paneMayReclaimFocus(_ pane: PaneView) -> Bool {
        pendingFocusTarget == nil || pendingFocusTarget === pane
    }

    /// Every focus change the controller initiates goes through here: record the intent, call
    /// moveFocus (which waits for the mount), then verify once more after the layout animation.
    func requestFocus(to pane: PaneView, from: PaneView? = nil) {
        pendingFocusTarget = pane
        PaneView.moveFocus(to: pane, from: from)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self, weak pane] in
            guard let self, let pane, self.pendingFocusTarget === pane else { return }
            if pane.window != nil, let window = self.window, !pane.holdsFirstResponder(of: window) {
                // Knocked out by a remount, or by an event during the animation: hand it over
                // once more.
                PaneView.moveFocus(to: pane)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self, weak pane] in
                if let self, let pane, self.pendingFocusTarget === pane { self.pendingFocusTarget = nil }
            }
        }
    }

    /// Focus reconciliation: the `focused` flag has to agree with the window's first responder
    /// (the timed safety net after a remount).
    func reconcileFocus() {
        guard let window else { return }
        let holder = model.allPanes.first { $0.holdsFirstResponder(of: window) }
        for pane in model.allPanes where pane.focused && pane !== holder {
            pane.focusDidChange(false)
        }
        if let holder, !holder.focused {
            holder.focusDidChange(true)
        }
    }

    private func scheduleFocusReconcile() {
        for delay in [0.15, 0.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.reconcileFocus() }
        }
    }

    /// - Parameters:
    ///   - screen: the target display (nil = the main display); the window is centered in its
    ///     visibleFrame, cascaded when the display already has windows
    ///   - index: the screen index (0 = the first one, titled `QuickTerm`)
    ///   - restoring: true means `SessionStore` will pour the archive in afterwards (this
    ///     controller neither opens a starter terminal nor reads from disk itself)
    ///   - id: the window identity from the archive (reused when restoring, random when new)
    ///   - restoredFrame: the window frame from the archive (it gets constrained into the target
    ///     display's visible area)
    ///   - inheritedDirectory: the cwd the new screen's first terminal inherits (from the source
    ///     window's focused pane)
    init(ghostty: Ghostty.App, session: AppSession,
         screen: NSScreen? = nil, index: Int = 0, restoring: Bool = false,
         id: UUID = UUID(), restoredFrame: CGRect? = nil,
         inheritedDirectory: String? = nil) {
        self.ghostty = ghostty
        self.session = session
        self.screenIndex = index
        self.windowID = id
        let window = HiddenTitlebarWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1024, height: 720),
            styleMask: [],  // HiddenTitlebarWindow pins the style mask internally
            backing: .buffered, defer: false)
        window.title = ScreenRegistry.title(forIndex: index)
        super.init(window: window)
        window.windowController = self
        window.delegate = self

        // Focus reconciliation safety net: any change to the layout, the workspace or the floating
        // layer makes SwiftUI remount the SurfaceView, and after a remount the `focused` flag can
        // come adrift from the window's first responder (see
        // SurfaceView.viewWillMove(toWindow:)).
        for publisher in [model.$layouts.map { _ in () }.eraseToAnyPublisher(),
                          model.$floatings.map { _ in () }.eraseToAnyPublisher(),
                          model.$titles.map { _ in () }.eraseToAnyPublisher(),
                          model.$activeIndex.map { _ in () }.eraseToAnyPublisher()] {
            publisher.dropFirst().sink { [weak self] in
                guard let self else { return }
                self.scheduleFocusReconcile()
                // Any change to the layout, the floating layer or the active workspace queues a
                // debounced save. 1.5.x saved only on quit, so a crash or a force quit threw the
                // whole session away.
                self.session.sessionStore.scheduleSave()
                // The pane set may have changed: resubscribe each pane's "archived content
                // changed" (a terminal's cwd, a browser's page).
                // @Published publishes in willSet, so `model.layouts` still holds the old value
                // right now - we have to wait for it to settle before reading it.
                DispatchQueue.main.async { [weak self] in self?.resubscribePaneSaves() }
            }
            .store(in: &cancellables)
        }

        // Control-plane events (Phase 4): a separate sink, deliberately **not** folded into the one
        // above - that one queues a debounced save and a focus reconciliation on every trigger,
        // while the close animation (`closingPanes`) only means "this pane is no longer
        // addressable" and should not cost an extra write to disk.
        // All this does is announce "something may have changed"; what actually happened is derived
        // by `ControlEventBus` diffing against the previous snapshot. Hand-written emits at every
        // mutation site are guaranteed to miss cases, and `perform()` is reentrant, so the same
        // event would be reported several times.
        for publisher in [model.$layouts.map { _ in () }.eraseToAnyPublisher(),
                          model.$floatings.map { _ in () }.eraseToAnyPublisher(),
                          model.$titles.map { _ in () }.eraseToAnyPublisher(),
                          model.$activeIndex.map { _ in () }.eraseToAnyPublisher(),
                          model.$closingPanes.map { _ in () }.eraseToAnyPublisher()] {
            publisher.dropFirst().sink { ControlEventBus.noteChange() }.store(in: &cancellables)
        }

        window.contentView = NSHostingView(rootView: RootView(
            model: model, ghostty: ghostty, stats: stats,
            action: { [weak self] op in self?.handleSplitOperation(op) },
            onScrollingDrop: { [weak self] payload, dest, zone in
                self?.scrollingDrop(payload: payload, destination: dest, zone: zone)
            },
            onSelectWorkspace: { [weak self] i in self?.switchWorkspace(i) },
            onRenameWorkspace: { [weak self] i in self?.promptWorkspaceTitle(i) },
            onPanelChoose: { [weak self] i in self?.choosePanelItem(i) })
            .environmentObject(themeManager)
            // The UI language, for `@EnvironmentObject private var i18n: Localization` in any
            // SwiftUI view: reading a string through it is what re-renders that view when
            // `[general] language` changes. AppKit code uses the global `L(_:_:)` instead.
            .environmentObject(Localization.shared))

        // Live theme switching: when the overlay changes, hot-reload every surface (spec §3.2,
        // under 200ms).
        // The engine's app-level reloadConfig is done once by AppDelegate, so it does not run N
        // times across N screens.
        themeManager.addOverlayListener(token: self) { [weak self] in
            guard let self else { return }
            for pane in self.allPanes {
                if let surface = (pane as? Ghostty.SurfaceView)?.surface {
                    self.ghostty.reloadConfig(surface: surface, soft: false)
                } else if let browser = pane as? BrowserPaneView {
                    self.applyBrowserTheme(browser)
                }
            }
            self.applyAppearance()
        }
        applyAppearance()

        // Layer 4 of the config chain: config.toml (keybindings, workspace count, theme, the
        // [ghostty] passthrough).
        // Reading the file, filling in the template, the watcher and the global half (the
        // keybinding table, the engine overlay, the global browser settings) all belong to
        // AppSession; here we only apply the already-loaded copy to this screen.
        applyWindowConfig(session.settings)

        // State restoration (spec §4.8 / v9 §3): reading and migrating the archive belong entirely
        // to `SessionStore`, which creates the controller and then calls `restore(from:)` to pour
        // the layout in (restoring = true). All we handle here is the "not restoring" path: start
        // with one blank terminal, inheriting the cwd from the source window's focused pane.
        // The view has not been mounted by SwiftUI yet, so calling makeFirstResponder directly
        // returns true and does nothing (AppKit complains about a "different window ((null))") -
        // hence Ghostty.moveFocus, which waits for the mount before setting it.
        if !restoring { ensureStarterPane(inheriting: inheritedDirectory) }
        place(on: screen, restoredFrame: restoredFrame)
        window.makeKeyAndOrderFront(nil)

        // All three engine notifications carry a SurfaceView as their object and are registered
        // with object: nil, so with several screens every controller receives all of them - each
        // handler starts by checking ownership (see ghosttyDidCloseSurface and friends).
        // Process exit, or a close action: remove the pane.
        NotificationCenter.default.addObserver(
            self, selector: #selector(ghosttyDidCloseSurface(_:)),
            name: Ghostty.Notification.ghosttyCloseSurface, object: nil)
        // A file manager pane's child process exited (the engine does not close it on its own):
        // open a terminal in its place, or close the pane.
        NotificationCenter.default.addObserver(
            self, selector: #selector(ghosttyChildExited(_:)),
            name: Ghostty.Notification.ghosttyChildExited, object: nil)
        // Double-clicking a dwindle divider: the engine posts didEqualizeSplits back, and the whole
        // tree is equalized.
        NotificationCenter.default.addObserver(
            self, selector: #selector(ghosttyDidEqualizeSplits(_:)),
            name: Ghostty.Notification.didEqualizeSplits, object: nil)

        // WM-level key combinations: intercepted before event dispatch, and anything that does not
        // match is passed through to the surface, so terminal-level keys are unaffected.
        // While an overlay panel is open it takes the up/down, return and escape navigation
        // first.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let window = self.window, event.window === window else { return event }
            if self.model.activePanel != nil, self.handlePanelKey(event) { return nil }
            guard let hit = self.keybindings.action(for: event) else { return event }
            // Pane-specific actions: a browser-only one is not consumed while the focus is not on
            // a browser pane (so Cmd+R, Cmd+= and the rest still belong to the terminal), and a
            // terminal-only one (clear screen) is passed through while the focus is not on a
            // terminal. Clear picks its target from the real first responder, since the Scratchpad
            // is not in `paneList`.
            let target = hit.action.terminalOnly ? self.clearTarget : self.focusedPane
            guard Self.consumes(hit.action, focusedPane: target) else { return event }
            if hit.action == .clearTerminal {
                // The engine did not perform it (alt screen), so per ghostty's performable
                // semantics the key goes to the program. We cannot `return event` here: the Shift+
                // Cmd+K key equivalent on the Shell menu would swallow it again.
                if !self.clearFocusedTerminal(), let surface = self.clearTarget { surface.keyDown(with: event) }
                return nil
            }
            self.perform(hit.action, precise: hit.precise)
            return nil
        }

        // Tracking the Cmd state (for the drag source overlay) plus Cmd+right-drag resizing
        // (spec §4.2)
        mouseMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.flagsChanged, .rightMouseDown, .rightMouseDragged, .rightMouseUp,
                       .leftMouseDown, .leftMouseDragged, .leftMouseUp, .mouseMoved]
        ) { [weak self] event in
            guard let self else { return event }
            // The Cmd state is process-level: resync it from the event's own modifier flags no
            // matter which window the event landed in or what type it is. When an NSAlert, sheet or
            // popover becomes key the events belong to no terminal window, and a Cmd release that
            // happens over another app is never seen by a local monitor at all - missing either one
            // leaves the drag source overlay stuck, with the grab cursor never going away and the
            // overlay eating the scroll wheel.
            // N controllers write the same value, which is idempotent; writing only on a real
            // change saves the redundant @Published notifications.
            ModifierState.shared.sync(event.modifierFlags)
            if event.type == .flagsChanged {
                // Only the controller of the event's own window resets the cursor.
                guard event.window == nil || event.window === self.window else { return event }
                if !event.modifierFlags.contains(.command), self.floatingDrag == nil { self.resetFloatingCursor() }
                return event
            }
            // Multi-screen: while a session is in flight, only this window's mouse events count -
            // a drag on another screen must not drive this controller's session.
            if self.floatingDrag != nil || self.resizeTarget != nil,
               event.window !== self.window { return event }
            // A drag session is ended by the mouse button, not by the modifier: releasing Cmd
            // before the left button still has to finish cleanly, otherwise the leftover session
            // hijacks the next Cmd+drag (a tiled pane will not drag, and the cursor is stuck).
            if self.floatingDrag != nil, let handled = self.floatingSessionEvent(event) {
                return handled ? nil : event
            }
            if let pane = self.resizeTarget {
                switch event.type {
                case .rightMouseDragged:
                    if let idx = self.floatingIndex(of: pane) {
                        self.resizeFloating(at: idx, dx: event.deltaX, dy: event.deltaY)
                    } else {
                        self.resizeByDrag(pane: pane, dx: event.deltaX, dy: event.deltaY)
                    }
                    return nil
                case .rightMouseUp:
                    self.resizeTarget = nil
                    return nil
                default: break
                }
            }
            guard event.window === self.window,
                  event.modifierFlags.contains(.command) else {
                if event.type == .mouseMoved { self.resetFloatingCursor() }
                return event
            }
            switch event.type {
            case .mouseMoved:
                // Cmd-hover: the middle of a floating pane gives the grab cursor (the link cursor
                // while pointing at a link), the edges and corners the resize cursor for that
                // direction.
                let hit = self.floatingDragHit(event)
                self.updateFloatingCursor(for: hit?.edges, pane: hit.map { self.model.floating[$0.index].pane })
                return event
            case .leftMouseDown:
                // Cmd+left: the middle of a floating pane moves it freely (and raises it), the
                // edges and corners resize it (with the opposite edge pinned). On a tiled pane it
                // is passed through to the drag-and-drop source.
                return self.beginFloatingDrag(with: event) ? nil : event
            case .leftMouseDragged, .leftMouseUp:
                // No session: pass it through. Drags and releases inside a session were handled
                // above.
                return event
            case .rightMouseDown:
                // No resizing a pane while it fades out.
                self.resizeTarget = self.paneUnderPointer(event)
                    .flatMap { self.model.closingPanes.contains($0.id) ? nil : $0 }
                return self.resizeTarget == nil ? event : nil
            case .rightMouseDragged, .rightMouseUp:
                return event   // No session: pass it through
            default:
                return event
            }
        }

        // Scroll wheel: over the top bar it cycles workspaces (spec §4.4); over the content area,
        // in a scrolling layout, and predominantly horizontal, it pans the canvas (spec §4.2-bis,
        // an incidental feature).
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            // The wheel resyncs the Cmd state too: the old bug where missing one release meant
            // "the terminal never scrolls again" heals itself here.
            ModifierState.shared.sync(event.modifierFlags)
            guard let self, let window = self.window, event.window === window,
                  let content = window.contentView else { return event }
            let p = content.convert(event.locationInWindow, from: nil)
            let yTop = content.isFlipped ? p.y : content.bounds.height - p.y
            if self.model.barVisible, yTop < StatusBarView.height {
                let delta = event.scrollingDeltaY + event.scrollingDeltaX
                guard abs(delta) > 0.5 else { return nil }
                let count = self.model.layouts.count
                let next = (self.model.activeIndex + (delta < 0 ? 1 : count - 1)) % count
                self.switchWorkspace(next)
                return nil
            }
            // While the Cmd drag source overlay covers a pane (the overlay is a sibling subtree, so
            // walking up superviews never finds the pane), claim the wheel for the pane it
            // covers.
            func effectiveHit(_ point: NSPoint) -> NSView? {
                let hit = content.hitTest(point)
                return (hit as? PaneOverlaying)?.overlaidPane ?? hit
            }
            // An overflowing browser tab bar takes the horizontal wheel itself (the monitor runs
            // before view dispatch, so otherwise the bar would never get a chance at it).
            if let hit = effectiveHit(p),
               let bar = sequence(first: hit, next: { $0.superview })
                   .compactMap({ $0 as? BrowserTabBarView }).first,
               bar.isOverflowing {
                return event
            }
            // An active browser pane takes the two-finger horizontal swipe itself (horizontal page
            // scrolling, the back/forward gesture) instead of panning the canvas.
            if let hit = effectiveHit(p), self.browserPaneClaimingScroll(under: hit) != nil {
                return event
            }
            if case .scrolling = self.model.layout,
               abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY),
               abs(event.scrollingDeltaX) > 0.5 || event.phase == .ended || event.momentumPhase == .ended {
                self.stripPanSerial += 1
                self.model.stripPan = .init(
                    delta: event.scrollingDeltaX,
                    ended: event.phase == .ended || event.momentumPhase == .ended,
                    serial: self.stripPanSerial)
                return nil
            }
            return event
        }
    }

    /// Returns the browser pane under the mouse when that pane **holds keyboard focus**: the wheel
    /// and two-finger swipe then belong to the page, not to canvas panning. An inactive browser
    /// pane pans the canvas as before - the pointer is only passing over it.
    func browserPaneClaimingScroll(under view: NSView) -> BrowserPaneView? {
        guard let window,
              let pane = sequence(first: view, next: { $0.superview }).compactMap({ $0 as? BrowserPaneView }).first,
              pane.holdsFirstResponder(of: window) else { return nil }
        return pane
    }

    // MARK: config.toml (layer 4 of the config chain, spec §4.7)
    // Reading the file, watching it, deduplicating and the global half all live in AppSession; all
    // this does is apply one Settings to **this screen**.
    // The rule for deciding: anything whose change affects other screens (the keybinding table, the
    // engine overlay, BrowserPaneView.settings, the extension switch) belongs to applyGlobalConfig
    // and runs once per reload.

    func applyWindowConfig(_ settings: ConfigStore.Settings) {
        // The empty-workspace hint shows the binding actually in effect (the keybinding table
        // comes from AppSession).
        model.newTerminalCombo = keybindings.displayBindings()
            .first { $0.action == .newTerminal }?.combo ?? "Cmd+Return"
        // Hot-reload the user agent and the inspector flag.
        for case let browser as BrowserPaneView in allPanes { browser.applySettings() }
        model.setWorkspaceCount(settings.workspaces)
        if let n = settings.visibleColumns { setVisibleColumns(n, persist: false) }
    }

    // MARK: Reading and writing state (spec §4.8 / v9 §3; reading and migrating belong to
    // `SessionStore`, this only covers one window's slice)

    /// This screen's slice of the archive (`SessionStore.snapshot()` calls it once per window).
    /// **Read-only**: archiving is now driven by a debounce timer, so a snapshot must never change
    /// anything on screen - panes that are fading out are filtered out of the copy only. We do not
    /// flush them, because that would cut short a close animation that is still playing.
    func windowState() -> WindowState {
        var layouts = model.layouts
        var floatings = model.floatings
        let closing = model.closingPanes
        if !closing.isEmpty {
            for i in layouts.indices {
                for pane in layouts[i].paneList where closing.contains(pane.id) {
                    switch layouts[i] {
                    case .scrolling(let strip):
                        layouts[i] = .scrolling(strip.removing(pane))
                    case .dwindle(let tree):
                        guard let node = tree.root?.node(view: pane) else { continue }
                        layouts[i] = .dwindle(tree.removing(node))
                    }
                }
            }
            for i in floatings.indices { floatings[i].removeAll { closing.contains($0.pane.id) } }
        }
        // While fullscreen the window fills the display, so what has to be archived is the frame
        // to restore when fullscreen ends.
        return WindowState(
            id: windowID,
            layouts: layouts,
            floatings: floatings,
            activeIndex: model.activeIndex,
            // If no workspace was ever named, omit the field entirely: in the vast majority of
            // archives it would be a row of nulls taking up space for nothing.
            workspaceTitles: model.titles.contains(where: { $0 != nil }) ? model.titles : nil,
            visibleColumns: visibleColumns,
            display: DisplayRef(screen: window?.screen),
            frame: savedFrame ?? window?.frame,
            isFullscreen: isSimpleFullscreen,
            joinAllSpaces: joinsAllSpaces,
            focusedPaneID: focusedPane.flatMap { closing.contains($0.id) ? nil : $0.id })
    }

    /// One "archived content changed" subscription per pane (a terminal's cwd through `$pwd`, a
    /// browser through `archiveDidChange`).
    /// A `cd` or opening a page has to reach the archive outside of layout events too - otherwise,
    /// after a crash or a force quit, what comes back is the directory and the page as of the last
    /// layout change.
    /// Every change to the pane set (creating, restoring, dropping in, closing) arrives here
    /// through the layout sink, and resubscribing is all that is needed.
    private func resubscribePaneSaves() {
        guard !isClosed else { return }
        let live = model.allPanes
        let ids = Set(live.map(ObjectIdentifier.init))
        paneSaveSubscriptions = paneSaveSubscriptions.filter { ids.contains($0.key) }
        for pane in live where paneSaveSubscriptions[ObjectIdentifier(pane)] == nil {
            let changes: AnyPublisher<Void, Never>
            if let terminal = pane as? Ghostty.SurfaceView {
                // dropFirst: the value at subscription time is not a "change". removeDuplicates:
                // most shells emit OSC 7 at every prompt.
                changes = terminal.$pwd.dropFirst().removeDuplicates().map { _ in () }.eraseToAnyPublisher()
            } else {
                changes = pane.archiveDidChange.eraseToAnyPublisher()
            }
            paneSaveSubscriptions[ObjectIdentifier(pane)] = changes.sink { [weak self] in
                self?.session.sessionStore.scheduleSave()
            }
        }
        // The control plane's pane.title.changed / pane.cwd.changed go through the same
        // resubscription path: a terminal's title and its OSC 7 pwd are both @Published, and a
        // browser pane's page changes arrive via archiveDidChange.
        // **Only the title and the cwd ever appear in an event; a pane's output content never
        // does.**
        paneEventSubscriptions = paneEventSubscriptions.filter { ids.contains($0.key) }
        for pane in live where paneEventSubscriptions[ObjectIdentifier(pane)] == nil {
            let changes: AnyPublisher<Void, Never>
            if let terminal = pane as? Ghostty.SurfaceView {
                changes = terminal.$title.dropFirst().removeDuplicates().map { _ in () }
                    .merge(with: terminal.$pwd.dropFirst().removeDuplicates().map { _ in () })
                    .eraseToAnyPublisher()
            } else {
                changes = pane.archiveDidChange.eraseToAnyPublisher()
            }
            paneEventSubscriptions[ObjectIdentifier(pane)] = changes.sink {
                ControlEventBus.noteChange()
            }
        }
    }

    /// The starter pane: open one terminal when there is no pane at all (a new screen, and the
    /// fallback for an empty archive).
    func ensureStarterPane(inheriting directory: String? = nil) {
        guard model.allPanes.isEmpty else { return }
        let first = newSurface(workingDirectory: directory)
        model.layout = .scrolling(ScrollingStrip(pane: first, widthFactor: columnFactor))
        requestFocus(to: first)
    }

    /// Pour an archive in: every pane reopens its shell at the archived cwd and every browser pane
    /// reopens its tabs.
    /// An empty archive returns false, and the caller opens a blank terminal.
    @discardableResult
    func restore(from state: WindowState) -> Bool {
        // Normalizing column widths needs the final column factor, so the visible column count has
        // to be applied first (the layout is still empty at this point, so nothing is relaid out).
        // When config.toml states `visible-columns` explicitly the config wins - the config layer
        // always beats the archive.
        if session.settings.visibleColumns == nil, let columns = state.visibleColumns {
            setVisibleColumns(columns, persist: false)
        }
        let restored = applyArchive(layouts: state.layouts, floatings: state.floatings,
                                    activeIndex: state.activeIndex, titles: state.workspaceTitles)
        guard restored else { return false }
        // Restored browser panes get the theme too.
        for case let browser as BrowserPaneView in allPanes { applyBrowserTheme(browser) }
        // The archived focus pane wins, looked up only inside the active workspace: do not hand
        // focus to a workspace that is not mounted.
        // An old archive, or an id that does not resolve, falls back to the first pane, exactly as
        // v4 behaved.
        let target = state.focusedPaneID.flatMap { id in paneList.first { $0.id == id } } ?? focusedPane
        if let target { requestFocus(to: target) }
        joinsAllSpaces = state.joinAllSpaces
        if state.isFullscreen, !isSimpleFullscreen { toggleSimpleFullscreen() }
        return true
    }

    /// Apply the three pieces - layouts, floating layer, active workspace - shared by v2-v5;
    /// includes normalizing historical column widths and padding out the floating layer.
    private func applyArchive(layouts: [WorkspaceLayout], floatings rawFloatings: [[FloatingPane]]?,
                              activeIndex: Int, titles: [String?]? = nil) -> Bool {
        let floatings = rawFloatings ?? Array(repeating: [], count: layouts.count)
        guard !(layouts.allSatisfy(\.isEmpty) && floatings.allSatisfy(\.isEmpty)) else { return false }
        // Normalize old state: 0.49 (from when the peek was 2%) and 0.44 (from when it was 6%) were
        // the historical default column widths, so map them onto the current column factor. Widths
        // the user adjusted by hand are kept exactly as they are.
        let legacyDefaults = [0.49, 0.44]
        model.layouts = layouts.map { layout in
            guard case .scrolling(var strip) = layout else { return layout }
            for i in strip.columns.indices
            where legacyDefaults.contains(where: { abs(strip.columns[i].widthFactor - $0) < 0.001 }) {
                strip.columns[i].widthFactor = columnFactor
            }
            return .scrolling(strip)
        }
        model.floatings = floatings
        if model.floatings.count < model.layouts.count {
            model.floatings.append(contentsOf: Array(
                repeating: [], count: model.layouts.count - model.floatings.count))
        }
        // Apply the names first and let setWorkspaceCount align the length afterwards (an old
        // archive has no such field, which means no workspace was ever named).
        if let titles { model.titles = titles }
        model.setWorkspaceCount(max(model.layouts.count, 1))
        model.activeIndex = min(max(activeIndex, 0), model.layouts.count - 1)
        return true
    }

    /// Light theme follow-through (spec §4.5): the window appearance plus the engine's color
    /// scheme
    private func applyAppearance() {
        let light = themeManager.current.isLight
        window?.appearance = NSAppearance(named: light ? .aqua : .darkAqua)
        if let app = ghostty.app {
            ghostty_app_set_color_scheme(
                app, light ? GHOSTTY_COLOR_SCHEME_LIGHT : GHOSTTY_COLOR_SCHEME_DARK)
        }
    }

    // MARK: Window placement and screen lifecycle (multi-screen, spec v9 §1.2)

    /// The QuickTerm screen windows already on the same display (used for the cascade offset)
    private static func siblingWindows(excluding window: NSWindow, on screen: NSScreen?) -> [NSWindow] {
        NSApp.windows.filter {
            $0 !== window && $0.isVisible && $0.windowController is MainWindowController
                && (screen == nil || $0.screen === screen)
        }
    }

    /// Place the window: with a display given, center it in that display's visibleFrame, cascade it
    /// when the display already has windows, and always finish with constrainFrameRect.
    /// With no display given and this being the process's first window, keep the historical
    /// behavior (window.center()).
    /// A `restoredFrame` (from the archive) wins: put it back exactly, constrained only into the
    /// target display's visible area.
    private func place(on screen: NSScreen?, restoredFrame: CGRect? = nil) {
        guard let window else { return }
        if let restoredFrame {
            guard let target = screen ?? NSScreen.main else {
                window.setFrame(restoredFrame, display: false)
                return
            }
            let fitted = SessionStore.constrain(restoredFrame, into: target.visibleFrame)
            window.setFrame(window.constrainFrameRect(fitted, to: target), display: false)
            return
        }
        let siblings = Self.siblingWindows(excluding: window, on: screen ?? NSScreen.main)
        guard let target = screen ?? NSScreen.main else { window.center(); return }
        guard screen != nil || !siblings.isEmpty else { window.center(); return }
        let visible = target.visibleFrame
        var frame = window.frame
        frame.size.width = min(frame.width, visible.width)
        frame.size.height = min(frame.height, visible.height)
        // Center, then cascade: the nth window on the same display is offset 24pt right and down
        // per step, and the 7th wraps back to the start.
        let step = CGFloat(siblings.count % 6) * 24
        frame.origin = CGPoint(x: visible.midX - frame.width / 2 + step,
                               y: visible.midY - frame.height / 2 - step)
        frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
        frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
        window.setFrame(window.constrainFrameRect(frame, to: target), display: false)
    }

    /// Move this screen to another display: keep the window size (shrinking it if it does not fit)
    /// and land it at the same relative position it had within the old display's visible area.
    func move(to screen: NSScreen) {
        guard let window, window.screen !== screen else { return }
        let visible = screen.visibleFrame
        // While fullscreen the window fills the old display, so what actually has to move is the
        // frame that will be restored when fullscreen ends.
        var frame = savedFrame ?? window.frame
        frame.size.width = min(frame.width, visible.width)
        frame.size.height = min(frame.height, visible.height)
        let source = (window.screen ?? NSScreen.main)?.visibleFrame
        if let source, source.width > frame.width || source.height > frame.height {
            let rx = source.width > frame.width ? (frame.minX - source.minX) / (source.width - frame.width) : 0.5
            let ry = source.height > frame.height ? (frame.minY - source.minY) / (source.height - frame.height) : 0.5
            frame.origin = CGPoint(x: visible.minX + rx * max(visible.width - frame.width, 0),
                                   y: visible.minY + ry * max(visible.height - frame.height, 0))
        } else {
            frame.origin = CGPoint(x: visible.midX - frame.width / 2, y: visible.midY - frame.height / 2)
        }
        let placed = window.constrainFrameRect(frame, to: screen)
        if savedFrame != nil {
            // While fullscreen: the window fills the new display, and leaving fullscreen has to
            // land on the new display too - otherwise it jumps straight back the moment you
            // leave.
            savedFrame = placed
            window.setFrame(screen.frame, display: true)
        } else {
            window.setFrame(placed, display: true)
        }
    }

    /// "Show on all desktops": there is no public API to assign a window to a Space, so
    /// canJoinAllSpaces is all we can offer.
    var joinsAllSpaces: Bool {
        get { window?.collectionBehavior.contains(.canJoinAllSpaces) ?? false }
        set {
            guard let window else { return }
            var behavior = window.collectionBehavior
            if newValue {
                behavior.insert(.canJoinAllSpaces)
                behavior.remove(.moveToActiveSpace)
            } else {
                behavior.remove(.canJoinAllSpaces)
            }
            window.collectionBehavior = behavior
        }
    }

    /// Right-click on a workspace pill: name or rename this **slot**.
    /// The shape is identical to the terminal's "Change Terminal Title" (an NSAlert plus a one-line
    /// text field plus OK / Cancel), and leaving it blank clears the name so the pill falls back to
    /// its number. This path and `quickterm workspace set --title` are the only two things that
    /// change a name - clearing the workspace, closing the last pane and `spec apply` all leave it
    /// alone.
    func promptWorkspaceTitle(_ index: Int) {
        guard model.layouts.indices.contains(index), !AppDelegate.isRunningTests else { return }
        let alert = NSAlert()
        alert.messageText = L("window.workspace-title.title", index + 1)
        alert.informativeText = L("window.workspace-title.detail")
        alert.alertStyle = .informational
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 250, height: 24))
        field.stringValue = model.title(at: index) ?? ""
        alert.accessoryView = field
        alert.addButton(withTitle: L("window.button.ok"))
        alert.addButton(withTitle: L("window.button.cancel"))
        alert.window.initialFirstResponder = field
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            // One rulebook (`TitleRules`), two manners: the command line refuses a bad value, a
            // dialog filters it. A person is typing here, so anything over the cap is truncated
            // instead of raising an error, and control characters are dropped - this `NSTextField`
            // happily accepts a pasted newline, and a name with a newline lays the pill out over
            // two lines and bursts through the 26pt status bar.
            self.model.setTitle(TitleRules.fromTypedInput(field.stringValue), at: index)
        }
        // With a window, use a sheet, as "Change Terminal Title" does: a modal floating on some
        // other screen is a dialog the user cannot find.
        if let window {
            alert.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(alert.runModal())
        }
    }

    /// Confirmation before closing this screen (reusing the quit confirmation's count and copy);
    /// with no live pane it goes through without asking.
    func confirmCloseScreen() -> Bool {
        flushPendingCloses()
        let open = model.allPanes.count
        guard AppDelegate.shouldConfirmQuit(openPaneCount: open), !AppDelegate.isRunningTests else { return true }
        let alert = NSAlert()
        alert.messageText = L("window.close-screen.title")
        alert.informativeText = Lp("window.close-screen.detail", count: open, open)
        alert.addButton(withTitle: L("window.button.close"))
        alert.addButton(withTitle: L("window.button.cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Tear down everything that would outlive the window. Called explicitly when the window
    /// closes rather than relying on deinit ordering: the closures behind the monitors, the
    /// notifications and the theme listener keep the controller alive, and the weak-reference tests
    /// go red.
    private func teardown() {
        guard !isClosed else { return }
        isClosed = true
        flushPendingCloses()
        NotificationCenter.default.removeObserver(self)
        themeManager.removeOverlayListener(token: self)
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor); self.mouseMonitor = nil }
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor); self.scrollMonitor = nil }
        cancellables.removeAll()
        paneSaveSubscriptions.removeAll()
        paneEventSubscriptions.removeAll()
        floatingDrag = nil
        resizeTarget = nil
        // The presentationOptions behind non-native fullscreen are process-level: whatever this
        // window acquired has to be handed back. The ledger is per window and we return only our
        // own share - while another screen is still fullscreen the Dock and menu bar have to stay
        // hidden.
        savedFrame = nil
        session.setSimpleFullscreen(false, for: self)
        // The same per-pane teardown as removeFromActiveLayout / removeFromAnyWorkspace: a browser
        // pane has to cancel in-flight downloads and tell extensions the "window" closed (deinit
        // only tears the tabs down and does none of that).
        // It has to happen before the view hierarchy is torn down: while handling didCloseWindow,
        // WebKit calls back synchronously into tab.window(for:).
        ControlUndo.invalidate()
        for pane in model.allPanes {
            forgetFileManagerSession(pane)
            (pane as? BrowserPaneView)?.paneWillClose()
        }
        // Tear the view hierarchy down explicitly: the panes are held strongly by SwiftUI's view
        // tree, so AppKit keeping the window object around a little longer keeps every shell on
        // this screen alive. Closing a screen should end the processes inside it.
        window?.contentView = nil
        model.layouts = model.layouts.map { _ in .empty }
        model.floatings = model.floatings.map { _ in [] }
        model.scratchpadVisible = false
        model.scratchpadSurface = nil
        // Safety net for sessions not registered in allPanes (normally empty - the loop above has
        // already cleaned each one up).
        for session in fileManagerSessions.values { FileManagerLaunch.cleanup(session) }
        fileManagerSessions.removeAll()
    }

    private func paneUnderPointer(_ event: NSEvent) -> PaneView? {
        guard let content = window?.contentView else { return nil }
        var v = content.hitTest(content.convert(event.locationInWindow, from: nil))
        while let cur = v {
            if let s = cur as? PaneView { return s }
            v = cur.superview
        }
        // When the hit lands on a sibling view such as an overlay, fall back to a search by
        // geometry - and it has to go top-down in z order, with the floating layer (last array
        // entry is topmost) before the tiled layer. Otherwise, with a floating pane sitting on a
        // tiled one, a Cmd+drag or resize grabs the tiled pane underneath.
        let byZ = model.floating.reversed().map(\.pane) + model.layout.paneList
        return byZ.first {
            $0.window === window && $0.convert($0.bounds, to: nil).contains(event.locationInWindow)
        }
    }

    /// Cmd+right-drag: in dwindle it adjusts the nearest divider, in scrolling it adjusts the
    /// column width by the horizontal displacement.
    /// Both are only **this gesture's** conversion into `controlResizeSplit` /
    /// `controlResizeColumn` - the real algorithm exists once, and the control plane's
    /// `pane resize --dir` calls the very same function.
    private func resizeByDrag(pane: PaneView, dx: CGFloat, dy: CGFloat) {
        switch model.layout {
        case .dwindle:
            // Cap a single event's displacement at 200pt: the gesture occasionally throws out an
            // absurd delta.
            let amount = min(max(abs(dx) >= abs(dy) ? abs(dx) : abs(dy), 1), 200)
            let direction: SplitTree<PaneView>.Spatial.Direction =
                abs(dx) >= abs(dy) ? (dx > 0 ? .right : .left) : (dy > 0 ? .down : .up)
            controlResizeSplit(pane, workspace: model.activeIndex, points: amount, direction: direction)
        case .scrolling:
            controlResizeColumn(pane, workspace: model.activeIndex, deltaPoints: dx)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    deinit {
        // The normal path has already cleaned everything up in windowWillClose's teardown; this is
        // the safety net for when the close flow never ran.
        NotificationCenter.default.removeObserver(self)
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
    }

    // MARK: WM actions (spec §5.1 plus §4.2-bis; dispatched on the active layout)

    func perform(_ action: WMAction, precise: Bool = false) {
        // Layout operations act on the real layout: panes mid-fade are removed right away.
        flushPendingCloses()
        // A change that is not an insert must not replay the entry animation.
        if ![.newTerminal, .fileManager, .newBrowser].contains(action) { model.appearingPane = nil }
        switch action {
        case .newTerminal:
            insertNewPane(newSurface(inheritingFrom: focusedPane))

        case .clearTerminal:
            // Same as ghostty's clear_screen (Terminal.app's Cmd+K semantics: clear the screen and
            // the scrollback); only applies to the terminal that really is first responder.
            clearFocusedTerminal()

        case .fileManager:
            // Omarchy's Super+Shift+F: start the TUI file manager in a new pane, at the focused
            // pane's directory.
            let start = focusedPane?.workingDirectory ?? FileManager.default.homeDirectoryForCurrentUser.path
            let made = makeFileManagerPane(startDirectory: start)
            // Only register a session when the file manager really started (that is what skips the
            // close confirmation and reads the directory on exit); the hint pane opened when the
            // program is missing is an ordinary interactive shell and is treated as an ordinary
            // pane.
            if insertNewPane(made.pane), made.launch.found {
                fileManagerSessions[ObjectIdentifier(made.pane)] = made.launch.session
            } else {
                FileManagerLaunch.cleanup(made.launch.session)
            }

        case .newBrowser:
            openBrowserPane(url: BrowserPaneView.settings.homeURL, from: focusedPane)
        case .webBack: browserPane?.goBack()
        case .webForward: browserPane?.goForward()
        case .webReload: browserPane?.reload()
        case .webFocusAddress: browserPane?.focusAddressBar()
        case .webOpenExternal: browserPane?.openExternally()
        case .webZoomIn: browserPane?.zoom(by: 1.1)
        case .webZoomOut: browserPane?.zoom(by: 1 / 1.1)
        case .webZoomReset: browserPane?.resetZoom()
        case .webNewTab: browserPane?.newTab()
        case .webNextTab: browserPane?.selectTab(offset: 1)
        case .webPrevTab: browserPane?.selectTab(offset: -1)
        case .webExtensions: browserPane?.showExtensionsMenu()

        case .closePane:
            // With several tabs in a browser pane, Cmd+W closes the current tab and only the last
            // tab closes the pane (Chrome's semantics).
            if let browser = browserPane, browser.tabs.count > 1 {
                browser.closeActiveTab()
            } else if let focused = focusedPane {
                closePane(focused)
            }

        case .focusLeft: moveFocus(.left)
        case .focusRight: moveFocus(.right)
        case .focusUp: moveFocus(.up)
        case .focusDown: moveFocus(.down)

        case .swapLeft: swapFocused(.left)
        case .swapRight: swapFocused(.right)
        case .swapUp: swapFocused(.up)
        case .swapDown: swapFocused(.down)

        case .toggleSplitDirection:
            guard let focused = focusedPane else { return }
            switch model.layout {
            case .dwindle(let tree):
                model.layout = .dwindle((try? tree.togglingSplitDirection(around: focused)) ?? tree)
            case .scrolling(let strip):
                // Cmd+J: merge into the vertical stack of the column to the left, or split back
                // out into a column of its own (spec §4.2-bis).
                model.layout = .scrolling(strip.mergingOrSplitting(focused))
                requestFocus(to: focused)
            }

        case .toggleZoom:
            guard let focused = focusedPane else { return }
            switch model.layout {
            case .dwindle(let tree):
                guard let node = tree.root?.node(view: focused) else { return }
                model.layout = .dwindle(SplitTree(
                    root: tree.root, zoomed: tree.zoomed == node ? nil : node))
            case .scrolling(let strip):
                model.layout = .scrolling(strip.togglingZoom(focused))
            }

        case .equalize:
            switch model.layout {
            case .dwindle(let tree): model.layout = .dwindle(tree.equalized())
            case .scrolling(let strip): model.layout = .scrolling(strip.equalized(to: columnFactor))
            }

        case .resizeLeft: resizeFocused(.left, precise: precise)
        case .resizeRight: resizeFocused(.right, precise: precise)
        case .resizeUp: resizeFocused(.up, precise: precise)
        case .resizeDown: resizeFocused(.down, precise: precise)

        case .cyclePaneNext: cycleFocus(next: true)
        case .cyclePanePrev: cycleFocus(next: false)

        case .toggleLayout:
            // Cmd+L: dwindle and scrolling - restore the previous layout while the pane set is
            // unchanged, otherwise use the pane- and order-preserving conversion.
            model.toggleLayout(columnFactor: columnFactor)
            if let focused = focusedPane { requestFocus(to: focused) }

        case .gotoWorkspace1, .gotoWorkspace2, .gotoWorkspace3, .gotoWorkspace4, .gotoWorkspace5,
             .gotoWorkspace6, .gotoWorkspace7, .gotoWorkspace8, .gotoWorkspace9, .gotoWorkspace10:
            if let i = action.workspaceIndex { switchWorkspace(i) }
        case .moveToWorkspace1, .moveToWorkspace2, .moveToWorkspace3, .moveToWorkspace4, .moveToWorkspace5,
             .moveToWorkspace6, .moveToWorkspace7, .moveToWorkspace8, .moveToWorkspace9, .moveToWorkspace10:
            if let i = action.workspaceIndex { moveFocusedPane(to: i) }
        case .toggleBar:
            model.barVisible.toggle()

        case .themePicker:
            openPanel(.themes, selection: themeManager.themes.firstIndex(of: themeManager.current) ?? 0)
        case .backgroundMenu:
            if model.activePanel == .backgrounds {
                themeManager.nextBackground()
                model.panelSelection = themeManager.backgroundIndex
            } else {
                openPanel(.backgrounds, selection: themeManager.backgroundIndex)
            }
        case .toggleOpacity:
            themeManager.toggleOpacity()
        case .toggleGaps:
            themeManager.toggleGaps()

        case .keybindingHelp:
            openPanel(.keybindings)
        case .mainMenu:
            openPanel(.menu)
        case .scratchpad:
            toggleScratchpad()
        case .toggleFullscreen:
            toggleSimpleFullscreen()
        case .openSettings:
            openSettingsFile()
        case .exitFullscreen:
            // Only leaves fullscreen (Ctrl+Cmd+F is itself the toggle; Cmd+Esc is the dedicated
            // exit).
            if savedFrame != nil { toggleSimpleFullscreen() }
        case .toggleFloat:
            toggleFloat()
        }
    }

    // MARK: Visible columns per screen (ultra-wide display support)

    /// Set the visible column count and re-lay every scrolling workspace to the new factor
    func setVisibleColumns(_ n: Int, persist: Bool = true) {
        let clamped = min(max(n, 1), 6)
        guard clamped != visibleColumns || !model.layoutsMatch(factor: columnFactor) else {
            visibleColumns = clamped
            return
        }
        visibleColumns = clamped
        if persist {
            UserDefaults.standard.set(clamped, forKey: "quickterm.visibleColumns")
        }
        model.visibleColumnsDisplay = clamped
        let factor = columnFactor
        for i in model.layouts.indices {
            if case .scrolling(let strip) = model.layouts[i] {
                model.layouts[i] = .scrolling(strip.equalized(to: factor))
            }
        }
    }

    /// The main menu cycles 2 -> 3 -> 4 -> 2
    func cycleVisibleColumns() {
        let next = visibleColumns >= 4 ? 2 : visibleColumns + 1
        setVisibleColumns(next)
    }

    // MARK: Floating panes (spec v7: Cmd+T, Cmd+drag to move, Cmd+right-drag to resize)

    func toggleFloat(_ target: PaneView? = nil) {
        flushPendingCloses()
        // An explicit target may have just been removed by the flush above.
        guard let focused = target ?? focusedPane,
              paneList.contains(focused) else { return }
        if let idx = model.floating.firstIndex(where: { $0.pane === focused }) {
            // Put it back into the tiling: scrolling = a new column right of the last one,
            // dwindle = the regular insert.
            let fp = model.floating.remove(at: idx)
            switch model.layout {
            case .scrolling(let strip):
                model.layout = .scrolling(strip.insertingColumnRight(
                    of: strip.paneList.last, pane: fp.pane, widthFactor: columnFactor))
            case .dwindle(let tree):
                if tree.isEmpty {
                    model.layout = .dwindle(SplitTree(view: fp.pane))
                } else if let anchor = tree.root?.leaves().first,
                          let t = try? tree.inserting(
                            view: fp.pane, at: anchor,
                            direction: tree.dwindleDirection(for: anchor, in: dwindleLayoutSize)) {
                    model.layout = .dwindle(t)
                }
            }
            requestFocus(to: fp.pane)
        } else {
            // Float it up, Omarchy-style togglefloating: a fixed size, centered (width = the
            // default column width x 0.75, height = 45% of the content area).
            let rect = FloatingPane.defaultRect(columnFactor: columnFactor)
            removeFromActiveLayout(focused)
            model.floating.append(FloatingPane(pane: focused, rect: rect).clamped())
            requestFocus(to: focused)
        }
    }

    /// The size of the dwindle layout area (contentView minus the status bar at the top); its
    /// aspect ratio is what decides the split direction.
    /// The control plane needs it too when inserting a pane into an inactive workspace - both
    /// places have to use the same geometry.
    var dwindleLayoutSize: CGSize? {
        guard let content = window?.contentView else { return nil }
        let barH: CGFloat = model.barVisible ? StatusBarView.height : 0
        return CGSize(width: content.bounds.width, height: content.bounds.height - barH)
    }

    /// **The area the split tree / strip is actually laid out in** (in points) =
    /// `dwindleLayoutSize` minus RootView's outer ring of pane-gap padding (the
    /// `.padding(theme.paneGap)` in `RootView.content`).
    ///
    /// `window.contentLayoutRect` cannot stand in for it: that is the "minus the titlebar"
    /// rectangle, while RootView uses `.ignoresSafeArea(.container, edges: .top)` and lays out from
    /// the very top edge of contentView - so horizontally it always counts one ring of padding too
    /// many, and vertically the error even flips sign with `app set bar off`.
    /// Reported sizes (`size.points`), the `--points` conversion, the minimum-size clamp,
    /// Cmd+right-drag and the `resize-*` shortcuts all stand on this one basis: **with exactly one
    /// definition, the command line can never reach a place the mouse cannot**.
    ///
    /// Note that this is the pane's **slot**: inside each pane there is another ring of PaneChrome
    /// pane-gap padding plus the terminal's pane-padding, so a terminal's canvas is smaller than
    /// its slot (`size.cols/rows` is measured by the engine, never derived from this).
    var workspaceLayoutSize: CGSize? {
        guard let base = dwindleLayoutSize else { return nil }
        let inset = 2 * (themeManager.gapsEnabled ? themeManager.paneGap : 0)
        let size = CGSize(width: base.width - inset, height: base.height - inset)
        guard size.width > 1, size.height > 1 else { return nil }
        return size
    }

    /// Hover occlusion test (called from SurfaceView's mouseEntered/mouseMoved; spec v7 revision).
    /// It works on model geometry: a floating pane with a higher z, the Scratchpad, and a panel's
    /// dimming layer all count as occluding.
    override func surfaceIsOccluded(_ pane: PaneView,
                                    at locationInWindow: NSPoint) -> Bool {
        if model.activePanel != nil { return true }  // A panel's dimming layer is above everything
        if model.closingPanes.contains(pane.id) { return true }  // Mid-fade: hover cannot focus
        if model.scratchpadVisible { return model.scratchpadSurface !== pane }
        guard !model.floating.isEmpty,
              let point = normalizedContentPoint(locationInWindow) else { return false }
        return HoverOcclusion.isOccluded(
            paneFloatIndex: model.floating.firstIndex { $0.pane === pane },
            floatingRects: model.floating.map(\.rect),
            at: point)
    }

    /// Window coordinates to normalized top-left content coordinates (the content area is
    /// contentView minus the status bar at the top, which is the same coordinate system RootView's
    /// floating-layer GeometryReader uses).
    /// Note that contentView is an NSHostingView, which is flipped, so the result of convert is
    /// already top-left based; the isFlipped branch is defensive, so that swapping the host view
    /// out does not silently mirror everything.
    func normalizedContentPoint(_ locationInWindow: NSPoint) -> CGPoint? {
        guard let content = window?.contentView else { return nil }
        let barH: CGFloat = model.barVisible ? StatusBarView.height : 0
        let W = content.bounds.width
        let H = content.bounds.height - barH
        guard W > 0, H > 0 else { return nil }
        let p = content.convert(locationInWindow, from: nil)
        let yTop = content.isFlipped ? p.y : content.bounds.height - p.y
        return CGPoint(x: p.x / W, y: (yTop - barH) / H)
    }

    private func floatingIndex(of pane: PaneView?) -> Int? {
        guard let pane else { return nil }
        return model.floating.firstIndex { $0.pane === pane }
    }

    /// Hit testing for a Cmd+drag or Cmd-hover: it uses the floating pane's rectangle (padding and
    /// edge band included, walked top-down) rather than an NSView hit test - the edge band lies
    /// inside PaneChrome's padding, where an NSView hit test cannot reach it.
    /// On Cmd+left-down: a hit on a floating pane opens a session (the middle moves it and raises
    /// it, the edges and corners resize it). Returns true when the event has been taken over.
    @discardableResult
    func beginFloatingDrag(with event: NSEvent) -> Bool {
        guard let hit = floatingDragHit(event) else { return false }
        let idx = hit.edges.isMove ? raiseFloating(at: hit.index) : hit.index
        floatingDrag = FloatingDragSession(pane: model.floating[idx].pane, edges: hit.edges, down: event)
        if hit.edges.isMove { NSCursor.closedHand.set(); floatingCursorActive = true }
        return true
    }

    /// A drag or release inside a session. true = the event was consumed, false = pass it through,
    /// nil = it has nothing to do with the session.
    /// Coming up without ever passing the threshold means it was a plain click: both the down and
    /// the up are handed to the pane's keyboard focus view (a terminal gets engine PRESS/RELEASE,
    /// which is what makes Cmd+clicking a link fire open_url; a browser gets the WKWebView).
    func floatingSessionEvent(_ event: NSEvent) -> Bool? {
        guard let drag = floatingDrag else { return nil }
        switch event.type {
        case .leftMouseDragged:
            // The pane has left the floating layer (Cmd+T, a workspace switch or a move while the
            // button was held): the session is void.
            guard let pane = drag.pane, let index = model.floating.firstIndex(where: { $0.pane === pane }),
                  !model.closingPanes.contains(pane.id) else {
                floatingDrag = nil
                resetFloatingCursor()
                return true
            }
            // The movement before the threshold must not be lost: the event that crosses it
            // applies the whole accumulated displacement from the mouse-down point at once (deltaY
            // is positive downwards, while window coordinates are positive upwards).
            var dx = event.deltaX, dy = event.deltaY
            if !drag.moved {
                dx = event.locationInWindow.x - drag.down.locationInWindow.x
                dy = drag.down.locationInWindow.y - event.locationInWindow.y
                guard hypot(dx, dy) >= FloatingDragSession.threshold else { return true }
                floatingDrag?.moved = true
            }
            if drag.edges.isMove {
                moveFloating(at: index, dx: dx, dy: dy)
            } else {
                resizeFloating(at: index, edges: drag.edges, dx: dx, dy: dy)
            }
            return true
        case .leftMouseUp:
            floatingDrag = nil
            if !drag.moved, let pane = drag.pane, model.floating.contains(where: { $0.pane === pane }),
               !model.closingPanes.contains(pane.id),
               let target = pane.clickTarget(atWindowPoint: drag.down.locationInWindow) {
                target.mouseDown(with: drag.down)
                target.mouseUp(with: event)
            }
            if event.modifierFlags.contains(.command) {
                let hit = floatingDragHit(event)
                updateFloatingCursor(for: hit?.edges, pane: hit.map { model.floating[$0.index].pane })
            } else {
                resetFloatingCursor()
            }
            return true
        default:
            return nil
        }
    }

    func floatingDragHit(_ event: NSEvent) -> (index: Int, edges: FloatingPane.DragEdges)? {
        floatingDragHit(atWindowPoint: event.locationInWindow)
    }

    func floatingDragHit(atWindowPoint point: NSPoint) -> (index: Int, edges: FloatingPane.DragEdges)? {
        // A panel's dimming layer and the scratchpad are above the floating layer (the same
        // occlusion order surfaceIsOccluded uses).
        guard model.activePanel == nil, !model.scratchpadVisible else { return nil }
        guard let p = normalizedContentPoint(point), let content = window?.contentView else { return nil }
        let barH: CGFloat = model.barVisible ? StatusBarView.height : 0
        let W = max(content.bounds.width, 1), H = max(content.bounds.height - barH, 1)
        for idx in model.floating.indices.reversed() {   // Last array entry is topmost
            let fp = model.floating[idx]
            // No dragging a pane that is fading out.
            guard !model.closingPanes.contains(fp.pane.id) else { continue }
            if let edges = FloatingPane.dragEdges(at: p, in: fp.rect,
                                                  bandX: Self.floatingEdgeBand / W,
                                                  bandY: Self.floatingEdgeBand / H) {
                return (idx, edges)
            }
        }
        return nil
    }

    /// The Cmd-hover cursor: nil means the pointer is not over a floating pane (reset it), an empty
    /// set means the middle (the grab cursor), anything else the resize cursor for that edge or
    /// corner.
    private func updateFloatingCursor(for edges: FloatingPane.DragEdges?, pane: PaneView? = nil) {
        guard let edges else { resetFloatingCursor(); return }
        let cursor: NSCursor
        if edges.isMove {
            // The terminal reports the pointer is over a link: Cmd+click will open it, so show the
            // link cursor rather than the grab cursor.
            cursor = (pane as? Ghostty.SurfaceView)?.pointerStyle == .link ? .pointingHand : .openHand
        } else {
            let position: NSCursor.FrameResizePosition = switch (edges.contains(.left), edges.contains(.right),
                                                                edges.contains(.top), edges.contains(.bottom)) {
            case (true, _, true, _): .topLeft
            case (_, true, true, _): .topRight
            case (true, _, _, true): .bottomLeft
            case (_, true, _, true): .bottomRight
            case (true, _, _, _): .left
            case (_, true, _, _): .right
            case (_, _, true, _): .top
            default: .bottom
            }
            cursor = .frameResize(position: position, directions: .all)
        }
        cursor.set()
        floatingCursorActive = true
    }

    private func resetFloatingCursor() {
        guard floatingCursorActive else { return }
        floatingCursorActive = false
        NSCursor.arrow.set()
        window?.resetCursorRects()   // Let the terminal and web views set their own cursor again
    }

    /// Cmd+left-drag on a floating pane (deltaY is positive downwards, which matches SwiftUI's
    /// positive y direction)
    private func moveFloating(at index: Int, dx: CGFloat, dy: CGFloat) {
        guard let content = window?.contentView, model.floating.indices.contains(index) else { return }
        // The vertical divisor is the same one the floating layer's geometry and resizing use.
        let barH: CGFloat = model.barVisible ? StatusBarView.height : 0
        var fp = model.floating[index]
        fp.rect.origin.x += dx / max(content.bounds.width, 1)
        fp.rect.origin.y += dy / max(content.bounds.height - barH, 1)
        model.floating[index] = fp.clamped()
    }

    /// Cmd+right-drag: resize from the bottom-right corner (Hyprland's semantics, from a mouse-down
    /// anywhere in the pane)
    private func resizeFloating(at index: Int, dx: CGFloat, dy: CGFloat) {
        resizeFloating(at: index, edges: [.right, .bottom], dx: dx, dy: dy)
    }

    /// Cmd+left-drag on an edge band or a corner: the dragged edge follows the pointer and the
    /// opposite edge stays put
    private func resizeFloating(at index: Int, edges: FloatingPane.DragEdges, dx: CGFloat, dy: CGFloat) {
        guard let content = window?.contentView, model.floating.indices.contains(index) else { return }
        let barH: CGFloat = model.barVisible ? StatusBarView.height : 0
        model.floating[index] = model.floating[index].resized(
            edges: edges,
            dx: dx / max(content.bounds.width, 1),
            dy: dy / max(content.bounds.height - barH, 1))
    }

    /// Raise to the top (last array entry = topmost)
    private func raiseFloating(at index: Int) -> Int {
        guard index != model.floating.count - 1 else { return index }
        let fp = model.floating.remove(at: index)
        model.floating.append(fp)
        return model.floating.count - 1
    }

    // MARK: Scratchpad (spec §4.1)

    private func toggleScratchpad() {
        if model.scratchpadVisible {
            model.scratchpadVisible = false
            if let focused = focusedPane { requestFocus(to: focused) }
            return
        }
        if model.scratchpadSurface == nil {
            model.scratchpadSurface = newSurface(inheritingFrom: focusedPane)
        }
        model.scratchpadVisible = true
        if let scratch = model.scratchpadSurface {
            requestFocus(to: scratch)
        }
    }

    // MARK: Non-native fullscreen (the simple kind, spec §5.1 Ctrl+Cmd+F)
    // Per window: each has its own savedFrame, and the process-level presentationOptions are
    // accounted for by AppSession (when A leaves fullscreen while B is still fullscreen the menu
    // bar must not come back; closing a fullscreen screen returns only the share it took).

    /// The frame this screen restores to when it leaves fullscreen (nil = not fullscreen)
    private(set) var savedFrame: NSRect?

    /// Whether this screen is in non-native fullscreen
    var isSimpleFullscreen: Bool { savedFrame != nil }

    func toggleSimpleFullscreen() {
        guard let window, let screen = window.screen ?? NSScreen.main else { return }
        if let frame = savedFrame {
            savedFrame = nil
            session.setSimpleFullscreen(false, for: self)
            window.setFrame(frame, display: true, animate: false)
        } else {
            savedFrame = window.frame
            session.setSimpleFullscreen(true, for: self)
            window.setFrame(screen.frame, display: true, animate: false)
        }
        session.sessionStore.scheduleSave()
    }

    /// Refit after a display hot-plug or a resolution change (spec v9 §3.5; `AppSession` calls it
    /// per screen after the debounce).
    /// If the target display is gone, use whichever display the window is on now - AppKit has
    /// already moved it - and a fullscreen window refills the new display.
    /// The layout is never touched because something failed to resolve: the position can make do,
    /// the content cannot be lost.
    func reflowForScreenChange() {
        guard !isClosed, let window, let screen = window.screen ?? NSScreen.main else { return }
        if isSimpleFullscreen {
            // The frame to restore on leaving fullscreen has to be constrained into the new
            // display as well, or leaving fullscreen lands off-screen.
            savedFrame = SessionStore.constrain(savedFrame ?? window.frame, into: screen.visibleFrame)
            if window.frame != screen.frame { window.setFrame(screen.frame, display: true) }
            return
        }
        let fitted = window.constrainFrameRect(
            SessionStore.constrain(window.frame, into: screen.visibleFrame), to: screen)
        if fitted != window.frame { window.setFrame(fitted, display: true) }
    }

    // MARK: Overlay panels (Walker style)

    func openPanel(_ panel: OverlayPanel, selection: Int = 0) {
        if panel == .keybindings {
            model.keybindingRows = keybindings.displayBindings()
        }
        model.activePanel = panel
        model.panelSelection = selection
    }

    private var panelItemCount: Int {
        switch model.activePanel {
        case .themes: themeManager.themes.count
        // The last entry in the backgrounds panel is "choose an image".
        case .backgrounds: themeManager.backgroundChoices.count + 1
        case .menu: MenuEntry.allCases.count
        case .keybindings, nil: 0
        }
    }

    /// The up/down step: the backgrounds panel is a grid (3 columns), so up and down move by a row;
    /// every other panel moves by 1.
    private var panelRowStep: Int {
        model.activePanel == .backgrounds ? OverlayPanelView.backgroundsColumns : 1
    }

    /// Keyboard navigation inside a panel; true means the event was consumed
    private func handlePanelKey(_ event: NSEvent) -> Bool {
        switch KeybindingMap.normalizedKey(for: event) {
        case "escape":
            model.activePanel = nil
            return true
        case "up":
            model.panelSelection = max(0, model.panelSelection - panelRowStep)
            return true
        case "down":
            model.panelSelection = min(max(0, panelItemCount - 1),
                                       model.panelSelection + panelRowStep)
            return true
        case "left" where model.activePanel == .backgrounds:
            model.panelSelection = max(0, model.panelSelection - 1)
            return true
        case "right" where model.activePanel == .backgrounds:
            model.panelSelection = min(max(0, panelItemCount - 1), model.panelSelection + 1)
            return true
        case "return":
            choosePanelItem(model.panelSelection)
            return true
        default:
            return false
        }
    }

    func choosePanelItem(_ index: Int) {
        switch model.activePanel {
        case .themes:
            if themeManager.themes.indices.contains(index) {
                themeManager.apply(themeManager.themes[index])
            }
            model.activePanel = nil
        case .backgrounds:
            model.activePanel = nil
            if index < themeManager.backgroundChoices.count {
                themeManager.selectBackground(index)
            } else {
                pickUserBackground()  // The last entry: the system file picker
            }
        case .menu:
            // Visible columns per screen: cycle and keep the menu open, so it can be pressed
            // repeatedly.
            if MenuEntry(rawValue: index) == .visibleColumns {
                cycleVisibleColumns()
                return
            }
            model.activePanel = nil
            switch MenuEntry(rawValue: index) {
            case .newTerminal: perform(.newTerminal)
            case .fileManager: perform(.fileManager)
            case .browser: perform(.newBrowser)
            case .themes: perform(.themePicker)
            case .backgrounds: perform(.backgroundMenu)
            case .toggleBar: perform(.toggleBar)
            case .toggleGaps: perform(.toggleGaps)
            case .toggleOpacity: perform(.toggleOpacity)
            case .keybindings: perform(.keybindingHelp)
            case .settings: openSettingsFile()
            case .about: NSApp.orderFrontStandardAboutPanel(nil)
            case .visibleColumns, nil: break  // visibleColumns was handled above
            }
        case .keybindings, nil:
            model.activePanel = nil
        }
    }

    /// Settings (Cmd+, or the menu): open QuickTerm's config.toml, writing the template first if it
    /// does not exist, and open ~/.config/ghostty/config alongside it when that exists (layer 2 of
    /// the config chain, which users edit often).
    /// Custom background: pick an image with NSOpenPanel, copy it into
    /// ~/.config/quickterm/backgrounds and select it.
    private func pickUserBackground() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.message = L("window.background.choose-image")
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.themeManager.addUserBackground(from: url)
        }
    }

    private func openSettingsFile() {
        let url = ConfigStore.configURL
        // Fill in the missing keys before opening, so the user sees the complete list.
        ConfigStore.ensureTemplateKeys()
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? ConfigStore.template.write(to: url, atomically: true, encoding: .utf8)
        }
        NSWorkspace.shared.open(url)
        let ghosttyConfig = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/ghostty/config")
        if FileManager.default.fileExists(atPath: ghosttyConfig.path) {
            NSWorkspace.shared.open(ghosttyConfig)
        }
    }

    // MARK: Workspaces (spec §5.2)

    func switchWorkspace(_ index: Int) {
        flushPendingCloses()
        model.appearingPane = nil
        guard index != model.activeIndex else { return }
        // A value-semantics switch: instant, no animation (faithful to Omarchy).
        model.switchTo(index)
        if let focused = focusedPane {
            requestFocus(to: focused)
        }
    }

    /// Move the focused pane to the target workspace and follow it (Cmd+Shift+number); the insert
    /// follows the target workspace's own layout.
    func moveFocusedPane(to index: Int) {
        guard model.layouts.indices.contains(index), index != model.activeIndex,
              let focused = focusedPane else { return }

        // A floating pane moves to the target workspace with its floating state intact.
        if let idx = model.floating.firstIndex(where: { $0.pane === focused }) {
            let fp = model.floating.remove(at: idx)
            model.floatings[index].append(fp)
            model.switchTo(index)
            requestFocus(to: focused)
            return
        }

        // Compute the destination first, so a failure leaves the source untouched.
        let newTarget: WorkspaceLayout
        switch model.layouts[index] {
        case .scrolling(let strip):
            newTarget = .scrolling(strip.isEmpty
                ? ScrollingStrip(pane: focused, widthFactor: columnFactor)
                : strip.insertingColumnRight(of: strip.paneList.last, pane: focused,
                                             widthFactor: columnFactor))
        case .dwindle(let tree):
            if tree.isEmpty {
                newTarget = .dwindle(SplitTree(view: focused))
            } else if let anchor = tree.root?.leaves().first,
                      let t = try? tree.inserting(
                        view: focused, at: anchor,
                        direction: tree.dwindleDirection(for: anchor, in: dwindleLayoutSize)) {
                newTarget = .dwindle(t)
            } else {
                return
            }
        }

        removeFromActiveLayout(focused)
        model.layouts[index] = newTarget
        model.switchTo(index)
        requestFocus(to: focused)
    }

    // MARK: Focus, swapping and resizing, dispatched per layout

    private func moveFocus(_ direction: ScrollingStrip.Direction) {
        guard let focused = focusedPane else { return }
        let target: PaneView?
        switch model.layout {
        case .dwindle(let tree):
            guard let node = tree.root?.node(view: focused) else { return }
            target = tree.focusTarget(for: .spatial(direction.spatial), from: node)
        case .scrolling(let strip):
            target = strip.focusTarget(from: focused, direction: direction)
        }
        if let target { requestFocus(to: target, from: focused) }
    }

    private func swapFocused(_ direction: ScrollingStrip.Direction) {
        guard let focused = focusedPane else { return }
        switch model.layout {
        case .dwindle(let tree):
            guard let node = tree.root?.node(view: focused),
                  let target = tree.focusTarget(for: .spatial(direction.spatial), from: node),
                  let swapped = try? tree.swapping(focused, target) else { return }
            model.layout = .dwindle(swapped)
        case .scrolling(let strip):
            model.layout = .scrolling(strip.swapping(focused, direction: direction))
        }
        requestFocus(to: focused)
    }

    private func resizeFocused(_ direction: ScrollingStrip.Direction, precise: Bool) {
        guard let focused = focusedPane else { return }
        switch model.layout {
        case .dwindle:
            // The same path as Cmd+right-drag and the control plane's `pane resize --dir`, only
            // the step size differs.
            controlResizeSplit(focused, workspace: model.activeIndex,
                               points: precise ? 10 : 100, direction: direction.spatial)
        case .scrolling(let strip):
            // Column width is horizontal only (spec §4.2-bis: up and down do nothing).
            switch direction {
            case .left:
                model.layout = .scrolling(strip.resizingWidth(of: focused, delta: -ScrollingStrip.widthStep))
            case .right:
                model.layout = .scrolling(strip.resizingWidth(of: focused, delta: ScrollingStrip.widthStep))
            case .up, .down:
                break
            }
        }
    }

    private func cycleFocus(next: Bool) {
        guard let focused = focusedPane else { return }
        let target: PaneView?
        switch model.layout {
        case .dwindle(let tree):
            guard let node = tree.root?.node(view: focused) else { return }
            target = tree.focusTarget(for: next ? .next : .previous, from: node)
        case .scrolling(let strip):
            target = strip.linearTarget(from: focused, next: next)
        }
        if let target { requestFocus(to: target, from: focused) }
    }

    // MARK: Surface lifecycle

    /// Construct a file manager pane **without inserting it into a layout**:
    /// `perform(.fileManager)` and the control plane's `pane new --kind file-manager` share this
    /// one implementation - the cwd file, the login shell wrapper and `closesOnChildExit` would
    /// inevitably drift apart if each site wrote its own.
    func makeFileManagerPane(startDirectory: String)
        -> (pane: Ghostty.SurfaceView, launch: FileManagerLaunch) {
        let cwdFile = NSTemporaryDirectory() + "quickterm-fm-" + UUID().uuidString
        let launch = FileManagerLaunch.plan(program: fileManagerCommand,
                                            startDirectory: startDirectory, cwdFile: cwdFile)
        let pane = newSurface(workingDirectory: startDirectory, command: launch.command,
                              environment: launch.environment)
        // yazi emits no OSC 7, so seed the start directory: Cmd+Return and a second file manager
        // both inherit it from here.
        pane.pwd = startDirectory
        // Quitting closes it - the engine does not close a surface that was given a command.
        pane.closesOnChildExit = true
        return (pane, launch)
    }

    /// Create a new surface, inheriting the source pane's current directory (spec §4.1)
    func newSurface(inheritingFrom source: PaneView?) -> Ghostty.SurfaceView {
        newSurface(workingDirectory: source?.workingDirectory)
    }

    /// Shorthand for when the focus is on a browser pane (used by the web-* actions)
    private var browserPane: BrowserPaneView? { focusedPane as? BrowserPaneView }

    /// Create a browser pane: insert it into the active layout and focus it (a page's target=_blank
    /// and window.open come through here too).
    @discardableResult
    override func openBrowserPane(url: URL, from: PaneView?) -> BrowserPaneView? {
        let pane = BrowserPaneView(url: url)
        applyBrowserTheme(pane)
        insertNewPane(pane, anchor: from)
        return pane
    }

    override func requestClosePane(_ pane: PaneView) {
        closePane(pane, confirmIfNeeded: false)
    }

    /// An http(s) link Cmd+clicked in a terminal: if the current workspace already has a browser
    /// pane, open a new tab in the most recently activated one; if not, open a new pane next to the
    /// terminal.
    /// Other schemes (mailto, ssh, file, ...) and link-opener = system are not taken over, and the
    /// engine hands them to the system default application.
    override func openLink(_ url: URL, from: PaneView?) -> Bool {
        guard linkOpener.lowercased() != "system",
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) else { return false }
        // A link clicked from the Scratchpad: dismiss the Scratchpad first, otherwise the browser
        // pane sits under its dimming layer and the focus is blocked by it.
        if let from, from === model.scratchpadSurface, model.scratchpadVisible { model.scratchpadVisible = false }
        if let browser = mostRecentBrowserPane() {
            // While another pane is zoomed the browser pane is not mounted (window == nil), so the
            // tab would be added somewhere invisible and focus could not be handed over.
            if browser.window == nil { clearZoom() }
            browser.openLink(url)
            requestFocus(to: browser, from: from)
        } else {
            openBrowserPane(url: url, from: from)   // insertNewPane clears the zoom itself
        }
        return true
    }

    /// Clear the current layout's zoom, if there is one
    func clearZoom() {
        switch model.layout {
        case .dwindle(let tree):
            if tree.zoomed != nil { model.layout = .dwindle(SplitTree(root: tree.root, zoomed: nil)) }
        case .scrolling(let strip):
            if strip.zoomedID != nil {
                var next = strip
                next.zoomedID = nil
                model.layout = .scrolling(next)
            }
        }
    }

    /// The most recently activated browser pane across every workspace, floating included, ignoring
    /// ones that are fading out - used by the extension host.
    func mostRecentBrowserPaneAnywhere() -> BrowserPaneView? {
        browserPanes.filter { !model.closingPanes.contains($0.id) }
            .max { $0.lastActivatedAt < $1.lastActivatedAt }
    }

    /// The most recently activated browser pane in the current workspace (tiled plus floating),
    /// ignoring ones that are fading out
    func mostRecentBrowserPane() -> BrowserPaneView? {
        paneList.compactMap { $0 as? BrowserPaneView }
            .filter { !model.closingPanes.contains($0.id) }
            .max { $0.lastActivatedAt < $1.lastActivatedAt }
    }

    /// The control plane has to apply this too when it creates a browser pane
    /// (`controlMakeBrowserPane`): skip it and the background color does not match the theme.
    func applyBrowserTheme(_ pane: BrowserPaneView) {
        pane.applyTheme(background: NSColor(themeManager.background), foreground: NSColor(themeManager.foreground))
    }

    /// Create a surface in a given directory, optionally with a command and extra environment. With
    /// a command the engine forces wait-after-command, so the caller has to handle the exit itself
    /// (see SurfaceView.closesOnChildExit).
    func newSurface(workingDirectory: String?, command: String? = nil,
                    environment: [String: String] = [:]) -> Ghostty.SurfaceView {
        var config = Ghostty.SurfaceConfiguration()
        config.workingDirectory = workingDirectory
        config.command = command
        // Control-plane bootstrap: QUICKTERM_SOCKET / PANE / SCREEN / WORKSPACE / TOKEN.
        // The uuid has to be settled before the injection - PANE is that very uuid, and `-t @self`
        // relies on it.
        let paneID = UUID()
        config.environmentVariables = ControlEnvironment.inject(
            into: environment, paneID: paneID,
            screen: screenIndex + 1, workspace: model.activeIndex + 1)
        return Ghostty.SurfaceView(ghostty.app!, baseConfig: config, uuid: paneID)
    }

    /// Insert a new pane into the active layout and focus it (scrolling: a new column right of the
    /// anchor; dwindle: a split by the anchor's spatial geometry plus the local entry animation).
    /// The anchor defaults to the focused pane; when a file manager exits and we "open a terminal
    /// in its place", the anchor is the pane that is about to close.
    /// Returns whether the pane really made it into the layout (false when the dwindle tree is
    /// non-empty but no usable anchor can be found, in which case the caller must not reference the
    /// pane any further).
    /// The control plane (`Sources/Control`) goes through this too: reimplementing its invariants
    /// (the column width factor, dwindle's spatial geometry, the local entry animation, the focus
    /// handover) would inevitably introduce bugs, which is why this was widened from private to
    /// internal.
    @discardableResult
    func insertNewPane(_ pane: PaneView, anchor: PaneView? = nil) -> Bool {
        let anchor = anchor ?? focusedPane ?? paneList.first
        switch model.layout {
        case .scrolling(let strip):
            // Insert a new column to the right of the focused one (the semantics of screenshot 3),
            // its width taken from "visible columns per screen".
            model.layout = .scrolling(strip.insertingColumnRight(
                of: anchor, pane: pane, widthFactor: columnFactor))
        case .dwindle(let tree):
            // The anchor is not in the tree (the focus is on a floating pane, say): fall back to
            // the tree's first leaf.
            let target = anchor.flatMap { tree.root?.node(view: $0) != nil ? $0 : nil } ?? tree.root?.leaves().first
            if tree.isEmpty {
                model.layout = .dwindle(SplitTree(view: pane))
            } else if let focused = target,
                      let t = try? tree.inserting(
                        view: pane, at: focused,
                        direction: tree.dwindleDirection(for: focused, in: dwindleLayoutSize)) {
                // The local animation (TerminalSplitTreeView reads appearingPane): the original
                // pane shrinks from full size down to its ratio while the new one fades in, with no
                // rebuild of the whole tree. A second press in quick succession (under 0.35s) does
                // not animate - an in-flight parent animation gets dropped when the subtree changes
                // identity, and the result jumps. The marker is cleared when the animation ends.
                let now = Date()
                let animate = lastSplitAnimationAt.map { now.timeIntervalSince($0) > 0.35 } ?? true
                model.appearingPane = animate ? pane.id : nil
                if animate { lastSplitAnimationAt = now }
                model.layout = .dwindle(t)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    if self?.model.appearingPane == pane.id { self?.model.appearingPane = nil }
                }
            } else {
                return false
            }
        }
        requestFocus(to: pane, from: anchor)
        return true
    }

    /// A file manager pane has finished (its child process exited, or the engine closed it): if the
    /// directory changed, open a terminal next to it first and make that the focus successor, then
    /// close this pane (the close animation hands the space over to the new terminal).
    /// Returns false for a pane that was never registered.
    private func finishFileManager(_ view: PaneView) -> Bool {
        guard let session = fileManagerSessions.removeValue(forKey: ObjectIdentifier(view)) else { return false }
        var replacement: PaneView?
        if paneList.contains(view), let dir = FileManagerLaunch.nextDirectory(session: session) {
            let pane = newSurface(workingDirectory: dir)
            pane.pwd = dir
            if insertNewPane(pane, anchor: view) { replacement = pane }
        }
        FileManagerLaunch.cleanup(session)
        closePane(view, confirmIfNeeded: false, successor: replacement)
        return true
    }

    @objc private func ghosttyChildExited(_ notification: Foundation.Notification) {
        guard let view = notification.object as? PaneView else { return }
        // Multi-screen: registered with object: nil, so ignore panes owned by other windows.
        guard owns(view) else { return }
        guard paneList.contains(view) else {
            // It exited in an inactive workspace (a pkill or a crash after switching away): remove
            // it straight from whichever workspace it is in - this notification is already outside
            // the engine's callback stack.
            removeFromAnyWorkspace(view)   // Clears the session and the temp file internally
            return
        }
        if !finishFileManager(view) {
            closePane(view, confirmIfNeeded: false)
        }
    }

    /// For tests and extensions: register a file manager session (on exit, the session decides
    /// whether a terminal opens in its place).
    func registerFileManagerSession(_ view: PaneView, _ session: FileManagerLaunch.Session) {
        fileManagerSessions[ObjectIdentifier(view)] = session
    }

    /// **Hand the session over** without cleaning up the temp file: when a pane moves to another
    /// screen the session has to travel with it, otherwise its new owner does not know it is a file
    /// manager pane - the close confirmation comes back and quitting no longer opens a terminal in
    /// its place.
    /// `forgetFileManagerSession` means "close" (it deletes the cwd file), which is deliberately
    /// not reused here.
    func controlTakeFileManagerSession(_ view: PaneView) -> FileManagerLaunch.Session? {
        fileManagerSessions.removeValue(forKey: ObjectIdentifier(view))
    }

    private func forgetFileManagerSession(_ view: PaneView) {
        if let session = fileManagerSessions.removeValue(forKey: ObjectIdentifier(view)) {
            FileManagerLaunch.cleanup(session)
        }
    }

    /// Close a pane (scrolling drops an emptied column, dwindle reclaims the sibling); the window
    /// only closes once every workspace is empty.
    /// `successor`: a focus successor named by the caller (the new pane from "open a terminal in
    /// its place", for instance); with nil it is computed from the layout rules.
    func closePane(_ view: PaneView, confirmIfNeeded: Bool = true, animated: Bool = true,
                   successor: PaneView? = nil) {
        guard paneList.contains(view), !model.closingPanes.contains(view.id) else { return }
        // A file manager pane is just a viewer: even with a child process it does not raise the
        // "a process is still running" confirmation.
        if confirmIfNeeded, view.wantsConfirmClose, fileManagerSessions[ObjectIdentifier(view)] == nil {
            // The confirmation dialog is raised asynchronously: this method can be running inside
            // the engine's close_surface callback stack (a key binding into Zig's keyCallback), and
            // if the child process exits during the modal's nested run loop the callback fires a
            // second time and releases the surface synchronously, while the engine's stack still
            // touches it after returning - a use-after-free.
            // So let the engine's stack unwind first, then go modal. By the time the dialog appears
            // the pane may have been closed by another path, so revalidate.
            DispatchQueue.main.async { [weak self, weak view] in
                guard let self, let view, self.paneList.contains(view) else { return }
                let alert = NSAlert()
                alert.messageText = L("window.close-pane.title")
                alert.informativeText = L("window.close-pane.detail")
                alert.addButton(withTitle: L("window.button.close"))
                alert.addButton(withTitle: L("window.button.cancel"))
                guard alert.runModal() == .alertFirstButtonReturn else { return }
                guard self.paneList.contains(view), !self.model.closingPanes.contains(view.id) else { return }
                self.beginClose(view, animated: animated, successor: successor)
            }
            return
        }
        beginClose(view, animated: animated, successor: successor)
    }

    /// Closing happens in two stages, mirroring the create animation: first hand focus to the
    /// successor and mark the pane as fading (the view layer plays the collapse and fade), and only
    /// when the animation elapses does finishClose really remove it and release the surface.
    /// With the window invisible, or the animation disabled, it is removed immediately.
    private func beginClose(_ view: PaneView, animated: Bool, successor explicit: PaneView? = nil) {
        guard animated, closeAnimationEnabled, window?.isVisible == true else {
            removePane(view, successor: explicit)
            return
        }
        let successor = explicit ?? closeSuccessor(of: view)
        // Focus handover is asynchronous: when a close earlier in the same round has just pointed
        // the focus intent at this pane (pendingFocusTarget), `focused` is still false - we still
        // have to pass the focus further along, so the intent does not come to rest on a pane that
        // is fading out.
        if paneHoldsFocus(view) || pendingFocusTarget === view, let next = successor ?? firstLivePane(excluding: view) {
            requestFocus(to: next, from: view)
        }
        pendingCloses[ObjectIdentifier(view)] = PendingClose(view: view, successor: successor)
        model.closingPanes.insert(view.id)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.closeAnimationDuration + 0.02) {
            [weak self, weak view] in
            guard let self, let view else { return }
            self.finishClose(view)
        }
    }

    private func finishClose(_ view: PaneView) {
        guard let pending = pendingCloses.removeValue(forKey: ObjectIdentifier(view)) else { return }
        model.closingPanes.remove(view.id)
        guard paneList.contains(view) else { return }   // Already removed by another path
        let wasFocused = paneHoldsFocus(view)
        // Dropping the reference lets SurfaceView.deinit release the surface.
        removeFromActiveLayout(view)
        // Focus has usually been handed over in beginClose; if it is still on the closing pane (the
        // successor was itself closed in the meantime) catch it once more here.
        if wasFocused, let next = pending.successor.flatMap({ paneList.contains($0) ? $0 : nil })
            ?? firstLivePane(excluding: view) {
            requestFocus(to: next)
        }
    }

    /// Whether the pane holds focus: either the flag or the ground truth (while the address bar's
    /// field editor is first responder, the flag can lag behind the truth).
    private func paneHoldsFocus(_ view: PaneView) -> Bool {
        view.focused || (window.map { view.holdsFirstResponder(of: $0) } ?? false)
    }

    /// Fallback focus: the first pane that is not fading out
    private func firstLivePane(excluding view: PaneView) -> PaneView? {
        paneList.first { $0 !== view && !model.closingPanes.contains($0.id) }
    }

    /// Remove fading panes immediately: called before layout operations, workspace switches and
    /// archiving, so that all of them see the real layout.
    func flushPendingCloses() {
        for pending in Array(pendingCloses.values) { finishClose(pending.view) }
    }

    /// The pane that should take focus once `view` closes (scrolling: the left neighbour first;
    /// dwindle: the nearest leaf of the sibling subtree; floating: none).
    /// It is computed on a layout with "every other fading pane already removed": concurrent
    /// closes, such as several child processes exiting at once, do not go through `perform` and
    /// therefore do not flush, and focus must not be handed to a pane that is on its way out.
    private func closeSuccessor(of view: PaneView) -> PaneView? {
        let fading = paneList.filter { $0 !== view && model.closingPanes.contains($0.id) }
        switch model.layout {
        case .scrolling(var strip):
            for p in fading { strip = strip.removing(p) }
            return strip.focusTarget(from: view, direction: .left)
                ?? strip.focusTarget(from: view, direction: .right)
                ?? strip.focusTarget(from: view, direction: .up)
                ?? strip.focusTarget(from: view, direction: .down)
        case .dwindle(var tree):
            for p in fading { if let n = tree.root?.node(view: p) { tree = tree.removing(n) } }
            // Hyprland's dwindle semantics: focus goes to the nearest pane in the sibling subtree
            // that takes over the space (the next one, otherwise the previous one).
            return tree.closeSuccessor(of: view)
        }
    }

    /// Synchronous removal (the path without an animation)
    private func removePane(_ view: PaneView, successor explicit: PaneView? = nil) {
        let wasFocused = paneHoldsFocus(view)
        // Computed before the removal: afterwards the sibling relationship is gone.
        let successor = explicit ?? closeSuccessor(of: view)
        // Dropping the reference lets SurfaceView.deinit release the surface.
        removeFromActiveLayout(view)
        // The window stays after the last pane closes (RootView shows the "new terminal" hint) and
        // the app does not quit; quitting is only triggered by Cmd+Q or the menu (and
        // AppDelegate.applicationShouldTerminate decides whether to confirm).
        // paneList includes the floating layer: when the tiled layer empties out but floating panes
        // remain, focus still needs somewhere to go.
        if !paneList.isEmpty, wasFocused, let next = successor ?? paneList.first {
            requestFocus(to: next)
        }
    }

    /// Find the pane in any workspace and remove it (for the active workspace use
    /// removeFromActiveLayout, which also handles focus).
    /// **This means "close"**: it runs the per-pane teardown (a browser's paneWillClose, cleaning
    /// up the file manager session).
    /// For a move use `controlDetach(_:)`, which must not run a single one of those.
    func removeFromAnyWorkspace(_ view: PaneView) {
        ControlUndo.invalidate()
        forgetFileManagerSession(view)
        (view as? BrowserPaneView)?.paneWillClose()
        for i in model.layouts.indices {
            if let idx = model.floatings[i].firstIndex(where: { $0.pane === view }) {
                model.floatings[i].remove(at: idx)
                return
            }
            switch model.layouts[i] {
            case .dwindle(let tree):
                if let node = tree.root?.node(view: view) {
                    model.layouts[i] = .dwindle(tree.removing(node))
                    return
                }
            case .scrolling(let strip):
                if strip.paneList.contains(where: { $0 === view }) {
                    model.layouts[i] = .scrolling(strip.removing(view))
                    return
                }
            }
        }
    }

    /// As above, but only for the active workspace. **This also means "close"** and runs the
    /// per-pane teardown.
    func removeFromActiveLayout(_ view: PaneView) {
        ControlUndo.invalidate()
        forgetFileManagerSession(view)
        (view as? BrowserPaneView)?.paneWillClose()
        if let idx = model.floating.firstIndex(where: { $0.pane === view }) {
            model.floating.remove(at: idx)
            // The index is stale: it must not be reused when a pane is removed mid-drag.
            floatingDrag = nil
            resetFloatingCursor()
            if resizeTarget === view { resizeTarget = nil }
            return
        }
        switch model.layout {
        case .dwindle(let tree):
            guard let node = tree.root?.node(view: view) else { return }
            model.layout = .dwindle(tree.removing(node))
        case .scrolling(let strip):
            model.layout = .scrolling(strip.removing(view))
        }
    }

    @objc private func ghosttyDidEqualizeSplits(_ note: Foundation.Notification) {
        // Multi-screen: the engine sends the surface whose divider was double-clicked as the
        // object, so only the window owning it equalizes.
        guard let view = note.object as? PaneView, owns(view) else { return }
        perform(.equalize)
    }

    /// This pane belongs to this screen (inactive workspaces, the floating layer and the Scratchpad
    /// included)
    private func owns(_ view: PaneView) -> Bool {
        model.allPanes.contains { $0 === view }
    }

    @objc private func ghosttyDidCloseSurface(_ notification: Foundation.Notification) {
        guard let view = notification.object as? PaneView, owns(view) else { return }
        if view === model.scratchpadSurface {
            model.scratchpadVisible = false
            model.scratchpadSurface = nil
            return
        }
        guard paneList.contains(view) else {
            // A pane in an inactive workspace (its shell exited after switching away, say): remove
            // it straight from whatever workspace it is in, leaving focus alone.
            // Asynchronously: this method runs inside the engine's close_surface callback stack,
            // and a background pane is not held by SwiftUI, so dropping the reference synchronously
            // would immediately free a surface that is still on the engine's stack.
            DispatchQueue.main.async { [weak self] in self?.removeFromAnyWorkspace(view) }
            return
        }
        let processAlive = (notification.userInfo?["process_alive"] as? Bool) ?? false
        // File manager: the key-triggered engine close path is handled the same way.
        if finishFileManager(view) { return }
        closePane(view, confirmIfNeeded: processAlive)
    }

    // MARK: SwiftUI callbacks (dwindle dividers, drag and drop in both layouts)

    func handleSplitOperation(_ op: TerminalSplitOperation) {
        // A drop or a divider drag does not go through perform, so settle the real layout first.
        flushPendingCloses()
        guard case .dwindle(let tree) = model.layout else { return }
        switch op {
        case .resize(let resize):
            let resized = resize.node.resizing(to: resize.ratio)
            model.layout = .dwindle((try? tree.replacing(node: resize.node, with: resized)) ?? tree)
        case .equalize:
            perform(.equalize)
        case .drop(let drop):
            handleDwindleDrop(drop, tree: tree)
        }
    }

    private func handleDwindleDrop(_ drop: TerminalSplitOperation.Drop,
                                   tree: SplitTree<PaneView>) {
        // The tree algorithm lives in SplitTree+QuickTerm.dropping, and the control plane's
        // `pane move --where` uses the very same one - written twice, drag and drop and the command
        // line would eventually disagree about where a pane lands.
        guard let newTree = tree.dropping(drop.payload, on: drop.destination, zone: drop.zone) else { return }
        model.layout = .dwindle(newTree)
        requestFocus(to: drop.payload)
    }

    /// Drag and drop in the scrolling layout (spec §4.2-bis: the left and right edges insert a new
    /// column, the top and bottom edges merge into a stack, the center swaps).
    func scrollingDrop(payload: PaneView,
                       destination: PaneView,
                       zone: TerminalSplitDropZone) {
        flushPendingCloses()
        guard case .scrolling(let strip) = model.layout else { return }
        model.layout = .scrolling(strip.dropping(payload, on: destination, zone: zone))
        requestFocus(to: payload)
    }
}

/// The single conversion for direction words (the control plane's `pane resize --dir` uses it too,
/// rather than having its own copy).
extension ScrollingStrip.Direction {
    var spatial: SplitTree<PaneView>.Spatial.Direction {
        switch self {
        case .left: .left
        case .right: .right
        case .up: .up
        case .down: .down
        }
    }
}

// MARK: - Screen (window) lifecycle

extension MainWindowController: NSWindowDelegate {
    /// The close button and performClose: with live panes, ask once using the quit confirmation's
    /// rules.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        confirmCloseScreen()
    }

    /// Undo entries registered by the control plane have to be reachable from Edit > Undo and
    /// Cmd+Z: `undo:` travels up the responder chain to the window, and the window asks its
    /// delegate for an UndoManager. Without this, nothing registered in `AppDelegate.undoManager`
    /// could ever be triggered - which is exactly how it sat unused before Phase 1.
    /// Note that while the focus is on a terminal pane, EditMenuDelegate hands Cmd+Z back to the
    /// terminal (the kitty keyboard protocol). That is deliberate: Cmd+Z inside a terminal belongs
    /// to the terminal. Clicking the menu item undoes at any time.
    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        (NSApp.delegate as? AppDelegate)?.undoManager
    }

    /// Whenever the key window changes, recompute the process-level presentationOptions from
    /// AppSession's ledger: AppKit rewrites them on activation and window switches, and only the
    /// ledger knows whether any screen is fullscreen.
    func windowDidBecomeKey(_ notification: Foundation.Notification) {
        guard !isClosed else { return }
        // The control plane's "current screen": the only honest answer while the app is not in
        // the foreground.
        session.screens.recordKeyWindow(self)
        session.refreshPresentationOptions()
        // keyWindowID changed: the next launch has to focus the right screen.
        session.sessionStore.scheduleSave()
        // The "current window" as extensions see it is a cached value that only didFocusWindow
        // updates. With several screens, changing the key window without reporting it leaves
        // extensions sending their messages to a pane on another display - the icon looks like
        // clicking it does nothing.
        focusedBrowserPane?.makeCurrentForExtensions()
    }

    /// The window finished moving or resizing: archive it. Nothing is written mid-drag, since a
    /// live resize posts a notification every frame.
    func windowDidMove(_ notification: Foundation.Notification) {
        guard !isClosed else { return }
        session.sessionStore.scheduleSave()
    }

    func windowDidEndLiveResize(_ notification: Foundation.Notification) {
        guard !isClosed else { return }
        session.sessionStore.scheduleSave()
    }

    func windowWillClose(_ notification: Foundation.Notification) {
        teardown()
        // Drop the registry entry on the next runloop turn: this method can be running inside the
        // engine's callback stack, and releasing the last strong reference synchronously would
        // immediately free a surface that is still on that stack.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            (NSApp.delegate as? AppDelegate)?.forgetScreen(self)
        }
    }
}

// MARK: - Browser extension host (a pane is a window as far as extensions are concerned)

extension MainWindowController: BrowserExtensionHost {
    /// The browser panes across every workspace, the floating layer and the scratchpad included
    var browserPanes: [BrowserPaneView] { allPanes.compactMap { $0 as? BrowserPaneView } }

    /// The browser pane in this window that really holds first responder (the App-level aggregating
    /// host asks this first)
    var firstResponderBrowserPane: BrowserPaneView? {
        guard let window else { return nil }
        return browserPanes.first { $0.holdsFirstResponder(of: window) }
    }

    /// The browser pane holding first responder, falling back to the most recently activated one
    var focusedBrowserPane: BrowserPaneView? {
        firstResponderBrowserPane ?? mostRecentBrowserPaneAnywhere()
    }

    /// An extension's windows.create: open a new browser pane in the active workspace
    @discardableResult
    func openBrowserWindow(url: URL?) -> BrowserPaneView? {
        openBrowserPane(url: url ?? BrowserPaneView.settings.homeURL, from: focusedPane)
    }
}
