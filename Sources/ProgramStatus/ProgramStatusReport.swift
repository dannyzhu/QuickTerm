import Foundation
import GhosttyKit

/// **One OSC 7501 report, as the app holds it** (spec decisions 1 and 2).
///
/// The engine (patch 0005) has already parsed the sequence and enforced every limit and
/// control-character rule before it hands over a `ghostty_action_program_status_s`; a report that
/// broke any of them never arrives. This type is the Swift copy of that C struct, taken during the
/// callback (the C strings are valid only until it returns), with "absent" spelled as nil rather
/// than as an empty string or -1.
struct ProgramStatusReport: Equatable {
    enum State: String { case idle, working, done, blocked, error, clear }
    enum Kind: String { case permission, question, auth }

    var state: State
    /// Only meaningful with `blocked`; nil when absent or not one of the three kinds.
    var kind: Kind?
    /// 0–100, or nil.
    var progress: Int?
    /// The record's path, `build/test` → `["build", "test"]`. Empty = the pane's root record.
    var id: [String]
    var app: String?
    /// The program's own words, already base64-decoded. **Not yet safe to draw**: run them through
    /// `displayText` first.
    var title: String?
    var message: String?

    /// The Swift copy of the engine's report, or nil when the state is not one of the six.
    ///
    /// The engine already drops an unknown state; checking again here costs nothing, and it means
    /// a future engine path that forgot to validate cannot put a record nobody can rank into the
    /// store.
    static func from(_ c: ghostty_action_program_status_s) -> ProgramStatusReport? {
        guard let rawState = text(c.state), let state = State(rawValue: rawState) else { return nil }
        let progress = Int(c.progress)
        return ProgramStatusReport(
            state: state,
            kind: text(c.kind).flatMap(Kind.init(rawValue:)),
            progress: (0...100).contains(progress) ? progress : nil,
            id: text(c.id)?.split(separator: "/").map(String.init) ?? [],
            app: text(c.app),
            title: text(c.title),
            message: text(c.msg))
    }

    /// A C string from the engine as Swift text: nil for a null pointer, an empty string (the
    /// engine's "absent") or bytes that are not UTF-8.
    private static func text(_ pointer: UnsafePointer<CChar>?) -> String? {
        guard let pointer, pointer.pointee != 0 else { return nil }
        return String(validatingCString: pointer)
    }

    // MARK: Display

    /// A program's `title` or `msg`, made safe for the one-line band (spec decision 15).
    ///
    /// Unicode format characters (General_Category Cf) are removed: bidirectional embeddings,
    /// overrides and isolates (U+202A–U+202E, U+2066–U+2069) would let a program reorder the rest
    /// of the band, and zero-width characters (U+200B–U+200F, U+2060–U+2064, U+FEFF) hide text.
    /// Two Cf scalars are kept where an emoji needs them: U+200D ZERO WIDTH JOINER between two
    /// emoji (👨‍👩‍👧), and the tag characters U+E0020–U+E007F after an emoji (subdivision
    /// flags). Line and paragraph separators become spaces. The result then goes through the same
    /// rulebook and clamp the band applies to an agent's message (`TitleRules.fromTypedInput`:
    /// control characters out, trimmed, at most `TitleRules.maxLength` grapheme clusters).
    static func displayText(_ s: String) -> String {
        let scalars = Array(s.unicodeScalars)
        var kept = String.UnicodeScalarView()
        for (index, scalar) in scalars.enumerated() {
            switch scalar.properties.generalCategory {
            case .lineSeparator, .paragraphSeparator:
                kept.append(" ")
            case .format:
                if scalar == zeroWidthJoiner {
                    let next = index + 1 < scalars.count ? scalars[index + 1] : nil
                    if endsEmoji(kept), let next, isEmojiScalar(next) { kept.append(scalar) }
                } else if isTag(scalar), endsEmoji(kept) {
                    kept.append(scalar)
                }
            default:
                kept.append(scalar)
            }
        }
        return TitleRules.fromTypedInput(String(kept))
    }

    private static let zeroWidthJoiner: Unicode.Scalar = "\u{200D}"

    /// An emoji in its own right. `isEmoji` alone is also true for the ASCII digits, `#` and
    /// `*` (they have keycap forms), and a joiner between two digits joins nothing.
    private static func isEmojiScalar(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value > 0x7F && scalar.properties.isEmoji
    }

    private static func isTag(_ scalar: Unicode.Scalar) -> Bool {
        (0xE0020...0xE007F).contains(scalar.value)
    }

    /// Whether the text kept so far ends inside an emoji: an emoji, or one followed by the
    /// scalars that may trail it before a joiner or a tag — variation selectors, skin-tone
    /// modifiers and tags.
    private static func endsEmoji(_ kept: String.UnicodeScalarView) -> Bool {
        for scalar in kept.reversed() {
            if isEmojiScalar(scalar) { return true }
            let trails = (0xFE00...0xFE0F).contains(scalar.value)
                || scalar.properties.isEmojiModifier
                || isTag(scalar)
            if !trails { return false }
        }
        return false
    }
}

/// **Where the engine's OSC 7501 actions enter the app** (spec decisions 3, 5 and 20).
///
/// The one gate is `[agents] program-status`: with it off, no report, prompt start or reset
/// reaches the store, so nothing is kept and nothing is shown (the engine still answers the
/// feature query on its own). `AppSession.applyGlobalConfig` pushes the switch here on every
/// config load, the same way the notice centre and the agent registry get theirs. Switching it
/// off also drops every record already kept: off means nothing is shown (decision 20).
@MainActor
enum ProgramStatusRouter {
    static var isEnabled = true {
        didSet {
            if oldValue && !isEnabled { ProgramStatusStore.shared.removeAll() }
        }
    }

    static func report(_ report: ProgramStatusReport, pane: UUID, foregroundGroup: Int32?) {
        guard isEnabled else { return }
        ProgramStatusStore.shared.receive(report, pane: pane, foregroundGroup: foregroundGroup)
    }

    static func promptStarted(pane: UUID) {
        guard isEnabled else { return }
        ProgramStatusStore.shared.promptStarted(pane: pane)
    }

    static func reset(pane: UUID) {
        guard isEnabled else { return }
        ProgramStatusStore.shared.reset(pane: pane)
    }

    /// `ghostty_surface_foreground_pgid` as an optional: the engine answers -1 when it has no pty
    /// (or `tcgetpgrp` failed), and 0 is not a process group anybody runs in.
    nonisolated static func processGroup(_ raw: Int32) -> Int32? {
        raw > 0 ? raw : nil
    }

    /// Run `body` on the main actor: inline when the engine called on the main thread (it does;
    /// its tick is dispatched there), otherwise one hop to the main queue. Anything taken from the
    /// engine's C structs has to be copied **before** this is called.
    nonisolated static func onMain(_ body: @escaping @MainActor () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated(body)
        } else {
            DispatchQueue.main.async { MainActor.assumeIsolated(body) }
        }
    }
}
