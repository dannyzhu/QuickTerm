import Foundation

/// **The per-pane store of OSC 7501 program-status records** (spec decisions 3, 5 and 10).
///
/// `ProgramStatusRouter` is the only writer from the engine side; the heartbeat in
/// `ProcessScanner` drives `checkForeground`, and the agent registry forwards pane closes. The
/// store keeps no timers and holds no surfaces: whoever calls `checkForeground` resolves a pane id
/// to its live foreground process group.
///
/// `onChange(pane)` fires once per call that actually changed that pane's records. A repeated
/// identical report refreshes the record's `updatedAt` and fires nothing, so a listener that
/// raises alarms on change never raises the same one twice.
@MainActor
final class ProgramStatusStore {
    static let shared = ProgramStatusStore()

    /// Records per pane; past this the least recently updated one is dropped (decision 3).
    static let cap = 64

    struct Record: Equatable {
        var report: ProgramStatusReport
        /// The pty's foreground process group when the report arrived; nil when unknown.
        var foregroundGroup: Int32?
        var updatedAt: Date
    }

    var onChange: ((UUID) -> Void)?

    /// Tests only: called once per entry point with a one-line description of the call, so the
    /// routing tests can see what reached the store.
    var recordForTesting: ((String) -> Void)?

    private let clock: () -> Date
    /// In arrival order; a replaced record keeps its place.
    private var byPane: [UUID: [Record]] = [:]

    init(clock: @escaping () -> Date = Date.init) {
        self.clock = clock
    }

    // MARK: Reading

    func records(pane: UUID) -> [Record] {
        byPane[pane] ?? []
    }

    /// The panes holding at least one record.
    var panes: Set<UUID> {
        Set(byPane.keys)
    }

    // MARK: Engine entry points

    /// A report from the program in `pane`. `foregroundGroup` is the pty's foreground process
    /// group at the moment the report arrived (nil when the engine could not tell).
    func receive(_ report: ProgramStatusReport, pane: UUID, foregroundGroup: Int32?) {
        recordForTesting?(
            "receive \(pane.uuidString) \(report.state.rawValue) \(report.id) "
                + "fg=\(foregroundGroup.map(String.init) ?? "nil")")
        var records = byPane[pane] ?? []
        let before = records
        // Decision 5 runs on every report as well as on the heartbeat: a report from a new
        // foreground job means the old job's live records are over.
        if let foregroundGroup { Self.dropExited(&records, current: foregroundGroup) }

        if report.state == .clear {
            // Decision 3: the addressed record and everything beneath it, segment by segment
            // (`a` takes `a/b` but not `ab`); no id clears the pane. Never a record itself.
            records.removeAll { $0.report.id.starts(with: report.id) }
        } else {
            let record = Record(report: report, foregroundGroup: foregroundGroup, updatedAt: clock())
            if let index = records.firstIndex(where: { $0.report.id == report.id }) {
                records[index] = record
            } else {
                if records.count >= Self.cap,
                   let oldest = records.indices.min(by: { records[$0].updatedAt < records[$1].updatedAt }) {
                    records.remove(at: oldest)
                }
                records.append(record)
            }
        }
        store(records, pane: pane, changed: !Self.sameContent(before, records))
    }

    /// The shell in `pane` drew a new primary prompt (OSC 133). May arrive twice per prompt; the
    /// second finds nothing left to drop and changes nothing.
    func promptStarted(pane: UUID) {
        recordForTesting?("promptStarted \(pane.uuidString)")
        dropLiveRecords(pane: pane)
    }

    /// The pane's own process exited while the pane stays open (wait-after-command): the program
    /// that reported is gone, so its live records are too (decision 5). Idempotent.
    func childExited(pane: UUID) {
        dropLiveRecords(pane: pane)
    }

    /// The terminal in `pane` was fully reset, by the program (RIS) or by the user (Reset).
    func reset(pane: UUID) {
        recordForTesting?("reset \(pane.uuidString)")
        remove(pane: pane)
    }

    // MARK: Heartbeat and life cycle

    /// Decision 5's exit check: for every pane holding records, compare its current foreground
    /// group with the one each record remembers. A `working`, `blocked` or `idle` record from
    /// another group drops; `done` and `error` stay. Nothing is judged when either group is
    /// unknown.
    func checkForeground(current: (UUID) -> Int32?) {
        for pane in Array(byPane.keys) {
            guard var records = byPane[pane], let group = current(pane) else { continue }
            let count = records.count
            Self.dropExited(&records, current: group)
            store(records, pane: pane, changed: records.count != count)
        }
    }

    /// Forget a pane that closed.
    func paneClosed(_ pane: UUID) {
        remove(pane: pane)
    }

    /// `[agents] program-status` was switched off (decision 20): nothing is kept.
    func removeAll() {
        for pane in Array(byPane.keys) { remove(pane: pane) }
    }

    // MARK: Private

    /// Drop `working`, `blocked` and `idle`; keep `done` and `error`. One change at most.
    private func dropLiveRecords(pane: UUID) {
        guard var records = byPane[pane] else { return }
        let count = records.count
        records.removeAll { Self.dropsOnExit($0.report.state) }
        store(records, pane: pane, changed: records.count != count)
    }

    private func remove(pane: UUID) {
        guard byPane.removeValue(forKey: pane) != nil else { return }
        onChange?(pane)
    }

    private func store(_ records: [Record], pane: UUID, changed: Bool) {
        byPane[pane] = records.isEmpty ? nil : records
        if changed { onChange?(pane) }
    }

    private static func dropsOnExit(_ state: ProgramStatusReport.State) -> Bool {
        state == .working || state == .blocked || state == .idle
    }

    private static func dropExited(_ records: inout [Record], current: Int32) {
        records.removeAll { record in
            guard let group = record.foregroundGroup else { return false }
            return group != current && dropsOnExit(record.report.state)
        }
    }

    /// Equal apart from `updatedAt`: a refreshed timestamp alone is not a change.
    private static func sameContent(_ a: [Record], _ b: [Record]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy {
            $0.report == $1.report && $0.foregroundGroup == $1.foregroundGroup
        }
    }
}
