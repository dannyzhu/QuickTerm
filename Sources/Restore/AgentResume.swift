import Foundation

/// What one terminal pane offers to resume after a relaunch (spec decision 15): the agent's rule id
/// and, when one was reported and passed the check, its session id. Nothing else is saved; the
/// pane's own archived working directory is the directory to resume in.
struct AgentResumeRecord: Codable, Equatable {
    var agent: String
    var session: String?
}

/// **Which agent to offer to resume in each pane, and the line that offer types** (session
/// restore, spec decisions 13–18).
///
/// The session id was reported by a program running in the pane, and the resume offer types a
/// line containing it into the user's shell. So it is checked against a narrow pattern before it
/// is kept, and the line is built from the rule file's argument array with every word quoted.
enum AgentResume {
    /// Set by `AppSession.exportRestoreContentOnce` right after the quit-time capture, before both
    /// quit paths' final `saveNow()`. Cleared only by `AppSession.cancelQuitExport`, when a screen
    /// is opened after closing the last one did not end the process. Until
    /// it is set, no save writes an `agentResume` key: a debounced save mid-run would otherwise
    /// write a record that a crash or force quit leaves in the archive, offering at the next
    /// launch an agent nobody proved was running at quit (spec decision 13).
    @MainActor static var quitSaveStarted = false

    /// Spec decision 16: `^[A-Za-z0-9][A-Za-z0-9_-]{7,127}$`, ASCII only. The first character
    /// is a letter or digit so the id can never be read as an option: shell quoting keeps
    /// `--dangerously-skip-permissions` one word, but the agent's own parser would still take it
    /// as a flag. Real ids (Claude Code and Codex UUIDs, kiro's `cli_<uuid>_<8>`) all start with one.
    static func isValidSessionID(_ id: String) -> Bool {
        let bytes = id.utf8
        guard (8...128).contains(bytes.count), let first = bytes.first, isAlphanumeric(first) else {
            return false
        }
        return bytes.allSatisfy { isAlphanumeric($0) || $0 == UInt8(ascii: "_") || $0 == UInt8(ascii: "-") }
    }

    private static func isAlphanumeric(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"),
             UInt8(ascii: "0")...UInt8(ascii: "9"): true
        default: false
        }
    }

    /// The argument array to run, or nil when this rule file has no matching form. A session id
    /// uses the `session` form only; an id that fails the check yields nil rather than falling
    /// back to `latest`, because "the most recent session" may be another pane's.
    static func command(rules: AgentRules, session: String?) -> [String]? {
        guard let session else { return rules.resume?.latest }
        guard isValidSessionID(session), let form = rules.resume?.session else { return nil }
        return form.map { $0 == AgentRules.Resume.placeholder ? session : $0 }
    }

    /// One shell line: every argument single-quoted, a `'` inside one written as `'\''`.
    static func shellLine(_ argv: [String]) -> String {
        argv.map { "'" + $0.replacingOccurrences(of: "'", with: #"'\''"#) + "'" }
            .joined(separator: " ")
    }

    /// The records to keep, by pane.
    ///
    /// - A pane is kept only when the scan found **that agent's** process in it (decision 13): a
    ///   registry status can come from OSC text, or outlive its process.
    /// - A session id that fails `isValidSessionID` is treated as no session id (decision 16).
    /// - Two panes with the same agent and session id: only the one whose status changed last
    ///   keeps it (decision 18). A tie has no "last", so neither does.
    /// - No session id: kept only when no other pane in the same directory (standardized) has
    ///   the same agent running, since `latest` cannot tell two such panes apart (decision 17).
    ///   A pane with no saved directory has nowhere to resume and is dropped.
    static func records(statuses: [UUID: AgentStatus], running: [UUID: AgentPresence],
                        directories: [UUID: String]) -> [UUID: AgentResumeRecord] {
        func isRunning(_ agent: String, in pane: UUID) -> Bool {
            !(running[pane]?.byRule[agent]?.isEmpty ?? true)
        }
        func standardized(_ path: String) -> String { (path as NSString).standardizingPath }

        var withSession: [UUID: (status: AgentStatus, session: String)] = [:]
        var withoutSession: [UUID: AgentStatus] = [:]
        for (pane, status) in statuses where isRunning(status.agent, in: pane) {
            if let session = status.sessionID, isValidSessionID(session) {
                withSession[pane] = (status, session)
            } else {
                withoutSession[pane] = status
            }
        }

        var out: [UUID: AgentResumeRecord] = [:]
        for (pane, entry) in withSession {
            let rivals = withSession.filter {
                $0.key != pane && $0.value.status.agent == entry.status.agent && $0.value.session == entry.session
            }
            guard rivals.allSatisfy({ $0.value.status.since < entry.status.since }) else { continue }
            out[pane] = AgentResumeRecord(agent: entry.status.agent, session: entry.session)
        }
        for (pane, status) in withoutSession {
            guard let directory = directories[pane].map(standardized) else { continue }
            let sharing = running.keys.filter { other in
                other != pane && isRunning(status.agent, in: other)
                    && directories[other].map(standardized) == directory
            }
            guard sharing.isEmpty else { continue }
            out[pane] = AgentResumeRecord(agent: status.agent, session: nil)
        }
        return out
    }

    /// Quit-time capture: set every pane's `agentResumeRecord` from this moment's statuses and one
    /// process scan. Every pane is cleared first, so a record decoded at launch never survives a
    /// quit at which its agent was no longer running. With `enabled` off (`[restore]
    /// agent-resume = false`) or no panes the scan is not run; when it cannot run (detection
    /// off) nothing is kept, because nothing proves the agent was still there.
    @MainActor
    static func capture(into panes: [Ghostty.SurfaceView], enabled: Bool,
                        statuses: [UUID: AgentStatus], scan: () -> ProcessScan.Result?) {
        for pane in panes { pane.agentResumeRecord = nil }
        guard enabled, !panes.isEmpty, let result = scan() else { return }
        var directories: [UUID: String] = [:]
        for pane in panes {
            if let directory = pane.archivedWorkingDirectory { directories[pane.id] = directory }
        }
        let found = records(statuses: statuses, running: result.byPane, directories: directories)
        for pane in panes { pane.agentResumeRecord = found[pane.id] }
    }
}
