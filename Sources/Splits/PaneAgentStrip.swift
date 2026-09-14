import AppKit
import SwiftUI

/// **The agent status bar** (plan §2.11): one filled bar across the pane's own top padding saying
/// who is in that pane, what they are doing, and for how long.
///
/// It replaces the 1.6.1 "info strip" — a 10pt line of unbacked text — and the reason is the
/// screenshot that produced this change: drawn as bare glyphs in the padding it landed two points
/// under the title badge riding on the border, the two read as one smudge, and at 10pt regular
/// neither was noticeable at a glance. A bar has a background, so it is a *place* on the pane
/// rather than some text over a terminal: the eye finds it, and its colour alone says whether
/// anybody is waiting for you.
///
/// The three rules of the old strip survive it unchanged, and each is a rule about what the bar
/// may *not* do:
///
/// - **It never resizes the terminal.** It is an overlay drawn into padding the engine already
///   reserves (`[appearance] pane-padding`, default 14). Below `Metrics.minPadding` there is no
///   room for a line without covering text, so below that the bar does not exist — the terminal is
///   never shrunk to make room for it, and the pane mark is left to tell the story.
/// - **It observes its pane and nothing else.** `PaneChrome` already holds the `PaneView` as an
///   `@ObservedObject`, and `agentStatus` is written only by `AgentRegistry`, which sends
///   `objectWillChange` before it moves. So one pane's agent churning through tool calls redraws
///   one frame — never the registry's other panes, and never the notification centre (plan §1.5).
/// - **It eats exactly its own rectangle.** The rest of the chrome refuses the mouse so terminal
///   selection and Cmd+click on a link pass through; this bar takes a click (to focus the pane)
///   and is therefore sized to its own frame and no larger, exactly like the notice dot's tooltip.
///
/// One rule is new, and it is the anti-overlap one: **while the bar is drawn it is the pane's
/// title**, and `PaneChrome` does not put the badge on the border as well (`PaneTitleBadge
/// .borderTitle`). Two titles two points apart was the bug.
///
/// `Model` is a pure function of `(status, title, now)` and holds every word and colour decision,
/// so the text, the background role and the elapsed time are tested without SwiftUI ever being
/// instantiated; `Bar` is a function of `Model` plus two colours, so the laid-out geometry is
/// testable too.
struct PaneAgentStrip: View {
    @ObservedObject var surfaceView: PaneView
    @EnvironmentObject var theme: ThemeManager

    /// Geometry, in one place: a bar spanning the pane's inner width inside the padding band.
    enum Metrics {
        /// The tallest band the bar is ever given, measured from the pane's outer top edge. A
        /// `pane-padding` larger than this leaves the extra space to the terminal rather than
        /// growing the bar.
        static let maxHeight: CGFloat = 16
        /// Where the bar starts, measured from the pane's outer top edge: one point in, i.e. under
        /// the inner half of the 2pt border. `PaneFrame` is drawn on top of the bar, so that point
        /// is never visible as bar — but it is what makes the bar 13pt tall at the default
        /// `pane-padding` of 14, and 11pt semibold glyphs measure 12.96pt from cap top to
        /// descender bottom. Starting at the full border width (2) left 12pt and clipped a point
        /// of every descender at the default setting; the fit test measures exactly this.
        static let topInset: CGFloat = 1
        /// Below this much padding there is nowhere to put the bar, so nothing is drawn. Two
        /// points lower than the old strip's 14: from 12 the bar gets 11pt, which clips a little
        /// of the descenders (`.clipped()`) and nothing of the terminal's first row.
        static let minPadding = 12
        /// Left and right inset **inside** the bar, so the text does not touch the border.
        static let inset: CGFloat = 6
        /// 11pt semibold, up from 10pt regular. On a filled background this is the difference
        /// between "there is something written there" and text you actually read in passing.
        static let fontSize: CGFloat = 11
        /// The glyph cycles at this rate while the agent is working.
        static let spinnerPeriod: TimeInterval = 0.25
        /// Everything else only needs the elapsed time to tick.
        static let tickPeriod: TimeInterval = 1
        /// How long `done` keeps its green before it has faded into the ordinary background.
        static let doneFade: TimeInterval = 3
        /// The elapsed time is the same colour as the rest, one notch down: it is the least
        /// urgent thing on the bar and must not compete with the agent's own words.
        static let elapsedOpacity: Double = 0.75
    }

