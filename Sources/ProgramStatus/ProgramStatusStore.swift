// Stub — Task 3 replaces the bodies.
//
// The per-pane store of OSC 7501 program-status records (spec decisions 3, 5 and 10). Task 2
// routes the engine's actions here; Task 3 builds the records, the clearing rules and the
// heartbeat behind these exact signatures.

import Foundation

@MainActor
final class ProgramStatusStore {
    static let shared = ProgramStatusStore()

    /// Tests only: called once per entry point with a one-line description of the call, so the
    /// routing tests can see what reached the store without a real store behind it.
    var recordForTesting: ((String) -> Void)?

    /// A report from the program in `pane`. `foregroundGroup` is the pty's foreground process
    /// group at the moment the report arrived (nil when the engine could not tell).
    func receive(_ report: ProgramStatusReport, pane: UUID, foregroundGroup: Int32?) {
        recordForTesting?(
            "receive \(pane.uuidString) \(report.state.rawValue) \(report.id) "
                + "fg=\(foregroundGroup.map(String.init) ?? "nil")")
    }

    /// The shell in `pane` drew a new primary prompt (OSC 133). May arrive twice per prompt.
    func promptStarted(pane: UUID) {
        recordForTesting?("promptStarted \(pane.uuidString)")
    }

    /// The terminal in `pane` was fully reset, by the program (RIS) or by the user (Reset).
    func reset(pane: UUID) {
        recordForTesting?("reset \(pane.uuidString)")
    }
}
