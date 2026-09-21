import SwiftUI

/// What the pane's frame has to know about an alarm on this pane: **only a live `needsUser`
/// notice draws anything** (design §3.5, "Pane mark"), and the only thing the frame needs from it
/// is the tooltip.
///
/// The title is payload-free by construction (`NoticeCenter.post` sanitises it, and the design
/// forbids a command line in a title), which is what makes it safe to hang off a tooltip that
/// anybody walking past the screen can hover.
struct PaneFrameMark: Equatable {
    let title: String
}

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
    /// **The pane mark's only wiring.** The frame asks the centre directly rather than reading a
    /// flag some sink wrote onto `PaneView`: the mark is a pure function of the pane's live
    /// notices, and `live` is `@Published`, so posting, superseding and every resolution redraw
    /// this frame on their own. One source, no cache to fall out of date.
    @ObservedObject private var notices = NoticeCenter.shared
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

    private var isTerminal: Bool { surfaceView.kind == .terminal }

    /// The band's drawn height for this pane, in points (0 = no band). > 0 is the reason **the
    /// border badge stands down**: a live band spans the whole width and its first column is the
    /// pane's own name, so a badge on the border would repeat it.
    private var bandHeight: CGFloat {
        let s = AgentRegistry.shared.settings
        return PaneAgentStrip.band(infoStrip: s.infoStrip, stripHeight: s.stripHeight,
                                   isTerminal: isTerminal)
    }

    /// The top inset the terminal surface is pushed down by. Pushing it down (not overlaying) means
    /// the band sits *above* the surface and can never land on the first row, whatever the engine
    /// does. It is the band height minus the terminal's own top padding, which the band reuses, so
    /// the first row hugs the band instead of a dead gap below it.
    private var bandTopInset: CGFloat {
        let s = AgentRegistry.shared.settings
        return PaneAgentStrip.topReserve(infoStrip: s.infoStrip, stripHeight: s.stripHeight,
                                         panePadding: theme.panePadding, isTerminal: isTerminal)
    }

    /// What the strip reserved above the surface is painted with: **the terminal's own
    /// background, exactly as the engine paints it** — its resolved colour (which follows OSC
    /// colour changes) at its `background-opacity`, over the same underlay the surface sits on. An
    /// empty band then reads as more terminal rather than as a differently coloured bar at the
    /// top of every idle pane; a painted band covers this anyway. Nil for a pane that is not a
    /// terminal, which reserves no band.
    private var bandFill: Color? {
        guard let surface = surfaceView as? Ghostty.SurfaceView else { return nil }
        let color = surface.backgroundColor ?? surface.derivedConfig.backgroundColor
        return color.opacity(surface.derivedConfig.backgroundOpacity)
    }

    /// The title drawn on the top border: **only an explicitly set one counts** (right-click
    /// "Change Terminal Title", or `pane set --title` from the control plane). What the shell
    /// reports over OSC does not - that changes on every command you type, and the border would
    /// judder along with it. The master switch is the `pane-title` config key, and the status bar
    /// takes precedence over the badge - the whole rule lives in `PaneTitleBadge.borderTitle`.
    private var titleOnFrame: String? {
        PaneTitleBadge.borderTitle(custom: surfaceView.customTitle,
                                   enabled: theme.paneTitleEnabled,
                                   barVisible: bandHeight > 0)
    }

    /// The red dot: this pane has at least one live `needsUser` notice.
    ///
    /// The tooltip is the **most recently posted** one - `live(pane:)` is in post order - because
    /// that is the prompt the user is being asked about now; the older ones are still counted by
    /// the Dock badge and the workspace pill.
    /// `[notifications] pane-mark = false` switches it off. Read live rather than cached: the
    /// config is hot-reloadable, and the switch then takes hold on this pane's next redraw.
    private var noticeMark: PaneFrameMark? {
        guard notices.settings.paneMark,
              notices.urgency(pane: surfaceView.id) == .needsUser,
              let notice = notices.live(pane: surfaceView.id).last(where: { $0.urgency == .needsUser })
        else { return nil }
        return PaneFrameMark(title: notice.title)
    }

    func body(content: Content) -> some View {
        let mark = noticeMark
        return content
            // Reserve the status band above the terminal by insetting the surface's top. This
            // shrinks the hosted surface, so the engine recomputes its rows to fit and the band is
            // real space above the first row — never an overlay that can land on top of text. Held
            // whenever the band is on, painted or blank, so an agent coming or going never nudges
            // the terminal. Background and every edge below span the whole pane.
            .padding(.top, bandTopInset)
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
            // The strip reserved above the surface (`bandTopInset`), in the terminal's own
            // background so it joins the terminal below instead of showing the pane underlay as a
            // bar of its own. Drawn under the status bar, which covers it whenever it paints.
            .overlay(alignment: .top) {
                if bandTopInset > 0, let bandFill {
                    bandFill.frame(height: bandTopInset)
                }
            }
            // No more `.border`: the title has to bite a gap out of the top border the way a
            // fieldset legend does, so all four edges are drawn by hand (pixel for pixel identical
            // to the old 2px square-cornered border).
            // The agent status bar, drawn in the top band this modifier reserves above the terminal
            // (plan §2.11). A separate overlay because it takes a click, and it reads
            // `surfaceView.agentStatus` — this pane's, nobody else's. It goes UNDER `PaneFrame`,
            // not over it: the bar is an
            // opaque fill starting one border line in (y = 2), while the red pane mark is a 6pt
            // dot centred on that 2pt line (y = -2…4). Drawn later, the bar would paint over the
            // dot's lower third and sit between the cursor and the dot's tooltip. `PaneFrame`
            // refuses hit-testing, so drawing it on top costs the bar none of its clicks.
            .overlay { PaneAgentStrip(surfaceView: surfaceView) }
            .overlay { PaneFrame(color: borderColor, titleColor: titleColor,
                                 title: titleOnFrame, overhang: overhang,
                                 mark: mark, markColor: theme.alert) }
            // The tooltip is a **separate** overlay on purpose: `PaneFrame` refuses every mouse
            // event (`allowsHitTesting(false)`), and it has to keep refusing - this is the one
            // 10x10 spot of the chrome that takes a cursor.
            .overlay {
                if let mark { PaneNoticeMarkTooltip(mark: mark) }
            }
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
    /// the only space outside the border is its own ring of pane-gap.
    private var overhang: CGFloat { theme.gapsEnabled ? theme.paneGap : 0 }
}