    /// Whether the bar is drawn at all. Three independent reasons not to draw, spelled once so
    /// the view, `PaneChrome`'s title suppression and the tests cannot disagree.
    static func visible(status: AgentStatus?, infoStrip: Bool, panePadding: Int) -> Bool {
        status != nil && infoStrip && panePadding >= Metrics.minPadding
    }

    /// The bar's own rectangle inside the pane, in the pane's coordinate space. **This is also
    /// its hit-test rectangle**: a click anywhere else on the chrome still belongs to the
    /// terminal.
    ///
    /// It occupies the padding band from the pane's outer top edge down to
    /// `min(panePadding, maxHeight)`, minus the border line, which owns the first two points on
    /// every edge and is not the bar's to paint over — the red pane mark rides on that line and
    /// has to stay visible. So: inset by the border on the left, the right and the top, and
    /// ending exactly where the engine's padding ends.
    static func rect(in size: CGSize, panePadding: Int) -> CGRect {
        let border = PaneTitleBadge.lineWidth
        let band = min(CGFloat(panePadding), Metrics.maxHeight)
        let width = max(0, size.width - border * 2)
        return CGRect(x: border, y: Metrics.topInset, width: width,
                      height: max(0, band - Metrics.topInset))
    }

    /// The lead of the line: the pane's own title when it has one, the agent's name otherwise.
    ///
    /// `[appearance] pane-title` governs it, the same key that governs the badge on the border —
    /// it is one switch meaning "show this pane's own name", and the bar is now where that name
    /// is drawn.
    private var leadTitle: String? {
        theme.paneTitleEnabled ? surfaceView.customTitle : nil
    }

    /// `AgentRegistry.shared.settings` read live rather than cached, the same way `PaneChrome`
    /// reads `notices.settings.paneMark`: the keys hot-reload, and this way a changed colour or a
    /// flipped switch takes hold on this pane's next redraw.
    private var settings: AgentSettings { AgentRegistry.shared.settings }

    var body: some View {
        GeometryReader { geo in
            if let status = surfaceView.agentStatus,
               Self.visible(status: status, infoStrip: settings.infoStrip,
                            panePadding: theme.panePadding) {
                let rect = Self.rect(in: geo.size, panePadding: theme.panePadding)
                // One schedule drives both the spinner and the elapsed time, and it only exists
                // while the bar is on screen: a pane whose agent is idle ticks once a second,
                // a working one four times, and a pane with no agent has no timeline at all.
                TimelineView(.periodic(from: status.since,
                                       by: status.state == .working ? Metrics.spinnerPeriod
                                                                    : Metrics.tickPeriod)) { context in
                    let model = Model.make(status: status, now: context.date, title: leadTitle)
                    Bar(model: model, size: rect.size,
                        background: background(model.tone), text: textColor)
                }
                // The background already fills the rectangle, but a `Model` with no glyphs at all
                // would not: give the bar an explicit shape so the click never falls through to
                // the terminal underneath.
                .contentShape(Rectangle())
                .onTapGesture {
                    // The pane knows its controller (it caches the last one it was attached to,
                    // so a mid-remount click is not dropped); the chrome deliberately has no
                    // controller of its own to reach for.
                    (surfaceView.controller as? MainWindowController)?.requestFocus(to: surfaceView)
                }
                .offset(x: rect.minX, y: rect.minY)
            }
        }
    }

    /// The bar's background for a state. `[agents] strip-background` for the four quiet states,
    /// `[agents] strip-attention` for the two that mean "go and look".
    private func background(_ tone: Model.Tone) -> Color {
        let base = Self.color(hex: settings.stripBackground,
                              fallback: AgentSettings.defaultStripBackground)
        switch tone {
        case .neutral: return base
        case .alert: return Self.color(hex: settings.stripAttention,
                                       fallback: AgentSettings.defaultStripAttention)
        // A finished turn is worth a green flash and not worth a permanently green pane: the
        // background decays into the ordinary base over `doneFade` seconds, so a workspace left
        // running overnight is not a wall of green.
        case .finished(let fade):
            return Self.blend(theme.current.color("green") ?? .green, base, fade)
        }
    }

