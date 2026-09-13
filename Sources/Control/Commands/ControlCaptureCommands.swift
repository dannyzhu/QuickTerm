import AppKit
import GhosttyKit

/// `pane capture-text` - read back **the text currently on screen** in a terminal pane.
///
/// Why this sits at the same security class as `input send-text` (`sensitive`) rather than `read`:
/// the viewport of a shell can hold anything - a token that was just `export`ed, a password typed
/// at the prompt but not yet submitted, private code from a `git diff`, the output of a live ssh
/// session. That is far more sensitive than "the URL of a browser pane" (the thing the control
/// plane has redacted by default from the start). So the gates stacked on it are the same rank as
/// send-text's, and each one holds independently:
///
/// 1. **Off by default**: until `[control] capture-text = true`, the command never even gets a
///    chance to run;
/// 2. **This launch's token is mandatory**: a caller without `QUICKTERM_TOKEN` is always refused -
///    that is the very same token that gates browser-URL redaction. Whoever cannot read a browser
///    URL certainly should not be reading someone else's tty;
/// 3. **Confirmed once per calling process** (at `(pid, command)` granularity, see
///    `ControlConsent`): there is a first time only after the user has seen "such-and-such process
///    wants to read the screen contents of t7" inside QuickTerm and clicked "allow";
/// 4. **The body leaves no trace anywhere**: not in the activity log (read commands are not logged
///    to begin with), not in the event stream (events carry no pane output by design), not in
///    OSLog. It appears exactly once, in that one response.
///
/// There is deliberately **no** "reading your own pane needs no confirmation" opening. `send-text`
/// has that opening because the calling process can already write to its own tty (without going
/// through QuickTerm at all); **reading** is different: a process has no normal way to read its own
/// tty's scrollback, and what is lying there may be whatever the user typed before handing this
/// pane over to an agent. With no precedent to follow, the safe side is to ask.
@MainActor
extension ControlCommandRunner {
    func paneCaptureText(_ ctx: ControlContext) throws -> (ResolvedTarget?, any Encodable) {
        let hit = try requirePane(ctx, ctx.target)
        try verifyPinned(ctx, controller: hit.controller, workspace: hit.workspace, pane: hit.pane)
        guard let surface = hit.pane as? Ghostty.SurfaceView else {
            throw ControlErrorBody(
                .wrongPaneKind,
                "\(handleName(hit.pane)) is a \(hit.pane.kind.rawValue) pane, so it has no terminal screen to read",
                hint: "Only a kind=terminal pane can be captured (quickterm list panes)")
        }
        let scrollback = ctx.int("scrollback") ?? 0
        guard (0...ControlCaptureLimits.maxScrollback).contains(scrollback) else {
            throw ControlErrorBody(
                .badRequest,
                "--scrollback has to be between 0 and \(ControlCaptureLimits.maxScrollback), got \(scrollback)",
                hint: "For more history, write it to a file from inside that pane (tee / script): "
                    + "a whole scrollback buffer in one response eats an agent's entire context.")
        }
        guard let capture = Self.capture(surface, scrollback: scrollback) else {
            throw ControlErrorBody(.busy, "The terminal is not ready yet (the engine surface "
                                       + "has not been created)",
                                   hint: "Retry shortly; nothing was done this time.", retryAfterMs: 200)
        }

        let payload = ControlCaptureTextPayload(
            command: ctx.spec.name,
            pane: paneInfo(hit, encoder: ctx.encoder),
            cols: surface.surfaceSize.map { Int($0.columns) },
            rows: surface.surfaceSize.map { Int($0.rows) },
            lines: capture.lines,
            scrollback: capture.scrollbackLines,
            truncated: capture.truncated ? true : nil,
            text: capture.text)
        return (hit.echo, payload)
    }

    struct Capture {
        var text: String
        var lines: Int
        var scrollbackLines: Int
        var truncated: Bool
    }

    /// Read the viewport (plus N more lines above it when `--scrollback N` is given).
    ///
    /// **Does not go through `cachedVisibleContents`**: that cache has a 500ms lifetime and exists
    /// for accessibility. The caller is asking "what is on screen right now" - passing off a
    /// snapshot up to half a second old as "now" is exactly where illusions like "I sent a command
    /// and read back the previous screen" come from.
    static func capture(_ surface: Ghostty.SurfaceView, scrollback: Int) -> Capture? {
        guard let viewport = surface.controlReadText(tag: GHOSTTY_POINT_VIEWPORT) else { return nil }
        let screen = scrollback > 0 ? surface.controlReadText(tag: GHOSTTY_POINT_SCREEN) : nil
        return assemble(viewport: viewport, screen: screen, scrollback: scrollback)
    }

