import AppKit
import GhosttyKit
import OSLog

/// The answer to the engine's three "ask the user first" clipboard requests.
///
/// libghostty hands three clipboard decisions to the app instead of making them itself: a paste
/// that carries a line break into a program that is not framing pastes (`clipboard-paste-
/// protection`), a program reading the clipboard through OSC 52 while `clipboard-read = ask`
/// (the default), and a program writing it while `clipboard-write = ask`. Each arrives as
/// `Notification.confirmClipboard`, posted by `Ghostty.App.confirmReadClipboard` /
/// `writeClipboard`; upstream answers it from `BaseTerminalController` with a sheet built from an
/// xib. QuickTerm has neither, so until this object existed the notification had no observer at
/// all: the paste vanished, the write was dropped, and an OSC 52 read never got its reply — the
/// program sat waiting on it for good, and the engine's request allocation leaked with it.
///
/// Two rules from the engine's contract shape everything here:
/// - A paste or read request **is completed exactly once, whatever the answer**: the engine keeps
///   an allocation alive until `ghostty_surface_complete_clipboard_request`, and a denied OSC 52
///   read is still answered — with an empty clipboard, which is what the program is waiting to
///   hear. A write never goes back to the engine: allowing it is the app putting the text on the
///   pasteboard, denying it is doing nothing.
/// - One question at a time, as upstream: a request that arrives while a sheet is up is denied
///   on the spot rather than queued, so a program spamming OSC 52 reads cannot stack sheets up
///   behind the user's back.
///
/// A sheet on the pane's window, never `runModal` (ControlConsent spells out why). Deny is the
/// default button of the two OSC 52 questions: a program asking for the clipboard on its own gets
/// the treatment an agent asking to run a command gets — allowing takes a click. The unsafe paste
/// is the user's own ⌘V, so there Paste stays on Return and Esc cancels.
@MainActor
final class ClipboardConfirmation: NSObject {
    enum Action {
        case allow, deny
    }

    struct Request {
        /// Weak: a pending question must not keep a closed pane alive, and a pane that is gone
        /// has taken the engine's request with it (see `answer`).
        weak var view: Ghostty.SurfaceView?
        let contents: String
        let kind: Ghostty.ClipboardRequest
        /// The engine's request, for `.paste` / `.osc_52_read`; `nil` for a write.
        let state: UnsafeMutableRawPointer?
    }