    private var textColor: Color {
        Self.color(hex: settings.stripText, fallback: AgentSettings.defaultStripText)
    }

    /// `#rrggbb` -> a colour, **through the config schema's own validator** so that what the
    /// settings accept and what the bar can draw are one decision. `fallback` is a second
    /// `#rrggbb` from `AgentSettings`' defaults; a value that fails both (impossible — the schema
    /// refuses a bad colour long before here) comes out as the plain foreground rather than as a
    /// crash.
    static func color(hex: String, fallback: String) -> Color {
        parse(hex: hex) ?? parse(hex: fallback) ?? Palette.foreground
    }

    private static func parse(hex: String) -> Color? {
        guard let normalized = ConfigKeySpec.hexColor(hex) else { return nil }
        var value: UInt64 = 0
        guard Scanner(string: String(normalized.dropFirst())).scanHexInt64(&value) else { return nil }
        return Color(red: Double((value >> 16) & 0xff) / 255,
                     green: Double((value >> 8) & 0xff) / 255,
                     blue: Double(value & 0xff) / 255)
    }

    /// Linear interpolation in device RGB. `Color` gained a `mix(with:by:)` only in the newest
    /// SDKs and this has to work with whatever colour a theme file supplied, so it goes through
    /// `NSColor`; an unconvertible colour falls back to a hard switch at the halfway point rather
    /// than to a crash.
    static func blend(_ from: Color, _ to: Color, _ t: Double) -> Color {
        let t = min(max(t, 0), 1)
        guard let a = NSColor(from).usingColorSpace(.deviceRGB),
              let b = NSColor(to).usingColorSpace(.deviceRGB) else { return t < 0.5 ? from : to }
        func mix(_ x: CGFloat, _ y: CGFloat) -> CGFloat { x + (y - x) * CGFloat(t) }
        return Color(nsColor: NSColor(deviceRed: mix(a.redComponent, b.redComponent),
                                      green: mix(a.greenComponent, b.greenComponent),
                                      blue: mix(a.blueComponent, b.blueComponent),
                                      alpha: mix(a.alphaComponent, b.alphaComponent)))
    }
}

extension PaneAgentStrip {
    /// **The bar as a function of values only** — no pane, no theme, no clock.
    ///
    /// Split out for one reason that is worth the extra type: this is the half whose *geometry*
    /// can be wrong, and only a real layout pass can tell you so. An 11pt semibold line in a 10pt
    /// band is the kind of thing that looks fine in the formula and spills onto the terminal's
    /// first row on screen, so a test hosts this view and measures it. Hosting the whole
    /// `PaneAgentStrip` would need a `PaneView` and a `ThemeManager`; this needs a struct.
    struct Bar: View {
        let model: Model
        /// Exactly what `PaneAgentStrip.rect` decided. The frame is hard, and the contents are
        /// clipped to it: the band belongs to the padding, and nothing the text does may grow it.
        let size: CGSize
        let background: Color
        let text: Color

        private var font: Font { .system(size: Metrics.fontSize, weight: .semibold) }

        var body: some View {
            HStack(spacing: 5) {
                Text(model.glyph)
                    .font(font)
                Text(model.text)
                    .font(font)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                Text(model.elapsed)
                    .font(font)
                    .opacity(Metrics.elapsedOpacity)
                    .lineLimit(1)
                    .fixedSize()
            }
            .foregroundStyle(text)
            .padding(.horizontal, Metrics.inset)
            .frame(width: size.width, height: size.height, alignment: .leading)
            .background(background)
            // The band is the engine's padding and not one point more. A line taller than the
            // band (11pt semibold in a `pane-padding = 12` pane) is cut, never allowed to draw
            // over the terminal's first row.
            .clipped()
        }
    }

    /// Everything the bar draws, as a value. Pure, so the wording, the colour role and the clock
    /// are all testable without a window.
    struct Model: Equatable {
        /// The leading symbol: a spinner frame while working, a fixed mark otherwise.
        var glyph: String
        /// `<pane title or agent name> · <state>[ · <tool>][: <message>]`, already clamped.
        var text: String
        /// How long this state has lasted, in the UI language.
        var elapsed: String
        var state: AgentState
        var tone: Tone

