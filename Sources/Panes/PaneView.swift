import AppKit
import Combine

/// Pane kind: used to tell archived panes apart and to dispatch the content view.
enum PaneKind: String, Codable {
    case terminal
    case browser
}

/// Polymorphic factory used by the layout containers (SplitTree / ScrollingStrip / FloatingPane)
/// when they code their leaves. The base class's `init(from:)` cannot construct a subclass, so the
/// base class dispatches on the `kind` stored in the archive to reach the concrete type; old
/// archives (v3 and earlier) carry no kind and are treated as terminals.
protocol PaneCodable {
    static func decodePane(from decoder: Decoder) throws -> Self
    func encodePane(to encoder: Encoder) throws
}

/// Base class for every pane: terminal (Ghostty.SurfaceView), browser (BrowserPaneView), and so on.
/// The layout tree, the scrolling strip, the floating layer, the focus model, drag and drop and the
/// archive all speak only this type; terminal semantics stay in the subclass (close confirmation,
/// working-directory inheritance, engine callbacks, live theme switching).
///
/// The truth about focus = the window's first responder is this pane **or one of its descendants**
/// (a browser pane's FR is the WKWebView inside it). The `focused` flag is driven only by
/// focusDidChange (become/resign, the hosted view's callbacks, the controller's reconciliation).
class PaneView: NSView, ObservableObject, Identifiable, PaneCodable {
    let id: UUID

    /// Subclasses must override this.
    class var kind: PaneKind { fatalError("PaneView subclass must override kind") }
    var kind: PaneKind { type(of: self).kind }

    init(id: UUID = UUID(), frame: NSRect) {
        self.id = id
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: - Subclass interface

    /// Title used by the status bar and the cheat sheet.
    var paneTitle: String { "" }
    /// Title drawn onto the pane's border: **only a title that was set explicitly** counts (rename
    /// from the context menu, or `pane set --title` on the control plane). The base class always
    /// returns nil: a browser pane's title comes from the web page, nobody named it, so it does not
    /// go on the border. This hook exists so that `PaneChrome` does not have to reach into
    /// SurfaceView's internal state.
    var customTitle: String? { nil }
    /// Directory a newly created terminal inherits (terminal = the pwd from OSC 7; browser = nil).
    var workingDirectory: String? { nil }
    /// Whether closing needs a confirmation (terminal: a child process is still running).
    var wantsConfirmClose: Bool { false }
    /// The view keyboard focus actually lands on (terminal = self; browser = the WKWebView).
    var focusTarget: NSView { self }

    /// "Something that goes into the archive changed": a browser pane's URL or its set of tabs.
    /// The controller subscribes to this and schedules one debounced archive write, so that a crash
    /// or a force quit still restores the last page that was open. A terminal pane's cwd does not
    /// come through here: the controller observes `SurfaceView.$pwd` (OSC 7) directly.
    let archiveDidChange = PassthroughSubject<Void, Never>()

    /// Target for when the Cmd+drag source overlay or a floating session hands a plain click back to
    /// the pane: the view under the pointer has to be the focus view or a descendant of it (terminal =
    /// the surface, browser = the web page), otherwise nil. On an AppKit control such as the browser
    /// toolbar we must not call mouseDown directly: NSControl enters a tracking loop waiting for the
    /// mouse-up, and the real mouse-up has already gone by.
    func clickTarget(atWindowPoint point: NSPoint) -> NSView? {
        guard let superview else { return nil }
        let focus = focusTarget
        guard let hit = hitTest(superview.convert(point, from: nil)),
              hit === focus || hit.isDescendant(of: focus) else { return nil }
        return focus
    }

    // MARK: - Focus

    /// Whether this pane holds keyboard focus (observed by the PaneChrome border and others). Not
    /// @Published: objectWillChange is sent by hand when it changes.
    private(set) var focused = false

    /// Focus changed. A subclass that overrides this calls super first, then does its engine sync.
    func focusDidChange(_ focused: Bool) {
        guard self.focused != focused else { return }
        objectWillChange.send()
        self.focused = focused
        // The truth about focus flows out of this one place (the class comment says as much), so the
        // control plane's focus.changed hangs off this one place too: hanging it off requestFocus /
        // reconcileFocus would miss the keyboard and the mouse paths.
        ControlEventBus.noteChange()
    }

    /// The window's first responder is this pane or one of its descendants.
    func holdsFirstResponder(of window: NSWindow) -> Bool {
        guard let fr = window.firstResponder else { return false }
        if fr === self { return true }
        if let view = fr as? NSView { return view.isDescendant(of: self) }
        return false
    }

    /// The controller this pane belonged to the last time it was attached to a window. While SwiftUI
    /// rebuilds the hierarchy the pane is briefly detached from its window (window == nil; see the
    /// retry in moveFocus), and if an engine callback gives up at that moment because it "cannot find
    /// the controller", a Cmd+clicked link is thrown at the system default browser (the bug where
    /// clicking a link sometimes opened Safari).
    private weak var lastKnownController: BaseTerminalController?

    var controller: BaseTerminalController? {
        if let live = window?.windowController as? BaseTerminalController {
            lastKnownController = live
            return live
        }
        // Fallback while detached from the window; never resurrect a screen that is already torn down.
        guard let last = lastKnownController, last.acceptsPaneOperations else { return nil }
        return last
    }

    /// This pane (or its hosted view) became first responder: update the flag and notify the
    /// controller so it can maintain the single-focus invariant.
    func paneDidBecomeFirstResponder() {
        focusDidChange(true)
        controller?.paneDidBecomeFirstResponder(self)
    }

    func paneDidResignFirstResponder() {
        focusDidChange(false)
    }

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result { paneDidBecomeFirstResponder() }
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        // Sometimes called by hand (SplitView / moveFocus) to force focus to be given up.
        if result { paneDidResignFirstResponder() }
        return result
    }

