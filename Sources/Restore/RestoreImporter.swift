import Darwin
import Foundation
import GhosttyKit

/// **Launch-time import of a pane's previous output** (session restore, spec decisions 5, 6, 20).
///
/// A pane decoded from the session archive takes its content file (read once: the store deletes
/// it before decrypting), and the engine receives that content as program output, followed by
/// one dim, localized marker line, so the old text sits above the fresh shell and is never read
/// as new output. When the pane offered an agent resume but its directory is gone, one more line
/// says the conversation cannot be resumed here.
@MainActor
enum RestoreImporter {
    private static let reset = "\u{1b}[0m"
    private static let dim = "\u{1b}[2m"

    /// The take half, run before the surface exists: the file is deleted here, so whatever is fed
    /// later can never be fed again by a launch that crashes on the way. nil means feed nothing.
    ///
    /// Ruling: with `[restore] content = false` nothing reaches the screen, not even the
    /// directory line; a stray file is still removed so no content outlives the launch.
    static func restoredOutput(pane: UUID, store: RestoreStore, contentEnabled: Bool,
                               directoryGone: Bool, now: Date = Date()) -> Data? {
        guard contentEnabled else {
            store.remove(pane: pane)
            return nil
        }
        return payload(content: store.take(pane: pane), restoredAt: now, directoryGone: directoryGone)
    }

    /// The bytes fed to the engine: the content, then a reset and a new line (so a colour run cut
    /// by the export's byte cap cannot leak, and the marker never joins the content's last line),
    /// the dim marker and a new line, then the directory-gone line when set. nil when there is
    /// neither content nor a line to show.
    static func payload(content: Data?, restoredAt: Date, directoryGone: Bool) -> Data? {
        let content = content.flatMap { $0.isEmpty ? nil : $0 }
        guard content != nil || directoryGone else { return nil }
        var out = content ?? Data()
        out.append(Data(reset.utf8))
        if content != nil { out.append(Data("\r\n".utf8)) }
        out.append(Data("\(dim)\(RestoreText.marker(restoredAt))\(reset)\r\n".utf8))
        if directoryGone { out.append(Data("\(RestoreText.directoryGone)\r\n".utf8)) }
        return out
    }

    /// Feed `payload` through the engine's pty-output path (engine patch 0003). The engine takes
    /// its renderer lock itself.
    static func feed(_ payload: Data, into surface: ghostty_surface_t) {
        payload.withUnsafeBytes { raw in
            // An empty buffer's base address can be nil: there is nothing to feed then.
            guard let base = raw.baseAddress, raw.count > 0 else { return }
            ghostty_surface_import_output(surface, base.assumingMemoryBound(to: CChar.self),
                                          UInt(raw.count))
        }
    }

    /// Spec decision 20, ruling 4: the line shows only for a pane that had an agent to resume and
    /// whose saved directory no longer exists. Only "no such file" (or a non-directory) counts as
    /// gone: a protected directory that refuses access still exists.
    static func directoryGone(saved: String?, hasAgentRecord: Bool) -> Bool {
        guard hasAgentRecord, let saved, !saved.isEmpty else { return false }
        var info = stat()
        if stat(saved, &info) != 0 { return errno == ENOENT || errno == ENOTDIR }
        return (info.st_mode & S_IFMT) != S_IFDIR
    }
}

/// The session-restore UI strings, read through the catalog (`Restore.strings`).
@MainActor
enum RestoreText {
    /// The restore time as month, day, hours and minutes in the user's time zone, ordered and
    /// punctuated for the language the UI is drawn in (`[general] language`), not the system
    /// locale: the marker's words come from that language's catalog, and the date must match them.
    static func time(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: Localization.shared.language.lprojName)
        formatter.timeZone = .autoupdatingCurrent
        formatter.setLocalizedDateFormatFromTemplate("MMddHHmm")
        return formatter.string(from: date)
    }

    /// `─── Restored 10-29 09:46 ───`
    static func marker(_ date: Date) -> String { L("restore.marker", time(date)) }

    static var directoryGone: String { L("restore.directory-gone") }

    /// The resume button in the pane's agent band (Task 6). `agent` is the agent's display name.
    static func resumeButton(agent: String) -> String { L("restore.resume.button", agent) }

    /// The resume button when no session id is known: the agent's `latest` form.
    static func resumeLatest(agent: String) -> String { L("restore.resume.latest", agent) }

    /// The resume button's tooltip.
    static var resumeHelp: String { L("restore.resume.help") }
}
