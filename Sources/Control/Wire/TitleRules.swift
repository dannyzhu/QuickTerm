import Foundation

/// **The one rulebook for titles** — pane titles and workspace names both.
///
/// There is only one story here, and before this file it was told in nine places: the C0/DEL/C1
/// predicate was written out longhand in `ControlPaneCommands`, again as `WorkspaceModel`'s own
/// scalar test, and a third time inside `WorkspaceSpec`'s validator; the 200-character ceiling was
/// a constant on `ControlCommandRunner` *and* a constant on `SpecLimits`, held together by a test
/// that only asserted the two numbers were equal; and "trim, empty means no title" was open-coded
/// wherever someone happened to need it. Nine copies do not stay in step — the pane rename sheet
/// proves it, having shipped with no filter and no cap at all while the workspace dialog next to it
/// was fixed.
///
/// This file lives in `Sources/Control/Wire`, which is compiled into **both** the app and the
/// `quickterm` tool target — that is why it may only `import Foundation`, and also why the rule can
/// live in exactly one place: the CLI validates a spec offline with the same predicate the app
/// enforces at the command layer.
///
/// What is deliberately **not** here: the display caps. The title on a pane border stops at 20
/// characters (`PaneTitleBadge.maxCharacters`) and a workspace pill at 12
/// (`WorkspacePill.maxCharacters`); two surfaces of different widths, correctly different numbers.
/// `clamp` takes the limit as an argument precisely so neither one can quietly adopt the other's.
enum TitleRules {
    /// How long a title may be, counted in **grapheme clusters** (one CJK ideograph or one ZWJ
    /// emoji = 1). A title goes into the window title bar, the status bar and every single `state`
    /// response; an agent stuffing a whole log line into one is a thing that happens.
    ///
    /// The command layer **refuses** anything longer (a program is calling, and it should be told
    /// it got it wrong); a dialog **truncates** instead (see `fromTypedInput`) — a person who
    /// pasted too much does not deserve an error sheet.
    static let maxLength = 200

    /// The truncation marker. It **counts against the limit** it is added for, so clamping to 20
    /// yields 19 real characters plus this one — the alternative is a string that is one cell wider
    /// than the caller budgeted for, and the border gap is drawn from that budget.
    static let ellipsis = "…"

    /// Whether this scalar belongs in a title: everything except C0 (newline and tab included),
    /// DEL, and C1.
    ///
    /// Not cosmetic. A newline in a workspace name makes SwiftUI lay the pill out over two lines,
    /// and the status bar's 26pt height is hard-coded, so the second line is drawn straight through
    /// the background; an ESC in a pane title is a terminal escape sequence being echoed back into
    /// a title bar.
    static func isPrintable(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value >= 0x20 && scalar.value != 0x7F && !(0x80...0x9F).contains(scalar.value)
    }

    /// The same rule applied to a whole string — what every `--title` validator asks.
    static func isPrintable(_ text: String) -> Bool {
        text.unicodeScalars.allSatisfy(isPrintable)
    }

    /// The canonical form of a title: surrounding whitespace stripped, and **nothing left means no
    /// title at all** (nil).
    ///
    /// This is what makes `--title "   "` mean "hand it back" rather than "pin an invisible title
    /// the shell can never update again", and it is the form both sides of an idempotency check
    /// have to be in — otherwise `--title "dev"` followed by `--title " dev "` reports a change
    /// that never happened.
    static func normalized(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }

    /// Truncate for **display** to `limit` grapheme clusters, ellipsis counted inside the limit;
    /// nil when there is nothing to show.
    ///
    /// Grapheme clusters, not UTF-16 units and not bytes: one Han character is one cell to the
    /// counting rule (its *pixel* width is a separate question, and only the pane border has to ask
    /// it a second time — a pill grows to fit itself).
    /// `limit < 2` cannot be honored at all (there is no room for a character plus the ellipsis),
    /// so an over-long title with such a limit gives nothing rather than a bare `…`.
    static func clamp(_ title: String, to limit: Int) -> String? {
        guard let trimmed = normalized(title) else { return nil }
        let chars = Array(trimmed)   // Character = grapheme cluster; CJK and emoji count as one
        guard chars.count > limit, limit >= 2 else { return chars.count <= limit ? trimmed : nil }
        return String(chars.prefix(limit - 1)) + ellipsis
    }

    /// What a rename dialog does to a typed or pasted string: drop the characters that cannot be in
    /// a title, trim, and cut to `maxLength`.
    ///
    /// **A dialog filters where the command line refuses.** Both rename sheets (Cmd+click a
    /// workspace pill, "Change Terminal Title" on a pane) run a person's keystrokes through here,
    /// so an empty result is a real answer — it means "hand the title back", exactly what
    /// `--title ""` means on the command line.
    /// The final `normalized` is not redundant: the cut can land on a space, and a title with a
    /// trailing space is one the next idempotency check would call a difference.
    static func fromTypedInput(_ raw: String) -> String {
        let printable = String(String.UnicodeScalarView(raw.unicodeScalars.filter(isPrintable)))
        guard let trimmed = normalized(printable) else { return "" }
        return normalized(String(trimmed.prefix(maxLength))) ?? ""
    }
}
