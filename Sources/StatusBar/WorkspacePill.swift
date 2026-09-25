import AppKit
import SwiftUI

/// **Layout math** for the workspace pills in the status bar (`StatusBarView` does the drawing).
///
/// It lives here as pure functions for the same reason as `PaneTitleBadge`: a view cannot measure
/// "does not fit". The status bar has three sections - on the left the logo, the pills and the
/// control-plane flash; in the middle the clock (centered independently in a ZStack, unaffected by
/// either side's width); on the right the update indicator (when there is one), cpu / network / volume / battery. The moment the pills start
/// showing names the left section gets longer, and when it grows far enough to run into the clock
/// SwiftUI does not complain: it squeezes and truncates the `Text`, and the whole bar looks broken.
/// So "does it fit" has to be answered before anything is drawn, and answered for **the whole row
/// at once**: half names and half numbers just reads as a bug.
enum WorkspacePill {
    /// A name is at most 12 grapheme clusters, with the truncating `…` counted inside those 12
    /// (`TitleRules.clamp`, the same counting rule pane titles use, only with a different limit:
    /// a pill sits in a 26pt status bar next to a centered clock, a pane border does not).
    static let maxCharacters = 12

    /// The status bar's Monaco 12. Monaco ships with the system; if it really cannot be had (the
    /// font was disabled) this falls back to the monospaced system font. What matters is that the
    /// font used to measure and the font used to draw are the same one - otherwise the measured
    /// width proves nothing - so `pill` uses this font directly instead of spelling out
    /// `.custom("Monaco", size: 12)` a second time.
    static let font: NSFont = NSFont(name: "Monaco", size: 12)
        ?? .monospacedSystemFont(ofSize: 12, weight: .regular)

    /// Width of a number or `■` pill (exactly as it looks today, not one point different).
    static let plainWidth: CGFloat = 18
    /// A named pill gets a little padding on each side: pills are only 3pt apart, and without it
    /// two names blur into one.
    static let titlePadding: CGFloat = 4
    /// Between pills.
    static let spacing: CGFloat = 3
    /// Between the logo, the pill group and the control-plane flash (= the spacing of
    /// `leftSection`'s HStack).
    static let sectionSpacing: CGFloat = 8
    /// The control-plane flash's own horizontal padding.
    static let flashPadding: CGFloat = 6
    /// The minimum air left between the left section and the clock. It also absorbs measurement
    /// error: what is measured here is an `NSAttributedString`'s width, while SwiftUI's layout
    /// rounds each piece up by a fraction of a point of its own.
    static let clearance: CGFloat = 8

