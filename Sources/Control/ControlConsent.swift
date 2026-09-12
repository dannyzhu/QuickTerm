import AppKit
import OSLog

/// The confirmation gate for destructive / sensitive commands.
///
/// Three deliberate design choices:
/// 1. **Cached once per (peer pid, command class)** (kitty's approach): agents send commands in
///    batches, so asking about every single one amounts to asking about none;
/// 2. **A sheet, never `runModal()`**: `runModal` spins a nested run loop that wedges the main
///    thread and the whole control server along with it, and QuickTerm already has several
///    `runModal` sites of its own (the quit confirmation, the close-screen confirmation, the
///    browser's JS dialogs). Blocks queued with `DispatchQueue.main.async` during a nested run
///    loop **execute behind the user's dialog** — so this code neither creates a new nested run
///    loop nor proceeds while another modal is up; it refuses outright (busy);
/// 3. **The alert is anchored on one of the app's own windows, not on the requesting pane**
///    (Zellij has a documented hole here: a background plugin has no pane, so it can never be
///    granted anything). A call made from Terminal.app or from a background job can therefore
///    be approved just the same.
///
/// ⚠️ There is no branch here that skips the confirmation because the caller carried the right
/// QUICKTERM_TOKEN, and there must never be one: the token is proof of origin, not a permission
/// boundary (see ControlEnvironment). The process name shown in the alert comes from the kernel
/// (LOCAL_PEERPID), so even if the token has been copied, what the user reads is still the real
/// `node (pid 4821)`.
@MainActor
final class ControlConsent {
    enum Decision: String {
        case allow, deny, timeout
    }

    struct Request {
        var peerName: String
        var peerPID: pid_t
        /// Command class (destructive / sensitive)
        var cls: ControlCommandClass
        /// What this command is about to do, in plain language
        var summary: String
        /// The origin pane's handle, when there is one. **The caller reports this itself** and
        /// the server cannot verify a word of it — hence the wording "claims to come from", and
        /// hence it is only ever set for a caller that carried this launch's token (see
        /// `ControlCommandRunner.originHandle(for:)`).
        /// The kernel-supplied `peerName` / `peerPID` are the only trustworthy identity in this
        /// alert
        var originPane: String?
        /// The origin pane has been **proven** (`QUICKTERM_PANE_TOKEN` matches the
        /// self-reported `origin.pane`). Wording only: proven says "from pane t3" outright,
        /// unproven still says "claims to come from"
        var originVerified: Bool = false
        /// The request carried the token generated for this launch (wording only; it never
        /// decides whether to prompt)
        var tokenPresent: Bool
        /// Whether this approval may be cached under (pid, class). **Always false for
        /// `input send-text`**: closing a pane is something the user watches happen, so caching
        /// one approval is defensible, whereas text injected into somebody else's tty can be
        /// completely different content every single time — "approved once" is no consent at
        /// all for the next one
        var cacheable: Bool = true
        /// **Which** key this approval is cached under. nil = by command class (destructive
        /// commands are equivalent to one another: what the user approved is "this process may
        /// close things"). Sensitive commands get one key per command — approving "read t7's
        /// screen" is emphatically not approving "type into t7" along with it; those are two
        /// different grants
        var scope: String?
        /// A preview of the payload, **drawn for the user and for nobody else** (only
        /// `input send-text` has one; already sanitized and truncated).
        ///
        /// It has to be in the alert, because it is the only thing separating this confirmation
        /// from the last one: two calls with an identical command name and target pane can be
        /// `echo hi` one time and `curl … | sh` the next. Without it the user reads the same two
        /// sentences both times, and that is not informed consent.
        ///
        /// ⚠️ It **never goes into `summary`**: `summary` is written to the unified log with
        /// `privacy: .public`, and "the payload enters no record that is kept" is the same line
        /// the activity log holds on its own side
        var payload: String?
        /// The **full** character count of the payload (the preview is truncated, and the user
        /// needs to know how much more there is)
        var payloadLength: Int?
        /// A Return follows the payload — which is to say the shell **will actually run** it
        var payloadEnter: Bool = false
    }