        /// Which **background** the bar wears, as a decision rather than as a `Color` — the view
        /// owns the config and the theme, this owns which of the three roles applies. (Before the
        /// bar this picked the colour of the *text*; the text now has one colour of its own and
        /// the background is what changes, because a filled colour is what carries across a
        /// screen full of panes.)
        enum Tone: Equatable {
            /// Working, idle, or a process we can see and know nothing about.
            case neutral
            /// A human is being waited for, or the turn failed. `[agents] strip-attention`.
            case alert
            /// The turn finished: green, fading into `neutral` as `fade` goes 0 → 1.
            case finished(fade: Double)
        }

        /// The spinner, in order. Four frames at 0.25 s is one revolution a second — fast enough
        /// to read as alive, slow enough not to flicker in the corner of an eye.
        static let spinner = ["◐", "◓", "◑", "◒"]
    }

}

extension PaneAgentStrip.Model {
    /// The bar's contents for a status, at a moment.
    ///
    /// `now` is passed in rather than read: the tests drive it and the view gets it from its
    /// `TimelineView`, so nothing here ever reads the clock behind anybody's back.
    ///
    /// `title` is the pane's own name when it has one. It leads the line because the bar is now
    /// the only place a pane's title is drawn while an agent is in it, and because on a screen of
    /// four Claude Code panes the agent's name is the one word that distinguishes nothing.
    static func make(status: AgentStatus, now: Date, title: String? = nil,
                     language: AppLanguage = Localization.shared.language) -> Self {
        let elapsed = max(0, now.timeIntervalSince(status.since))
        let lead = TitleRules.clamp(title ?? "", to: PaneTitleBadge.maxCharacters) ?? status.name
        var text = "\(lead) · \(status.localizedStateText)"
        // The tool **name** may be shown; the agent's own words follow a colon, and are the only
        // part of this line that could carry a command anybody typed.
        if let tool = status.tool, !tool.isEmpty { text += " · \(tool)" }
        if let message = status.message, !message.isEmpty { text += ": \(message)" }
        return Self(
            glyph: glyph(for: status, elapsed: elapsed),
            // The one title rulebook, here too: no control characters reach a line drawn over a
            // terminal, and 200 characters is the ceiling everywhere else in the app.
            text: TitleRules.fromTypedInput(text),
            elapsed: elapsedText(elapsed, language: language),
            state: status.state,
            tone: tone(for: status, elapsed: elapsed))
    }

    private static func glyph(for status: AgentStatus, elapsed: TimeInterval) -> String {
        switch status.state {
        case .working:
            let frame = Int(elapsed / PaneAgentStrip.Metrics.spinnerPeriod)
            return spinner[((frame % spinner.count) + spinner.count) % spinner.count]
        // The same filled dot the pane mark, the workspace pill and the CLI all use for "a human
        // is needed here": one symbol, one meaning, four surfaces.
        case .blocked: return "●"
        case .error: return "✗"
        case .done: return "✓"
        case .idle: return "○"
        // Seen by the process scan and silent: we know it is there and nothing more.
        case .unknown: return "◌"
        }
    }

    private static func tone(for status: AgentStatus, elapsed: TimeInterval) -> Tone {
        switch status.state {
        case .blocked, .error: .alert
        case .done: .finished(fade: min(1, elapsed / PaneAgentStrip.Metrics.doneFade))
        case .working, .idle, .unknown: .neutral
        }
    }

    /// `5s` / `2m 5s` / `1h 1m`, in the UI language.
    ///
    /// Two units at most on purpose: this sits in the right-hand corner of a line that is mostly
    /// the agent's own words, and `1h 1m 1s` is three units of clock nobody reads. The locale is
    /// the **UI** language rather than the system's, so a bar drawn in English does not say
    /// `1小时` on a Chinese machine and vice versa.
    static func elapsedText(_ interval: TimeInterval, language: AppLanguage) -> String {
        Duration.seconds(Int(max(0, interval).rounded(.down)))
            .formatted(.units(allowed: [.hours, .minutes, .seconds], width: .narrow,
                              maximumUnitCount: 2)
                .locale(Locale(identifier: language == .zh ? "zh_Hans_CN" : "en_US_POSIX")))
    }
}
