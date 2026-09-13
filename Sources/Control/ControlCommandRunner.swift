import AppKit

/// The body that executes control commands. **Always runs on the main thread** (every entry
/// point carries a `dispatchPrecondition`): `MainWindowController` has no `@MainActor`
/// annotation and the project is Swift 5.10, so writing a `@Published` from the socket callback
/// thread compiles perfectly cleanly and then crashes at runtime with "publishing changes from
/// background thread".
///
/// Serialization uses a **flag**, not a lock: `perform()` is reentrant (the engine callback
/// `ghosttyDidEqualizeSplits → perform(.equalize)`, the keyboard monitor and the menu items all
/// call it), and holding a lock across a main-thread hop would wedge the UI outright the first
/// time an engine callback came in.
@MainActor
final class ControlCommandRunner {
    struct Config {
        /// `[control] socket` (formerly `enabled`)
        var socket: Bool = true
        /// `[control] mcp`: applies only to the `quickterm mcp` process (see
        /// `ControlConfigGate`).
        /// **The socket side pays no attention to it**: every MCP call is an ordinary control
        /// request, "I am MCP" is something the caller says about itself, and the server cannot
        /// verify a word of it — using an unverifiable field as a gate only hands the user a
        /// false sense of security
        var mcp: Bool = true
        var mode: String = "ask"
        var exposeBrowser: String = "token"
        var sendText: Bool = false
        var captureText: Bool = false

        init() {}

        init(_ settings: ConfigStore.Settings) {
            socket = settings.controlSocket
            mcp = settings.controlMCP
            mode = settings.controlMode
            exposeBrowser = settings.controlExposeBrowser
            sendText = settings.controlSendText
            captureText = settings.controlCaptureText
        }

        /// Has the user explicitly switched this `sensitive` command on?
        /// **One switch per command**: there used to be a single `sendText` here, so "I want the
        /// agent to be able to read my screen" also switched on "the agent may type into my
        /// shell" — two completely different grants
        func allowsSensitive(_ command: String) -> Bool {
            switch command {
            case "input.send-text": sendText
            case "pane.capture-text": captureText
            default: false   // an unknown sensitive command stays off: a default can only be the safe side
            }
        }

        /// When the command is not switched on, tell the user where to switch it on
        func sensitiveHint(_ command: String) -> String {
            switch command {
            case "input.send-text": "Set send-text = true under [control] in ~/.config/quickterm/config.toml"
            case "pane.capture-text": "Set capture-text = true under [control] in ~/.config/quickterm/config.toml"
            default: "This command has no switch of its own under [control]"
            }
        }

        /// Listening or not = the strictest of three switches: `socket = false`, the old
        /// `enabled = false` (already folded into socket during parsing), and `mode = "off"` —
        /// any one of them means not listening
        var isListening: Bool { socket && mode != "off" }
        var allowsMutation: Bool { isListening && mode != "readonly" }
        /// **Written the other way round**: as long as a command can run at all, destructive /
        /// sensitive commands have to be confirmed.
        /// Writing this as `mode == "ask"` would mean that any other spelling of mode — "on" in
        /// the config file, an extra setting added later, even a slip of the shift key — silently
        /// switches the entire confirmation gate off.
        /// The gate may be bypassed only by an explicit off / readonly, never by a typo
        var promptsForDestructive: Bool { allowsMutation }
    }

    /// **The one** subject the confirmation gate approved. What the user read and what the knife
    /// lands on have to be the same thing: during the ten seconds the alert is up, other mutate
    /// commands (`focus-right` and the like, which need no confirmation) can move the focus, and
    /// then "close the focused pane" closes a different pane.
    ///
    /// From Phase 2 on the subject is not necessarily one pane: `workspace clear` pins "these
    /// panes in this workspace" (a changed set counts as changed), and `screen close` pins a
    /// whole screen
    struct PinnedSubject {
        var controller: MainWindowController
        var workspace: Int
        var pane: PaneView?
        var handle: String?
        /// For `workspace clear`: the set of panes in that workspace at confirmation time
        var paneIDs: Set<UUID>?
        /// For `spec apply`: **every** (screen, workspace) this will touch, each with the set of
        /// panes it held at the time. One `quickterm.screen/1` covers every workspace on a whole
        /// screen and `quickterm.session/1` covers every screen — pin only the one `-t` names and
        /// what the user approved is not the thing that is about to happen
        var scopes: [PinnedScope] = []
        /// The short form of the sentence in the alert (handed back to the caller when the
        /// subject drifts, so it knows what had been confirmed).
        /// **Written in English**: it goes verbatim into the body of the `busy` error, and the
        /// command-line side is English throughout
        var description: String
        /// The same subject in the **UI language**, for the consent alert only: that text is
        /// shown in QuickTerm's own window and never travels back over the socket, so it
        /// follows `[general] language` instead of staying English the way the CLI does.
        var consentText: String
    }

    /// One pinned workspace (an element of `PinnedSubject.scopes`)
    struct PinnedScope {
        var controller: MainWindowController
        var workspace: Int
        /// The panes in this workspace at the moment of confirmation (**fading ones excluded**:
        /// a flush happens between the confirmation and the knife going in)
        var paneIDs: Set<UUID>
    }

    let screens: ScreenRegistry
    let consent: ControlConsent
    var config = Config()
    /// The monotonic state counter. **`ControlEventBus` owns it**: from Phase 4 on every typed
    /// event advances it, so "the seq in the response" and "the seq in an event" are the same
    /// ruler by construction — an agent can take the seq a mutation returned straight into
    /// `events poll --since` and miss none of the events its own command produced
    var seq: Int { ControlEventBus.shared.seq }
    /// One command executes at a time. A modal's nested run loop drains the main queue behind
    /// the user's dialog, and a second command must never slip in while that happens
    private var isExecuting = false
    /// Per-origin rate limiting for mutations (the connection-level bucket cannot cover a CLI
    /// that opens a new connection for every command)
    var rateLimiter = ControlRateLimiter()
    /// The two global flags of the command currently running (`isExecuting` guarantees there is
    /// only ever one at a time)
    private(set) var currentFlags: (dryRun: Bool, failIfNoop: Bool) = (false, false)
    /// **Injectable**: is a modal blocking the main thread? Tests use it to pin "every mutation
    /// command is refused while a modal is up" as a structural test — putting up a real NSAlert
    /// would wedge the test host itself
    var modalBusyProbe: () -> Bool = { NSApp.modalWindow != nil }