    static func width(of text: String) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: font]).width
    }

    /// Truncate to 12 characters; an unnamed slot (nil, empty, or all whitespace) gives nil.
    /// The counting rule is the shared one (`TitleRules.clamp`); only the 12 is this surface's own.
    static func clamped(_ title: String?) -> String? {
        title.flatMap { TitleRules.clamp($0, to: maxCharacters) }
    }

    /// What gets drawn on this slot **before the notice count**: the name, if the slot has one and
    /// the row is showing names; otherwise the old look - `■` for the active one, the index for the
    /// rest.
    static func baseLabel(title: String?, index: Int, active: Bool, showingTitles: Bool) -> String {
        if showingTitles, let name = clamped(title) { return name }
        return active ? "■" : "\(index + 1)"
    }

    /// The `●N` term: how many panes of this workspace hold a live `needsUser` notice (design
    /// §3.5, "Workspace pill"). Empty at zero - a workspace nobody is waiting on says nothing.
    ///
    /// Not a localized string: it is a dot and a number, identical in both languages. What *is*
    /// localized is the accessibility label (`StatusBarView`), because "●2" read aloud is noise.
    static func countSuffix(_ count: Int) -> String { count > 0 ? " ●\(count)" : "" }

    /// The whole label: `dev ●2` / `3 ●1` / `dev` / `3`.
    static func label(title: String?, index: Int, active: Bool, showingTitles: Bool,
                      count: Int = 0) -> String {
        baseLabel(title: title, index: index, active: active, showingTitles: showingTitles)
            + countSuffix(count)
    }

    /// How wide one pill is: a named pill is the text width plus padding on both sides, a numbered
    /// pill is always those 18pt.
    ///
    /// **The nesting order has to match `pill` exactly**: over there `padding` wraps
    /// `frame(minWidth:)`, so the 18pt floor applies to the text alone and the padding is added
    /// outside it. Written as `max(18, textWidth + 8)` it becomes a different shape: narrow names
    /// like a single letter or a single CJK character under-count by up to 8pt per pill, while the
    /// whole row only has `clearance`'s 8pt of slack - five pills like that are enough to push the
    /// names onto the clock.
    ///
    /// A pill carrying a notice count is measured the same way a named one is, **even when the row
    /// is drawing numbers**: `3 ●1` is wider than those 18pt, and a count that is not in the budget
    /// is a count that shoves the last pill under the clock.
    static func pillWidth(title: String?, index: Int, active: Bool, showingTitles: Bool,
                          count: Int = 0) -> CGFloat {
        let text = label(title: title, index: index, active: active,
                         showingTitles: showingTitles, count: count)
        guard (showingTitles && clamped(title) != nil) || count > 0 else { return plainWidth }
        return max(plainWidth, width(of: text)) + 2 * titlePadding
    }

    /// The text on a pill **itself** (color and click handling are `StatusBarView`'s job).
    ///
    /// The layout layer is written only here: the width is computed in this file, and every extra
    /// equivalent modifier chain is one more chance for "measured and drawn disagree" - `pillWidth`
    /// corresponds to this one to one, and the test lays both out for real and compares them
    /// (`testPillWidthMatchesTheLaidOutPill`).
    ///
    /// The `●N` is the one part with a colour of its own (`theme.alert`, passed in so this file
    /// still measures and draws without an environment): the base keeps whatever the caller set,
    /// so an active pill stays accent and an inactive one stays foreground. Concatenating two
    /// `Text`s rather than stacking two views is what keeps the drawn width equal to
    /// `width(of: label)` - an `HStack` would add its own spacing to one side of the budget only.
    static func pill(title: String?, index: Int, active: Bool, showingTitles: Bool,
                     count: Int = 0, countColor: Color = Palette.alert) -> some View {
        let named = showingTitles && clamped(title) != nil
        let base = baseLabel(title: title, index: index, active: active, showingTitles: showingTitles)
        return (Text(base) + Text(countSuffix(count)).foregroundStyle(countColor))
            // If a newline gets into a name (pasted, or hand-edited into the saved state), `Text`
            // dutifully lays it out on two lines: the status bar's 26pt height is hard-coded, and
            // the second line pushes the text straight out past the background.
            .lineLimit(1)
            // This is the very `font` the width was measured with. Written as
            // `.custom("Monaco", size: 12)`, the two sides fall back to different fonts when Monaco
            // is disabled, and the measured width proves nothing.
            .font(Font(font))
            .frame(minWidth: plainWidth, minHeight: 20)
            .padding(.horizontal, named || count > 0 ? titlePadding : 0)
    }

    /// How wide the whole left section is (logo + pills + control-plane flash).
    ///
    /// `counts` is indexed in parallel with `titles`; a short array simply means "no count there",
    /// which is what lets every existing caller stay as it is.
    static func leftSectionWidth(titles: [String?], activeIndex: Int, showingTitles: Bool,
                                 flash: String?, counts: [Int] = []) -> CGFloat {
        var out = width(of: "◆")
        for index in titles.indices {
            out += (index == 0 ? sectionSpacing : spacing)
                + pillWidth(title: titles[index], index: index,
                            active: index == activeIndex, showingTitles: showingTitles,
                            count: counts.indices.contains(index) ? counts[index] : 0)
        }
        if let flash { out += sectionSpacing + width(of: flash) + 2 * flashPadding }
        return out
    }

    /// **Whether** this row of pills may show names (all of them or none).
    ///
    /// The test: the left section must not reach into the clock. The clock is dead center in the
    /// content area, so its left edge is `contentWidth / 2 − clockWidth / 2` - a number that can
    /// be computed, not estimated.
    /// The stats on the right sit on the far side of the clock, and the left section cannot reach
    /// them; if it ever could, the right section would itself be wider than half the bar, which is
    /// a separate problem that already crowds the bar today without any names involved.
    /// When the content width has not been measured yet (the first frame's `GeometryReader` hands
    /// back 0) this answers "does not fit": better for the names to appear one frame late than to
    /// draw one broken frame first.
    /// The counts are part of the budget, and deliberately so: they are drawn whether the row
    /// shows names or numbers (an alarm is not decoration), so a workspace waiting on the user
    /// makes the names give way one pill sooner. The row still falls back all together.
    static func showsTitles(contentWidth: CGFloat, titles: [String?], activeIndex: Int,
                            clockWidth: CGFloat, flash: String?, counts: [Int] = []) -> Bool {
        guard contentWidth > 0, titles.contains(where: { clamped($0) != nil }) else { return false }
        let left = leftSectionWidth(titles: titles, activeIndex: activeIndex,
                                    showingTitles: true, flash: flash, counts: counts)
        return left <= contentWidth / 2 - clockWidth / 2 - clearance
    }
}
