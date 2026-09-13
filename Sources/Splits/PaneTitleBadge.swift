import AppKit

/// **Layout math** for the title that rides on a pane's top border (`PaneChrome` does the drawing).
///
/// It lives here as pure functions because several rules are tangled together: a 20-character cap,
/// never running past the top-right corner, leaving at least two characters' worth of line for the
/// border on the right, and actually sitting on that 2px line. A view cannot measure "does not
/// fit" - `Text` truncates on its own, wraps on its own, and will park the `…` in the last cell,
/// at which point the "gap in the border" and "the glyphs actually drawn" no longer agree. Only by
/// pinning down the exact string together with its placement up front can the gap be drawn
/// accurately - and tested.
enum PaneTitleBadge {
    /// At most 20 characters, counted in **grapheme clusters**: one CJK ideograph, or one emoji
    /// (even a ZWJ sequence), each count as 1. The ellipsis added when truncating **counts against
    /// those 20**, so a 30-character title is drawn as 19 characters + `…`.
    ///
    /// This number is the border's own: a workspace pill stops at 12 (`WorkspacePill`). Only the
    /// **counting rule** is shared, and it lives in `TitleRules.clamp`.
    static let maxCharacters = 20

    /// Border line width (the same on all four edges; vertically the title rides on the center of
    /// this line).
    static let lineWidth: CGFloat = 2

    struct Metrics: Equatable {
        let font: NSFont
        /// Distance from the outer edge of the pane's left border to the start of the text.
        let leadingInset: CGFloat
        /// How much wider the gap is than the text on each side, so the first and last glyph do
        /// not touch the cut ends of the line.
        let sidePadding: CGFloat
        /// Length of border that has to survive on the right, measured in "characters".
        let reservedCharacters: Int

        /// What "one character wide" means here: a proportional font has no single glyph width, so
        /// this takes the advance width of the digit `0`. Digits in the UI font are tabular (tables
        /// have to line up) and wider than most lowercase letters, which makes `0` both a definite
        /// and a conservative stand-in for "a character" - the reserved line only ever comes out
        /// longer than two real characters.
        var characterWidth: CGFloat { width(of: "0") }

        /// Height of the badge's single line (needed to center it vertically).
        var lineHeight: CGFloat {
            ("0" as NSString).size(withAttributes: [.font: font]).height
        }

        /// Distance from the top of a single-line `Text` box to the baseline: the box is
        /// `lineHeight` tall and the baseline sits at half-leading + ascender
        /// (half-leading = (line height − font height) / 2).
        var baselineInset: CGFloat {
            (lineHeight - (font.ascender - font.descender)) / 2 + font.ascender
        }

        /// Distance from the top of the box to the top of a capital letter. Deciding whether the
        /// line really passes through the glyphs requires this - the top of the box is not the top
        /// of the ink: the 3-odd points above it are empty (half-leading, plus the part of the
        /// ascender no glyph reaches). Measuring from the box top judges even the default
        /// `pane-gap = 5` as "does not fit", which kills the whole feature.
        var capTopInset: CGFloat { baselineInset - font.capHeight }

        func width(of text: String) -> CGFloat {
            (text as NSString).size(withAttributes: [.font: font]).width
        }

        /// The same small UI weight the status bar uses; 10pt on a 2px line is present without
        /// shouting.
        static let standard = Metrics(font: .systemFont(ofSize: 10, weight: .medium),
                                      leadingInset: 8, sidePadding: 4, reservedCharacters: 2)
    }

    /// The title on the top border for this frame: which glyphs, where they go, and where the
    /// border is bitten open.
    /// nil (`place` returning nothing) means **draw the whole border unbroken, as usual**.
    struct Placement: Equatable {
        /// The string actually drawn, after truncation.
        let text: String
        /// Vertical offset of the `Text` box's top-left corner from the pane's top-left corner (the
        /// outer edge of the border), positive downward.
        let offsetY: CGFloat
        /// The gap in the top border, relative to the outer edge of the pane's left border.
        let gapStart: CGFloat
        let gapEnd: CGFloat
    }

