import SwiftUI

/// Omarchy look (spec §1.1/§4.2): a 2px border (focused = accent #7aa2f7 / unfocused = grey
/// 0x59 @ 67%), gaps_in semantics (pane-gap on every side of every pane, default 5: adjacent panes
/// compose to 10, and the outer ring uses the same value so it composes to 10 too - left, middle
/// and right gaps come out equal, and scrolling / dwindle / floating all agree), square corners,
/// and an 87% popin animation. The focus state follows hover with no delay.
struct PaneChrome: ViewModifier {
    @ObservedObject var surfaceView: PaneView
    /// Floating-layer pane: no frosted backdrop when inactive. What sits behind it is the content
    /// of the tiled panes below, not the wallpaper, and smearing the HUD material over that comes
    /// out nearly opaque. Skipping it leaves the floating pane at 0.92 alpha, same as a tiled one.
    var floating: Bool = false
    @EnvironmentObject var theme: ThemeManager
    @State private var appeared: Bool

    /// Surfaces that have already played the popin: a view remounted by a layout change must not
    /// replay it, or the whole screen "flashes" at once.
    private static var popped = Set<UUID>()

    init(surfaceView: PaneView, floating: Bool = false) {
        self.surfaceView = surfaceView
        self.floating = floating
        _appeared = State(initialValue: Self.popped.contains(surfaceView.id))
    }

    private var borderColor: Color { surfaceView.focused ? theme.accent : Palette.inactiveBorder }
    /// The title and the border are **not the same color**: focused, both use the accent (bright
    /// enough); unfocused, the line stays dim as before but the text gets its own brighter shade -
    /// half of each glyph sits on wallpaper outside the border, and dimming the text along with
    /// the line makes it unreadable.
    private var titleColor: Color { surfaceView.focused ? theme.accent : Palette.inactiveTitle }

    /// The title drawn on the top border: **only an explicitly set one counts** (right-click
    /// "Change Terminal Title", or `pane set --title` from the control plane). What the shell
    /// reports over OSC does not - that changes on every command you type, and the border would
    /// judder along with it. The master switch is the `pane-title` config key.
    private var titleOnFrame: String? {
        theme.paneTitleEnabled ? surfaceView.customTitle : nil
    }

    func body(content: Content) -> some View {
        content
            // Inactive pane: back it with an in-window backdrop blur - what gets frosted is the
            // wallpaper showing through, and the text stays sharp.
            // Active pane: no backdrop = clear glass, with the wallpaper crisp behind it.
            .background {
                if surfaceView.focused {
                    // Active = clear glass, only more solid (composited to active-opacity,
                    // default 0.98)
                    theme.background.opacity(theme.activeUnderlayAlpha)
                } else if theme.frostedInactive, !floating {
                    // Inactive = frosted glass (the backdrop blurs the wallpaper, text stays sharp)
                    VisualEffectBlur()
                }
            }
            // No more `.border`: the title has to bite a gap out of the top border the way a
            // fieldset legend does, so all four edges are drawn by hand (pixel for pixel identical
            // to the old 2px square-cornered border).
            .overlay { PaneFrame(color: borderColor, titleColor: titleColor,
                                 title: titleOnFrame, overhang: overhang) }
            // pane-gap of breathing room on every side (the same in both layouts)
            .padding(theme.gapsEnabled ? theme.paneGap : 0)
            .scaleEffect(appeared ? 1 : 0.87)
            .opacity(appeared ? 1 : 0)
            .onAppear {
                guard !appeared else { return }
                Self.popped.insert(surfaceView.id)
                withAnimation(.easeOut(duration: 0.2)) { appeared = true }
            }
    }

    /// How far the title may stick out above the border: the enclosing slot is `.clipped()`, so
    /// the only space outside the border is that one ring of pane-gap.
    private var overhang: CGFloat { theme.gapsEnabled ? theme.paneGap : 0 }
}

/// The pane's four edges plus the title riding on the top one. The stretch of border behind the
/// title is broken open, like a fieldset legend. When focus changes, line and text change color
/// together so it still reads as one frame; unfocused, the text is one notch brighter than the
/// line (see `PaneChrome.titleColor`: half of it sits on wallpaper outside the border).
private struct PaneFrame: View {
    let color: Color
    /// Title color (see `PaneChrome.titleColor`: one notch brighter than the border when
    /// unfocused)
    let titleColor: Color
    /// The raw title to show. How far it is truncated, where it is drawn and which stretch of
    /// border is broken are all computed in `PaneTitleBadge`; nil, or a title that turns out not
    /// to fit, means draw the full unbroken border.
    let title: String?
    /// How much space can be borrowed above the top border (= pane-gap). With nothing to borrow,
    /// neither the title nor the gap is drawn.
    let overhang: CGFloat

    var body: some View {
        GeometryReader { geo in
            let metrics = PaneTitleBadge.Metrics.standard
            // Gap and text come out of one call: computed separately you get "the border is
            // bitten open but the text dropped below the line"
            let badge = PaneTitleBadge.place(title: title, topEdgeWidth: geo.size.width,
                                             overhang: overhang, metrics: metrics)
            ZStack(alignment: .topLeading) {
                Path { path in
                    frame(&path, size: geo.size, gap: badge.map { (start: $0.gapStart, end: $0.gapEnd) })
                }
                .fill(color)
                if let badge {
                    Text(badge.text)
                        .font(Font(metrics.font))
                        .foregroundStyle(titleColor)
                        .lineLimit(1)
                        .fixedSize()
                        .offset(x: metrics.leadingInset, y: badge.offsetY)
                }
            }
        }
        // Neither border nor title may eat the mouse: terminal selection and Cmd+click on a link
        // both have to pass straight through.
        .allowsHitTesting(false)
    }

    /// Each edge is a filled rectangle rather than a stroke: square corners, an exact line width,
    /// and a gap that is easy to cut.
    private func frame(_ path: inout Path, size: CGSize, gap: (start: CGFloat, end: CGFloat)?) {
        let line = PaneTitleBadge.lineWidth
        let (w, h) = (size.width, size.height)
        guard w > 0, h > 0 else { return }
        // The left and right edges run the full height, which fills in all four corners.
        path.addRect(CGRect(x: 0, y: 0, width: line, height: h))
        path.addRect(CGRect(x: w - line, y: 0, width: line, height: h))
        path.addRect(CGRect(x: 0, y: h - line, width: w, height: line))
        guard let gap, gap.start < w else {
            path.addRect(CGRect(x: 0, y: 0, width: w, height: line))
            return
        }
        path.addRect(CGRect(x: 0, y: 0, width: gap.start, height: line))
        let right = min(gap.end, w)
        path.addRect(CGRect(x: right, y: 0, width: w - right, height: line))
    }
}