    /// When the first-responder view is taken out of the window, AppKit silently resets the FR
    /// **without calling** resignFirstResponder (verified with a standalone probe), and `focused`
    /// stays stuck at true. This is guaranteed to happen whenever SwiftUI rebuilds the hierarchy
    /// (Cmd+L / Cmd+T / switching workspaces). So record "this pane was the FR when it detached",
    /// reclaim focus after it is remounted, and the flag lines up with the truth again.
    private var reclaimFocusOnAttach = false

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil, let window, holdsFirstResponder(of: window) {
            reclaimFocusOnAttach = true
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let owner = window?.windowController as? BaseTerminalController { lastKnownController = owner }
        guard reclaimFocusOnAttach, let window else { return }
        reclaimFocusOnAttach = false
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window === window, !self.holdsFirstResponder(of: window) else { return }
            // Only reclaim when the detach silently reset the FR to the window or nil; if some other
            // responder took focus meanwhile (a pane that was just created and focused by the
            // controller, say), never steal it, or the new pane loses its focus to the old one.
            if let fr = window.firstResponder, fr !== window { return }
            if let controller = self.controller, !controller.paneMayReclaimFocus(self) { return }
            window.makeFirstResponder(self.focusTarget)
        }
    }

    /// Hover tracking for non-terminal panes: the container installs its own tracking area.
    /// WKWebView's own tracking area is held by an internal observer object, and mouseMoved is
    /// delivered to that observer rather than to the view, so a subclass override never sees it; a
    /// tracking area, by contrast, is delivered to its owner by rectangle, no matter which subview is
    /// hit. The terminal pane (SurfaceView) manages its own tracking area and leaves this off.
    var installsHoverTracking: Bool { false }
    private var hoverTrackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        guard installsHoverTracking else { return }
        if let old = hoverTrackingArea { removeTrackingArea(old) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .inVisibleRect, .activeAlways],
            owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        guard installsHoverTracking else { return }
        // No hover response while covered by the floating layer or a mask (same as SurfaceView).
        if let controller, controller.surfaceIsOccluded(self, at: event.locationInWindow) { return }
        hoverFocusIfNeeded()
    }

    /// Hover-to-focus (spec §4.2): subclasses call this from mouseMoved, past the occlusion check.
    func hoverFocusIfNeeded() {
        guard let window, let controller,
              !controller.commandPaletteIsShowing,
              window.isKeyWindow,
              controller.focusFollowsMouse,
              !holdsFirstResponder(of: window),          // trust the real FR, not a stale `focused`
              controller.paneMayReclaimFocus(self) else { return }
        // That last condition: inserting a new pane makes the neighbours rebuild their tracking areas
        // and AppKit synthesizes one mouseMoved. With the mouse sitting over the old pane, hover would
        // snatch back the focus just handed to the new pane; so while the controller has a pending
        // focus intent, do not take it.
        PaneView.moveFocus(to: self)
    }

    /// Hand keyboard focus over (ported from Ghostty.moveFocus): if the target is not in a window yet,
    /// retry with exponential backoff for up to 0.5s; `from` gives focus up explicitly, because the
    /// engine-side resign callback sometimes never arrives.
    static func moveFocus(to: PaneView, from: PaneView? = nil, delay: TimeInterval? = nil) {
        let maxDelay: TimeInterval = 0.5
        guard (delay ?? 0) < maxDelay else { return }
        let nextDelay: TimeInterval = delay.map { $0 * 2 } ?? 0.05
        let work = DispatchWorkItem {
            guard let window = to.window else {
                moveFocus(to: to, from: from, delay: nextDelay)
                return
            }
            // A deliberate difference from Ghostty.moveFocus: do not resign when from === to (a cycle
            // that wrapped around to itself). Otherwise AppKit short-circuits makeFirstResponder and
            // never calls become back, leaving the pane as FR with focused=false.
            // Only resign by hand for a pane that is its own FR (a terminal); a hosted view
            // (WKWebView) must not be sent resignFirstResponder outside the makeFirstResponder flow
            // (it trips a WebKit internal assertion), so let the makeFirstResponder below give it up
            // through the normal path.
            if let from, from !== to, from.focusTarget === from {
                _ = from.resignFirstResponder()
            }
            window.makeFirstResponder(to.focusTarget)
        }
        if let delay {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }

    // MARK: - Archiving (PaneCodable)

    private enum KindKey: String, CodingKey { case kind }

    static func decodePane(from decoder: Decoder) throws -> Self {
        let kind = try decoder.container(keyedBy: KindKey.self)
            // a v3 archive carries no kind, which means terminal
            .decodeIfPresent(PaneKind.self, forKey: .kind) ?? .terminal
        let pane: PaneView
        switch kind {
        case .terminal: pane = try Ghostty.SurfaceView(from: decoder)
        case .browser: pane = try BrowserPaneView.decode(from: decoder)
        }
        guard let typed = pane as? Self else {
            throw DecodingError.typeMismatch(Self.self, .init(
                codingPath: decoder.codingPath, debugDescription: "pane kind \(kind) is not \(Self.self)"))
        }
        return typed
    }

    func encodePane(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: KindKey.self)
        try container.encode(kind, forKey: .kind)
        try encodePayload(to: encoder)
    }

    /// Subclasses encode their own fields into this same encoder, as siblings of `kind`.
    func encodePayload(to encoder: Encoder) throws {}
}

extension PaneView {
    /// Snapshot image of the pane, used as the drag preview.
    var asImage: NSImage? {
        guard let bitmapRep = bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        cacheDisplay(in: bounds, to: bitmapRep)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(bitmapRep)
        return image
    }
}
