import Combine
import SwiftUI

/// **The find bar** (Cmd+F): one field, a match counter, previous / next / close.
///
/// One view for both kinds of pane. A terminal drives the engine's search (`SurfaceSearchOverlay`
/// hands it the engine's needle, counter and `navigate_search`); a browser pane drives WebKit's
/// find in page (`BrowserPaneView.findBar`). The bar knows nothing about either: it edits a needle,
/// shows a counter, and says "forward", "back", "escape" and "close".
///
/// The bar is its natural size; the host pins it `inset` in from the pane's top-right corner. It is
/// drawn at 0.9 opacity, so the text under it still
/// shows through a little. Return goes to the next match and Shift+Return to the previous one;
/// both wrap at the ends, so holding Return cycles through every match.
struct PaneFindBar: View {
    @Binding var needle: String
    /// "3/12", "-/12" or "No matches"; nil while there is nothing to count yet.
    let counter: String?
    /// Fires whenever the field should take keyboard focus again (Cmd+F while the bar is open).
    let focusRequests: AnyPublisher<Void, Never>
    let onNavigate: (_ forward: Bool) -> Void
    let onEscape: () -> Void
    let onClose: () -> Void
    /// Which way "next" goes on screen, so the arrow buttons point where the match will move: up
    /// in a terminal (the engine's next is the next *older* match), down in a web page.
    var nextIsUp = false

    @EnvironmentObject private var i18n: Localization
    @FocusState private var fieldFocused: Bool

    static let opacity: Double = 0.9
    static let inset: CGFloat = 8

    /// The counter text, from the engine's (or WebKit's) selected index and total.
    static func counter(selected: UInt?, total: UInt?) -> String? {
        guard let total else { return nil }
        if total == 0 { return L("terminal.find.no-match") }
        return L("terminal.find.counter", selected.map { String($0 + 1) } ?? "-", String(total))
    }

    var body: some View {
        HStack(spacing: 4) {
            TextField(i18n("terminal.find.placeholder"), text: $needle)
                .textFieldStyle(.plain)
                .frame(width: 180)
                .padding(.leading, 8)
                .padding(.trailing, 70)
                .padding(.vertical, 6)
                .background(Color.primary.opacity(0.1))
                .cornerRadius(6)
                .focused($fieldFocused)
                .overlay(alignment: .trailing) {
                    if let counter {
                        Text(counter)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                            .lineLimit(1)
                            .padding(.trailing, 8)
                    }
                }
                .onExitCommand(perform: onEscape)
                .onKeyPress(.return, phases: .down) { press in
                    onNavigate(!press.modifiers.contains(.shift))
                    return .handled
                }

            button("chevron.up", help: i18n(nextIsUp ? "terminal.find.next" : "terminal.find.previous")) {
                onNavigate(nextIsUp)
            }
            button("chevron.down", help: i18n(nextIsUp ? "terminal.find.previous" : "terminal.find.next")) {
                onNavigate(!nextIsUp)
            }
            button("xmark", help: i18n("terminal.find.close"), action: onClose)
        }
        .padding(8)
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .shadow(radius: 4)
        .opacity(Self.opacity)
        .onAppear { fieldFocused = true }
        .onReceive(focusRequests) { DispatchQueue.main.async { fieldFocused = true } }
    }

    private func button(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol) }
            .buttonStyle(FindButtonStyle())
            .help(help)
    }

    private struct FindButtonStyle: ButtonStyle {
        @State private var hovered = false

        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .foregroundStyle(hovered || configuration.isPressed ? .primary : .secondary)
                .padding(.horizontal, 2)
                .frame(height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.primary.opacity(configuration.isPressed ? 0.2 : hovered ? 0.1 : 0)))
                .onHover { hovered = $0 }
        }
    }
}

/// **The zoom badge**: a translucent "shrink" icon in the top-right corner of a zoomed pane.
///
/// It says "this pane is zoomed" to someone who did not press the key, and a click on it un-zooms.
/// It sits below whatever the pane draws across its own top (the agent band, a browser's toolbar),
/// and while the find bar is open it moves down below that too rather than sitting under it.
struct PaneZoomBadge: View {
    /// Where the pane's own content starts, measured from the pane's top edge.
    let contentTop: CGFloat
    let findBarOpen: Bool
    let onExit: () -> Void

    @EnvironmentObject private var i18n: Localization
    @State private var hovered = false

    static let size: CGFloat = 26
    /// Room the find bar takes at the top: its 26pt buttons, 8pt padding on each side, the inset.
    static let findBarClearance: CGFloat = 26 + 16 + PaneFindBar.inset

    var body: some View {
        Button(action: onExit) {
            Image(systemName: "arrow.down.right.and.arrow.up.left")
                .font(.system(size: 12, weight: .semibold))
                .frame(width: Self.size, height: Self.size)
                .background(RoundedRectangle(cornerRadius: 6).fill(.black.opacity(hovered ? 0.55 : 0.35)))
                .foregroundStyle(.white.opacity(hovered ? 1 : 0.8))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(i18n("terminal.zoom.exit"))
        .padding(.top, contentTop + PaneFindBar.inset + (findBarOpen ? Self.findBarClearance : 0))
        .padding(.trailing, PaneFindBar.inset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
    }
}
