import Foundation

/// **The resume button of one restored pane** (session restore, spec decisions 13, 16, 19, 20).
///
/// A pane whose agent was still running at quit comes back as an ordinary shell with this offer
/// in its agent band. Accepting it types the agent's resume command into the shell, once, as soon
/// as the shell is ready to read it.
///
/// "Ready" is decided by watching the viewport text: engine 1.3.1 reports no prompt start and has
/// no per-surface output callback. The pane was created with its restored content already on
/// screen, so the shell's first output (its prompt) changes the viewport; once it has changed and
/// then stayed unchanged for `quietPeriod`, the shell is waiting for input. The viewport is read
/// every `pollInterval`, and only between the click and the send. If the screen never settles,
/// the line goes anyway `maxWait` after the click, which is no worse than typing it by hand.
///
/// All timing goes through `Scheduler`, so the tests drive the clock and never sleep.
@MainActor
final class ResumeOffer {
    /// How often the viewport is read while waiting.
    static let pollInterval: TimeInterval = 0.1
    /// How long the viewport has to stay unchanged after the shell's output for it to be ready.
    static let quietPeriod: TimeInterval = 0.3
    /// The line is sent this long after the click whatever the screen is doing.
    static let maxWait: TimeInterval = 5

    /// A clock and a one-shot timer. `main` is the real one.
    struct Scheduler {
        var now: @MainActor () -> TimeInterval
        var after: @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> Void

        static let main = Scheduler(
            now: { ProcessInfo.processInfo.systemUptime },
            after: { delay, work in
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    MainActor.assumeIsolated { work() }
                }
            })
    }

    /// The button text, for example `Claude Code · Resume last session`.
    let label: String
    /// The button tooltip (launch flags are not restored).
    let help: String
    /// The exact text typed into the shell: the quoted command and a Return.
    let line: String

    private let snapshot: @MainActor () -> String
    private let send: @MainActor (String) -> Void
    private let scheduler: Scheduler

    /// The viewport when the offer was made, i.e. right after the restored content was fed.
    private let baseline: String
    private var lastText: String
    private var lastChangeAt: TimeInterval
    private var lastObservedAt: TimeInterval
    private var changedSinceRestore = false

    private enum Phase { case offered, waiting, done }
    private var phase = Phase.offered

    /// nil when the rule file has no matching resume form, or the session id fails the check
    /// again (`AgentResume.command`): there is then nothing safe to type.
    init?(record: AgentResumeRecord, rules: AgentRules,
          snapshot: @escaping @MainActor () -> String,
          send: @escaping @MainActor (String) -> Void,
          scheduler: Scheduler = .main) {
        guard let argv = AgentResume.command(rules: rules, session: record.session) else { return nil }
        label = record.session != nil ? RestoreText.resumeButton(agent: rules.name)
                                      : RestoreText.resumeLatest(agent: rules.name)
        help = RestoreText.resumeHelp
        line = AgentResume.shellLine(argv) + "\r"
        self.snapshot = snapshot
        self.send = send
        self.scheduler = scheduler
        let now = scheduler.now()
        baseline = snapshot()
        lastText = baseline
        lastChangeAt = now
        lastObservedAt = now
    }

    /// The offer a pane decoded from the archive gets, or nil. Ruling: only with `[restore]
    /// agent-resume` on, a decoded record, a loaded rule file for its agent, and a saved directory
    /// that still exists (spec decision 20: the directory-gone line is shown instead).
    static func forRestoredPane(record: AgentResumeRecord?, settings: ConfigStore.Settings,
                                directoryGone: Bool, rules: [String: AgentRules],
                                snapshot: @escaping @MainActor () -> String,
                                send: @escaping @MainActor (String) -> Void,
                                scheduler: Scheduler = .main) -> ResumeOffer? {
        guard settings.restoreAgentResume, !directoryGone, let record,
              let agentRules = rules[record.agent] else { return nil }
        return ResumeOffer(record: record, rules: agentRules, snapshot: snapshot, send: send,
                           scheduler: scheduler)
    }

    /// The viewport has changed since the restore and has then been unchanged for `quietPeriod`,
    /// as far as the reads so far can tell.
    var isReady: Bool {
        // A hair of tolerance: the poll times are sums of 0.1 and do not land exactly.
        changedSinceRestore && lastObservedAt - lastChangeAt >= Self.quietPeriod - 1e-6
    }

    /// Read the viewport once and update the readiness state. The poll calls it; so does a
    /// click, so a screen that is already settled is judged from the click on.
    func observe() {
        let now = scheduler.now()
        let text = snapshot()
        if text != lastText {
            lastText = text
            lastChangeAt = now
        }
        if text != baseline { changedSinceRestore = true }
        lastObservedAt = now
    }

    /// The click. Sends at once when ready, otherwise as soon as it is, and in any case
    /// `maxWait` from now. At most once; a dismissed offer never sends.
    func accept() {
        guard phase == .offered else { return }
        phase = .waiting
        if isReady { return fire() }
        observe()
        if isReady { return fire() }
        // The scheduled work holds the offer strongly until it has sent or been dismissed, at most
        // `maxWait`: the pane takes the button away on the click and may drop its reference.
        scheduler.after(Self.maxWait) { self.fire() }
        schedulePoll()
    }

    /// The user typed, or an agent started in the pane: nothing will be sent.
    func dismiss() { phase = .done }

    private func schedulePoll() {
        scheduler.after(Self.pollInterval) {
            guard self.phase == .waiting else { return }
            self.observe()
            if self.isReady { self.fire() } else { self.schedulePoll() }
        }
    }

    private func fire() {
        guard phase == .waiting else { return }
        phase = .done
        send(line)
    }
}
