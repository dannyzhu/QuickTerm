import AppKit

/// The shared skeleton of the Phase 2 mutation commands: **compute the diff first, then decide
/// whether to touch anything at all**.
///
/// Every command is written to the same shape:
/// 1. compute `changes` read-only (current value → target value);
/// 2. hand them to `commit(_:apply:)`, which deals with `--dry-run` / `--fail-if-noop` / undo
///    registration / the status-bar flash / the activity log / bumping `seq`, all in one place.
///
/// That shape is **how idempotency is implemented**, not a promise that it holds:
/// an empty `changes` means "already in the requested state", and the `apply` block is simply
/// never called. So "run it twice and the second run is a no-op" is not the conscientiousness
/// of any individual command, it is one control flow that all of them share.
@MainActor
struct ControlMutationRequest {
    /// The command's name on the wire (`pane.set`)
    let command: String
    let request: ControlRequest
    let peer: ControlSocket.Peer
    /// The diff, computed read-only. **Empty = there is nothing to do**
    let changes: [ControlChange]
    /// The controllers this will change (where the undo snapshot is taken and where the
    /// status-bar flash lands; two of them for a move across screens)
    let controllers: [MainWindowController]
    /// The command the undo entry stands for (`pane set`), or nil when this step cannot be
    /// undone (closing a pane, say: the process is already dead, so an undo would only be a
    /// pretence). The wire spells it in English (`ControlUndo.wireName`); the Edit menu and the
    /// status-bar flash draw `ControlUndo.displayName`, which follows the UI language.
    let undoCommand: String?
    /// Where it landed, as the log shows it (`1:2.t7`)
    let target: String?
}

/// The activity log's outcome vocabulary, spelled out once so `commit` and `logRefusal` cannot
/// drift from the panel that renders them. English in both UI languages — see `Entry.Outcome`.
private typealias Outcome = ControlActivityLog.Entry.Outcome

@MainActor
extension ControlCommandRunner {
    var isDryRun: Bool { currentFlags.dryRun }
    var failsIfNoop: Bool { currentFlags.failIfNoop }

    /// The one exit for mutation commands. `applied` / `changed` / `changes` in the return
    /// value are already filled in; all the caller adds is the entity as it stands afterwards
    /// (pane / workspace / screen)
    func commit(_ mutation: ControlMutationRequest,
                apply: () throws -> Void) throws -> ControlMutationPayload {
        dispatchPrecondition(condition: .onQueue(.main))
        let changed = !mutation.changes.isEmpty
        let dryRun = isDryRun

        guard changed else {
            log(mutation, outcome: failsIfNoop ? Outcome.noopFailIfNoop : Outcome.noop)
            if failsIfNoop {
                throw ControlErrorBody(.noop, "Already in the requested state, nothing changed",
                                       hint: "Without --fail-if-noop this is a silent success, which is how an absolute setter is meant to behave.")
            }
            return ControlMutationPayload(command: mutation.command, applied: false,
                                          changed: false, dryRun: dryRun)
        }
        guard !dryRun else {
            log(mutation, outcome: Outcome.dryRun)
            return ControlMutationPayload(command: mutation.command, applied: false,
                                          changed: true, dryRun: true, changes: mutation.changes)
        }

        // The undo snapshot has to be taken **before** anything moves: layouts / floatings are
        // value types, so snapshotting them is a complete copy of the old layout
        let generation = ControlUndo.generation
        var snapshots = mutation.undoCommand == nil ? [] : mutation.controllers.map { $0.controlSnapshot() }
        do {
            try apply()
        } catch {
            // apply threw = this step did not land: seq does not move, nothing goes on the undo
            // stack, the status bar does not flash.
            // It **does** get logged, though — a failed mutation is exactly the kind of entry
            // the user most needs to find in the activity log.
            // (Command bodies always `throw` outright and never route a failure around commit
            //  through a captured variable: that would bump seq for a change that never
            //  happened, push an undo entry that undoes the wrong thing, and log it as applied.)
            let body = (error as? ControlErrorBody) ?? ControlErrorBody(.failed, "\(error)")
            log(mutation, outcome: Outcome.failed(body.code))
            throw body
        }
        seqDidMutate()
        if let undoCommand = mutation.undoCommand, !snapshots.isEmpty,
           ControlUndo.generation == generation {
            // Register only if no pane was closed during apply: if one was, the snapshot is
            // left holding a pane that is already dead
            for index in snapshots.indices { snapshots[index].stampExpectedPanes() }
            ControlUndo.register(command: undoCommand, before: snapshots)
        }
        flash(mutation)
        log(mutation, outcome: Outcome.applied)
        return ControlMutationPayload(command: mutation.command, applied: true, changed: true,
                                      dryRun: false, changes: mutation.changes,
                                      undo: mutation.undoCommand.map(ControlUndo.wireName))
    }

    /// Flash the status bar. `mutate` commands run silently, and **visibility is the condition
    /// on which they are allowed to be silent**. The text names the command and the pane it
    /// claims to come from — so the user at least knows that was not their own keystroke
    private func flash(_ mutation: ControlMutationRequest) {
        let origin = originHandle(for: mutation.request)
        let text = origin.map { L("control.flash.command-from-pane", mutation.command, $0) }
            ?? L("control.flash.command", mutation.command)
        let controllers = mutation.controllers.isEmpty
            ? [screens.controlCurrent].compactMap { $0 }
            : mutation.controllers
        for controller in controllers { controller.model.showControlFlash(text) }
    }

