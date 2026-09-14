import AppKit
import SwiftUI

/// **The info strip** (plan §2.11): one line inside the pane's own top padding saying what the
/// agent in that pane is doing, and for how long.
///
/// Three properties are the whole design, and each of them is a rule about what the strip may
/// *not* do:
///
/// - **It never resizes the terminal.** It is an overlay drawn into padding the engine already
///   reserves (`[appearance] pane-padding`, default 14). Below 14 there is no room for a 10pt
///   line without covering text, so below 14 the strip does not exist — it does not shrink the
///   terminal to make room for itself.
/// - **It observes its pane and nothing else.** `PaneChrome` already holds the `PaneView` as an
///   `@ObservedObject`, and `agentStatus` is written only by `AgentRegistry`, which sends
///   `objectWillChange` before it moves. So one pane's agent churning through tool calls redraws
///   one frame — never the registry's other panes, and never the notification centre (plan §1.5).
/// - **It eats exactly its own rectangle.** The rest of the chrome refuses the mouse so terminal
///   selection and Cmd+click on a link pass through; this strip takes a click (to focus the pane)
///   and is therefore sized to its own frame and no larger, exactly like the notice dot's tooltip.
///
/// `Model` is a pure function of `(status, now)` and holds every word and colour decision, so the
/// text, the state colour and the elapsed time are tested without SwiftUI ever being instantiated.
struct PaneAgentStrip: View {
    @ObservedObject var surfaceView: PaneView
    @EnvironmentObject var theme: ThemeManager

    /// Geometry, in one place: the strip is a single 10pt line living in a 14pt band.
    enum Metrics {
        /// The tallest the strip is ever drawn. A `pane-padding` larger than this leaves the
        /// extra space to the terminal rather than growing the text.
        static let maxHeight: CGFloat = 14
        /// Below this much padding there is nowhere to put the line, so nothing is drawn.
        static let minPadding = 14
        /// Left and right inset inside the padding band, so the text does not touch the border.
        static let inset: CGFloat = 8
        static let fontSize: CGFloat = 10
        /// The glyph cycles at this rate while the agent is working.
        static let spinnerPeriod: TimeInterval = 0.25
        /// Everything else only needs the elapsed time to tick.
        static let tickPeriod: TimeInterval = 1
        /// How long `done` stays green before it has faded into the ordinary dim text.
        static let doneFade: TimeInterval = 3
    }

    /// Whether the strip is drawn at all. Three independent reasons not to draw, spelled once so
    /// the view and its tests cannot disagree.
    static func visible(status: AgentStatus?, infoStrip: Bool, panePadding: Int) -> Bool {
        status != nil && infoStrip && panePadding >= Metrics.minPadding
    }

    /// The strip's own rectangle inside the pane, in the pane's coordinate space. **This is also
    /// its hit-test rectangle**: a click anywhere else on the chrome still belongs to the
    /// terminal.
    static func rect(in size: CGSize, panePadding: Int) -> CGRect {
        let height = min(CGFloat(panePadding), Metrics.maxHeight)
        let width = max(0, size.width - Metrics.inset * 2)
        return CGRect(x: Metrics.inset, y: 0, width: width, height: height)
    }

    var body: some View {
        GeometryReader { geo in
            if let status = surfaceView.agentStatus,
               Self.visible(status: status,
                            // Read live rather than cached, the same way `PaneChrome` reads
                            // `notices.settings.paneMark`: the key hot-reloads, and this way the
                            // switch takes hold on this pane's next redraw.
                            infoStrip: AgentRegistry.shared.settings.infoStrip,
                            panePadding: theme.panePadding) {
                let rect = Self.rect(in: geo.size, panePadding: theme.panePadding)
                // One schedule drives both the spinner and the elapsed time, and it only exists
                // while the strip is on screen: a pane whose agent is idle ticks once a second,
                // a working one four times, and a pane with no agent has no timeline at all.
                TimelineView(.periodic(from: status.since,
                                       by: status.state == .working ? Metrics.spinnerPeriod
                                                                    : Metrics.tickPeriod)) { context in
                    line(Model.make(status: status, now: context.date))
                }
                .frame(width: rect.width, height: rect.height)
                // `Color.clear` and text both draw nothing where there is no glyph, so give the
                // strip an explicit shape — otherwise the click lands on the terminal underneath.
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

    @ViewBuilder
    private func line(_ model: Model) -> some View {
        HStack(spacing: 4) {
            Text(model.glyph)
                .font(.system(size: Metrics.fontSize))
                // The one moving thing on an otherwise still frame gets the accent while the
                // agent is working; everything else is the colour of its own state.
                .foregroundStyle(model.state == .working ? theme.accent : color(model.tone))
            Text(model.text)
                .font(.system(size: Metrics.fontSize))
                .foregroundStyle(color(model.tone))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            Text(model.elapsed)
                .font(.system(size: Metrics.fontSize))
                .foregroundStyle(Palette.inactiveTitle)
                .lineLimit(1)
                .fixedSize()
        }
    }

    private func color(_ tone: Model.Tone) -> Color {
        switch tone {
        case .neutral: Palette.inactiveTitle
        case .alert: theme.alert
        // A finished turn is worth a green flash and not worth a permanently green pane: it
        // decays into the ordinary dim text over `doneFade` seconds, so a workspace left running
        // overnight is not a wall of green.
        case .finished(let fade):
            Self.blend(theme.current.color("green") ?? .green, Palette.inactiveTitle, fade)
        }
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
    /// Everything the strip draws, as a value. Pure, so the wording, the colour and the clock
    /// are all testable without a window.
    struct Model: Equatable {
        /// The leading symbol: a spinner frame while working, a fixed mark otherwise.
        var glyph: String
        /// `<name> · <state>[ · <tool>][: <message>]`, already clamped.
        var text: String
        /// How long this state has lasted, in the UI language.
        var elapsed: String
        var state: AgentState
        var tone: Tone

        /// The colour the line is drawn in, as a decision rather than as a `Color` — the view
        /// owns the theme, this owns which of the three roles applies.
        enum Tone: Equatable {
            /// Working, idle, or a process we can see and know nothing about.
            case neutral
            /// A human is being waited for, or the turn failed. `theme.alert`.
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
    /// The strip's contents for a status, at a moment.
    ///
    /// `now` is passed in rather than read: the tests drive it and the view gets it from its
    /// `TimelineView`, so nothing here ever reads the clock behind anybody's back.
    static func make(status: AgentStatus, now: Date,
                     language: AppLanguage = Localization.shared.language) -> Self {
        let elapsed = max(0, now.timeIntervalSince(status.since))
        var text = "\(status.name) · \(status.localizedStateText)"
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
    /// the **UI** language rather than the system's, so a strip drawn in English does not say
    /// `1小时` on a Chinese machine and vice versa.
    static func elapsedText(_ interval: TimeInterval, language: AppLanguage) -> String {
        Duration.seconds(Int(max(0, interval).rounded(.down)))
            .formatted(.units(allowed: [.hours, .minutes, .seconds], width: .narrow,
                              maximumUnitCount: 2)
                .locale(Locale(identifier: language == .zh ? "zh_Hans_CN" : "en_US_POSIX")))
    }
}
