import AppKit
import XCTest
@testable import QuickTerm

/// Agent resume data (session restore, spec decisions 13–18): which agent each terminal pane
/// offers to resume after a relaunch, and the command line that offer would type.
///
/// The session id comes from a program running in the pane and ends up in a line typed into the
/// user's shell, so most of these cases are about what is **refused**.
@MainActor
final class AgentResumeTests: XCTestCase {
    private static let claude = """
    id = "claude-code"
    name = "Claude Code"
    process = ["claude"]

    [resume]
    session = ["claude", "--resume", "{session}"]
    latest  = ["claude", "--continue"]
    """

    private func status(_ agent: String = "claude-code", session: String? = nil,
                        since: Date = Date(timeIntervalSince1970: 1_000)) -> AgentStatus {
        AgentStatus(agent: agent, name: agent, state: .idle, since: since, evidence: .hook,
                    sessionID: session)
    }

    private func running(_ agent: String = "claude-code", pid: pid_t = 100) -> AgentPresence {
        AgentPresence(byRule: [agent: [pid]])
    }

    // MARK: Validation and quoting

    func testSessionIDValidation() {
        XCTAssertTrue(AgentResume.isValidSessionID("a1b2c3d4"))
        XCTAssertTrue(AgentResume.isValidSessionID("sess_0f9e8d7c-6b5a-4321-abcd-ef0123456789"))
        XCTAssertTrue(AgentResume.isValidSessionID(String(repeating: "a", count: 128)), "128 is the upper bound")
        XCTAssertFalse(AgentResume.isValidSessionID("short"))
        XCTAssertFalse(AgentResume.isValidSessionID("a1b2c3d"), "seven characters is one too few")
        XCTAssertFalse(AgentResume.isValidSessionID(String(repeating: "a", count: 129)))
        XCTAssertFalse(AgentResume.isValidSessionID("abc'; rm -rf ~"))
        XCTAssertFalse(AgentResume.isValidSessionID("a b c d e f g h"))
        XCTAssertFalse(AgentResume.isValidSessionID("ａｂｃｄｅｆｇｈ"), "letters means ASCII letters")
        XCTAssertFalse(AgentResume.isValidSessionID("a1b2c3d4\n"))
    }

    func testResumeLineQuotesEveryArgument() {
        XCTAssertEqual(AgentResume.shellLine(["claude", "--resume", "a1b2c3d4"]),
                       "'claude' '--resume' 'a1b2c3d4'")
        XCTAssertEqual(AgentResume.shellLine(["echo", "it's"]), #"'echo' 'it'\''s'"#,
                       "a quote inside an argument closes, escapes and reopens")
    }

    func testCommandUsesLatestWithoutSession() throws {
        let rules = try AgentRules.parse(Self.claude)
        XCTAssertEqual(AgentResume.command(rules: rules, session: "a1b2c3d4"),
                       ["claude", "--resume", "a1b2c3d4"])
        XCTAssertEqual(AgentResume.command(rules: rules, session: nil), ["claude", "--continue"])
        XCTAssertNil(AgentResume.command(rules: rules, session: "abc'; rm -rf ~"),
                     "an id that fails the check is never typed, and never quietly becomes `latest`")

        let noResume = try AgentRules.parse(Self.claude.replacingOccurrences(
            of: "[resume]\nsession = [\"claude\", \"--resume\", \"{session}\"]\nlatest  = [\"claude\", \"--continue\"]",
            with: ""))
        XCTAssertNil(AgentResume.command(rules: noResume, session: "a1b2c3d4"))
        XCTAssertNil(AgentResume.command(rules: noResume, session: nil))

        let latestOnly = try AgentRules.parse(Self.claude.replacingOccurrences(
            of: "session = [\"claude\", \"--resume\", \"{session}\"]\n", with: ""))
        XCTAssertEqual(AgentResume.command(rules: latestOnly, session: nil), ["claude", "--continue"])
        XCTAssertNil(AgentResume.command(rules: latestOnly, session: "a1b2c3d4"),
                     "a known session is not swapped for whatever session is most recent")
    }

    // MARK: Which panes keep a record

    func testOnlyARunningAgentIsKept() {
        let alive = UUID(), exited = UUID(), otherAgent = UUID()
        let records = AgentResume.records(
            statuses: [alive: status(session: "a1b2c3d4"),
                       exited: status(session: "e5f6a7b8"),
                       otherAgent: status(session: "c9d0e1f2")],
            running: [alive: running(), otherAgent: running("codex")],
            directories: [alive: "/tmp/a", exited: "/tmp/b", otherAgent: "/tmp/c"])
        XCTAssertEqual(records, [alive: AgentResumeRecord(agent: "claude-code", session: "a1b2c3d4")],
                       "a status alone is not enough: the scan has to find that agent's own process")
    }

    func testAnInvalidSessionIsTreatedAsNoSession() {
        let pane = UUID()
        let records = AgentResume.records(statuses: [pane: status(session: "abc'; rm -rf ~")],
                                          running: [pane: running()],
                                          directories: [pane: "/tmp/a"])
        XCTAssertEqual(records, [pane: AgentResumeRecord(agent: "claude-code", session: nil)])
    }