    private func log(_ mutation: ControlMutationRequest, outcome: String) {
        ControlActivityLog.shared.record(.init(
            at: Date(),
            command: mutation.command,
            peer: "\(mutation.peer.processName)(pid \(mutation.peer.pid))",
            originPane: originHandle(for: mutation.request),
            target: mutation.target,
            outcome: outcome,
            changes: mutation.changes))
    }

    /// Log reads too? **No.** Reads are frequent and harmless, and logging them would only bury
    /// the actual changes. Refused mutations, on the other hand, do get logged — those are the
    /// entries the user most needs to see
    func logRefusal(_ command: String, peer: ControlSocket.Peer, request: ControlRequest,
                    code: ControlErrorCode, message: String) {
        ControlActivityLog.shared.record(.init(
            at: Date(),
            command: command,
            peer: "\(peer.processName)(pid \(peer.pid))",
            originPane: originHandle(for: request),
            target: request.target,
            outcome: Outcome.refused(code.rawValue),
            changes: []))
    }
}

/// Undo registration, through `AppDelegate.undoManager` — which has been there all along and
/// had never been used.
///
/// Snapshot-based undo (store layouts / floatings / activeIndex wholesale, then put the whole
/// thing back) rather than inverting operations one by one: the layout is a value type, so one
/// snapshot is one complete copy of the old state, and there is no way to end up with a
/// half-done rollback that "forgot to invert the zoom".
/// The price is that a snapshot holds those PaneViews strongly, so `levelsOfUndo` has to be
/// capped — otherwise a runaway agent leaves the undo stack keeping hundreds of surfaces alive
/// in memory.
///
/// **Closing a pane or a screen registers no undo**: the process has already been killed, and
/// putting the layout back would only manufacture the impression that it is still there.
@MainActor
enum ControlUndo {
    static let levels = 25

    /// Incremented on every registration and on every real close. `commit` uses it to tell
    /// whether a pane was closed between taking the snapshot and the knife going in
    private(set) static var generation = 0

    private final class Target {
        static let shared = Target()
    }

    /// **Closing a pane or a screen voids the entire control-plane undo stack.**
    ///
    /// The layouts / floatings inside a snapshot are value types, but what they contain is
    /// `PaneView` (a class) — that is **one strong reference per pane**, while closing works by
    /// giving up the last reference, which is what triggers
    /// `SurfaceView.deinit → ghostty_surface_free` (the comments on `finishClose`, `removePane`
    /// and `teardown` all say exactly this). Holding on to the snapshot has two consequences,
    /// both of them in direct conflict with the lifecycle invariants of the close path:
    /// 1. the closed surface is never released and the shell never exits (closing a screen is
    ///    explicitly documented as "the processes inside it are supposed to end");
    /// 2. Cmd+Z can drop a browser pane that has already run its one-shot `paneWillClose()` back
    ///    into the layout intact, and it will never report a window event to the extension
    ///    again.
    ///
    /// The actual `removeAllActions()` is deferred to the next turn: this method may be running
    /// inside the engine's close_surface callback stack, and releasing synchronously would free
    /// a surface that is still on the engine's stack. Record the generation when queueing; if
    /// anything registered in the meantime (the generation changed) do not clear — that new undo
    /// entry was taken **after** this close, so it is clean by construction.
    nonisolated static func invalidate() {
        MainActor.assumeIsolated {
            generation &+= 1
            let queuedAt = generation
            guard let manager = (NSApp.delegate as? AppDelegate)?.undoManager,
                  manager.canUndo || manager.canRedo else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard generation == queuedAt, !manager.isUndoing, !manager.isRedoing else { return }
                    manager.removeAllActions()
                }
            }
        }
    }

    /// The undo entry's name on the wire — English in both UI languages, like the rest of the
    /// CLI surface, because `quickterm --json` prints it and an agent may match on it.
    static func wireName(_ command: String) -> String { "Control plane: \(command)" }

    /// The same name for the Edit menu and the status-bar flash, in the UI language.
    static func displayName(_ command: String) -> String { L("control.undo.name", command) }

    static func register(command: String, before: [MainWindowController.ControlSnapshot]) {
        guard let manager = (NSApp.delegate as? AppDelegate)?.undoManager else { return }
        manager.levelsOfUndo = levels
        generation &+= 1
        // The other half of the reversal: after undoing you have to be able to redo, so undoing
        // snapshots "now" as well and registers that back
        let after = before.compactMap { $0.controller?.controlSnapshot() }
        manager.registerUndo(withTarget: Target.shared) { _ in
            MainActor.assumeIsolated {
                // Putting the whole thing back = replacing the entire set of panes. So undo only
                // while every screen still holds exactly the set of panes this change left
                // behind, and do it all or not at all (rolling back half of a cross-screen move
                // would conjure a pane out of nowhere, or lose one)
                guard before.allSatisfy({ $0.matchesLive() }) else {
                    for snapshot in before {
                        snapshot.controller?.model.showControlFlash(
                            L("control.undo.stale", displayName(command)))
                    }
                    return
                }
                // When the undo itself closes panes (undoing `pane new`), register no redo: a
                // redo snapshot would hold on to a pane that has already run its teardown, and
                // could even put it back into the layout
                let closes = before.contains { $0.closesPanesOnRestore }
                for snapshot in before { _ = snapshot.restore() }
                if !after.isEmpty, !closes {
                    var redo = after
                    for index in redo.indices { redo[index].stampExpectedPanes() }
                    register(command: command, before: redo)
                }
                for snapshot in before {
                    snapshot.controller?.model.showControlFlash(
                        L("control.undo.undone", displayName(command)))
                }
            }
        }
        manager.setActionName(displayName(command))
    }
}