    /// Maximum width the text may take on the top border.
    /// The right edge of the gap = leading inset + text width + a little padding; what lies between
    /// it and the top-right corner is the stretch of line that has to survive, and that must be
    /// >= two characters wide - which leaves exactly this much for the text.
    static func availableTextWidth(topEdgeWidth: CGFloat, metrics: Metrics = .standard) -> CGFloat {
        topEdgeWidth - metrics.leadingInset - metrics.sidePadding
            - CGFloat(metrics.reservedCharacters) * metrics.characterWidth
    }

    /// Pure function: the string to draw on the top border this frame; nil when not a single
    /// character fits (or there was no title to begin with).
    /// nil means **draw the whole border unbroken**, not an empty notch or a lone ellipsis.
    static func fit(title: String, topEdgeWidth: CGFloat, metrics: Metrics = .standard) -> String? {
        guard let capped = TitleRules.clamp(title, to: maxCharacters) else { return nil }
        let available = availableTextWidth(topEdgeWidth: topEdgeWidth, metrics: metrics)
        guard available > 0 else { return nil }
        if metrics.width(of: capped) <= available { return capped }

        // The character count is fine but the pixels are not: back off one cell at a time.
        // `content` is the number of characters **excluding** the ellipsis, so content + 1
        // characters get drawn and the loop starts exactly at the cap of 20. Stop before nothing
        // but the ellipsis is left - a lone `…` occupying the border says nothing, and a complete
        // line is better than that.
        let chars = Array(capped)   // already <= 20 clusters (truncation ellipsis included)
        for content in stride(from: chars.count - 1, through: 1, by: -1) {
            let candidate = String(chars.prefix(content)) + TitleRules.ellipsis
            if metrics.width(of: candidate) <= available { return candidate }
        }
        return nil
    }

    /// Vertical placement: the `Text` box's offset from the outer edge of the top border; **nil
    /// when there is no room above it, meaning no title this frame**.
    ///
    /// The trap: a pane slot is clipped to the slot, so the only space to borrow outside the border
    /// is its own ring of pane-gap (`overhang`). With gaps turned off (Cmd+Shift+Backspace, or
    /// `app set --gaps off`) or `pane-gap = 0` there is nothing to borrow at all, and the text
    /// drops entirely below the line onto the terminal's first row while the border still has an
    /// empty notch bitten out of it - exactly what "the text must not escape the top frame line"
    /// exists to forbid. So when there is nothing to borrow, draw nothing; the test is that **the
    /// center of the line has to land inside the glyph body (cap height)**: the line has to pass
    /// through the text for it to count as riding on it.
    static func verticalOffset(overhang: CGFloat, metrics: Metrics = .standard) -> CGFloat? {
        let centred = lineWidth / 2 - metrics.lineHeight / 2   // box center on line center
        let offset = max(-overhang, centred)                   // can't borrow that much: shift down
        guard offset + metrics.capTopInset <= lineWidth / 2 else { return nil }
        return offset
    }

    /// The stretch bitten out of the top border, relative to the outer edge of the pane's left
    /// border. What you pass in has to be the string `fit` produced.
    static func gapRange(for text: String,
                         metrics: Metrics = .standard) -> (start: CGFloat, end: CGFloat) {
        (max(0, metrics.leadingInset - metrics.sidePadding),
         metrics.leadingInset + metrics.width(of: text) + metrics.sidePadding)
    }

    /// The one entry point: text, placement and gap all computed in a single pass.
    /// Gap and text have to come out of the same decision - decided in two places you get "the
    /// border is bitten open, but the text was never drawn / dropped below the line".
    static func place(title: String?, topEdgeWidth: CGFloat, overhang: CGFloat,
                      metrics: Metrics = .standard) -> Placement? {
        guard let title,
              let offsetY = verticalOffset(overhang: overhang, metrics: metrics),
              let text = fit(title: title, topEdgeWidth: topEdgeWidth, metrics: metrics)
        else { return nil }
        let gap = gapRange(for: text, metrics: metrics)
        return Placement(text: text, offsetY: offsetY, gapStart: gap.start, gapEnd: gap.end)
    }
}
