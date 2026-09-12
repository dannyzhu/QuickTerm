import Cocoa
import GhosttyKit

/// The fullscreen modes we support define how the fullscreen behaves.
enum FullscreenMode: String, Codable {
    case native
    case nonNative
    case nonNativeVisibleMenu
    case nonNativePaddedNotch

    /// Initializes the fullscreen style implementation for the mode. This will not toggle any
    /// fullscreen properties. This may fail if the window isn't configured properly for a given
    /// mode.
    func style(for window: NSWindow) -> FullscreenStyle? {
        switch self {
        case .native:
            return NativeFullscreen(window)

        case .nonNative:
            return NonNativeFullscreen(window)

        case  .nonNativeVisibleMenu:
            return NonNativeFullscreenVisibleMenu(window)

        case .nonNativePaddedNotch:
            return NonNativeFullscreenPaddedNotch(window)
        }
    }
}

/// Protocol that must be implemented by all fullscreen styles.
protocol FullscreenStyle {
    var delegate: FullscreenDelegate? { get set }
    var fullscreenMode: FullscreenMode { get }
    var isFullscreen: Bool { get }
    var supportsTabs: Bool { get }
    init?(_ window: NSWindow)
    func enter()
    func exit()
}

/// Delegate that can be implemented for fullscreen implementations.
protocol FullscreenDelegate: AnyObject {
    /// Called whenever the fullscreen state changed. You can call isFullscreen to see
    /// the current state.
    func fullscreenDidChange()
}

/// The base class for fullscreen implementations, cannot be used as a FullscreenStyle on its own.
class FullscreenBase {
    let window: NSWindow
    weak var delegate: FullscreenDelegate?

    required init?(_ window: NSWindow) {
        self.window = window

        // We want to trigger delegate methods on window native fullscreen
        // changes (didEnterFullScreenNotification, etc.) no matter what our
        // fullscreen style is.
        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(didEnterFullScreenNotification),
            name: NSWindow.didEnterFullScreenNotification,
            object: window)
        center.addObserver(
            self,
            selector: #selector(didExitFullScreenNotification),
            name: NSWindow.didExitFullScreenNotification,
            object: window)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func didEnterFullScreenNotification(_ notification: Notification) {
        NotificationCenter.default.post(name: .fullscreenDidEnter, object: self)
        delegate?.fullscreenDidChange()
    }

    @objc private func didExitFullScreenNotification(_ notification: Notification) {
        NotificationCenter.default.post(name: .fullscreenDidExit, object: self)
        delegate?.fullscreenDidChange()
    }
}

/// macOS native fullscreen. This is the typical behavior you get by pressing the green fullscreen
/// button on regular titlebars.
class NativeFullscreen: FullscreenBase, FullscreenStyle {
    var fullscreenMode: FullscreenMode { .native }
    var isFullscreen: Bool { window.styleMask.contains(.fullScreen) }
    var supportsTabs: Bool { true }

    required init?(_ window: NSWindow) {
        // TODO: There are many requirements for native fullscreen we should
        // check here such as the stylemask.
        super.init(window)
    }

    func enter() {
        guard !isFullscreen else { return }

        // The titlebar separator shows up erroneously in fullscreen if the tab bar
        // is made to appear and then disappear by opening and then closing a tab.
        // We get rid of the separator while in fullscreen to prevent this.
        window.titlebarSeparatorStyle = .none

        // Enter fullscreen
        window.toggleFullScreen(self)

        // Note: we don't call our delegate here because the base class
        // will always trigger the delegate on native fullscreen notifications
        // and we don't want to double notify.
    }

    func exit() {
        guard isFullscreen else { return }

        // Restore titlebar separator style. See enter for explanation.
        window.titlebarSeparatorStyle = .automatic

        window.toggleFullScreen(nil)

        // Note: we don't call our delegate here because the base class
        // will always trigger the delegate on native fullscreen notifications
        // and we don't want to double notify.
    }
}


// QuickTerm trim (M0): the NonNativeFullscreen family depends on the Ghostty app's
// TerminalWindow / CGSSpace / window-tab logic. M1 will re-port it against QuickTerm's own window
// classes. See docs/porting-notes.md.
class NonNativeFullscreen: NativeFullscreen {}
class NonNativeFullscreenVisibleMenu: NonNativeFullscreen {}
class NonNativeFullscreenPaddedNotch: NonNativeFullscreen {}

extension Notification.Name {
    static let fullscreenDidEnter = Notification.Name("com.mitchellh.fullscreenDidEnter")
    static let fullscreenDidExit = Notification.Name("com.mitchellh.fullscreenDidExit")
}
