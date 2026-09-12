import AppKit

/// `input send-text` - the **only** command in the whole control plane that can make someone
/// else's shell run an arbitrary command.
///
/// To be clear about what it actually is: this is not "sending a message to a terminal", it is
/// **typing on that tty**. What runs there may be a root shell, a live ssh session, or vim in
/// normal mode; every character sent in is interpreted by that program under its own rules. When
/// the remote control of tmux / kitty gets weaponized, this is the primitive being used. That is
/// why four gates are stacked on it, each of which holds independently:
///
/// 1. **Off by default**: until `[control] send-text = true`, the command never even gets a chance
///    to run (the `sensitive`-class gate in `ControlCommandRunner.handle`, which sits ahead of rate
///    limiting and confirmation);
/// 2. **`sensitive` class**: hard-coded in the command table, and the describe / MCP hints are
///    generated from there;
/// 3. **Confirmation every time**: injecting anywhere other than the caller's own pane takes one
///    click on "allow" by the user inside QuickTerm, and **that approval is never cached** (see
///    `ControlConsent.Request.cacheable`);
/// 4. **Control characters are always refused, a newline only comes from `--enter`**: without this
///    rule a call that "just wanted to fill in a text field" executes a command on the way past;
///    with it, "send text" and "make it run" are two intents that have to be written out
///    separately.
///
/// The one confirmation-free opening is "writing into your own pane", decided in
/// `ControlCommandRunner.writesIntoOwnPane`: that tty already belongs to the calling process,
/// which can write to it without going through QuickTerm at all.
@MainActor
extension ControlCommandRunner {
    /// How many characters one call may send. An agent hallucinating an entire file and pasting it
    /// into a shell is a thing that really happens
    static let maxSendTextLength = 4096

    func runInput(_ ctx: ControlContext) throws -> (echo: ResolvedTarget?, data: any Encodable) {
        switch ctx.spec.verb {
        case "send-text": return try inputSendText(ctx)
        default:
            throw ControlErrorBody(.unknownCommand, "input has no verb \(ctx.spec.verb)",
                                   candidates: ControlCommandTable.commands(inGroup: "input").map(\.verb))
        }
    }

    private func inputSendText(_ ctx: ControlContext) throws -> (ResolvedTarget?, any Encodable) {
        // **-t has to be written out.** Everywhere else the default landing spot is "the focused
        // pane"; here that would mean "type into whichever shell happens to be focused right now",
        // and an agent cannot see the focus, so such a default only manufactures the kind of
        // accident nobody can trace afterwards. If you do mean the focused pane, say `-t @focused`
        // explicitly.
        guard ctx.target?.pane != nil else {
            throw ControlErrorBody(
                .badTarget, "input send-text needs an explicit target pane (-t)",
                hint: "Your own pane is -t @self; any other pane is -t <handle>, and that asks "
                    + "for confirmation every time.")
        }
        let raw = ctx.request.args["text"]?.stringValue ?? ""
        let text = try Self.validateSendText(raw)
        let enter = ctx.flag("enter")

        let hit = try requirePane(ctx, ctx.target)
        try verifyPinned(ctx, controller: hit.controller, workspace: hit.workspace, pane: hit.pane)
        guard let surface = hit.pane as? Ghostty.SurfaceView else {
            throw ControlErrorBody(
                .wrongPaneKind,
                "\(handleName(hit.pane)) is a \(hit.pane.kind.rawValue) pane, so there is no "
                    + "terminal to type into",
                hint: "Only panes with kind=terminal can receive send-text (quickterm list panes)")
        }
        guard let model = surface.surfaceModel else {
            throw ControlErrorBody(.busy, "The terminal is not ready yet (the engine surface "
                                       + "has not been created)",
                                   hint: "Retry shortly; nothing was done this time.",
                                   retryAfterMs: 200)
        }

        // **The body never appears in the diff**: the activity log and the status-bar flash are
        // there for the user to read, and what gets sent in is usually a command line - writing it
        // verbatim into a log that is kept around is a new leak surface all of its own.
        let changes = [ControlChange(path(hit.controller, hit.workspace, hit.pane),
                                     from: "(keyboard input)",
                                     to: "\(text.count) characters"
                                         + (enter ? " + Return" : " (no Return)"))]
        let mutation = ControlMutationRequest(
            command: ctx.spec.name, request: ctx.request, peer: ctx.peer, changes: changes,
            controllers: [hit.controller],
            // **Not undoable**: there is no such thing as putting typed characters back into a
            // shell, and registering an undo entry would only make the user believe Cmd+Z can
            // take back a command that has already started running.
            undoCommand: nil,
            target: path(hit.controller, hit.workspace, hit.pane))
        var payload = try commit(mutation) {
            if !text.isEmpty { model.sendText(text) }
            // Return is CR (0x0D), not LF: that is what Enter has always been in a terminal.
            if enter { model.sendText("\r") }
        }
        payload.pane = paneInfo(hit, encoder: ctx.encoder)
        return (hit.echo, payload)
    }

    /// Validate the body. **Refuse, do not filter**: quietly stripping a character would leave the
    /// caller believing it sent the string it wrote, while what reached the shell was a different
    /// one - and that is exactly the shape an injection accident has
    static func validateSendText(_ raw: String) throws -> String {
        guard raw.utf16.count <= maxSendTextLength else {
            throw ControlErrorBody(
                .badRequest, "The text is too long (\(raw.utf16.count) characters, limit "
                    + "\(maxSendTextLength))",
                hint: "Send it in a few pieces, or start the command directly with "
                    + "pane new --cmd.")
        }
        for scalar in raw.unicodeScalars {
            let value = scalar.value
            let isC0 = value < 0x20
            let isDelete = value == 0x7F
            let isC1 = (0x80...0x9F).contains(value)
            guard isC0 || isDelete || isC1 else { continue }
            let name: String
            switch value {
            case 0x0A: name = "newline (\\n)"
            case 0x0D: name = "carriage return (\\r)"
            case 0x09: name = "tab (\\t)"
            case 0x1B: name = "Esc"
            case 0x03: name = "Ctrl-C"
            default: name = String(format: "U+%04X", value)
            }
            throw ControlErrorBody(
                .badRequest, "The text contains a control character: \(name). send-text only "
                    + "sends visible text",
                hint: value == 0x0A || value == 0x0D
                    ? "A newline can only be given explicitly with --enter, which is the one way "
                        + "to make the shell actually run what you sent."
                    : "Control characters (Esc, Ctrl-x and tab included) are always refused: "
                        + "whatever runs in that terminal reads them as instructions.")
        }
        return raw
    }
}
