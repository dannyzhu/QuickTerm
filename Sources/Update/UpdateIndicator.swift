import SwiftUI

/// What the status bar draws for one update state: a glyph or a progress ring, its colour and its
/// tooltip. Pure, so the mapping is testable without a view.
struct UpdateIndicatorGlyph: Equatable {
    enum Tone: Equatable { case foreground, accent, alert }

    var symbol: String?
    /// 0…1 draws a ring instead of a symbol.
    var ring: Double?
    var tone: Tone
    var tooltipKey: String
    var tooltipArguments: [String]

    init?(state: UpdateState) {
        switch state {
        case .idle:
            return nil
        case .checking:
            self.init(symbol: "arrow.triangle.2.circlepath", tone: .foreground, key: "update.bar.checking")
        case .updateAvailable(let available):
            self.init(symbol: "arrow.down.circle", tone: .accent,
                      key: available.stage == .downloaded ? "update.bar.downloaded" : "update.bar.available",
                      arguments: [available.version])
        case .downloading(let downloading):
            let fraction = downloading.fraction ?? 0
            self.init(ring: fraction, tone: .accent, key: "update.bar.downloading",
                      arguments: [downloading.version ?? "", String(Int((fraction * 100).rounded()))])
        case .extracting(let extracting):
            self.init(ring: extracting.progress, tone: .accent, key: "update.bar.extracting",
                      arguments: [extracting.version ?? ""])
        case .installing(let installing):
            self.init(symbol: "power.circle", tone: .accent, key: "update.bar.installing",
                      arguments: [installing.version ?? ""])
        case .notFound:
            self.init(symbol: "checkmark.circle", tone: .foreground, key: "update.bar.up-to-date")
        case .error:
            self.init(symbol: "exclamationmark.triangle", tone: .alert, key: "update.bar.error")
        }
    }

    private init(symbol: String? = nil, ring: Double? = nil, tone: Tone, key: String,
                 arguments: [String] = []) {
        self.symbol = symbol
        self.ring = ring
        self.tone = tone
        self.tooltipKey = key
        self.tooltipArguments = arguments
    }

    /// Every key the glyph mapping can produce, spelled out for the catalog lint and the tests.
    static let tooltipKeys: [String] = [
        L("update.bar.checking"), L("update.bar.available"), L("update.bar.downloaded"),
        L("update.bar.downloading", "", ""), L("update.bar.extracting", ""),
        L("update.bar.installing", ""), L("update.bar.up-to-date"), L("update.bar.error"),
    ]
}

/// The updater's item in the status bar's right cluster: hidden when idle, otherwise one glyph in
/// the bar's monochrome style, or a progress ring. Text is read through `i18n` at render time so
/// a language change re-labels it.
struct UpdateIndicator: View {
    @ObservedObject var model: UpdateViewModel
    @EnvironmentObject var theme: ThemeManager
    @EnvironmentObject private var i18n: Localization
    let onClick: () -> Void

    var body: some View {
        if let glyph = UpdateIndicatorGlyph(state: model.state) {
            let label = i18n.string(glyph.tooltipKey, glyph.tooltipArguments)
            Button { onClick() } label: {
                Group {
                    if let fraction = glyph.ring {
                        ProgressRing(fraction: fraction)
                    } else if let symbol = glyph.symbol {
                        Image(systemName: symbol)
                    }
                }
                .frame(width: 14, height: 14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(colour(glyph.tone))
            .help(label)
            .accessibilityLabel(label)
        }
    }

    private func colour(_ tone: UpdateIndicatorGlyph.Tone) -> Color {
        switch tone {
        case .foreground: theme.foreground
        case .accent: theme.accent
        case .alert: theme.alert
        }
    }
}

/// A 12 pt ring: the track at 30 % and the arc from twelve o'clock.
struct ProgressRing: View {
    let fraction: Double

    var body: some View {
        ZStack {
            Circle().stroke(lineWidth: 1.5).opacity(0.3)
            Circle()
                .trim(from: 0, to: max(0, min(1, fraction)))
                .stroke(style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 12, height: 12)
    }
}