    /// A mutation really landed: scan out the typed events it produced first, and bump seq
    /// separately only if there were none at all
    func seqDidMutate() { ControlEventBus.shared.settleMutation() }

    func dryRun(_ request: ControlRequest) -> Bool {
        request.args[ControlCommandTable.Flag.dryRun]?.boolValue ?? false
    }

    init(screens: ScreenRegistry, consent: ControlConsent) {
        self.screens = screens
        self.consent = consent
    }

    /// A connection went away. `events follow` is the only thing that outlives a single request,
    /// and the peer disappearing is its **only** termination condition — without this step a
    /// stream goes on writing to an fd that is already closed
    func connectionDidClose(_ connection: UInt64) {
        dispatchPrecondition(condition: .onQueue(.main))
        ControlEventBus.shared.connectionDidClose(connection)
    }

    var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
    }

    // MARK: Entry point

    func handle(_ request: ControlRequest, peer: ControlSocket.Peer,
                completion: @escaping (ControlResponse) -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))

        func fail(_ error: ControlErrorBody, resolved: ResolvedTarget? = nil) {
            completion(.failure(id: request.id, seq: seq, resolved: resolved, error: error))
        }

        guard request.v == ControlProtocol.version else {
            fail(ControlErrorBody(.protocolMismatch,
                                  "Protocol version mismatch: the caller speaks v\(request.v), QuickTerm \(appVersion) speaks v\(ControlProtocol.version)",
                                  hint: "Update the quickterm CLI (QuickTerm.app/Contents/MacOS/quickterm), or run install-cli again."))
            return
        }
        guard let spec = ControlCommandTable.command(request.cmd) else {
            fail(ControlErrorBody(.unknownCommand, "Unknown command \(request.cmd)",
                                  hint: "quickterm describe --json lists every command.",
                                  candidates: ControlCommandTable.commands.map(\.name)))
            return
        }
        guard config.isListening else {
            // `disabled`, not `denied`: nobody refused anything, a switch is off. Retrying gets
            // the same answer until the user edits the config, and an agent has to be able to
            // tell that from "the human clicked Deny this once".
            fail(ControlErrorBody(.disabled, "The control plane is off ([control] mode = \(config.mode))",
                                  hint: "Set mode = \"ask\" under [control] in ~/.config/quickterm/config.toml."))
            return
        }

        var target: ControlTarget?
        if let raw = request.target, !raw.isEmpty {
            do {
                target = try ControlTarget.parse(raw)
            } catch {
                fail(ControlErrorBody(.badTarget, "\(error)",
                                      hint: ControlTarget.grammarLines.joined(separator: " / ")))
                return
            }
        }

        // Command class: for `action` the class comes from the specific action, everything else
        // is read straight off the table
        var cls = spec.cls
        var action: WMAction?
        if spec.name == "action", request.args["list"]?.boolValue != true {
            guard let raw = request.args["name"]?.stringValue, !raw.isEmpty else {
                fail(ControlErrorBody(.badRequest, "action needs an action name",
                                      hint: "quickterm action --list"))
                return
            }
            guard let parsed = WMAction(rawValue: raw) else {
                fail(ControlErrorBody(.unknownAction, "Unknown action \(raw)",
                                      hint: "quickterm action --list",
                                      candidates: Self.suggestions(for: raw)))
                return
            }
            action = parsed
            cls = ControlCommandTable.actionClass(parsed)
        } else if spec.name == "action" {
            cls = .read   // --list only prints the table
        }
        // How destructive `spec apply` is depends on its mode: the default --into-empty
        // **cannot destroy anything** (a non-empty workspace is always refused, exit code 4),
        // while --replace / --reuse close existing panes.
        // The command table declares it destructive (describe and the MCP hints state the worst
        // case), and only the mode that genuinely closes nothing is downgraded here — written
        // the other way round (default to mutate, upgrade on seeing --replace), a mode added
        // later that does close panes would silently slip past the confirmation gate
        if spec.name == "spec.apply",
           request.args["replace"]?.boolValue != true, request.args["reuse"]?.boolValue != true {
            cls = .mutate
        }

        if cls == .interactive, let action {
            fail(ControlErrorBody(.interactiveAction,
                                  "\(action.rawValue) opens a panel or pop-up menu that needs keyboard interaction, so it cannot run over the socket",
                                  hint: ControlCommandTable.interactiveHint(action)))
            return
        }
        if cls == .sensitive, !config.allowsSensitive(spec.name) {
            fail(ControlErrorBody(.disabled, "Sensitive commands are off by default (\(spec.cli))",
                                  hint: config.sensitiveHint(spec.name)))
            return
        }
        // **Reading the text off somebody else's screen takes at least the token that gates
        // browser URLs.** A caller without `QUICKTERM_TOKEN` cannot even read a browser pane's
        // title (redacted by default), so it has even less business reading a shell's visible
        // area — where a credential that was just exported may still be sitting.
        // This gate comes **before** the confirmation gate: a command that is going to be refused
        // anyway must not first drag the user over to click "Allow"
        if spec.name == "pane.capture-text", request.token != ControlEnvironment.token {
            logRefusal(request.cmd, peer: peer, request: request, code: .disabled, message: "no token")
            fail(ControlErrorBody(
                .disabled, "capture-text requires the caller to carry this launch's origin token (QUICKTERM_TOKEN)",
                hint: "Run this command inside a QuickTerm pane, where the environment variable is injected for you; "
                    + "an external process has to inherit QUICKTERM_TOKEN from a pane."))
            return
        }
        if cls.isMutation, !config.allowsMutation {
            fail(ControlErrorBody(.disabled, "The control plane is read-only ([control] mode = \(config.mode))",
                                  hint: "Set mode = \"ask\" to allow mutations."))
            return
        }

        // Commands that carry these two flags without **implementing** them are refused up front,
        // **before** the rate limiter and the confirmation gate: for a read command the caller has
        // misread the semantics (a read changes nothing anyway); `action` is worse — it goes
        // straight through to `perform()`, so accepting it silently means the "preview" really
        // swung the knife, and `--dry-run` would switch the confirmation gate off on the way
        if !spec.honorsMutationFlags,
           request.args[ControlCommandTable.Flag.dryRun]?.boolValue == true
               || request.args[ControlCommandTable.Flag.failIfNoop]?.boolValue == true {
            fail(ControlErrorBody(
                .badRequest,
                "--dry-run / --fail-if-noop only mean something for the noun-verb mutation commands (\(spec.cli) has no diff to preview)",
                hint: spec.name == "action"
                    ? "action is a direct line to the keybindings. To dry-run a change, use a command "
                        + "like quickterm pane close or workspace clear."
                    : nil))
            return
        }

        // Mutation commands: while the user is held up by a dialog in front of them, never move
        // the layout behind their back. Two cases `isExecuting` does not cover at all:
        // (1) `NSAlert.runModal`'s nested run loop is still draining the main queue — the
        //     "processes are still running" confirmation in `closePane` goes out through
        //     `DispatchQueue.main.async`, so by the time it actually appears `perform()` has long
        //     returned and `isExecuting` has long been reset;
        // (2) our own consent sheet is still up — a `focus-*` slipping in now moves the focus,
        //     and the user looking at "Close the focused pane?" clicks Allow while a different
        //     pane takes the knife.
        // `consent.isModalBusy` is deliberately **not** used here: it covers attachedSheet on any
        // window, so one JS `confirm()` in a web page that is never dismissed would pin the whole
        // control plane at busy forever (web content DoSing the agent)
        if cls.isMutation, modalBusyProbe() || consent.isPrompting {
            fail(ControlErrorBody(.busy, "A dialog is open in QuickTerm, so mutation commands are held back",
                                  hint: "Dismiss the dialog in QuickTerm first.", retryAfterMs: 2000))
            return
        }

        // Rate limiting: mutation commands are limited a second time, by **origin**. The CLI
        // opens a new connection per command, so the connection-level bucket does nothing at all
        // against `for i in {1..200}; do quickterm pane new; done`
        if cls.isMutation, !(dryRun(request) && spec.honorsMutationFlags) {
            let origin = request.origin?.pane.map { "pane:\($0)" } ?? "pid:\(peer.pid)"
            if case .limited(let retry, let scope) = rateLimiter.admit(origin: origin) {
                logRefusal(request.cmd, peer: peer, request: request, code: .rateLimited,
                           message: "rate limited (\(scope))")
                fail(ControlErrorBody(.rateLimited, "Mutations are coming in too fast (\(scope) rate limit)",
                                      hint: "Batch the operations, or retry more slowly.", retryAfterMs: retry))
                return
            }
        }

        // `--dry-run` changes nothing, so it **does not ask**: the alert asks "shall I go
        // ahead", and this time nothing goes ahead. Whatever it can read, `state` hands out
        // anyway, under the same redaction rules.
        // The exemption is tied to "this command really implements the preview", not to "this
        // flag was passed": when another pass-through command that computes no diff is added
        // later, forgetting to implement dry-run at worst means accepting a useless flag — the
        // gate down in execute() refuses it outright — instead of quietly dismantling the
        // confirmation gate
        var needsConsent = cls.requiresConsent && config.promptsForDestructive
            && !(dryRun(request) && spec.honorsMutationFlags)

        // The send-text payload is validated **before** the user is asked: text that cannot be
        // delivered at all (control characters, over-long) must not first drag the user over to
        // click "Allow".
        // While we are here, take the preview the alert will show — it is only ever drawn on
        // screen, and not one character of it reaches the log
        var sendTextPreview: String?
        if spec.name == "input.send-text" {
            let raw = request.args["text"]?.stringValue ?? ""
            do {
                _ = try Self.validateSendText(raw)
            } catch let error as ControlErrorBody {
                fail(error)
                return
            } catch {
                fail(ControlErrorBody(.internalError, "\(error)"))
                return
            }
            sendTextPreview = Self.sendTextPreview(raw)
        }

        // **The only exemption from confirmation, and it is narrow enough to fit in one sentence:
        // the caller typing into its own pane.**
        //
        // This is not "carrying a token gets you through" — that shape is explicitly forbidden by
        // the comments on ControlEnvironment, and written that way it really would be a hole:
        // there is exactly **one** `QUICKTERM_TOKEN` per launch and it is injected into **every**
        // pane, so it can prove "from some pane" and never "from this pane". An earlier
        // implementation treated `origin.pane` (a UUID the caller reports about itself, which the
        // server cannot verify at all) as identity, so
        // `QUICKTERM_PANE=<somebody else's uuid> quickterm input send-text … -t <somebody else>`
        // would type into somebody else's shell with no confirmation at all.
        //
        // The test now accepts only the **verifiable** marker: `QUICKTERM_PANE_TOKEN` is the
        // per-pane `HMAC(per-launch secret, paneID)`, and the server recomputes it from the id of
        // **the pane `-t` actually resolved to** and compares. Only a match shows that the calling
        // process really is running inside that pane (or a child of it) — and that tty is its own
        // anyway; it could write to it without going through QuickTerm. A mismatch takes the road
        // where it is asked every time (and a send-text grant is not cached either, see
        // `cacheable` below)
        if needsConsent, spec.name == "input.send-text", writesIntoOwnPane(request, target: target) {
            needsConsent = false
        }

        // **Resolve the target first, then ask.** Asking with the caller's raw spelling
        // (`@focused`, or nothing at all) and resolving after the user answers leaves ten seconds
        // in which things really do change: what the user reads has to be one concrete pane, and
        // after approval the identity is checked once more before the knife goes in
        var pinned: PinnedSubject?
        if needsConsent {
            do {
                pinned = try pin(spec, action: action, target: target, request: request)
            } catch let error as ControlErrorBody {
                fail(error)          // the target was never valid: no need to disturb the user
                return
            } catch {
                fail(ControlErrorBody(.internalError, "\(error)"))
                return
            }
        }

        let execute = { [weak self] in
            guard let self else { return }
            self.execute(request, spec: spec, action: action, cls: cls, target: target,
                         pinned: pinned, peer: peer, completion: completion)
        }

        guard needsConsent else {
            execute()
            return
        }
        // Sensitive commands get one grant key each: having approved "read the screen" is not
        // approval for "type into the shell"
        let grantScope: String? = cls == .sensitive ? spec.name : nil
        if consent.isModalBusy, !consent.hasGrant(pid: peer.pid, cls: cls, scope: grantScope) {
            fail(ControlErrorBody(.busy, "A dialog is open in QuickTerm, so destructive commands are held back",
                                  hint: "Dismiss the dialog in QuickTerm first.", retryAfterMs: 2000))
            return
        }
        consent.evaluate(.init(peerName: peer.processName, peerPID: peer.pid, cls: cls,
                               summary: Self.consentSummary(request, spec: spec, action: action,
                                                            target: target, subject: pinned),
                               originPane: originHandle(for: request),
                               originVerified: originIsProven(request),
                               tokenPresent: request.token == ControlEnvironment.token,
                               // A send-text grant is **never cached**: typing into somebody
                               // else's tty is asked about every single time. Destructive
                               // commands are cached once per calling pid and command class
                               // because closing a pane is something the user can see, whereas
                               // injected text runs
                               // whatever it likes in that shell and can differ completely
                               // from one call to the next
                               cacheable: spec.name != "input.send-text",
                               scope: grantScope,
                               // The payload is drawn for the user alone: it is the only thing
                               // separating this confirmation from the last one, and without it
                               // `echo hi` and `curl … | sh` look identical in the alert
                               payload: sendTextPreview,
                               payloadLength: sendTextPreview == nil
                                   ? nil : (request.args["text"]?.stringValue ?? "").count,
                               payloadEnter: request.args["enter"]?.boolValue == true)) { decision in
            switch decision {
            case .allow:
                execute()
            case .deny:
                fail(ControlErrorBody(.denied, "The user denied this command"))
            case .timeout:
                fail(ControlErrorBody(.confirmationRequired,
                                      "This needs confirming in QuickTerm (no answer within \(Int(ControlConsent.timeout)) seconds)",
                                      hint: "Switch to QuickTerm, approve it, then retry."))
            }
        }
    }

    /// The "from pane t3" line in the alert. **Shown only when this launch's token came with the
    /// request**: `origin.pane` is self-reported (the CLI copies its own `$QUICKTERM_PANE`
    /// verbatim) and the server can verify none of it. Without the token there is not even
    /// evidence for "I come from some pane", so nothing is written at all — never present a
    /// self-report as fact on the screen where the user is making a trust decision.
    /// Even with the token the wording stays "claims": the token proves the request came from
    /// **some** pane, not from **this** one
    func originHandle(for request: ControlRequest) -> String? {
        guard request.token == ControlEnvironment.token else { return nil }
        guard let raw = request.origin?.pane, let uuid = UUID(uuidString: raw) else { return nil }
        // It has to be a pane that is alive right now: the handle registry is never pruned, so
        // without this check it would name a pane that was closed ten minutes ago
        guard ControlResolver.addressablePanes(in: screens).contains(where: { $0.pane.id == uuid }) else {
            return nil
        }
        return ControlHandleRegistry.shared.existingHandle(for: uuid)
    }

    /// Has the self-reported origin pane **been proven** (does `QUICKTERM_PANE_TOKEN` match
    /// `origin.pane`)?
    /// This affects the wording of the alert and nothing else — "from pane t3" and "claims to
    /// come from pane t3" are two different sentences, and the user is making a trust decision
    /// out of that one sentence
    func originIsProven(_ request: ControlRequest) -> Bool {
        guard let raw = request.origin?.pane, let uuid = UUID(uuidString: raw) else { return false }
        return ControlEnvironment.constantTimeEquals(request.origin?.paneToken,
                                                     ControlEnvironment.paneToken(for: uuid))
    }

    /// The `input send-text` exemption test: **is this command writing into the caller's own
    /// pane**?
    ///
    /// There is exactly one test, and neither side of it is something the caller can simply write
    /// down: recompute `HMAC(per-launch secret, paneID)` from the id of **the pane `-t` actually
    /// resolved to**, and compare it in constant time against the `QUICKTERM_PANE_TOKEN` the
    /// request carried.
    ///
    /// `origin.pane` is deliberately **not** consulted: it is self-reported. The old
    /// implementation treated it as identity, so `QUICKTERM_PANE=<somebody else's uuid>` could
    /// disguise any pane as "my own". Now, even writing somebody else's uuid into origin (which
    /// makes `-t @self` resolve over there as well) fails the HMAC, and the confirmation still
    /// happens.
    ///
    /// Resolution failed, the marker was not carried, or it writes into somebody else's pane —
    /// all of them return false (false = go and confirm, the safe side)
    func writesIntoOwnPane(_ request: ControlRequest, target: ControlTarget?) -> Bool {
        guard let claim = request.origin?.paneToken, !claim.isEmpty else { return false }
        var effective = target ?? ControlTarget()
        if effective.pane == nil { effective.pane = .focused }
        guard let resolved = try? makeResolver(request).resolve(effective).pane else { return false }
        return ControlEnvironment.constantTimeEquals(claim,
                                                     ControlEnvironment.paneToken(for: resolved.id))
    }

    /// The payload preview line in the alert. **Sanitized and truncated, never drawn verbatim**:
    /// `validateSendText` blocks C0 / DEL / C1, but U+2028 / U+2029 (AppKit really does break a
    /// line there), the bidi control U+202E and zero-width characters all still get through —
    /// drawn as they are, a caller could forge a few lines inside the dialog that look like the
    /// dialog speaking for itself. And 4096 characters could never fit in an NSAlert anyway
    static func sendTextPreview(_ raw: String, limit: Int = 120) -> String {
        var out = ""
        var shown = 0
        for scalar in raw.unicodeScalars {
            if shown >= limit { out += "…"; break }
            let v = scalar.value
            let dangerous = v < 0x20 || v == 0x7F || (0x80...0x9F).contains(v)
                || v == 0x2028 || v == 0x2029
                || (0x200B...0x200F).contains(v) || (0x202A...0x202E).contains(v)
                || (0x2066...0x2069).contains(v) || v == 0xFEFF
            out += dangerous ? String(format: "<U+%04X>", v) : String(Character(scalar))
            shown += 1
        }
        return out
    }

    /// **Resolve the target first, then ask**, and pin what came back. Destructive commands each
    /// have a different subject: `pane close` is one pane, `workspace clear` is the group of panes
    /// in one workspace, `screen close` is an entire screen — each of them has to be spelled out
    /// in the alert, and each of them is checked again before the knife goes in
    private func pin(_ spec: ControlCommandSpec, action: WMAction?, target: ControlTarget?,
                     request: ControlRequest) throws -> PinnedSubject? {
        let resolver = makeResolver(request)
        switch spec.name {
        case "workspace.clear":
            let resolution = try resolver.resolve(target)
            let controller = resolution.controller
            let panes = controller.model.layouts[resolution.workspace].paneList
                + controller.model.floatings[resolution.workspace].map(\.pane)
            let handles = panes.map { ControlHandleRegistry.shared.handle(for: $0) }
            return PinnedSubject(
                controller: controller, workspace: resolution.workspace, pane: nil, handle: nil,
                paneIDs: Set(panes.map(\.id)),
                description: "screen \(controller.screenIndex + 1) workspace \(resolution.workspace + 1)"
                    + " (\(panes.count) pane\(panes.count == 1 ? "" : "s"): \(handles.joined(separator: " ")))",
                consentText: Lp("consent.subject.workspace", count: panes.count,
                                L("consent.subject.place", controller.screenIndex + 1,
                                  resolution.workspace + 1),
                                panes.count, handles.joined(separator: " ")))
        case "spec.apply":
            // What gets pinned is "these panes across this batch of workspaces": **the scope is
            // decided by the spec body**, not by `-t`. A screen spec covers every workspace on a
            // whole screen and a session spec covers every screen; write only the one `-t` names
            // into the alert and the user is approving something far smaller than what happens
            let resolution = try resolver.resolve(target)
            guard let text = request.args["spec"]?.stringValue, !text.isEmpty else {
                throw ControlErrorBody(.badRequest, "No spec content was provided",
                                       hint: "quickterm spec apply -f <file>, or pipe the spec in on stdin")
            }
            // A spec that cannot be parsed, or cannot be applied, fails right here: no point
            // calling the user over to confirm something that cannot be done
            let document = try SpecParser.parse(text)
            let targets = try Self.specTargets(document, controller: resolution.controller,
                                               workspace: resolution.workspace, screens: screens)
            var scopes: [PinnedScope] = []
            var handles: [String] = []
            var places: [String] = []
            /// The same places in the UI language (consent alert only, never over the socket).
            var localizedPlaces: [String] = []
            for target in targets {
                let closing = target.controller.model.closingPanes
                let panes = (target.controller.model.layouts[target.workspace].paneList
                    + target.controller.model.floatings[target.workspace].map(\.pane))
                    .filter { !closing.contains($0.id) }
                handles += panes.map { ControlHandleRegistry.shared.handle(for: $0) }
                if places.count < 6 {
                    places.append("screen \(target.controller.screenIndex + 1) workspace \(target.workspace + 1)")
                    localizedPlaces.append(L("consent.subject.place",
                                             target.controller.screenIndex + 1, target.workspace + 1))
                }
                scopes.append(PinnedScope(controller: target.controller, workspace: target.workspace,
                                          paneIDs: Set(panes.map(\.id))))
            }
            let listed = handles.prefix(12).joined(separator: " ")
                + (handles.count > 12 ? " …" : "")
            let where_ = places.joined(separator: ", ") + (targets.count > places.count ? " …" : "")
            let whereLocalized = localizedPlaces.joined(separator: L("consent.list.separator"))
                + (targets.count > localizedPlaces.count ? " …" : "")
            let description = targets.count == 1
                ? "\(where_) (\(handles.count) pane\(handles.count == 1 ? "" : "s"): \(listed))"
                : "\(targets.count) workspaces (\(where_)), "
                    + "\(ControlChange.count(handles.count, "pane")) in all: \(listed)"
            let consentText = targets.count == 1
                ? Lp("consent.subject.workspace", count: handles.count,
                     whereLocalized, handles.count, listed)
                : Lp("consent.subject.spec-multi", count: handles.count,
                     targets.count, whereLocalized, handles.count, listed)
            return PinnedSubject(
                controller: resolution.controller, workspace: resolution.workspace,
                pane: nil, handle: nil, paneIDs: nil, scopes: scopes, description: description,
                consentText: consentText)
        case "screen.close":
            let resolution = try resolver.resolve(target)
            let controller = resolution.controller
            let count = controller.model.allPanes.count
            return PinnedSubject(
                controller: controller, workspace: resolution.workspace, pane: nil, handle: nil,
                paneIDs: nil,
                description: "screen \(controller.screenIndex + 1) \"\(controller.window?.title ?? "")\""
                    + " (\(count) pane\(count == 1 ? "" : "s"))",
                consentText: Lp("consent.subject.screen", count: count,
                                controller.screenIndex + 1, controller.window?.title ?? "", count))
        default:
            var effective = target ?? ControlTarget()
            if effective.pane == nil { effective.pane = .focused }
            let resolution = try resolver.resolve(effective)
            guard let subject = resolution.pane ?? resolution.controller.focusedPane else { return nil }
            let handle = ControlHandleRegistry.shared.handle(for: subject)
            return PinnedSubject(
                controller: resolution.controller, workspace: resolution.workspace,
                pane: subject, handle: handle, paneIDs: nil,
                description: "\(handle) \"\(subject.paneTitle)\"",
                consentText: L("consent.subject.pane", handle, subject.paneTitle))
        }
    }

    /// The body of the alert. It has to name **the concrete subject** (handle + title + screen /
    /// workspace) rather than merely echo the caller's spelling back — "close the focused pane"
    /// is not, on its own, something anyone can consent to.
    /// The title given here is the real, unredacted one: redaction protects against the caller,
    /// while this text is for the user's eyes only and never travels back over the socket
    static func consentSummary(_ request: ControlRequest, spec: ControlCommandSpec, action: WMAction?,
                               target: ControlTarget?, subject: PinnedSubject?) -> String {
        // One line = one whole sentence. **Never glue fragments together** ("applies to X" +
        // "· screen 1 · workspace 2"): word order differs between the two languages, so that
        // shape cannot be translated. The location is its own line, and so is "tab only".
        var lines = [action.map { L("consent.summary.action", $0.rawValue, $0.localizedHelp) }
            ?? L("consent.summary.command", spec.cli, spec.summary)]
        if let subject {
            let controller = subject.controller
            switch spec.name {
            case "workspace.clear":
                lines.append(L("consent.summary.workspace-clear", subject.consentText))
            case "screen.close":
                lines.append(L("consent.summary.screen-close", subject.consentText))
            case "spec.apply":
                lines.append(L("consent.summary.spec-apply", subject.consentText))
            case "browser.close":
                let tabs = (subject.pane as? BrowserPaneView)?.tabs.count ?? 0
                let which = request.args["tab"]?.stringValue ?? "@active"
                if request.args["others"]?.boolValue == true {
                    let others = max(tabs - 1, 0)
                    lines.append(Lp("consent.summary.browser-close-others", count: others,
                                    subject.consentText, which, others))
                } else if tabs <= 1 {
                    lines.append(L("consent.summary.browser-close-last", subject.consentText))
                } else {
                    lines.append(Lp("consent.summary.browser-close-tab", count: tabs - 1,
                                    subject.consentText, which, tabs - 1))
                }
                lines.append(L("consent.summary.location",
                               controller.screenIndex + 1, subject.workspace + 1))
            case "pane.capture-text":
                // Reading the screen has to be worded as reading in the alert: what the user is
                // approving is "hand over the text on that pane's screen", not some abstract
                // "perform a sensitive operation"
                lines.append(L("consent.summary.capture-text", subject.consentText))
                lines.append(L("consent.summary.location",
                               controller.screenIndex + 1, subject.workspace + 1))
            default:
                lines.append(L("consent.summary.applies-to", subject.consentText))
                lines.append(L("consent.summary.location",
                               controller.screenIndex + 1, subject.workspace + 1))
                // A browser pane holding more than one tab is the one place where the action
                // and the command part ways, and the alert has to say which one the user is
                // looking at:
                //   `action close-pane` is the Cmd+W path — it closes the current TAB only
                //     (Chrome's semantics), so the reassuring sentence is true there;
                //   `quickterm pane close` means "close this pane": the whole thing goes, tabs
                //     and all (the recorded decision in ControlPaneCommands.paneClose).
                // Both used to print "only the current tab is closed", which is a promise the
                // command line does not keep — the user read it and lost every tab in the pane.
                if let browser = subject.pane as? BrowserPaneView, browser.tabs.count > 1 {
                    if action == .closePane {
                        lines.append(L("consent.summary.tab-only"))
                    } else if spec.name == "pane.close" {
                        lines.append(Lp("consent.summary.whole-pane", count: browser.tabs.count,
                                        browser.tabs.count))
                    }
                }
            }
        } else if let target, !target.isEmpty {
            lines[0] = L("consent.summary.with-target", lines[0], target.text)
        }
        return lines.joined(separator: "\n")
    }

    /// Offer the nearest few names for a mistyped action (agents hallucinate `close_pane` and
    /// `focus-l`)
    static func suggestions(for raw: String) -> [String] {
        let needle = raw.lowercased()
        let all = WMAction.allCases.map(\.rawValue)
        let prefixed = all.filter { $0.hasPrefix(String(needle.prefix(3))) }
        let contains = all.filter { $0.contains(needle) || needle.contains($0) }
        let merged = Array(Set(prefixed + contains)).sorted()
        return Array(merged.prefix(8))
    }

    // MARK: Execution

    /// The encoder for this request (it decides whether a browser pane's URL / title get
    /// redacted)
    private func makeEncoder(_ request: ControlRequest) -> ControlStateEncoder {
        ControlStateEncoder(screens: screens, trusted: request.token == ControlEnvironment.token,
                            exposeBrowser: config.exposeBrowser, mode: config.mode)
    }

    /// The resolver for this request. **The redaction decision has to be carried all the way
    /// into the resolver**: otherwise the `title:~` predicate matches against the real,
    /// unredacted title and becomes a probing channel around the redaction
    private func makeResolver(_ request: ControlRequest) -> ControlResolver {
        ControlResolver(screens: screens, origin: request.origin,
                        exposesBrowser: makeEncoder(request).exposesBrowser)
    }

    private func execute(_ request: ControlRequest, spec: ControlCommandSpec, action: WMAction?,
                         cls: ControlCommandClass, target: ControlTarget?,
                         pinned: PinnedSubject?,
                         peer: ControlSocket.Peer, completion: @escaping (ControlResponse) -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !isExecuting else {
            completion(.failure(id: request.id, seq: seq,
                                error: ControlErrorBody(.busy, "Another control command is already running",
                                                        retryAfterMs: 50)))
            return
        }
        isExecuting = true
        currentFlags = (dryRun: request.args[ControlCommandTable.Flag.dryRun]?.boolValue ?? false,
                        failIfNoop: request.args[ControlCommandTable.Flag.failIfNoop]?.boolValue ?? false)
        defer {
            isExecuting = false
            currentFlags = (false, false)
        }
        // Backstop: `handle()` already refused this once, before the rate limiter and the
        // confirmation gate — which is the right place, because calling the user over to confirm
        // and only then telling them the command does not know this flag is not acceptable
        if !spec.honorsMutationFlags, currentFlags.dryRun || currentFlags.failIfNoop {
            completion(.failure(id: request.id, seq: seq,
                                error: ControlErrorBody(
                                    .badRequest,
                                    "--dry-run / --fail-if-noop only mean something for the noun-verb mutation commands (\(spec.cli) has no diff to preview)")))
            return
        }

        // Local commands (`install-cli`, `mcp`) have no business appearing on this socket at
        // all: they run entirely on the caller's side. Left unsaid, they fall into the default
        // branch below and get told "not implemented in this phase" — which is false, and an
        // agent will take it at face value and wait for a release that never comes
        if spec.local {
            completion(.failure(id: request.id, seq: seq,
                                error: ControlErrorBody(
                                    .unknownCommand,
                                    "\(spec.cli) runs entirely on the quickterm side and never goes over the socket",
                                    hint: "Run quickterm \(spec.cli) directly in a terminal.")))
            return
        }

        let encoder = makeEncoder(request)
        let resolver = makeResolver(request)
        do {
            switch spec.name {
            case "state":
                let resolution = try resolver.resolve(target)
                let scope = target?.screen != nil ? resolution.controller : nil
                let payload = encoder.payload(scope: scope)
                let data: any Encodable = try project(payload, fields: request.args["fields"]?.stringValue)
                completion(.success(id: request.id, seq: seq, resolved: resolution.echo, data: data))

            case "list":
                let resolution = try resolver.resolve(target)
                let what = request.args["what"]?.stringValue ?? "panes"
                let payload = encoder.payload(scope: target?.screen != nil ? resolution.controller : nil)
                let fields = request.args["fields"]?.stringValue
                var out = ControlListPayload()
                switch what {
                case "screens":
                    out.screens = payload.screens
                case "workspaces":
                    out.workspaces = encoder.screenInfo(
                        resolution.controller,
                        isKey: resolution.controller === screens.controlCurrent).workspaces
                case "panes":
                    var panes = payload.panes
                    if target?.workspace != nil {
                        panes = panes.filter {
                            $0.screen == resolution.controller.screenIndex + 1
                                && $0.workspace == resolution.workspace + 1
                        }
                    }
                    out.panes = try panes.map { try projectPane($0, fields: fields) }
                default:
                    throw ControlErrorBody(.badRequest, "list only accepts screens / workspaces / panes",
                                           candidates: ["screens", "workspaces", "panes"])
                }
                completion(.success(id: request.id, seq: seq, resolved: resolution.echo, data: out))

            case "get":
                var effective = target ?? ControlTarget()
                if effective.pane == nil { effective.pane = .focused }
                let resolution = try resolver.resolve(effective)
                guard let pane = resolution.pane else {
                    throw ControlErrorBody(.notFound, "No addressable pane")
                }
                let positions = ControlStateEncoder.positions(
                    in: resolution.controller.model.layouts[resolution.workspace],
                    closing: resolution.controller.model.closingPanes)
                let workspace = encoder.workspaceInfo(resolution.controller, index: resolution.workspace)
                let handle = ControlHandleRegistry.shared.handle(for: pane)
                let info = encoder.paneInfo(pane, controller: resolution.controller,
                                            workspace: resolution.workspace,
                                            at: positions[pane.id],
                                            float: workspace.floating.contains(handle),
                                            zoomed: workspace.zoom == handle)
                completion(.success(id: request.id, seq: seq, resolved: resolution.echo,
                                    data: ControlPanePayload(pane: info)))

            case "action":
                if request.args["list"]?.boolValue == true {
                    completion(.success(id: request.id, seq: seq, resolved: nil,
                                        data: ControlActionListPayload(actions: ControlCommandTable.actionDocs)))
                    return
                }
                guard let action else { throw ControlErrorBody(.badRequest, "action needs an action name") }
                let payload = try runAction(action, target: target, resolver: resolver,
                                            precise: request.args["precise"]?.boolValue ?? false,
                                            encoder: encoder, pinned: pinned)
                seqDidMutate()
                completion(.success(id: request.id, seq: seq, resolved: payload.echo, data: payload.data))

            case "describe":
                let document = ControlDescribeDocument.make(
                    cliVersion: appVersion, appVersion: appVersion,
                    socket: ControlEnvironment.socketPath, mode: config.mode)
                completion(.success(id: request.id, seq: seq, resolved: nil, data: document))

            case "version":
                completion(.success(id: request.id, seq: seq, resolved: nil,
                                    // cli is left empty: the app has no way to know the
                                    // version of the caller's binary, so the CLI fills it in
                                    // from its own cliVersion (see CLI/main.swift).
                                    // Encoding appVersion here would make the "CLI and app
                                    // versions disagree" diagnostic report agreement forever,
                                    // and an old binary left on PATH after an upgrade is
                                    // exactly the case the design set out to catch
                                    data: ControlVersionPayload(
                                        cli: nil, app: appVersion,
                                        protocolVersion: ControlProtocol.version,
                                        appProtocolVersion: ControlProtocol.version,
                                        socket: ControlEnvironment.socketPath, running: true)))

            case "events.poll", "events.follow":
                // **The one command that need not answer synchronously**: a long poll hangs there
                // waiting, and a stream keeps pushing. `isExecuting` is reset when this function
                // returns (defer), so a suspended poll does not block every other command — which
                // is both the price and the premise of "the event stream is the long-lived
                // connection"
                let ctx = ControlContext(spec: spec, request: request, peer: peer, target: target,
                                         resolver: resolver, encoder: encoder, pinned: pinned)
                try runEvents(ctx, completion: completion)

            default:
                // The Phase 2 noun-verb layer: one uniform (echo, mutation envelope) shape
                guard let group = spec.group else {
                    throw ControlErrorBody(.unknownCommand, "Command \(spec.name) is not implemented in this phase")
                }
                let ctx = ControlContext(spec: spec, request: request, peer: peer, target: target,
                                         resolver: resolver, encoder: encoder, pinned: pinned)
                let result: (echo: ResolvedTarget?, data: any Encodable)
                switch group {
                case "pane": result = try runPane(ctx)
                case "workspace": result = try runWorkspace(ctx)
                case "screen": result = try runScreen(ctx)
                case "app": result = try runApp(ctx)
                case "spec": result = try runSpec(ctx)
                case "input": result = try runInput(ctx)
                case "browser": result = try runBrowser(ctx)
                default:
                    throw ControlErrorBody(.unknownCommand, "Unknown command group \(group)",
                                           candidates: ControlCommandTable.groups)
                }
                completion(.success(id: request.id, seq: seq, resolved: result.echo, data: result.data))
            }
        } catch let error as ControlErrorBody {
            completion(.failure(id: request.id, seq: seq, error: error))
        } catch {
            completion(.failure(id: request.id, seq: seq,
                                error: ControlErrorBody(.internalError, "\(error)")))
        }
    }

    // MARK: action

    private func runAction(_ action: WMAction, target: ControlTarget?, resolver: ControlResolver,
                           precise: Bool, encoder: ControlStateEncoder, pinned: PinnedSubject?)
        throws -> (echo: ResolvedTarget, data: ControlActionPayload) {
        let resolution = try resolver.resolve(target)
        let controller = resolution.controller

        // Actions that carry a workspace index: out of range has to state the range explicitly,
        // never silently do nothing
        if let index = action.workspaceIndex {
            let count = controller.model.layouts.count
            guard index < count else {
                throw ControlErrorBody(
                    .notFound,
                    "\(action.rawValue) points at workspace \(index + 1), but screen \(controller.screenIndex + 1) only has \(count)",
                    hint: "Raise workspaces (1–10) in ~/.config/quickterm/config.toml")
            }
        }

        // `action` goes straight through to `perform()`, and `perform()` acts only on the
        // **active** workspace. Going ahead anyway when the target names a different workspace is
        // exactly the silent failure where the agent believes it changed one thing and changed
        // another
        if target?.workspace != nil, resolution.workspace != controller.model.activeIndex,
           action.workspaceIndex == nil {
            throw ControlErrorBody(
                .badTarget,
                "action applies to the active workspace (currently \(controller.model.activeIndex + 1)), but the target is \(resolution.workspace + 1)",
                hint: "Run quickterm action goto-workspace-\(resolution.workspace + 1) first.")
        }

        // The target names a pane explicitly: hand the focus over first, and execute only once
        // **the handover has been verified**. The handover retries asynchronously (up to 0.75 s),
        // and a failed check always returns busy — never act on the wrong pane
        if target?.pane != nil, let pane = resolution.pane {
            guard resolution.workspace == controller.model.activeIndex else {
                throw ControlErrorBody(
                    .badTarget,
                    "pane \(ControlHandleRegistry.shared.handle(for: pane)) is in workspace \(resolution.workspace + 1), which is not the active workspace",
                    hint: "Run quickterm action goto-workspace-\(resolution.workspace + 1) first.")
            }
            if controller.focusedPane !== pane {
                controller.requestFocus(to: pane)
                guard controller.focusedPane === pane else {
                    throw ControlErrorBody(
                        .busy,
                        "Focus could not be handed to \(ControlHandleRegistry.shared.handle(for: pane)) in the same turn (SwiftUI has not mounted it yet)",
                        hint: "Retry shortly; nothing was done this time.", retryAfterMs: 200)
                }
            }
        }

        if action.browserOnly, !(controller.focusedPane is BrowserPaneView) {
            throw ControlErrorBody(
                .wrongPaneKind, "\(action.rawValue) only works on a browser pane, and the focused pane is not one",
                hint: "Pass -t <browser pane handle> (the ones with kind=browser in quickterm list panes)")
        }
        if action.terminalOnly, !(controller.focusedPane is Ghostty.SurfaceView) {
            throw ControlErrorBody(
                .wrongPaneKind, "\(action.rawValue) only works on a terminal pane, and the focused pane is not one",
                hint: "Pass -t <terminal pane handle>")
        }

        // The confirmation gate approved **this one** pane: check the identity again before the
        // knife goes in. During the ten seconds the user spends reading the alert, mutate commands
        // that need no confirmation (`focus-right`, `goto-workspace-N`, …) can slip in and move
        // the focus; better to fail the whole command as busy than to let an approved cut land
        // somewhere else
        if let pinned, let pinnedPane = pinned.pane {
            guard controller === pinned.controller, controller.focusedPane === pinnedPane,
                  !controller.model.closingPanes.contains(pinnedPane.id) else {
                throw ControlErrorBody(
                    .busy,
                    "The target changed while the confirmation prompt was up (what was confirmed: "
                        + "\(pinned.handle ?? pinned.description), which is no longer focused): nothing was done",
                    hint: "Send it again, or name the target exactly with -t \(pinned.handle ?? "<handle>")",
                    retryAfterMs: 200)
            }
        }

        let before = Set(controller.model.allPanes.map(\.id))
        let confirmPending = action == .closePane && (controller.focusedPane?.wantsConfirmClose ?? false)
        controller.perform(action, precise: precise)   // perform() flushPendingCloses() first itself

        let after = controller.model.allPanes.filter { !before.contains($0.id) }
        let positions = ControlStateEncoder.positions(in: controller.model.layout,
                                                     closing: controller.model.closingPanes)
        let created = after.map { pane in
            encoder.paneInfo(pane, controller: controller, workspace: controller.model.activeIndex,
                             at: positions[pane.id], float: false, zoomed: false)
        }
        // Echoing where it landed: if a pane was created, report that one, not "whichever pane
        // holds the focus right now". `requestFocus` is an asynchronous handover with backoff
        // retries (up to 0.75 s), and by the time the command returns the focus has often not
        // actually moved yet — rather than return an old pane that happens to be focused at this
        // instant, report the new pane honestly and flag focusPending
        let subject = after.first ?? (target?.pane != nil ? resolution.pane : nil) ?? controller.focusedPane
        let focusPending = subject.map { controller.focusedPane !== $0 } ?? false
        let echo = ResolvedTarget(
            screen: controller.screenIndex + 1,
            screenID: controller.windowID.uuidString,
            workspace: controller.model.activeIndex + 1,
            pane: subject.map { ControlHandleRegistry.shared.handle(for: $0) },
            paneID: subject?.id.uuidString)
        return (echo, ControlActionPayload(
            action: action.rawValue,
            cls: ControlCommandTable.actionClass(action),
            applied: !confirmPending,
            confirmPending: confirmPending ? true : nil,
            focusPending: focusPending ? true : nil,
            panes: created.isEmpty ? nil : created))
    }

    // MARK: --fields projection

    private func project(_ payload: ControlStatePayload, fields: String?) throws -> any Encodable {
        guard let list = Self.fieldList(fields) else { return payload }
        return ControlStateProjected(
            schema: payload.schema, app: payload.app, screens: payload.screens,
            panes: try payload.panes.map { try $0.projected(to: list) })
    }

    private func projectPane(_ pane: ControlStatePayload.PaneInfo, fields: String?) throws -> JSONValue {
        guard let list = Self.fieldList(fields) else {
            let data = try ControlJSON.encoder.encode(pane)
            return try ControlJSON.decoder.decode(JSONValue.self, from: data)
        }
        return try pane.projected(to: list)
    }

    static func fieldList(_ raw: String?) -> [String]? {
        guard let raw, !raw.isEmpty else { return nil }
        let list = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return list.isEmpty ? nil : list
    }
}

/// The state payload after `--fields` (each pane becomes a projected object)
struct ControlStateProjected: Encodable {
    var schema: String
    var app: ControlStatePayload.AppInfo
    var screens: [ControlStatePayload.ScreenInfo]
    var panes: [JSONValue]
}

