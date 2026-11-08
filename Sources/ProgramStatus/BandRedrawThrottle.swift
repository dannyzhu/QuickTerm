import Foundation

/// **At most four band redraws a second per pane** (spec decision 18).
///
/// A program can print a hundred progress steps in a tenth of a second, and every one of them
/// changes the pane's records. The first change after a quiet spell is drawn at once; changes
/// that arrive within `interval` of the last draw collapse into one pending draw, run when the
/// interval is up, and that draw reads whatever is current then, so the final value is always the
/// one drawn. Nothing is scheduled while a pane is quiet: there is one one-shot callback per busy
/// pane, never a repeating timer.
///
/// The clock and the scheduler are injected so a test can drive time by hand.
@MainActor
final class BandRedrawThrottle {
    /// 250 ms: four redraws a second.
    static let interval: TimeInterval = 0.25

    typealias Schedule = (_ delay: TimeInterval, _ run: @escaping @MainActor () -> Void) -> Void

    private let clock: () -> Date
    private let schedule: Schedule
    /// When each pane was last drawn. Only entries younger than `interval` matter; older ones are
    /// pruned on the next request, so the map holds recently busy panes only.
    private var lastDrawn: [UUID: Date] = [:]
    /// The latest draw waiting for its slot, per pane.
    private var pending: [UUID: @MainActor () -> Void] = [:]

    init(clock: @escaping () -> Date = Date.init, schedule: Schedule? = nil) {
        self.clock = clock
        self.schedule = schedule ?? { delay, run in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated(run) }
        }
    }

    /// Ask for `pane`'s band to be redrawn by `draw`. `draw` should read the current state when it
    /// runs rather than capture it, because only the last request in a burst runs.
    func request(_ pane: UUID, draw: @escaping @MainActor () -> Void) {
        let now = clock()
        lastDrawn = lastDrawn.filter { now.timeIntervalSince($0.value) < Self.interval }
        if pending[pane] != nil {
            pending[pane] = draw
            return
        }
        guard let last = lastDrawn[pane] else {
            lastDrawn[pane] = now
            draw()
            return
        }
        pending[pane] = draw
        schedule(Self.interval - now.timeIntervalSince(last)) { [weak self] in
            guard let self, let latest = self.pending.removeValue(forKey: pane) else { return }
            self.lastDrawn[pane] = self.clock()
            latest()
        }
    }
}