    func testDuplicateSessionKeepsTheLatestPane() {
        let older = UUID(), newer = UUID()
        let records = AgentResume.records(
            statuses: [older: status(session: "a1b2c3d4", since: Date(timeIntervalSince1970: 1_000)),
                       newer: status(session: "a1b2c3d4", since: Date(timeIntervalSince1970: 2_000))],
            running: [older: running(pid: 1), newer: running(pid: 2)],
            directories: [older: "/tmp/a", newer: "/tmp/b"])
        XCTAssertEqual(records, [newer: AgentResumeRecord(agent: "claude-code", session: "a1b2c3d4")],
                       "the pane that reported the session last is the only one to offer it")

        let tie = AgentResume.records(
            statuses: [older: status(session: "a1b2c3d4"), newer: status(session: "a1b2c3d4")],
            running: [older: running(pid: 1), newer: running(pid: 2)],
            directories: [older: "/tmp/a", newer: "/tmp/b"])
        XCTAssertEqual(tie, [:], "with no pane later than the other, neither offers the session")
    }

    func testLatestNeedsASinglePaneInTheDirectory() {
        let alone = UUID(), shared1 = UUID(), shared2 = UUID(), withSession = UUID(), codex = UUID()
        let homeless = UUID()
        let records = AgentResume.records(
            statuses: [alone: status(), shared1: status(), shared2: status(),
                       withSession: status(session: "a1b2c3d4"), codex: status("codex"),
                       homeless: status()],
            running: [alone: running(), shared1: running(), shared2: running(),
                      withSession: running(), codex: running("codex"), homeless: running()],
            directories: [alone: "/tmp/alone", shared1: "/tmp/shared",
                          shared2: "/tmp/./shared/", withSession: "/tmp/codex",
                          codex: "/tmp/codex"])
        XCTAssertEqual(records[alone], AgentResumeRecord(agent: "claude-code", session: nil))
        XCTAssertNil(records[shared1], "two Claude Code panes in one directory: `latest` cannot tell them apart")
        XCTAssertNil(records[shared2], "paths are compared standardized")
        XCTAssertEqual(records[codex], AgentResumeRecord(agent: "codex", session: nil),
                       "another agent in the same directory does not count")
        XCTAssertEqual(records[withSession], AgentResumeRecord(agent: "claude-code", session: "a1b2c3d4"))
        XCTAssertNil(records[homeless], "with no saved directory there is no directory to resume in")

        // A pane with the agent running but no registry status still makes `latest` ambiguous.
        let lone = UUID(), unseen = UUID()
        let crowded = AgentResume.records(statuses: [lone: status()],
                                          running: [lone: running(pid: 1), unseen: running(pid: 2)],
                                          directories: [lone: "/tmp/x", unseen: "/tmp/x"])
        XCTAssertEqual(crowded, [:])
    }

    // MARK: Quit-time capture

    private func pane() throws -> Ghostty.SurfaceView {
        let appDelegate = try XCTUnwrap(NSApp.delegate as? AppDelegate)
        return Ghostty.SurfaceView(try XCTUnwrap(appDelegate.ghostty.app),
                                   baseConfig: Ghostty.SurfaceConfiguration())
    }

    func testCaptureFillsEveryPaneAndClearsTheRest() throws {
        let found = try pane(), gone = try pane()
        found.pwd = "/tmp/found"
        gone.agentResumeRecord = AgentResumeRecord(agent: "codex", session: "stale-session-id")
        AgentResume.capture(into: [found, gone], enabled: true,
                            statuses: [found.id: status(session: "a1b2c3d4"),
                                       gone.id: status("codex", session: "stale-session-id")]) {
            ProcessScan.Result(byPane: [found.id: self.running()])
        }
        XCTAssertEqual(found.agentResumeRecord, AgentResumeRecord(agent: "claude-code", session: "a1b2c3d4"))
        XCTAssertNil(gone.agentResumeRecord, "a record from an earlier launch never outlives this quit")
    }

    func testCaptureOffClearsWithoutScanning() throws {
        let only = try pane()
        only.agentResumeRecord = AgentResumeRecord(agent: "claude-code", session: "a1b2c3d4")
        var scanned = false
        AgentResume.capture(into: [only], enabled: false,
                            statuses: [only.id: status(session: "a1b2c3d4")]) {
            scanned = true
            return ProcessScan.Result(byPane: [only.id: self.running()])
        }
        XCTAssertFalse(scanned, "`[restore] agent-resume = false` does not walk the process table")
        XCTAssertNil(only.agentResumeRecord)
    }

    func testCaptureWithoutAScanKeepsNothing() throws {
        let only = try pane()
        AgentResume.capture(into: [only], enabled: true,
                            statuses: [only.id: status(session: "a1b2c3d4")]) { nil }
        XCTAssertNil(only.agentResumeRecord, "no scan, no proof the agent was still running")
    }
}