    /// How long an unanswered prompt waits: on expiry it returns exit code 4, so the agent can
    /// tell the user to go and confirm in QuickTerm instead of sitting there waiting
    static let timeout: TimeInterval = 10

    private struct GrantKey: Hashable {
        var pid: pid_t
        var cls: ControlCommandClass
        /// See `Request.scope`
        var scope: String?
    }

    static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "dev.danny.quickterm",
                               category: "ControlConsent")

    private var grants: Set<GrantKey> = []
    /// Only one confirmation alert at a time: a second one is always busy (stacking up N sheets
    /// is what actually happens once an agent starts looping)
    private(set) var isPrompting = false

    /// The decision stub tests inject: the test host never puts up a real sheet.
    /// **Asynchronous in shape** (the answer is handed back to the test) rather than a plain
    /// return, because a real sheet is asynchronous: a test has to be able to **hold** the state
    /// "a confirmation is currently up" in order to verify that other commands are blocked while
    /// it is
    var decisionStub: ((Request, @escaping (Decision) -> Void) -> Void)?

    weak var screens: ScreenRegistry?

    init(screens: ScreenRegistry?) {
        self.screens = screens
    }

    func reset() {
        grants.removeAll()
        isPrompting = false
    }

    /// Already granted? **Always false when the pid could not be obtained (<= 0)**: otherwise
    /// every peer of unknown identity shares one GrantKey(0, …), and once the first of them is
    /// approved every one after it gets the grant for free — a single consent becomes a
    /// permanent back door
    func hasGrant(pid: pid_t, cls: ControlCommandClass, scope: String? = nil) -> Bool {
        guard pid > 0 else { return false }
        return grants.contains(GrantKey(pid: pid, cls: cls, scope: scope))
    }

    /// Same rule: cache only when there is a real pid
    private func grant(pid: pid_t, cls: ControlCommandClass, scope: String?) {
        guard pid > 0 else { return }
        grants.insert(GrantKey(pid: pid, cls: cls, scope: scope))
    }

    /// Is another modal up on the main thread (a sheet, or `NSAlert.runModal`'s nested run
    /// loop)? If so, destructive commands are refused outright — an agent must never get to
    /// close a pane while the user is staring at some other dialog
    var isModalBusy: Bool {
        if NSApp.modalWindow != nil { return true }
        if let screens {
            for controller in screens.controllers where controller.window?.attachedSheet != nil { return true }
        }
        return isPrompting
    }

    /// The alert itself. **"Deny" is the first button**, which makes it the default button, so
    /// Return lands on it.
    ///
    /// That is not a layout preference, it is the fix for an accident we measured: the default
    /// button used to be "Allow", and during a smoke test one Return that happened to land on
    /// the window (anyone can hit that by reflex) approved a destructive command outright. What
    /// the log was left with was `Control consent result: allow` — the user had not read the
    /// alert at all. A safety gate's default answer has to be no: allowing takes a **click**,
    /// denying can be Return or Esc.
    static func makeAlert(_ request: Request) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = L(request.cls == .destructive
            ? "consent.alert.title.destructive"
            : "consent.alert.title.sensitive")
        // One line = one whole sentence. **Never splice in a fragment** like ", claiming to
        // come from pane t3": word order differs between the two languages, so the smallest
        // translatable unit is a whole sentence — each of the three origins is its own key.
        let pid = String(request.peerPID)
        let who = request.originPane.map { pane in
            L(request.originVerified ? "consent.alert.request.from-pane"
                                     : "consent.alert.request.claims-pane",
              request.peerName, pid, pane, request.summary)
        } ?? L("consent.alert.request.plain", request.peerName, pid, request.summary)

        var paragraphs = [who]
        // The payload gets a paragraph of its own, and it spells out "Return = it will be
        // executed": `--enter` is the only line between "deliver the text" and "make it run",
        // and which of those two the user is approving has to be said in the alert
        if let text = request.payload {
            paragraphs.append(L("consent.alert.payload.header",
                                request.payloadLength ?? text.count, text))
            paragraphs.append(L(request.payloadEnter ? "consent.alert.payload.enter"
                                                     : "consent.alert.payload.no-enter"))
        }
        paragraphs.append(L(request.cacheable ? "consent.alert.scope.cacheable"
                                              : "consent.alert.scope.once"))
        paragraphs.append(L(request.tokenPresent ? "consent.alert.token.present"
                                                 : "consent.alert.token.absent"))
        alert.informativeText = paragraphs.joined(separator: "\n\n")
        alert.addButton(withTitle: L("consent.alert.button.deny"))    // first = default = Return
        alert.addButton(withTitle: L("consent.alert.button.allow"))
        // NSAlert makes the first button's key equivalent Return by default; pinned explicitly
        // here so that reordering the buttons later cannot make it drift silently. Esc is mapped
        // by NSAlert itself onto the last button, so "Allow" has to have its key equivalent
        // taken away again
        alert.buttons.first?.keyEquivalent = "\r"
        alert.buttons.last?.keyEquivalent = ""
        alert.alertStyle = .warning
        return alert
    }

    /// "Allow" is the second button (the first one is the default, "Deny")
    static let allowResponse = NSApplication.ModalResponse.alertSecondButtonReturn

    /// The decision. `completion` is always called exactly once, on the main thread
    func evaluate(_ request: Request, completion: @escaping (Decision) -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        if request.cacheable, hasGrant(pid: request.peerPID, cls: request.cls, scope: request.scope) {
            completion(.allow)
            return
        }
        if let stub = decisionStub {
            // Same lifecycle as a real sheet: isPrompting is true from the moment the question
            // goes out and only drops when the answer comes back — that is what lets a test
            // verify that mutation commands are all busy while a confirmation is up
            isPrompting = true
            var answered = false
            stub(request) { [weak self] decision in
                guard !answered else { return }
                answered = true
                self?.isPrompting = false
                if decision == .allow, request.cacheable {
                    self?.grant(pid: request.peerPID, cls: request.cls, scope: request.scope)
                }
                completion(decision)
            }
            return
        }
        // No stub in the test host means deny: never put a dialog up on a machine running tests
        guard !AppDelegate.isRunningTests else {
            completion(.deny)
            return
        }
        guard !isModalBusy else {
            completion(.timeout)   // the caller turns this into busy / confirmation-required
            return
        }
        guard let window = (screens?.key ?? screens?.primary)?.window else {
            completion(.deny)
            return
        }

        isPrompting = true
        Self.logger.notice("Control consent: \(request.peerName, privacy: .public)(pid \(request.peerPID)) requests \(request.cls.rawValue, privacy: .public) — \(request.summary, privacy: .public)")
        let alert = Self.makeAlert(request)

        var answered = false
        let finish: (Decision) -> Void = { [weak self] decision in
            guard !answered else { return }
            answered = true
            self?.isPrompting = false
            if decision == .allow, request.cacheable {
                self?.grant(pid: request.peerPID, cls: request.cls, scope: request.scope)
            }
            Self.logger.notice("Control consent result: \(decision.rawValue, privacy: .public) (pid \(request.peerPID))")
            completion(decision)
        }

        alert.beginSheetModal(for: window) { response in
            finish(response == Self.allowResponse ? .allow : .deny)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.timeout) { [weak window, weak alert] in
            guard !answered else { return }
            // **Settle on "timeout" first, then take the sheet down**: `endSheet` invokes the
            // completion above synchronously, so finish(.deny) would win the race and the agent
            // would be told the user denied this command (exit code 5) — when the user had in
            // fact said nothing at all. That reports to the agent a denial that never happened,
            // and it contradicts the "timeout → exit code 4" that describe and the docs both
            // nail down. The answered flag that finish sets makes the .deny callback right
            // after it a no-op
            finish(.timeout)
            if let window, let alert { window.endSheet(alert.window, returnCode: .cancel) }
        }
    }
}