/// The dot's tooltip, and nothing else: a `markHitSize` square sitting exactly on the dot.
///
/// Why it is its own view rather than a `.help` on the frame: `.help` needs the view to hit-test,
/// and the frame must never do that (terminal selection and Cmd+click on a link both pass straight
/// through it). Keeping the target to the dot alone is the whole point - hovering anywhere else on
/// the pane still belongs to the terminal.
private struct PaneNoticeMarkTooltip: View {
    let mark: PaneFrameMark

    var body: some View {
        GeometryReader { geo in
            if let rect = PaneTitleBadge.markHitRect(topEdgeWidth: geo.size.width) {
                Color.clear
                    .frame(width: rect.width, height: rect.height)
                    // `Color.clear` draws nothing, so without this there is nothing to hover.
                    .contentShape(Rectangle())
                    .offset(x: rect.minX, y: rect.minY)
                    .help(mark.title)
            }
        }
    }
}

/// The pane's four edges plus the title riding on the top one, and the notice dot at its top-right
/// corner. Both bite a gap out of the top border, like a fieldset legend. When focus changes, line
/// and text change color together so it still reads as one frame; unfocused, the text is one notch
/// brighter than the line (see `PaneChrome.titleColor`: half of it sits on wallpaper outside the
/// border).
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
    /// Non-nil while this pane holds a live `needsUser` notice.
    let mark: PaneFrameMark?
    /// `theme.alert`, passed in so this stays a pure drawing view with no environment of its own.
    let markColor: Color

    var body: some View {
        GeometryReader { geo in
            let metrics = PaneTitleBadge.Metrics.standard
            // The dot's own geometry is decided FIRST, and its answer is what the title is told:
            // computed the other way round, a pane too narrow for the dot would still have paid
            // `markReserve` out of the title's width.
            let markRect = mark == nil ? nil : PaneTitleBadge.markRect(topEdgeWidth: geo.size.width)
            // Gap and text come out of one call: computed separately you get "the border is
            // bitten open but the text was never drawn"
            let badge = PaneTitleBadge.place(title: title, topEdgeWidth: geo.size.width,
                                             overhang: overhang, mark: markRect != nil,
                                             metrics: metrics)
            ZStack(alignment: .topLeading) {
                Path { path in
                    frame(&path, size: geo.size, gaps: [
                        badge.map { (start: $0.gapStart, end: $0.gapEnd) },
                        markRect == nil ? nil : PaneTitleBadge.markGapRange(topEdgeWidth: geo.size.width),
                    ].compactMap { $0 })
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
                if let markRect {
                    Circle()
                        .fill(markColor)
                        .frame(width: markRect.width, height: markRect.height)
                        .offset(x: markRect.minX, y: markRect.minY)
                }
            }
        }
        // Neither border nor title nor dot may eat the mouse: terminal selection and Cmd+click on
        // a link both have to pass straight through. The dot's tooltip is a separate overlay
        // (`PaneNoticeMarkTooltip`) for exactly this reason.
        .allowsHitTesting(false)
    }

    /// Each edge is a filled rectangle rather than a stroke: square corners, an exact line width,
    /// and gaps that are easy to cut.
    ///
    /// `gaps` arrive in ascending order and cannot overlap - the title's is capped by
    /// `availableTextWidth`, which subtracts `markReserve` whenever the dot is drawn - so one
    /// left-to-right walk draws the surviving stretches of the top edge.
    private func frame(_ path: inout Path, size: CGSize, gaps: [(start: CGFloat, end: CGFloat)]) {
        let line = PaneTitleBadge.lineWidth
        let (w, h) = (size.width, size.height)
        guard w > 0, h > 0 else { return }
        // The left and right edges run the full height, which fills in all four corners.
        path.addRect(CGRect(x: 0, y: 0, width: line, height: h))
        path.addRect(CGRect(x: w - line, y: 0, width: line, height: h))
        path.addRect(CGRect(x: 0, y: h - line, width: w, height: line))
        var x: CGFloat = 0
        for gap in gaps where gap.start < w {
            let start = max(x, gap.start)
            if start > x { path.addRect(CGRect(x: x, y: 0, width: start - x, height: line)) }
            x = max(x, min(gap.end, w))
        }
        if x < w { path.addRect(CGRect(x: x, y: 0, width: w - x, height: line)) }
    }
}