    /// The assembly step lives on its own (pure function, never touches the engine): the counts
    /// after truncation are easy to get wrong, and getting them wrong costs the caller a slice of
    /// `text` by `scrollback` that mistakes the viewport for history
    static func assemble(viewport: String, screen: String?, scrollback: Int) -> Capture {
        var lines = Self.trimmed(viewport)
        // How many lines the viewport itself has - **after truncation this is what lets us work
        // back out how much history is left**
        let viewportLines = lines.count
        var scrollbackLines = 0

        if scrollback > 0, let screen {
            let all = Self.trimmed(screen)
            // The engine's "screen" includes the scrollback, and normally its tail is exactly the
            // viewport lines. When they match, cut them off: what is above is the history that
            // really sits **on top of the viewport**. When they do not match (the user is scrolled
            // up), fall back honestly to "the last N lines of the whole history" - never pretend
            // those N lines are necessarily the ones adjacent to the viewport.
            if lines.count <= all.count, Array(all.suffix(lines.count)) == lines {
                let history = all.dropLast(lines.count).suffix(scrollback)
                scrollbackLines = history.count
                lines = Array(history) + lines
            } else {
                let tail = Array(all.suffix(scrollback + lines.count))
                scrollbackLines = max(tail.count - lines.count, 0)
                lines = tail
            }
        }

        var text = lines.joined(separator: "\n")
        var truncated = false
        if text.utf8.count > ControlCaptureLimits.maxBytes {
            // **Cut from the head**: the newest lines on screen are always the ones the caller
            // wants most.
            var kept: [String] = []
            var bytes = 0
            for line in lines.reversed() {
                bytes += line.utf8.count + 1
                if bytes > ControlCaptureLimits.maxBytes { break }
                kept.append(line)
            }
            lines = kept.reversed()
            text = lines.joined(separator: "\n")
            truncated = true
            // What survives is the **last** N lines = the viewport lines plus a short stretch of
            // history right above them. `min(original history line count, total line count)` would
            // count the viewport lines as history too (in the extreme it reports
            // scrollback == lines, so "viewport = lines - scrollback" comes out as 0). The
            // remaining history can only be "lines kept minus viewport lines".
            scrollbackLines = max(0, lines.count - viewportLines)
        }
        return Capture(text: text, lines: lines.count,
                       scrollbackLines: scrollbackLines, truncated: truncated)
    }

    /// Strip trailing whitespace (the terminal pads every line out with spaces), but **do not drop
    /// a single line** - a blank line in the middle is part of the output, and erasing it means
    /// what comes back is no longer what is on screen. Only the run of completely empty lines at
    /// the very end is cut (the blank screen below the prompt)
    static func trimmed(_ raw: String) -> [String] {
        var lines = raw.components(separatedBy: "\n").map {
            String($0.reversed().drop { $0 == " " || $0 == "\t" }.reversed())
        }
        while let last = lines.last, last.isEmpty { lines.removeLast() }
        return lines
    }
}

extension Ghostty.SurfaceView {
    /// Read a stretch of text out of the engine (`GHOSTTY_POINT_VIEWPORT` = the viewport,
    /// `GHOSTTY_POINT_SCREEN` = including scrollback). The memory `ghostty_surface_read_text`
    /// allocates has to be handed back to the engine (`free_text`), hence the defer here
    func controlReadText(tag: ghostty_point_tag_e) -> String? {
        guard let surface else { return nil }
        var text = ghostty_text_s()
        let selection = ghostty_selection_s(
            top_left: ghostty_point_s(tag: tag, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0),
            bottom_right: ghostty_point_s(tag: tag, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0),
            rectangle: false)
        guard ghostty_surface_read_text(surface, selection, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }
        // On an empty screen the engine can hand back a null pointer: feeding nil to
        // `String(cString:)` crashes on the spot, and "there is nothing on screen" is a perfectly
        // normal answer.
        guard let pointer = text.text else { return "" }
        return String(cString: pointer)
    }
}
