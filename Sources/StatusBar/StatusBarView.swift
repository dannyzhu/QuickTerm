import SwiftUI

/// Waybar-style top bar (spec §4.4): 26pt, Monaco 12, monochrome SF Symbols, no rounded corners.
/// Left: logo + workspace pills. Center: clock. Right: cpu, network, volume, battery.
struct StatusBarView: View {
    /// Bar height (MainWindowController refers to it when converting content-area coordinates).
    static let height: CGFloat = 26

    @EnvironmentObject var theme: ThemeManager
    @EnvironmentObject private var i18n: Localization
    @ObservedObject var model: WorkspaceModel
    @ObservedObject var stats: SystemStatsService
    let onSelectWorkspace: (Int) -> Void
    /// Right-clicking a workspace pill names or renames that slot (left click still switches to
    /// the workspace).
    let onRenameWorkspace: (Int) -> Void
    let onToggleMute: () -> Void

    @State private var altClock = false
    /// Content width, excluding the 8pt of padding on each side. Whether the pills show names hangs
    /// entirely on it; see `WorkspacePill`.
    @State private var contentWidth: CGFloat = 0

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                leftSection
                Spacer(minLength: 0)
                rightSection
            }
            clock  // centered independently of either side's width (waybar center module)
        }
        .font(.custom("Monaco", size: 12))
        .foregroundStyle(theme.foreground)
        .frame(height: Self.height)
        // What gets measured is the stretch **inside** the padding (`padding` is only applied on
        // the next line): the pills, the clock and the right-hand stats all lay out in there.
        // This uses `onGeometryChange` rather than `background(GeometryReader)` + a preference,
        // because a preference set from the background never makes it up (tried it: the value
        // measured that way is always 0), and this width is the only input to "do the names fit" -
        // without it the whole feature is dead.
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { contentWidth = $0 }
        .padding(.horizontal, 8)
        .background(theme.background.opacity(theme.effectiveChromeOpacity))
        .contentShape(Rectangle())
        // Standard title bar behavior: double-clicking empty space zooms the window to fill the
        // screen's visible area, and double-clicking again restores it.
        // Gestures on the subviews (pills, clock, volume) take precedence and are unaffected.
        .onTapGesture(count: 2) {
            (NSApp.mainWindow ?? NSApp.keyWindow)?.zoom(nil)
        }
    }

    private var leftSection: some View {
        // **The pills that get drawn and the pills that get measured have to come from the same
        // array.** `model.titles` is not trimmed when the workspace count shrinks (a name belongs
        // to the slot, and it has to still be there when the count goes back up), so measuring it
        // as-is pays for pills that are never drawn - those names eat budget out of nowhere, and a
        // row that plainly fits falls back to numbers anyway.
        // The answer for the row is also computed **once per frame**: it has to measure the clock
        // and every name, and all the pills have to get the same answer (half names and half
        // numbers just reads as a bug).
        let titles = model.visibleTitles
        let showingTitles = showsWorkspaceTitles(titles)
        return HStack(spacing: WorkspacePill.sectionSpacing) {
            Text("◆")
                .foregroundStyle(theme.accent)
                .accessibilityLabel("QuickTerm")
            HStack(spacing: WorkspacePill.spacing) {
                ForEach(titles.indices, id: \.self) { i in
                    workspacePill(i, title: titles[i], showingTitles: showingTitles)
                }
            }
            controlFlash
        }
    }

    /// Whether this row of pills currently shows names or numbers. **All or nothing for the whole
    /// row**: the config switch being off, not one slot having a name, or the left section not
    /// fitting before the clock's left edge all fall back to numbers.
    /// The names are passed in by the caller (exactly the row it draws), so what gets measured and
    /// what gets drawn cannot come from two different reads.
    private func showsWorkspaceTitles(_ titles: [String?]) -> Bool {
        theme.workspaceTitleEnabled
            && WorkspacePill.showsTitles(contentWidth: contentWidth, titles: titles,
                                         activeIndex: model.activeIndex,
                                         clockWidth: clockWidth, flash: model.controlFlash?.text)
    }

    /// Control-plane activity indicator (control plane spec, §Security): `mutate` commands put up
    /// no dialog and ask no one - the **precondition** for letting them be that silent is that they
    /// leave a trace you can see at a glance afterwards.
    /// It lingers 2.5s and then disappears on its own; the full record lives under
    /// "Control Plane Activity...".
    @ViewBuilder
    private var controlFlash: some View {
        if let flash = model.controlFlash {
            Text(flash.text)
                .lineLimit(1)
                .foregroundStyle(theme.accent)
                .padding(.horizontal, 6)
                .frame(minHeight: 18)
                .background(theme.accent.opacity(0.15))
                .transition(.opacity)
                .accessibilityLabel(i18n("status.control.flash-label", flash.text))
                .help(i18n("status.control.flash-help"))
        }
    }

    private func workspacePill(_ i: Int, title: String?, showingTitles: Bool) -> some View {
        let active = model.activeIndex == i
        return Button {
            onSelectWorkspace(i)
        } label: {
            // A named slot draws its name where the number or the ■ would go: the active pill
            // still uses the accent color (that is what marks it active), and inactive pills still
            // use the foreground color plus the half alpha of an empty workspace.
            // Layout (font size, minimum width, padding) lives in `WorkspacePill.pill` - the same
            // file that computes the width.
            WorkspacePill.pill(title: title, index: i, active: active,
                               showingTitles: showingTitles)
                .foregroundStyle(active ? theme.accent : theme.foreground)
                .opacity(active || !model.isEmpty(i) ? 1 : 0.5)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Right-click renames. It still works when the names do not fit (or the config switch is
        // off): renaming is a property of the slot and has nothing to do with what is displayed.
        .overlay(RightClickCatcher { onRenameWorkspace(i) })
        .accessibilityLabel(title.map { i18n("status.workspace.label-with-name", i + 1, $0) }
                            ?? i18n("status.workspace.label", i + 1))
    }

    private var clock: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            Text(clockText(context.date, alt: altClock))
                .foregroundStyle(theme.foreground)
                .onTapGesture { altClock.toggle() }
        }
    }

    private func clockText(_ date: Date, alt: Bool) -> String {
        let fmt = DateFormatter()
        // Weekday and month names follow the language the UI is drawn in, not the system
        // locale: the config may pin the UI to a language the Mac is not set to, and a Chinese
        // weekday sitting next to an English menu is exactly where that seam would show.
        fmt.locale = Locale(identifier: i18n.language.lprojName)
        // Omarchy: "Sunday 14:32"; a click switches it to "31 August W36 2026".
        // The pattern itself is in the catalog: the two languages order a date differently.
        fmt.dateFormat = i18n(alt ? "status.clock.format-alt" : "status.clock.format")
        return fmt.string(from: date)
    }

    /// How wide the clock is. **Measure both formats and take the wider one**: clicking the clock
    /// switches format, and sizing by the current one alone means a single click on the date can
    /// make the whole row of workspace names disappear.
    private var clockWidth: CGFloat {
        let now = Date()
        return max(WorkspacePill.width(of: clockText(now, alt: false)),
                   WorkspacePill.width(of: clockText(now, alt: true)))
    }

    private var rightSection: some View {
        HStack(spacing: 14) {
            HStack(spacing: 3) {
                Image(systemName: "cpu")
                Text("\(stats.cpuPercent)%")
                    .monospacedDigit()
            }
            Image(systemName: stats.networkUp
                  ? (stats.networkWifi ? "wifi" : "network")
                  : "wifi.slash")
            Button { onToggleMute() } label: {
                Image(systemName: stats.muted ? "speaker.slash" : "speaker.wave.2")
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(i18n(stats.muted ? "status.volume.unmute" : "status.volume.mute"))
            if let percent = stats.batteryPercent {
                battery(percent)
            }
        }
    }

    @ViewBuilder
    private func battery(_ percent: Int) -> some View {
        let low = percent <= 20 && !stats.batteryCharging
        HStack(spacing: 3) {
            // While charging, the icon alone; otherwise `85%` plus the icon (Omarchy semantics);
            // a low battery warns in red.
            if !stats.batteryCharging || low {
                Text("\(percent)%").monospacedDigit()
            }
            Image(systemName: batterySymbol(percent))
        }
        .foregroundStyle(low ? theme.alert : theme.foreground)
    }

    private func batterySymbol(_ percent: Int) -> String {
        if stats.batteryCharging { return "battery.100percent.bolt" }
        switch percent {
        case 88...: return "battery.100percent"
        case 63...: return "battery.75percent"
        case 38...: return "battery.50percent"
        case 13...: return "battery.25percent"
        default: return "battery.0percent"
        }
    }
}