    static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "dev.danny.quickterm",
                               category: "clipboard-confirmation")

    /// Puts the question to the user and calls back with the answer. The default is the sheet in
    /// `presentSheet`; tests swap in an answer of their own.
    var present: (Request, @escaping (Action) -> Void) -> Void
    /// Hands the answer for a paste or read back to the engine, marked as confirmed. The default
    /// is the C API through `Ghostty.App.completeClipboardRequest`; tests swap in a spy.
    var complete: (ghostty_surface_t, String, UnsafeMutableRawPointer?) -> Void

    /// The question currently up, if any.
    private(set) var pending: Request?
    private let center: NotificationCenter

    init(center: NotificationCenter = .default) {
        self.center = center
        present = Self.presentSheet
        complete = { surface, data, state in
            Ghostty.App.completeClipboardRequest(surface, data: data, state: state, confirmed: true)
        }
        super.init()
        center.addObserver(self, selector: #selector(onConfirmClipboard(_:)),
                           name: Ghostty.Notification.confirmClipboard, object: nil)
    }

    deinit {
        center.removeObserver(self)
    }

    @objc private func onConfirmClipboard(_ notification: Foundation.Notification) {
        guard let view = notification.object as? Ghostty.SurfaceView,
              let info = notification.userInfo,
              let contents = info[Ghostty.Notification.ConfirmClipboardStrKey] as? String,
              let kind = info[Ghostty.Notification.ConfirmClipboardRequestKey] as? Ghostty.ClipboardRequest
        else { return }
        // Posted as an `UnsafeMutableRawPointer?` boxed in Any; absent altogether for a write.
        let state = info[Ghostty.Notification.ConfirmClipboardStateKey] as? UnsafeMutableRawPointer
        let request = Request(view: view, contents: contents, kind: kind, state: state)

        switch kind {
        case .paste, .osc_52_read:
            // Without the engine's request there is nothing that could be completed, so nothing
            // worth asking about either.
            guard state != nil else {
                Self.logger.error("clipboard request without its engine state; ignored")
                return
            }
        case .osc_52_write:
            break
        }

        // A question is still up (a stale one, whose pane has since closed, does not count).
        if let open = pending, open.view != nil {
            Self.logger.notice("clipboard request denied: another one is still being asked")
            answer(request, .deny)
            return
        }

        pending = request
        var answered = false
        present(request) { [weak self] action in
            guard !answered else { return }
            answered = true
            guard let self else { return }
            self.pending = nil
            self.answer(request, action)
        }
    }

    /// Carries the answer out. For a paste or read that means completing the engine's request —
    /// on Deny too, with nothing, so that the engine frees it and (for a read) the program gets
    /// its reply.
    private func answer(_ request: Request, _ action: Action) {
        switch request.kind {
        case .osc_52_write(let pasteboard):
            guard action == .allow else { return }
            let target = pasteboard ?? NSPasteboard.general
            target.declareTypes([.string], owner: nil)
            target.setString(request.contents, forType: .string)

        case .paste, .osc_52_read:
            guard let state = request.state else { return }
            // The pane closed while the question was up: its surface has been freed and the
            // engine's request with it, so there is nothing left to complete (the sheet's
            // completion must not reach into a freed surface).
            guard let view = request.view, let surface = view.surface else {
                Self.logger.notice("clipboard request outlived its pane; dropped")
                return
            }
            complete(surface, action == .allow ? request.contents : "", state)
        }
    }

    // MARK: The sheet

    /// A pane that is not in a window (in a workspace that is not on screen, say) has nowhere to
    /// hang a sheet: its request is denied — answered, that is, not left hanging.
    static func presentSheet(_ request: Request, _ answer: @escaping (Action) -> Void) {
        guard let view = request.view, let window = view.window else {
            logger.notice("clipboard request from a pane without a window; denied")
            answer(.deny)
            return
        }
        let alert = makeAlert(request.kind, contents: request.contents)
        let allow = allowResponse(for: request.kind)

        // The terminal hides the pointer while typing, and a sheet the user cannot point at is no
        // question at all: bring it back for the sheet's lifetime, then hide it again as it was.
        let hidden = Cursor.unhideCompletely()
        // Nothing of ours was hiding it: one plain unhide, in case something else was (as
        // upstream does; there is no way to ask NSCursor).
        if hidden == 0 { _ = Cursor.unhide() }

        alert.beginSheetModal(for: window) { response in
            for _ in 0..<hidden { Cursor.hide() }
            answer(response == allow ? .allow : .deny)
        }
    }

    /// The button that grants the request: first for the paste (Paste, on Return), second for
    /// the OSC 52 questions (Allow, behind a click).
    static func allowResponse(for kind: Ghostty.ClipboardRequest) -> NSApplication.ModalResponse {
        switch kind {
        case .paste: return .alertFirstButtonReturn
        case .osc_52_read, .osc_52_write: return .alertSecondButtonReturn
        }
    }

    /// The text the question is about is shown in a scrollable, selectable area under a one-
    /// paragraph explanation, so a long paste does not balloon the sheet.
    static func makeAlert(_ kind: Ghostty.ClipboardRequest, contents: String) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        switch kind {
        case .paste:
            alert.messageText = L("terminal.clipboard.paste.title")
            alert.setScrollableBody(contents, intro: L("terminal.clipboard.paste.detail"), minLines: 4)
            alert.addButton(withTitle: L("terminal.clipboard.button.paste"))  // first = default = Return
            alert.addButton(withTitle: L("window.button.cancel"))
            alert.buttons.first?.keyEquivalent = "\r"
            alert.buttons.last?.keyEquivalent = "\u{1b}"

        case .osc_52_read:
            alert.messageText = L("terminal.clipboard.read.title")
            alert.setScrollableBody(contents, intro: L("terminal.clipboard.read.detail"), minLines: 4)
            addDenyAllow(to: alert)

        case .osc_52_write:
            alert.messageText = L("terminal.clipboard.write.title")
            alert.setScrollableBody(contents, intro: L("terminal.clipboard.write.detail"), minLines: 4)
            addDenyAllow(to: alert)
        }
        return alert
    }

    /// Same shape as the control-plane consent alert, for the same reason: a stray Return must
    /// not grant anything, so Deny is the default and Allow has no key at all (NSAlert would
    /// otherwise put Esc on the last button).
    private static func addDenyAllow(to alert: NSAlert) {
        alert.addButton(withTitle: L("consent.alert.button.deny"))
        alert.addButton(withTitle: L("consent.alert.button.allow"))
        alert.buttons.first?.keyEquivalent = "\r"
        alert.buttons.last?.keyEquivalent = ""
    }
}
