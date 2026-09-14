import Foundation

/// **What "the user acted" means to a live alarm** (spec §9 Q1, plan §2.8).
///
/// The owner's answer is (b): a keystroke in the pane withdraws the banner and clears the Dock
/// badge for that pane; the pane mark, the workspace count and the info strip stay until a hook or
/// the process confirms. Notification-evidenced alarms resolve fully on the keystroke — no later
/// signal will ever come for them, because there is no hook behind an OSC text.
///
/// The documented cost, accepted rather than worked around: under the default
/// `hook-detail = "lifecycle"` no hook fires between the user's approval and the end of the turn
/// (`PostToolUse` belongs to the `tools` tier), so the pane mark stays up until `Stop` — minutes,
/// not seconds. The exact remedy is `hook-detail = "tools"`.
enum AgentPolicy {
    enum UserActed: Equatable {
        /// Phase 1's behaviour: every notice of that pane resolves.
        case resolveFully
        /// (b), the default.
        case clearInterruptingSinks
        /// (c): resolve fully, and re-post the same alarm after this long if nothing has
        /// contradicted it meanwhile.
        case resolveFullyAndRearm(seconds: TimeInterval)
    }

    static let userActed: UserActed = .clearInterruptingSinks

    /// How long `.resolveFullyAndRearm` waits before putting the alarm back.
    static let rearmDelay: TimeInterval = 30
}