/// A transparent layer that **eats right clicks only**. Left clicks (and everything else) pass
/// straight through to the `Button` underneath - a left click on a pill means "switch to this
/// workspace", and not one word of that changes.
/// SwiftUI has no "right-clicked once" gesture (`contextMenu` wants a menu; what is needed here is
/// a dialog), so this borrows an NSView: `hitTest` claims itself only when the current event really
/// is a right click.
struct RightClickCatcher: NSViewRepresentable {
    let action: () -> Void

    /// Whether to claim this click. **The event type is the only criterion**, split out so it can
    /// be tested: claim one type too many here and a pill's left click (switch workspace) goes dead
    /// on the spot - a regression you can only catch with your eyes.
    static func claims(_ type: NSEvent.EventType?) -> Bool {
        type == .rightMouseDown || type == .rightMouseUp
    }

    func makeNSView(context: Context) -> Catcher { Catcher(action: action) }
    func updateNSView(_ nsView: Catcher, context: Context) { nsView.action = action }

    final class Catcher: NSView {
        var action: () -> Void

        init(action: @escaping () -> Void) {
            self.action = action
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard RightClickCatcher.claims(NSApp.currentEvent?.type) else { return nil }
            return super.hitTest(point)
        }

        override func rightMouseDown(with event: NSEvent) { action() }
    }
}
